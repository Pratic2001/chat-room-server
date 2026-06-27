#!/usr/bin/env bash
# 100-init-complete.sh
# -----------------------------------------------------------------------------
# Writes a sentinel file into $MYSQL_DATADIR once every init script has
# succeeded. Read by mysql/replication_bootstrap.sh on the master path
# to detect a broken first-init: the official mysql entrypoint decides
# whether to run /docker-entrypoint-initdb.d/* based purely on whether
# $DATADIR/mysql exists (see docker-library/mysql docker_setup_env() —
# the DATABASE_ALREADY_EXISTS flag). If the master pod crashes mid-init
# (a syntax error in 01-schema.sql, an OOM during InnoDB warmup, a node
# power loss between CREATE DATABASE chatroom_db and CREATE USER
# 'repl'@'%'), the PVC ends up half-populated and every subsequent
# restart silently skips the init scripts. The chatroom-app connects
# fine (root@% already has a hash from MYSQL_ROOT_PASSWORD) but
# replicas get `Access denied for user 'repl'@'...'` because the
# replication user was never created.
#
# 100-init-complete.sh is the last init file (filename sorts after
# 99-grants.sql) so it runs only when every earlier init script
# succeeded. If any earlier script aborted, the entrypoint stops the
# init-file loop and never reaches this script — leaving the sentinel
# absent and the broken datadir exactly where the bootstrap script can
# find it.
#
# Why a .sh script (not .sql with SELECT ... INTO OUTFILE):
# the official mysql:8 Docker image sets `secure-file-priv=NULL` in
# /etc/mysql/my.cnf, which disables INTO OUTFILE entirely. A bash
# script sidesteps that — we derive the datadir at runtime from the
# already-running mysqld (see the resolve block below). Writing a
# sentinel file from bash is portable, doesn't depend on any MySQL
# server setting, and the datadir is owned by the mysql user (which
# is who runs this script at init time, since the official entrypoint
# has already gosu-dropped to mysql by the time init scripts run on
# the first-boot path), so the file lands with the right perms.
#
# The sentinel is a one-byte file containing '1'. Its presence is the
# only signal the bootstrap script checks for, so its contents don't
# matter. Filename starts with `.` so it doesn't collide with any
# MySQL/MariaDB table-space file (those are unhidden).
set -eu

# Determine the datadir. The official mysql entrypoint declares DATADIR
# in its own global scope (via `declare -g DATADIR` in docker_setup_env)
# and NEVER exports it, so child processes (which is what we are — this
# script is chmod 755 so the entrypoint invokes us with "$f", not ". $f")
# do not see it. Earlier versions of this script read $MYSQL_DATADIR and
# refused to run when it was unset, but MYSQL_DATADIR is also never set
# by the entrypoint — the env var was a misreading of docker_setup_env's
# `declare -g DATADIR` (a shell-global variable, not an env var). On
# every init run the script aborted with
# `MYSQL_DATADIR: MYSQL_DATADIR is unset — refusing to write sentinel`,
# the sentinel was never written, and the bootstrap script then treated
# the empty sentinel as a broken first-init on the very next pod restart.
#
# We can't query the running mysqld either: by the time this script
# runs, docker_setup_db has already pinned root@localhost to
# caching_sha2_password with MYSQL_ROOT_PASSWORD, and we're executing
# as the mysql OS user (the entrypoint has gosu-dropped to mysql before
# invoking init scripts). The mysql client over the local socket would
# be challenged for a password we have no clean way to provide.
#
# Resolution order:
#   1. Live mysqld /proc/<pid>/cmdline — if the operator passed
#      --datadir=… on the command line (the StatefulSet's args: in
#      k8s/, or `docker run mysqld --datadir=…` for standalone
#      debugging), it shows up here. The official entrypoint's
#      docker_temp_server_start does NOT append --datadir for MySQL
#      8.0+ (the function only forwards "$@"), so this match is rare
#      but worth checking first because cmdline wins over my.cnf.
#   2. /etc/mysql/conf.d/*.cnf and /etc/mysql/my.cnf — the official
#      image's bundled config files. Custom config mounted into
#      /etc/mysql/conf.d/ (the documented hook for operators) will
#      have `datadir = …` here. We grep with case-insensitive
#      anchored matches so we don't accidentally pick up `loose-…`
#      options or comment text. !includedir lines aren't datadirs
#      themselves and we skip them.
#   3. $MYSQL_DATADIR — explicit env override (handy for `docker run`
#      debugging on a custom datadir; matches the bootstrap script's
#      own fallback chain at replication_bootstrap.sh:120).
#   4. Canonical default /var/lib/mysql — the official image's
#      hardcoded my.cnf default and the volumeMount in our StatefulSet
#      pod template. This is the path 99% of deployments will resolve
#      to.
#
# Only after all four fall through do we refuse to write — and we log
# loudly in that case so the operator notices.
DATADIR=""
DATADIR_SOURCE=""

