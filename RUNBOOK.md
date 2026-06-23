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

---

## 1. What gets deployed

| Component | Image | Replicas | Storage | Exposed via |
| --- | --- | --- | --- | --- |
| `chatroom-app` (FastAPI + static frontend) | `chat-room-server:latest` | 2 | none | ClusterIP Service `:80` → Ingress |
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
> the JWT signing key, and the Fernet room-secret key. It is gitignored.
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
5. Runs `docker build` for the MySQL image, passing the password as a
   build-arg. The MySQL Dockerfile `sed`s the value into
   `mysql/init/99-grants.sql`, so on first boot the container pins the
   root password to that exact value.
6. Runs `docker build` for the app image. **No `.env` is baked in** —
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
   "Run scripts/build_images.sh first").
3. Creates the `chatroom` namespace if it doesn't exist.
4. Creates/updates the `chatroom-mysql` and `chatroom-app` Secrets
   imperatively from `app/.env.runtime`. **The values never end up in a
   committed manifest.**
5. `kubectl apply -f k8s/` — applies all nine manifests in lexical
   order.
6. `kubectl rollout status` for both Deployments, with a 5-minute
   timeout each.
7. Prints the Ingress address if one was assigned, or a `port-forward`
   hint if not.

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

### 6.3 Pushing to a registry (managed clusters / multi-node)

The `build_images.sh` script only tags images in the local Docker
daemon. If your cluster's nodes can't reach that daemon (e.g. EKS, GKE,
AKS, or a multi-node kind setup), push to a registry and update the
Deployments to pull:

```
# Example: GitHub Container Registry
REGISTRY=ghcr.io/your-org/chat-room-server
docker tag chat-room-server:latest $REGISTRY:1.0.0
docker tag chatroom-mysql:latest     $REGISTRY-mysql:1.0.0
docker push $REGISTRY:1.0.0
docker push $REGISTRY-mysql:1.0.0
```

Then edit `k8s/21-mysql-deployment.yaml` and `k8s/40-app-deployment.yaml`
to reference the registry tag and remove `imagePullPolicy: Never` (or
set it to `Always`). This is the one place the committed k8s manifests
need editing before deploy.

### 6.4 `--uninstall`

```
./scripts/deploy_k8s.sh --uninstall
```

Deletes the `chatroom` namespace and every resource in it, **including
the PVC and all its data**. There is no `--uninstall --keep-data`; if
you want to preserve the data, take a `mysqldump` first (see §8.2).

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
docker save chatroom-mysql:latest | <load into cluster>   # see §5
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
# Read the password
MYSQL_PASSWORD="$(grep ^MYSQL_PASSWORD= app/.env.runtime | cut -d= -f2-)"
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
kubectl -n chatroom exec -it mysql-0 -- mysql -uroot -p"$MYSQL_PASSWORD" chatroom_db < my-migration.sql
```

(Or use Alembic / a proper migration tool — out of scope for this
project.)

### 8.5 Tearing down

```
./scripts/deploy_k8s.sh --uninstall
```

This is destructive: it deletes the PVC and the data on it. To preserve
the data, take a dump first (§8.2), then uninstall.

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
| Deploy | `./scripts/deploy_k8s.sh` |
| Check pod status | `kubectl -n chatroom get pods` |
| Tail app logs | `kubectl -n chatroom logs -f -l app.kubernetes.io/component=app` |
| Tail MySQL logs | `kubectl -n chatroom logs -f mysql-0` |
| Port-forward to app | `kubectl -n chatroom port-forward svc/chatroom-app 8000:80` |
| Health check | `curl -s http://localhost:8000/healthz` |
| Roll out a new app image | `kubectl -n chatroom rollout restart deployment/chatroom-app` |
| Uninstall (data-loss) | `./scripts/deploy_k8s.sh --uninstall` |
