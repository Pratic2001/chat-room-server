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
> the 10 values from `app/.env.runtime` — one per line, in the order
> documented in §6.5 — then run `./scripts/deploy_k8s.sh`. See §6.5.

---

## 1. What gets deployed

| Component | Image | Replicas | Storage | Exposed via |
| --- | --- | --- | --- | --- |
| `chatroom-app` (FastAPI + static frontend) | `chat-room-server:latest` | 1 per cluster node (set by `deploy_k8s.sh`) | none | ClusterIP Service `:80` → Ingress |
| `mysql` (database, master + read-replicas) | `chatroom-mysql:latest` | 1 per cluster node: 1 master (`mysql-0`) + N-1 read-replicas (`mysql-1..N-1`), joined via GTID-based async replication on first boot | 5Gi RWO PVC per pod | `mysql` ClusterIP Service `:3306` (master only) + `mysql-replica` ClusterIP Service (read-replicas); cluster-internal |
| `redis` (cache + cross-pod WebSocket fan-out) | `redis:7-alpine` | 1 per cluster node: 1 master (`redis-0`) + N-1 replicas (`redis-1..N-1`), joined via `replicaof` on first boot | 1Gi RWO PVC per pod (AOF) | `chatroom-redis` ClusterIP Service (static alias matching all redis pods); the app talks to it via Sentinel |
| `redis-sentinel` (Sentinel monitors the Redis master) | `redis:7-alpine` | `min(3, NODE_COUNT)` — odd quorum | none | `chatroom-redis-sentinel` headless Service (pod DNS); app discovers the master through it |
| `chatroom` Ingress | — | — | — | routes `chatroom.local/` to the app Service |

The MySQL and Redis Services are `ClusterIP` and have no Ingress route, so
they are not reachable from outside the cluster. The only entry point is
the app, via the Ingress.

### 1.1 Single-node behavior

On a 1-node cluster (`kind`, `k3d`, `minikube`, dev/CI), the topology
collapses back to single-pod behavior automatically:

- **MySQL** — one master pod, no replicas. `MYSQL_READ_HOST` defaults
  to `MYSQL_HOST` in the app, so `app/database.py` uses the same engine
  for reads and writes. The `mysql-replica` Service has zero endpoints,
  which is harmless because nothing points at it.
- **Redis** — one master pod, no replicas, one Sentinel (`quorum=1`).
  Streams still back the cross-pod broadcast (there is only one pod,
  so fan-out is a no-op but the durable backlog survives a restart).
- **Sentinel** — one pod. `sentinel monitor chatroom-redis 1` makes
  quorum = majority-of-1, so failover works (with no redundancy, but
  the single Sentinel still detects failure and promotes).

Every gate in the scripts is conditioned on `NODE_COUNT`, so the
behavior change happens at `NODE_COUNT > 1` without you doing anything
special. To enable replica reads on a multi-node cluster (offload
`SELECT` traffic from the master), see §6.6.

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
- **A node that can run all four images** with the resources requested
  in the StatefulSet and Deployment manifests
  (`k8s/23-mysql-statefulset.yaml`, `k8s/26-redis-statefulset.yaml`,
  `k8s/28-redis-sentinel-statefulset.yaml`,
  `k8s/40-app-deployment.yaml`) — 64Mi–128Mi memory on the Sentinels,
  256Mi memory requested / 1Gi memory limit on MySQL and the app,
  100m–1000m CPU. On multi-node clusters, StatefulSet PVCs
  (`ReadWriteOnce`) bind to one node and ride along when the pod
  reschedules — your cluster must be able to honor RWO volume
  affinity (the default on every StorageClass).
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
this stack (MySQL, Redis, Redis-Sentinels, chatroom-app) on the standard
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
3. Generates a JWT `SECRET_KEY`, a Fernet `ROOM_SECRET_KEY`, and a
   `REPLICATION_PASSWORD` (used by MySQL read-replicas to authenticate
   `CHANGE MASTER TO` against the master) — Python `secrets` and
   `cryptography.fernet` respectively.
4. Writes those values, plus the algorithm and token-expiry settings
   and the read-replica hostname (`MYSQL_READ_HOST=mysql-replica`) and
   the Redis Sentinel list (`REDIS_SENTINELS`), into
   `app/.env.runtime` with `chmod 600`.
