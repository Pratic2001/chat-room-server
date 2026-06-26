#!/usr/bin/env bash
# fix_mysql_repl.sh
# -----------------------------------------------------------------------------
# Repair a stuck MySQL replica in the chatroom k8s cluster.
#
# This is the runbook-driven response to a `Replica SQL for channel '':
# Worker 1 failed executing transaction ... Error_code: MY-001396` line in
# `kubectl logs mysql-1` — the replica's applier thread aborted on a single
# bad event (most often an `ALTER USER` replayed from the master's binlog,
# e.g. from `99-grants.sql`). The pod stays `1/1 Running` (the IO thread
# is fine) but `Seconds_Behind_Master` grows without bound.
#
# Subcommands:
#
#   status                  Print SHOW REPLICA STATUS\G, parsed. The default
#                           if no subcommand is given. Use this first.
#
#   skip [--dry-run]        Stop the SQL thread, advance the in-memory skip
#                           counter by 1, restart the SQL thread. This is
#                           the right fix for non-GTID-blocking errors and
#                           for single-statement skips where the offending
#                           event is one transactional unit (the common
#                           case for ALTER USER). Safe as long as the
#                           skipped event is idempotent (a CREATE USER,
#                           ALTER USER, etc. all are).
#
#   skip-gtid <uuid:tag> [--dry-run]
#                           GTID-aware skip: inject one empty transaction
#                           at the specified GTID so the replica's
#                           Executed_Gtid_Set advances past it. Use this
#                           when the offending transaction is part of a
#                           multi-statement binlog event and a single
#                           counter skip would skip too much. The GTID is
#                           the `:20` part of the error message
#                           (b11692f4-70d7-11f1-8f40-ceedec70d9b7:20 in
#                           the trigger error).
#
#   reset [--dry-run]       The nuclear option: STOP REPLICA; RESET REPLICA;
#                           CHANGE REPLICATION SOURCE TO ... SOURCE_AUTO_POSITION=1;
#                           START REPLICA;. Re-establishes the channel
#                           from scratch using the credentials baked into
#                           `app/.env.runtime`. Use this when skip/skip-gtid
#                           loops on the same transaction or the relay log
#                           has been corrupted by repeated partial applies.
#
# All destructive subcommands require a `--yes` flag (or `-y`) past an
# interactive prompt, so a stray tab-completion can't accidentally reset
# production replication. `--dry-run` skips the prompt and prints the SQL
# without executing.
#
# Usage:
#   ./scripts/fix_mysql_repl.sh status                       # safe
#   ./scripts/fix_mysql_repl.sh skip --dry-run               # see what it would do
#   ./scripts/fix_mysql_repl.sh skip --yes
#   ./scripts/fix_mysql_repl.sh skip-gtid b11692f4-...:20 --yes
#   ./scripts/fix_mysql_repl.sh reset --yes
#
# The script refuses to operate on `mysql-0` (the master); passing it as
# a pod name exits non-zero. It also verifies that the target pod is a
# replica (not the master) by inspecting its role before any change.
# -----------------------------------------------------------------------------

set -euo pipefail

# -----------------------------------------------------------------------------
# Constants & helpers
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC2034  # sourced for color helpers only
SOURCED_RANDOM=0
if [[ -f "$SCRIPT_DIR/_random_password.sh" ]]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/_random_password.sh"
    SOURCED_RANDOM=1
fi

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "fix-mysql-repl" "$*" >&2; }
warn() { printf '\033[1;33m[%s]\033[0m %s\n' "fix-mysql-repl" "$*" >&2; }
fail() { printf '\033[1;31m[%s]\033[0m %s\n' "fix-mysql-repl" "$*" >&2; exit 1; }

