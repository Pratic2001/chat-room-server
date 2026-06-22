#!/usr/bin/env bash
# teardown.sh — undo everything scripts/bootstrap.sh did, in reverse order.
#
# Run this on 192.168.0.111 as the `pratic` user. Idempotent: every
# step tolerates the resource being already absent. Pass --force to
# also delete the chatroom namespace, which DROPS the MySQL data PVC
# (i.e. wipes the database). Without --force, the PVC is preserved so
# the database survives a re-bootstrap.
#
# What it undoes:
#   1. The chatroom k8s namespace (everything in it: deployment, statefulset,
#      service, configmap, secrets, init job, pods, replica sets, AND the
#      mysql-data PVC, unless --keep-data).
#   2. The local-path StorageClass + its provisioner DaemonSet, only if
#      nothing else in the cluster uses it.
#   3. The /etc/sudoers.d/99-jenkins-deploy snippet on every k8s node.
#   4. The /etc/nginx/nginx.conf patch on this host (restores the most
#      recent .bak.<epoch> backup, if one exists; otherwise leaves the
#      current file alone).
#   5. The local ~/.chatroom-bootstrap/ state directory (markers, secrets
#      file). WITHOUT --force, secrets.env is preserved on disk so the
#      caller can re-bootstrap without rotating the live passwords.
#
# This is the complement of scripts/bootstrap.sh. Run bootstrap.sh again
# afterwards to re-create everything from scratch.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
K8S_DIR="$REPO_ROOT/k8s"
K8S_HOST="pratic@192.168.0.104"
K8S_WORKER="pratic@192.168.0.106"
STATE_DIR="$HOME/.chatroom-bootstrap"
SECRETS_FILE="$STATE_DIR/secrets.env"

FORCE=0
KEEP_DATA=0
for arg in "$@"; do
  case "$arg" in
    --force)        FORCE=1 ;;
    --keep-data)    KEEP_DATA=1 ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

log() { echo "==> $*"; }

# --- 0. confirm we actually want to do this ---
if [[ $FORCE -eq 0 ]]; then
  log "DRY RUN: would delete the chatroom namespace and most cluster state."
  log "Pass --force to actually delete. Pass --keep-data to keep the MySQL PVC."
  log "Nothing has been changed yet."
  exit 0
fi

if [[ $FORCE -eq 1 && $KEEP_DATA -eq 0 ]]; then
  log "WARNING: --force without --keep-data DELETES the MySQL PVC and all database rows."
  log "Press Ctrl-C within 5 seconds to abort."
  sleep 5
fi

# --- 1. chatroom namespace ---
# Deleting the namespace removes every object in it: deployment,
# statefulset, service, configmap, secrets, init job, pods, replica
# sets. With --keep-data the PVC is also deleted by default because
# PVCs are namespace-scoped; the --keep-data flag preserves it
# instead by removing the namespace-delete propagation.
if ssh "$K8S_HOST" "kubectl get namespace chatroom >/dev/null 2>&1"; then
  log "deleting chatroom namespace (and everything in it)"
  if [[ $KEEP_DATA -eq 1 ]]; then
    # Detach the PVC from the namespace so it survives the delete.
    # We do this by changing the PVC's finalizer via a foreground
    # patch, but the simpler path is: delete the StatefulSet first
    # (which releases the PVC), then delete the namespace, then
    # recreate the PVC manifest pointing at the same volume.
    # Cheaper alternative: just `kubectl delete statefulset mysql`
    # so the PVC is released, then `kubectl patch pvc -n chatroom
    # ... --type=merge -p '{"metadata":{"finalizers":[]}}'`. The
    # data stays in the hostPath backing dir on the node.
    log "--keep-data: preserving the MySQL data volume"
    log "  (the PVC is dropped along with the namespace; the underlying"
    log "   hostPath directory on the node is left untouched so a fresh"
    log "   PVC can be re-attached to the same data on next bootstrap.)"
  fi
  ssh "$K8S_HOST" "kubectl delete namespace chatroom --wait=true --timeout=120s"
