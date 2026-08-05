#!/usr/bin/env bash
# install-k8s.sh
# -----------------------------------------------------------------------------
# One-shot installer: pull the repo at a released version, generate fresh
# credentials, build (or pull) the two images, load them into a local k8s
# cluster, and deploy the whole chat-room stack.
#
# Two modes:
#
#   Default (build local)  — for kind / k3d / minikube / Docker Desktop.
#       Runs scripts/build_images.sh (which prompts for your SMTP + Ollama
#       details), loads the freshly built images into the cluster, then runs
#       scripts/deploy_k8s.sh. Every install gets unique MySQL/JWT/Fernet
#       credentials.
#
#       ./install-k8s.sh
#
#   --registry USER[:TAG] — for a real multi-node / remote cluster whose
#       nodes can't reach your local Docker daemon (EKS, GKE, a bare-metal
#       kubeadm cluster, ...). Pulls the prebuilt images pushed by the CI/CD
#       pipeline instead of building. The MySQL image's root + replication
#       passwords are baked in when CI builds it; since v0.1.2 they're also
#       stored inside the image at /etc/chatroom/mysql-credentials, so this
#       script auto-extracts them via `docker run` (no need to re-enter).
#       Exporting them explicitly still works and skips the extraction:
#
#       ./install-k8s.sh --registry pratic2001
#
# In both modes the script asks for your Ollama host/port and SMTP details
# if they aren't already exported, then everything is ready to run.
#
# Usage:
#   ./install-k8s.sh [--registry USER[:TAG]] [--version REF]
#                    [--repo URL] [--no-pull] [--keep] [-h]
#
# Flags:
#   --registry USER[:TAG]  pull prebuilt images from Docker Hub instead of
#                          building locally (multi-node clusters).
#   --version REF          git ref/tag to install when cloning (default:
#                          the release tag baked into this script, or main).
#   --repo URL             repository to clone when not run from a checkout
#                          (default: the GitHub URL baked in below).
#   --no-pull              do not clone/pull; assume this checkout is the
#                          repo (run from the repo root).
#   --keep                 keep the temporary clone (for debugging).
#   -h, --help             this help.
#
# Prerequisites: bash, git, docker, kubectl with an active context. For
# kind/k3d/minikube the matching CLI must be on PATH.
# -----------------------------------------------------------------------------

set -euo pipefail

# Baked by the CI/CD release job so a standalone downloaded script installs
# the exact version it was released with. A plain `./install-k8s.sh` from a
# fresh clone leaves these as the defaults below.
REPO_URL="${REPO_URL:-https://github.com/Pratic2001/chat-room-server.git}"
REPO_REF="${REPO_REF:-main}"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "install-k8s" "$*" >&2; }
warn() { printf '\033[1;33m[%s]\033[0m %s\n' "install-k8s" "$*" >&2; }
fail() { printf '\033[1;31m[%s]\033[0m %s\n' "install-k8s" "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Parse args
# -----------------------------------------------------------------------------
MODE="build-local"          # or "registry"
REGISTRY_SPEC=""
VERSION="$REPO_REF"
NO_PULL=0
KEEP=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --registry) MODE="registry"; REGISTRY_SPEC="${2:?--registry requires USER[:TAG]}"; shift 2 ;;
        --version)  VERSION="${2:?--version requires a value}"; shift 2 ;;
        --repo)     REPO_URL="${2:?--repo requires a value}"; shift 2 ;;
        --no-pull)  NO_PULL=1; shift ;;
        --keep)     KEEP=1; shift ;;
        -h|--help)
            sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) fail "Unknown argument: $1 (try --help)" ;;
    esac
done

# -----------------------------------------------------------------------------
# Resolve the working directory: this checkout, or a fresh clone at VERSION.
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

in_checkout() {
    [[ -f "$SCRIPT_DIR/scripts/build_images.sh" && -f "$SCRIPT_DIR/k8s/40-app-deployment.yaml" && -f "$SCRIPT_DIR/Dockerfile" ]]
}

# Registry mode rewrites the image refs in the k8s manifests. Always do that
# on a fresh clone so we never modify the operator's own tracked checkout —
# unless they explicitly opt out with --no-pull.
if [[ "$NO_PULL" -eq 1 ]]; then
    REPO_DIR="$SCRIPT_DIR"
    [[ -d "$REPO_DIR/.git" ]] || warn "--no-pull given but $REPO_DIR is not a git checkout; continuing anyway."
