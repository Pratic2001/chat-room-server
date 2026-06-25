#!/usr/bin/env bash
# replication_bootstrap.sh
# -----------------------------------------------------------------------------
# Per-pod MySQL bootstrap for the chatroom StatefulSet topology.
#
# Called as the Docker entrypoint for the chatroom-mysql image. Decides
# master-vs-replica from the MYSQL_ROLE env var (set via the StatefulSet's
# downward API on pod mysql-0 vs. the rest) and either starts mysqld
# directly (master, via the official entrypoint) or dump-loads from the
# master and starts replication (replicas, via a self-contained bootstrap).
#
# Master path:
#   - Delegate immediately to the official mysql:8 entrypoint. The
#     01-schema.sql / 02-replication-user.sql / 99-grants.sql init scripts
#     run as usual on first boot of an empty datadir. The mysqld server
#     args add --server-id, --log-bin, --gtid-mode=ON etc. (set by the
#     Dockerfile's CMD) so binlog is on from the start.
#
# Replica path:
#   Why we don't delegate to the official entrypoint: the entrypoint
#   checks for `$DATADIR/mysql` to decide whether to initialize. On a
#   fresh replica PVC that directory is empty, so the entrypoint runs
#   its own `mysqld --initialize-insecure` then `docker_temp_server_start`
#   to apply init scripts. We need to dump-load from the master first,
#   then run CHANGE MASTER TO + START SLAVE against a running mysqld.
#   The cleanest path is to do the whole lifecycle ourselves and never
#   invoke the official entrypoint.
#
#   Steps:
#   1. Wait for the master's TCP port to accept connections.
#   2. Wait for the master's mysqld to accept authenticated pings.
#   3. Run `mysqld --initialize-insecure` (creates system tables; doesn't
#      start the server).
#   4. Start mysqld in the background (with --skip-networking so no
#      external clients can race our setup) and wait for the socket.
#   5. mysqldump from master (with --set-gtid-purged=COMMENTED so the
#      restore doesn't conflict with MASTER_AUTO_POSITION) and pipe into
#      the local mysql client. This replaces the local system tables
#      with the master's, so 'repl'@'%' etc. are aligned.
#   6. CHANGE MASTER TO ... MASTER_AUTO_POSITION=1.
#   7. START SLAVE.
#   8. Stop the temporary mysqld (so the foreground start below can
#      claim the socket/port cleanly).
#   9. exec mysqld $@ in the foreground, with --read-only=ON and
#      --super-read-only=ON so accidental writes are rejected.
#
# Why dump-load before START SLAVE:
#   Without a local clone, START SLAVE replays every binlog event from the
#   master's GTID set with no local data — works eventually but takes hours
#   for any non-trivial dataset. With a snapshot, the replica applies only
#   the binlog tail from the dump's GTID set forward, which is sub-second
#   in steady state.
#
# Why --set-gtid-purged=COMMENTED:
#   The default (AUTO) writes `SET @@GLOBAL.GTID_PURGED=...` to the dump,
#   which on restore tries to set the local GTID_PURGED to the master's
#   value. That conflicts with MASTER_AUTO_POSITION=1 (which expects the
#   replica to compute its own GTID_PURGED from CHANGE MASTER TO's
#   RECEIVED_TRANSACTION_SET). COMMENTED includes the GTID set as a
#   comment only, so the restore doesn't touch GTID_PURGED.
# -----------------------------------------------------------------------------

set -euo pipefail

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "replication" "$*" >&2; }
warn() { printf '\033[1;33m[%s]\033[0m %s\n' "replication" "$*" >&2; }
fail() { printf '\033[1;31m[%s]\033[0m %s\n' "replication" "$*" >&2; exit 1; }

# MYSQL_ROLE is set by the StatefulSet pod template (downward API on
# POD_NAME: "master" on mysql-0, "replica" on the rest). REPLICATION_PASSWORD
# comes from the chatroom-mysql Secret. The official mysql:8 image sets
# MYSQL_ROOT_PASSWORD into the local root user at first boot via the init
# scripts; for the replica bootstrap we reuse it to authenticate the local
# mysqldump restore.
#
# MYSQL_ROLE derivation: the StatefulSet pod template doesn't set
# MYSQL_ROLE explicitly (k8s env values are static — they can't branch
# on the pod's name). Instead, the entrypoint script derives it from
# the pod's hostname, which the downward API exposes as metadata.name
# (= "mysql-0", "mysql-1", ...). mysql-0 is the master; everything
# else is a replica. POD_ORDINAL is extracted from the hostname and
# used to compute a unique server-id (100 + ordinal) so the cluster
# satisfies MySQL's "every server has a unique server-id" requirement.
POD_NAME_VALUE="${POD_NAME:-${HOSTNAME:-}}"
if [[ -z "$POD_NAME_VALUE" ]]; then
    fail "Neither POD_NAME nor HOSTNAME is set; cannot derive MYSQL_ROLE."
