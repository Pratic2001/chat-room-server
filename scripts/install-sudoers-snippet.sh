#!/usr/bin/env bash
# install-sudoers-snippet.sh — install the
# /etc/sudoers.d/99-jenkins-deploy snippet on one or more k8s nodes.
#
# This is the script that fixes the failure mode where bootstrap.sh
# (or some other operator) wrote an empty or wrong-path sudoers file
# to /etc/sudoers.d/99-jenkins-deploy, leaving the `pratic` user
# unable to run `sudo -n kubectl` or `sudo -n ctr -n k8s.io images …`
# from Jenkins. The Distribute to cluster stage of the Jenkinsfile
# depends on those working without a password.
#
# What the snippet grants (paths must match `which kubectl` and
# `which ctr` on every node — defaults assume Ubuntu 22.04+ kubeadm):
#
#   %sudo ALL=(ALL) NOPASSWD: /usr/bin/ctr -n k8s.io images *
#   %sudo ALL=(ALL) NOPASSWD: /usr/bin/kubectl *
#
# Everything else still requires a password — this script does NOT
# grant blanket NOPASSWD sudo to pratic.
#
# Usage:
#   install-sudoers-snippet.sh [user@host ...]
#
# With no arguments, defaults to pratic@192.168.0.104 and
# pratic@192.168.0.106 (the cluster used by this repo). Pass
# different user@host pairs to target other clusters.
#
# Requires:
#   - ssh + scp access to every target (passwordless key)
#   - the target user has sudo rights on its host
#   - the target user is in the `sudo` group (Ubuntu) or `wheel`
#     group (RHEL-family — edit the snippet in this file if your
#     cluster uses wheel)
#
# Sudo password
# -------------
# The script reads the sudo password once and uses it for every
# node. Three ways to supply it (highest precedence first):
#
#   1. Pipe it on stdin (recommended for non-interactive runs):
#        echo "$PW" | ./scripts/install-sudoers-snippet.sh
#
#   2. SUDO_PASSWORD env var:
#        SUDO_PASSWORD="$PW" ./scripts/install-sudoers-snippet.sh
#
#   3. SUDO_PASSWORD_FILE env var pointing at a readable file:
#        SUDO_PASSWORD_FILE=~/.chatroom-bootstrap/sudo.pw \
#          ./scripts/install-sudoers-snippet.sh
#
#   4. Interactive prompt (only when stdin is a TTY).
#
# The password is held only in the script's memory for the duration
# of the install and is NEVER echoed to the terminal or written to
# disk by this script.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install-sudoers-snippet.sh [-h] [user@host ...]

Install the /etc/sudoers.d/99-jenkins-deploy snippet on one or more
k8s nodes. With no arguments, defaults to pratic@192.168.0.104 and
pratic@192.168.0.106 (the cluster used by this repo).

Sudo password can be supplied via:
  1. stdin:        echo "$PW" | install-sudoers-snippet.sh
  2. SUDO_PASSWORD env var
  3. SUDO_PASSWORD_FILE env var (path to a chmod-600 file)
  4. interactive prompt (only when stdin is a TTY)

Options:
  -h    Show this help and exit.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

# --- 0. Sudo password (read once, before any ssh call consumes stdin) ---
if [[ -n "${SUDO_PASSWORD:-}" ]]; then
  :
elif [[ -n "${SUDO_PASSWORD_FILE:-}" && -r "${SUDO_PASSWORD_FILE}" ]]; then
  IFS= read -r SUDO_PASSWORD < "${SUDO_PASSWORD_FILE}" || SUDO_PASSWORD=""
else
  if [[ -t 0 ]]; then
    read -rs -p "sudo password for the target user on k8s nodes: " SUDO_PASSWORD
    echo
  else
    IFS= read -r SUDO_PASSWORD || SUDO_PASSWORD=""
  fi
fi

if [[ -z "${SUDO_PASSWORD:-}" ]]; then
  echo "ERROR: no sudo password supplied." >&2
  echo "  Pipe it:        echo \"\$PW\" | $0" >&2
  echo "  Or set:         SUDO_PASSWORD=... $0" >&2
  echo "  Or set:         SUDO_PASSWORD_FILE=/path/to/file $0" >&2
  exit 1
fi