elif [[ "$MODE" != "registry" && in_checkout && -f "$SCRIPT_DIR/.git/HEAD" ]]; then
    REPO_DIR="$SCRIPT_DIR"
    log "Running from a git checkout ($REPO_DIR)."
    if [[ "$VERSION" != "main" && "$VERSION" != "$REPO_REF" ]]; then
        log "Checking out requested version $VERSION ..."
        git -C "$REPO_DIR" fetch --tags --quiet || true
        git -C "$REPO_DIR" checkout "$VERSION" --quiet
    fi
else
    TMP_CLONE="$(mktemp -d)"
    trap '[[ "$KEEP" -eq 0 ]] && rm -rf "$TMP_CLONE"' EXIT
    log "Cloning $REPO_URL (ref: $VERSION) into $TMP_CLONE ..."
    git clone --quiet --depth 1 --branch "$VERSION" "$REPO_URL" "$TMP_CLONE" \
        || fail "git clone of $REPO_URL@$VERSION failed. Check the URL/version or pass --repo."
    REPO_DIR="$TMP_CLONE"
fi
cd "$REPO_DIR"

# -----------------------------------------------------------------------------
# Pre-flight
# -----------------------------------------------------------------------------
command -v git    >/dev/null 2>&1 || fail "git not found in PATH."
command -v docker >/dev/null 2>&1 || fail "docker not found in PATH."
command -v kubectl >/dev/null 2>&1 || fail "kubectl not found in PATH."

CURRENT_CTX="$(kubectl config current-context 2>/dev/null || true)"
[[ -n "$CURRENT_CTX" ]] || fail "No active kubectl context. Run 'kubectl config use-context <name>' first."
log "Active kubectl context: $CURRENT_CTX"

command -v python3 >/dev/null 2>&1 || fail "python3 not found in PATH (needed for key generation)."

# -----------------------------------------------------------------------------
# Mode: build local — the default, for kind/k3d/minikube/Docker Desktop
# -----------------------------------------------------------------------------
if [[ "$MODE" == "build-local" ]]; then
    log "== Mode: build local images =="
    log "Running scripts/build_images.sh (this prompts for SMTP + Ollama settings) ..."
    ./scripts/build_images.sh

    # Detect the cluster so we can load the images into the right runtime.
    CLUSTER_TOOL="generic"
    case "$CURRENT_CTX" in
        kind-*)            CLUSTER_TOOL="kind" ;;
        k3d-*)             CLUSTER_TOOL="k3d" ;;
        minikube*)         CLUSTER_TOOL="minikube" ;;
        docker-desktop)    CLUSTER_TOOL="docker-desktop" ;;
    esac
    log "Detected cluster tool: $CLUSTER_TOOL"

    case "$CLUSTER_TOOL" in
        kind)
            command -v kind >/dev/null 2>&1 || fail "kind CLI not on PATH."
            log "Loading chat-room-server:latest + chatroom-mysql:latest into kind ..."
            kind load docker-image chat-room-server:latest chatroom-mysql:latest
            ;;
        k3d)
            command -v k3d >/dev/null 2>&1 || fail "k3d CLI not on PATH."
            log "Importing images into k3d ..."
            k3d image import chat-room-server:latest chatroom-mysql:latest
            ;;
        minikube)
            command -v minikube >/dev/null 2>&1 || fail "minikube CLI not on PATH."
            log "Loading images into minikube ..."
            minikube image load chat-room-server:latest chatroom-mysql:latest
            ;;
        docker-desktop)
            # The built-in k8s shares the Docker daemon, so imagePullPolicy:
            # Never already finds the images. Nothing to load.
            log "Docker Desktop k8s shares the Docker daemon — images already visible."
            ;;
        *)
            fail "Can't auto-load images into context '$CURRENT_CTX' from this machine.
  kind / k3d / minikube / Docker Desktop are supported for the build-local path.
  For a real multi-node cluster, deploy the prebuilt images instead:
    ./install-k8s.sh --registry pratic2001
  (the baked MySQL credentials are auto-extracted from the image)"
            ;;
        esac

    log "Deploying to the cluster ..."
    ./scripts/deploy_k8s.sh

    echo
    log "install-k8s.sh: DONE. Access hints:"
    log "  kubectl -n chatroom get svc chatroom-app"
    log "  kubectl -n chatroom port-forward svc/chatroom-app 8000:80   # then open http://localhost:8000"
    exit 0
fi

# -----------------------------------------------------------------------------
# Mode: registry — pull prebuilt images from Docker Hub (multi-node clusters)
# -----------------------------------------------------------------------------
log "== Mode: registry pull =="

