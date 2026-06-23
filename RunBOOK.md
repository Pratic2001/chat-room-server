# Runbook – Chat‑Room Server

This runbook documents the common operational tasks for the chat‑room server (FastAPI + MySQL) when running locally, in Docker, or on Kubernetes.

---

## 1. Prerequisites

| Tool | Version |
|------|---------|
| Docker | ≥ 20.10 |
| kubectl | ≥ 1.25 (for k8s deployments) |
| kind / k3d / minikube | optional – for local clusters |
| python | 3.11 (only for local venv runs) |

---

## 2. Local Development (venv)

```bash
# 1️⃣ Create & activate virtual environment
python -m venv .venv && source .venv/bin/activate

# 2️⃣ Install dependencies
pip install -r requirements.txt

# 3️⃣ Bootstrap .env (run once, then edit the generated file)
./scripts/create_env.sh

# 4️⃣ Initialise the database schema
mysql -u root -p < database_setup.sql

# 5️⃣ Start the API (serves frontend at http://localhost:8000)
uvicorn app.main:app --reload
```

**Health check:** `curl http://localhost:8000/healthz` → `{"status":"ok"}`

---

## 3. Building Container Images (one‑time / when rotating secrets)

```bash
# Generates a random MySQL root password, JWT secret, Fernet key
# and writes them to app/.env.runtime (git‑ignored)
./scripts/build_images.sh            # idempotent
./scripts/build_images.sh --rebuild  # rotate MySQL password & rebuild images
```

*Outputs:* `chat-room-server:latest` and `chatroom-mysql:latest` in the local Docker daemon.

> **Note:** For a local Kubernetes cluster (kind, k3d, minikube) you must load the images into the cluster’s container runtime, e.g.  
> `kind load docker-image chat-room-server:latest chatroom-mysql:latest`

---

## 4. Deploying to Kubernetes

```bash
# 1️⃣ Create namespace, Secrets (from app/.env.runtime), and apply manifests
./scripts/deploy_k8s.sh

# 2️⃣ Verify rollout
kubectl -n chatroom rollout status deploy/chat-room-server
kubectl -n chatroom rollout status deploy/chatroom-mysql

# 3️⃣ Get the Ingress address (or use port‑forward for quick testing)
kubectl -n chatroom get ingress
# or
kubectl -n chatroom port-forward svc/chat-room-server 8000:80
```

**Uninstall:**

```bash
./scripts/deploy_k8s.sh --uninstall
```

---

## 5. Updating the MySQL Cluster IP (when the Service IP changes)

If the MySQL Service receives a new **clusterIP** (e.g., after a namespace change, Service recreation, or IP‑pool exhaustion), the FastAPI pods will fail to connect with an error like:

```
cannot connect to mysql on root@<old‑cluster‑IP>
```

### Procedure

1. **Discover the new clusterIP**

   ```bash
   kubectl -n chatroom get svc chatroom-mysql -o jsonpath='{.spec.clusterIP}'
   ```

2. **Run the helper script to inject the new IP into `app/.env.runtime`**

   ```bash
   chmod +x scripts/update_mysql_host.sh   # only once
   ./scripts/update_mysql_host.sh
   # → prompts for the new IP, updates app/.env.runtime
   ```

3. **Redeploy / rollout the app so it picks up the updated env file**

   ```bash
   ./scripts/deploy_k8s.sh
   # or, if you only want a rolling restart:
   kubectl -n chatroom rollout restart deploy/chat-room-server
   ```

> **Why this works:** `deploy_k8s.sh` reads `app/.env.runtime` to create the `app-secrets` Secret. Updating that file and re‑applying (or restarting) propagates the new `MYSQL_HOST` value to the pods.

---

## 6. Rotating Secrets (MySQL password, JWT, Fernet)

```bash
# Rotate MySQL root password + rebuild images + update K8s Secrets
./scripts/build_images.sh --rebuild
./scripts/deploy_k8s.sh
```

*All other secrets (JWT `SECRET_KEY`, Fernet `ROOM_SECRET_KEY`) are regenerated automatically by `build_images.sh`.*

---

## 7. SMTP Debugging (no real relay)

Run a local debugging SMTP server:

```bash
python -m smtpd -n -c DebuggingServer localhost:1025
```

Then set in `.env` / `app/.env.runtime`:

```
MAIL_HOST=localhost
MAIL_PORT=1025
MAIL_USE_TLS=false
MAIL_USER=
MAIL_PASSWORD=
```

Invitation emails will be printed to the console.

---

## 8. Common Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| `cannot connect to mysql on root@<IP>` | MySQL Service IP changed | Follow **§5 – Updating the MySQL Cluster IP** |
| `Health check fails` | DB not reachable / pod not ready | Check pod logs: `kubectl -n chatroom logs deploy/chat-room-server` |
| `Invitation emails not sent` | SMTP config wrong / port blocked | Verify `MAIL_*` vars; test with debug server (§7) |
| `WebSocket connection drops` | Ingress / proxy timeout | Increase proxy read timeout or use `port-forward` for testing |

---

## 9. Useful One‑liners

```bash
# Tail API logs
kubectl -n chatroom logs -f deploy/chat-room-server

# Tail MySQL logs
kubectl -n chatroom logs -f deploy/chatroom-mysql

# Exec into API pod (debug)
kubectl -n chatroom exec -it deploy/chat-room-server -- /bin/bash

# View current Secrets (decoded)
kubectl -n chatroom get secret app-secrets -o jsonpath='{.data}' | \
  jq -r 'to_entries|map("\(.key)=\(.value|@base64d)")|.[]'
```

---

## 10. References

- `CLAUDE.md` – full architecture & code‑map
- `scripts/` – all automation scripts
- `k8s/` – Kubernetes manifests
- `database_setup.sql` – idempotent schema + migrations

---

*Keep this runbook up‑to‑date whenever you add new operational scripts or change deployment topology.*