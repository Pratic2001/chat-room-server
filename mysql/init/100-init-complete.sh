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
# script sidesteps that — the entrypoint invokes executable .sh files
# in init.d/ (via `docker_process_init_files`) with $MYSQL_DATADIR in
# scope (exported by docker_setup_env). Writing a sentinel file from
# bash is portable, doesn't depend on any MySQL server setting, and
# the datadir is owned by the mysql user (which is who runs this
# script at init time), so the file lands with the right perms.
#
# The sentinel is a one-byte file containing '1'. Its presence is the
# only signal the bootstrap script checks for, so its contents don't
# matter. Filename starts with `.` so it doesn't collide with any
# MySQL/MariaDB table-space file (those are unhidden).
set -eu

# Belt-and-braces: refuse to run outside the entrypoint's expected
# context. $MYSQL_DATADIR is set by docker_setup_env before init
# scripts run. If it's unset we have no safe place to write the
# sentinel — fail loud so the operator notices (the bootstrap script
# will treat the missing sentinel as "broken init" and try to
# recover, which is exactly the right response to "we never wrote it").
: "${MYSQL_DATADIR:?MYSQL_DATADIR is unset — refusing to write sentinel}"

SENTINEL="${MYSQL_DATADIR}/.chatroom_init_complete"
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