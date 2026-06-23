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
write_runtime_env_file "$RUNTIME_ENV" "scripts/build_images.sh"
log "Wrote $RUNTIME_ENV (chmod 600)"

# -----------------------------------------------------------------------------
# Build images
# -----------------------------------------------------------------------------
APP_IMAGE="chat-room-server:latest"
MYSQL_IMAGE="chatroom-mysql:latest"

log "Building $MYSQL_IMAGE (with baked root password)..."
# Build context is the mysql/ directory (not the repo root), so the
# Dockerfile's `COPY init/...` lines resolve correctly. We can't use the
# repo root here because .dockerignore strips the mysql/ tree out of the
# context — the same ignore rules that keep the app image lean would
# otherwise remove the SQL files this image needs.
docker build \
    "${DOCKER_BUILD_ARGS[@]}" \
    --build-arg "MYSQL_ROOT_PASSWORD=${MYSQL_PASSWORD}" \
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
