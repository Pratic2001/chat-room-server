#!/usr/bin/env bash
# write_runtime_env.sh
# -----------------------------------------------------------------------------
# Write app/.env.runtime without rebuilding the container images.
#
# Why this exists: scripts/deploy_k8s.sh refuses to run without
# app/.env.runtime, because that file holds the three secrets the cluster
# needs at deploy time (MySQL root password, JWT signing key, Fernet key
# for room pass-phrase encryption). Normally scripts/build_images.sh
# creates the file as a side effect of building the images.
#
# But there are legitimate workflows where the images were built
# elsewhere — by CI, by a teammate, on a different machine — and you just
# want to deploy from this checkout. In that case the MySQL image was
# already built with a specific MYSQL_PASSWORD baked into
# /docker-entrypoint-initdb.d/99-grants.sql, and the cluster's MySQL pod
# will reject any other password. This script captures those values so
# the deploy script can write the matching k8s Secret.
#
# Usage:
#   ./scripts/write_runtime_env.sh                 # generate fresh (only
#                                                  # safe if you also rebuild
#                                                  # the MySQL image with
#                                                  # the new password)
#   ./scripts/write_runtime_env.sh --from-stdin   # paste the three values
#                                                  # on stdin (one per line)
#   ./scripts/write_runtime_env.sh --from-file P  # read them from a file
#
# On stdin / --from-file the expected order is:
#   MYSQL_PASSWORD
#   SECRET_KEY
#   ROOM_SECRET_KEY
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_ENV="$REPO_ROOT/app/.env.runtime"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/_random_password.sh"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "env" "$*" >&2; }
fail() { printf '\033[1;31m[%s]\033[0m %s\n' "env" "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Parse args
# -----------------------------------------------------------------------------
FROM_STDIN=0
FROM_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --from-stdin)  FROM_STDIN=1; shift ;;
        --from-file)   [[ $# -ge 2 ]] || fail "--from-file requires a path."
                       FROM_FILE="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) fail "Unknown argument: $1 (try --help)" ;;
    esac
done

# Refuse ambiguous invocations.
if [[ "$FROM_STDIN" -eq 1 && -n "$FROM_FILE" ]]; then
    fail "--from-stdin and --from-file are mutually exclusive."
fi

# -----------------------------------------------------------------------------
# Pre-flight
# -----------------------------------------------------------------------------
command -v python3 >/dev/null 2>&1 || fail "python3 not found in PATH (needed for SECRET_KEY / ROOM_SECRET_KEY generation)."

if [[ -f "$RUNTIME_ENV" ]]; then
    log "WARNING: $RUNTIME_ENV already exists."
    if [[ "$FROM_STDIN" -eq 0 && -z "$FROM_FILE" ]]; then
        log "  Re-run with --from-stdin or --from-file to overwrite; otherwise delete it first."
        log "  Refusing to clobber (the existing values match the existing MySQL image)."
        exit 1
    fi
    log "  Overwriting with the values you supplied (--from-stdin / --from-file)."
fi

# -----------------------------------------------------------------------------
# Acquire the three values
# -----------------------------------------------------------------------------
if [[ "$FROM_STDIN" -eq 1 ]]; then
    log "Reading MYSQL_PASSWORD, SECRET_KEY, ROOM_SECRET_KEY from stdin..."
    # Read exactly three lines, in order. Trailing newline tolerated.
    IFS= read -r MYSQL_PASSWORD  || fail "stdin closed before MYSQL_PASSWORD."
    IFS= read -r SECRET_KEY      || fail "stdin closed before SECRET_KEY."
    IFS= read -r ROOM_SECRET_KEY || fail "stdin closed before ROOM_SECRET_KEY."
elif [[ -n "$FROM_FILE" ]]; then
    [[ -f "$FROM_FILE" ]] || fail "--from-file: $FROM_FILE not found."
    log "Reading MYSQL_PASSWORD, SECRET_KEY, ROOM_SECRET_KEY from $FROM_FILE..."
    {
        IFS= read -r MYSQL_PASSWORD  || fail "$FROM_FILE: missing MYSQL_PASSWORD on line 1."
        IFS= read -r SECRET_KEY      || fail "$FROM_FILE: missing SECRET_KEY on line 2."
        IFS= read -r ROOM_SECRET_KEY || fail "$FROM_FILE: missing ROOM_SECRET_KEY on line 3."
    } < "$FROM_FILE"
else
    log "Generating fresh credentials..."
    log "  Use this only if you ALSO plan to rebuild the MySQL image with these"
    log "  same values (delete the existing image, then run build_images.sh with"
    log "  the file in place so the build-arg flow bakes MYSQL_PASSWORD in)."
    log "  To capture values from an EXISTING image, use --from-stdin."
    echo
    if [[ -t 0 ]]; then
        printf 'Continue? [y/N] ' >&2
        IFS= read -r ans
        [[ "$ans" == "y" || "$ans" == "Y" ]] || { log "Aborted."; exit 1; }
    fi
    eval "$(load_or_generate_runtime_secrets "")"
fi

# Validate: refuse to write obvious junk.
[[ -n "${MYSQL_PASSWORD:-}"  ]] || fail "MYSQL_PASSWORD is empty."
[[ -n "${SECRET_KEY:-}"      ]] || fail "SECRET_KEY is empty."
[[ -n "${ROOM_SECRET_KEY:-}" ]] || fail "ROOM_SECRET_KEY is empty."
# Fernet keys are exactly 44 url-safe base64 chars + '=' padding.
if ! [[ "$ROOM_SECRET_KEY" =~ ^[A-Za-z0-9_-]{43}=$ ]]; then
    fail "ROOM_SECRET_KEY doesn't look like a Fernet key (expect 44 url-safe base64 chars ending in '='). Got: ${ROOM_SECRET_KEY:0:8}..."
fi
# JWT secret should be long enough to be useful.
if [[ "${#SECRET_KEY}" -lt 32 ]]; then
    fail "SECRET_KEY is suspiciously short (${#SECRET_KEY} chars). HS256 wants at least 32."
fi

# -----------------------------------------------------------------------------
# Write
# -----------------------------------------------------------------------------
write_runtime_env_file "$RUNTIME_ENV" "scripts/write_runtime_env.sh"
log "Wrote $RUNTIME_ENV (chmod 600)"

echo
printf '\033[1;32m============================================================\033[0m\n'
printf '\033[1;32m  app/.env.runtime is ready\033[0m\n'
printf '\033[1;32m============================================================\033[0m\n'
printf 'Next step:\n'
printf '  ./scripts/deploy_k8s.sh\n'
echo
printf 'If you built the images in a registry, the deployments already\n'
printf 'reference your registry tags — no extra work is needed.\n'
printf 'If you built them locally, load them into the cluster first:\n'
printf '  kind load docker-image chat-room-server:latest chatroom-mysql:latest\n'
printf '  # or k3d image import / minikube image load — see the runbook.\n'
