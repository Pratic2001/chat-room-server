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
    local mysql_pw jwt fernet repl_pw
    # MAIL_* values: if the existing file has them, reuse; otherwise leave
    # blank (the caller — build_images.sh — will then prompt for them).
    # We do NOT generate defaults here; the build-time prompts are the
    # right place to collect SMTP credentials, since they can be blank
    # (disabled) or supplied by a human who knows the relay.
    local mail_host mail_port mail_user mail_password mail_from mail_use_tls
    # Redis topology values. Empty REDIS_SENTINELS means "single-pod
    # mode — connect directly to REDIS_URL". The defaults here match
    # the in-cluster chatroom-redis / chatroom-redis-sentinel Services.
    local redis_url mysql_read_host redis_sentinels redis_master_name

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
            # REPLICATION_PASSWORD may be missing from older .env.runtime
            # files (it was added with the MySQL StatefulSet topology).
            # In that case generate a fresh one and persist it. We do
            # NOT abort the build — the MySQL image's 02-replication-user
            # sql needs this, so it's effectively required, but we
            # generate instead of failing so existing deploys keep working.
            #
            # MySQL 8 rejects CREATE USER with a password longer than 32
            # bytes (ERROR 3056). generate_url_safe_password can produce
            # ~43 chars after the URL-special strip, so cap the replica
            # password here. The other secrets (MySQL root, JWT, Fernet)
            # have no such limit and keep their full length.
            if [[ -z "${REPLICATION_PASSWORD-}" ]]; then
                REPLICATION_PASSWORD="$(generate_url_safe_password | cut -c1-32)"
            fi
            printf '%s\n' "$MYSQL_PASSWORD"      > /tmp/_crs_mysql_pw
            printf '%s\n' "$SECRET_KEY"          > /tmp/_crs_jwt
            printf '%s\n' "$ROOM_SECRET_KEY"     > /tmp/_crs_fernet
            printf '%s\n' "$REPLICATION_PASSWORD" > /tmp/_crs_repl_pw
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
            # REDIS_URL: written by an earlier build, but treat it as
            # optional so older .env.runtime files still load. The default
            # matches the in-cluster chatroom-redis Service.
            printf '%s\n' "${REDIS_URL-redis://chatroom-redis:6379/0}" > /tmp/_crs_redis_url
            # MYSQL_READ_HOST: where read-only endpoints (messages, room
            # list) connect. Empty falls back to MYSQL_HOST in
            # app/database.py; on multi-node clusters it's set to the
            # mysql-replica Service.
            printf '%s\n' "${MYSQL_READ_HOST-}" > /tmp/_crs_mysql_read_host
            # REDIS_SENTINELS: comma-separated host:port list. Empty
            # means "use REDIS_URL directly" (single-pod mode).
            printf '%s\n' "${REDIS_SENTINELS-}" > /tmp/_crs_redis_sentinels
            # REDIS_MASTER_NAME: Sentinel's logical name for the master
            # group. Must match the `sentinel monitor` line in
            # k8s/28-redis-sentinel-statefulset.yaml.
            printf '%s\n' "${REDIS_MASTER_NAME-chatroom-redis}" > /tmp/_crs_redis_master_name
        )
        mysql_pw="$(cat /tmp/_crs_mysql_pw)";          rm -f /tmp/_crs_mysql_pw
        jwt="$(cat /tmp/_crs_jwt)";                    rm -f /tmp/_crs_jwt
        fernet="$(cat /tmp/_crs_fernet)";              rm -f /tmp/_crs_fernet
        repl_pw="$(cat /tmp/_crs_repl_pw)";            rm -f /tmp/_crs_repl_pw
        mysql_port="$(cat /tmp/_crs_mysql_port)";      rm -f /tmp/_crs_mysql_port
        mail_host="$(cat /tmp/_crs_mail_host)";        rm -f /tmp/_crs_mail_host
        mail_port="$(cat /tmp/_crs_mail_port)";        rm -f /tmp/_crs_mail_port
        mail_user="$(cat /tmp/_crs_mail_user)";        rm -f /tmp/_crs_mail_user
        mail_password="$(cat /tmp/_crs_mail_password)"; rm -f /tmp/_crs_mail_password
        mail_from="$(cat /tmp/_crs_mail_from)";        rm -f /tmp/_crs_mail_from
        mail_use_tls="$(cat /tmp/_crs_mail_use_tls)";  rm -f /tmp/_crs_mail_use_tls
        redis_url="$(cat /tmp/_crs_redis_url)";        rm -f /tmp/_crs_redis_url
        mysql_read_host="$(cat /tmp/_crs_mysql_read_host)"; rm -f /tmp/_crs_mysql_read_host
        redis_sentinels="$(cat /tmp/_crs_redis_sentinels)"; rm -f /tmp/_crs_redis_sentinels
        redis_master_name="$(cat /tmp/_crs_redis_master_name)"; rm -f /tmp/_crs_redis_master_name
    else
        # Generate. Same algorithms as change_db_password.sh.
        mysql_pw="$(generate_url_safe_password)"
        jwt="$(python3 -c 'import secrets; print(secrets.token_urlsafe(64))')"
        fernet="$(python3 -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())')"
        # REPLICATION_PASSWORD: the credential the 'repl'@'%' user on
        # the MySQL master uses for CHANGE MASTER TO from replicas.
        # Generated alongside the other secrets so the MySQL image's
        # 02-replication-user.sql template has it on first build.
        # Capped at 32 bytes because MySQL 8 rejects CREATE USER with a
        # longer password (ERROR 3056); the other secrets have no such
        # limit and keep their full entropy.
        repl_pw="$(generate_url_safe_password | cut -c1-32)"
        # MAIL_* defaults for first-time use — the build script will
        # prompt the user, who can accept the defaults by hitting Enter.
        mysql_port="3306"
        mail_host=""
        mail_port="587"
        mail_user=""
        mail_password=""
        mail_from="Chat Room <no-reply@example.com>"
        mail_use_tls="true"
        # Redis topology. REDIS_URL points at the in-cluster
        # chatroom-redis Service for direct (single-broker) mode.
        # REDIS_SENTINELS is a comma-separated list of host:port pairs
        # that the app uses to discover the master via Sentinel. The
        # default matches the in-cluster chatroom-redis-sentinel
        # headless Service. REDIS_MASTER_NAME is Sentinel's logical
        # name for the master group (matches `sentinel monitor` in
        # k8s/28-redis-sentinel-statefulset.yaml).
        #
        # Users running uvicorn locally can override REDIS_URL (e.g.
        # redis://localhost:6379/0) or clear REDIS_SENTINELS to skip
        # the Sentinel path entirely.
        redis_url="redis://chatroom-redis:6379/0"
        mysql_read_host=""
        redis_sentinels="chatroom-redis-sentinel:26379"
        redis_master_name="chatroom-redis"
    fi

    printf "MYSQL_PASSWORD=%q\n"   "$mysql_pw"
    printf "SECRET_KEY=%q\n"       "$jwt"
    printf "ROOM_SECRET_KEY=%q\n"  "$fernet"
    printf "REPLICATION_PASSWORD=%q\n" "$repl_pw"
    printf "MYSQL_PORT=%q\n"       "$mysql_port"
    printf "MAIL_HOST=%q\n"        "$mail_host"
    printf "MAIL_PORT=%q\n"        "$mail_port"
    printf "MAIL_USER=%q\n"        "$mail_user"
    printf "MAIL_PASSWORD=%q\n"    "$mail_password"
    printf "MAIL_FROM=%q\n"        "$mail_from"
    printf "MAIL_USE_TLS=%q\n"     "$mail_use_tls"
    printf "REDIS_URL=%q\n"        "$redis_url"
    printf "MYSQL_READ_HOST=%q\n"  "$mysql_read_host"
    printf "REDIS_SENTINELS=%q\n"  "$redis_sentinels"
    printf "REDIS_MASTER_NAME=%q\n" "$redis_master_name"
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
    # REPLICATION_PASSWORD is required because the MySQL image's
    # 02-replication-user.sql template bakes it in at build time. We
    # generate it in load_or_generate_runtime_secrets when no existing
    # value is found, so by the time we get here it's always set.
    : "${REPLICATION_PASSWORD:?REPLICATION_PASSWORD unset (call load_or_generate_runtime_secrets first)}"

    # MAIL_* are optional in the strict sense — empty is a valid value.
    # Use ${VAR-} so unset and empty are both treated as empty.
    local mail_host="${MAIL_HOST-}"
    local mail_port="${MAIL_PORT-}"
    local mail_user="${MAIL_USER-}"
    local mail_password="${MAIL_PASSWORD-}"
    local mail_from="${MAIL_FROM-}"
    local mail_use_tls="${MAIL_USE_TLS-}"
    local mysql_port="${MYSQL_PORT-3306}"
    # Redis topology. REDIS_URL is the direct-connect broker URL used
    # by single-pod dev (uvicorn) and as the Sentinel-mode fallback.
    # REDIS_SENTINELS is a comma-separated host:port list. Empty is a
    # valid value for both — empty REDIS_SENTINELS means "use
    # REDIS_URL directly"; empty REDIS_URL means "single-pod mode".
    #
    # These values are themselves URLs / connection strings, not
    # secrets, so the k8s ConfigMap entries below are the literal
    # values (no URL-encoding). .env files are read by python-dotenv
    # which preserves the raw string, so the values are usable on
    # both deployment paths.
    local redis_url="${REDIS_URL-redis://chatroom-redis:6379/0}"
    local mysql_read_host="${MYSQL_READ_HOST-}"
    local redis_sentinels="${REDIS_SENTINELS-}"
    local redis_master_name="${REDIS_MASTER_NAME-chatroom-redis}"

    local mysql_pw_enc jwt_enc fernet_enc repl_pw_enc mysql_port_enc
    local mail_host_enc mail_port_enc mail_user_enc mail_password_enc mail_from_enc mail_use_tls_enc
    mysql_pw_enc="$(url_encode_value "$MYSQL_PASSWORD")"
    jwt_enc="$(url_encode_value "$SECRET_KEY")"
    fernet_enc="$(url_encode_value "$ROOM_SECRET_KEY")"
    # REPLICATION_PASSWORD is a credential, not a URL. URL-encode it
    # anyway so it round-trips safely through 'set -a; source' and
    # any future hand-edits.
    repl_pw_enc="$(url_encode_value "$REPLICATION_PASSWORD")"
    mysql_port_enc="$(url_encode_value "$mysql_port")"
    mail_host_enc="$(url_encode_value "$mail_host")"
    mail_port_enc="$(url_encode_value "$mail_port")"
    # MAIL_USER and MAIL_FROM are emitted verbatim — they go to the
    # SMTP server via smtp.login() / the From: header, with no
    # URL-decoding step in the app. Encoding them turns the @ in
    # 'user@gmail.com' into %40, which the server then rejects as
    # an unknown account.
    mail_user_enc="$mail_user"
    mail_password_enc="$(url_encode_value "$mail_password")"
    mail_from_enc="$mail_from"
    mail_use_tls_enc="$(url_encode_value "$mail_use_tls")"

    local tmp_env
    tmp_env="$(mktemp "${target_path}.XXXXXX")"
    # Every value is wrapped in double quotes except the two integer ports
    # and ACCESS_TOKEN_EXPIRE_MINUTES (so a stray digit, when edited by
    # hand, is hard to fat-finger into a string). The URL-fed values
    # (MYSQL_PASSWORD, SECRET_KEY, ROOM_SECRET_KEY, MYSQL_HOST,
    # MYSQL_USER, MYSQL_DB) are also URL-encoded by url_encode_value
    # above, so a future password containing @ : / ? # [ ] % = or spaces
    # round-trips safely through 'set -a; source ...'. MAIL_USER and
    # MAIL_FROM are emitted verbatim — see the block comment in the
    # generated file below for why.
    # The heredoc marker below is unquoted on purpose: we need ${generator_label}
    # and $(date ...) to expand at write time. The body has no backticks or
    # other command-substitution chars, so the unquoted EOF is safe here.
    cat > "$tmp_env" <<EOF
