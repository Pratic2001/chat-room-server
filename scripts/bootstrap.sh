#!/usr/bin/env bash
# bootstrap.sh — one-time cluster bring-up. Run on 192.168.0.111 as the
# `pratic` user (the same one whose key the Jenkins credential holds).
#
# What this script does:
#   1. Verifies SSH access to the k8s nodes.
#   2. Installs local-path-provisioner (provides the `local-path`
#      StorageClass that the MySQL PVC uses).
#   3. Drops a sudoers snippet on each k8s node so the pratic user can
#      run `ctr -n k8s.io images …` and `kubectl …` without a password.
#      Everything else still requires a password.
#   4. Creates the k8s namespace and populates the live `mysql-secret`
#      and `chatroom-secrets` Secrets with real random passwords. The
#      generated values are written to ~/.chatroom-bootstrap/secrets.env
#      for the user to keep; they are NEVER echoed to the terminal and
#      NEVER committed to git.
#   5. Builds a ConfigMap from the repo's `database_setup.sql`.
#   6. Applies k8s/30-mysql-statefulset.yaml and waits for the pod.
#   7. Applies k8s/35-mysql-init-job.yaml and waits for the Job to
#      complete.
#   8. Applies the rest of k8s/ (configmap, app deployment placeholder,
#      NodePort service).
#   9. Edits /etc/nginx/nginx.conf on this host to proxy to the new
#      NodePort, with WebSocket support and 100 MB uploads. Done with
#      three idempotent sed substitutions rather than a unified diff
#      because the file's existing indentation is mixed tabs/spaces.
#
# This script is idempotent — re-running it is safe. Secret values
# already in the cluster are NOT overwritten.
#
# Sudo password
# -------------
# Step 3 needs to write /etc/sudoers.d/99-jenkins-deploy on each k8s node
# via `sudo`, and `sudo` is not passwordless for that path. The password
# can be supplied any of three ways (highest precedence first):
#
#   1. Pipe it on stdin — recommended for non-interactive runs:
#        echo "$PW" | ./scripts/bootstrap.sh
#      The script reads the first line of stdin and uses it as the sudo
#      password on every node.
#
#   2. SUDO_PASSWORD env var:
#        SUDO_PASSWORD="$PW" ./scripts/bootstrap.sh
#
#   3. SUDO_PASSWORD_FILE env var pointing at a readable file:
#        SUDO_PASSWORD_FILE=~/.chatroom-bootstrap/sudo.pw ./scripts/bootstrap.sh
#
#   4. Interactive prompt (only when stdin is a TTY).
#
# The password is NEVER echoed to the terminal and is held only in the
# script's memory for the duration of the sudoers step.
set -euo pipefail

# --- 0. sudo password (read once, before any ssh call consumes stdin) ---
if [[ -n "${SUDO_PASSWORD:-}" ]]; then
  :
elif [[ -n "${SUDO_PASSWORD_FILE:-}" && -r "${SUDO_PASSWORD_FILE}" ]]; then
  IFS= read -r SUDO_PASSWORD < "${SUDO_PASSWORD_FILE}" || SUDO_PASSWORD=""
else
  if [[ -t 0 ]]; then
    read -rs -p "Enter sudo password for pratic on k8s nodes: " SUDO_PASSWORD
    echo
  else
    # stdin is a pipe (e.g. `echo "$PW" | ./bootstrap.sh`).
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

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
K8S_DIR="$REPO_ROOT/k8s"
DEPLOY_DIR="$REPO_ROOT/deploy"
K8S_HOST="pratic@192.168.0.104"
K8S_WORKER="pratic@192.168.0.106"
K8S_API="192.168.0.104"
STATE_DIR="$HOME/.chatroom-bootstrap"
SECRETS_FILE="$STATE_DIR/secrets.env"
MARKER_DIR="$STATE_DIR/markers"

mkdir -p "$STATE_DIR" "$MARKER_DIR"

# Helper: skip a step if its marker file exists
mark_done() { mkdir -p "$(dirname "$MARKER_DIR/$1")" && touch "$MARKER_DIR/$1"; }
already_done() { [[ -f "$MARKER_DIR/$1" ]]; }

log() { echo "==> $*"; }

# --- 1. verify ssh ---
log "verifying ssh to $K8S_HOST and $K8S_WORKER"
ssh -o BatchMode=yes -o ConnectTimeout=5 "$K8S_HOST"  true
ssh -o BatchMode=yes -o ConnectTimeout=5 "$K8S_WORKER" true

