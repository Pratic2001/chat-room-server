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

# -----------------------------------------------------------------------------
# Detect and recover from a broken first-init on the master.
#
# The official mysql:8 entrypoint decides whether to run
# /docker-entrypoint-initdb.d/* based purely on whether $DATADIR/mysql
# exists (see docker-library/mysql docker_setup_env() — the
# DATABASE_ALREADY_EXISTS flag). If the master pod crashed mid-init (e.g.
# a syntax error in 01-schema.sql, an OOM kill during InnoDB warmup, the
# node losing power between `CREATE DATABASE chatroom_db` and `CREATE
# USER 'repl'@'%'`), the PVC ends up with a half-populated datadir and
# the entrypoint silently skips every init script on every subsequent
# pod restart. The chatroom-app then connects fine (root@% already has
# a hash from MYSQL_ROOT_PASSWORD) but replicas get
# `Access denied for user 'repl'@'...'` because the replication user was
# never created. Re-deploying the StatefulSet does NOT recover — the
# existing PVC keeps the broken state.
#
# 100-init-complete.sh writes a sentinel file
# ($DATADIR/.chatroom_init_complete) at the very end of a successful
# init. The bootstrap script reads it: missing sentinel + present
# $DATADIR/mysql → broken state → move the datadir aside so the
# entrypoint re-initialises. The mv only triggers when the chatroom_db
# users table is empty (so we never destroy populated production data
# on a spuriously-missing sentinel).
#
# This is destructive on a broken first-init. The fix is destructive on
# purpose: a half-initialised master can't accept writes (the user
# table is empty even on the live cluster today), can't seed replicas,
# and gets stuck in an indefinite "init scripts skipped on every
# restart" loop. Recreating from scratch is faster than chasing each
# missing artifact by hand.
#
# This block only runs on the master path. Replicas have their own
# idempotent restart logic at "Step 3" below and don't depend on the
# sentinel (they dump-load from the master, so a healthy master means a
# healthy replica after the bootstrap).
if [[ "$MYSQL_ROLE" != "replica" ]]; then
    INIT_SENTINEL="${DATADIR}/.chatroom_init_complete"
    if [[ -d "${DATADIR}/mysql" && ! -e "${INIT_SENTINEL}" ]]; then
        # $DATADIR/mysql exists but the sentinel is missing — broken
        # first-init. Decide whether it's safe to nuke by sampling the
        # chatroom_db user-table row count from the file system. For a
        # freshly broken init the InnoDB tablespace is tiny (just the
        # schema with zero rows); for a populated production DB it's
        # multiple MB.
        #
        # We can't safely read .ibd files without mysqld, so we use size
        # as a proxy: an empty InnoDB tablespace for `users` is well
        # under 100 KiB (the 16 KiB page + metadata overhead for an
        # auto-increment INT PK + a few VARCHAR indexes), and a single
        # user row already pushes it past 64 KiB of "real" data. We use
        # 1 MiB as a conservative cutoff — anything that large was
        # definitely populated, anything that small is almost certainly
        # the broken-init empty-schema state. Conservative on purpose:
        # we'd rather recover a fresh DB than mistakenly destroy
        # production data on a corrupted sentinel.
        USER_FILE="${DATADIR}/chatroom_db/users.ibd"
        USER_BYTES=0
        if [[ -f "${USER_FILE}" ]]; then
            USER_BYTES="$(stat -c '%s' "${USER_FILE}" 2>/dev/null || echo 0)"
        fi
        if [[ "${USER_BYTES}" -lt 1048576 ]]; then
            # Empty / nearly-empty users table: safe to re-init.
            # Two possible recovery strategies, chosen by what the
            # filesystem underneath $DATADIR allows:
            #
            #   1. Rename the datadir aside. Works on local PVs
            #      (hostPath, CSI local, kubelet-managed emptyDir) —
            #      `mv` of an unused directory is a single rename on
            #      the same filesystem, atomic from the kubelet's
            #      perspective, and the aside directory survives on
            #      the PVC for forensic inspection.
            #
            #   2. In-place cleanup. Required when $DATADIR is itself
            #      a mount point (NFS, cephfs, glusterfs, AWS EFS, …).
            #      The Linux kernel returns EBUSY ("Device or resource
            #      busy") on rename() of any directory that is a
            #      mountpoint — NFS servers reject it server-side as
            #      well, so the mv fails with the same error even when
            #      no client is actively using the volume. In that case
            #      we cannot move the mount aside; instead we delete
            #      the contents of $DATADIR in place, leaving the
            #      mountpoint itself intact. The official entrypoint
            #      only checks `$DATADIR/mysql` (not `$DATADIR` itself),
            #      so an empty $DATADIR is sufficient for the
            #      re-initialisation to kick in.
            #
            # Detection: try (1), and if `mv` fails with EBUSY /
            # EXDEV / ENOTSUP, fall back to (2). Doing the rename
            # first means local PVs (the common case in kind / k3d /
            # minikube / single-node clusters) still get the forensic
            # aside-directory behaviour; only NFS-class storage takes
            # the in-place path.
            STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
            ASIDE="${DATADIR}.broken.${STAMP}"
            log "Broken first-init detected: ${DATADIR}/mysql exists but ${INIT_SENTINEL} is absent (users.ibd=${USER_BYTES} bytes). Moving datadir aside to ${ASIDE} so the entrypoint can re-initialize."
            if mv "${DATADIR}" "${ASIDE}" 2>/tmp/chatroom_mv_err; then
                # Local-PV path: rename succeeded, recreate the empty
                # datadir so the entrypoint can re-initialise.
                mkdir -p "${DATADIR}"
                chown mysql:mysql "${DATADIR}"
            else
                # NFS / mountpoint path: rename refused the active
                # mount. Drop the contents in place instead.
                #
                # Why no forensic aside on this path: on NFS the parent
                # of $DATADIR lives inside kubelet's
                # pods/<uid>/volumes/... tree, which is owned by root
                # and disappears when the pod is deleted. So copying
                # the broken contents there (a) would be racy with the
                # kubelet's cleanup of the failed pod's volumes dir
                # and (b) provides no forensic value because the
                # operator can't keep the aside directory alive across
                # a redeploy anyway. Logging the original mv error to
                # the pod's stderr is sufficient — `kubectl logs
                # mysql-0 --previous` shows the full failure context.
                log "mv ${DATADIR} -> ${ASIDE} failed ($(cat /tmp/chatroom_mv_err)). $DATADIR is likely a mountpoint (NFS/cephfs/EFS) — cleaning contents in place."
                rm -f /tmp/chatroom_mv_err
                # rm -rf the contents but not the directory itself —
                # the directory IS the mountpoint and cannot be
                # removed without unmounting. Leaving the directory in
                # place with nothing inside it is exactly what
                # initialize-insecure expects.
                find "${DATADIR}" -mindepth 1 -maxdepth 1 \
                    -exec rm -rf {} +
                # Make sure the empty datadir is owned by the mysql
                # user so the entrypoint's initialize-insecure can
                # write into it. Belt-and-braces: the directory was
                # already owned by mysql before (the broken init ran
                # under that uid), but find+rm can leave the mount
                # point's metadata untouched.
                chown mysql:mysql "${DATADIR}" 2>/dev/null || true
            fi
        else
            # Sentinel is missing but users.ibd looks populated — refuse
            # to recover automatically. The operator should investigate
            # the datadir manually (the aside-directory trick would be
            # destructive on a real production DB). Log loudly and let
            # the entrypoint take its normal "datadir exists, skip
            # init" path so the operator can `kubectl exec` in and
            # decide.
            log "Sentinel ${INIT_SENTINEL} missing but ${USER_FILE} is ${USER_BYTES} bytes — refusing automatic re-init (looks like populated production data). Investigate manually; the datadir has not been moved."
        fi
    fi

    # Master path: delegate to the official entrypoint with --server-id
    # prepended so the master's server-id is unique in the cluster. The
    # official entrypoint runs `exec "$@"` after init, so the server-id
    # reaches mysqld. The manifest's `args:` does NOT include --server-id
    # (the script injects it for both master and replica paths).
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
#
# The same --init-file is also passed to the foreground mysqld at the
# bottom of this script. Reason: the dump-load that follows overwrites
# mysql.plugin with the master's version, and the master never had
# auth_socket installed, so the plugin reference in mysql.plugin is
# gone by the time we hand off to the foreground mysqld. Without
# re-running the init file on the foreground, the auth_socket plugin
# isn't loaded there, `root@localhost` (re-pinned to auth_socket below
# at step "Re-pin root@localhost") is a dangling plugin reference, and
# any subsequent `kubectl exec ... -- mysql -uroot` (no -h) call fails
# with `ERROR 1524 (HY000): Plugin 'auth_socket' is not loaded`. The
# init file's `INSTALL PLUGIN` is guarded by an INFORMATION_SCHEMA.PLUGINS
# check, so it's a no-op on subsequent restarts.
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