# Generated by ${generator_label} on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# DO NOT COMMIT. DO NOT EDIT BY HAND unless you also delete the chatroom-mysql
# image and rebuild it (the build-arg flow bakes MYSQL_PASSWORD into
# /docker-entrypoint-initdb.d/99-grants.sql in the MySQL image). SECRET_KEY
# and ROOM_SECRET_KEY can be rotated independently — see the runbook.
#
# Consumed by:
#   - scripts/deploy_k8s.sh (loads these into env, then renders
#     k8s/secrets.runtime.yaml, which kubectl apply -f k8s/ applies as
#     the chatroom-mysql + chatroom-app Secrets and the chatroom-app
#     ConfigMap)
#
# Values that feed a URL parser (MYSQL_PASSWORD, SECRET_KEY,
# ROOM_SECRET_KEY, MYSQL_HOST, MYSQL_USER, MYSQL_DB) are URL-encoded
# and wrapped in double quotes, so a future password containing
# @ : / ? # [ ] % = or spaces round-trips safely through
# 'set -a; source'. MYSQL_PASSWORD in particular needs the encoded
# form: app/database.py builds mysql+pymysql://user:password@host/db
# and PyMySQL URL-decodes the userinfo component on connect.
#
# SMTP values are emitted verbatim. MAIL_USER and MAIL_FROM go to
# the SMTP server via smtp.login() / the From: header with no
# URL-decoding step in the app — encoding the @ in 'user@gmail.com'
# to %40 turns it into an unknown account on the server side.
#
# Bare knobs: the two ports, the token expiry, and MAIL_USE_TLS
# (true/false).

