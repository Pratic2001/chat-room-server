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

# -----------------------------------------------------------------------------
# Runtime credentials shared by build_images.sh and write_runtime_env.sh
# -----------------------------------------------------------------------------
# These three values are the ones the cluster needs at deploy time:
#   MYSQL_PASSWORD   - pinned into the MySQL image's 99-grants.sql at build
#                      time; the app and the MySQL pod must agree.
#   SECRET_KEY       - JWT signing key. Lives in the chatroom-app Secret.
#   ROOM_SECRET_KEY  - Fernet key for room pass-phrase encryption. Same.
#
# build_images.sh generates them, bakes the MySQL password into the image,
# and writes the rest into app/.env.runtime. write_runtime_env.sh is the
# "images were built elsewhere (CI / a teammate / an earlier box); I just
# need to deploy" path: it requires the operator to supply the values that
# the existing MySQL image was built with.

# Print MYSQL_PASSWORD, SECRET_KEY, ROOM_SECRET_KEY on stdout, space-
# separated, after either reusing the values in $1 (the path to an
# existing app/.env.runtime) or generating fresh ones.
#
# Usage:
#   eval "$(load_or_generate_runtime_secrets "$RUNTIME_ENV")"   # reuse
#   eval "$(load_or_generate_runtime_secrets "")"                # generate
#
# Output (shell-eval-friendly):
#   MYSQL_PASSWORD='...'
#   SECRET_KEY='...'
#   ROOM_SECRET_KEY='...'
load_or_generate_runtime_secrets() {
    local existing_env="$1"
    local mysql_pw jwt fernet
    # MAIL_* values: if the existing file has them, reuse; otherwise leave
    # blank (the caller — build_images.sh — will then prompt for them).
    # We do NOT generate defaults here; the build-time prompts are the
    # right place to collect SMTP credentials, since they can be blank
    # (disabled) or supplied by a human who knows the relay.
    local mail_host mail_port mail_user mail_password mail_from mail_use_tls

    if [[ -n "$existing_env" && -f "$existing_env" ]]; then
        # Reuse — exact same values the previous build/deploy used.
        (
            set -a
            # shellcheck disable=SC1090
            source "$existing_env"
            set +a
            : "${MYSQL_PASSWORD:?MYSQL_PASSWORD missing from $existing_env}"
            : "${SECRET_KEY:?SECRET_KEY missing from $existing_env}"
            : "${ROOM_SECRET_KEY:?ROOM_SECRET_KEY missing from $existing_env}"
            printf '%s\n' "$MYSQL_PASSWORD"  > /tmp/_crs_mysql_pw
            printf '%s\n' "$SECRET_KEY"      > /tmp/_crs_jwt
            printf '%s\n' "$ROOM_SECRET_KEY" > /tmp/_crs_fernet
            # MAIL_* may be missing from older .env.runtime files; in that
            # case the build script will re-prompt and write fresh values.
            # We use ${VAR-} so unset is treated as empty.
            printf '%s\n' "${MYSQL_PORT-3306}"   > /tmp/_crs_mysql_port
            printf '%s\n' "${MAIL_HOST-}"        > /tmp/_crs_mail_host
            printf '%s\n' "${MAIL_PORT-587}"     > /tmp/_crs_mail_port
            printf '%s\n' "${MAIL_USER-}"        > /tmp/_crs_mail_user
            printf '%s\n' "${MAIL_PASSWORD-}"    > /tmp/_crs_mail_password
            printf '%s\n' "${MAIL_FROM-Chat Room <no-reply@example.com>}" > /tmp/_crs_mail_from
            printf '%s\n' "${MAIL_USE_TLS-true}" > /tmp/_crs_mail_use_tls
        )
        mysql_pw="$(cat /tmp/_crs_mysql_pw)";          rm -f /tmp/_crs_mysql_pw
        jwt="$(cat /tmp/_crs_jwt)";                    rm -f /tmp/_crs_jwt
        fernet="$(cat /tmp/_crs_fernet)";              rm -f /tmp/_crs_fernet
        mysql_port="$(cat /tmp/_crs_mysql_port)";      rm -f /tmp/_crs_mysql_port
        mail_host="$(cat /tmp/_crs_mail_host)";        rm -f /tmp/_crs_mail_host
        mail_port="$(cat /tmp/_crs_mail_port)";        rm -f /tmp/_crs_mail_port
        mail_user="$(cat /tmp/_crs_mail_user)";        rm -f /tmp/_crs_mail_user
        mail_password="$(cat /tmp/_crs_mail_password)"; rm -f /tmp/_crs_mail_password
        mail_from="$(cat /tmp/_crs_mail_from)";        rm -f /tmp/_crs_mail_from
        mail_use_tls="$(cat /tmp/_crs_mail_use_tls)";  rm -f /tmp/_crs_mail_use_tls
    else
        # Generate. Same algorithms as change_db_password.sh.
        mysql_pw="$(generate_url_safe_password)"
        jwt="$(python3 -c 'import secrets; print(secrets.token_urlsafe(64))')"
        fernet="$(python3 -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())')"
        # MAIL_* defaults for first-time use — the build script will
        # prompt the user, who can accept the defaults by hitting Enter.
        mysql_port="3306"
        mail_host=""
        mail_port="587"
        mail_user=""
        mail_password=""
        mail_from="Chat Room <no-reply@example.com>"
        mail_use_tls="true"
    fi

    printf "MYSQL_PASSWORD=%q\n"   "$mysql_pw"
    printf "SECRET_KEY=%q\n"       "$jwt"
    printf "ROOM_SECRET_KEY=%q\n"  "$fernet"
    printf "MYSQL_PORT=%q\n"       "$mysql_port"
    printf "MAIL_HOST=%q\n"        "$mail_host"
    printf "MAIL_PORT=%q\n"        "$mail_port"
    printf "MAIL_USER=%q\n"        "$mail_user"
    printf "MAIL_PASSWORD=%q\n"    "$mail_password"
    printf "MAIL_FROM=%q\n"        "$mail_from"
    printf "MAIL_USE_TLS=%q\n"     "$mail_use_tls"
}

