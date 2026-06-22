#!/usr/bin/env bash
# distribute-image.sh — copy an OCI image tarball to one or more remote
# nodes and `ctr -n k8s.io images import` it on each.
#
# Usage:
#   distribute-image.sh <tarball> <user@host>...
#
# Requires:
#   - ssh + scp access to each host (passwordless key)
#   - the pratic user (or whoever is logging in) has NOPASSWD sudo for
#     `/usr/bin/ctr -n k8s.io images …` and `/usr/local/bin/kubectl …`
#     (installed by scripts/bootstrap.sh)
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <tarball> <user@host>..." >&2
  exit 1
fi

TAR="$1"
shift

if [[ ! -f "$TAR" ]]; then
  echo "tarball not found: $TAR" >&2
  exit 1
fi

# Pull the image ref out of the tarball name. Our build produces
# /tmp/chatroom-server-<tag>.tar and we want to retag it to
# docker.io/library/chatroom-server:<tag> on import so the manifest's
# image ref matches.
TAG=$(basename "$TAR" | sed -E 's/^chatroom-server-(.+)\.tar$/\1/')
if [[ -z "$TAG" || "$TAG" == "chatroom-server-" ]]; then
  echo "could not extract tag from tarball name: $TAR" >&2
  exit 1
fi
REMOTE_TAR="/tmp/chatroom-server-${TAG}.tar"

for HOST in "$@"; do
  echo "==> $HOST"
  scp -o StrictHostKeyChecking=no "$TAR" "$HOST:$REMOTE_TAR"
  ssh -o StrictHostKeyChecking=no "$HOST" \
    "sudo -n ctr -n k8s.io images import $REMOTE_TAR \
       && sudo -n ctr -n k8s.io images tag chatroom-server:$TAG docker.io/library/chatroom-server:$TAG \
       && rm -f $REMOTE_TAR"
done

echo "done."
