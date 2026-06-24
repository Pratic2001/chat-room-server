# chat-room-server — Runbook

This runbook walks a fresh user through deploying the chat-room-server app
(the FastAPI backend + MySQL + frontend, plus a k8s Ingress) to their own
k8s cluster, using the scripts in this repository. Nothing in this workflow
references machine-specific paths, credentials, or self-signed certs — you
can hand it to anyone and they can follow it from a clean clone.

> **If you just want the short version:** run `./scripts/build_images.sh`,
> load the images into your cluster's runtime, then run
> `./scripts/deploy_k8s.sh`. Everything else in this document is the
> detailed explanation of what those two commands do and what to do when
> they go wrong.
>
> **If you built the images elsewhere** (CI, a teammate, or in a
> registry): run `./scripts/write_runtime_env.sh --from-stdin` and paste
> the 9 values from `app/.env.runtime` — one per line, in the order
> documented in §6.5 — then run `./scripts/deploy_k8s.sh`. See §6.5.

---

## 1. What gets deployed

| Component | Image | Replicas | Storage | Exposed via |
| --- | --- | --- | --- | --- |
| `chatroom-app` (FastAPI + static frontend) | `chat-room-server:latest` | 1 per cluster node (set by `deploy_k8s.sh`) | none | ClusterIP Service `:80` → Ingress |
| `mysql` (database, schema pre-baked) | `chatroom-mysql:latest` | 1 | 5Gi PVC | ClusterIP Service `:3306` (cluster-internal only) |
| `chatroom` Ingress | — | — | — | routes `chatroom.local/` to the app Service |

The MySQL Service is `ClusterIP` and has no Ingress route, so it is not
reachable from outside the cluster. The only entry point is the app, via
the Ingress.

---

## 2. Prerequisites

You need all of the following on the machine where you'll run the scripts
(the "build host"). It can be a laptop, a CI runner, a VM — anywhere with
a working Docker daemon and network access to your k8s cluster's API.

### 2.1 Local tooling

| Tool | Why | How to install |
| --- | --- | --- |
| **Docker Engine 20.10+** | Builds the two container images. | https://docs.docker.com/engine/install/ |
| **kubectl** | Talks to your cluster. Must be on `PATH`. | https://kubernetes.io/docs/tasks/tools/ |
| **bash 4+** | Runs the scripts. macOS ships bash 3.2 by default — install 5+ via Homebrew if you're on a Mac. | `brew install bash` on macOS; Linux distros ship a new enough bash. |
| **GNU coreutils** (`base64`, `tr`, `head`, `sed`, `awk`) | Used by the password generator. | Preinstalled on Linux; on macOS: `brew install coreutils`. |
| **python3** | Used by `build_images.sh` to generate `SECRET_KEY` and `ROOM_SECRET_KEY` (Fernet). | Preinstalled on most distros; macOS: `brew install python@3.11`. |

You do **not** need a local MySQL server, the `mysql` CLI, Python pip, or
git LFS for the k8s workflow — those are only required for the older
"run on the host" workflow documented in `CLAUDE.md`.

### 2.2 A working k8s cluster

The scripts work on any conformant k8s cluster that has:

- **A default `StorageClass** (so the MySQL PVC can be provisioned
  dynamically). On managed clusters (GKE, EKS, AKS) this is the default.
  On local tools, you may need to confirm it:
  ```
  kubectl get storageclass
  # look for one marked (default)
  ```
- **A node that can run both images** with the resources requested in
  `k8s/21-mysql-deployment.yaml` and `k8s/40-app-deployment.yaml` (256Mi
  memory requested, 1Gi memory limit; 100m–1000m CPU).
- **Network access from the build host to the cluster's API server**
  (typically `https://<api-server>:6443`).

Tested-on combinations (this is not exhaustive; any cluster that meets the
above works):

- **kind** (Kubernetes in Docker) — easiest on a laptop.
- **k3d** (k3s in Docker) — similar to kind, lighter footprint.
- **minikube** — fine, but more setup for the image-loading step.
- **GKE / EKS / AKS** — works; the `imagePullPolicy: Never` on the
  Deployments is overridden by the registry-based workflow if you also
  push the images to a registry your cluster can pull from (see §6.3).

### 2.3 An Ingress controller

The deploy script applies a `networking.k8s.io/v1` Ingress resource. If
your cluster has **no** Ingress controller, the Ingress object will exist
but won't route traffic — you'll get a `port-forward` hint from the
deploy script and can use that for testing (see §7.4).

Common choices:

- **ingress-nginx** — the default for kind, minikube, and most managed
  clusters that offer an "nginx ingress" add-on. This is what
  `k8s/50-ingress.yaml` is configured for (`ingressClassName: nginx`).
- **Traefik, Kong, HAProxy, ALB, GCP Ingress, etc.** — supported by
  editing the `ingressClassName` field in `k8s/50-ingress.yaml`. The
  proxy timeouts and body-size annotations are nginx-specific; remove
  them if you switch controllers.

To install ingress-nginx on a bare cluster:

```
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.2/deploy/static/provider/cloud/deploy.yaml
```

For kind: https://kind.sigs.k8s.io/docs/user/ingress/

#### 2.3.1 Tuning ingress-nginx and MetalLB for your cluster

`scripts/deploy_k8s.sh` sets `tolerationSeconds: 10` on every pod in
this stack (Redis, MySQL, chatroom-app) on the standard
`node.kubernetes.io/unreachable` and `node.kubernetes.io/not-ready`
NoExecute taints, so when a node goes unhealthy the pods are evicted
within 10s rather than waiting the k8s default of 300s. **The
cluster-wide components in front of this stack have their own values,
and the shipped defaults are not always a good fit for every
environment — review and tune them to match your cluster's size,
traffic profile, and maintenance windows:**