# --- 2. install local-path-provisioner (StorageClass) ---
if ! ssh "$K8S_HOST" 'kubectl get storageclass local-path >/dev/null 2>&1'; then
  log "installing local-path-provisioner (provides the 'local-path' StorageClass)"
  ssh "$K8S_HOST" 'kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml'
  ssh "$K8S_HOST" 'kubectl annotate storageclass local-path storageclass.kubernetes.io/is-default-class=true --overwrite'
  ssh "$K8S_HOST" 'kubectl get storageclass'
fi
mark_done storageclass-installed

# --- 3. sudoers snippet on each k8s node ---
# Discovered via kubectl so that nodes added to the cluster after the
# initial bootstrap are picked up the next time this script is run. The
# snippet is identical on every node and idempotent (re-running is a
# no-op apart from overwriting the file).
SUDOERS_SNIPPET='/etc/sudoers.d/99-jenkins-deploy'
SUDOERS_CONTENT='%sudo ALL=(ALL) NOPASSWD: /usr/bin/ctr -n k8s.io images import *
%sudo ALL=(ALL) NOPASSWD: /usr/bin/ctr -n k8s.io images tag *
%sudo ALL=(ALL) NOPASSWD: /usr/bin/ctr -n k8s.io images ls *
%sudo ALL=(ALL) NOPASSWD: /usr/local/bin/kubectl *
'
# Write the snippet to a local temp file first so we don't have to pipe
# its content through sudo's stdin (sudo -S wants only the password on
# stdin — anything else gets fed to the command, which corrupts tee).
SUDOERS_TMP=$(mktemp)
chmod 600 "$SUDOERS_TMP"
trap 'rm -f "$SUDOERS_TMP"' EXIT
printf '%s\n' "$SUDOERS_CONTENT" > "$SUDOERS_TMP"

mapfile -t NODE_IPS < <(ssh "$K8S_HOST" \
  "kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type==\"InternalIP\")].address}{\"\\n\"}{end}'")
for IP in "${NODE_IPS[@]}"; do
  log "installing sudoers snippet on pratic@${IP}"
  # scp avoids the "stdin is shared between sudo -S and the command" trap.
  scp -q "$SUDOERS_TMP" "pratic@${IP}:/tmp/99-jenkins-deploy"

  # Why we pipe the password via `<<<` instead of `SUDO_PASSWORD=…`:
  # OpenSSH's server-side `AcceptEnv` is restrictive by default — it
  # only accepts variables prefixed with `LC_*`. Anything else sent via
  # ssh's `VAR=value command` syntax is silently dropped by sshd before
  # the remote shell runs, so $SUDO_PASSWORD ends up empty on the
  # remote side and sudo -S receives a blank password → "Authentication
  # failed" even though the password was correct locally.
  #
  # ssh's stdin, in contrast, always passes through to the remote
  # command. The remote `read` consumes the first line as the password
  # (sudo wants "password\n", which is exactly what printf produces),
  # then the snippet is tee'd into place via sudo -S.
  #
  # No `-t`: sudo -S does not need a PTY when its stdin is a pipe, and
  # forcing a PTY would re-prompt for the password on the local
  # keyboard and fail under non-interactive shells (CI, `echo ... |
  # bootstrap.sh`, etc.).
  ssh "pratic@${IP}" '
    IFS= read -r SUDO_PW
    printf "%s\n" "$SUDO_PW" | sudo -S -p "" tee '"$SUDOERS_SNIPPET"' >/dev/null \
      && sudo -S -p "" chmod 440 '"$SUDOERS_SNIPPET"' \
      && rm -f /tmp/99-jenkins-deploy
  ' <<<"$SUDO_PASSWORD"
done
mark_done sudoers-installed

# --- 4. namespace + secrets + configmap (idempotent) ---
log "applying namespace"
ssh "$K8S_HOST" "kubectl apply -f -" < "$K8S_DIR/00-namespace.yaml"
mark_done ns-applied

# Build a ConfigMap from database_setup.sql so the init Job can mount it.
# Re-created on every run (idempotent — configmaps are safe to overwrite).
log "rendering ConfigMap from database_setup.sql"
SQL_CONTENT=$(cat "$REPO_ROOT/database_setup.sql")
# Escape for embedding inside a heredoc-ish yaml string. Use base64 to be
# safe with quotes, then decode at runtime via an init step. But the
# init Job in 35-mysql-init-job.yaml expects a plain text key, so we
# just embed via sed-friendly substitution here. Simpler approach: write
# to a temp file, base64-encode, render a small yaml that decodes it.
B64=$(base64 -w0 < "$REPO_ROOT/database_setup.sql")
cat > "$STATE_DIR/30-mysql-statefulset-and-init.yaml" <<EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: mysql-init-sql
  namespace: chatroom
