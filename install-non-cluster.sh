#!/usr/bin/env bash
# install-non-cluster.sh
# -----------------------------------------------------------------------------
# One-shot installer that brings the chat-room stack up as plain Docker
# containers — no Kubernetes involved. Good for a single VM, a laptop, or
# anywhere you don't want a cluster.
#
# What it does:
#   1. Pulls the repo at a released version (unless run from a checkout).
#   2. Runs scripts/build_images.sh — this builds chat-room-server + the
#      chatroom-mysql image (baking a fresh MySQL root password), generates
#      the JWT/Fernet keys, writes app/.env.runtime, and prompts you for
#      your SMTP + Ollama details.
#   3. Brings up MySQL, Redis, and the app with docker compose (the
#      docker-compose.yml in this repo). The app container reads its config
#      from app/.env.runtime; compose points MySQL/Redis hostnames at the
#      containers.
#
# The result is a running stack on http://localhost:8000 with the frontend
# at /, the API under /auth /rooms /messages /ws, and /healthz.
#
# Usage:
#   ./install-non-cluster.sh [--version REF] [--repo URL] [--no-pull]
#                            [--down] [-h]
#
# Flags:
#   --version REF   git ref/tag to install when cloning (default: the
#                   release tag baked into this script, or main).
#   --repo URL      repository to clone when not run from a checkout.
#   --no-pull       assume this checkout is the repo (run from repo root).
#   --down          docker compose down (stop the stack) instead of install.
#   -h, --help      this help.
#
# Prerequisites: bash, git, docker, and docker compose (v2 plugin or the
# docker-compose v1 binary).
# -----------------------------------------------------------------------------

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/Pratic2001/chat-room-server.git}"
REPO_REF="${REPO_REF:-main}"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "install-non-cluster" "$*" >&2; }
warn() { printf '\033[1;33m[%s]\033[0m %s\n' "install-non-cluster" "$*" >&2; }
fail() { printf '\033[1;31m[%s]\033[0m %s\n' "install-non-cluster" "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Parse args
# -----------------------------------------------------------------------------
VERSION="$REPO_REF"
NO_PULL=0
DOWN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="${2:?--version requires a value}"; shift 2 ;;
        --repo)    REPO_URL="${2:?--repo requires a value}"; shift 2 ;;
        --no-pull) NO_PULL=1; shift ;;
        --down)    DOWN=1; shift ;;
        -h|--help)
            sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) fail "Unknown argument: $1 (try --help)" ;;
    esac
done

# -----------------------------------------------------------------------------
# Resolve working dir (this checkout, or a clone at VERSION)
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

in_checkout() {
    [[ -f "$SCRIPT_DIR/scripts/build_images.sh" && -f "$SCRIPT_DIR/docker-compose.yml" ]]
}

if [[ "$NO_PULL" -eq 1 ]]; then
    REPO_DIR="$SCRIPT_DIR"
elif in_checkout && [[ -f "$SCRIPT_DIR/.git/HEAD" ]]; then
    REPO_DIR="$SCRIPT_DIR"
    log "Running from a git checkout ($REPO_DIR)."
    if [[ "$VERSION" != "main" && "$VERSION" != "$REPO_REF" ]]; then
        log "Checking out requested version $VERSION ..."
        git -C "$REPO_DIR" fetch --tags --quiet || true
        git -C "$REPO_DIR" checkout "$VERSION" --quiet
    fi
else
    TMP_CLONE="$(mktemp -d)"
    trap 'rm -rf "$TMP_CLONE"' EXIT
    log "Cloning $REPO_URL (ref: $VERSION) into $TMP_CLONE ..."
    git clone --quiet --depth 1 --branch "$VERSION" "$REPO_URL" "$TMP_CLONE" \
        || fail "git clone of $REPO_URL@$VERSION failed. Check the URL/version or pass --repo."
    REPO_DIR="$TMP_CLONE"
fi
cd "$REPO_DIR"

# -----------------------------------------------------------------------------
# Pre-flight
# -----------------------------------------------------------------------------
command -v git    >/dev/null 2>&1 || fail "git not found in PATH."
command -v docker >/dev/null 2>&1 || fail "docker not found in PATH."
if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
else
    fail "Neither 'docker compose' nor 'docker-compose' is available."
fi

# -----------------------------------------------------------------------------
# --down: stop the stack
# -----------------------------------------------------------------------------
if [[ "$DOWN" -eq 1 ]]; then
    log "Stopping the stack ..."
    "${COMPOSE_CMD[@]}" -f docker-compose.yml down
    log "Done. Volumes are preserved (mysql-data, redis-data); use"
    log "  docker compose rm -f && docker volume rm chatroom_mysql-data chatroom_redis-data"
    log "to wipe the data if you want a truly fresh start."
    exit 0
fi

# -----------------------------------------------------------------------------
# Install
# -----------------------------------------------------------------------------
log "== Building images + generating credentials (this prompts for SMTP + Ollama) =="
./scripts/build_images.sh

# The MySQL image baked MYSQL_PASSWORD (the same value is in
# app/.env.runtime). Compose needs it as MYSQL_ROOT_PASSWORD so the entrypoint
# provisions root@'%' to match before 99-grants re-pins it. Source the runtime
# env and re-export the two MySQL values.
set -a
# shellcheck disable=SC1090
source app/.env.runtime
set +a
export MYSQL_ROOT_PASSWORD="${MYSQL_PASSWORD}"
export REPLICATION_PASSWORD
# Non-cluster: single Redis, no Sentinel, no read replicas.
export REDIS_SENTINELS=""
export MYSQL_READ_HOST=""

# build_images.sh defaults OLLAMA_HOST to http://ollama (the in-cluster k8s
# Service name). That name doesn't resolve in plain Docker, so warn loudly
# when the user kept the default and the AI assistant will silently no-op.
if [[ "${OLLAMA_HOST:-}" == "http://ollama" ]]; then
    warn "OLLAMA_HOST is the k8s in-cluster default 'http://ollama', which does not"
    warn "resolve in Docker. Set it in app/.env.runtime to a reachable address"
    warn "(e.g. http://host.docker.internal:11434 or http://<your-ollama-host>:11434)"
    warn "then re-run this script, or the AI assistant will never respond."
fi

log "Bringing up MySQL + Redis + app with compose ..."
"${COMPOSE_CMD[@]}" -f docker-compose.yml up -d

echo
printf '\033[1;32m============================================================\033[0m\n'
printf '\033[1;32m  Chat room server is up\033[0m\n'
printf '\033[1;32m============================================================\033[0m\n'
printf '  Frontend:   http://localhost:8000/\n'
printf '  Health:     http://localhost:8000/healthz\n'
printf '  Logs:       %s -f docker-compose.yml logs -f app\n' "${COMPOSE_CMD[*]}"
printf '  Stop:       ./install-non-cluster.sh --down\n'
echo
printf '  SMTP / Ollama values were captured by build_images.sh into\n'
printf '  app/.env.runtime — edit that file and re-run this script to change them.\n'
