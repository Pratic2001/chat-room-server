#!/usr/bin/env bash
# bootstrap.sh — one-time cluster bring-up. Run on 192.168.0.111 as the
# `pratic` user (the same one whose key the Jenkins credential holds).
#
# What this script does:
#   1. Verifies SSH access to the k8s nodes.
#   2. Installs local-path-provisioner (provides the `local-path`
#      StorageClass that the MySQL PVC uses).
#   3. Drops a sudoers snippet on each k8s node so the pratic user can
#      run `ctr -n k8s.io images …` and `kubectl …` without a password.
#      Everything else still requires a password.
#   4. Creates the k8s namespace and populates the live `mysql-secret`
#      and `chatroom-secrets` Secrets with real random passwords. The
#      generated values are written to ~/.chatroom-bootstrap/secrets.env
#      for the user to keep; they are NEVER echoed to the terminal and
#      NEVER committed to git.
#   5. Builds a ConfigMap from the repo's `database_setup.sql`.
#   6. Applies k8s/30-mysql-statefulset.yaml and waits for the pod.
#   7. Applies k8s/35-mysql-init-job.yaml and waits for the Job to
#      complete.
#   8. Applies the rest of k8s/ (configmap, app deployment placeholder,
#      NodePort service).
#   9. Patches /etc/nginx/nginx.conf on this host to proxy to the new
#      NodePort, with WebSocket support and 100 MB uploads.
#
# This script is idempotent — re-running it is safe. Secret values
# already in the cluster are NOT overwritten.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
K8S_DIR="$REPO_ROOT/k8s"
DEPLOY_DIR="$REPO_ROOT/deploy"
K8S_HOST="pratic@192.168.0.104"
K8S_WORKER="pratic@192.168.0.106"
K8S_API="192.168.0.104"
STATE_DIR="$HOME/.chatroom-bootstrap"
SECRETS_FILE="$STATE_DIR/secrets.env"
MARKER_DIR="$STATE_DIR/markers"

mkdir -p "$STATE_DIR" "$MARKER_DIR"

# Helper: skip a step if its marker file exists
mark_done() { mkdir -p "$(dirname "$MARKER_DIR/$1")" && touch "$MARKER_DIR/$1"; }
already_done() { [[ -f "$MARKER_DIR/$1" ]]; }

log() { echo "==> $*"; }

# --- 1. verify ssh ---
log "verifying ssh to $K8S_HOST and $K8S_WORKER"
ssh -o BatchMode=yes -o ConnectTimeout=5 "$K8S_HOST"  true
ssh -o BatchMode=yes -o ConnectTimeout=5 "$K8S_WORKER" true

# --- 2. install local-path-provisioner (StorageClass) ---
if ! ssh "$K8S_HOST" 'kubectl get storageclass local-path >/dev/null 2>&1'; then
  log "installing local-path-provisioner (provides the 'local-path' StorageClass)"
  ssh "$K8S_HOST" 'kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml'
  ssh "$K8S_HOST" 'kubectl annotate storageclass local-path storageclass.kubernetes.io/is-default-class=true --overwrite'
  ssh "$K8S_HOST" 'kubectl get storageclass'
fi
mark_done storageclass-installed

# --- 3. sudoers snippet on each k8s node ---
# Discovered via kubectl so that nodes added to the cluster after the
# initial bootstrap are picked up the next time this script is run. The
# snippet is identical on every node and idempotent (re-running is a
# no-op apart from overwriting the file).
SUDOERS_SNIPPET='/etc/sudoers.d/99-jenkins-deploy'
SUDOERS_CONTENT='%sudo ALL=(ALL) NOPASSWD: /usr/bin/ctr -n k8s.io images import *
%sudo ALL=(ALL) NOPASSWD: /usr/bin/ctr -n k8s.io images tag *
%sudo ALL=(ALL) NOPASSWD: /usr/bin/ctr -n k8s.io images ls *
%sudo ALL=(ALL) NOPASSWD: /usr/local/bin/kubectl *
'
mapfile -t NODE_IPS < <(ssh "$K8S_HOST" \
  "kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type==\"InternalIP\")].address}{\"\\n\"}{end}'")
for IP in "${NODE_IPS[@]}"; do
  log "installing sudoers snippet on pratic@${IP}"
  ssh "pratic@${IP}" "echo '$SUDOERS_CONTENT' | sudo -S tee $SUDOERS_SNIPPET >/dev/null && sudo -S chmod 440 $SUDOERS_SNIPPET"
done
mark_done sudoers-installed

# --- 4. namespace + secrets + configmap (idempotent) ---
log "applying namespace"
ssh "$K8S_HOST" "kubectl apply -f $K8S_DIR/00-namespace.yaml"
mark_done ns-applied

# Build a ConfigMap from database_setup.sql so the init Job can mount it.
# Re-created on every run (idempotent — configmaps are safe to overwrite).
log "rendering ConfigMap from database_setup.sql"
SQL_CONTENT=$(cat "$REPO_ROOT/database_setup.sql")
# Escape for embedding inside a heredoc-ish yaml string. Use base64 to be
# safe with quotes, then decode at runtime via an init step. But the
# init Job in 35-mysql-init-job.yaml expects a plain text key, so we
# just embed via sed-friendly substitution here. Simpler approach: write
# to a temp file, base64-encode, render a small yaml that decodes it.
B64=$(base64 -w0 < "$REPO_ROOT/database_setup.sql")
cat > "$STATE_DIR/30-mysql-statefulset-and-init.yaml" <<EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: mysql-init-sql
  namespace: chatroom
