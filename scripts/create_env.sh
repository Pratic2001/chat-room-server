#!/usr/bin/env bash
# create_env.sh
# -----------------------------------------------------------------------------
# Bootstrap a `.env` file at the repo root for the chat-room-server FastAPI
# app. Writes every variable that the application reads, with placeholders
# and inline documentation describing what each value is for and how to
# generate a strong one.
#
# Usage:
#   ./scripts/create_env.sh              # refuse to clobber an existing .env
#   ./scripts/create_env.sh --force      # back up the existing .env and overwrite
#   ./scripts/create_env.sh --path /tmp/foo/.env   # write to a custom location
#
# After running this script:
#   1. Open the generated .env in your editor.
#   2. Replace every `CHANGE_ME_*` placeholder with a real value.
#   3. Generate the cryptographic keys with the helper commands in the
#      comments (also printed at the end of this script's output).
#   4. Start the server.
# -----------------------------------------------------------------------------

set -euo pipefail

# -----------------------------------------------------------------------------
# Resolve paths — works no matter what CWD the script is invoked from.
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_ENV_FILE="$REPO_ROOT/.env"

# -----------------------------------------------------------------------------
# Tiny logging helpers (kept consistent with change_db_password.sh).
# -----------------------------------------------------------------------------
log()  { printf '\033[1;34m[%s]\033[0m %s\n' "create-env" "$*" >&2; }
warn() { printf '\033[1;33m[%s]\033[0m %s\n' "create-env" "$*" >&2; }
fail() { printf '\033[1;31m[%s]\033[0m %s\n' "create-env" "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Parse arguments.
# -----------------------------------------------------------------------------
FORCE=0
TARGET="$DEFAULT_ENV_FILE"

usage() {
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--force)
            FORCE=1
            shift
            ;;
        -p|--path)
            [[ $# -ge 2 ]] || fail "--path requires an argument."
            TARGET="$2"
            shift 2
            ;;
        -h|--help)
            usage 0
            ;;
        *)
            fail "Unknown argument: $1 (try --help)"
            ;;
    esac
done

# -----------------------------------------------------------------------------
# Refuse to clobber an existing .env unless --force was given.
# -----------------------------------------------------------------------------
if [[ -e "$TARGET" ]]; then
    if [[ "$FORCE" -ne 1 ]]; then
        fail "$TARGET already exists. Re-run with --force to back it up and overwrite, or pass --path to write somewhere else."
    fi
    TS="$(date +%s)"
    BACKUP="$TARGET.bak.$TS"
    cp -p "$TARGET" "$BACKUP"
    warn "Existing $TARGET backed up to $BACKUP"
fi

# Make sure the parent directory exists (handles a custom --path).
TARGET_DIR="$(dirname "$TARGET")"
mkdir -p "$TARGET_DIR"

# -----------------------------------------------------------------------------
# Write the .env template.
#
# Notes on the placeholders below:
#   * MYSQL_PASSWORD             — replace with the password for MYSQL_USER.
#                                  Avoid characters that have meaning in URLs
#                                  ( @ : / ? # [ ] % ) — use
#                                  scripts/change_db_password.sh to rotate.
#   * SECRET_KEY                 — JWT signing key. Generate with:
#                                    python -c "import secrets; print(secrets.token_urlsafe(64))"
#   * ROOM_SECRET_KEY            — Fernet key for room pass-phrase encryption.
#                                  Generate with:
#                                    python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
#   * MAIL_*                     — SMTP outgoing-mail credentials.
# -----------------------------------------------------------------------------
TMP_ENV="$(mktemp "${TARGET}.XXXXXX")"
trap 'rm -f "$TMP_ENV"' EXIT

cat > "$TMP_ENV" <<'ENV_TEMPLATE'
# ============================================================
# Chat Room Server — Environment Configuration
# ============================================================
# IMPORTANT: Replace every `CHANGE_ME_*` placeholder below with
# a real value before running the server. Do NOT commit this
# file to version control (make sure `.env` is in .gitignore).
#
# This file is consumed by `python-dotenv` at application start
# (see app/database.py and app/utils.py). Keys and value
# formats must match what the code expects exactly.
# ============================================================

# --- MySQL Database ---------------------------------------------------------
# Used by app/database.py to build the SQLAlchemy connection URL:
#   mysql+pymysql://MYSQL_USER:MYSQL_PASSWORD@MYSQL_HOST/MYSQL_DB
#
# Tip: avoid passwords containing  @ : / ? # [ ] %  — they get
# misparsed in URLs. Use scripts/change_db_password.sh to rotate
# to a URL-safe random password.
MYSQL_USER=CHANGE_ME_mysql_user
MYSQL_PASSWORD=CHANGE_ME_mysql_password
MYSQL_HOST=localhost
MYSQL_DB=chatroom_db