# --- MySQL connection (consumed by app/database.py) -----------------------
MYSQL_USER="root"
MYSQL_PASSWORD="${mysql_pw_enc}"
MYSQL_HOST="mysql"
MYSQL_PORT=${mysql_port_enc}
MYSQL_DB="chatroom_db"
# MYSQL_READ_HOST: read-only endpoints (GET /messages, GET /rooms/my)
# connect here. On 1-node clusters (kind/k3d/minikube) leave this
# blank — app/database.py falls back to MYSQL_HOST when it's unset,
# so reads land on the master. On multi-node clusters set this to
# "mysql-replica" (matches k8s/24-mysql-replica-service.yaml).
MYSQL_READ_HOST="${mysql_read_host}"

# --- MySQL replication (consumed by mysql/replication_bootstrap.sh) ------
# REPLICATION_PASSWORD is the credential the 'repl'@'%' user on the
# MySQL master uses to authenticate CHANGE MASTER TO from replicas.
# Baked into the MySQL image at build time via the
# 02-replication-user.sql.template; rotating it requires rebuilding
# the image AND running FLUSH PRIVILEGES on the live master.
REPLICATION_PASSWORD="${repl_pw_enc}"

# --- JWT signing (consumed by app/utils.py) -------------------------------
SECRET_KEY="${jwt_enc}"
ALGORITHM="HS256"
ACCESS_TOKEN_EXPIRE_MINUTES=60

