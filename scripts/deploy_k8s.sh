#!/usr/bin/env bash
# deploy_k8s.sh
# -----------------------------------------------------------------------------
# Deploy the chat-room-server + MySQL stack to a k8s cluster.
#
# Reads credentials from app/.env.runtime (produced by scripts/build_images.sh)
# and applies every manifest under k8s/. Idempotent: re-running reconciles
# to the current desired state.
#
# What this script does:
#   1. Refuses to run if `kubectl` is not on PATH or if the active context
#      is empty (so it can't accidentally clobber some other cluster).
#   2. Creates the `chatroom` namespace if it doesn't exist.
#   3. Applies every manifest under k8s/ in lexical order. This includes
#      `k8s/secrets.runtime.yaml` (gitignored), which holds the rendered
#      chatroom-mysql + chatroom-app Secrets and the chatroom-app ConfigMap.
#      The committed templates under k8s/ (10-mysql-secret.yaml,
#      31-app-secret.yaml) are intentionally invalid (`REPLACE_AT_DEPLOY_TIME`
#      placeholders); they are NOT applied.
#   4. Waits for both Deployments to roll out.
#   5. Prints the Ingress address (or, if no Ingress is installed, the
#      instructions to port-forward).
#
# Usage:
#   ./scripts/deploy_k8s.sh                 # deploy / reconcile
#   ./scripts/deploy_k8s.sh --uninstall     # delete the chatroom namespace
#                                           # (and everything in it)
#
# Prerequisite: a working `kubectl` context AND the two images built by
# `scripts/build_images.sh` (chat-room-server:latest and chatroom-mysql:latest
# in the local Docker daemon). The script does not push images to a registry
# and does not configure image loaders — for kind/k3d/minikube that's the
# caller's job, since the right command depends on which one they're using.
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
K8S_DIR="$REPO_ROOT/k8s"
RUNTIME_ENV="$REPO_ROOT/app/.env.runtime"
NAMESPACE="chatroom"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "deploy" "$*" >&2; }
warn() { printf '\033[1;33m[%s]\033[0m %s\n' "deploy" "$*" >&2; }
fail() { printf '\033[1;31m[%s]\033[0m %s\n' "deploy" "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Parse args
# -----------------------------------------------------------------------------
UNINSTALL=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --uninstall) UNINSTALL=1; shift ;;
        -h|--help)
            sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) fail "Unknown argument: $1 (try --help)" ;;
    esac
done

# -----------------------------------------------------------------------------
# Pre-flight
# -----------------------------------------------------------------------------
command -v kubectl >/dev/null 2>&1 || fail "kubectl not found in PATH."

# Refuse to run if there's no active context. This stops the script from
# silently targeting whatever's in ~/.kube/config if the user forgot to
# switch contexts.
CURRENT_CTX="$(kubectl config current-context 2>/dev/null || true)"
if [[ -z "$CURRENT_CTX" ]]; then
    fail "No active kubectl context. Run 'kubectl config use-context <name>' first."
fi
log "Active context: $CURRENT_CTX"

# -----------------------------------------------------------------------------
# Uninstall path
# -----------------------------------------------------------------------------
if [[ "$UNINSTALL" -eq 1 ]]; then
    log "Deleting namespace $NAMESPACE (and everything in it)..."
    kubectl delete namespace "$NAMESPACE" --ignore-not-found
    log "Done. The chatroom-mysql PVC and any data it held are also gone."
    exit 0
fi

[[ -f "$RUNTIME_ENV" ]] || fail "$RUNTIME_ENV not found.
  Two ways to create it:

    1. Build the images locally:   ./scripts/build_images.sh
    2. Images were built elsewhere (CI / a teammate / registry):
         ./scripts/write_runtime_env.sh --from-stdin
       then paste 9 values (MYSQL_PASSWORD, SECRET_KEY, ROOM_SECRET_KEY,
       MAIL_PASSWORD, MAIL_HOST, MAIL_USER, MAIL_PORT, MAIL_FROM,
       MAIL_USE_TLS), one per line, in that order.

  The MySQL image's 99-grants.sql was baked with a specific
  MYSQL_PASSWORD at build time, so the value you supply must match
  the one used when the MySQL image was built. See the runbook §6.3.

  Whichever path you take, the script also writes k8s/secrets.runtime.yaml
  (gitignored) which is what kubectl apply -f k8s/ actually uses for
  the chatroom-mysql + chatroom-app Secrets and the chatroom-app
  ConfigMap."
[[ -d "$K8S_DIR" ]]     || fail "$K8S_DIR not found. Is the repo layout intact?"
[[ -f "$K8S_DIR/secrets.runtime.yaml" ]] \
    || fail "$K8S_DIR/secrets.runtime.yaml not found.
  That file is gitignored and is created by scripts/build_images.sh
  (or scripts/write_runtime_env.sh). Re-run one of those to generate it."