- **ingress-nginx controller** — installed from the URL above (or via
  your distro's package). Two fields are commonly worth overriding,
  usually via a `values.yaml` for the Helm chart or a `controller:` /
  `controllerConfig:` block in the manifest:

  - `replicaCount` (or `spec.replicas` in the manifest) — the
    default is 1, which is a single point of failure for the data
    plane. Set this to 2 or more for any non-toy cluster, and
    spread the pods with a `topologySpreadConstraints` block on
    nodes (the same pattern as `k8s/40-app-deployment.yaml`). For
    a single-node dev cluster, 1 is fine.
  - `tolerationSeconds` on the controller pod — the
    default is 300s, mostly so the controller has time to drain
    WebSocket / long-poll connections. Match it to your longest
    expected in-flight request: a chat workload (idle WS
    connections + small HTTP) is happy with 30–60s; a workload
    with large uploads or slow upstream calls needs more. Pick a
    value that's *at least* as long as `proxy-read-timeout` and
    `proxy-send-timeout` on the Ingress annotations in
    `k8s/50-ingress.yaml` (currently 3600s) — otherwise the
    controller gets SIGKILLed mid-response during a rolling
    update.

  After changing either value, roll the controller:
  `kubectl -n ingress-nginx rollout restart deploy/ingress-nginx-controller`.

- **MetalLB speaker / controller** (only relevant if you're using
  MetalLB to give bare-metal clusters a `LoadBalancer` Service —
  see the kind/k3d add-on guides). Both pods ship with
  `tolerationSeconds` of 300. That's appropriate for
  production BGP speakers (BGP neighbors need time to withdraw
  routes gracefully) but is a long wait on a single-node dev
  cluster. For dev / kind / k3d, 30s is plenty; for production
  BGP, keep the default or raise it. To change it, edit the
  `MetalLB` / `MetalLBSpeaker` / `MetalLBController` CRs (Helm
  chart values: `speaker.tolerationSeconds`,
  `controller.tolerationSeconds`) and re-apply.

The principle: this project's `tolerationSeconds: 10` is deliberately
tight because the pods hold no state worth keeping bound to a dead
node — when a node goes NotReady, evict fast and let the rescheduled
replica come back up cleanly. Anything else in the request path
(ingress controller, the LoadBalancer, BGP speakers) has different
trade-offs and its own default — **read it, then decide**.

### 2.4 DNS (optional but recommended)

The committed Ingress uses the placeholder host `chatroom.local`. To
reach it from a browser, add an entry like `127.0.0.1 chatroom.local` to
your `/etc/hosts` (on the build host, not the cluster). For a
production-style deployment, point a real DNS A/AAAA record at the
Ingress's external address and update `host:` in `k8s/50-ingress.yaml`.

---

## 3. First-time setup

```
git clone <this-repo-url> chat-room-server
cd chat-room-server
```

That's it. There is no `pip install`, no `.env` to fill in, no
`database_setup.sql` to run by hand — the scripts handle all of it.

> **One thing to know:** the scripts write a file called
> `app/.env.runtime` in the repo. It contains the MySQL root password,
> the JWT signing key, the Fernet room-secret key, and (if supplied)
> the SMTP relay credentials. It is gitignored.
> **Do not commit it.** Treat it like any other credential.

---

## 4. Build the images

```
./scripts/build_images.sh
```

What this does, in order:

1. Refuses to run if `docker` isn't on `PATH`.
2. Generates a random URL-safe MySQL root password (no `@:/?#[]%`
   characters, so the value is safe to embed in a SQLAlchemy URL).
3. Generates a JWT `SECRET_KEY` and a Fernet `ROOM_SECRET_KEY` (Python
   `secrets` and `cryptography.fernet` respectively).
4. Writes those three values, plus the algorithm and token-expiry
   settings, into `app/.env.runtime` with `chmod 600`.
5. Prompts for six SMTP settings — `MAIL_HOST`, `MAIL_PORT`, `MAIL_USER`,
   `MAIL_PASSWORD`, `MAIL_FROM`, `MAIL_USE_TLS` — and writes them to
   `app/.env.runtime` next to the secrets. `MAIL_PASSWORD` is read
   silently (so it doesn't echo). Leave `MAIL_HOST` blank to disable
   invite emails entirely. On a re-run, the previous values are used
   as defaults — pass `--rebuild` to start fresh. See §6.5 for the
   full layout and the local debug-sink path.
6. Runs `docker build` for the MySQL image, passing the password as a
   build-arg. The MySQL Dockerfile `sed`s the value into
   `mysql/init/99-grants.sql`, so on first boot the container pins the
   root password to that exact value.
7. Runs `docker build` for the app image. **No `.env` is baked in** —
   the app reads config from env at runtime.

Output: two images in the local Docker daemon, tagged `:latest`:

- `chat-room-server:latest`
- `chatroom-mysql:latest`

### 4.1 Re-running

By default, `build_images.sh` reuses `app/.env.runtime` if it already
exists, so the MySQL image stays in sync with the password the deploy
script will put in the k8s Secret. Two flags:

- `--no-cache` — pass `--no-cache` to both `docker build` invocations.
- `--rebuild` — ignore the existing `app/.env.runtime` and generate a
  fresh MySQL password (use this if you suspect the secret has leaked).
  After `--rebuild`, the next `deploy_k8s.sh` will create a Secret with
  the new password, but the existing PVC still holds the *old* one. To
  fully rotate, follow §8.

### 4.2 Sanity check

```
docker images | grep -E 'chat-room|chatroom-mysql'
# REPOSITORY           TAG       IMAGE ID
# chat-room-server     latest    ...
# chatroom-mysql       latest    ...
```

---

## 5. Load the images into your cluster

The Deployments use `imagePullPolicy: Never`, which tells kubelet to use
an image that's already on the node's runtime — there is no registry
involved. The catch is that "already on the node" depends on your
cluster topology:

- **Single-node local cluster (kind, k3d, minikube, Docker Desktop):**
  the image is in your laptop's Docker daemon, and the cluster runs in
  the same daemon. You still need to tell the cluster-runtime to pick
  it up. Each tool has its own command (see below).
- **Multi-node cluster, or a managed cluster (GKE/EKS/AKS):** the
  images aren't on the cluster's nodes. You need to either push them to
  a registry the cluster can pull from, or build them inside the cluster
  (e.g. with `k3d`'s in-cluster registry). See §6.3.

### 5.1 kind

```
kind load docker-image chat-room-server:latest chatroom-mysql:latest
```

That ships the images to every node in the `kind` cluster. Repeat after
every `build_images.sh` run.

### 5.2 k3d

```
k3d image import chat-room-server:latest chatroom-mysql:latest -c <cluster-name>
```

The default cluster name is `k3s-default`.

### 5.3 minikube

```
minikube image load chat-room-server:latest
minikube image load chatroom-mysql:latest
```

(For an older minikube that lacks `image load`, use the shell-into-node
trick: `minikube ssh "docker load"` against `docker save` output from
the build host.)

### 5.4 Docker Desktop (built-in k8s)

Docker Desktop's built-in cluster shares the host's Docker daemon, so
images are visible without an extra step. **Skip this section** if
you're using Docker Desktop.

### 5.5 Verify

After loading:

```
# kind example
docker exec -it kind-control-plane crictl images | grep -E 'chatroom|chat-room'
```

You should see both `chatroom-mysql` and `chat-room-server` listed.

---

## 6. Deploy

### 6.1 Confirm your kubectl context

The deploy script refuses to run with an empty context, so you'll see a
clear error if you forgot to point `kubectl` at the right cluster:

```
kubectl config current-context   # make sure this is the cluster you want
```

### 6.2 Run the deploy

```
./scripts/deploy_k8s.sh
```

What it does, in order:

1. Refuses if `kubectl` is missing or no context is active.
2. Loads credentials from `app/.env.runtime` (refuses if missing —
   "Run scripts/build_images.sh first"). It also refuses if
   `k8s/secrets.runtime.yaml` is missing — that file is gitignored
   and is produced by `build_images.sh` (or `write_runtime_env.sh`).
3. Creates the `chatroom` namespace if it doesn't exist.
4. Sanity-checks the live cluster: if the `chatroom-app` Secret
   already holds a `MYSQL_PASSWORD` that disagrees with
   `app/.env.runtime`, it fails fast with a clear message. This
   catches the case where the rendered manifest was regenerated
   without re-applying — MySQL would 1045 every login otherwise.
5. `kubectl apply -f k8s/` — applies all manifests in lexical order,
   including `k8s/secrets.runtime.yaml`. That single file is the
   source of truth for the `chatroom-mysql` and `chatroom-app`
   Secrets and the `chatroom-app` ConfigMap.
6. Scales `chatroom-app` to one replica per cluster node (queries
   `kubectl get nodes | wc -l`). The committed Deployment manifest has
   no `replicas:` field — see the comment in
   `k8s/40-app-deployment.yaml`. Defaults to 2 if the node count
   can't be determined.
7. `kubectl rollout status` for both Deployments, with a 5-minute
   timeout each.
8. Prints the Ingress address if one was assigned, or a `port-forward`
   hint if not.

> **Why this changed:** prior to this revision the deploy script wrote
> the Secrets + ConfigMap imperatively (`kubectl create secret ... |
> kubectl apply`). That kept secrets off disk entirely but left the
> committed `k8s/10-mysql-secret.yaml` and `k8s/31-app-secret.yaml`
> as `REPLACE_AT_DEPLOY_TIME` placeholders that would silently apply
> literal placeholders if anyone bypassed the script. The current
> flow has `build_images.sh` render the real values into
> `k8s/secrets.runtime.yaml` (gitignored + dockerignored), so a
> bare `kubectl apply -f k8s/` from a fresh checkout also produces
> a working cluster. The committed templates under `k8s/` are now
> marked as templates and are intentionally invalid — see the
> comments at the top of `k8s/10-mysql-secret.yaml` and
> `k8s/31-app-secret.yaml`.

A successful run ends with something like:

```
============================================================
  chatroom deployed to namespace "chatroom"
============================================================

Pods:
NAME                          READY   STATUS    RESTARTS   AGE
chatroom-app-7f9c...          1/1     Running   0          30s
chatroom-app-b8a1...          1/1     Running   0          30s
mysql-7d5e...                 1/1     Running   0          45s
```

(The two `chatroom-app` pods above are a 2-node cluster. On a
3-node cluster you'd see three app pods; on kind's default
1-node cluster, just one. See §6.2 step 7.)

### 6.3 Pushing to a registry (managed clusters / multi-node)

The `build_images.sh` script only tags images in the local Docker
daemon. If your cluster's nodes can't reach that daemon (e.g. EKS, GKE,
AKS, or a multi-node kind setup), push to a registry and tell the
Deployments to pull from there. This section uses **Docker Hub** as the
example (the most common case); the steps are identical for any other
OCI registry — only the hostname changes.

#### 6.3.1 One-time setup on the build host

1. **Create a Docker Hub account** at https://hub.docker.com/ if you
   don't have one. Create two repositories there, both **public** (or
   **private** if you'll configure image-pull secrets — see §6.3.4):

   - `<your-dockerhub-username>/chatroom-app`
   - `<your-dockerhub-username>/chatroom-mysql`

   The repo names don't have to match the local image names exactly;
   you choose the tag scheme below.

2. **Log in once** from the build host:

   ```
   docker login
   # Username: <your-dockerhub-username>
   # Password: <your-personal-access-token-or-password>
   ```

   This writes `~/.docker/config.json`. The credentials persist until
   you `docker logout`. Using a Docker Hub **personal access token**
   (https://hub.docker.com/settings/security) instead of your account
   password is recommended — you can scope the token to "Read, Write,
   Delete" and revoke it without rotating your password.

#### 6.3.2 Tag and push the images

Pick a version tag (anything that helps you roll back — date, semver,
git SHA, all fine). The example below uses `v1.0.0`:

```
DOCKERHUB_USER=<your-dockerhub-username>          # edit me
TAG=v1.0.0                                          # edit me

# Tag the local images. Docker Hub addresses look like
# docker.io/<user>/<repo>:<tag> — the docker.io/ prefix is implicit.
docker tag chat-room-server:latest \
           docker.io/$DOCKERHUB_USER/chatroom-app:$TAG
docker tag chatroom-mysql:latest \
           docker.io/$DOCKERHUB_USER/chatroom-mysql:$TAG

# Push both layers.
docker push docker.io/$DOCKERHUB_USER/chatroom-app:$TAG
docker push docker.io/$DOCKERHUB_USER/chatroom-mysql:$TAG
```

You should see `digest: sha256:...` lines for each layer. If the push
hangs or returns `denied: requested access to the resource is denied`,
your `docker login` token has expired or you tagged under the wrong
username — re-run `docker login` and double-check the username.

Verify the push landed:

```
# In a browser:
https://hub.docker.com/r/<your-dockerhub-username>/chatroom-app/tags
https://hub.docker.com/r/<your-dockerhub-username>/chatroom-mysql/tags
```

#### 6.3.3 Tell the cluster to pull from Docker Hub

The committed manifests have `image: chat-room-server:latest` (and
`image: chatroom-mysql:latest`) with `imagePullPolicy: Never`. Update
them so kubelet actually fetches from Docker Hub.

**`k8s/40-app-deployment.yaml`** — change the container `image:` line:

```
        - name: app
          image: docker.io/<your-dockerhub-username>/chatroom-app:v1.0.0   # was: chat-room-server:latest
          imagePullPolicy: IfNotPresent                                     # was: Never
```

**`k8s/21-mysql-deployment.yaml`** — same shape:

```
        - name: mysql
          image: docker.io/<your-dockerhub-username>/chatroom-mysql:v1.0.0 # was: chatroom-mysql:latest
          imagePullPolicy: IfNotPresent                                     # was: Never
```

`IfNotPresent` (rather than `Always`) is fine — it means kubelet will
skip the pull if the node already has that exact tag, which saves time
on the second pod after a rollout. If you want every pull to be
authoritative, use `Always`.

If you'd rather not edit the committed manifests by hand, you can `sed`
them in place before applying:

```
DOCKERHUB_USER=<your-dockerhub-username>
TAG=v1.0.0
sed -i.bak \
  -e "s|image: chat-room-server:latest|image: docker.io/$DOCKERHUB_USER/chatroom-app:$TAG|" \
  -e 's|imagePullPolicy: Never|imagePullPolicy: IfNotPresent|' \
  k8s/40-app-deployment.yaml
sed -i.bak \
  -e "s|image: chatroom-mysql:latest|image: docker.io/$DOCKERHUB_USER/chatroom-mysql:$TAG|" \
  -e 's|imagePullPolicy: Never|imagePullPolicy: IfNotPresent|' \
  k8s/21-mysql-deployment.yaml
```

Re-run `./scripts/deploy_k8s.sh` after the edit. The `.bak` files are
safe to delete (or add to `.gitignore`).

Then watch kubelet actually pull from Docker Hub:

```
kubectl -n chatroom get pods -w
# during the first rollout you'll see:
#   Normal  Pulling    ...  Pulling image "docker.io/<user>/chatroom-app:v1.0.0"
#   Normal  Pulled     ...  Successfully pulled image ... in 5.2s
```

#### 6.3.4 Private repos (image pull secrets)

If you made the Docker Hub repos **private**, kubelet will fail with
`ImagePullBackOff: pull access denied`. Fix it by creating a
`docker-registry` Secret in the `chatroom` namespace and referencing it
from each Deployment:

```
kubectl create secret docker-registry dockerhub-pull \
    --namespace chatroom \
    --docker-server=docker.io \
    --docker-username=<your-dockerhub-username> \
    --docker-password=<your-personal-access-token> \
    --docker-email=<your-email>
```

Then add to **both** `k8s/40-app-deployment.yaml` and
`k8s/21-mysql-deployment.yaml`, at the same indentation level as
`containers:`:

```
      imagePullSecrets:
        - name: dockerhub-pull
```

Re-apply with `kubectl apply -f k8s/`.

#### 6.3.5 Pushing updates later

After editing code and rerunning `./scripts/build_images.sh`, the local
`:latest` tags are refreshed. To publish a new version:

```
TAG=v1.0.1                              # bump me
DOCKERHUB_USER=<your-dockerhub-username>
docker tag chat-room-server:latest docker.io/$DOCKERHUB_USER/chatroom-app:$TAG
docker tag chatroom-mysql:latest     docker.io/$DOCKERHUB_USER/chatroom-mysql:$TAG
docker push docker.io/$DOCKERHUB_USER/chatroom-app:$TAG
docker push docker.io/$DOCKERHUB_USER/chatroom-mysql:$TAG
```

Then update `image:` in both Deployment manifests to the new tag (or
apply a `kubectl set image` command). For more on rolling out app-only
updates without touching the database image, see §8.3.

#### 6.3.6 Other registries (GHCR, ECR, GCR, Quay, etc.)

The flow is identical — only the hostname and login change. Examples:

- **GitHub Container Registry**:
  ```
  echo $GITHUB_TOKEN | docker login ghcr.io -u <github-username> --password-stdin
  docker tag chat-room-server:latest ghcr.io/<github-username>/chatroom-app:v1.0.0
  docker tag chatroom-mysql:latest     ghcr.io/<github-username>/chatroom-mysql:v1.0.0
  docker push ghcr.io/<github-username>/chatroom-app:v1.0.0
  docker push ghcr.io/<github-username>/chatroom-mysql:v1.0.0
  ```
- **Amazon ECR** (auth token rotates every 12h, so always log in just
  before pushing):
  ```
  aws ecr get-login-password --region <region> | \
      docker login --username AWS --password-stdin <aws-account-id>.dkr.ecr.<region>.amazonaws.com
  ECR=<aws-account-id>.dkr.ecr.<region>.amazonaws.com
  docker tag chat-room-server:latest $ECR/chatroom-app:v1.0.0
  docker tag chatroom-mysql:latest     $ECR/chatroom-mysql:v1.0.0
  docker push $ECR/chatroom-app:v1.0.0
  docker push $ECR/chatroom-mysql:v1.0.0
  ```
  For private ECR, also create a `docker-registry` Secret with the same
  `aws ecr get-login-password` value as the password.
- **Google Artifact Registry** / **Azure Container Registry**: same
  pattern; substitute `gcloud auth configure-docker` or `az acr login`
  for `docker login`.

In every case, the `image:` line in `k8s/40-app-deployment.yaml` and
`k8s/21-mysql-deployment.yaml` is the only thing that needs to change
in the k8s manifests.

### 6.4 `--uninstall`

```
./scripts/deploy_k8s.sh --uninstall
```

Deletes the `chatroom` namespace and every resource in it, **including
the PVC and all its data**. There is no `--uninstall --keep-data`; if
you want to preserve the data, take a `mysqldump` first (see §8.2).

### 6.5 Configuring SMTP

The room-invite flow uses SMTP to send the room secret phrase (and the
join link) to invited users. The build script prompts for six values
and persists them to `app/.env.runtime`; `build_images.sh` then renders
them into `k8s/secrets.runtime.yaml` (gitignored + dockerignored),
which `deploy_k8s.sh` applies as part of `kubectl apply -f k8s/`. One
Secret key (`MAIL_PASSWORD`) and five ConfigMap keys
(`MAIL_HOST`, `MAIL_PORT`, `MAIL_USER`, `MAIL_FROM`, `MAIL_USE_TLS`).

| Variable | Source | Purpose | Blank OK? |
| --- | --- | --- | --- |
| `MAIL_HOST` | ConfigMap `chatroom-app` | SMTP relay hostname. | **No — blank disables invite emails entirely.** The Invite button in the UI will return a clear 502. |
| `MAIL_PORT` | ConfigMap `chatroom-app` | SMTP relay port. Default 587. Integer 1–65535. | Yes (defaults to 587). |
| `MAIL_USER` | ConfigMap `chatroom-app` | SMTP auth username, if your relay requires it. | Yes. |
| `MAIL_PASSWORD` | Secret `chatroom-app` | SMTP auth password, if your relay requires it. | Yes. |
| `MAIL_FROM` | ConfigMap `chatroom-app` | `From:` header. Must be a `Display Name <addr@host>` string. | **No — required for any invite to work.** |
| `MAIL_USE_TLS` | ConfigMap `chatroom-app` | `true` (default) uses STARTTLS on the chosen port; `false` is needed for unauthenticated local debug relays. | Yes (defaults to `true`). |

`MAIL_PASSWORD` is read with `read -rs` in the build script so the
value doesn't echo to the terminal. All six are accepted blank.

**Quick reference: the values land here in k8s.**

```
# Values that must stay secret
kubectl -n chatroom get secret chatroom-app \
  -o jsonpath='{.data.MAIL_PASSWORD}' | base64 --decode

# Everything else
kubectl -n chatroom get configmap chatroom-app -o yaml
```

**Local debug sink — no real relay needed.** Python ships a debugging
SMTP server in the stdlib that just prints the email it receives:

```
# on the build host
python -m smtpd -n -c DebuggingServer localhost:1025 &

# then rebuild with the matching values:
./scripts/build_images.sh --rebuild    # prompts for MAIL_*
#   MAIL_HOST=localhost
#   MAIL_PORT=1025
#   MAIL_USE_TLS=false
#   MAIL_USER=     (blank)
#   MAIL_PASSWORD= (blank)
#   MAIL_FROM=Chat Room <no-reply@example.com>

./scripts/deploy_k8s.sh
```

Sign in via the UI, create a room, click **Invite** with a real email
address — the message appears in the `smtpd` stdout. **Port 465 = SMTPS
(implicit TLS); all other ports use opportunistic STARTTLS when
`MAIL_USE_TLS=true`.** So if you switch to port 465 you'll want
`MAIL_USE_TLS=false` (the `app/utils.py` SMTP layer treats port 465
specially — implicit TLS — and ignores `MAIL_USE_TLS` for it).

**If you built the images elsewhere** (CI, a teammate, a registry) and
the deployment is missing the SMTP values: run
`./scripts/write_runtime_env.sh --from-stdin` (or `--from-file`) and
paste the 9 lines from the build host's `app/.env.runtime`, in this
order:

```
MYSQL_PASSWORD
SECRET_KEY
ROOM_SECRET_KEY
MAIL_PASSWORD
MAIL_HOST
MAIL_USER
MAIL_PORT
MAIL_FROM
MAIL_USE_TLS
```

The values are validated as they're read (e.g. `MAIL_PORT` must be
1–65535, `MAIL_USE_TLS` must be `y`/`n`/`true`/`false`). Empty
`MAIL_HOST` disables invites; empty `MAIL_PASSWORD`/`MAIL_USER` are
fine for relays that don't authenticate. The script also writes
`k8s/secrets.runtime.yaml` (gitignored) so a bare
`kubectl apply -f k8s/` from a fresh checkout is enough to push the
values to the cluster.

**Rotating `MAIL_PASSWORD` only.** Edit `app/.env.runtime` in place,
then re-run `./scripts/deploy_k8s.sh` (it reads the file and rewrites
the Secret imperatively) and
`kubectl -n chatroom rollout restart deploy/chatroom-app`. No rebuild
needed — the app reads env at start. There's no separate
`change_mail_password.sh`; if you'd rather script the rotation,
`scripts/write_runtime_env.sh --from-file <file>` is the canonical
write path.

---

## 7. Verify the deployment

### 7.1 Pods are healthy

```
kubectl -n chatroom get pods
# both app pods: Running, 1/1 Ready
# mysql-0:      Running, 1/1 Ready
```

The MySQL pod takes longer to become Ready than the app pods because it
runs the schema migrations on first boot. If `mysql-0` stays at `0/1`
for more than a few minutes, see §9.1.

### 7.2 `/healthz` works

The simplest end-to-end check, regardless of Ingress:

```
kubectl -n chatroom port-forward svc/chatroom-app 8000:80
# in another terminal:
curl -s http://localhost:8000/healthz
# {"status":"ok"}
```

`/healthz` is intentionally DB-free (see the comment in `app/main.py`),
so a 200 here means the app process is up and the Ingress path doesn't
matter.

### 7.3 Sign-up + login

```
# in the same terminal as the port-forward
curl -s -X POST http://localhost:8000/auth/signup \
    -H 'Content-Type: application/json' \
    -d '{"username":"alice","email":"alice@example.com","password":"hunter2hunter2"}'

curl -s -X POST http://localhost:8000/auth/login \
    -H 'Content-Type: application/json' \
    -d '{"username":"alice","password":"hunter2hunter2"}'
# returns {"access_token":"...","token_type":"bearer","user_id":1,"username":"alice",...}
```

Save the `access_token` and try a JWT-protected endpoint:

```
TOKEN="<paste token here>"
curl -s http://localhost:8000/rooms/my -H "Authorization: Bearer $TOKEN"
# []
```

### 7.4 Reach the app via the Ingress

Find the Ingress address:

```
kubectl -n chatroom get ingress chatroom
# ADDRESS column is empty for most local clusters
```

If the `ADDRESS` is populated (some cloud LBs do this), you can reach the
app at `http://<address>/` — but you'll also need to point a hostname at
it (the Ingress is bound to `chatroom.local` by default; edit
`k8s/50-ingress.yaml` and re-apply if you want a different host).

If the `ADDRESS` is empty (kind, k3d, minikube), use `port-forward` as
in §7.2, or set up host-routing:

```
# kind: get the control-plane port
kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}'
# map 127.0.0.1:chatroom.local to that nodePort, or use the kind 'extraPortMappings'
# cluster-creation flag
```

### 7.5 Open the frontend

The same `port-forward` lets you open the web UI:

```
# in a browser
http://localhost:8000/
```

You should see the chat frontend served by FastAPI's static-files
mount.

---

## 8. Operating the deployment

### 8.1 Rotating the MySQL password

```
./scripts/build_images.sh --rebuild    # new MYSQL_PASSWORD, baked into MySQL image
                                      # and rendered into k8s/secrets.runtime.yaml
docker save chatroom-mysql:latest | <load into cluster>   # see §5
./scripts/deploy_k8s.sh               # applies the rendered Secret, rolls the Deployments
kubectl -n chatroom delete pod -l app.kubernetes.io/component=mysql   # restart with new image
# the pod re-runs the schema on the existing PVC; if the password in
# 99-grants.sql no longer matches the one used at first boot, MySQL
# may refuse to start. In that case, drop the PVC and re-create it.
```

The "drop the PVC" path is destructive — it loses all chat history. To
keep the data, do a `mysqldump` first, drop the PVC, let MySQL
re-initialise, then restore. See §8.2 for the dump.

### 8.2 Backing up the database

From a build host that has the `mysql` client and can reach the cluster:

```
# Start a port-forward to the MySQL Service
kubectl -n chatroom port-forward svc/mysql 3306:3306 &
# Read the password (URL-decoded — see §9.1.2 for why)
MYSQL_PASSWORD="$(python3 -c "from urllib.parse import unquote; \
  print(unquote(open('app/.env.runtime').read().split('MYSQL_PASSWORD=',1)[1].split('\n',1)[0]))")"
# Dump
mysqldump -h 127.0.0.1 -P 3306 -u root -p"$MYSQL_PASSWORD" \
    --single-transaction --routines --triggers \
    chatroom_db > chatroom-$(date +%Y%m%d).sql
```

To restore, point a `mysql` client at the same port-forward and pipe the
dump in.

### 8.3 Updating the app after a code change

```
# 1. edit code
# 2. rebuild
./scripts/build_images.sh
# 3. load the new app image into the cluster
kind load docker-image chat-room-server:latest   # or k3d / minikube equivalent
# 4. force a rollout
kubectl -n chatroom rollout restart deployment/chatroom-app
# 5. watch
kubectl -n chatroom rollout status deployment/chatroom-app
```

Because `app/.env.runtime` was reused (not regenerated), the JWT and
Fernet keys stay the same — existing user sessions keep working.

### 8.4 Updating the schema

Edit `mysql/init/01-schema.sql` (it's the source of truth) and any
additive DDL needed for migration. There is no auto-migration tool; the
init file only runs on an **empty** datadir. To apply schema changes
without nuking the PVC, run them manually:

```
MYSQL_PASSWORD="$(python3 -c "from urllib.parse import unquote; \
  print(unquote(open('app/.env.runtime').read().split('MYSQL_PASSWORD=',1)[1].split('\n',1)[0]))")"
kubectl -n chatroom exec -i mysql-0 -- mysql -uroot -p"$MYSQL_PASSWORD" chatroom_db < my-migration.sql
```

(`-i` instead of `-it` so stdin isn't a TTY and the heredoc pipes in
cleanly. The password is URL-decoded — see §9.1.2.)

(Or use Alembic / a proper migration tool — out of scope for this
project.)

### 8.5 Tearing down

```
./scripts/deploy_k8s.sh --uninstall
```

This is destructive: it deletes the PVC and the data on it. To preserve
the data, take a dump first (§8.2), then uninstall.

### 8.6 Restarting containers

There are four common reasons to want a restart, and they have different
"right answers" — picking the wrong one either causes downtime or leaves
the cluster in the same state as before.

#### 8.6.1 Pick a new image (you rebuilt `build_images.sh`)

After `./scripts/build_images.sh`, the cluster's local Docker daemon has
the new image, but the running pods are still running the old one
(`imagePullPolicy: Never` means k8s never re-checks). Force a rollout so
the new image is picked up:

```
kubectl -n chatroom rollout restart deploy/mysql
kubectl -n chatroom rollout restart deploy/chatroom-app
kubectl -n chatroom rollout status deploy/mysql --timeout=2m
kubectl -n chatroom rollout status deploy/chatroom-app --timeout=3m
```

`rollout restart` issues a rolling update — the app Deployment has
replicas set to one per cluster node (configured by `deploy_k8s.sh`,
see §6.2) + `maxUnavailable: 0` + `maxSurge: 1`, so traffic stays served
throughout (old pod only stops accepting connections once the new pod
is `Ready`). The MySQL Deployment is single-replica so expect a brief
gap of a few seconds while it comes back up.

For the MySQL pod specifically, an equivalent (and slightly cheaper)
form is just to delete the pod — the ReplicaSet controller re-creates
it immediately, picking up the new image:

```
kubectl -n chatroom delete pod -l app.kubernetes.io/component=mysql
```

Either form is fine. Use whichever you can type faster.

#### 8.6.2 Pick up a changed ConfigMap or Secret

ConfigMaps and Secrets are mounted into the pod at start; changing the
resource does **not** restart the pod automatically. The app pod
mounts the chatroom-app Secret as env vars (`envFrom: secretRef`), so
env changes also need a restart to take effect. Same commands as 8.6.1:

```
kubectl -n chatroom rollout restart deploy/chatroom-app
kubectl -n chatroom rollout status deploy/chatroom-app --timeout=3m
```

For Secrets only (no code change), you can also use
`scripts/deploy_k8s.sh` — it re-applies `k8s/secrets.runtime.yaml`
and rolls the Deployment so the new values are read.

#### 8.6.3 A pod is wedged (CrashLoopBackOff, hung, OOM-killed)

Don't `rollout restart` — that only helps if a new pod would actually
succeed. Investigate first:

```
kubectl -n chatroom describe pod -l app.kubernetes.io/component=app | tail -40
kubectl -n chatroom logs --previous -l app.kubernetes.io/component=app --tail=200
```

Once you understand the failure and have a reason to believe a fresh
start would succeed (e.g. you've fixed the upstream cause, or it's
clearly a transient runtime state issue), restart just that component:

```
kubectl -n chatroom delete pod -l app.kubernetes.io/component=app
# ReplicaSet creates a new one. Both replicas are replaced, but with
# maxUnavailable=0 the Service keeps serving throughout.
```

#### 8.6.4 Quick "bounce everything"

```
kubectl -n chatroom rollout restart deploy/mysql
kubectl -n chatroom rollout restart deploy/chatroom-app
```

Use this when you've changed cluster-wide infra (e.g. updated the
Ingress controller, rotated the MySQL root password via 8.1 and want
both pods to come up cleanly with the new Secret). Order matters:
restart MySQL first so the app pods can reconnect to it once they
come back up.

#### 8.6.5 What's safe to skip

- `kubectl delete deploy/...` is **not** a restart — it tears down
  the Deployment and (without `--cascade=orphan`) the ReplicaSet and
  Pods, leaving the cluster without the app until you re-apply the
  manifests. Use only for §8.5 teardown.
- `kubectl drain` / `kubectl cordon` are for node maintenance, not
  pod restart. They evict pods to a different node, which is the
  wrong tool here.

---

## 9. Troubleshooting

### 9.1 `mysql-0` stuck at `0/1 Ready`

Symptoms: `kubectl -n chatroom get pods` shows `mysql-0` in
`Running` but `0/1`. Logs:

```
kubectl -n chatroom logs mysql-0
```

Common causes, in order of likelihood:

- **Empty/MalformedPassword error from MySQL.** This usually means the
  PVC was previously initialised with a different password than the one
  the current `99-grants.sql` is trying to set. The fastest fix is to
  drop the PVC and let MySQL re-initialise (loses data):
  ```
  kubectl -n chatroom delete pvc chatroom-mysql-data
  kubectl -n chatroom delete pod -l app.kubernetes.io/component=mysql
  ```
- **The image on the node is stale.** Re-load it (§5) and restart the
  pod:
  ```
  kubectl -n chatroom delete pod -l app.kubernetes.io/component=mysql
  ```
- **No default StorageClass.** `kubectl get storageclass` shows none
  marked `(default)`. Either mark one as default or set
  `storageClassName:` in `k8s/20-mysql-pvc.yaml`.

### 9.1.1 `kubectl exec ... -- mysql` fails: `exec: " ": executable file not found in $PATH`

```
kubectl -n chatroom exec -it deploy/mysql -- \
    mysql -u root -p$(awk '/^MYSQL_ROOT_PASSWORD=/{print $2}' app/.env.runtime)
# error: ... exec failed: ... exec: " ": executable file not found in $PATH
# Command 'mysql' not found, but can be installed with:
# sudo apt install mariadb-client-core  # version ...
# sudo apt install mysql-client-core    # version ...
```

The `mysql` CLI is not installed in the running `chatroom-mysql` image.
This happens on `mysql:8.0-debian`-based images: that base image is
configured with **only** Oracle's MySQL apt repo
(`http://repo.mysql.com/apt/debian bookworm mysql-8.0`) — not the full
Debian main repo. So Debian packages like `default-mysql-client`
(and `mysql-client`, which on Debian 12 would resolve to MariaDB's
`mariadb` binary anyway) are not installable at all. The shipped
`mysql/Dockerfile` installs `mysql-community-client` from the MySQL
repo (same upstream as the image's server) — but if you're running
an image built before the fix landed, you have the old one.

**Fix** — rebuild the image and reload it into the cluster:

```
./scripts/build_images.sh --rebuild
kind load docker-image chatroom-mysql:latest          # or k3d / minikube equivalent
kubectl -n chatroom delete pod -l app.kubernetes.io/component=mysql
# pod re-creates with the new image; the schema and the data on the PVC
# are untouched
```

If you don't want to rotate the MySQL password, drop `--rebuild` — the
Dockerfile change alone is enough to install the `mysql` binary.

### 9.1.2 `mysql: Access denied` even after the binary is present

Same `kubectl exec` command, but you get:

```
ERROR 1045 (28000): Access denied for user 'root'@'localhost' (using password: YES)
```

`scripts/_random_password.sh::write_runtime_env_file` URL-encodes the
three secrets before writing `app/.env.runtime` (so they're safe to
embed in a SQLAlchemy URL and in a `kubectl create secret` value
without shell expansion surprises). That means the literal you read
with `awk`/`grep` is the **encoded** form, not the password MySQL was
initialised with. Pass it through `urllib.parse.unquote` first.

**Don't** quote-fix this by stripping `%` or editing `.env.runtime` —
both the encoded form (in the file and in the k8s Secret) and the
real password (in the MySQL image's `99-grants.sql`) have to stay in
sync, and `url_encode_value` is what keeps them aligned.

**One-liner that decodes and execs in one go** (uses the k8s
Service name as the host so you don't need a port-forward):

```
PW=$(python3 -c "from urllib.parse import unquote; \
  print(unquote([l.split('=',1)[1].strip() for l in open('app/.env.runtime') \
                 if l.startswith('MYSQL_PASSWORD=')][0]))")
kubectl -n chatroom exec -it deploy/mysql -- mysql -u root -p"$PW" chatroom_db
```

Or use the same port-forward pattern as §8.2, but URL-decode the
password first:

```
kubectl -n chatroom port-forward svc/mysql 3306:3306 &
PW=$(python3 -c "from urllib.parse import unquote; \
  print(unquote(open('app/.env.runtime').read().split('MYSQL_PASSWORD=',1)[1].split('\n',1)[0]))")
mysql -h 127.0.0.1 -P 3306 -u root -p"$PW" chatroom_db
```

### 9.1.3 `sqlalchemy.exc.OperationalError: (1045, "Access denied for user 'root'@'<ip>' (using password: YES)")` from the app

The app pod has the binary, the URL, and the password — and it's *sending*
a password (`using password: YES` confirms this; the previous "using
password: NO" was a different bug, see §9.1.2). MySQL is rejecting it.

This means the password the **app** has doesn't match the password the
**MySQL** pod was initialised with. Most common cause: the
`chatroom-app` k8s Secret and the `chatroom-mysql` image's
`99-grants.sql` were last rendered from **different**
`k8s/secrets.runtime.yaml` (or from the same rendered file with a
stale cluster Secret — typically because `build_images.sh` was
re-run with `--rebuild` but `scripts/deploy_k8s.sh` was not, or
vice versa).

The encoded form of the password is what both sides need to agree on
(`url_encode_value` in `scripts/_random_password.sh` is what keeps
them in lock-step — see §9.1.2 for why). If they ever disagree, the
image and the Secret need to be regenerated from the same
`app/.env.runtime` value, and the rendered manifest re-applied.

**Step 1 — find the MySQL pod's IP and name.** You need both: the IP
to know which pod is logging the rejection, and the name to `exec`
into it for the password check.

```
kubectl -n chatroom get pods -l app.kubernetes.io/component=mysql -o wide
# NAME                     READY   STATUS    RESTARTS   AGE   IP            NODE       ...
# mysql-xxxxxxxxxx-yyyyy   1/1     Running   0          ...   10.244.0.xx   node-1     ...
```

The `IP` column is the pod's cluster-internal IP. The app's connection
URL is `mysql://root:...@mysql:3306/chatroom_db` (the Service name
`mysql` resolves to the Service's ClusterIP, which DNATs to this pod
IP). The IP in the error message is the **app pod's** IP, not MySQL's
— but the MySQL pod IP is what you need for the next step.

**Step 2 — check what password MySQL actually expects.** Connect to
the MySQL pod directly (bypassing the app) using the same password
the app *thinks* it has, and see whether the server accepts it:

```
# Password the app reads from the chatroom-app Secret (URL-encoded form).
APP_PW=$(kubectl -n chatroom get secret chatroom-app \
  -o jsonpath='{.data.MYSQL_PASSWORD}' | base64 --decode)
echo "App thinks password is: $APP_PW"

# Password baked into the MySQL image's 99-grants.sql at build time.
IMG_PW="$(awk -F= '/^MYSQL_PASSWORD=/{print $2}' app/.env.runtime)"
echo "Image baked password is: $IMG_PW"
```

If `$APP_PW` and `$IMG_PW` print different values, that's the bug —
the app's Secret was last rendered from a different
`app/.env.runtime` than the MySQL image was built from. (Or the
`k8s/secrets.runtime.yaml` was regenerated on the build host and
the cluster Secret is stale.) Both are URL-encoded forms
(both will look like base64-ish strings without URL-specials); the
mismatch will be visible as different strings.

**Step 3 — try logging into MySQL with the app's password.** This
proves whether the app's password is the one MySQL is rejecting:

```
# Decode the app's password (the chatroom-app Secret holds the encoded form).
APP_PW_DECODED=$(printf '%s' "$APP_PW" | python3 -c 'import sys, urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))')

# Try logging in. If THIS works, MySQL accepts the app's password —
# the problem is the wrong app replica pointing at the wrong pod (rare;
# skip to step 4). If this fails too, the password is genuinely wrong.
kubectl -n chatroom exec -it deploy/mysql -- \
    mysql -u root -p"$APP_PW_DECODED" chatroom_db -e "SELECT 1;"
```

**Step 4 — the most common case: regenerate and reconcile.** Re-run
both build and deploy, in that order, so the k8s Secret is rewritten
from the *same* `app/.env.runtime` the image was just baked from:

```
./scripts/build_images.sh
./scripts/deploy_k8s.sh
```

`build_images.sh` is idempotent — it re-uses the existing
`app/.env.runtime` if present, bakes that exact value into
`99-grants.sql`, and renders the matching `chatroom-app` Secret into
`k8s/secrets.runtime.yaml`. `deploy_k8s.sh` then `kubectl apply -f
k8s/` (which picks up the rendered manifest) and rolls the
Deployments. The app pods automatically pick up the new Secret and
reconnect.

**Step 5 — verify the fix.** Re-run the failing query from the app
(or watch the app's logs):

```
# Tail the app logs while you re-trigger the failing action.
kubectl -n chatroom logs -f deploy/chatroom-app --tail=50

# Confirm the app pod can now log in by triggering a simple query
# (the /healthz endpoint is DB-free, so it won't help here — sign in
# via the UI or curl /auth/login instead).
```

**If `$APP_PW` and `$IMG_PW` are identical but MySQL still rejects:**
the password in `app/.env.runtime` is no longer the one either side
was initialised with. This can happen if `app/.env.runtime` was
hand-edited, or if a previous `build_images.sh` was run with
`--rebuild` on a different machine and the file was rsync'd over
without the image being rebuilt. Force a full rotation:

```
./scripts/build_images.sh --rebuild    # generates a new password, bakes it into a new image,
                                          # renders the matching Secret into k8s/secrets.runtime.yaml
./scripts/deploy_k8s.sh                # applies the rendered manifest, rolls both Deployments
kind load docker-image chatroom-mysql:latest   # or k3d / minikube equivalent
kubectl -n chatroom delete pod -l app.kubernetes.io/component=mysql   # pick up the new image
kubectl -n chatroom rollout status deploy/mysql --timeout=2m
```

**Why "update the MySQL pod's password" is the wrong instinct.** You
*can* change MySQL's root password with `ALTER USER ... IDENTIFIED
BY` from inside the running pod — but the chatroom-mysql image is
baked from `99-grants.sql` at first boot, and the k8s Secret isn't
auto-synced to the new value. The next pod restart (e.g. from
`imagePullPolicy` flip, node reboot, or an `evict`) re-runs
`99-grants.sql` and resets the password back to the image-baked
value. Always regenerate-and-reconcile; never hand-edit either side.

### 9.2 `chatroom-app-*` CrashLoopBackOff

```
kubectl -n chatroom logs chatroom-app-<pod>
```

The app exits with a stack trace. The most common cause is a
configuration error: missing or wrong env var. Cross-check:

```
kubectl -n chatroom get deployment chatroom-app -o yaml | grep -A2 envFrom -A20
kubectl -n chatroom get secret chatroom-app -o jsonpath='{.data}' | base64 -d
```

Common values to verify against `app/.env.runtime`:

- `MYSQL_HOST=mysql` (the Service name, not `localhost` or `127.0.0.1`).
- `MYSQL_USER=root` (matches what `mysql/Dockerfile` bakes).
- `MYSQL_PASSWORD` matches the value in `app/.env.runtime` and the
  MySQL image.

If the app is logging `sqlalchemy.exc.OperationalError: (1045, ...)`
specifically, jump to §9.1.3 — that section has the step-by-step
diagnostic for the password-mismatch case, including how to extract
the MySQL pod IP and read the app Secret directly.

### 9.3 WebSocket connections drop after ~60s

The chat frontend uses WebSockets. If the connection drops every minute
or so, the timeout is being applied by a proxy in the path:

- The **Service-to-pod hop** in k8s has no timeout, so this is not it.
- The **Ingress** has `proxy-read-timeout: 3600` and
  `proxy-send-timeout: 3600` in `k8s/50-ingress.yaml`. If you're using
  a different Ingress controller, set the equivalent timeouts.
- The **cloud load balancer** in front of the cluster may have its own
  idle timeout. AWS NLB default is 350s; GCP's is configurable.

### 9.4 `kubectl apply` errors about `chatroom` namespace not existing

The deploy script creates the namespace first. If you ran the manifests
manually (`kubectl apply -f k8s/`), apply `00-namespace.yaml` first.

### 9.5 `ImagePullBackOff` for `chatroom-mysql` / `chat-room-server`

The image isn't on the node. Re-run the appropriate load command from
§5. Confirm the image is on the node with `docker exec ... crictl images`
(kind) or the equivalent for your runtime.

### 9.6 "No active kubectl context"

```
kubectl config use-context <name>
```

The deploy script intentionally refuses to run with no context set, to
avoid clobbering the wrong cluster.

### 9.7 `build_images.sh` says "docker not found in PATH"

Install Docker, or fix your shell's `PATH`. The script does **not**
auto-detect a Docker socket at a non-default location; if you're using
`DOCKER_HOST=tcp://...`, that's fine as long as the `docker` CLI binary
is on `PATH`.

### 9.8 `build_images.sh` fails with "failed to compute cache key for /mysql/init/..." (or `init/...`)

This means the MySQL image's `COPY` lines can't find the SQL files in
the build context. There are two possible causes, depending on which
path shows up in the error:

- **The error mentions `/mysql/init/...`**: the MySQL `Dockerfile` is
  using the old `mysql/init/...` `COPY` paths. Make sure your local
  `mysql/Dockerfile` reads:
  ```
  COPY init/01-schema.sql         /docker-entrypoint-initdb.d/01-schema.sql
  COPY init/99-grants.sql.template /tmp/99-grants.sql.template
  ```
  and that `build_images.sh` passes `$REPO_ROOT/mysql` (not
  `$REPO_ROOT`) as the build context. This is the configuration as
  shipped — if you've edited either file, restore the shipped versions.
- **The error mentions `/init/...` but the files exist**: the build
  context was overridden (e.g. by a custom wrapper script or a
  manual `docker build` call that used a different `-f`/`context`
  pair). The MySQL image requires the build context to be the `mysql/`
  directory itself, not the repo root, because the repo-root
  `.dockerignore` strips out the `mysql/` tree.

If you want to bypass the script and build manually:

```
# NOTE: pass the URL-encoded value as-is. The Dockerfile `sed`s it
# straight into 99-grants.sql, so the literal there must match the
# literal in app/.env.runtime (and in the k8s Secret that
# build_images.sh renders into k8s/secrets.runtime.yaml).
# Don't URL-decode here — see §9.1.2.
docker build \
    --build-arg MYSQL_ROOT_PASSWORD="$(grep ^MYSQL_PASSWORD= app/.env.runtime | cut -d= -f2-)" \
    -f mysql/Dockerfile \
    -t chatroom-mysql:latest \
    mysql/
```

(That last argument — `mysql/` — is the build context, and the part
that's easy to get wrong.)

### 9.9 `ImagePullBackOff` with `pull access denied` (private registry)

You pushed the images to a private Docker Hub / GHCR / ECR repo but
didn't create a `docker-registry` Secret, or the Secret is in the wrong
namespace. See §6.3.4 for the fix.

Verify the Secret exists in the right namespace:

```
kubectl -n chatroom get secret dockerhub-pull
# NAME             TYPE                             DATA   AGE
# dockerhub-pull   kubernetes.io/dockerconfigjson   1      5m
```

And that the Deployment references it:

```
kubectl -n chatroom get deployment chatroom-app -o jsonpath='{.spec.template.spec.imagePullSecrets}'
# [{"name":"dockerhub-pull"}]
```

If the Secret exists but the pull still fails with `unauthorized`, the
stored token has expired — re-run the `kubectl create secret
docker-registry` command with a fresh personal-access token.

---

## 10. Quick reference

| Task | Command |
| --- | --- |
| Build images | `./scripts/build_images.sh` |
| Rebuild with fresh MySQL password | `./scripts/build_images.sh --rebuild` |
| Build without cache | `./scripts/build_images.sh --no-cache` |
| Load into kind | `kind load docker-image chat-room-server:latest chatroom-mysql:latest` |
| Load into k3d | `k3d image import chat-room-server:latest chatroom-mysql:latest -c <cluster>` |
| Load into minikube | `minikube image load chat-room-server:latest && minikube image load chatroom-mysql:latest` |
| Log in to Docker Hub | `docker login` |
| Tag for Docker Hub | `docker tag chat-room-server:latest docker.io/<user>/chatroom-app:v1.0.0` (and likewise for `chatroom-mysql`) |
| Push to Docker Hub | `docker push docker.io/<user>/chatroom-app:v1.0.0` (and likewise) |
| Deploy | `./scripts/deploy_k8s.sh` |
| Check pod status | `kubectl -n chatroom get pods` |
| Tail app logs | `kubectl -n chatroom logs -f -l app.kubernetes.io/component=app` |
| Tail MySQL logs | `kubectl -n chatroom logs -f mysql-0` |
| Port-forward to app | `kubectl -n chatroom port-forward svc/chatroom-app 8000:80` |
| Health check | `curl -s http://localhost:8000/healthz` |
| Roll out a new app image | `kubectl -n chatroom rollout restart deployment/chatroom-app` |
| Uninstall (data-loss) | `./scripts/deploy_k8s.sh --uninstall` |
