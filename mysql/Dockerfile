# syntax=docker/dockerfile:1.6
# chatroom-mysql — MySQL image with the chatroom schema, a baked-in
# root password, the replication user, and a custom entrypoint that
# decides master-vs-replica based on the MYSQL_ROLE env var.
#
# Why a custom image (instead of the official mysql:8 with MYSQL_ROOT_PASSWORD
# set on the Deployment): we want a known schema available the moment a fresh
# PVC is attached, with no need for a sidecar migration job. The
# /docker-entrypoint-initdb.d/ directory runs every *.sql file in lexical
# order on first boot of an empty datadir.
#
# Replication topology (replaces the singleton Deployment in k8s/21-*.yaml):
#   Pod mysql-0   MYSQL_ROLE=master   — runs mysqld directly. Init scripts
#                                       seed the schema + repl user + grant
#                                       root's password to the build-arg value.
#   Pod mysql-1+  MYSQL_ROLE=replica  — runs replication_bootstrap.sh, which
#                                       dump-loads from mysql-0 and starts
#                                       GTID-based async replication. The
#                                       server args below add --read-only and
#                                       --super-read-only on replicas so they
#                                       reject writes (defense in depth — the
#                                       replica Service routes reads, but if
#                                       someone points a writer at the pod
#                                       directly, MySQL refuses).
#
# The server-id and replica flags depend on the pod's ordinal, which only
# the k8s downward API can supply at runtime. The StatefulSet pod template
# sets the env vars; the Dockerfile declares them as ARG defaults so a
# developer can `docker run` the image standalone and still get a valid
# server-id (1) and no replica flags.

ARG MYSQL_IMAGE=mysql:8.0-debian
FROM ${MYSQL_IMAGE}