fi
if [[ "$POD_NAME_VALUE" == "mysql-0" ]]; then
    MYSQL_ROLE="master"
    # Always derive server-id from the pod ordinal on StatefulSet pods.
    # We deliberately do NOT honor MYSQL_SERVER_ID here even if it's
    # set in the environment — a frozen value would collide with another
    # pod in the StatefulSet and break replication with "source and
    # replica have equal MySQL server ids". A previous version of the
    # Dockerfile baked `ENV MYSQL_SERVER_ID=1` into the image, which
    # pinned every pod (master and replica alike) to server-id 1 and
    # surfaced exactly that error.
    DERIVED_SERVER_ID="$((100 + 0))"
    SERVER_ID="${DERIVED_SERVER_ID}"
elif [[ "$POD_NAME_VALUE" =~ ^mysql-([0-9]+)$ ]]; then
    MYSQL_ROLE="replica"
    DERIVED_SERVER_ID="$((100 + ${BASH_REMATCH[1]}))"
    SERVER_ID="${DERIVED_SERVER_ID}"
else
    # Standalone `docker run` (no StatefulSet hostname). Treat as master
    # and let MYSQL_SERVER_ID override the default — useful for local
    # debugging where the operator wants a specific server-id.
    MYSQL_ROLE="${MYSQL_ROLE:-master}"
    SERVER_ID="${MYSQL_SERVER_ID:-1}"
fi
log "Derived MYSQL_ROLE=${MYSQL_ROLE}, SERVER_ID=${SERVER_ID} from POD_NAME=${POD_NAME_VALUE}"
export MYSQL_ROLE SERVER_ID
MYSQL_MASTER_HOST="${MYSQL_MASTER_HOST:-mysql-0.mysql-headless}"
MYSQL_MASTER_PORT="${MYSQL_MASTER_PORT:-3306}"
REPLICATION_USER="${REPLICATION_USER:-repl}"
REPLICATION_PASSWORD="${REPLICATION_PASSWORD:?REPLICATION_PASSWORD env var is required (sourced from the chatroom-mysql Secret)}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD env var is required (sourced from the chatroom-mysql Secret)}"
# Datadir inside the container — must match the official image's default
# and the volumeMount in the StatefulSet pod template.
DATADIR="${MYSQL_DATADIR:-/var/lib/mysql}"

# Master path: delegate to the official entrypoint with --server-id
# prepended so the master's server-id is unique in the cluster. The
# official entrypoint runs `exec "$@"` after init, so the server-id
# reaches mysqld. The manifest's `args:` does NOT include --server-id
# (the script injects it for both master and replica paths).
if [[ "$MYSQL_ROLE" != "replica" ]]; then
    log "Master path (MYSQL_ROLE=${MYSQL_ROLE}); delegating to official entrypoint with server-id=${SERVER_ID}."
    exec /usr/local/bin/docker-entrypoint.sh mysqld --server-id="${SERVER_ID}" "$@"
fi

# -----------------------------------------------------------------------------
# Replica path (below)
# -----------------------------------------------------------------------------
log "Replica bootstrap starting (target master: ${MYSQL_MASTER_HOST}:${MYSQL_MASTER_PORT}, server-id: ${SERVER_ID})..."

# Step 1+2: Wait for master to be reachable AND responsive to authenticated
# pings. The StatefulSet guarantees mysql-0 is scheduled before mysql-1..N-1,
# but mysqld inside the master pod may not be listening yet when this runs.
log "Waiting for master ${MYSQL_MASTER_HOST}:${MYSQL_MASTER_PORT}..."
for attempt in $(seq 1 90); do
    if mysqladmin ping \
        --host="${MYSQL_MASTER_HOST}" \
        --port="${MYSQL_MASTER_PORT}" \
        --user="${REPLICATION_USER}" \
        --password="${REPLICATION_PASSWORD}" \
        --connect-timeout=5 \
        --silent >/dev/null 2>&1; then
        log "Master mysqld answered ping on attempt $attempt."
        break
    fi
    if [[ "$attempt" -eq 90 ]]; then
        fail "Master mysqld did not respond to ping within 90s. Aborting replica bootstrap."
    fi
    sleep 2