# --- Redis pub/sub bus ------------------------------------------------------
# Used by app/redis_bus.py to fan WebSocket broadcasts out to every
# app pod. Defaults to localhost for `uvicorn`-style local dev; the
# k8s manifest at k8s/40-app-deployment.yaml overrides this to the
# in-cluster Redis Service via the chatroom-app ConfigMap.
#
# Leave this blank to run in single-pod mode (broadcasts stay
# in-process — fine for development, broken on a multi-replica
# deployment). The app logs a warning at startup if REDIS_URL is
# unset, so it's easy to spot the misconfiguration.
REDIS_URL=redis://localhost:6379/0

# --- JWT Authentication -----------------------------------------------------
# Used by app/utils.py for signing/verifying access tokens.
# Generate a strong key with:
#   python -c "import secrets; print(secrets.token_urlsafe(64))"
#
# ALGORITHM must be one supported by `python-jose`; HS256 is the
# default and matches the rest of the codebase.
# ACCESS_TOKEN_EXPIRE_MINUTES is how long an issued JWT stays valid.
SECRET_KEY=CHANGE_ME_jwt_secret_at_least_64_random_chars
ALGORITHM=HS256
ACCESS_TOKEN_EXPIRE_MINUTES=60

# --- Room pass-phrase encryption (Fernet) -----------------------------------
# Used by app/utils.py to encrypt room secret phrases so they can
# be recovered later for invitation emails. The phrase is
# encrypted (reversibly), not hashed, so the server can include
# the exact phrase in an invite.
#
# Generate a key with:
#   python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
#
# IMPORTANT: changing this key invalidates every existing room
# secret phrase already stored in the database.
ROOM_SECRET_KEY=CHANGE_ME_fernet_key_44_url_safe_base64_chars=

# --- SMTP (outgoing mail for room invites) ----------------------------------
# Used by app/utils.py::send_invite_email when a user clicks
# "Invite" in the web UI.
#
# For local development you can run a debug SMTP sink that
# prints incoming mail instead of actually delivering it:
#   python -m smtpd -n -c DebuggingServer localhost:1025
# then set:
#   MAIL_HOST=localhost
#   MAIL_PORT=1025
#   MAIL_USE_TLS=false
#   MAIL_USER= (leave blank)
#   MAIL_PASSWORD= (leave blank)
#
# MAIL_FROM is the From: header used on outgoing invites. The
# RFC-5322 "Display Name <addr@host>" form is supported; keep
# the quotes around it because the value contains spaces.
MAIL_HOST=smtp.example.com
MAIL_PORT=587
MAIL_USER=CHANGE_ME_smtp_username
MAIL_PASSWORD=CHANGE_ME_smtp_password
MAIL_FROM="Chat Room <no-reply@example.com>"
MAIL_USE_TLS=true

# --- Ollama (AI assistant backend) -----------------------------------------
# Used by app/ai.py when a user mentions @assistant in a room that was
# created with ai_enabled=true. The AI sends the room's last 30 messages
# (text content + filenames for image/file/video) to Ollama and persists
# the response like any other chat message.
#
# OLLAMA_HOST must include scheme (http:// or https://). The runtime
# passes the value through unchanged when a port is already present
# (e.g. http://1.2.3.4:9999); otherwise it appends ":OLLAMA_PORT". For
# local development, run `ollama serve` in another terminal and set:
#   OLLAMA_HOST=http://localhost
#   OLLAMA_PORT=11434
# then `ollama pull llama3.2` (or whichever model you set below) once
# before the first @assistant mention.
#
# OLLAMA_MODEL must be a model you've already pulled. Common choices:
# llama3.2 (small/fast), llama3.1:8b, mistral, qwen2.5, phi3. The app
# silently does nothing if Ollama is unreachable, so it's safe to leave
# these set when the AI feature is unused.
OLLAMA_HOST=http://localhost
OLLAMA_PORT=11434
OLLAMA_MODEL=llama3.2
ENV_TEMPLATE

# -----------------------------------------------------------------------------
# Move into place atomically and tighten permissions (file is a credential).
# -----------------------------------------------------------------------------
mv "$TMP_ENV" "$TARGET"
trap - EXIT  # tmp file no longer exists
chmod 600 "$TARGET" 2>/dev/null || true

# -----------------------------------------------------------------------------
# Summary + next-step hints.
# -----------------------------------------------------------------------------
echo
printf '\033[1;32m============================================================\033[0m\n'
printf '\033[1;32m  .env template written\033[0m\n'
printf '\033[1;32m============================================================\033[0m\n'
printf '  path:        %s\n' "$TARGET"
printf '  permissions: 600 (owner read/write only)\n'
echo
printf 'Next steps:\n'
printf '  1. Open the file and replace every CHANGE_ME_* placeholder.\n'
printf '  2. Generate a JWT signing key:\n'
printf '       python -c "import secrets; print(secrets.token_urlsafe(64))"\n'
printf '     and paste the output as SECRET_KEY.\n'
printf '  3. Generate a Fernet key for room pass-phrase encryption:\n'
printf '       python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"\n'
printf '     and paste the output as ROOM_SECRET_KEY.\n'
printf '  4. Fill in the MySQL and SMTP credentials.\n'
printf '  5. Start the server (e.g. uvicorn app.main:app --reload).\n'
echo
