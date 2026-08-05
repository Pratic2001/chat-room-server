# chat-room-server

A self-hosted chat room server: a **FastAPI** backend with **MySQL** storage,
real-time delivery over **WebSockets**, a vanilla JS/HTML/CSS frontend served
from `app/static`, and an optional **AI assistant** (`@assistant`) backed by
Ollama. It deploys either as plain Docker containers or to a Kubernetes
cluster — both via one-command installers.

```
┌────────────┐   REST + WS   ┌──────────────────┐   SQL/Redis/LLM   ┌──────────┐
│  Browser   │ ─────────────►│  chat-room-server │ ────────────────►│ MySQL    │
│  (static)  │               │  (FastAPI)       │                   │ Redis    │
└────────────┘               └──────────────────┘                   │ Ollama   │
                                                                     └──────────┘
```

---

## Features

- **Rooms & members** — create rooms (optionally pass-phrase protected), join by
  name or id, invite members by email (SMTP), ban/rejoin, delete (owner-only).
- **Real-time chat** — WebSockets for live delivery; the same state is reachable
  over REST for history pagination, uploads and invites. Text, image, file and
  video messages (images get a 200×200 thumbnail).
- **AI agent** — opt-in per room (`ai_enabled=true`). Mention `@assistant` and a
  tool-calling agent backed by Ollama replies in the room's persona
  (Professional, Funny, Chaotic, Sarcastic, Anime-girlfriend, Peter-Griffin,
  Stewie-Griffin). The agent decides itself when to use tools — it can search
  the web (`web_search`), pull recent news (`web_news`), see who's in the room
  (`room_users`), read the time (`current_time`) and do arithmetic
  (`calculate`). It auto-detects whether the configured Ollama model supports
  tool-calling and falls back to a plain (still streaming) reply otherwise.
- **Secure by default** — passwords bcrypt-hashed, JWTs for auth, room pass
  phrases stored encrypted (Fernet) so they can be emailed on invite.
- **HA-ready** — the k8s layout runs MySQL master + read-replicas, Redis +
  Sentinel failover, and a multi-replica app tier; pods tolerate node loss and
  reschedule within ~25s of a node failure.

### AI agent & tools

Rooms with **Enable AI assistant** get a synthetic `@assistant` participant.
Mention `@assistant` and the room's persona replies — but the assistant is now
an **agent**: if the configured Ollama model supports function calling, it can
decide to call tools mid-conversation and the results are fed back before it
composes the final answer. While a tool runs you'll see a small
"🔍 searching the web…" status line in the chat bubble.

Available tools (see `app/agent_tools.py`):

| Tool | What it does |
|---|---|
| `web_search(query)` | Web results (title/URL/snippet) — Brave or Google first, DuckDuckGo as fallback |
| `web_news(query)` | Recent news headlines for breaking-news questions |
| `room_users()` | The usernames currently in the room, so it can address people |
| `current_time()` | Server UTC + local time for time/date/schedule questions |
| `calculate(expression)` | Safe arithmetic (`2+2*7`, `sqrt(144)`) — no `eval` |

Search is multi-provider: `web_search` / `web_news` try **Brave**
(`BRAVE_API_KEY`), then **Google** (`GOOGLE_API_KEY` + `GOOGLE_CSE_ID`; web
only), and always fall back to **DuckDuckGo** (no key) when a provider is
unconfigured, fails, or returns nothing. Leave the keys blank to keep
DuckDuckGo-only behavior — the results each carry an `engine` field so the
agent can cite its source.