5. Prompts for six SMTP settings — `MAIL_HOST`, `MAIL_PORT`, `MAIL_USER`,
   `MAIL_PASSWORD`, `MAIL_FROM`, `MAIL_USE_TLS` — and writes them to
   `app/.env.runtime` next to the secrets. `MAIL_PASSWORD` is read
   silently (so it doesn't echo). Leave `MAIL_HOST` blank to disable
   invite emails entirely. On a re-run, the previous values are used
   as defaults — pass `--rebuild` to start fresh. See §6.5 for the
   full layout and the local debug-sink path.
6. Runs `docker build` for the MySQL image, passing `MYSQL_ROOT_PASSWORD`
   and `REPLICATION_PASSWORD` as build-args. The MySQL Dockerfile
   `sed`s both values into the init SQL files (root's password into
   `99-grants.sql`; the `repl`@'%' user's password into
   `02-replication-user.sql.template`), so on first boot the container
   pins both credentials to those exact values. The
   `replication_bootstrap.sh` entrypoint then uses
   `REPLICATION_PASSWORD` to authenticate `mysqldump` /
   `CHANGE MASTER TO` on every replica pod.
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
7. Scales the three StatefulSets: `statefulset/mysql` and
   `statefulset/redis` to `NODE_COUNT`, and `statefulset/redis-sentinel`
   to `min(3, NODE_COUNT)`. Sentinel needs an odd quorum — capping at
   3 means a 1-node cluster gets one Sentinel with `quorum=1` (works,
   no failover redundancy) and a 2-node cluster gets two Sentinels
   (also `quorum=1`, since 2-of-2 is not a majority over 2 nodes).
   With 3+ nodes the Sentinel count saturates at 3 and the quorum
   defaults to 2-of-3, which tolerates one Sentinel crash.
8. `kubectl rollout status` for the three StatefulSets and the
   Deployment, with a 5-minute timeout each, in this order:
   MySQL → Redis → Sentinels → app. The order matters because the
   app's readiness probe will fail on cold start if it can't reach
   the DB or a Redis master, so the data plane needs to be settled
   before the app readiness wait starts.
9. Prints the Ingress address if one was assigned, or a `port-forward`
   hint if not.

> **MySQL replica bootstrap takes a few minutes per replica.** On a
> cold start, `mysql-1..N-1` run a `mysqldump` of the master followed
> by `CHANGE MASTER TO ... MASTER_AUTO_POSITION=1; START SLAVE;`. The
> mysqldump on an empty schema takes ~10 seconds; on a populated one,
> longer. The 5-minute rollout timeout is generous for a fresh DB
> and tight enough to surface a stuck replica within a single deploy
> cycle. If you see `mysql-1` stuck at `0/1 Ready` past that window,
> see §9.10.

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

A successful run on a 3-node cluster ends with something like:

```
============================================================
  chatroom deployed to namespace "chatroom"
============================================================

Pods:
NAME                          READY   STATUS    RESTARTS   AGE
chatroom-app-7f9c...          1/1     Running   0          30s
chatroom-app-b8a1...          1/1     Running   0          30s
chatroom-app-c2d4...          1/1     Running   0          30s
mysql-0                       1/1     Running   0          45s
mysql-1                       1/1     Running   0          90s
mysql-2                       1/1     Running   0          120s
redis-0                       1/1     Running   0          20s
redis-1                       1/1     Running   0          25s
redis-2                       1/1     Running   0          25s
redis-sentinel-0              1/1     Running   0          20s
redis-sentinel-1              1/1     Running   0          20s
redis-sentinel-2              1/1     Running   0          20s
```

(The three `chatroom-app` pods above are a 3-node cluster; on a
2-node cluster you'd see two app pods, two Redis pods, two Sentinels,
two MySQL pods (1 master + 1 replica); on kind's default 1-node
cluster, you'd see one of each, one Sentinel, and no MySQL replica.
See §1.1.)

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

**`k8s/23-mysql-statefulset.yaml`** — same shape:

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
  k8s/23-mysql-statefulset.yaml
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
`k8s/23-mysql-statefulset.yaml`, at the same indentation level as
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
`k8s/23-mysql-statefulset.yaml` is the only thing that needs to change
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
paste the 10 lines from the build host's `app/.env.runtime`, in this
order:

```
MYSQL_PASSWORD
SECRET_KEY
ROOM_SECRET_KEY
REPLICATION_PASSWORD
MAIL_PASSWORD
MAIL_HOST
MAIL_USER
MAIL_PORT
MAIL_FROM
MAIL_USE_TLS
```

The values are validated as they're read (e.g. `MAIL_PORT` must be
1–65535, `MAIL_USE_TLS` must be `y`/`n`/`true`/`false`, `ROOM_SECRET_KEY`
must look like a Fernet key, `SECRET_KEY` must be at least 32 chars).
Empty `MAIL_HOST` disables invites; empty `MAIL_PASSWORD`/`MAIL_USER`
are fine for relays that don't authenticate. `REPLICATION_PASSWORD` is
the credential the replica pods use for `mysqldump` / `CHANGE MASTER TO`
against the master — it's baked into the MySQL image at build time,
so the value you paste must match what the image was built with, or
every replica will fail to start (see §9.10). The script also writes
`k8s/secrets.runtime.yaml` (gitignored) so a bare
`kubectl apply -f k8s/` from a fresh checkout is enough to push the
values to the cluster.

**Rotating `MAIL_PASSWORD` only.** Edit `app/.env.runtime` in place,
then re-run `./scripts/deploy_k8s.sh` (it reads the file and rewrites
the Secret imperatively) and
`kubectl -n chatroom rollout restart deployment/chatroom-app`. No rebuild
needed — the app reads env at start. There's no separate
`change_mail_password.sh`; if you'd rather script the rotation,
`scripts/write_runtime_env.sh --from-file <file>` is the canonical
write path.

### 6.6 Enabling MySQL read-replicas (multi-node clusters)

The MySQL StatefulSet runs 1 master (`mysql-0`) + N-1 read-replicas
(`mysql-1..N-1`), and the read-only endpoints (`GET /messages/{room_id}/messages`,
`GET /rooms/my`) can route to the replicas instead of the master. This
offloads `SELECT` traffic from the master and gives you horizontal
read scaling. **It's only worth doing on a multi-node cluster** — on a
1-node cluster there are no replicas, so the `mysql-replica` Service
has zero endpoints and the app falls back to the master anyway.

**Default behavior.** On a fresh build, `app/.env.runtime` has
`MYSQL_READ_HOST=` (empty), and `app/database.py` falls back to
`MYSQL_HOST=mysql` for reads. That works — it's just a single endpoint.
To enable replica reads, set `MYSQL_READ_HOST=mysql-replica` (the name
of the ClusterIP Service in `k8s/24-mysql-replica-service.yaml`, which
selects on the `role=replica` label).

#### 6.6.1 Set it on a fresh cluster

```
# Either export it in your shell before running build_images.sh:
export MYSQL_READ_HOST=mysql-replica
./scripts/build_images.sh    # picks it up, persists it into app/.env.runtime

# ...or edit app/.env.runtime after the first build, before deploy:
echo 'MYSQL_READ_HOST=mysql-replica' >> app/.env.runtime
./scripts/deploy_k8s.sh      # re-renders k8s/secrets.runtime.yaml
```

Both paths land the value in `chatroom-app`'s ConfigMap as
`MYSQL_READ_HOST`, which `app/database.py` reads at startup. The
`get_read_db()` dependency then issues `SELECT` queries against
`mysql-replica`, which load-balances across every `1/1 Ready` replica.

#### 6.6.2 Set it on an existing cluster (no rebuild)

You don't need to rebuild the image just to flip this — the value is
in the ConfigMap, not baked into the image. Edit `app/.env.runtime`
to add or change the line, re-run `build_images.sh` (which is
idempotent and re-renders the ConfigMap), then deploy:

```
# 1. Edit in place
echo 'MYSQL_READ_HOST=mysql-replica' >> app/.env.runtime

# 2. Re-render the rendered manifest (no rebuild, no image changes)
./scripts/build_images.sh    # idempotent: reuses existing passwords
#   ↑ this rewrites k8s/secrets.runtime.yaml with the new MYSQL_READ_HOST

# 3. Apply and roll the app pods so they pick up the new ConfigMap
./scripts/deploy_k8s.sh
```

`deploy_k8s.sh` always calls `kubectl rollout restart deployment/chatroom-app`
after applying manifests, so the change is picked up within a few seconds.

#### 6.6.3 Verify replica reads are landing on the replicas

The simplest end-to-end check: watch MySQL's processlist on the master
and replicas while you hit the read endpoints.