usage() {
    # Print everything between the second line (after the shebang) and the
    # first "----" separator — that's the header comment block. Strip the
    # leading "# " (or "#") so the output reads as plain text. Avoids the
    # BSD-vs-GNU sed `//!p` portability trap.
    awk '
        NR > 1 && /^-{10,}/ { exit }
        NR > 1 { sub(/^# ?/, ""); print }
    ' "$0"
    exit "${1:-0}"
}

# -----------------------------------------------------------------------------
# Pre-flight
# -----------------------------------------------------------------------------
command -v kubectl >/dev/null 2>&1 || fail "kubectl not found in PATH."

# Resolve namespace: prefer -n flag, else default to 'chatroom' (the only
# namespace this project uses — see k8s/00-namespace.yaml).
NAMESPACE="chatroom"
POD=""
SUBCMD=""
DRY_RUN=0
ASSUME_YES=0
GTID_ARG=""
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage 0
            ;;
        -n|--namespace)
            NAMESPACE="$2"; shift 2 ;;
        --namespace=*)
            NAMESPACE="${1#*=}"; shift ;;
        -p|--pod)
            POD="$2"; shift 2 ;;
        --pod=*)
            POD="${1#*=}"; shift ;;
        --dry-run)
            DRY_RUN=1; shift ;;
        -y|--yes)
            ASSUME_YES=1; shift ;;
        status|skip|skip-gtid|reset|grants)
            SUBCMD="$1"; shift
            # Collect remaining positional args (used by skip-gtid).
            while [[ $# -gt 0 && "$1" != -* ]]; do
                EXTRA_ARGS+=("$1"); shift
            done
            ;;
        *)
            fail "Unknown argument: $1 (try --help)"
            ;;
    esac
done

[[ -n "$SUBCMD" ]] || { SUBCMD="status"; }
[[ -n "$POD" ]] || fail "Missing --pod (e.g. --pod mysql-1). The script targets one replica at a time."

# Refuse to run on the master. The replica path won't ever be on mysql-0
# in this project (mysql-0 is always the master per the StatefulSet), so
# this is also a sanity check that the operator picked the right pod.
[[ "$POD" != "mysql-0" ]] || fail "Refusing to operate on mysql-0 (that's the master). Target a replica: mysql-1, mysql-2, ..."

log "Target: pod=$POD  namespace=$NAMESPACE  subcommand=$SUBCMD"

# Confirm the pod exists and is Ready before touching anything.
if ! kubectl -n "$NAMESPACE" get pod "$POD" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null \
        | grep -q '^True$'; then
    warn "Pod $POD is not Ready. Replication recovery on a not-Ready replica is rarely what you want."
    warn "If the pod is CrashLoopBackOff from a bootstrap failure, see RUNBOOK.md §9.10.1 instead."
    if [[ $ASSUME_YES -eq 0 ]]; then
        read -rp "Continue anyway? [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]] || fail "Aborted."
    fi
fi

# -----------------------------------------------------------------------------
# Credential discovery
# -----------------------------------------------------------------------------
# The replica pod's mysqld knows MYSQL_ROOT_PASSWORD from the chatroom-mysql
# Secret (rendered into k8s/secrets.runtime.yaml). We need it locally only
# so the `kubectl exec mysql ... -p"$PW"` calls authenticate. We pull the
# raw value from the Secret, NOT the URL-encoded form, because the in-pod
# mysql client takes the cleartext password.
ROOT_PW="$(kubectl -n "$NAMESPACE" get secret chatroom-mysql \
    -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' | base64 -d)" \
    || fail "Could not read MYSQL_ROOT_PASSWORD from chatroom-mysql Secret."
[[ -n "$ROOT_PW" ]] || fail "chatroom-mysql Secret has no MYSQL_ROOT_PASSWORD."

# REPLICATION_PASSWORD is also sourced from the chatroom-mysql Secret. We
# only need it for the `reset` subcommand.
REPL_PW="$(kubectl -n "$NAMESPACE" get secret chatroom-mysql \
    -o jsonpath='{.data.REPLICATION_PASSWORD}' | base64 -d)" \
    || fail "Could not read REPLICATION_PASSWORD from chatroom-mysql Secret."

# Convenience: run `mysql -uroot -p"$ROOT_PW" ...` inside the pod. We pass
# the password via MYSQL_PWD env var, which the in-pod mysql client picks
# up automatically — avoids the warning about passwords on the command
# line and keeps the secret out of `kubectl describe pod` output.
#
# Transport: try the unix socket first, then fall back to TCP at
# 127.0.0.1. The socket path works on standalone `docker run mysql:8`
# and on chatroom replicas whose bootstrap installed the `auth_socket`
# plugin. On replicas where the bootstrap couldn't install it
# (replication_bootstrap.sh writes /tmp/replica-bootstrap-init.sql to
# `--init-file=` the background mysqld, but the foreground mysqld starts
# without one — see that script's comment at the exec), socket auth
# fails with `Plugin 'auth_socket' is not loaded`. TCP at 127.0.0.1
# always works on chatroom replicas because replication_bootstrap.sh
# reconciles root@% on every replica it boots (CREATE + ALTER USER), so
# `root@127.0.0.1` authenticates as root@%. Using TCP as a fallback keeps
# `status` / `skip` / `skip-gtid` / `reset` callable on a broken
# replica, so `grants` can then repair it on the socket path (which
# bypasses read-only, which TCP does too but the comment in cmd_grants
# spells out why the socket path is preferred for that one).
mysql_in_pod_socket() {
    kubectl -n "$NAMESPACE" exec -i "$POD" -- \
        env MYSQL_PWD="$ROOT_PW" mysql -uroot "$@"
}
mysql_in_pod_tcp() {
    kubectl -n "$NAMESPACE" exec -i "$POD" -- \
        env MYSQL_PWD="$ROOT_PW" mysql -uroot -h 127.0.0.1 "$@"
}
mysql_in_pod() {
    if mysql_in_pod_socket -e "SELECT 1" >/dev/null 2>&1; then
        mysql_in_pod_socket "$@"
    else
        mysql_in_pod_tcp "$@"
    fi
}

# -----------------------------------------------------------------------------
# Pre-flight: confirm the target is actually a replica (not the master)
# -----------------------------------------------------------------------------
ROLE="$(mysql_in_pod -N -B -e "SELECT IF(@@read_only, 'replica', 'master');" 2>/dev/null \
    | tr -d '[:space:]')" || fail "Could not query @@read_only on $POD — is mysqld running?"
if [[ "$ROLE" != "replica" ]]; then
    fail "$POD has @@read_only=0, which means it's the master, not a replica. Aborting."
fi
log "Confirmed $POD is a replica (@@read_only=1)."

# Detect MySQL version so we pick REPLICA (8.0.22+) vs SLAVE keywords.
MYSQL_VERSION="$(mysql_in_pod -N -B -e "SELECT VERSION();")"
MYSQL_MAJOR="$(printf '%s' "$MYSQL_VERSION" | cut -d. -f1)"
MYSQL_MINOR="$(printf '%s' "$MYSQL_VERSION" | cut -d. -f2)"
if [[ "$MYSQL_MAJOR" -gt 8 || ( "$MYSQL_MAJOR" -eq 8 && "$MYSQL_MINOR" -ge 22 ) ]]; then
    USE_REPLICA_KEYWORDS=1
    log "MySQL $MYSQL_VERSION — using REPLICA keyword family."
else
    USE_REPLICA_KEYWORDS=0
    warn "MySQL $MYSQL_VERSION — pre-8.0.22, falling back to SLAVE keyword family."
fi

# Pick the right keyword pair based on version.
if [[ $USE_REPLICA_KEYWORDS -eq 1 ]]; then
    SHOW_STATUS_CMD="SHOW REPLICA STATUS"
    STOP_CMD="STOP REPLICA"
    START_CMD="START REPLICA"
    RESET_CMD="RESET REPLICA"
    CHANGE_CMD_PREFIX="CHANGE REPLICATION SOURCE TO"
    CHANGE_AUTO_KW="SOURCE_AUTO_POSITION"
else
    SHOW_STATUS_CMD="SHOW SLAVE STATUS"
    STOP_CMD="STOP SLAVE"
    START_CMD="START SLAVE"
    RESET_CMD="RESET SLAVE"
    CHANGE_CMD_PREFIX="CHANGE MASTER TO"
    CHANGE_AUTO_KW="MASTER_AUTO_POSITION"
fi

# -----------------------------------------------------------------------------
# Subcommand: status
# -----------------------------------------------------------------------------
cmd_status() {
    log "Reading $SHOW_STATUS_CMD\\G from $POD..."
    echo
    # Show only the most actionable fields. The full output is verbose and
    # contains hex GTID sets that obscure what matters for triage.
    mysql_in_pod -e "$SHOW_STATUS_CMD\\G" \
        | grep -E 'Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master|Last_IO_Error|Last_SQL_Error|Last_IO_Error_Timestamp|Last_SQL_Error_Timestamp|Master_Log_File|Read_Master_Log_Pos|Relay_Master_Log_File|Exec_Master_Log_Pos|Replica_IO_State|Source_Log_File|Read_Source_Log_Pos|Relay_Source_Log_File|Exec_Source_Log_Pos|Channel_Name' \
        || true
    echo
    log "GTID state on the replica:"
    mysql_in_pod -e "SELECT @@GLOBAL.GTID_EXECUTED AS executed, @@GLOBAL.GTID_PURGED AS purged;"
}

# -----------------------------------------------------------------------------
# Subcommand: skip
# -----------------------------------------------------------------------------
cmd_skip() {
    [[ ${#EXTRA_ARGS[@]} -eq 0 ]] || fail "'skip' takes no positional arguments (got: ${EXTRA_ARGS[*]})"

    if [[ $ASSUME_YES -eq 0 && $DRY_RUN -eq 0 ]]; then
        warn "This will $STOP_CMD, advance sql_replica_skip_counter by 1, and $START_CMD."
        warn "Safe only if the skipped event is idempotent (most ALTER USER / CREATE USER / GRANT are)."
        read -rp "Proceed? [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]] || fail "Aborted."
    fi

    # The skip counter is a session variable, but its effect is global
    # (only meaningful on a stopped SQL thread, with no concurrent applier
    # to race). Setting it after STOP REPLICA / STOP SLAVE is the documented
    # sequence — see the MySQL refman "Skipping Transactions".
    local sql="
        $STOP_CMD;
        SET GLOBAL sql_replica_skip_counter = 1;
        $START_CMD;
    "

    if [[ $DRY_RUN -eq 1 ]]; then
        log "[dry-run] Would execute on $POD:"
        echo "----- BEGIN SQL -----"
        printf '%s\n' "$sql"
        echo "----- END SQL -----"
        return 0
    fi

    log "Applying skip on $POD..."
    mysql_in_pod -e "$sql"
    log "Skip applied. New state:"
    cmd_status
}

# -----------------------------------------------------------------------------
# Subcommand: skip-gtid <uuid:tag>
# -----------------------------------------------------------------------------
cmd_skip_gtid() {
    [[ ${#EXTRA_ARGS[@]} -eq 1 ]] || fail "'skip-gtid' requires exactly one argument: <uuid:tag> (e.g. b11692f4-70d7-11f1-8f40-ceedec70d9b7:20)"
    local gtid="${EXTRA_ARGS[0]}"
    # Light validation — uuid is 8-4-4-4-12 hex, then ':', then digits.
    if ! [[ "$gtid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}:[0-9]+$ ]]; then
        fail "Argument '$gtid' is not a valid <uuid:tag> GTID."
    fi

    if [[ $ASSUME_YES -eq 0 && $DRY_RUN -eq 0 ]]; then
        warn "This will inject an empty transaction at GTID '$gtid' on $POD and resume replication."
        warn "Use this when the offending transaction is part of a multi-event group and a single"
        warn "counter skip would lose too much. The GTID comes from the 'Error_code: MY-001396'"
        warn "line in the replica's error log — the part after the source UUID colon."
        read -rp "Proceed? [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]] || fail "Aborted."
    fi

    # The pattern: STOP REPLICA; SET GTID_NEXT='<uuid:tag>'; BEGIN; COMMIT;
    # SET GTID_NEXT='AUTOMATIC'; START REPLICA. This is documented in the
    # MySQL refman "Skipping Transactions With GTIDs" — the empty
    # transaction records the GTID in the Executed_Gtid_Set so the applier
    # can move past it on the next iteration.
    local sql="
        $STOP_CMD;
        SET GTID_NEXT='$gtid';
        BEGIN;
        COMMIT;
        SET GTID_NEXT='AUTOMATIC';
        $START_CMD;
    "

    if [[ $DRY_RUN -eq 1 ]]; then
        log "[dry-run] Would execute on $POD:"
        echo "----- BEGIN SQL -----"
        printf '%s\n' "$sql"
        echo "----- END SQL -----"
        return 0
    fi

    log "Injecting empty transaction at $gtid on $POD..."
    mysql_in_pod -e "$sql"
    log "GTID skip applied. New state:"
    cmd_status
}

# -----------------------------------------------------------------------------
# Subcommand: reset
# -----------------------------------------------------------------------------
cmd_reset() {
    [[ ${#EXTRA_ARGS[@]} -eq 0 ]] || fail "'reset' takes no positional arguments (got: ${EXTRA_ARGS[*]})"

    # Resolve the master's hostname the same way the bootstrap script does:
    # the headless service resolves to mysql-0.mysql-headless. That's where
    # CHANGE MASTER TO points so the replica pulls from the master pod
    # directly (port-forward style). For a k8s Service-based master
    # (mysql.chatroom.svc), the bootstrap uses the Service DNS so failovers
    # survive — match that here too.
    #
    # Read MYSQL_HOST from the cluster's ConfigMap (rendered by
    # build_images.sh into k8s/secrets.runtime.yaml as
    # chatroom-app → MYSQL_HOST). It's typically 'mysql' (the Service).
    local master_host
    master_host="$(kubectl -n "$NAMESPACE" get cm chatroom-app \
        -o jsonpath='{.data.MYSQL_HOST}' 2>/dev/null || true)"
    if [[ -z "$master_host" ]]; then
        # Fall back to the headless service so the replica addresses
        # mysql-0 directly. This is the same target the in-container
        # bootstrap uses.
        master_host="mysql-0.mysql-headless"
    fi
    log "Master host for CHANGE ... TO: $master_host"

    if [[ $ASSUME_YES -eq 0 && $DRY_RUN -eq 0 ]]; then
        warn "This will $RESET_CMD and re-establish the replication channel from scratch."
        warn "It does NOT re-clone the data directory; the replica will replay any binlog events"
        warn "between the last-applied GTID and the master's current position. If that's a lot,"
        warn "the replica will catch up over a few seconds-to-minutes depending on write rate."
        warn "If you need a full re-clone, see RUNBOOK.md §9.10.1 (delete pod + PVC)."
        read -rp "Proceed? [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]] || fail "Aborted."
    fi

    local repl_user="repl"
    local sql="
        $STOP_CMD;
        $RESET_CMD;
        $CHANGE_CMD_PREFIX
            SOURCE_HOST='$master_host',
            SOURCE_USER='$repl_user',
            SOURCE_PASSWORD='$REPL_PW',
            ${CHANGE_AUTO_KW}=1;
        $START_CMD;
    "

    if [[ $DRY_RUN -eq 1 ]]; then
        log "[dry-run] Would execute on $POD:"
        echo "----- BEGIN SQL -----"
        printf '%s\n' "$sql"
        echo "----- END SQL -----"
        return 0
    fi

    log "Resetting replication channel on $POD..."
    mysql_in_pod -e "$sql"
    log "Replication channel re-established. New state:"
    cmd_status
}

# -----------------------------------------------------------------------------
# Subcommand: grants
# -----------------------------------------------------------------------------
# Reconcile root@% on a replica to MYSQL_ROOT_PASSWORD from the
# chatroom-mysql Secret. The chatroom-app's read engine connects as
# root from a k8s pod IP, so it needs root@%. Replicas can end up
# without it if the dump-load snapshot (taken by replication_bootstrap.sh
# at first boot) happened before the master applied its own
# 99-grants.sql — see mysql/init/99-grants.sql.template for the
# master-side ordering. Running this on every replica after deploy
# guarantees the read path works regardless of dump-timing race.
#
# Idempotent: re-running on a replica that already has the right
# grant writes the same hash and is a no-op for the user-facing auth
# path. Safe under the replica's --read-only / --super-read-only
# flags because we connect via the local unix socket as root, which
# bypasses session-level read-only the same way the official mysql
# entrypoint does during init.
cmd_grants() {
    [[ ${#EXTRA_ARGS[@]} -eq 0 ]] || fail "'grants' takes no positional arguments (got: ${EXTRA_ARGS[*]})"

    if [[ $ASSUME_YES -eq 0 && $DRY_RUN -eq 0 ]]; then
        warn "This will ALTER USER 'root'@'%' IDENTIFIED BY <MYSQL_ROOT_PASSWORD> on $POD."
        warn "It's idempotent: if root@% is already correct, this is a no-op write to the binlog."
        read -rp "Proceed? [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]] || fail "Aborted."
    fi

    local sql="
        ALTER USER 'root'@'%' IDENTIFIED BY '${ROOT_PW}';
        FLUSH PRIVILEGES;
    "

    if [[ $DRY_RUN -eq 1 ]]; then
        log "[dry-run] Would execute on $POD:"
        echo "----- BEGIN SQL -----"
        printf '%s\n' "$sql"
        echo "----- END SQL -----"
        return 0
    fi

    log "Reconciling root@% on $POD..."
    mysql_in_pod -e "$sql"
    log "Done. Current grants:"
    mysql_in_pod -e "SELECT user, host FROM mysql.user WHERE user='root';"
}

# -----------------------------------------------------------------------------
# Dispatch
# -----------------------------------------------------------------------------
case "$SUBCMD" in
    status)      cmd_status ;;
    skip)        cmd_skip ;;
    skip-gtid)   cmd_skip_gtid ;;
    reset)       cmd_reset ;;
    grants)      cmd_grants ;;
    *)
        fail "Unknown subcommand: $SUBCMD (try --help)"
        ;;
esac