# -----------------------------------------------------------------------------
# Load credentials from app/.env.runtime
# -----------------------------------------------------------------------------
# Source in a subshell so the values land in MYSQL_PASSWORD, SECRET_KEY, etc.
# without polluting this shell's environment.
# shellcheck disable=SC1090
(
    set -a
    # shellcheck disable=SC1090
    source "$RUNTIME_ENV"
    set +a
    : "${MYSQL_PASSWORD:?MYSQL_PASSWORD missing from $RUNTIME_ENV}"
    : "${SECRET_KEY:?SECRET_KEY missing from $RUNTIME_ENV}"
    : "${ROOM_SECRET_KEY:?ROOM_SECRET_KEY missing from $RUNTIME_ENV}"
    # The MAIL_* values are optional in the strict sense — the app
    # treats MAIL_HOST="" as "invites disabled" and MAIL_PASSWORD=""
    # as "no SMTP auth". Default MYSQL_PORT to 3306 if missing (older
    # .env.runtime files might not have it).
    printf '%s\n' "$MYSQL_PASSWORD"  > /tmp/_crs_mysql_pw
    printf '%s\n' "$SECRET_KEY"      > /tmp/_crs_jwt
    printf '%s\n' "$ROOM_SECRET_KEY" > /tmp/_crs_fernet
    printf '%s\n' "${MYSQL_HOST-mysql}"                 > /tmp/_crs_mysql_host
    printf '%s\n' "${MYSQL_PORT-3306}"                  > /tmp/_crs_mysql_port
    printf '%s\n' "${MYSQL_USER-root}"                  > /tmp/_crs_mysql_user
    printf '%s\n' "${MYSQL_DB-chatroom_db}"             > /tmp/_crs_mysql_db
    printf '%s\n' "${ALGORITHM-HS256}"                  > /tmp/_crs_alg
    printf '%s\n' "${ACCESS_TOKEN_EXPIRE_MINUTES-60}"   > /tmp/_crs_exp
    printf '%s\n' "${MAIL_HOST-}"        > /tmp/_crs_mail_host
    printf '%s\n' "${MAIL_PORT-587}"     > /tmp/_crs_mail_port
    printf '%s\n' "${MAIL_USER-}"        > /tmp/_crs_mail_user
    printf '%s\n' "${MAIL_PASSWORD-}"    > /tmp/_crs_mail_password
    printf '%s\n' "${MAIL_FROM-Chat Room <no-reply@example.com>}" > /tmp/_crs_mail_from
    printf '%s\n' "${MAIL_USE_TLS-true}" > /tmp/_crs_mail_use_tls
)
trap 'rm -f /tmp/_crs_mysql_pw /tmp/_crs_jwt /tmp/_crs_fernet \
        /tmp/_crs_mysql_host /tmp/_crs_mysql_port /tmp/_crs_mysql_user /tmp/_crs_mysql_db \
        /tmp/_crs_alg /tmp/_crs_exp \
        /tmp/_crs_mail_host /tmp/_crs_mail_port /tmp/_crs_mail_user /tmp/_crs_mail_password \
        /tmp/_crs_mail_from /tmp/_crs_mail_use_tls' EXIT
MYSQL_PASSWORD="$(cat /tmp/_crs_mysql_pw)"
SECRET_KEY="$(cat /tmp/_crs_jwt)"
ROOM_SECRET_KEY="$(cat /tmp/_crs_fernet)"
MYSQL_HOST="$(cat /tmp/_crs_mysql_host)"
MYSQL_PORT="$(cat /tmp/_crs_mysql_port)"
MYSQL_USER="$(cat /tmp/_crs_mysql_user)"
MYSQL_DB="$(cat /tmp/_crs_mysql_db)"
ALGORITHM="$(cat /tmp/_crs_alg)"
ACCESS_TOKEN_EXPIRE_MINUTES="$(cat /tmp/_crs_exp)"
MAIL_HOST="$(cat /tmp/_crs_mail_host)"
MAIL_PORT="$(cat /tmp/_crs_mail_port)"
MAIL_USER="$(cat /tmp/_crs_mail_user)"
MAIL_PASSWORD="$(cat /tmp/_crs_mail_password)"
MAIL_FROM="$(cat /tmp/_crs_mail_from)"
MAIL_USE_TLS="$(cat /tmp/_crs_mail_use_tls)"

# -----------------------------------------------------------------------------
# Create namespace
# -----------------------------------------------------------------------------
# `kubectl create namespace --dry-run=client -o yaml | kubectl apply -f -`
# is the standard "create or noop" pattern.
log "Ensuring namespace $NAMESPACE exists..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# -----------------------------------------------------------------------------
# Sanity check: chatroom-app Secret in the rendered manifest must hold
# the same MYSQL_PASSWORD that's baked into the chatroom-mysql image's
# 99-grants.sql. If the rendered file was generated against an old
# app/.env.runtime that doesn't match the running MySQL pod, the app
# pods will 1045. We catch that here instead of after a failed rollout.
# -----------------------------------------------------------------------------
RENDERED_MYSQL_PASSWORD_B64="$(kubectl get secret chatroom-app \
    --namespace "$NAMESPACE" \
    -o jsonpath='{.data.MYSQL_PASSWORD}' 2>/dev/null || true)"
