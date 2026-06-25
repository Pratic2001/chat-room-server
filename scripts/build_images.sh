#!/usr/bin/env bash
# build_images.sh
# -----------------------------------------------------------------------------
# Build the chat-room-server and chatroom-mysql container images from this
# repository. The output is two `latest`-tagged images in the local Docker
# daemon, with no host-specific paths or secrets baked in.
#
# What this script does:
#   1. Refuses to run if `docker` is not on PATH.
#   2. Generates a random URL-safe MySQL root password (sourcing
#      _random_password.sh so the no-@-:-/-?-#-[-]-% invariant lives in
#      one place).
#   3. Generates JWT_SECRET_KEY and ROOM_SECRET_KEY (Fernet) on first run
#      and reuses them on subsequent runs.
#   4. Writes those values into app/.env.runtime (gitignored) — the deploy
#      script reads this file to populate k8s Secrets.
#   5. Builds chatroom-mysql:latest with the password baked into
#      99-grants.sql via a build-arg.
#   6. Builds chat-room-server:latest — the app reads config from env at
#      runtime, so no .env is baked in.
#
# Re-running is safe: it re-uses app/.env.runtime if it already exists,
# so the MySQL image stays in sync with the app secret. To rotate the
# MySQL password, delete app/.env.runtime first.
#
# Usage:
#   ./scripts/build_images.sh
#   ./scripts/build_images.sh --no-cache    # pass --no-cache to docker build
#   ./scripts/build_images.sh --rebuild     # force a fresh MYSQL_PASSWORD
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/_random_password.sh"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "build" "$*" >&2; }
warn() { printf '\033[1;33m[%s]\033[0m %s\n' "build" "$*" >&2; }
fail() { printf '\033[1;31m[%s]\033[0m %s\n' "build" "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Parse args
# -----------------------------------------------------------------------------
NO_CACHE=0
REBUILD=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-cache) NO_CACHE=1; shift ;;
        --rebuild)  REBUILD=1; shift ;;
        -h|--help)
            sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) fail "Unknown argument: $1 (try --help)" ;;
    esac
done

# -----------------------------------------------------------------------------
# Pre-flight
# -----------------------------------------------------------------------------
command -v docker >/dev/null 2>&1 || fail "docker not found in PATH."

# Sanity: make sure the repo layout is what we expect.
[[ -f "$REPO_ROOT/requirements.txt" ]]        || fail "requirements.txt not found at repo root."
[[ -d "$REPO_ROOT/app" ]]                     || fail "app/ not found at repo root."
[[ -f "$REPO_ROOT/mysql/Dockerfile" ]]        || fail "mysql/Dockerfile not found."
[[ -f "$REPO_ROOT/mysql/init/01-schema.sql" ]]|| fail "mysql/init/01-schema.sql not found."
[[ -f "$REPO_ROOT/mysql/init/99-grants.sql.template" ]] \
    || fail "mysql/init/99-grants.sql.template not found."

RUNTIME_ENV="$REPO_ROOT/app/.env.runtime"
DOCKER_BUILD_ARGS=()
if [[ "$NO_CACHE" -eq 1 ]]; then
    DOCKER_BUILD_ARGS+=(--no-cache)
fi

# -----------------------------------------------------------------------------
# Generate or reuse credentials
# -----------------------------------------------------------------------------
# On a fresh clone, app/.env.runtime doesn't exist: generate everything.
# On a re-run, reuse the values so the MySQL image stays in sync with the
# k8s Secret the deploy script will create. --rebuild forces regeneration
# of the MySQL password (use this if you suspect the secret has leaked).
if [[ -f "$RUNTIME_ENV" && "$REBUILD" -ne 1 ]]; then
    log "Reusing existing $RUNTIME_ENV (pass --rebuild to regenerate the MySQL password)"
    eval "$(load_or_generate_runtime_secrets "$RUNTIME_ENV")"
else
    log "Generating fresh credentials..."
    eval "$(load_or_generate_runtime_secrets "")"
fi

