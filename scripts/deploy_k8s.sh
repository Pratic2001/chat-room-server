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
#   3. Writes the chatroom-mysql and chatroom-app Secrets from .env.runtime.
#   4. Applies every manifest under k8s/ in lexical order.
#   5. Waits for both Deployments to roll out.
#   6. Prints the Ingress address (or, if no Ingress is installed, the
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
       then paste MYSQL_PASSWORD, SECRET_KEY, and ROOM_SECRET_KEY
       (one per line, in that order).

  The MySQL image's 99-grants.sql was baked with a specific
  MYSQL_PASSWORD at build time, so the value you supply must match
  the one used when the MySQL image was built. See the runbook §6.3."
[[ -d "$K8S_DIR" ]]     || fail "$K8S_DIR not found. Is the repo layout intact?"

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
    printf '%s\n' "$MYSQL_PASSWORD"  > /tmp/_crs_mysql_pw
    printf '%s\n' "$SECRET_KEY"      > /tmp/_crs_jwt
    printf '%s\n' "$ROOM_SECRET_KEY" > /tmp/_crs_fernet
)
trap 'rm -f /tmp/_crs_mysql_pw /tmp/_crs_jwt /tmp/_crs_fernet' EXIT
MYSQL_PASSWORD="$(cat /tmp/_crs_mysql_pw)"
SECRET_KEY="$(cat /tmp/_crs_jwt)"
ROOM_SECRET_KEY="$(cat /tmp/_crs_fernet)"

# -----------------------------------------------------------------------------
# Create namespace and Secrets
# -----------------------------------------------------------------------------
# The namespace manifest is a plain file, so apply it like everything else,
# but we want to make sure it exists before we try to create the Secret.
# `kubectl create namespace --dry-run=client -o yaml | kubectl apply -f -`
# is the standard "create or noop" pattern.
log "Ensuring namespace $NAMESPACE exists..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# Write the Secrets imperatively. They contain values that must NOT end up
# in committed manifests, so we generate them at deploy time from .env.runtime.
# `kubectl create secret --dry-run=client -o yaml | kubectl apply -f -` is the
# idempotent "create or update" pattern.
log "Writing chatroom-mysql Secret..."
kubectl create secret generic chatroom-mysql \
    --namespace "$NAMESPACE" \
    --from-literal=MYSQL_ROOT_PASSWORD="$MYSQL_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

log "Writing chatroom-app Secret..."
kubectl create secret generic chatroom-app \
    --namespace "$NAMESPACE" \
    --from-literal=MYSQL_PASSWORD="$MYSQL_PASSWORD" \
    --from-literal=SECRET_KEY="$SECRET_KEY" \
    --from-literal=ROOM_SECRET_KEY="$ROOM_SECRET_KEY" \
    --from-literal=MAIL_PASSWORD="" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# -----------------------------------------------------------------------------
# Apply all manifests
# -----------------------------------------------------------------------------
log "Applying manifests from $K8S_DIR ..."
kubectl apply -f "$K8S_DIR"

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