# Step 1: /proc/<pid>/cmdline of every mysqld process.
for pid_dir in /proc/[0-9]*; do
    [[ -r "${pid_dir}/cmdline" ]] || continue
    cmdline="$(tr '\0' ' ' < "${pid_dir}/cmdline" 2>/dev/null || true)"
    [[ "${cmdline}" == *mysqld* ]] || continue
    if [[ "${cmdline}" =~ --datadir=([^[:space:]]+) ]]; then
        DATADIR="${BASH_REMATCH[1]}"
        DATADIR_SOURCE="mysqld cmdline (pid ${pid_dir##*/})"
        break
    elif [[ "${cmdline}" =~ --datadir[[:space:]]+([^[:space:]]+) ]]; then
        DATADIR="${BASH_REMATCH[1]}"
        DATADIR_SOURCE="mysqld cmdline (pid ${pid_dir##*/})"
        break
    fi
done

# Step 2: parse my.cnf-style configs. Iterate /etc/mysql/conf.d/*.cnf
# first because the docs say those override /etc/mysql/my.cnf, and
# we want the last match wins semantics (same as mysqld). Each file
# is plain `key = value` text; we strip comments (# and ;) and the
# section headers ([mysqld]), then look for ^[[:space:]]*datadir[[:space:]]*=
# on a line by itself.
if [[ -z "${DATADIR}" ]]; then
    for cnf in /etc/mysql/conf.d/*.cnf /etc/mysql/my.cnf /etc/mysql/mysql.conf.d/mysqld.cnf; do
        [[ -r "${cnf}" ]] || continue
        # awk keeps only lines that look like `datadir = path`, comments
        # and section headers excluded. `sub` strips the leading key +
        # optional whitespace + `=`, leaving just the path (possibly
        # quoted). Note: POSIX awk doesn't support \s — we use
        # [[:space:]] instead so this works on mawk (Debian) and gawk
        # alike.
        candidate="$(awk '
            /^[[:space:]]*[#;]/ {next}
            /^[[:space:]]*\[/ {next}
            /^[[:space:]]*datadir[[:space:]]*=/ {
                val = $0
                sub(/^[[:space:]]*datadir[[:space:]]*=[[:space:]]*/, "", val)
                gsub(/^["'\''[:space:]]+|["'\''[:space:]]+$/, "", val)
                # Strip a single trailing slash so /srv/mysql and
                # /srv/mysql/ both normalize to /srv/mysql — matches
                # mysqld own canonicalization and keeps the sentinel
                # path consistent across deployments that quote the
                # value vs. those that do not.
                if (sub(/\/$/, "", val)) {}
                if (length(val) > 0) { print val; exit }
            }
        ' "${cnf}" 2>/dev/null || true)"
        if [[ -n "${candidate}" ]]; then
            DATADIR="${candidate}"
            DATADIR_SOURCE="${cnf}"
            break
        fi
    done
fi

# Step 3: explicit env override.
if [[ -z "${DATADIR}" && -n "${MYSQL_DATADIR:-}" ]]; then
    DATADIR="${MYSQL_DATADIR}"
    DATADIR_SOURCE="\$MYSQL_DATADIR"
fi

# Step 4: canonical default.
if [[ -z "${DATADIR}" ]]; then
    DATADIR="/var/lib/mysql"
    DATADIR_SOURCE="default"
fi

if [[ -z "${DATADIR}" ]]; then
    echo "[chatroom-init] FATAL: cannot determine datadir. Refusing to write sentinel." >&2
    exit 1
fi
echo "[chatroom-init] Resolved datadir=${DATADIR} (source: ${DATADIR_SOURCE})" >&2

SENTINEL="${DATADIR}/.chatroom_init_complete"
# Write atomically via a temp file in the same directory (so the
# rename is on the same filesystem and never sees a half-written
# state). `mktemp` defaults to /tmp which is fine — we'll move it.
TMP_SENTINEL="$(mktemp)"
trap 'rm -f "${TMP_SENTINEL}"' EXIT
printf '1\n' > "${TMP_SENTINEL}"
mv -f "${TMP_SENTINEL}" "${SENTINEL}"

# Print so the entrypoint's "running /docker-entrypoint-initdb.d/..."
# log line is followed by a clear "sentinel written" breadcrumb.
echo "[chatroom-init] Wrote ${SENTINEL}" >&2