done

# Step 3: Initialize system tables. Skip if the datadir already has the
# mysql/ schema directory (idempotent restart of an already-bootstrapped
# replica — common during a StatefulSet reschedule).
if [[ -d "${DATADIR}/mysql" ]]; then
    log "Datadir already initialized; skipping mysqld --initialize-insecure."
else
    log "Initializing local datadir..."
    # --initialize-insecure: no root password set (we'll override via
    # --init-file below so the dump's ALTER USER statements land on a
    # root user that already has the right password).
    # --user=mysql: write files owned by the mysql user so the foreground
    # mysqld can read them later without tripping permission checks.
    mysqld \
        --initialize-insecure \
        --user=mysql \
        --datadir="${DATADIR}" \
        --server-id="${SERVER_ID}" \
        --log-bin=mysql-bin \
        --gtid-mode=ON \
        --enforce-gtid-consistency=ON \
        --binlog-format=ROW
fi

# Step 4: Start mysqld in the background with --skip-networking so no
# external client can race our setup. --socket pins the socket path so
# the local mysql client knows where to find it.
#
# --init-file=/tmp/replica-bootstrap-init.sql is the load-bearing piece
# of the dump-load path. After --initialize-insecure, root@localhost on
# MySQL 8 uses caching_sha2_password with an empty hash; the
# empty-password fast path over a unix socket is unreliable on some
# MySQL 8 releases — the local `mysql --user=root --socket=…` (no
# password) call in the dump-load below gets 1045 with (using
# password: NO). The init file installs auth_socket and pins
# root@localhost to it BEFORE the background mysqld accepts any client
# connections, so the dump-load's local mysql client connects
# passwordlessly via the OS-user match. The init file is idempotent so
# a re-run on a populated datadir (the script's idempotent-restart
# path at the top of the replica block) still works.
log "Writing /tmp/replica-bootstrap-init.sql..."
cat > /tmp/replica-bootstrap-init.sql <<'INIT_SQL'
-- Replica bootstrap init file (mysql/replication_bootstrap.sh).
-- Runs once at mysqld startup, before the server accepts any client
-- connections. Idempotent so re-runs on a populated datadir (e.g. a
-- rescheduled replica) don't fail.

-- Register auth_socket plugin if not already registered. INSTALL
-- PLUGIN has no IF NOT EXISTS form, so guard with
-- INFORMATION_SCHEMA.PLUGINS.
SET @do_install := (SELECT COUNT(*) = 0
    FROM INFORMATION_SCHEMA.PLUGINS
    WHERE PLUGIN_NAME = 'auth_socket' AND PLUGIN_STATUS = 'ACTIVE');
SET @sql := IF(@do_install,
    'INSTALL PLUGIN auth_socket SONAME ''auth_socket.so''',
    'DO 0');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- Pin root@localhost to auth_socket. The dump-load below runs
-- `mysql --user=root --socket=…` with no password, and the script
-- continues to use the same connection for every subsequent local
-- mysql / mysqladmin call until the foreground mysqld takes over.
-- auth_socket is the only plugin that gives a reliable password-less
-- unix-socket connection regardless of MySQL 8 caching_sha2_password
-- startup state. The plugin's .so is bundled at
-- /usr/lib/mysql/plugin/auth_socket.so in the mysql:8.0-debian base.
ALTER USER 'root'@'localhost' IDENTIFIED WITH auth_socket;
INIT_SQL
chmod 644 /tmp/replica-bootstrap-init.sql

log "Starting mysqld (background, skip-networking)..."
mkdir -p /var/run/mysqld
chown -R mysql:mysql /var/run/mysqld 2>/dev/null || true

# Run the temporary mysqld under gosu mysql so all writes (relay log,
# binlog, InnoDB redo) are owned by the mysql user — matches the
# foreground mysqld below and avoids permission errors at handoff.
# gosu is at /usr/local/bin/gosu in the official mysql:8 image (added
# by the upstream Dockerfile for the same step-down-from-root reason).
/usr/local/bin/gosu mysql mysqld \
    --datadir="${DATADIR}" \
    --server-id="${SERVER_ID}" \
    --log-bin=mysql-bin \
    --gtid-mode=ON \
    --enforce-gtid-consistency=ON \
    --binlog-format=ROW \
    --skip-networking \
    --socket=/var/run/mysqld/mysqld.sock \
    --pid-file=/var/run/mysqld/mysqld.pid \
    --init-file=/tmp/replica-bootstrap-init.sql \
    >> /var/log/mysqld-bootstrap.log 2>&1 &