# Atomically write app/.env.runtime with the three secrets + the rest of
# the chat-room-server runtime config. Caller supplies the path and the
# three secret values via env (MYSQL_PASSWORD, SECRET_KEY, ROOM_SECRET_KEY).
# MAIL_* values are also read from env (see below) — the function does
# NOT validate them as required, since "blank" is a valid value (e.g.
# MAIL_HOST="" disables invite emails, MAIL_PASSWORD="" is fine for
# relays that don't authenticate).
#
# The header comment is updated to reflect who generated the file.
write_runtime_env_file() {
    local target_path="$1"
    local generator_label="$2"   # e.g. "scripts/build_images.sh" or "scripts/write_runtime_env.sh"

    : "${MYSQL_PASSWORD:?MYSQL_PASSWORD unset (call load_or_generate_runtime_secrets first)}"
    : "${SECRET_KEY:?SECRET_KEY unset (call load_or_generate_runtime_secrets first)}"
    : "${ROOM_SECRET_KEY:?ROOM_SECRET_KEY unset (call load_or_generate_runtime_secrets first)}"

    # MAIL_* are optional in the strict sense — empty is a valid value.
    # Use ${VAR-} so unset and empty are both treated as empty.
    local mail_host="${MAIL_HOST-}"
    local mail_port="${MAIL_PORT-}"
    local mail_user="${MAIL_USER-}"
    local mail_password="${MAIL_PASSWORD-}"
    local mail_from="${MAIL_FROM-}"
    local mail_use_tls="${MAIL_USE_TLS-}"
    local mysql_port="${MYSQL_PORT-3306}"

    local mysql_pw_enc jwt_enc fernet_enc
    local mail_host_enc mail_port_enc mail_user_enc mail_password_enc mail_from_enc mail_use_tls_enc
    mysql_pw_enc="$(url_encode_value "$MYSQL_PASSWORD")"
    jwt_enc="$(url_encode_value "$SECRET_KEY")"
    fernet_enc="$(url_encode_value "$ROOM_SECRET_KEY")"
    mail_host_enc="$(url_encode_value "$mail_host")"
    mail_port_enc="$(url_encode_value "$mail_port")"
    mail_user_enc="$(url_encode_value "$mail_user")"
    mail_password_enc="$(url_encode_value "$mail_password")"
    mail_from_enc="$(url_encode_value "$mail_from")"
    mail_use_tls_enc="$(url_encode_value "$mail_use_tls")"

    local tmp_env
    tmp_env="$(mktemp "${target_path}.XXXXXX")"
    cat > "$tmp_env" <<EOF
# Generated by ${generator_label} on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# DO NOT COMMIT. DO NOT EDIT BY HAND unless you also delete the chatroom-mysql
# image and rebuild it (the build-arg flow bakes MYSQL_PASSWORD into
# /docker-entrypoint-initdb.d/99-grants.sql in the MySQL image). SECRET_KEY
# and ROOM_SECRET_KEY can be rotated independently — see the runbook.
#
# Consumed by:
#   - scripts/deploy_k8s.sh (creates the chatroom-mysql and chatroom-app k8s
#     Secrets, and the chatroom-app k8s ConfigMap, from these values)
#
# --- MySQL connection (consumed by app/database.py) -----------------------
MYSQL_USER=root
MYSQL_PASSWORD=${mysql_pw_enc}
MYSQL_HOST=mysql
MYSQL_PORT=${mysql_port_enc}
MYSQL_DB=chatroom_db

# --- JWT signing (consumed by app/utils.py) -------------------------------
SECRET_KEY=${jwt_enc}
ALGORITHM=HS256
ACCESS_TOKEN_EXPIRE_MINUTES=60

# --- Room pass-phrase encryption (consumed by app/utils.py) ---------------
ROOM_SECRET_KEY=${fernet_enc}

# --- SMTP (consumed by app/utils.py::send_invite_email) -------------------
# Leave MAIL_HOST blank to disable invite emails entirely (the app will
# raise a clear RuntimeError if Invite is clicked with MAIL_HOST unset).
# MAIL_PASSWORD is read into a k8s Secret; the other five land in a k8s
# ConfigMap. See the runbook §6.5 for the full layout and the local debug
# SMTP path (python -m smtpd -n -c DebuggingServer localhost:1025).
MAIL_HOST=${mail_host_enc}
MAIL_PORT=${mail_port_enc}
MAIL_USER=${mail_user_enc}
MAIL_PASSWORD=${mail_password_enc}
MAIL_FROM=${mail_from_enc}
MAIL_USE_TLS=${mail_use_tls_enc}
EOF

    # Atomic rename. If mv fails the tmp file is left for the caller to
    # clean up — we don't install a global trap here because the caller
    # is the one with the right error context.
    mv "$tmp_env" "$target_path"
    chmod 600 "$target_path" 2>/dev/null || true
}