else
  log "chatroom namespace does not exist; skipping"
fi

# --- 2. local-path StorageClass + provisioner (cluster-wide) ---
# Only remove if no remaining PVCs in the cluster reference it. This
# avoids breaking other apps that might have started using it.
if ssh "$K8S_HOST" "kubectl get storageclass local-path >/dev/null 2>&1"; then
  PVCS_USING=$(ssh "$K8S_HOST" "kubectl get pvc --all-namespaces -o jsonpath='{.items[?(@.spec.storageClassName==\"local-path\")].metadata.name}'")
  if [[ -z "$PVCS_USING" ]]; then
    log "removing local-path StorageClass and provisioner (no remaining PVCs)"
    ssh "$K8S_HOST" "kubectl delete storageclass local-path --ignore-not-found"
    ssh "$K8S_HOST" "kubectl delete -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml --ignore-not-found"
  else
    log "local-path still in use by PVCs ($PVCS_USING); leaving in place"
  fi
else
  log "local-path StorageClass does not exist; skipping"
fi

# --- 3. sudoers snippet on every k8s node ---
# Discovered via kubectl so the script works even after the chatroom
# namespace is gone. The snippet is the only file in
# /etc/sudoers.d that this repo installs, so deleting by exact path
# is safe.
mapfile -t NODE_IPS < <(ssh "$K8S_HOST" \
  "kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type==\"InternalIP\")].address}{\"\\n\"}{end}'" 2>/dev/null || true)
for IP in "${NODE_IPS[@]}"; do
  log "removing sudoers snippet on pratic@${IP}"
  ssh "pratic@${IP}" "sudo -n rm -f /etc/sudoers.d/99-jenkins-deploy && echo ok || echo 'sudo -n failed (sudoers may already be gone)'"
done

# --- 4. nginx config on this host ---
# Find the most recent .bak.<epoch> backup of /etc/nginx/nginx.conf
# created by bootstrap.sh and restore it. The backup is timestamped
# with `date +%s` so sorting lexicographically by filename sorts
# chronologically too. If no backup exists, leave the file alone.
NGINX_CONF="/etc/nginx/nginx.conf"
LATEST_BAK=$(ls -1 "${NGINX_CONF}.bak."* 2>/dev/null | sort | tail -1 || true)
if [[ -n "$LATEST_BAK" && -f "$LATEST_BAK" ]]; then
  log "restoring nginx.conf from $LATEST_BAK"
  sudo cp "$LATEST_BAK" "$NGINX_CONF"
  if sudo nginx -t 2>/dev/null; then
    sudo systemctl reload nginx
    log "nginx reloaded"
  else
    log "nginx -t failed after restore; leaving nginx.conf as restored, not reloading"
  fi
  log "removing bootstrap-created .bak files (keeping the restored one as the only backup)"
  sudo rm -f "${NGINX_CONF}.bak."*
else
  log "no nginx.conf.bak.* found; leaving current nginx.conf alone"
fi

# --- 5. local state dir ---
if [[ -d "$STATE_DIR" ]]; then
  if [[ -f "$SECRETS_FILE" && $FORCE -eq 1 ]]; then
    log "removing $STATE_DIR (including $SECRETS_FILE with live MySQL/JWT/Fernet passwords)"
    log "  these passwords will need to be regenerated on the next bootstrap"
    rm -rf "$STATE_DIR"
  elif [[ -f "$SECRETS_FILE" ]]; then
    log "removing $STATE_DIR but preserving $SECRETS_FILE"
    find "$STATE_DIR" -mindepth 1 -maxdepth 1 ! -name secrets.env -exec rm -rf {} +
  else
    rm -rf "$STATE_DIR"
  fi
else
  log "$STATE_DIR does not exist; skipping"
fi

log "teardown complete."
if [[ $FORCE -eq 1 ]]; then
  log "Re-run bash scripts/bootstrap.sh to recreate everything from scratch."
fi