# URL-encode for the .env file so future hand-edits can't accidentally
# introduce a URL-special char. The MYSQL_PASSWORD value gets read verbatim
# by the Python app (no URL decoding happens there) — see app/database.py,
# which builds the URL from the env vars directly.
#
# MAIL_* values (loaded by load_or_generate_runtime_secrets above) are
# in scope here. If we're not in --rebuild mode, the values from the
# existing app/.env.runtime are in env; we prompt only the fields the
# user might want to change. On --rebuild or first run, we prompt for
# every field (or accept the default by hitting Enter).
prompt_default() {
    # $1 = prompt, $2 = default, $3 = secret flag (1 = read -s)
    local prompt="$1" default="$2" secret="${3:-0}"
    local ans
    if [[ "$secret" -eq 1 ]]; then
        # Read silently. Empty input = accept the default (which itself
        # may be empty for MAIL_PASSWORD).
        printf '%s [%s]: ' "$prompt" "$default" >&2
        IFS= read -rs ans
        printf '\n' >&2
    else
        printf '%s [%s]: ' "$prompt" "$default" >&2
        IFS= read -r ans
    fi
    printf '%s' "${ans:-$default}"
}

log "SMTP configuration (leave blank to disable invite emails)..."
# MYSQL_READ_HOST is prompted at the end of this block (after MAIL_USE_TLS)
# so the topology decision — single-node (leave empty) vs multi-node
# (set to mysql-replica) — can be made without re-running the SMTP
# prompts.
MAIL_HOST="$(prompt_default '  MAIL_HOST' "$MAIL_HOST")"
# MAIL_PORT: must be an integer 1-65535 or blank (→ 587). Re-prompt on
# garbage input rather than failing the whole build.
while :; do
    MAIL_PORT_INPUT="$(prompt_default '  MAIL_PORT' "$MAIL_PORT")"
    if [[ -z "$MAIL_PORT_INPUT" ]]; then
        MAIL_PORT="587"
        break
    fi
    if [[ "$MAIL_PORT_INPUT" =~ ^[0-9]+$ ]] && (( MAIL_PORT_INPUT >= 1 && MAIL_PORT_INPUT <= 65535 )); then
        MAIL_PORT="$MAIL_PORT_INPUT"
        break
    fi
    warn "MAIL_PORT must be an integer 1-65535 (or blank for 587); got '$MAIL_PORT_INPUT'."
done
MAIL_USER="$(prompt_default '  MAIL_USER' "$MAIL_USER")"
MAIL_PASSWORD="$(prompt_default '  MAIL_PASSWORD (input hidden)' "$MAIL_PASSWORD" 1)"
# MAIL_FROM: don't allow blank — the app needs a sender header.
while :; do
    MAIL_FROM_INPUT="$(prompt_default '  MAIL_FROM' "$MAIL_FROM")"
    if [[ -n "$MAIL_FROM_INPUT" ]]; then
        MAIL_FROM="$MAIL_FROM_INPUT"
        break
    fi
    warn "MAIL_FROM cannot be blank."
done
# MAIL_USE_TLS: accept y/yes/1/true (→ true), n/no/0/false (→ false),
# blank (→ default).
while :; do
    MAIL_USE_TLS_INPUT="$(prompt_default '  MAIL_USE_TLS (y/n)' "$MAIL_USE_TLS")"
    case "${MAIL_USE_TLS_INPUT,,}" in
        y|yes|1|true)  MAIL_USE_TLS="true";  break ;;
        n|no|0|false)  MAIL_USE_TLS="false"; break ;;
        "")            MAIL_USE_TLS="$MAIL_USE_TLS"; break ;;  # default kept
        *) warn "MAIL_USE_TLS must be y/n/yes/no/true/false (or blank); got '$MAIL_USE_TLS_INPUT'." ;;
    esac
done

