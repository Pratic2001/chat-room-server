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
    DERIVED_SERVER_ID="$((100 + 0))"
    SERVER_ID="${MYSQL_SERVER_ID:-$DERIVED_SERVER_ID}"
elif [[ "$POD_NAME_VALUE" =~ ^mysql-([0-9]+)$ ]]; then
    MYSQL_ROLE="replica"
    DERIVED_SERVER_ID="$((100 + ${BASH_REMATCH[1]}))"
    SERVER_ID="${MYSQL_SERVER_ID:-$DERIVED_SERVER_ID}"
else
    # Standalone `docker run` (no StatefulSet hostname). Treat as master
    # with the default server-id — useful for local debugging.
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
# schema, so the local repl user and root user (which we just initialized
# with no password) get overwritten by the master's values. After this
# step, root@localhost has the master's password and requires it for
# fresh connections — so the post-dump mysql / mysqladmin calls below
# use --password=$MYSQL_ROOT_PASSWORD.
#
# The dump itself is piped through `mysql --user=root` without a password
# because that connection starts before the dump's `ALTER USER` statement
# lands, and on the freshly-initialized server root@localhost uses
# auth_socket (matches the OS root user — same as the init).
log "Cloning master via mysqldump..."
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
    | mysql --user=root --socket=/var/run/mysqld/mysqld.sock; then
    fail "Initial dump-load failed; check that the master is healthy and credentials match."
fi
log "Dump-load complete."

# Helper: run a mysql client command against the local server with the
# post-dump root credentials. Defined after the dump-load because before
# the dump, root@localhost uses auth_socket (no password needed); after,
# it requires MYSQL_ROOT_PASSWORD.
mysql_local() {
    mysql --user=root --password="${MYSQL_ROOT_PASSWORD}" --socket=/var/run/mysqld/mysqld.sock "$@"
}
mysqladmin_local() {
    mysqladmin --user=root --password="${MYSQL_ROOT_PASSWORD}" --socket=/var/run/mysqld/mysqld.sock "$@"
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
SLAVE_STATUS="$(mysql_local -Nse 'SHOW SLAVE STATUS\G' 2>&1)"
if ! grep -q "Slave_IO_Running: Yes" <<<"$SLAVE_STATUS"; then
    fail "Slave_IO_Running is not Yes. SHOW SLAVE STATUS:\n${SLAVE_STATUS}"
fi
if ! grep -q "Slave_SQL_Running: Yes" <<<"$SLAVE_STATUS"; then
    fail "Slave_SQL_Running is not Yes. SHOW SLAVE STATUS:\n${SLAVE_STATUS}"
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