if [[ -n "$RENDERED_MYSQL_PASSWORD_B64" ]]; then
    RENDERED_MYSQL_PASSWORD="$(printf '%s' "$RENDERED_MYSQL_PASSWORD_B64" | base64 --decode)"
    if [[ "$RENDERED_MYSQL_PASSWORD" != "$MYSQL_PASSWORD" ]]; then
        fail "chatroom-app Secret in the cluster has a different MYSQL_PASSWORD than
  app/.env.runtime. The MySQL pod is initialized with the value in
  99-grants.sql (baked at image build time); if they disagree, the
  app pods will 1045.

  Cluster secret (decoded):  ${RENDERED_MYSQL_PASSWORD:0:8}...
  app/.env.runtime:          ${MYSQL_PASSWORD:0:8}...

  Re-run ./scripts/build_images.sh so k8s/secrets.runtime.yaml is
  regenerated, then re-run this script."
    fi
fi

# -----------------------------------------------------------------------------
# Apply all manifests (including k8s/secrets.runtime.yaml)
# -----------------------------------------------------------------------------
log "Applying manifests from $K8S_DIR ..."
kubectl apply -f "$K8S_DIR"
log "Applying manifests from $K8S_DIR (includes k8s/secrets.runtime.yaml, gitignored)..."
kubectl apply -f "$K8S_DIR"

# -----------------------------------------------------------------------------
# Scale chatroom-app to one replica per cluster node
# -----------------------------------------------------------------------------
# The committed manifest in k8s/40-app-deployment.yaml has no `replicas:`
# field (the previous hard-coded `replicas: 2` was removed — see the
# comment in that file). This step is the source of truth for the replica
# count, and it matches the cluster's node count so the app spreads
# across the cluster. The `topologySpreadConstraints` block in the
# manifest does the actual scheduling work; this step just sets the
# desired count.
#
# We default to 2 if we can't determine the node count (e.g. the user
# pointed kubectl at an empty context — defensive, but the pre-flight
# check above already catches that case before we get here).
NODE_COUNT="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [[ -z "$NODE_COUNT" || "$NODE_COUNT" -lt 1 ]]; then
    warn "Could not determine node count; defaulting replicas to 2."
    NODE_COUNT=2
fi
log "Scaling chatroom-app to $NODE_COUNT replicas (cluster node count)..."
kubectl scale deployment/chatroom-app --namespace "$NAMESPACE" --replicas="$NODE_COUNT"

# -----------------------------------------------------------------------------
# Rollout status
# -----------------------------------------------------------------------------
# MySQL must come up first — the app's readiness will fail if it can't
# reach the DB on the first connection attempts.
log "Waiting for MySQL to be ready..."
kubectl -n "$NAMESPACE" rollout status deployment/mysql --timeout=5m

log "Waiting for chatroom-app to be ready..."
kubectl -n "$NAMESPACE" rollout status deployment/chatroom-app --timeout=5m

# -----------------------------------------------------------------------------
# Print a useful "how to reach the app" footer
# -----------------------------------------------------------------------------
echo
printf '\033[1;32m============================================================\033[0m\n'
printf '\033[1;32m  chatroom deployed to namespace "%s"\033[0m\n' "$NAMESPACE"
printf '\033[1;32m============================================================\033[0m\n'
echo
printf 'Pods:\n'
kubectl -n "$NAMESPACE" get pods -o wide
echo

# Try to find an Ingress address. If no Ingress controller is installed,
# this will be empty — print a port-forward hint instead.
INGRESS_HOST="$(kubectl -n "$NAMESPACE" get ingress chatroom \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
INGRESS_IP="$(kubectl -n "$NAMESPACE" get ingress chatroom \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"

if [[ -n "$INGRESS_HOST" || -n "$INGRESS_IP" ]]; then
    printf 'Reachable at:\n'
    [[ -n "$INGRESS_HOST" ]] && printf '  http://%s/\n' "$INGRESS_HOST"
    [[ -n "$INGRESS_IP"   ]] && printf '  http://%s/\n'   "$INGRESS_IP"
else
    printf 'No Ingress address yet. Most local clusters (kind/k3d/minikube)\n'
    printf 'do not provision a load-balancer automatically.\n'
    printf 'Try this:\n'
    printf '  kubectl -n %s port-forward svc/chatroom-app 8000:80\n' "$NAMESPACE"
    printf '  curl http://localhost:8000/healthz\n'
fi
echo
printf 'To remove everything:\n'
printf '  ./scripts/deploy_k8s.sh --uninstall\n'