# MYSQL_READ_HOST: read-only endpoints (GET /messages, GET /rooms/my)
# connect here. On 1-node clusters (kind/k3d/minikube) keep this empty
# so app/database.py falls back to MYSQL_HOST and reads land on the
# master. On multi-node clusters set it to "mysql-replica" (matches
# k8s/24-mysql-replica-service.yaml) so reads land on the replica.
#
# Two-step prompt: first ask whether to keep it empty (the 1-node
# default). If the user says yes, MYSQL_READ_HOST stays empty. If no,
# prompt for the actual host. This is structured as y/n rather than a
# free-form read so it's obvious from the prompt itself what "empty"
# means in this context — a blank value with a free-form prompt is
# ambiguous between "I want to keep it empty" and "I just hit enter by
# accident".
while :; do
    KEEP_READ_HOST_EMPTY_INPUT="$(prompt_default '  Keep MYSQL_READ_HOST empty (1-node / single-master)?' "$([[ -z "$MYSQL_READ_HOST" ]] && echo y || echo n)")"
    case "${KEEP_READ_HOST_EMPTY_INPUT,,}" in
        y|yes|1|true)
            MYSQL_READ_HOST=""
            break
            ;;
        n|no|0|false)
            # Multi-node path: ask for the actual read host. The
            # default mirrors the in-cluster chatroom-mysql-replica
            # Service (k8s/24-mysql-replica-service.yaml) so a fresh
            # build that wants replicas picks the right name. Host
            # names are typically short hostnames (no URL-special
            # chars), so we accept any non-empty value verbatim.
            while :; do
                MYSQL_READ_HOST_INPUT="$(prompt_default '  MYSQL_READ_HOST' "${MYSQL_READ_HOST:-mysql-replica}")"
                if [[ -n "$MYSQL_READ_HOST_INPUT" ]]; then
                    MYSQL_READ_HOST="$MYSQL_READ_HOST_INPUT"
                    break
                fi
                warn "MYSQL_READ_HOST cannot be blank (answer 'y' to the previous question if you want it empty)."
            done
            break
            ;;
        "") warn "Please answer y (keep empty) or n (set a value)." ;;
        *)  warn "Please answer y (keep empty) or n (set a value); got '$KEEP_READ_HOST_EMPTY_INPUT'." ;;
    esac
done

write_runtime_env_file "$RUNTIME_ENV" "scripts/build_images.sh"
log "Wrote $RUNTIME_ENV (chmod 600)"

# -----------------------------------------------------------------------------
# Render the deployable k8s Secrets + ConfigMap manifest
# -----------------------------------------------------------------------------
# `k8s/secrets.runtime.yaml` is gitignored + dockerignored, so this is
# where the real values land. After this point, `kubectl apply -f k8s/`
# alone (no separate deploy step) is enough to reconcile the cluster.
# The committed templates under k8s/ (10-mysql-secret.yaml, 31-app-secret.yaml,
# 30-app-config.yaml) hold placeholders and are NOT valid manifests.
K8S_SECRETS_RUNTIME="$REPO_ROOT/k8s/secrets.runtime.yaml"
render_k8s_secrets "$K8S_SECRETS_RUNTIME" "scripts/build_images.sh"
log "Wrote $K8S_SECRETS_RUNTIME (chmod 600)"

# -----------------------------------------------------------------------------
# Build images
# -----------------------------------------------------------------------------
APP_IMAGE="chat-room-server:latest"
MYSQL_IMAGE="chatroom-mysql:latest"

log "Building $MYSQL_IMAGE (with baked root password + replication user)..."
# Build context is the mysql/ directory (not the repo root), so the
# Dockerfile's `COPY init/...` lines resolve correctly. We can't use the
# repo root here because .dockerignore strips the mysql/ tree out of the
# context — the same ignore rules that keep the app image lean would
# otherwise remove the SQL files this image needs.
#
# Two build-args are baked into the image:
#   MYSQL_ROOT_PASSWORD — root user's password (used by the app and by
#                         replication-username SQL on replicas).
#   REPLICATION_PASSWORD — credential for the 'repl'@'%' user, baked
#                          into 02-replication-user.sql.template. Used
#                          by replicas to authenticate CHANGE MASTER TO
#                          against the master.
docker build \
    "${DOCKER_BUILD_ARGS[@]}" \
    --build-arg "MYSQL_ROOT_PASSWORD=${MYSQL_PASSWORD}" \
    --build-arg "REPLICATION_PASSWORD=${REPLICATION_PASSWORD}" \
    -f "$REPO_ROOT/mysql/Dockerfile" \
    -t "$MYSQL_IMAGE" \
    "$REPO_ROOT/mysql"

log "Building $APP_IMAGE..."
docker build \
    "${DOCKER_BUILD_ARGS[@]}" \
    -f "$REPO_ROOT/Dockerfile" \
    -t "$APP_IMAGE" \
    "$REPO_ROOT"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo
printf '\033[1;32m============================================================\033[0m\n'
printf '\033[1;32m  Images built\033[0m\n'
printf '\033[1;32m============================================================\033[0m\n'
printf '  %s\n' "$APP_IMAGE"
printf '  %s\n' "$MYSQL_IMAGE"
echo
printf 'Next step:\n'
printf '  ./scripts/deploy_k8s.sh\n'
echo
printf 'Both images are tagged :latest and use imagePullPolicy: Never, so\n'
printf 'they will run on any k8s cluster that can reach this Docker daemon\n'
printf '(e.g., a kind / k3d cluster on the same host).\n'