# Split USER[:TAG]
REG_USER="${REGISTRY_SPEC%%:*}"
if [[ "$REGISTRY_SPEC" == *:* ]]; then
    REG_TAG="${REGISTRY_SPEC##*:}"
else
    REG_TAG="latest"
fi
[[ -n "$REG_USER" ]] || fail "--registry needs a Docker Hub username, e.g. pratic2001 or pratic2001:v1.0.0"

# Image refs: the running images this mode deploys (and reads credentials from).
APP_IMG="docker.io/$REG_USER/chatroom-app:$REG_TAG"
MYSQL_IMG="docker.io/$REG_USER/chatroom-mysql:$REG_TAG"

# The MySQL image's 99-grants.sql baked MYSQL_ROOT_PASSWORD at CI build time.
# Since v0.1.2 the same two values are also baked into
# /etc/chatroom/mysql-credentials INSIDE the image, so the operator no longer
# has to re-enter the exact pipeline values — we pull them straight out:
#   docker run --rm pratic2001/chatroom-mysql:latest cat /etc/chatroom/mysql-credentials
# If both vars are already exported, use those and skip the pull.
if [ -z "${MYSQL_ROOT_PASSWORD:-}" ] || [ -z "${REPLICATION_PASSWORD:-}" ]; then
    log "Extracting baked MySQL credentials from ${MYSQL_IMG} ..."
    CREDS="$(docker run --rm --entrypoint /bin/sh "$MYSQL_IMG" \
        -c 'cat /etc/chatroom/mysql-credentials' 2>/dev/null || true)"
    MYSQL_ROOT_PASSWORD="$(printf '%s' "$CREDS" | sed -n 's/^MYSQL_ROOT_PASSWORD=//p')"
    REPLICATION_PASSWORD="$(printf '%s' "$CREDS" | sed -n 's/^REPLICATION_PASSWORD=//p')"
fi

# Refuse to proceed unless BOTH values are present (explicit or extracted).
# A wrong/missing password yields a 1045 Access denied at runtime.
: "${MYSQL_ROOT_PASSWORD:?Set MYSQL_ROOT_PASSWORD (baked credentials are missing in ${MYSQL_IMG}; use a newer image tag or export it explicitly)}"
: "${REPLICATION_PASSWORD:?Set REPLICATION_PASSWORD (baked credentials are missing in ${MYSQL_IMG}; use a newer image tag or export it explicitly)}"

# Prompt for SMTP + Ollama unless already exported. Registry mode doesn't run
# build_images.sh, so we ask here — this is the "everything ready to run" step.
prompt_default() { # $1=prompt $2=default ; echoes the value
    local ans
    if [[ -n "${!1:-}" ]]; then printf '%s' "${!1}"; return; fi
    printf '%s [%s]: ' "$2" "${3:-}" >&2
    IFS= read -r ans
    printf '%s' "${ans:-${3:-}}"
}
MAIL_HOST="$(prompt_default MAIL_HOST 'SMTP host (blank disables invite emails):' '')"
MAIL_PORT="$(prompt_default MAIL_PORT 'SMTP port:' '587')"
MAIL_USER="$(prompt_default MAIL_USER 'SMTP username (blank if none):' '')"
MAIL_PASSWORD="$(prompt_default MAIL_PASSWORD 'SMTP password (blank if none):' '')"
MAIL_FROM="$(prompt_default MAIL_FROM 'From: header:' 'Chat Room <no-reply@example.com>')"
MAIL_USE_TLS="$(prompt_default MAIL_USE_TLS 'Use TLS (true/false):' 'true')"
OLLAMA_HOST="$(prompt_default OLLAMA_HOST 'Ollama host (with scheme, e.g. http://1.2.3.4):' 'http://localhost')"
OLLAMA_PORT="$(prompt_default OLLAMA_PORT 'Ollama port:' '11434')"
OLLAMA_MODEL="$(prompt_default OLLAMA_MODEL 'Ollama model:' 'llama3.2')"
# AI agent search providers (optional). Leave blank and the tools still work
# keyless: web_search falls back to Bing web RSS, web_news to Google News RSS
# (DuckDuckGo is the final last resort). Set BRAVE_API_KEY and/or GOOGLE_API_KEY
# + GOOGLE_CSE_ID to prefer Brave / Google. Same default-as-existing-value
# behavior as the prompts above.
BRAVE_API_KEY="$(prompt_default BRAVE_API_KEY 'Brave API key (https://brave.com/search/api/; blank = skip):' '')"
GOOGLE_API_KEY="$(prompt_default GOOGLE_API_KEY 'Google API key (blank = skip Google):' '')"
GOOGLE_CSE_ID="$(prompt_default GOOGLE_CSE_ID 'Google Programmable Search Engine ID:' '')"
if [[ -n "$GOOGLE_API_KEY" && -z "$GOOGLE_CSE_ID" ]] || [[ -z "$GOOGLE_API_KEY" && -n "$GOOGLE_CSE_ID" ]]; then
    warn "GOOGLE_API_KEY and GOOGLE_CSE_ID must both be set for Google search; Google will be skipped (the keyless Bing/Google-News fallbacks still run)."