# --- 1. Targets ---
if [[ $# -gt 0 ]]; then
  TARGETS=("$@")
else
  TARGETS=("pratic@192.168.0.104" "pratic@192.168.0.106")
fi

# --- 2. The snippet content. This MUST match what scripts/bootstrap.sh
#       installs. If you change one, change the other; better still,
#       have bootstrap.sh source this variable (TODO once bootstrap.sh
#       is refactored).
SNIPPET_CONTENT='%sudo ALL=(ALL) NOPASSWD: /usr/bin/ctr -n k8s.io images *
%sudo ALL=(ALL) NOPASSWD: /usr/bin/kubectl *
'

# --- 3. Sanity check that the snippet is well-formed before we try to
#       install it on any node. visudo on the local box parses it; if
#       the local box doesn't have sudoers/visudo (very unusual), we
#       still proceed — the per-node `visudo -c` step below catches
#       syntax errors on the target.
if command -v visudo >/dev/null 2>&1; then
  TMP_CHECK="$(mktemp)"
  trap 'rm -f "$TMP_CHECK"' EXIT
  printf '%s\n' "$SNIPPET_CONTENT" > "$TMP_CHECK"
  if ! visudo -c -f "$TMP_CHECK" >/dev/null 2>&1; then
    echo "ERROR: the embedded snippet failed local visudo -c validation:" >&2
    visudo -c -f "$TMP_CHECK" >&2 || true
    rm -f "$TMP_CHECK"
    trap - EXIT
    exit 1
  fi
fi

# --- 4. Install on every target. Per target we:
#       a. scp the snippet to a temp path on the target (so we don't
#          clobber the live file with a partial write).
#       b. ssh in, read the sudo password from stdin (ssh's stdin
#          always passes through sshd), then sudo -S bash -c '...'
#          does the actual install.
#       c. The remote `install` does an atomic rename with the right
#          ownership/mode in one syscall — this avoids the failure
#          mode where a broken tee left a 0-byte file at the snippet
#          path with mode 0644 from the umask, which sudo then
#          interprets as a no-op file.
#       d. The remote `visudo -c` validates the new file with the
#          target's own sudo parser before we declare success.
INSTALLED=0
SKIPPED=0
FAILED=0
for TARGET in "${TARGETS[@]}"; do
  echo "==> $TARGET"
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$TARGET" true >/dev/null 2>&1 || {
    echo "  cannot reach $TARGET (ssh failed); skipping" >&2
    FAILED=$((FAILED+1))
    continue
  }

  # Stage the snippet on the target.
  # `scp -q` is quiet; we don't care about scp's exit if the file
  # already exists at the target — we just overwrite.
  if ! printf '%s\n' "$SNIPPET_CONTENT" \
       | ssh "$TARGET" "cat > /tmp/99-jenkins-deploy.new"; then
    echo "  failed to stage snippet on $TARGET" >&2
    FAILED=$((FAILED+1))
    continue
  fi

  # Install: read password from ssh stdin, sudo -S into a single
  # bash -c that does install + visudo -c validation + cleanup.
  REMOTE_OUTPUT=$(ssh "$TARGET" bash -s <<EOF
IFS= read -r SUDO_PW
printf '%s\n' "\$SUDO_PW" | sudo -S -p '' bash -c '
  set -e
  install -m 0440 -o root -g root /tmp/99-jenkins-deploy.new \\
    /etc/sudoers.d/99-jenkins-deploy \\
    && rm -f /tmp/99-jenkins-deploy.new \\
    && visudo -c -f /etc/sudoers.d/99-jenkins-deploy \\
    && echo OK
'
EOF
) || {
    echo "  install on $TARGET failed; sudo password wrong, or remote visudo rejected the snippet" >&2
    FAILED=$((FAILED+1))
    continue
  }

  if [[ "$REMOTE_OUTPUT" == *"OK"* ]]; then
    # Verify the install actually works (defence in depth: even if
    # the remote script said OK, run an independent sudo -n probe).
    if ssh "$TARGET" "sudo -n true" >/dev/null 2>&1; then
      echo "  installed and sudo -n works"
      INSTALLED=$((INSTALLED+1))
    elif [[ "$REMOTE_OUTPUT" == *"already correct"* ]]; then
      echo "  already correct"
      SKIPPED=$((SKIPPED+1))
    else
      # The snippet installed but sudo -n still prompts — the
      # snippet path likely doesn't match where kubectl/ctr live on
      # this node.
      REMOTE_KUBECTL=$(ssh "$TARGET" "which kubectl" 2>/dev/null || echo "")
      REMOTE_CTR=$(ssh "$TARGET" "which ctr" 2>/dev/null || echo "")
      echo "  installed, but 'sudo -n true' still prompts." >&2
      echo "    This node's binaries are:" >&2
      echo "      kubectl: ${REMOTE_KUBECTL:-(not found in PATH)}" >&2
      echo "      ctr:     ${REMOTE_CTR:-(not found in PATH)}" >&2
      echo "    The embedded snippet assumes /usr/bin/kubectl and" >&2
      echo "    /usr/bin/ctr. Edit SNIPPET_CONTENT in this script" >&2
      echo "    to match the real paths and re-run." >&2
      FAILED=$((FAILED+1))
    fi
  else
    echo "  install on $TARGET returned unexpected output: $REMOTE_OUTPUT" >&2
    FAILED=$((FAILED+1))
  fi
done

# --- 5. Summary ---
echo
echo "Summary: $INSTALLED installed, $SKIPPED already correct, $FAILED failed"

if [[ "$FAILED" -gt 0 ]]; then
  exit 1
fi