# --- Room pass-phrase encryption (consumed by app/utils.py) ---------------
ROOM_SECRET_KEY="${fernet_enc}"

# --- SMTP (consumed by app/utils.py::send_invite_email) -------------------
# Leave MAIL_HOST blank to disable invite emails entirely (the app will
# raise a clear RuntimeError if Invite is clicked with MAIL_HOST unset).
# MAIL_PASSWORD is read into a k8s Secret; the other five land in a k8s
# ConfigMap. See the runbook §6.5 for the full layout and the local debug
# SMTP path (python -m smtpd -n -c DebuggingServer localhost:1025).
MAIL_HOST="${mail_host_enc}"
MAIL_PORT=${mail_port_enc}
MAIL_USER="${mail_user_enc}"
MAIL_PASSWORD="${mail_password_enc}"
MAIL_FROM="${mail_from_enc}"
MAIL_USE_TLS=${mail_use_tls_enc}

# --- Redis bus (consumed by app/redis_bus.py) ----------------------------
# The chatroom deployment now runs Redis with Sentinel-managed failover,
# so the app connects via Sentinels (REDIS_SENTINELS) rather than directly
# to a single broker. REDIS_URL is kept as the direct-connect fallback
# for local dev (uvicorn) — the app's bus code prefers REDIS_SENTINELS
# when both are set, and falls back to REDIS_URL when REDIS_SENTINELS is
# blank. REDIS_MASTER_NAME is Sentinel's logical name for the master
# group; it must match the `sentinel monitor` line in
# k8s/28-redis-sentinel-statefulset.yaml.
#
# Override REDIS_URL for local dev (redis://localhost:6379/0). Leave
# REDIS_SENTINELS blank AND REDIS_URL blank to disable cross-pod
# fan-out entirely (single-pod mode; the bus logs a warning and runs
# in degraded mode).
#
# Note: these values are URLs / connection strings, not secrets, so
# the k8s ConfigMap entries are the literal values (no URL-encoding).
# .env files are read by python-dotenv which preserves the raw string.
REDIS_URL="${redis_url}"
REDIS_SENTINELS="${redis_sentinels}"
REDIS_MASTER_NAME="${redis_master_name}"
EOF

    # Atomic rename. If mv fails the tmp file is left for the caller to
    # clean up — we don't install a global trap here because the caller
    # is the one with the right error context.
    mv "$tmp_env" "$target_path"
    chmod 600 "$target_path" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Render k8s/secrets.runtime.yaml — the deployable Secret + ConfigMap manifests