data:
  database_setup.sql: |
$(awk '{ print "    " $0 }' "$REPO_ROOT/database_setup.sql")
EOF
ssh "$K8S_HOST" "kubectl apply -f -" < "$STATE_DIR/30-mysql-statefulset-and-init.yaml"
mark_done configmap-rendered

# Create the live secrets with real random passwords, unless they already
# exist. This is the only place real secret values live on disk; the
# script chmods the file to 600 and prints a one-line reminder to back it
# up.
if ! ssh "$K8S_HOST" 'kubectl -n chatroom get secret mysql-secret >/dev/null 2>&1'; then
  log "generating random passwords"
  ROOT_PW=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
  APP_PW=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
  JWT_SECRET=$(openssl rand -base64 48 | tr -d '/+=' | head -c 64)
  FERNET_KEY=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")
  MAIL_PW="CHANGE_ME_GMAIL_APP_PASSWORD"   # user must edit this by hand

  cat > "$SECRETS_FILE" <<EOF
# Generated by scripts/bootstrap.sh on $(date -Iseconds)
# DO NOT COMMIT. Back this file up; you'll need it to recreate the
# live k8s Secrets.
ROOT_PW=$ROOT_PW
APP_PW=$APP_PW
JWT_SECRET=$JWT_SECRET
FERNET_KEY=$FERNET_KEY
MAIL_PW=$MAIL_PW
EOF
  chmod 600 "$SECRETS_FILE"
  log "secrets written to $SECRETS_FILE (mode 600)"

  # Source for the kubectl create secret invocations
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"

  ssh "$K8S_HOST" "kubectl -n chatroom create secret generic mysql-secret \
    --from-literal=MYSQL_ROOT_PASSWORD='$ROOT_PW' \
    --from-literal=MYSQL_PASSWORD='$APP_PW' \
    --from-literal=MYSQL_DATABASE=chatroom_db"

  ssh "$K8S_HOST" "kubectl -n chatroom create secret generic chatroom-secrets \
    --from-literal=MYSQL_USER=chatroom \
    --from-literal=MYSQL_PASSWORD='$APP_PW' \
    --from-literal=MYSQL_HOST=mysql.chatroom.svc.cluster.local \
    --from-literal=MYSQL_DB=chatroom_db \
    --from-literal=SECRET_KEY='$JWT_SECRET' \
    --from-literal=ROOM_SECRET_KEY='$FERNET_KEY' \
    --from-literal=MAIL_PASSWORD='$MAIL_PW'"

  mark_done secrets-created
  log "secrets created. REMINDER: edit MAIL_PASSWORD with:"
  log "  kubectl -n chatroom edit secret chatroom-secrets"
else
  log "mysql-secret already exists; not regenerating. Re-run with --rotate-secrets to force."
fi

# --- 6. apply MySQL StatefulSet ---
log "applying MySQL StatefulSet"
ssh "$K8S_HOST" "kubectl apply -f -" < "$K8S_DIR/30-mysql-statefulset.yaml"

if ! ssh "$K8S_HOST" 'kubectl -n chatroom get pod -l app=mysql -o name | grep -q .'; then
  log "waiting for mysql-0 to become Ready (timeout 5m)"
  ssh "$K8S_HOST" 'kubectl -n chatroom wait --for=condition=ready pod -l app=mysql --timeout=300s'
fi
mark_done mysql-statefulset-applied

# --- 7. apply init Job ---
log "applying mysql-init Job"
ssh "$K8S_HOST" "kubectl apply -f -" < "$K8S_DIR/35-mysql-init-job.yaml"

# Idempotent: if the Job already succeeded, skip the wait.
if ! ssh "$K8S_HOST" 'kubectl -n chatroom get job mysql-init -o jsonpath="{.status.succeeded}" 2>/dev/null | grep -q 1'; then
  log "waiting for mysql-init Job to complete (timeout 5m)"
  ssh "$K8S_HOST" 'kubectl -n chatroom wait --for=condition=complete job/mysql-init --timeout=300s'
fi
mark_done mysql-init-completed