Tool-calling needs a model that advertises `tools` in its Ollama capabilities
(`qwen3:8b` and `llama3.3` do; `llama3.2` doesn't). The server detects this per
model via `OLLAMA_MODEL` and falls back to a single streaming reply when tools
aren't available, so nothing breaks if you keep the default.

---

## Quick start

Pick one path. Both installers **prompt for your Ollama host/port and SMTP
details**, generate fresh credentials, and leave you with a running server.

### Option A — Kubernetes (recommended)

Targets `kind`, `k3d`, `minikube`, or Docker Desktop's built-in k8s:

```bash
curl -sL <release-url>/install-k8s.sh -o install-k8s.sh && bash install-k8s.sh
# or, from this repo:
./install-k8s.sh
```

It builds the two images locally, loads them into your cluster, and deploys
the whole stack. When it finishes:

```bash
kubectl -n chatroom port-forward svc/chatroom-app 8000:80   # open http://localhost:8000
```

For a **multi-node / remote cluster** (EKS, GKE, a bare-metal kubeadm cluster)
whose nodes can't reach your Docker daemon, pull the prebuilt images instead:

```bash
./install-k8s.sh --registry pratic2001
```

> The MySQL image bakes its root + replication passwords at build time from the
> `MYSQL_ROOT_PASSWORD` / `REPLICATION_PASSWORD` **GitHub Actions secrets**, and
> since v0.1.2 also stores them inside the image at
> `/etc/chatroom/mysql-credentials`. The installer auto-extracts them with
> `docker run ... cat /etc/chatroom/mysql-credentials`, so you don't re-enter
> them. (Exporting `MYSQL_ROOT_PASSWORD`/`REPLICATION_PASSWORD` still overrides
> and skips the extraction.)

### Option B — plain Docker (no Kubernetes)

```bash
curl -sL <release-url>/install-non-cluster.sh -o install-non-cluster.sh && bash install-non-cluster.sh
# or, from this repo:
./install-non-cluster.sh
```

This runs `scripts/build_images.sh` (builds `chat-room-server` +
`chatroom-mysql`, generates credentials, prompts for SMTP/Ollama) and brings
up MySQL + Redis + the app with `docker compose`. The stack lands on:

- Frontend: http://localhost:8000/
- Health:   http://localhost:8000/healthz

Stop it with `./install-non-cluster.sh --down`.

### Smoke test (either path)

```bash
curl http://localhost:8000/healthz                # {"status":"ok"}
# sign up → log in → create a room with ai_enabled → join → connect to
# ws://localhost:8000/ws/{room_id}?token=<jwt> and send a text message
# containing @assistant; the AI replies on the same socket within seconds.
```

---

## Releases & CI/CD

Every `v*` tag triggers a GitHub Actions workflow that:

1. Builds and pushes the images to Docker Hub:
   - `pratic2001/chatroom-app`
   - `pratic2001/chatroom-mysql`
   (tagged `:vX.Y.Z` and `:latest`; `main` pushes also update a rolling `:main`
   tag — other branches only build/validate).
2. Cuts a **GitHub Release** carrying the versioned installers
   (`install-k8s.sh`, `install-non-cluster.sh`, `docker-compose.yml`). The
   release job bakes the tag into the scripts' `REPO_REF`, so a standalone
   downloaded script installs exactly that version.

Configure these **repository secrets**:
`DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, and `MYSQL_ROOT_PASSWORD` +
`REPLICATION_PASSWORD` (baked into the MySQL image by the pipeline; the
installer reads them back out of the image, so you don't re-enter them).

```bash
git tag v1.1.0 && git push origin v1.1.0      # image push + release, automated
```

---

## Architecture

| Component | k8s (Option A) | Docker (Option B) |
|---|---|---|
| API + static frontend | `Deployment/chatroom-app` (1 pod/node, `imagePullPolicy: Never` or registry) | `chatroom-app` container |
| Storage | `StatefulSet/mysql` — `mysql-0` master, `mysql-1..N-1` read-replicas (GTID) | single `chatroom-mysql` (standalone master) |
| Cache / pub-sub | `StatefulSet/redis` + `redis-sentinel` (failover) | single `chatroom-redis` |
| Ingress | `Ingress/chatroom` (nginx) | `ports: "8000:8000"` |

Runtime config comes from **environment variables**, never baked files:
- `app/database.py` builds the MySQL URL from `MYSQL_*`.
- `app/utils.py` reads JWT / Fernet / SMTP.
- `app/redis_bus.py` fans WS broadcasts across pods (Sentinel or direct).
- `app/ai.py` talks to Ollama at `OLLAMA_HOST[:OLLAMA_PORT]`.

Credentials flow: `scripts/build_images.sh` (or the installers) generate a
MySQL root password, JWT key and Fernet key into `app/.env.runtime`
(gitignored), and render `k8s/secrets.runtime.yaml` (gitignored) which
`scripts/deploy_k8s.sh` applies as the `chatroom-app` / `chatroom-mysql`
Secrets + `chatroom-app` ConfigMap.

---

## Manual flows (if you don't use the installers)

```bash
# local dev (uvicorn, needs a MySQL on localhost)
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
./scripts/create_env.sh            # writes .env with placeholders; edit it
mysql -u root -p < database_setup.sql
uvicorn app.main:app --reload

# build + deploy to k8s
./scripts/build_images.sh          # builds images, writes app/.env.runtime
                                   #   + k8s/secrets.runtime.yaml
./scripts/deploy_k8s.sh            # kubectl apply -f k8s/, waits for rollout
./scripts/deploy_k8s.sh --uninstall
```

For `kind`/`k3d`/`minikube` the locally built images must be loaded after
`build_images.sh` (e.g. `kind load docker-image chat-room-server:latest
chatroom-mysql:latest`) — see `RUNBOOK.md` §5 for each tool.

---

## Environment variables

`.env` (local dev) or `app/.env.runtime` + rendered k8s Secrets/ConfigMap
(k8s). Full template in `scripts/create_env.sh`. The important ones:

| Variable | Purpose |
|---|---|
| `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_DB` | SQLAlchemy connection. `MYSQL_READ_HOST` (optional) routes reads to a replica on multi-node. |
| `SECRET_KEY`, `ALGORITHM`, `ACCESS_TOKEN_EXPIRE_MINUTES` | JWT signing. |
| `ROOM_SECRET_KEY` | Fernet key for encrypting room pass phrases. |
| `MAIL_HOST`, `MAIL_PORT`, `MAIL_USER`, `MAIL_PASSWORD`, `MAIL_FROM`, `MAIL_USE_TLS` | SMTP for invite emails (blank host disables). |
| `REDIS_URL`, `REDIS_SENTINELS`, `REDIS_MASTER_NAME` | WS cross-pod fan-out. |
| `OLLAMA_HOST`, `OLLAMA_PORT`, `OLLAMA_MODEL` | AI agent endpoint. For tool-calling (web search, news, …) configure a tools-capable model, e.g. `qwen3:8b` or `llama3.3`. The default `llama3.2` still works but replies without tools. |
| `BRAVE_API_KEY`, `GOOGLE_API_KEY`, `GOOGLE_CSE_ID` | Optional AI-agent search providers (see "AI agent & tools"). Leave blank for DuckDuckGo-only. |
| `MYSQL_ROOT_PASSWORD`, `REPLICATION_PASSWORD` | MySQL image build args / k8s Secrets (baked at build time). |

Generate a Fernet key with:
`python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"`
Rotate the MySQL password with `./scripts/change_db_password.sh`.

---

## Tests

There is no test suite in the repo. Smoke test in the "Quick start" section:
`/healthz`, sign-up → login → room → WS message with `@assistant`.

---

## Docs

- **`RUNBOOK.md`** — deep operations guide: prerequisites, image loading per
  cluster tool, registry push, verification, backups, password rotation, and
  the gotchas behind every layout decision. Read it before running anything
  in production.

## License / status

Home-lab project. CORS is wide open (`allow_origins=["*"]`) and there is no
built-in TLS — tighten both before exposing it publicly (see `RUNBOOK.md`).