# MYSQLD_BG_PID is captured for diagnostics if the startup fails.
MYSQLD_BG_PID=$!

# Wait for the socket to appear. The official image waits up to 30s for
# "mysqld: ready for connections" in the log; we do the same with a
# tighter socket-poll loop.
log "Waiting for local mysqld socket..."
for attempt in $(seq 1 60); do
    if [[ -S /var/run/mysqld/mysqld.sock ]]; then
        # Give the server a beat to finish initializing even after the
        # socket is up — `--skip-networking` doesn't slow init but some
        # startup steps (InnoDB buffer pool warmup, GTID module load)
        # still take a moment past socket-listen.
        sleep 1
        log "Local mysqld ready on attempt $attempt."
        break
    fi
    if [[ "$attempt" -eq 60 ]]; then
        fail "Local mysqld did not open its socket within 60s. See /var/log/mysqld-bootstrap.log."
    fi
    sleep 1
done

# Step 5: Dump-load from master. The dump includes the mysql/ system
# schema, so the local repl user and root user get overwritten by the
# master's values. The dump is piped through `mysql --user=root
# --socket=…` with no password; this connection works because the
# `--init-file` on the background mysqld above already pinned
# `root@localhost` to `auth_socket` (which authenticates by matching
# the OS user — root in this container — and skips the password
# roundtrip entirely). The dump itself then overwrites mysql.user with
# the master's rows, which use `caching_sha2_password` + a hash of
# `MYSQL_ROOT_PASSWORD`. The `ALTER USER 'root'@'localhost'
# IDENTIFIED WITH auth_socket;` reset below re-pins root to
# auth_socket so every subsequent local mysql call in this script
# (CHANGE MASTER TO, START SLAVE, the temp mysqld shutdown) is again
# password-less. See RUNBOOK.md §9.10 for the full failure modes.
log "Cloning master via mysqldump..."
# --no-tablespaces: skip tablespace metadata. The 'repl'@'%' user only
# has REPLICATION SLAVE — mysqldump's tablespaces branch additionally
# requires the PROCESS privilege and aborts with
# "Access denied; you need (at least one of) the PROCESS privilege(s)
# for this operation" when it's missing. We don't need the tablespace
# info for logical replication (it's only used by the offline
# `--clone` transport), so dropping the flag is the right fix.
if ! mysqldump \
    --host="${MYSQL_MASTER_HOST}" \
    --port="${MYSQL_MASTER_PORT}" \
    --user="${REPLICATION_USER}" \
    --password="${REPLICATION_PASSWORD}" \
    --all-databases \
    --set-gtid-purged=COMMENTED \
    --single-transaction \
    --triggers \
    --routines \
    --events \
    --hex-blob \
    --default-character-set=utf8mb4 \
    --column-statistics=0 \
    --no-tablespaces \
    | mysql --user=root --socket=/var/run/mysqld/mysqld.sock; then
    fail "Initial dump-load failed; check that the master is healthy and credentials match."
fi
log "Dump-load complete."

# After the dump, root@localhost on this replica has been overwritten by
# the master's `mysql.user` rows — which use `caching_sha2_password` (the
# MySQL 8 default) with a hash of the master's MYSQL_ROOT_PASSWORD. That
# plugin on a unix-socket connection has a known sharp edge: it requires
# either a secure transport or a successful RSA key exchange for the
# cleartext password, and even with --password on the command line the
# mysql client can fail with "Access denied" (1227 / 1045) because the
# server doesn't accept the cleartext over the socket under all startup
# states. The reliable workaround is to re-pin root@localhost to
# auth_socket (matches the OS root user inside the container), which
# gives every local `mysql` call a password-less connection by virtue of
# running as root — same trick the official mysql entrypoint uses during
# init. This script runs as root throughout (gosu drops to the mysql user
# only for the mysqld processes, never for the mysql client), so
# auth_socket is correct here.
#
# Prerequisite: the auth_socket plugin must be registered before this
# ALTER USER runs. The `--init-file` on the background mysqld
# (see "Step 4" above) installed it idempotently at server startup, so
# it's always available here. The earlier "INSTALL PLUGIN if not
# registered" guard that lived in this slot was removed when the
# init-file took over the install — the dump-load already used a
# passwordless auth_socket connection, so a post-dump install would
# have been redundant.
#
# We use the same dump-time mysql --user=root --socket=… (no password)
# connection that the dump-load just used, so no password roundtrip is
# needed to make this change.
mysql --user=root --socket=/var/run/mysqld/mysqld.sock <<'SQL'
ALTER USER 'root'@'localhost' IDENTIFIED WITH auth_socket;
FLUSH PRIVILEGES;
SQL