```
# On the master: count SELECTs originating from the app's connections
kubectl -n chatroom exec mysql-0 -- mysql -uroot \
  -p"$(python3 -c 'import urllib.parse; print(urllib.parse.unquote(open("app/.env.runtime").read().split("MYSQL_PASSWORD=",1)[1].split(chr(10),1)[0]))')" \
  -e "SHOW PROCESSLIST" | grep -c SELECT
# (this is non-zero because the master itself runs occasional SELECTs
# for change-master checks; the important comparison is across time)

# On a replica: the same query should now also be non-zero
kubectl -n chatroom exec mysql-1 -- mysql -uroot \
  -p"$(python3 -c 'import urllib.parse; print(urllib.parse.unquote(open("app/.env.runtime").read().split("MYSQL_PASSWORD=",1)[1].split(chr(10),1)[0]))')" \
  -e "SHOW PROCESSLIST" | grep -c SELECT
```

Then in another terminal, hit the read endpoint:

```
curl -s http://localhost:8000/messages/1/messages -H "Authorization: Bearer $TOKEN"
# ↑ if MYSQL_READ_HOST is wired correctly, the SELECT appears in
#   mysql-1..N-1's processlist, not in mysql-0's
```

You should also see the replica's `Questions` counter rise
(`SHOW GLOBAL STATUS LIKE 'Questions';`), which it does not when reads
are routed to the master.

#### 6.6.4 What does NOT need to change

- **`MYSQL_HOST`** stays `mysql` (the master-only Service in
  `k8s/22-mysql-service.yaml`). Writes, schema migrations, and the
  replication handshake all flow through the master Service and
  must not be re-pointed at the replicas.
- **The `REPLICATION_PASSWORD` Secret** stays unchanged — that's the
  credential the replicas use to authenticate `CHANGE MASTER TO`
  against the master, baked into the MySQL image at build time.
- **The app's connection pool** doesn't need tuning. Each app pod
  has two engines (write + read); the read engine's pool fills on
  first use and stays warm. With 3 replicas and 3 app pods, expect
  ~9 active connections per replica (the SQLAlchemy default pool size
  is 5 plus an overflow buffer).

#### 6.6.5 Caveats

- **Read-after-write lag.** A `POST /messages` writes to the master;
  the replica picks it up via replication within a few hundred ms.
  An immediate `GET /messages/{room_id}/messages` from the same user
  may not see the new message yet. The chat UI already dedupes WS
  broadcasts against HTTP responses by message id (see CLAUDE.md), so
  users don't see their own messages "lost", but two browsers on
  different pods may briefly disagree about the latest message in a
  fast-moving conversation. If you need strict read-after-write,
  set `MYSQL_READ_HOST=mysql` (the master) — or wait for replication
  to catch up before serving reads.
- **Empty `mysql-replica` Service on 1-node clusters.** If you set
  `MYSQL_READ_HOST=mysql-replica` on a 1-node cluster (where there
  are no replicas), the read engine fails to connect and the app
  crashes on startup. Always check that `kubectl -n chatroom get
  endpoints mysql-replica` returns at least one IP before setting
  this. See §9.13.

---

## 7. Verify the deployment

### 7.1 Pods are healthy

```
kubectl -n chatroom get pods
# both app pods:                Running, 1/1 Ready
# mysql-0 (master):             Running, 1/1 Ready
# mysql-1..N-1 (replicas):      Running, 1/1 Ready   (multi-node only)
# redis-0 (master):             Running, 1/1 Ready
# redis-1..N-1 (replicas):      Running, 1/1 Ready   (multi-node only)
# redis-sentinel-0..2:          Running, 1/1 Ready   (1 pod on 1-node)
```

The MySQL master pod takes longer to become Ready than the app pods
because it runs the schema migrations on first boot. The replica pods
take longer still because each one runs a `mysqldump` of the master
followed by `CHANGE MASTER TO ... START SLAVE`. If any pod stays at
`0/1` for more than 5 minutes, see §9.1 (master) or §9.10 (replica).

### 7.1.1 Replication is healthy

On a multi-node cluster, also check that the data tier is actually
replicating, not just running:

```
# MySQL: every replica's Seconds_Behind_Master should be 0
kubectl -n chatroom exec mysql-1 -- mysql -uroot \
  -p"$(python3 -c 'import urllib.parse; print(urllib.parse.unquote(open(\"app/.env.runtime\").read().split(\"MYSQL_PASSWORD=\",1)[1].split(\"\\n\",1)[0]))')" \
  -e "SHOW SLAVE STATUS\G" | grep -E 'Slave_IO_Running|Slave_SQL_Running|Seconds_Behind'

# Redis: every replica should show role:slave and master_link_status:up
kubectl -n chatroom exec redis-1 -- redis-cli INFO replication | \
    grep -E 'role|master_link_status|master_last_io_seconds_ago'

# Sentinels: master recognized by every Sentinel
for s in 0 1 2; do
  kubectl -n chatroom exec redis-sentinel-$s -- \
    redis-cli -p 26379 sentinel master chatroom-redis
done
# look for "ip" matching redis-0's pod IP, "port" 6379, "flags" containing "master"
```

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
./scripts/build_images.sh --rebuild    # new MYSQL_PASSWORD (and a new
                                      # REPLICATION_PASSWORD), baked
                                      # into the MySQL image and rendered
                                      # into k8s/secrets.runtime.yaml
docker save chatroom-mysql:latest | <load into cluster>   # see §5
./scripts/deploy_k8s.sh               # applies the rendered Secret, rolls
                                      # the StatefulSets + Deployment
kubectl -n chatroom delete pod -l app.kubernetes.io/component=mysql   # restart with new image
# the pod re-runs the schema on the existing PVC; if the password in
# 99-grants.sql no longer matches the one used at first boot, MySQL
# may refuse to start. In that case, drop the PVC and re-create it.
```

`--rebuild` also rotates `REPLICATION_PASSWORD` (the credential the
read-replica pods use to authenticate `CHANGE MASTER TO`). On a
multi-node cluster, this means after the rebuild every replica has to
re-clone from the master — expect the replica rollout to take the
full 5 minutes per replica on a populated DB.

The "drop the PVC" path is destructive — it loses all chat history
and resets the cluster back to a single master with no replication.
To keep the data, do a `mysqldump` first, drop the PVC, let MySQL
re-initialise, then restore. See §8.2 for the dump.

**Rotating `REPLICATION_PASSWORD` only** (no root-password change) is
not a one-flag operation today. Because the password is baked into
the MySQL image at build time, you need a full rebuild + redeploy;
otherwise the running replicas keep using the old credential and
new replicas will fail `CHANGE MASTER TO` with an access-denied
error. Track this as a manual admin task, not a routine operation.

### 8.2 Backing up the database

From a build host that has the `mysql` client and can reach the cluster:

```
# Start a port-forward to the MySQL master Service (port-forwards
# always land on mysql-0 — the Service selector narrows to that pod
# specifically, so reads-then-writes to the same port-forward are
# guaranteed to hit the master, never a replica).
kubectl -n chatroom port-forward svc/mysql 3306:3306 &
# Read the password (URL-decoded — see §9.1.2 for why)
MYSQL_PASSWORD="$(python3 -c "from urllib.parse import unquote; \
  print(unquote(open('app/.env.runtime').read().split('MYSQL_PASSWORD=',1)[1].split('\n',1)[0]))")"
