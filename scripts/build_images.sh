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
    # Source it in a subshell so the values land in MYSQL_PASSWORD, etc.
    # shellcheck disable=SC1090
    (
        set -a
        # shellcheck disable=SC1090
        source "$RUNTIME_ENV"
        set +a
        : "${MYSQL_PASSWORD:?MYSQL_PASSWORD missing from $RUNTIME_ENV}"
        : "${SECRET_KEY:?SECRET_KEY missing from $RUNTIME_ENV}"
        : "${ROOM_SECRET_KEY:?ROOM_SECRET_KEY missing from $RUNTIME_ENV}"
        printf '%s\n' "$MYSQL_PASSWORD"  > /tmp/_crs_mysql_pw
        printf '%s\n' "$SECRET_KEY"      > /tmp/_crs_jwt
        printf '%s\n' "$ROOM_SECRET_KEY" > /tmp/_crs_fernet
    )
    MYSQL_PASSWORD="$(cat /tmp/_crs_mysql_pw)";  rm -f /tmp/_crs_mysql_pw
    SECRET_KEY="$(cat /tmp/_crs_jwt)";           rm -f /tmp/_crs_jwt
    ROOM_SECRET_KEY="$(cat /tmp/_crs_fernet)";   rm -f /tmp/_crs_fernet
else
    log "Generating fresh credentials..."
    MYSQL_PASSWORD="$(generate_url_safe_password)"
    SECRET_KEY="$(python3 -c 'import secrets; print(secrets.token_urlsafe(64))')"
    ROOM_SECRET_KEY="$(python3 -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())')"
fi

# URL-encode for the .env file so future hand-edits can't accidentally
# introduce a URL-special char. The MYSQL_PASSWORD value gets read verbatim
# by the Python app (no URL decoding happens there) — see app/database.py,
# which builds the URL from the env vars directly.
MYSQL_PASSWORD_ENC="$(url_encode_value "$MYSQL_PASSWORD")"
SECRET_KEY_ENC="$(url_encode_value "$SECRET_KEY")"
ROOM_SECRET_KEY_ENC="$(url_encode_value "$ROOM_SECRET_KEY")"

# Write app/.env.runtime atomically with tight permissions.
TMP_ENV="$(mktemp "${RUNTIME_ENV}.XXXXXX")"
trap 'rm -f "$TMP_ENV"' EXIT
cat > "$TMP_ENV" <<EOF
# Generated by scripts/build_images.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# DO NOT COMMIT. DO NOT EDIT BY HAND unless you also delete the chatroom-mysql
# image and rebuild it (the build-arg flow bakes this password into
# /docker-entrypoint-initdb.d/99-grants.sql in the MySQL image).
#
# Consumed by:
#   - scripts/deploy_k8s.sh (creates the chatroom-mysql and chatroom-app k8s
#     Secrets from these values)
#
MYSQL_USER=root
MYSQL_PASSWORD=${MYSQL_PASSWORD_ENC}
MYSQL_HOST=mysql
MYSQL_DB=chatroom_db
SECRET_KEY=${SECRET_KEY_ENC}
ALGORITHM=HS256
ACCESS_TOKEN_EXPIRE_MINUTES=60
ROOM_SECRET_KEY=${ROOM_SECRET_KEY_ENC}
EOF
mv "$TMP_ENV" "$RUNTIME_ENV"
trap - EXIT
chmod 600 "$RUNTIME_ENV" 2>/dev/null || true
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