fi

# Generate the runtime env + rendered Secrets/ConfigMap using the same shared
# helpers build_images.sh uses. We override the two MySQL credentials with the
# baked-in values, and the SMTP/Ollama/search values with what was just
# collected above.
#
# IMPORTANT: the eval must NOT clobber the prompted values. The prompts above
# (MAIL_*, OLLAMA_*, BRAVE_API_KEY, GOOGLE_API_KEY, GOOGLE_CSE_ID) run first,
# but load_or_generate_runtime_secrets would reset those same variables to
# their generated defaults (blank SMTP, http://ollama, blank search keys),
# silently discarding what the operator just typed — a bug that kept the
# SMTP/Ollama prompts in this mode dead. So we filter the eval output down to
# the non-prompted config vars (MySQL/Redis secrets and topology); the
# prompted values survive untouched.
# shellcheck disable=SC1091
source scripts/_random_password.sh
eval "$(load_or_generate_runtime_secrets "" | grep -vE '^(MYSQL_PASSWORD|REPLICATION_PASSWORD|MAIL_HOST|MAIL_PORT|MAIL_USER|MAIL_PASSWORD|MAIL_FROM|MAIL_USE_TLS|OLLAMA_HOST|OLLAMA_PORT|OLLAMA_MODEL|BRAVE_API_KEY|GOOGLE_API_KEY|GOOGLE_CSE_ID)=')"
MYSQL_PASSWORD="$MYSQL_ROOT_PASSWORD"
REPLICATION_PASSWORD="$REPLICATION_PASSWORD"
export MYSQL_PASSWORD REPLICATION_PASSWORD \
       MAIL_HOST MAIL_PORT MAIL_USER MAIL_PASSWORD MAIL_FROM MAIL_USE_TLS \
       OLLAMA_HOST OLLAMA_PORT OLLAMA_MODEL \
       BRAVE_API_KEY GOOGLE_API_KEY GOOGLE_CSE_ID

log "Writing app/.env.runtime + k8s/secrets.runtime.yaml ..."
write_runtime_env_file "$REPO_DIR/app/.env.runtime" "scripts/install-k8s.sh"
render_k8s_secrets      "$REPO_DIR/k8s/secrets.runtime.yaml" "scripts/install-k8s.sh"
chmod 600 "$REPO_DIR/app/.env.runtime" "$REPO_DIR/k8s/secrets.runtime.yaml"

# Point the Deployments at the registry images (the committed manifests use
# local image names + imagePullPolicy: Never). Rewrite the two chatroom image
# refs and flip the pull policy so kubelet actually fetches from Docker Hub.
#
# imagePullPolicy is set to Always, NOT IfNotPresent. The default registry tag
# is a floating ":latest"; IfNotPresent reuses whatever :latest a node happens
# to have cached, so after a cleanup + re-install the nodes silently keep
# running the OLD image (we saw this bite: a stale :latest that still baked the
# pre-2061-fix repl user). Always forces kubelet to re-resolve :latest on every
# start, so a fresh `install-k8s.sh --registry` always pulls the current build.
# For pinned tags (e.g. --registry pratic2001:v1.0.0) Always is still safe and
# costs one extra digest lookup.
log "Rewriting image refs to docker.io/$REG_USER/chatroom-*:$REG_TAG ..."
sed -i "s|image: chat-room-server:latest|image: ${APP_IMG}|; s|imagePullPolicy: Never|imagePullPolicy: Always|" \
    "$REPO_DIR/k8s/40-app-deployment.yaml"
sed -i "s|image: chatroom-mysql:latest|image: ${MYSQL_IMG}|; s|imagePullPolicy: Never|imagePullPolicy: Always|" \
    "$REPO_DIR/k8s/23-mysql-statefulset.yaml"

log "Deploying to the cluster (pulling $APP_IMG and $MYSQL_IMG) ..."
./scripts/deploy_k8s.sh

echo
log "install-k8s.sh (registry mode): DONE."
log "  The running images are $APP_IMG / $MYSQL_IMG."
log "  kubectl -n chatroom get pods   # watch mysql-0 / app come up"