# -----------------------------------------------------------------------------
# This is the build-time source of truth for the chatroom-mysql + chatroom-app
# k8s Secrets and the chatroom-app ConfigMap. It is the only path through which
# the cluster learns MYSQL_PASSWORD, SECRET_KEY, ROOM_SECRET_KEY, MAIL_PASSWORD,
# and the MAIL_* ConfigMap keys. The committed templates under k8s/
# (10-mysql-secret.yaml, 31-app-secret.yaml) hold `REPLACE_AT_DEPLOY_TIME`
# placeholders and are intentionally invalid for `kubectl apply` — apply
# `k8s/secrets.runtime.yaml` (or `kubectl apply -f k8s/` once the rendered
# file exists) instead.
#
# Why the values live in a manifest (not just in app/.env.runtime that the
# deploy script reads): so a bare `kubectl apply -f k8s/` from a fresh
# checkout produces a working cluster, with no separate deploy step. The
# file is gitignored (.gitignore: k8s/secrets.runtime.yaml) and excluded
# from the app image's build context (.dockerignore: k8s/secrets.runtime.yaml).
#
# Required env (read at function-call time — caller must export these):
#   MYSQL_PASSWORD, SECRET_KEY, ROOM_SECRET_KEY        — chatroom-app Secret
#   MAIL_PASSWORD                                       — chatroom-app Secret
#   MYSQL_HOST, MYSQL_PORT, MYSQL_USER, MYSQL_DB        — chatroom-app ConfigMap
#   ALGORITHM, ACCESS_TOKEN_EXPIRE_MINUTES              — chatroom-app ConfigMap
#   MAIL_HOST, MAIL_PORT, MAIL_USER, MAIL_FROM,
#   MAIL_USE_TLS                                        — chatroom-app ConfigMap
#   REDIS_URL                                           — chatroom-app ConfigMap
#   MYSQL_PASSWORD (also)                               — chatroom-mysql Secret
#                                                        (chatroom-mysql uses
#                                                        MYSQL_ROOT_PASSWORD;
#                                                        we map MYSQL_PASSWORD
#                                                        → MYSQL_ROOT_PASSWORD
#                                                        here so the caller
#                                                        only sets one knob)
#
# Usage:
#   render_k8s_secrets "$REPO_ROOT/k8s/secrets.runtime.yaml" \
#                     "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
render_k8s_secrets() {
    local target_path="$1"
    local generated_at="${2:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

    # Required: the three Secret values for chatroom-app, plus MAIL_PASSWORD
    # (which is a Secret because it's a credential). MYSQL_PASSWORD is the
    # one knob for both chatroom-app.MYSQL_PASSWORD and the
    # chatroom-mysql.MYSQL_ROOT_PASSWORD — they must always agree, and
    # the MySQL image's build-arg is the same value, so this stays a
    # single source. REPLICATION_PASSWORD is a second Secret value for
    # chatroom-mysql — it's the credential the 'repl'@'%' user uses
    # for CHANGE MASTER TO from replica pods.
    : "${MYSQL_PASSWORD:?MYSQL_PASSWORD unset (call load_or_generate_runtime_secrets first)}"
    : "${SECRET_KEY:?SECRET_KEY unset (call load_or_generate_runtime_secrets first)}"
    : "${ROOM_SECRET_KEY:?ROOM_SECRET_KEY unset (call load_or_generate_runtime_secrets first)}"
    : "${REPLICATION_PASSWORD:?REPLICATION_PASSWORD unset (call load_or_generate_runtime_secrets first)}"
    : "${MAIL_PASSWORD:=}"  # empty is a valid value (no SMTP auth)

    # ConfigMap values. Empty is a valid value for MAIL_HOST (disables
    # invite emails) and MAIL_USER. Use ${VAR-default} for unset-vs-empty
    # in case older .env.runtime files are missing keys.
    local mysql_host="${MYSQL_HOST:-mysql}"
    local mysql_port="${MYSQL_PORT:-3306}"
    local mysql_user="${MYSQL_USER:-root}"
    local mysql_db="${MYSQL_DB:-chatroom_db}"
    local algorithm="${ALGORITHM:-HS256}"
    local access_token_expire_minutes="${ACCESS_TOKEN_EXPIRE_MINUTES:-60}"
    local mail_host="${MAIL_HOST:-}"
    local mail_port="${MAIL_PORT:-587}"
    local mail_user="${MAIL_USER:-}"
    local mail_password="${MAIL_PASSWORD:-}"
    local mail_from="${MAIL_FROM:-Chat Room <no-reply@example.com>}"
    local mail_use_tls="${MAIL_USE_TLS:-true}"
    # REDIS_URL lands in the chatroom-app ConfigMap (not a Secret —
    # it's not a credential). Defaults to the in-cluster Redis Service
    # name. Empty is a valid value to run the app in single-pod mode.
    local redis_url="${REDIS_URL:-redis://chatroom-redis:6379/0}"
    # MYSQL_READ_HOST: read-only endpoints connect here. Defaults to
    # empty (1-node fallback to MYSQL_HOST). On multi-node clusters
    # set this to "mysql-replica" via the rendered ConfigMap.
    local mysql_read_host="${MYSQL_READ_HOST:-}"
    # REDIS_SENTINELS: comma-separated host:port list. Empty means
    # "connect directly via REDIS_URL" (single-broker / local dev).
    # Defaults to the in-cluster chatroom-redis-sentinel headless
    # Service so a fresh build lands on the Sentinel-managed cluster.
    local redis_sentinels="${REDIS_SENTINELS:-}"
    # REDIS_MASTER_NAME: Sentinel's logical name for the master group.
    # Must match the `sentinel monitor` line in
    # k8s/28-redis-sentinel-statefulset.yaml. The app passes this to
    # redis.asyncio.sentinel.Sentinel.
    local redis_master_name="${REDIS_MASTER_NAME:-chatroom-redis}"

    # URL-encode the values that feed a URL parser (MYSQL_PASSWORD,
    # SECRET_KEY, ROOM_SECRET_KEY, REPLICATION_PASSWORD, MYSQL_HOST,
    # MYSQL_USER, MYSQL_DB). The encoding is defensive (auto-generated
    # values are already URL-safe) but load-bearing for MYSQL_PASSWORD
    # specifically — runbook §9.1.2 documents that the encoded form
    # is what both the chatroom-app Secret and the chatroom-mysql
    # image's 99-grants.sql must agree on, since app/database.py builds
    # mysql+pymysql://user:password@host/db and PyMySQL URL-decodes
    # the userinfo component on connect.
    #
    # MAIL_USER and MAIL_FROM are emitted verbatim — see the block
    # comment in the generated env file for the SMTP rationale.
    local mysql_pw_enc jwt_enc fernet_enc repl_pw_enc mail_password_enc
    local mysql_host_enc mysql_port_enc mysql_user_enc mysql_db_enc
    local algorithm_enc access_token_enc
    local mail_host_enc mail_port_enc mail_user_enc mail_from_enc mail_use_tls_enc
    mysql_pw_enc="$(url_encode_value "$MYSQL_PASSWORD")"
    jwt_enc="$(url_encode_value "$SECRET_KEY")"
    fernet_enc="$(url_encode_value "$ROOM_SECRET_KEY")"
    repl_pw_enc="$(url_encode_value "$REPLICATION_PASSWORD")"
    mail_password_enc="$(url_encode_value "$mail_password")"
    mysql_host_enc="$(url_encode_value "$mysql_host")"
    mysql_port_enc="$(url_encode_value "$mysql_port")"
    mysql_user_enc="$(url_encode_value "$mysql_user")"
    mysql_db_enc="$(url_encode_value "$mysql_db")"
    algorithm_enc="$(url_encode_value "$algorithm")"
    access_token_enc="$(url_encode_value "$access_token_expire_minutes")"
    mail_host_enc="$(url_encode_value "$mail_host")"
    mail_port_enc="$(url_encode_value "$mail_port")"
    mail_user_enc="$mail_user"
    mail_from_enc="$mail_from"
    mail_use_tls_enc="$(url_encode_value "$mail_use_tls")"

    local tmp_yaml
    tmp_yaml="$(mktemp "${target_path}.XXXXXX")"
    cat > "$tmp_yaml" <<EOF
# Generated on ${generated_at} by scripts/build_images.sh (or
# scripts/write_runtime_env.sh). DO NOT COMMIT. DO NOT EDIT BY HAND —
# re-run the build script to regenerate.
#
# This file is the single source of truth for the chatroom-mysql and
# chatroom-app k8s Secrets and the chatroom-app ConfigMap. The committed
# templates under k8s/ (10-mysql-secret.yaml, 31-app-secret.yaml) hold
# \`REPLACE_AT_DEPLOY_TIME\` placeholders and are intentionally invalid;
# \`kubectl apply\` them and you'll get a cluster with a literal
# \`REPLACE_AT_DEPLOY_TIME\` MySQL password (1045 Access denied).
#
# Apply via \`kubectl apply -f k8s/\` (this file is in k8s/ and is
# gitignored) or \`kubectl apply -f k8s/secrets.runtime.yaml\` directly.
#
# All stringData / data values are URL-encoded so future hand-edits
# can't accidentally introduce URL-special chars. PyMySQL URL-decodes
# the userinfo component on connect, so the app transparently sees the
# real password. See RUNBOOK.md §9.1.2.
---
apiVersion: v1
kind: Secret
metadata:
  name: chatroom-mysql
  namespace: chatroom
  labels:
    app.kubernetes.io/name: chatroom
    app.kubernetes.io/component: mysql
type: Opaque
stringData:
  MYSQL_ROOT_PASSWORD: "${mysql_pw_enc}"
  # REPLICATION_PASSWORD: credential for the 'repl'@'%' user. The
  # master uses it to authenticate CHANGE MASTER TO from replicas.
  # Also baked into the MySQL image at build time via
  # 02-replication-user.sql.template.
  REPLICATION_PASSWORD: "${repl_pw_enc}"
---
apiVersion: v1
kind: Secret
metadata:
  name: chatroom-app
  namespace: chatroom
  labels:
    app.kubernetes.io/name: chatroom
    app.kubernetes.io/component: app
type: Opaque
stringData:
  MYSQL_PASSWORD: "${mysql_pw_enc}"
  SECRET_KEY: "${jwt_enc}"
  ROOM_SECRET_KEY: "${fernet_enc}"
  MAIL_PASSWORD: "${mail_password_enc}"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: chatroom-app
  namespace: chatroom
  labels:
    app.kubernetes.io/name: chatroom
    app.kubernetes.io/component: app
data:
  MYSQL_HOST: "${mysql_host_enc}"
  MYSQL_PORT: "${mysql_port_enc}"
  MYSQL_USER: "${mysql_user_enc}"
  MYSQL_DB: "${mysql_db_enc}"
  # MYSQL_READ_HOST: where read-only endpoints (GET /messages,
  # GET /rooms/my) connect. Empty falls back to MYSQL_HOST in
  # app/database.py (1-node clusters). On multi-node clusters set
  # this to "mysql-replica" — see k8s/24-mysql-replica-service.yaml.
  MYSQL_READ_HOST: "${mysql_read_host}"
  ALGORITHM: "${algorithm_enc}"
  ACCESS_TOKEN_EXPIRE_MINUTES: "${access_token_enc}"
  MAIL_HOST: "${mail_host_enc}"
  MAIL_PORT: "${mail_port_enc}"
  MAIL_USER: "${mail_user_enc}"
  MAIL_FROM: "${mail_from_enc}"
  MAIL_USE_TLS: "${mail_use_tls_enc}"
  # REDIS_URL is itself a URL; emit it verbatim so the redis-py
  # client can parse it directly. URL-encoding it (the way passwords
  # are) would break the redis:// scheme parsing.
  REDIS_URL: "${redis_url}"
  # REDIS_SENTINELS: comma-separated host:port list. When non-empty,
  # the app uses redis.asyncio.sentinel.Sentinel to discover the
  # current master instead of connecting via REDIS_URL directly.
  # Defaults to the in-cluster chatroom-redis-sentinel headless
  # Service (k8s/30-redis-sentinel-service.yaml) so a fresh deploy
  # automatically picks up the new Sentinel-managed Redis topology.
  REDIS_SENTINELS: "${redis_sentinels}"
  # REDIS_MASTER_NAME: Sentinel's logical name for the master group.
  # Must match the `sentinel monitor` line in
  # k8s/28-redis-sentinel-statefulset.yaml.
  REDIS_MASTER_NAME: "${redis_master_name}"
EOF

    # Atomic rename. Same error-handling choice as write_runtime_env_file.
    mv "$tmp_yaml" "$target_path"
    chmod 600 "$target_path" 2>/dev/null || true
}