# Helper: run a mysql client command against the local server as root
# via the unix socket and the auth_socket plugin. Defined after the
# dump-load + auth_socket reset because both steps assume the dump-time
# password-less connection is still valid.
mysql_local() {
    mysql --user=root --socket=/var/run/mysqld/mysqld.sock "$@"
}
mysqladmin_local() {
    mysqladmin --user=root --socket=/var/run/mysqld/mysqld.sock "$@"
}

# Step 6+7: Configure replication and start the slave thread.
log "Configuring CHANGE MASTER TO + START SLAVE..."
mysql_local <<SQL
STOP SLAVE;
CHANGE MASTER TO
    MASTER_HOST='${MYSQL_MASTER_HOST}',
    MASTER_PORT=${MYSQL_MASTER_PORT},
    MASTER_USER='${REPLICATION_USER}',
    MASTER_PASSWORD='${REPLICATION_PASSWORD}',
    MASTER_AUTO_POSITION=1;
START SLAVE;
SQL

# Verify replication is actually running before we hand off — fail loud
# here is much better than a silently-stuck replica at runtime.
log "Verifying SHOW SLAVE STATUS..."
# Don't pass -N (--skip-column-names): SHOW SLAVE STATUS\G produces one
# field per line in "Label: value" form, and the grep checks below need the
# label text. With -N, the labels are stripped and the grep always fails
# even on a healthy replica — that surfaced as a CrashLoopBackOff where
# every retry showed `Slave_IO_Running: Yes` and `Slave_SQL_Running: Yes`
# in the captured values, but no labels anywhere in the output.
#
# The IO thread can take a moment to connect to the master (DNS, TCP,
# auth handshake, GTID exchange) right after START SLAVE. Poll for up to
# ~10s before giving up — fast enough not to mask real failures, slow
# enough to absorb the cold-start handshake. Each iteration captures a
# fresh SHOW SLAVE STATUS so we can include the final state in the
# failure message.
SLAVE_STATUS=""
REPLICATION_OK=0
for attempt in $(seq 1 20); do
    SLAVE_STATUS="$(mysql_local -e 'SHOW SLAVE STATUS\G' 2>&1)"
    if grep -q "Slave_IO_Running: Yes" <<<"$SLAVE_STATUS" \
        && grep -q "Slave_SQL_Running: Yes" <<<"$SLAVE_STATUS"; then
        REPLICATION_OK=1
        break
    fi
    sleep 0.5
done
if [[ "$REPLICATION_OK" -ne 1 ]]; then
    fail "Slave_IO_Running/Slave_SQL_Running did not both reach Yes within 10s. SHOW SLAVE STATUS:\n${SLAVE_STATUS}"
fi
log "Replication started successfully."

# Step 8: Stop the temporary mysqld. We want the foreground start below
# to claim the socket/port cleanly. Send SIGTERM (the default mysql
# shutdown signal) and wait for the pid to exit.
log "Stopping temporary mysqld..."
mysqladmin_local shutdown
for attempt in $(seq 1 30); do
    if [[ ! -S /var/run/mysqld/mysqld.sock ]]; then
        log "Temporary mysqld stopped on attempt $attempt."
        break
    fi
    if [[ "$attempt" -eq 30 ]]; then
        fail "Temporary mysqld did not stop within 30s."
    fi
    sleep 1
done

# Step 9: Start mysqld in the foreground as the container's main process.
# Replica-only flags are baked into the args here (rather than passed via
# the StatefulSet's args:) because they're conditional on MYSQL_ROLE.
#
# The official mysql image runs mysqld via gosu to drop from root to the
# mysql user. We replicate that here so file ownership is consistent
# with the master path. gosu is in the official image at
# /usr/local/bin/gosu.
log "Starting mysqld in foreground (replica mode)..."
exec /usr/local/bin/gosu mysql mysqld \
    --server-id="${SERVER_ID}" \
    --log-bin=mysql-bin \
    --gtid-mode=ON \
    --enforce-gtid-consistency=ON \
    --binlog-format=ROW \
    --read-only=ON \
    --super-read-only=ON \
    --socket=/var/run/mysqld/mysqld.sock \
    --pid-file=/var/run/mysqld/mysqld.pid \
    "$@"