# Dump
mysqldump -h 127.0.0.1 -P 3306 -u root -p"$MYSQL_PASSWORD" \
    --single-transaction --routines --triggers \
    --set-gtid-purged=COMMENTED \
    chatroom_db > chatroom-$(date +%Y%m%d).sql
```

`--set-gtid-purged=COMMENTED` matches what
`mysql/replication_bootstrap.sh` uses during replica clone — it
preserves the GTID coordinates in the dump's metadata without writing
a `SET @@GLOBAL.GTID_PURGED=...` statement that would conflict with
the master's GTID set on restore. The dumped file is safe to load
into a fresh master or a replica.

To restore, point a `mysql` client at the same port-forward and pipe
the dump in. To restore into a specific replica for verification
(use the `mysql-replica` Service), point at
`svc/mysql-replica:3306` instead.

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
cleanly. The password is URL-decoded — see §9.1.2. Always run schema
migrations against `mysql-0` (the master) — every replica picks up the
change via replication, so a single command reaches the whole cluster.
Running DDL on a replica is a no-op for the master's binlog and will
silently drift the replica from the master.)

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

> **StatefulSet nuance:** MySQL, Redis, and Redis-Sentinels are
> StatefulSets, not Deployments. `rollout restart statefulset/...`
> works the same way (rolling update by ordinal, with the StatefulSet's
> `updateStrategy.rollingUpdate.partition: 0` for full replacement),
> but the order matters more: each pod restarts serially, and the
> replica pods re-clone from the master on cold start (see §9.10), so a
> `rollout restart` on a populated DB takes several minutes.
> `kubectl delete pod <name>` is the cheaper form for a single pod —
> the StatefulSet controller re-creates it on the same node with the
> same PVC, and the replica's `CHANGE MASTER TO` reconnects in seconds.

#### 8.6.1 Pick a new image (you rebuilt `build_images.sh`)

After `./scripts/build_images.sh`, the cluster's local Docker daemon has
the new image, but the running pods are still running the old one
(`imagePullPolicy: Never` means k8s never re-checks). Force a rollout so
the new image is picked up:

```
kubectl -n chatroom rollout restart statefulset/mysql
kubectl -n chatroom rollout restart statefulset/redis
kubectl -n chatroom rollout restart statefulset/redis-sentinel
kubectl -n chatroom rollout restart deployment/chatroom-app
kubectl -n chatroom rollout status statefulset/mysql --timeout=10m
kubectl -n chatroom rollout status statefulset/redis --timeout=3m
kubectl -n chatroom rollout status statefulset/redis-sentinel --timeout=3m
kubectl -n chatroom rollout status deployment/chatroom-app --timeout=3m
```

`rollout restart` issues a rolling update — the app Deployment has
replicas set to one per cluster node (configured by `deploy_k8s.sh`,
see §6.2) + `maxUnavailable: 0` + `maxSurge: 1`, so traffic stays served
throughout (old pod only stops accepting connections once the new pod
is `Ready`). The MySQL and Redis StatefulSets update one pod at a time
in ordinal order (master first, then replicas), so the master is
already on the new image before any replica re-clones. The timeout
on the MySQL rollout is bumped to 10m because every replica re-runs
`mysqldump` against the new master; on a populated DB this is the slow
step.

For a single-pod restart (cheaper):

```
kubectl -n chatroom delete pod mysql-0    # StatefulSet recreates it on the same node
kubectl -n chatroom delete pod redis-0
```

Either form is fine. Use whichever you can type faster.

#### 8.6.2 Pick up a changed ConfigMap or Secret

ConfigMaps and Secrets are mounted into the pod at start; changing the
resource does **not** restart the pod automatically. The app pod
mounts the chatroom-app Secret as env vars (`envFrom: secretRef`), so
env changes also need a restart to take effect. The MySQL pod reads
`MYSQL_ROOT_PASSWORD` and `REPLICATION_PASSWORD` from the Secret at
start, so a Secret rotation also needs a restart. Same commands as 8.6.1:

```
kubectl -n chatroom rollout restart statefulset/mysql
kubectl -n chatroom rollout restart deployment/chatroom-app
kubectl -n chatroom rollout status statefulset/mysql --timeout=10m
kubectl -n chatroom rollout status deployment/chatroom-app --timeout=3m
```

For Secrets only (no code change), you can also use
`scripts/deploy_k8s.sh` — it re-applies `k8s/secrets.runtime.yaml`
and rolls the StatefulSet + Deployment so the new values are read.

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
# ReplicaSet creates a new one. All replicas are replaced, but with
# maxUnavailable=0 the Service keeps serving throughout.
```

For a single StatefulSet pod (cheaper than a full rollout):

```
kubectl -n chatroom delete pod mysql-0
# StatefulSet recreates it on the same node with the same PVC
# attached. The pod's datadir is preserved.
```

#### 8.6.4 Quick "bounce everything"

```
kubectl -n chatroom rollout restart statefulset/mysql
kubectl -n chatroom rollout restart statefulset/redis
kubectl -n chatroom rollout restart statefulset/redis-sentinel
kubectl -n chatroom rollout restart deployment/chatroom-app
```

Use this when you've changed cluster-wide infra (e.g. updated the
Ingress controller, rotated the MySQL root password via 8.1 and want
the pods to come up cleanly with the new Secret). Order matters:
restart MySQL first, then Redis and Sentinels (Sentinels reconnect
to the new master automatically), then the app — the app pods can
only reconnect to MySQL and Redis once both are up.

#### 8.6.5 What's safe to skip

