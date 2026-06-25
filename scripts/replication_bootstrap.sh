#!/usr/bin/env bash
# replication_bootstrap.sh (repo-root wrapper)
# -----------------------------------------------------------------------------
# Thin wrapper around mysql/replication_bootstrap.sh. The actual bootstrap
# logic lives next to the MySQL Dockerfile (build context = mysql/), so
# `COPY replication_bootstrap.sh /usr/local/bin/` works during `docker build`.
# This wrapper exists so the runbook / debugging flow can invoke the same
# script from the repo root:
#
#   ./scripts/replication_bootstrap.sh --help
#
# Both this script and the real one share the same name by design — the
# wrapper just exec's the real one so SIGTERM and arg parsing carry over.
# -----------------------------------------------------------------------------

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/../mysql/replication_bootstrap.sh" "$@"