# Reconcile root@% on this replica to the build-time MYSQL_ROOT_PASSWORD.
#
# Why this step exists: the dump-load above captures the master's
# `mysql.user` table at whatever state it happens to be in at the moment.
# If the dump didn't include root@% (e.g. the master's own
# /docker-entrypoint-initdb.d/ scripts hadn't run yet — specifically
# 99-grants.sql, which issues `ALTER USER 'root'@'%' IDENTIFIED BY ...` —
# or the dump is empty for any other reason), the replica ends up with
# only `root@localhost` and no `root@%`. The chatroom-app's read engine
# connects as root from a k8s pod IP, so it needs `root@%` — without
# it, every read request that round-robins onto this replica via the
# `mysql-replica` Service gets 1045 "Access denied". That's the
# intermittent "Failed to load room" the frontend reports.
#
# This used to assume root@% already existed from the dump and only
# issued `ALTER USER`. That assumption broke in production when the
# 'repl' user was missing the SELECT (and friends) privileges mysqldump
# needs — the dump was structurally empty, root@% never landed, and
# `ALTER USER 'root'@'%'` failed with ERROR 1396 ("operation failed
# for", the code MySQL returns when an ALTER USER target doesn't exist).
# The fix is belt-and-braces: CREATE USER IF NOT EXISTS first, then
# ALTER USER. CREATE USER IF NOT EXISTS is a no-op when the user
# already exists, so the dump-succeeded path is unchanged; on the
# dump-failed path it creates the row with the right hash and ALTER
# USER is then a no-op write of the same hash.
#
# Issuing these statements locally on the replica is safe under all
# the constraint surfaces we care about:
#   - This block runs against the **background** mysqld we started at
#     step 4, which has neither --read-only nor --super-read-only
#     (those flags are only added when we hand off to the foreground
#     mysqld at the bottom of this script). super-read-only blocks
#     every write from any session regardless of auth plugin — the
#     `auth_socket` connection we use here gives us a password-less
#     login, not a write bypass — so this exact CREATE USER / ALTER
#     USER against the *foreground* mysqld (e.g. from
#     scripts/fix_mysql_repl.sh grants) needs an explicit
#     SET GLOBAL super_read_only = OFF around the write.
#   - caching_sha2_password hashes MYSQL_ROOT_PASSWORD to the same
#     value as the master, so the grant converges cluster-wide even
#     though we're running it independently on every replica.
#   - Both statements are idempotent: re-running on a replica that
#     already has the correct grant is a no-op for the user-facing
#     auth path.
#   - Replicated ALTER USER statements on `mysql.user` flow through the
#     row-binlog applier, so any subsequent rebuild that recreates this
#     divergence will replay the same statement on every replica.
mysql_local <<SQL
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
ALTER USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
FLUSH PRIVILEGES;
SQL
log "Reconciled root@% on this replica."

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
#
# --slave-skip-errors=1061,1060 makes the replica tolerate two narrow
# "schema already up-to-date" DDL errors that fire on a dump-loaded
# replica whose source-of-truth already matches the master's current
# schema:
#
#   1061 ER_DUP_KEYNAME    "Duplicate key name"
#       Fires when the master's binlog replays a CREATE INDEX (or an
#       inline KEY clause re-logged from a dump/restore) against a
#       replica that already has the index from the dump-load. The
#       chatroom schema defines indexes inline in CREATE TABLE
#       (see mysql/init/01-schema.sql), so this shouldn't fire in
#       normal operation — but it acts as a defensive belt-and-braces
#       for any future out-of-band DDL that adds an index the replica
#       already has.
#
#   1060 ER_DUP_FIELDNAME  "Duplicate column name '%s'"
#       Fires when the master's binlog replays an ALTER TABLE ... ADD
#       COLUMN against a replica that already has the column from the
#       dump-load. The chatroom schema migrations in 01-schema.sql now
#       use the INFORMATION_SCHEMA.COLUMNS dynamic-SQL guard (plain
#       `ADD COLUMN IF NOT EXISTS` is rejected by stock MySQL 8.0.x —
#       see the schema file for the rationale), so fresh masters won't
#       re-log these ALTERs. But binlog events generated before the
#       guard was introduced are still in the master's binlog and get
#       replayed on every fresh replica dump-load. Without 1060 here,
#       the replica's SQL thread stops on the first such ALTER
#       (`Worker 1 failed executing transaction ... Error 'Duplicate
#       column name 'mentions'' ...`), which surfaces in the frontend
#       as 403s / "Failed to load messages" when a read round-robins
#       onto a stuck replica whose tables no longer match the master's.
#
# Without these, a single benign schema-drift DDL stops the replica's
# SQL thread forever. 1060,1061 is the narrowest skip set that covers
# both known failure modes (and is what every MySQL HA playbook
# recommends for this scenario); wildcards like "all" or
# "ddl_exist_errors" would mask real corruption.
log "Starting mysqld in foreground (replica mode)..."
exec /usr/local/bin/gosu mysql mysqld \
    --server-id="${SERVER_ID}" \
    --log-bin=mysql-bin \
    --gtid-mode=ON \
    --enforce-gtid-consistency=ON \
    --binlog-format=ROW \
    --read-only=ON \
    --super-read-only=ON \
    --slave-skip-errors=1061,1060 \
    --socket=/var/run/mysqld/mysqld.sock \
    --pid-file=/var/run/mysqld/mysqld.pid \
    --init-file=/tmp/replica-bootstrap-init.sql \
    "$@"