- `kubectl delete deploy/...` is **not** a restart — it tears down
  the Deployment and (without `--cascade=orphan`) the ReplicaSet and
  Pods, leaving the cluster without the app until you re-apply the
  manifests. Use only for §8.5 teardown.
- `kubectl delete statefulset/...` is even worse — it tears down
  every pod **and** its PVC, which loses the database contents.
  Always restart via `rollout restart` or `kubectl delete pod <name>`.
- `kubectl drain` / `kubectl cordon` are for node maintenance, not
  pod restart. They evict pods to a different node, which is the
  wrong tool here (a drained StatefulSet pod's PVC has to be
  re-attached to the new node, which works but is slow).

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
  kubectl -n chatroom delete pvc chatroom-mysql-data-mysql-0
  kubectl -n chatroom delete pod mysql-0
  ```
  Note the PVC name has the StatefulSet pod suffix (`-mysql-0`); the
  old `chatroom-mysql-data` name from the singleton Deployment is
  no longer used.
- **The image on the node is stale.** Re-load it (§5) and restart the
  pod:
  ```
  kubectl -n chatroom delete pod mysql-0
  ```
- **No default StorageClass.** `kubectl get storageclass` shows none
  marked `(default)`. Either mark one as default or set
  `storageClassName:` in `k8s/23-mysql-statefulset.yaml`.

### 9.1.1 `kubectl exec ... -- mysql` fails: `exec: " ": executable file not found in $PATH`

```
kubectl -n chatroom exec -it mysql-0 -- \
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
kubectl -n chatroom exec -it mysql-0 -- mysql -u root -p"$PW" chatroom_db
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
kubectl -n chatroom exec -it mysql-0 -- \
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
./scripts/deploy_k8s.sh                # applies the rendered manifest, rolls both StatefulSets
kind load docker-image chatroom-mysql:latest   # or k3d / minikube equivalent
kubectl -n chatroom delete pod mysql-0   # pick up the new image
kubectl -n chatroom rollout status statefulset/mysql --timeout=10m
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

### 9.10 MySQL replica pods stuck at `0/1 Ready`

Symptoms: on a multi-node cluster, `mysql-0` (the master) is `1/1 Ready`
but `mysql-1..N-1` (the replicas) sit at `0/1` past the 5-minute
rollout timeout. Logs:

```
kubectl -n chatroom logs mysql-1
```

Common causes:

- **`ERROR 1045 (28000): Access denied for user 'repl'@'...'` during
  `mysqldump`.** The replica's `REPLICATION_PASSWORD` (in the
  `chatroom-mysql` Secret) does not match the `repl`@'%' user's
  password baked into the master's `02-replication-user.sql`. The
  most common cause: a previous `build_images.sh --rebuild` on a
  different machine, or the rendered `k8s/secrets.runtime.yaml` is
  stale relative to the running MySQL image. Fix by re-running
  build + deploy together so both come from the same
  `app/.env.runtime`:

  ```
  ./scripts/build_images.sh
  ./scripts/deploy_k8s.sh
  kind load docker-image chatroom-mysql:latest   # or k3d / minikube equivalent
  kubectl -n chatroom rollout restart statefulset/mysql --timeout=10m
  ```

  Compare the values the same way you would for §9.1.3 — extract
  `REPLICATION_PASSWORD` from the cluster Secret and from
  `app/.env.runtime`, both should be identical URL-encoded forms.

- **Replica bootstrap hangs on `mysqldump` past 5 minutes.** On a
  populated master the dump can take longer than the rollout timeout.
  Check whether the dump is making progress:

  ```
  kubectl -n chatroom logs -f mysql-1 | grep -E 'mysqldump|CHANGE MASTER|START SLAVE'
  ```

  If the dump is still running, wait it out; if it's stuck on a
  particular table, the master may be under load — try again when
  the cluster is idle.

- **`Slave_IO_Running: Connecting` after a clean start.** Replicas
  log this transiently when the master is still initializing. It
  should resolve within a few seconds. If it persists, the
  `MASTER_HOST` (the master's headless-service DNS name) may not be
  resolvable from inside the pod — `kubectl -n chatroom exec mysql-1
  -- nslookup mysql-0.mysql-headless` should return the master's
  pod IP.

- **`Seconds_Behind_Master: NULL`.** This is normal during the first
  few seconds of a fresh replica (no events to apply yet). It should
  resolve to `0` once the dump is loaded and replication catches up.
  If it stays `NULL` for more than a minute, the replica's I/O thread
  is not making progress — check `Last_IO_Error` in `SHOW SLAVE
  STATUS\G` for the underlying error.

- **`ERROR 1045 (28000): Access denied for user 'root'@'localhost'
  (using password: NO)` from the dump-load's local `mysql` client.**
  This is the dump-load itself failing: the local `mysql --user=root
  --socket=…` (no password) call inside the `mysqldump | mysql …`
  pipeline gets rejected. On MySQL 8, `mysqld --initialize-insecure`
  creates `root@localhost` with `caching_sha2_password` and an empty
  hash, and the empty-password fast path over a unix socket is not
  reliable on every release — sometimes the server returns 1045 with
  `(using password: NO)`. The replica bootstrap script handles this
  with a `--init-file` that registers the `auth_socket` plugin and
  pins `root@localhost` to `auth_socket` **before** the background
  mysqld accepts any client connections, so the dump-load's no-
  password connection matches the OS root user inside the container
  and is accepted without a password roundtrip. If you're seeing this
  error, the running `chatroom-mysql` image predates the `--init-file`
  fix — rebuild and roll the StatefulSet (see Recovery §9.10.1 below).

- **`ERROR 1045 (28000): Access denied for user 'root'@'localhost'
  (using password: YES)` from the local `mysql` client** right after
  the dump-load completes. The dump's `mysql --user=root --socket=…`
  (no password) connection succeeded — `root@localhost` is already
  pinned to `auth_socket` by the `--init-file` described in the bullet
  above. The dump itself overwrites `root@localhost` with the master's
  row, which uses `caching_sha2_password` (MySQL 8 default) and stores
  a hash of `MYSQL_ROOT_PASSWORD`. The replica bootstrap then tries to
  `CHANGE MASTER TO + START SLAVE` over that same socket using
  `--password="$MYSQL_ROOT_PASSWORD"` — and on a unix-socket
  connection, `caching_sha2_password` has a known sharp edge where
  the server doesn't accept the cleartext password under all startup
  states, so the client gets a 1045. The replica bootstrap script
  handles this by re-pinning `root@localhost` to `auth_socket`
  immediately after the dump, so every subsequent local `mysql` call
  is password-less and routed via the OS-user match. If you see this
  error on an older build, rebuild the MySQL image so the new
  bootstrap script ships.

### 9.10.1 Recovery: stuck `mysql-1` after a bootstrap failure

The bootstrap script exits 1 on any of the failure modes above, and
the pod's restartPolicy is `Always`, so the replica enters
`CrashLoopBackOff`. The PVC has a partially-initialized datadir from
the failed attempt — either the temp mysqld got far enough to write
files, or it didn't. The script's idempotent-restart path at
`mysql/replication_bootstrap.sh:161-162` then skips
`--initialize-insecure` on the next attempt (it sees an existing
`${DATADIR}/mysql` directory), so a re-run on a stale PVC hits the
same bug regardless of which image is running.

**Default to dropping both pod and PVC** so the StatefulSet recreates
with a fresh datadir. The replica has no useful state to preserve —
replication is fresh-cloned from the master on every cold start, so
there's nothing to lose on the replica side.

1. Build the patched image:

   ```
   ./scripts/build_images.sh
   ```

2. Load it into the cluster's container runtime (the deploy script
   doesn't do this — `imagePullPolicy: Never` means the image has to
   be present locally on every node, but kind/k3d/minikube all share
   a Docker daemon with the host so a single load is enough):

   ```
   kind load docker-image chatroom-mysql:latest    # kind
   k3d image import chatroom-mysql:latest --cluster <name>   # k3d
   minikube image load chatroom-mysql:latest       # minikube
   ```