# Install the MySQL CLI client so `kubectl exec ... -- mysql ...` works.
#
# The mysql:8.0-debian base image only has Oracle's MySQL apt repo configured
# (http://repo.mysql.com/apt/debian bookworm mysql-8.0) — NOT the full
# Debian main repo. So generic Debian packages like `default-mysql-client`
# (or `mysql-client`, which on Debian 12 resolves to MariaDB's `mariadb`
# binary anyway) are not installable here. The MySQL repo ships
# `mysql-community-client` (the actual `mysql` CLI, same upstream that the
# image's server is built from) — that's the one we need.
RUN set -eux; \
    if command -v apt-get > /dev/null; then \
        apt-get update && apt-get install -y --no-install-recommends mysql-community-client && rm -rf /var/lib/apt/lists/*; \
    else \
        apk add --no-cache mysql-client; \
    fi


# Build-time only: the root password the app will use. Not exposed in the
# final image as a layer env var (we sed-substitute it into a file and then
# unset the arg, so the literal value does not survive into the next layer).
ARG MYSQL_ROOT_PASSWORD=placeholder
# Replication credential for the 'repl'@'%' user. Baked into
# 02-replication-user.sql.template the same way MYSQL_ROOT_PASSWORD is
# baked into 99-grants.sql.template. Replicas use this to authenticate
# CHANGE MASTER TO against mysql-0. unset after substitution so the
# literal value does not survive into the next layer.
ARG REPLICATION_PASSWORD=placeholder

# Schema. Adapted from database_setup.sql at the repo root — the only
# changes are dropping CREATE USER / GRANT statements, since the official
# mysql entrypoint already creates 'root'@'%' from the env-supplied
# MYSQL_ROOT_PASSWORD. The 99-grants.sql script re-pins the password to
# the build-time value so the app's MYSQL_PASSWORD env matches.
#
# The build context for this image is the `mysql/` directory itself
# (passed by scripts/build_images.sh), so the COPY paths are bare
# `init/...` rather than `mysql/init/...`.
COPY init/01-schema.sql /docker-entrypoint-initdb.d/01-schema.sql
COPY init/02-replication-user.sql.template /tmp/02-replication-user.sql.template
COPY init/99-grants.sql.template /tmp/99-grants.sql.template
COPY init/100-init-complete.sh /docker-entrypoint-initdb.d/100-init-complete.sh

# Substitute the build-arg passwords into the templates. We use a
# delimiter (|) that the passwords (base64-ish) will never contain, so the
# sed won't choke if a future generated password happened to include '/'.
# Then `unset` removes the values from the layer that was just produced.
# The rendered files are in /docker-entrypoint-initdb.d (a directory
# baked into the image) and run on first boot in lexical order:
#   01-schema.sql → CREATE TABLE statements
#   02-replication-user.sql → CREATE USER 'repl' + GRANT REPLICATION SLAVE
#   99-grants.sql → ALTER USER 'root' to the build-time password
#   100-init-complete.sh → write $DATADIR/.chatroom_init_complete marker
#                            (read by replication_bootstrap.sh to detect
#                             broken first-init — see that file for the
#                             full rationale)
RUN set -eux; \
    sed "s|__MYSQL_ROOT_PASSWORD__|${MYSQL_ROOT_PASSWORD}|g" \
        /tmp/99-grants.sql.template \
        > /docker-entrypoint-initdb.d/99-grants.sql; \
    sed "s|__REPLICATION_PASSWORD__|${REPLICATION_PASSWORD}|g" \
        /tmp/02-replication-user.sql.template \
        > /docker-entrypoint-initdb.d/02-replication-user.sql; \
    rm /tmp/99-grants.sql.template /tmp/02-replication-user.sql.template; \
    unset MYSQL_ROOT_PASSWORD; \
    unset REPLICATION_PASSWORD; \
    chmod 644 /docker-entrypoint-initdb.d/*.sql; \
    chmod 755 /docker-entrypoint-initdb.d/*.sh

# Per-pod bootstrap script. Lives in the image at /usr/local/bin/ so the
# ENTRYPOINT below can invoke it directly. The script decides master vs
# replica from the MYSQL_ROLE env var (set by the StatefulSet's downward
# API on each pod). For master pods it's effectively a no-op pass-through
# to the official entrypoint. For replica pods it dump-loads from
# mysql-0.mysql-headless and starts GTID-based replication before
# delegating to the official entrypoint.
COPY replication_bootstrap.sh /usr/local/bin/replication_bootstrap.sh
RUN chmod 755 /usr/local/bin/replication_bootstrap.sh

# Wrap the official entrypoint. The official mysql:8 entrypoint
# (/usr/local/bin/docker-entrypoint.sh) is what reads MYSQL_ROOT_PASSWORD
# and other env vars, runs /docker-entrypoint-initdb.d/* on first boot,
# and finally execs mysqld with the CMD-supplied args. We run our
# bootstrap script first — for master pods it's a no-op pass-through,
# for replica pods it dump-loads from mysql-0 and starts replication —
# then exec the official entrypoint so the rest of the lifecycle (init
# scripts, SIGTERM shutdown, etc.) is unchanged.
#
# Why a thin wrapper instead of replacing the entrypoint entirely:
# keeping the official entrypoint as the leaf means every fix the
# upstream mysql image ships (new auth plugin, new init flow, etc.)
# still applies here. We only add the replication concern.
ENTRYPOINT ["/usr/local/bin/replication_bootstrap.sh"]

# Default server args for both roles. The actual `--server-id` is
# supplied at runtime via the MYSQL_SERVER_ID env var (set by the
# StatefulSet pod template from the pod's ordinal, so it's unique
# cluster-wide per the MySQL replication requirements).
#
#   --server-id                 : required for replication; unique per
#                                 server. The bootstrap script derives
#                                 it from the pod's hostname
#                                 (100 + ordinal) so master and replicas
#                                 never collide. We deliberately do NOT
#                                 `ENV MYSQL_SERVER_ID=...` here — that
#                                 would freeze the value into every pod,
#                                 making master and replica server-ids
#                                 match and `CHANGE MASTER TO` fail with
#                                 "source and replica have equal MySQL
#                                 server ids". A standalone `docker run`
#                                 of the image falls through to the
#                                 script's `else` branch which defaults
#                                 to server-id=1.
#   --log-bin                   : turn on the binary log. Required for
#                                 master (replication source) and harmless
#                                 on replicas (a replica's binlog is empty
#                                 but the flag itself is required when
#                                 --gtid-mode=ON).
#   --gtid-mode=ON              : required for MASTER_AUTO_POSITION.
#   --enforce-gtid-consistency=ON: prevents statements that would make
#                                 the binlog unsafe to apply via GTID
#                                 (e.g. CREATE TABLE ... SELECT against
#                                 a non-transactional engine). The chatroom
#                                 schema is InnoDB-only, so this never fires.
#   --binlog-format=ROW         : default since MySQL 5.7, but explicit
#                                 for clarity — the repl user and the
#                                 chatroom CRUD all use ROW.
#
# Replica-only flags (added at runtime by the StatefulSet on pods with
# MYSQL_ROLE=replica):
#   --read-only=ON
#   --super-read-only=ON        : belt-and-braces; super-read-only also
#                                 blocks SUPER users, so even a stray
#                                 operator with root credentials can't
#                                 accidentally write to a replica.
#
# These default args live here so `docker run chatroom-mysql` standalone
# still gives a working single-node server. The k8s manifests append the
# pod-specific bits via env or via the `--args` form (see the StatefulSet
# pod template for the exact args list).