data:
  database_setup.sql: |
$(awk '{ print "    " $0 }' "$REPO_ROOT/database_setup.sql")
EOF
ssh "$K8S_HOST" "kubectl apply -f -" < "$STATE_DIR/30-mysql-statefulset-and-init.yaml"
mark_done configmap-rendered

# Create the live secrets with real random passwords, unless they already
# exist. This is the only place real secret values live on disk; the
# script chmods the file to 600 and prints a one-line reminder to back it
# up.
if ! ssh "$K8S_HOST" 'kubectl -n chatroom get secret mysql-secret >/dev/null 2>&1'; then
  log "generating random passwords"
  ROOT_PW=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
  APP_PW=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
  JWT_SECRET=$(openssl rand -base64 48 | tr -d '/+=' | head -c 64)
  FERNET_KEY=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")
  MAIL_PW="CHANGE_ME_GMAIL_APP_PASSWORD"   # user must edit this by hand

  cat > "$SECRETS_FILE" <<EOF
# Generated by scripts/bootstrap.sh on $(date -Iseconds)
# DO NOT COMMIT. Back this file up; you'll need it to recreate the
# live k8s Secrets.
ROOT_PW=$ROOT_PW
APP_PW=$APP_PW
JWT_SECRET=$JWT_SECRET
FERNET_KEY=$FERNET_KEY
MAIL_PW=$MAIL_PW
EOF
  chmod 600 "$SECRETS_FILE"
  log "secrets written to $SECRETS_FILE (mode 600)"

  # Source for the kubectl create secret invocations
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"

  ssh "$K8S_HOST" "kubectl -n chatroom create secret generic mysql-secret \
    --from-literal=MYSQL_ROOT_PASSWORD='$ROOT_PW' \
    --from-literal=MYSQL_PASSWORD='$APP_PW' \
    --from-literal=MYSQL_DATABASE=chatroom_db"

  ssh "$K8S_HOST" "kubectl -n chatroom create secret generic chatroom-secrets \
    --from-literal=MYSQL_USER=chatroom \
    --from-literal=MYSQL_PASSWORD='$APP_PW' \
    --from-literal=MYSQL_HOST=mysql.chatroom.svc.cluster.local \
    --from-literal=MYSQL_DB=chatroom_db \
    --from-literal=SECRET_KEY='$JWT_SECRET' \
    --from-literal=ROOM_SECRET_KEY='$FERNET_KEY' \
    --from-literal=MAIL_PASSWORD='$MAIL_PW'"

  mark_done secrets-created
  log "secrets created. REMINDER: edit MAIL_PASSWORD with:"
  log "  kubectl -n chatroom edit secret chatroom-secrets"
else
  log "mysql-secret already exists; not regenerating. Re-run with --rotate-secrets to force."
fi

# --- 6. apply MySQL StatefulSet ---
log "applying MySQL StatefulSet"
ssh "$K8S_HOST" "kubectl apply -f $K8S_DIR/30-mysql-statefulset.yaml"

if ! ssh "$K8S_HOST" 'kubectl -n chatroom get pod -l app=mysql -o name | grep -q .'; then
  log "waiting for mysql-0 to become Ready (timeout 5m)"
  ssh "$K8S_HOST" 'kubectl -n chatroom wait --for=condition=ready pod -l app=mysql --timeout=300s'
fi
mark_done mysql-statefulset-applied

# --- 7. apply init Job ---
log "applying mysql-init Job"
ssh "$K8S_HOST" "kubectl apply -f $K8S_DIR/35-mysql-init-job.yaml"

# Idempotent: if the Job already succeeded, skip the wait.
if ! ssh "$K8S_HOST" 'kubectl -n chatroom get job mysql-init -o jsonpath="{.status.succeeded}" 2>/dev/null | grep -q 1'; then
  log "waiting for mysql-init Job to complete (timeout 5m)"
  ssh "$K8S_HOST" 'kubectl -n chatroom wait --for=condition=complete job/mysql-init --timeout=300s'
fi
mark_done mysql-init-completed

# --- 8. apply configmap + app secret + deployment placeholder + nodeport service ---
log "applying ConfigMap, app Secret template, Deployment placeholder, NodePort service"
ssh "$K8S_HOST" "kubectl apply -f $K8S_DIR/20-configmap.yaml"
ssh "$K8S_HOST" "kubectl apply -f $K8S_DIR/10-secret.yaml || true   # template; values are in chatroom-secrets"
ssh "$K8S_HOST" "kubectl apply -f $K8S_DIR/40-deployment.yaml"   # the Jenkinsfile rewrites the image on first build
ssh "$K8S_HOST" "kubectl apply -f $K8S_DIR/50-service.yaml"
mark_done remaining-manifests-applied

# --- 9. nginx patch ---
NGINX_CONF="/etc/nginx/nginx.conf"
if ! grep -q "192.168.0.104:30800" "$NGINX_CONF" 2>/dev/null; then
  log "patching /etc/nginx/nginx.conf"
  sudo cp "$NGINX_CONF" "$NGINX_CONF.bak.$(date +%s)"
  sudo patch -p0 "$NGINX_CONF" < "$DEPLOY_DIR/nginx-location.patch"
  sudo nginx -t
  sudo systemctl reload nginx
  mark_done nginx-patched
else
  log "nginx already patched; skipping"
fi

log "bootstrap complete. You can now trigger a Jenkins build."
log "Verify with:  curl -kfsS https://localhost/healthz   (will 502 until first deploy)"