3. Apply the new manifest and reconcile the cluster (this is
   idempotent — safe to run on a healthy cluster too):

   ```
   ./scripts/deploy_k8s.sh
   ```

4. **Drop the stuck pod and its PVC** so the StatefulSet recreates
   with a fresh datadir:

   ```
   kubectl -n chatroom delete pod mysql-1
   kubectl -n chatroom delete pvc data-mysql-1
   ```

   The StatefulSet recreates the pod within seconds; the PVC is
   re-bound to a freshly-provisioned volume (the cluster's default
   StorageClass handles this). The new pod's bootstrap runs from a
   blank datadir — `--initialize-insecure` runs, the `--init-file`
   pins `root@localhost` to `auth_socket`, the dump-load succeeds.

5. Watch the bootstrap log for the success markers. The whole flow
   takes 30-90s on a populated master:

   ```
   kubectl -n chatroom logs -f mysql-1 | grep -E 'init-file|MASTER_AUTO|Seconds_Behind|Dump-load|Replication started'
   ```

   You should see, in order:
   - `Writing /tmp/replica-bootstrap-init.sql...`
   - `Local mysqld ready on attempt N`
   - `Dump-load complete`
   - `Replication started successfully`
   - `Slave_IO_Running: Yes` + `Slave_SQL_Running: Yes` (from the
     `SHOW SLAVE STATUS` verification)

6. Confirm replication is keeping up:

   ```
   kubectl -n chatroom exec mysql-1 -- \
       mysql -uroot -e 'SHOW SLAVE STATUS\G' | grep Seconds_Behind
   # Seconds_Behind_Master: 0
   ```

   And that the row count on a sample table matches the master
   (replication lag is sub-second in steady state, so a few-second
   gap between the two `COUNT(*)` calls is plenty):

   ```
   kubectl -n chatroom exec mysql-0 -- mysql -uroot chatroom_db \
       -e 'SELECT COUNT(*) AS messages FROM messages'
   kubectl -n chatroom exec mysql-1 -- mysql -uroot chatroom_db \
       -e 'SELECT COUNT(*) AS messages FROM messages'
   ```

This recovery flow also applies to any future replica bootstrap
failure — keeping a stale PVC after an image rollback can leave the
replica in a state where the idempotent restart path skips
`--initialize-insecure` and re-hits the original bug. Default to
dropping both pod and PVC.

### 9.11 `redis-1` (or another replica) shows `role:master` instead of `role:slave`

Symptom: more than one Redis pod thinks it's the master. The wrapper
entrypoint in `k8s/26-redis-statefulset.yaml` decides master vs.
replica from the pod's hostname (`redis-0` → master, anything else
→ `replicaof redis-0.redis-headless 6379`). If the pod's name does
not match the StatefulSet's ordinal, the script falls through to
the master path.

Check:

```
kubectl -n chatroom get pods -l app.kubernetes.io/component=redis -o name
# should be pod/redis-0, pod/redis-1, ..., pod/redis-N
```

If the names are not in the `redis-N` shape, the StatefulSet's
`serviceName: redis-headless` is not matching — verify
`k8s/27-redis-headless-service.yaml` is applied and that the
StatefulSet's `spec.serviceName` still references it.

### 9.12 `chatroom-app` can't reach Redis through Sentinel

Symptom: app pod logs show `redis.exceptions.ConnectionError` or
`MasterNotFoundError` from `app/redis_bus.py` and falls back to
single-pod mode (cross-pod WS broadcasts are lost, but local
broadcasts still work).

```
kubectl -n chatroom logs -f chatroom-app-xxx | grep -E 'Sentinel|chatroom-redis'
```

Common causes:

- **`No sentinels available` from the app.** The app's
  `REDIS_SENTINELS` env (in the chatroom-app ConfigMap) is empty or
  points at the wrong hostnames. Verify:

  ```
  kubectl -n chatroom get configmap chatroom-app -o yaml | grep REDIS_SENTINELS
  # should list all three redis-sentinel pods at port 26379,
  # comma-separated, e.g. "redis-sentinel-0.chatroom-redis-sentinel:26379,..."
  ```

  If empty, re-run `./scripts/build_images.sh` to re-render the
  ConfigMap — the value is generated from the StatefulSet's pod DNS
  names.

- **All Sentinels log `+sdown master chatroom-redis`.** Sentinel
  itself is up but cannot see the master. Sentinel monitors
  `redis-0.redis-headless` (a pod DNS name from the
  `redis-headless` Service) — verify `redis-0` is `1/1 Ready` and
  that the headless Service resolves from inside the cluster:

  ```
  kubectl -n chatroom get pods -l app.kubernetes.io/component=redis
  # redis-0 must be 1/1 Ready
  kubectl -n chatroom exec redis-sentinel-0 -- \
      nslookup redis-0.redis-headless
  # must return redis-0's pod IP
  ```

  If `redis-0` itself is stuck at `0/1`, check its logs:

  ```
  kubectl -n chatroom logs redis-0 --previous
  ```

  The most common causes match the mysql replica pattern (§9.10):
  PVC stuck in `Pending`, the `redis:7-alpine` image missing on the
  node (`ImagePullBackOff`), or the wrapper entrypoint failing
  (rare — the script is straightforward). The wrapper entrypoint
  branches on `${POD_NAME}` from the downward API, so a pod whose
  name does not match `redis-0`/`redis-1`/... will fall through to
  the master path (see §9.11).

