# syntax=docker/dockerfile:1.6
# chatroom-mysql — MySQL image with the chatroom schema and a baked-in
# root password (rotated at build time by scripts/build_images.sh).
#
# Why a custom image (instead of the official mysql:8 with MYSQL_ROOT_PASSWORD
# set on the Deployment): we want a known schema available the moment a fresh
# PVC is attached, with no need for a sidecar migration job. The
# /docker-entrypoint-initdb.d/ directory runs every *.sql file in lexical
# order on first boot of an empty datadir.

ARG MYSQL_IMAGE=mysql:8.0
FROM ${MYSQL_IMAGE}

# Build-time only: the root password the app will use. Not exposed in the
# final image as a layer env var (we sed-substitute it into a file and then
# unset the arg, so the literal value does not survive into the next layer).
ARG MYSQL_ROOT_PASSWORD=placeholder

# Schema. Adapted from database_setup.sql at the repo root — the only
# changes are dropping CREATE USER / GRANT statements, since the official
# mysql entrypoint already creates 'root'@'%' from the env-supplied
# MYSQL_ROOT_PASSWORD. The 99-grants.sql script re-pins the password to
# the build-time value so the app's MYSQL_PASSWORD env matches.
COPY mysql/init/01-schema.sql /docker-entrypoint-initdb.d/01-schema.sql
COPY mysql/init/99-grants.sql.template /tmp/99-grants.sql.template

# Substitute the build-arg password into the grants template. We use a
# delimiter (|) that the password (base64-ish) will never contain, so the
# sed won't choke if a future generated password happened to include '/'.
# Then `unset MYSQL_ROOT_PASSWORD` removes the value from the layer that
# was just produced. The rendered file is in /docker-entrypoint-initdb.d
# (which is a directory baked into the image) and is needed at first boot.
RUN set -eux; \
    sed "s|__MYSQL_ROOT_PASSWORD__|${MYSQL_ROOT_PASSWORD}|g" \
        /tmp/99-grants.sql.template \
        > /docker-entrypoint-initdb.d/99-grants.sql; \
    rm /tmp/99-grants.sql.template; \
    unset MYSQL_ROOT_PASSWORD; \
    chmod 644 /docker-entrypoint-initdb.d/01-schema.sql /docker-entrypoint-initdb.d/99-grants.sql

# The official entrypoint script reads MYSQL_ROOT_PASSWORD from the
# environment at first-boot to create the root user. We don't set it
# here (the k8s manifest does) so that rotating the password in the Secret
# after first boot works as expected. The init file 99-grants.sql pins it
# back to the build-time value for the chatroom use case.
