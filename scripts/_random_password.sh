#!/usr/bin/env bash
# _random_password.sh
# -----------------------------------------------------------------------------
# Generate a URL-safe random password suitable for embedding in a MySQL
# connection URL or a k8s Secret.
#
# Why this exists: SQLAlchemy URL syntax treats `@ : / ? # [ ] %` specially
# inside the userinfo component, so a password containing any of those chars
# is silently misparsed. Stripping them at generation time keeps the value
# usable as-is in `mysql+pymysql://user:password@host/db`.
#
# Sourced (not executed) by:
#   - scripts/change_db_password.sh   (rotates a real MySQL user's password)
#   - scripts/build_images.sh         (generates a fresh password for the
#                                      containerized MySQL root user)
#
# Usage (from another script):
#   source "$(dirname "${BASH_SOURCE[0]}")/_random_password.sh"
#   new_pw="$(generate_url_safe_password)"
# -----------------------------------------------------------------------------

# Print a random URL-safe password to stdout.
#
# Strategy: 32 bytes from /dev/urandom, base64-encoded, then every URL-special
# character is stripped. Loop until non-empty AND at least 16 chars long
# (vanishingly unlikely to loop more than once).
generate_url_safe_password() {
    local candidate
    while :; do
        candidate="$(head -c 32 /dev/urandom | base64 | tr -d '=+/@\?#[]:%' | tr -d '\n')"
        [[ -n "$candidate" ]] || continue
        [[ ${#candidate} -ge 16 ]] || continue
        printf '%s' "$candidate"
        return
    done
}

# URL-encode a string for safe inclusion in a .env file or k8s Secret value.
# Defensive — generated passwords already avoid these characters, but this
# keeps callers from accidentally injecting specials via shell expansion.
url_encode_value() {
    local s="$1"
    s="${s//\%/%25}"
    s="${s//@/%40}"
    s="${s//:/%3A}"
    s="${s//\//%2F}"
    s="${s//\?/%3F}"
    s="${s//#/%23}"
    s="${s//\[/%5B}"
    s="${s//\]/%5D}"
    printf '%s' "$s"
}