- **`chatroom-redis` Service has no endpoints.** That Service is a
  static alias matching every redis pod (the `role=master` selector
  was removed because nothing in the stack maintained it). If the
  Service has no endpoints, no redis pods are `1/1 Ready` — fix
  that first, the Service comes back automatically.

- **Failover happened and the app didn't reconnect.** Sentinel
  promotes a new master and updates its config; the
  `redis.asyncio.sentinel.Sentinel` client in the app should pick
  up the new master on its next call. If it doesn't, restart the
  app pods:

  ```
  kubectl -n chatroom rollout restart deployment/chatroom-app
  ```

### 9.12.1 `redis-0` stuck at `Init:0/1` (init container never exits)

Symptom: `kubectl -n chatroom get pods` shows `redis-0` in `Pending`
or `Init:0/1` indefinitely, while `redis-sentinel-0..2` and the rest
of the stack are healthy. The wrapper entrypoint never gets a chance
to run.

Common causes:

- **A leftover init container on an older StatefulSet revision.**
  Earlier revisions of `k8s/26-redis-statefulset.yaml` defined an
  `initContainer` named `role-labeler` that ran `while true; do ...
  done` (and never PATCHed any labels). If the StatefulSet is on a
  controller-revision that still has it, the main `redis` container
  never starts. Verify by checking the pod's `initContainers`:

  ```
  kubectl -n chatroom get pod redis-0 -o jsonpath='{.spec.initContainers}' | jq .
  # should print: []   (empty list)
  ```

  If `role-labeler` is listed, the StatefulSet is on an older
  revision. Force the new pod spec by deleting the pod:

  ```
  kubectl -n chatroom delete pod redis-0 --force --grace-period=0
  # StatefulSet recreates it with the current (no-init-container) spec
  ```

- **The image isn't on the node.** `redis:7-alpine` is a stock
  upstream image; if it isn't already present, kubelet pulls it on
  first run. Verify:

  ```
  kubectl -n chatroom describe pod redis-0 | grep -E 'Image|Pull'
  # ImagePullBackOff / ErrImagePull means the node can't reach the
  # registry. On local clusters (kind/k3d/minikube) check the
  # cluster's registry config.
  ```

- **PVC stuck in `Pending`.** Same pattern as a stuck MySQL replica
  — see §9.10. The StatefulSet pod won't reach `Init` until its PVC
  is bound.

After the init-container fix lands, also `kubectl rollout restart
statefulset/redis-sentinel -n chatroom` so the Sentinel pods pick up
the new `sentinel monitor` target (`redis-0.redis-headless` instead
of `chatroom-redis`). Existing Sentinel processes have the old monitor
target cached in their config and will keep logging `+sdown master`
until they restart.

### 9.13 `mysql-replica` Service has no endpoints

Symptom: `kubectl -n chatroom get endpoints mysql-replica` returns
`<none>`. This is **expected on 1-node clusters** — there are no
replicas, so the Service has no backing pods. The app detects this
via `MYSQL_READ_HOST` defaulting to `MYSQL_HOST` when the values
are equal, and uses the same engine for reads and writes. No
action needed.

On a multi-node cluster, the Service has endpoints only when the
replica pods are `1/1 Ready`. If a replica is stuck at `0/1`, see
§9.10.

### 9.14 MySQL replica SQL thread aborted (`Error_code: MY-001396`)

Symptom: the replica pod (`mysql-1` etc.) is `1/1 Running`, but its
log shows the applier thread has stopped:

```
2026-06-25T20:53:18.669317Z 10 [ERROR] [MY-010584] [Repl] Replica SQL for channel '':
  Worker 1 failed executing transaction
  'b11692f4-70d7-11f1-8f40-ceedec70d9b7:20' at source log mysql-bin.000002,
  end_log_pos 2961994; Error 'Operation ALTER USER failed for 'root'@'%'' on query.
  Default database: 'chatroom_db'. Query: 'ALTER USER 'root'@'%' IDENTIFIED WITH
  'caching_sha2_password' AS '$A$005$...'', Error_code: MY-001396
2026-06-25T20:53:18.669414Z 6 [ERROR] [MY-010586] [Repl] Error running query,
  replica SQL thread aborted. Fix the problem, and restart the replica SQL
  thread with "START REPLICA". We stopped at log 'mysql-bin.000002' position 2958981
```

`Seconds_Behind_Master` on the replica climbs without bound and stays
non-zero even though the IO thread is still pulling events. The root
cause is almost always a single binlog event the replica can't replay
against its current state — most often an `ALTER USER` line that was
replayed from the master (the `99-grants.sql` template the master ran
on first boot also lives in the binlog and gets re-applied to
replicas). Other common triggers: a duplicate-key `CREATE USER`, a
`GRANT` for a user that doesn't exist, a `DROP` of a row that already
moved on, etc.

**This is different from §9.10 / §9.10.1** — those cover the replica
*pod* being stuck (`0/1 Ready`, CrashLoopBackOff) because the
bootstrap dump-load itself failed. Here the pod is fine; only the
applier thread is stuck. No PVC drop is needed.

#### 9.14.1 Diagnose

Pick the offending replica and read its status:

```
./scripts/fix_mysql_repl.sh --pod mysql-1 status
```

The relevant fields:

- `Replica_SQL_Running: No` (or `Slave_SQL_Running: No` on MySQL
  < 8.0.22) — the applier is stopped.
- `Last_SQL_Error` — the human-readable form of the failure
  (`Operation ALTER USER failed for 'root'@'%'`).
- `Exec_Master_Log_Pos` (or `Exec_Source_Log_Pos`) — where the
  replica stopped. The error message above shows
  `We stopped at log 'mysql-bin.000002' position 2958981`, which
  matches.
- `Relay_Master_Log_File` / `Relay_Source_Log_File` — the relay log
  the stopped transaction lives in.

The GTID of the failing transaction is the `:20` part of the error
message (`b11692f4-70d7-11f1-8f40-ceedec70d9b7:20` in the example).
You'll need it for the GTID-aware skip below.

#### 9.14.2 Fix it

