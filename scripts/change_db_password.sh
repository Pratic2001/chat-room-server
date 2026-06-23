#!/usr/bin/env bash
# change_db_password.sh
# -----------------------------------------------------------------------------
# Rotate the MySQL password used by the chat-room-server FastAPI app and keep
# the project's .env file in sync. Generates a URL-safe random password (no
# @ : / ? # [ ] %) so it cannot re-introduce the bug where @ in a password is
# parsed as the user/host separator in the SQLAlchemy URL.
#
# Usage:
#   ./scripts/change_db_password.sh
#
# You will be prompted for the CURRENT MySQL password of MYSQL_USER@MYSQL_HOST.
# The new password is printed once at the end; copy it then.
# -----------------------------------------------------------------------------

set -euo pipefail

# Resolve repo root from the script's location so the script works from any CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

# Shared URL-safe password generator (also used by build_images.sh so the
# no-@-:-/-?-#-[-]-% invariant lives in one place).
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_random_password.sh"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "change-db" "$*" >&2; }
fail() { printf '\033[1;31m[%s]\033[0m %s\n' "change-db" "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 1. Pre-flight checks
# -----------------------------------------------------------------------------
command -v mysql >/dev/null 2>&1 || fail "mysql client not found in PATH. Install it (e.g. sudo apt install default-mysql-client)."

[[ -f "$ENV_FILE" ]] || fail ".env not found at $ENV_FILE"

# Source only the four MySQL-related lines from .env so we don't accidentally
# execute arbitrary code or pull in SECRET_KEY (which we don't need here).
get_env_var() {
    local key="$1"
    # Match "KEY=...", strip optional surrounding quotes, ignore comments / blanks.
    local val
    val="$(grep -E "^${key}=" "$ENV_FILE" | tail -n1 | cut -d= -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")"
    [[ -n "$val" ]] || fail "Missing $key in $ENV_FILE"
    printf '%s' "$val"
}

MYSQL_USER="$(get_env_var MYSQL_USER)"
MYSQL_HOST="$(get_env_var MYSQL_HOST)"
MYSQL_DB="$(get_env_var MYSQL_DB)"
# MYSQL_PASSWORD is intentionally not loaded here -- we need the CURRENT one
# interactively, in case the stored value is already wrong / stale.

log "Target:  user=$MYSQL_USER  host=$MYSQL_HOST  db=$MYSQL_DB"
log "Repo:    $REPO_ROOT"

NEW_PASSWORD="$(generate_url_safe_password)"

# -----------------------------------------------------------------------------
# 3. Prompt for the CURRENT MySQL password
# -----------------------------------------------------------------------------
echo
printf 'Enter the CURRENT MySQL password for %s@%s: ' "$MYSQL_USER" "$MYSQL_HOST" >&2
read -rs CURRENT_PASSWORD
echo >&2
[[ -n "$CURRENT_PASSWORD" ]] || fail "Empty password supplied."

# -----------------------------------------------------------------------------
# 4. Test the current credentials before touching anything
# -----------------------------------------------------------------------------
log "Verifying current credentials..."
if ! MYSQL_PWD="$CURRENT_PASSWORD" mysql \
        --connect-timeout=10 \
        -u "$MYSQL_USER" -h "$MYSQL_HOST" \
        -e "SELECT 1;" >/dev/null 2>&1; then
    fail "Could not authenticate to MySQL as $MYSQL_USER@$MYSQL_HOST with the supplied current password. Aborting; .env was not modified."
fi
log "Current credentials OK."

# -----------------------------------------------------------------------------
# 5. Apply ALTER USER
# -----------------------------------------------------------------------------
log "Changing password for $MYSQL_USER@$MYSQL_HOST..."
# We build the SQL with carefully-quoted string literals. Single quotes inside
# the password would break the SQL, so we escape them: ' -> ''.
ESC_NEW="${NEW_PASSWORD//\'/\'\'}"
if ! MYSQL_PWD="$CURRENT_PASSWORD" mysql \
        -u "$MYSQL_USER" -h "$MYSQL_HOST" \
        -e "ALTER USER '$MYSQL_USER'@'$MYSQL_HOST' IDENTIFIED BY '$ESC_NEW'; FLUSH PRIVILEGES;"; then
    fail "ALTER USER failed. The database password was NOT changed and .env was NOT modified."
fi
log "ALTER USER applied."

# -----------------------------------------------------------------------------
# 6. Verify the new password works
# -----------------------------------------------------------------------------
log "Verifying new password..."
if ! MYSQL_PWD="$NEW_PASSWORD" mysql \
        --connect-timeout=10 \
        -u "$MYSQL_USER" -h "$MYSQL_HOST" \
        -e "SELECT 1;" >/dev/null 2>&1; then
    # The DB-side change already succeeded; this is just our own sanity check.
    # Don't bail out -- still update .env so the user isn't locked out of the
    # script, but warn loudly.
    printf '\033[1;33m[change-db]\033[0m WARNING: ALTER USER succeeded but the verification SELECT 1 failed.\n' >&2
    printf '\033[1;33m[change-db]\033[0m          This can happen if the user account has additional auth plugins or\n' >&2
    printf '\033[1;33m[change-db]\033[0m          host restrictions. The .env file is being updated anyway.\n' >&2
else
    log "New password verified."
fi

# -----------------------------------------------------------------------------
# 7. Update .env atomically with a backup
# -----------------------------------------------------------------------------
TS="$(date +%s)"
BACKUP_FILE="$ENV_FILE.bak.$TS"
cp -p "$ENV_FILE" "$BACKUP_FILE"
log "Backed up $ENV_FILE -> $BACKUP_FILE"

# Defensive URL-encode for the value we write into .env. The generated password
# already avoids reserved chars, but this protects against future hand-edits.
NEW_PASSWORD_ENCODED="$(url_encode_value "$NEW_PASSWORD")"

TMP_ENV="$(mktemp "${ENV_FILE}.XXXXXX")"
trap 'rm -f "$TMP_ENV"' EXIT

awk -v new_value="$NEW_PASSWORD_ENCODED" '
    BEGIN { replaced = 0 }
    /^MYSQL_PASSWORD=/ { print "MYSQL_PASSWORD=" new_value; replaced = 1; next }
    { print }
    END {
        if (!replaced) print "MYSQL_PASSWORD=" new_value
    }
' "$ENV_FILE" > "$TMP_ENV"

mv "$TMP_ENV" "$ENV_FILE"
trap - EXIT  # tmp file no longer exists

# Tighten permissions: .env contains a credential.
chmod 600 "$ENV_FILE" 2>/dev/null || true

# -----------------------------------------------------------------------------
# 8. Summary
# -----------------------------------------------------------------------------
echo
printf '\033[1;32m============================================================\033[0m\n'
printf '\033[1;32m  MySQL password rotated successfully\033[0m\n'
printf '\033[1;32m============================================================\033[0m\n'
printf '  user:           %s\n' "$MYSQL_USER"
printf '  host:           %s\n' "$MYSQL_HOST"
printf '  db:             %s\n' "$MYSQL_DB"
printf '  .env updated:   %s\n' "$ENV_FILE"
printf '  backup of old:  %s\n' "$BACKUP_FILE"
echo
printf '\033[1;33m=== NEW MYSQL PASSWORD (copy now, not stored) ===\033[0m\n'
printf '%s\n' "$NEW_PASSWORD"
printf '\033[1;33m=== END ===\033[0m\n'
echo
printf 'Restart the FastAPI server for the new .env to take effect.\n'