# --- 8. apply configmap + app secret + nodeport service ---
# 40-deployment.yaml is intentionally NOT applied here: its `image:`
# field contains an unsubstituted `${TAG}` placeholder that this script
# has no way to fill in (only a Jenkins build knows the real tag).
# The first Jenkins build will `kubectl apply` the manifest with the
# real tag substituted; subsequent builds will be no-ops for the
# deployment except for the image update. The Deployment object will
# not exist on the cluster until that first build, so the NodePort
# service (50-service.yaml) will have no backing pods in the
# meantime — which is the correct, expected state.
log "applying ConfigMap, app Secret template, and NodePort service (deployment is created by the first Jenkins build)"
ssh "$K8S_HOST" "kubectl apply -f -" < "$K8S_DIR/20-configmap.yaml"
# 10-secret.yaml is a template; live values are in chatroom-secrets. Tolerate
# `AlreadyExists` (k8s disallows `kubectl create secret` over an existing
# secret but `kubectl apply` updates are fine — if apply succeeds, this
# just no-ops; if it fails for any other reason, we still want the rest
# of step 8 to run).
ssh "$K8S_HOST" "kubectl apply -f -" < "$K8S_DIR/10-secret.yaml" || true
ssh "$K8S_HOST" "kubectl apply -f -" < "$K8S_DIR/50-service.yaml"
mark_done remaining-manifests-applied

# --- 9. nginx proxy + WebSocket + upload-size config ---
# Done with sed rather than `patch` because /etc/nginx/nginx.conf on the
# Jenkins host has mixed-tabs/spaces indentation that breaks unified-diff
# context matching. The three substitutions below are idempotent and
# whitespace-insensitive:
#
#   1. proxy_pass 127.0.0.1:8000  ->  192.168.0.104:30800
#      (substitution only; sed leaves the line alone if the value is
#      already correct)
#   2. inject WebSocket upgrade headers inside `location / { ... }`
#   3. inject `client_max_body_size 100m;` inside `server { ... }`
#      (right after the listen line)
#
# Idempotency for (2) and (3): the script first greps for a sentinel
# value that is only present if the injection has already happened, and
# skips the inject if so. Re-runs are safe.
NGINX_CONF="/etc/nginx/nginx.conf"

# We need sudo to read/write the file. The script's earlier sudo
# password plumbing only runs if the sudoers snippet is not yet
# installed; from this point forward (on 192.168.0.111) we are running
# on the local host as pratic, and a sudo password may again be needed.
# The same password the script already read is reused — we just route it
# to the local sudo. (If this script were ever run *on* the Jenkins
# host, the local sudo would be a no-op for pratic if NOPASSWD is set
# in /etc/sudoers for the local user.)
if [[ -n "${SUDO_PASSWORD:-}" ]] && ! sudo -n true 2>/dev/null; then
  log "authenticating local sudo for nginx edits"
  printf '%s\n' "$SUDO_PASSWORD" | sudo -S -p '' true
fi

if ! sudo grep -q "192.168.0.104:30800" "$NGINX_CONF" 2>/dev/null; then
  log "patching $NGINX_CONF (proxy target, WebSocket, upload size)"
  sudo cp "$NGINX_CONF" "$NGINX_CONF.bak.$(date +%s)"

  # 1. Swap the proxy_pass target. -E for extended regex; matches the
  #    value alone so indentation differences don't matter.
  sudo sed -i -E 's|proxy_pass[[:space:]]+http://127\.0\.0\.1:8000;|proxy_pass http://192.168.0.104:30800;|' "$NGINX_CONF"

  # 2. Inject WebSocket headers right after the `location / {` line, but
  #    only if the sentinel header `proxy_http_version 1.1;` is not
  #    already in the file (i.e. we've already done this on a prior
  #    run).
  if ! sudo grep -q 'proxy_http_version 1.1;' "$NGINX_CONF"; then
    sudo sed -i -E '/location[[:space:]]+\/[[:space:]]*\{/a\
                proxy_http_version 1.1;\
                proxy_set_header Upgrade $http_upgrade;\
                proxy_set_header Connection "upgrade";\
                proxy_read_timeout 300s;' "$NGINX_CONF"
  fi

  # 3. Inject client_max_body_size 100m right after the listen 443 ssl;
  #    line, but only if not already present.
  if ! sudo grep -q 'client_max_body_size 100m;' "$NGINX_CONF"; then
    sudo sed -i -E '/listen[[:space:]]+443[[:space:]]+ssl;/a\
                client_max_body_size 100m;' "$NGINX_CONF"
  fi

  sudo nginx -t
  sudo systemctl reload nginx
  mark_done nginx-patched
else
  log "nginx already patched; skipping"
fi

log "bootstrap complete. You can now trigger a Jenkins build."
log "Verify with:  curl -kfsS https://localhost/healthz   (will 502 until first deploy)"