Three options, in order of escalation. The bundled script wraps each
one with version detection (REPLICA keyword on 8.0.22+, SLAVE on
older), pre-flight checks (refuses to run on `mysql-0`, refuses to
operate on a not-Ready pod), and `--dry-run` so you can see the SQL
before it executes.

**Option A — single-event skip (`sql_replica_skip_counter`).**
Right for the most common case: the failing transaction is one
idempotent DDL statement (`ALTER USER`, `CREATE USER`, `GRANT`,
`DROP`). The replica advances past it without losing any data, then
resumes streaming from the next event.

```
./scripts/fix_mysql_repl.sh --pod mysql-1 skip --dry-run   # read first
./scripts/fix_mysql_repl.sh --pod mysql-1 skip --yes
```

Under the hood:

```sql
STOP REPLICA;
SET GLOBAL sql_replica_skip_counter = 1;
START REPLICA;
```

If the failing event is part of a multi-statement transaction and
`sql_replica_skip_counter = 1` skips too much, use option B.

**Option B — GTID-aware skip.** Inject one empty transaction at the
offending GTID so the replica's `Executed_Gtid_Set` advances past
it. Use this when the failing transaction is grouped with other
statements that should still be applied.

```
./scripts/fix_mysql_repl.sh --pod mysql-1 skip-gtid \
    b11692f4-70d7-11f1-8f40-ceedec70d9b7:20 --dry-run
./scripts/fix_mysql_repl.sh --pod mysql-1 skip-gtid \
    b11692f4-70d7-11f1-8f40-ceedec70d9b7:20 --yes
```

Under the hood:

```sql
STOP REPLICA;
SET GTID_NEXT='b11692f4-70d7-11f1-8f40-ceedec70d9b7:20';
BEGIN;
COMMIT;
SET GTID_NEXT='AUTOMATIC';
START REPLICA;
```

This is the documented "Skipping Transactions With GTIDs" procedure
in the MySQL refman.

**Option C — reset the channel.** Stop and re-establish the
replication channel from scratch using the credentials baked into
the `chatroom-mysql` Secret. The replica keeps its existing datadir
and replays any binlog events between the last-applied GTID and the
master's current position. Faster than a full re-clone (no dump-load,
no PVC drop) — slower than a skip, but bulletproof.

```
./scripts/fix_mysql_repl.sh --pod mysql-1 reset --dry-run
./scripts/fix_mysql_repl.sh --pod mysql-1 reset --yes
```

Use this when skip / skip-gtid loop on the same transaction, or when
the relay log has been corrupted by repeated partial applies.

#### 9.14.3 Verify

After any of the above, re-run `status` and confirm:

- `Replica_SQL_Running: Yes`
- `Seconds_Behind_Master: 0` (give it a few seconds — the IO thread
  has to catch up first; sub-second in steady state)
- `Last_SQL_Error:` is empty

Then spot-check a row count matches the master:

```
kubectl -n chatroom exec mysql-0 -- mysql -uroot chatroom_db \
    -e 'SELECT COUNT(*) AS messages FROM messages'
kubectl -n chatroom exec mysql-1 -- mysql -uroot chatroom_db \
    -e 'SELECT COUNT(*) AS messages FROM messages'
```

#### 9.14.4 If the same transaction keeps failing

If `skip` advances the position but the *next* event is also a
problem (you'll see a new `Last_SQL_Error` referencing a different
GTID), the underlying state on the replica is genuinely diverged
from the master. Common causes:

- A manual `mysql>` session on the replica wrote to a
  non-`--read-only` table — replicas in this StatefulSet set
  `--super-read-only=ON`, but that only catches writes via the
  standard client; `SET sql_log_bin=0` followed by a write still
  bypasses it. Identify the divergent rows with `pt-table-checksum`
  or `mysqlcheck` and reconcile by hand, then run `skip` again.
- The replica's `REPLICATION_PASSWORD` does not match the master —
  re-render `k8s/secrets.runtime.yaml` (run
  `./scripts/build_images.sh` so both sides come from the same
  `app/.env.runtime`) and reset the channel with option C.
- The replica was bootstrapped from an older snapshot and is missing
  a schema migration the master has applied. Drop the PVC and let
  the bootstrap re-clone, per §9.10.1.

#### 9.14.5 Don't confuse with §9.10

§9.10 covers a replica that won't *start* (stuck at `0/1 Ready`,
CrashLoopBackOff from a bootstrap-time failure, `mysqldump`
permission errors, etc.) — that flow needs a pod + PVC drop and a
re-bootstrap. §9.14 here covers a replica that *is* running but the
applier thread inside mysqld has stopped on a bad binlog event. No
PVC drop is needed for §9.14.

---

## 10. Quick reference

| Task | Command |
| --- | --- |
| Build images | `./scripts/build_images.sh` |
| Rebuild with fresh MySQL + replication password | `./scripts/build_images.sh --rebuild` |
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
| Tail MySQL master logs | `kubectl -n chatroom logs -f mysql-0` |
| Tail MySQL replica logs | `kubectl -n chatroom logs -f mysql-1` |
| Check MySQL replication | `kubectl -n chatroom exec mysql-1 -- mysql -uroot -p"$PW" -e 'SHOW SLAVE STATUS\G'` |
| Repair a stuck replica SQL thread | `./scripts/fix_mysql_repl.sh --pod mysql-1 status` (then `skip` / `skip-gtid <uuid:tag>` / `reset` — see §9.14) |
| Tail Redis logs | `kubectl -n chatroom logs -f redis-0` |
| Check Redis replication | `kubectl -n chatroom exec redis-1 -- redis-cli INFO replication` |
| List Sentinel masters | `kubectl -n chatroom exec redis-sentinel-0 -- redis-cli -p 26379 sentinel master chatroom-redis` |
| Port-forward to app | `kubectl -n chatroom port-forward svc/chatroom-app 8000:80` |
| Port-forward to MySQL master | `kubectl -n chatroom port-forward svc/mysql 3306:3306` |
| Enable replica reads (multi-node) | `echo 'MYSQL_READ_HOST=mysql-replica' >> app/.env.runtime && ./scripts/build_images.sh && ./scripts/deploy_k8s.sh` |
| Health check | `curl -s http://localhost:8000/healthz` |
| Roll out a new app image | `kubectl -n chatroom rollout restart deployment/chatroom-app` |
| Roll out a new MySQL image | `kubectl -n chatroom rollout restart statefulset/mysql` |
| Uninstall (data-loss) | `./scripts/deploy_k8s.sh --uninstall` |
