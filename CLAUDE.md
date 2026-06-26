# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A FastAPI chat-room backend backed by MySQL, with a vanilla-JS/HTML/CSS frontend served from `app/static`. Real-time delivery uses WebSockets; the same room state is reachable via REST for non-live operations (uploads, history pagination, invites). Room secret phrases are stored encrypted (Fernet) so the server can include them in invitation emails — they are not hashed.

## Layout

- `app/main.py` — FastAPI app. Mounts routers under `/auth`, `/rooms`, `/ws`, `/messages`; serves `/`, `/login`, `/signup` and `/static/*` from `app/static/`. Exposes `/healthz` (intentionally DB-free so k8s probes don't restart pods on transient DB blips).
- `app/database.py` — SQLAlchemy engine + `get_db()` dependency. Reads `MYSQL_USER`/`MYSQL_PASSWORD`/`MYSQL_HOST`/`MYSQL_DB` from `.env`. Raises on startup if any are missing.
- `app/models.py` — ORM: `User`, `Room`, `RoomMember`, `Message`. `Room.name` is unique; `Room.secret_phrase_hash` is nullable (NULL = no pass phrase).
- `app/schemas.py` — Pydantic v2 request/response models. Each class has its own `model_config = ConfigDict(from_attributes=True)` (module-level assignment does not work).
- `app/crud.py` — DB access functions. `join_room` enforces pass-phrase rules and is the single source of truth for both `/rooms/{id}/join` and `/rooms/join-by-name`.
- `app/utils.py` — Password hashing (bcrypt, with UTF-8-safe 72-byte truncation), JWT signing, Fernet-based room secret encrypt/decrypt, SMTP invite sender. Port 465 = SMTPS (implicit TLS), other ports use opportunistic STARTTLS when `MAIL_USE_TLS=true`.
- `app/ws_manager.py` — In-memory `room_id -> [WebSocket]` registry. Module-level singleton shared by both routers.
- `app/routers/auth.py` — `/auth/signup`, `/auth/login`, plus `get_current_user` dependency (OAuth2 bearer). Both REST and WS depend on it (WS variant lives inline in `chats.py`).
- `app/routers/rooms.py` — Create/list/join/delete rooms and the SMTP-backed `/rooms/{id}/invite`. The owner-only `DELETE /rooms/{id}` removes the caller's membership, not the room itself.
- `app/routers/messages.py` — REST message fetch (`GET /messages/{room_id}/messages`) and upload (`POST /messages?room_id=...`). Owns a hand-rolled `_serialize` because Pydantic v2 will not auto-coerce `LargeBinary` bytes to `str` for the response model — calling `MessageResponse.model_validate` on an ORM instance with binary data raises.
- `app/routers/chats.py` — WebSocket endpoint `/ws/{room_id}`. Authenticates via `?token=...` query param or `Authorization: Bearer` header, sends last 50 messages on connect, then loops. Image messages get a 200×200 thumbnail via Pillow.
- `app/static/` — Frontend (`index.html`, `login.html`, `signup.html`, `script.js`, `style.css`).
- `database_setup.sql` — Idempotent CREATE TABLE statements plus the two migrations that retro-fit existing installs: drop NOT NULL on `rooms.secret_phrase_hash`, add unique index on `rooms.name`.
- `scripts/create_env.sh` — Bootstraps `.env` with documented placeholders. Refuses to clobber an existing `.env` unless `--force` is passed.
- `scripts/change_db_password.sh` — Rotates the MySQL password (URL-safe random, avoids `@:/?#[]%`) and rewrites `.env` atomically with a timestamped backup. Sources `scripts/_random_password.sh` for the generator.
- `scripts/_random_password.sh` — Shared helper (sourced, not executed). Defines `generate_url_safe_password` and `url_encode_value`. Also used by `build_images.sh` so the no-`@:/?#[]%` invariant lives in one place.
- `Dockerfile` (repo root) — App image (`python:3.11-slim`, non-root `app` user, `EXPOSE 8000`, healthcheck on `/healthz`). Reads config from environment at runtime; no `.env` baked in.
- `mysql/Dockerfile` + `mysql/init/01-schema.sql` + `mysql/init/99-grants.sql.template` — Custom MySQL 8 image. `01-schema.sql` is the schema only (the official mysql entrypoint handles root from env). `99-grants.sql.template` is sed-rendered at build time with the build-arg password so the app's `MYSQL_PASSWORD` env matches the DB side. The rendered `99-grants.sql` is gitignored.
- `scripts/build_images.sh` — Generates a random URL-safe MySQL root password + JWT + Fernet keys, writes them to `app/.env.runtime` (gitignored), renders the matching chatroom-mysql + chatroom-app Secrets and the chatroom-app ConfigMap into `k8s/secrets.runtime.yaml` (also gitignored + dockerignored), and builds both images into the local Docker daemon as `chat-room-server:latest` and `chatroom-mysql:latest`. Idempotent (reuses `app/.env.runtime`); pass `--rebuild` to rotate the MySQL password.
- `k8s/` — k8s manifests (namespace, MySQL + app Deployments, PVC, Services, placeholder Secrets, Ingress). The Secrets templates (`10-mysql-secret.yaml`, `31-app-secret.yaml`) hold `REPLACE_AT_DEPLOY_TIME` placeholders and are intentionally invalid for `kubectl apply` — `build_images.sh` renders the real values into `k8s/secrets.runtime.yaml` (which is what `kubectl apply -f k8s/` actually applies). The static ConfigMap that used to live in `30-app-config.yaml` is now part of the rendered manifest too. `imagePullPolicy: Never` (images are local-only). No `hostPath`, no `nodeSelector` — works on any cluster with a default StorageClass and an Ingress controller.
- `scripts/deploy_k8s.sh` — Pre-flight (`kubectl` + active context), creates the `chatroom` namespace, sanity-checks the cluster's chatroom-app Secret against `app/.env.runtime` (fails fast on password mismatch), `kubectl apply -f k8s/`, scales chatroom-app to one replica per cluster node, rolls out both Deployments, prints the Ingress address (or a `port-forward` hint). Supports `--uninstall` to tear down.
- `.dockerignore` — Excludes `.git`, `__pycache__`, `*.pem`, `bdy.tar.gz`, `app/.env.runtime`, the entire `k8s/` and `mysql/` scaffolding trees, and AI-assistant state from the app image's build context.

## Running locally

```
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
./scripts/create_env.sh        # writes .env with placeholders; edit it
mysql -u root -p < database_setup.sql
uvicorn app.main:app --reload  # serves API on :8000, frontend at /
```

## Container + k8s deployment

Anyone with Docker and a `kubectl` context can run:

```
./scripts/build_images.sh      # builds chatroom-mysql + chat-room-server
                               #   (writes app/.env.runtime, renders
                               #    k8s/secrets.runtime.yaml, both gitignored)
./scripts/deploy_k8s.sh        # kubectl apply -f k8s/, waits for rollout
```

For `kind`/`k3d`/`minikube`, the images need to be loaded into the cluster's
container runtime after `build_images.sh` — e.g. `kind load docker-image chat-room-server:latest chatroom-mysql:latest`. The script does not push to a registry and does not invoke a specific loader, since the right command depends on which local-cluster tool is in use.

To rotate the MySQL password, rerun `./scripts/build_images.sh --rebuild` (which updates `app/.env.runtime` and the MySQL image) and then `./scripts/deploy_k8s.sh` to reconcile. To tear everything down, `./scripts/deploy_k8s.sh --uninstall`.

For SMTP without a real relay, run `python -m smtpd -n -c DebuggingServer localhost:1025` and set `MAIL_HOST=localhost`, `MAIL_PORT=1025`, `MAIL_USE_TLS=false`, with `MAIL_USER`/`MAIL_PASSWORD` blank.

The project ships an HTTP frontend at `/`; you can also drive it from any WebSocket/HTTP client.

## Tests

There is no test suite in the repo (`requirements.txt` has no pytest). For a smoke test:

- `curl http://localhost:8000/healthz` → `{"status":"ok"}`
- Sign up → log in → `GET /rooms/my` → `POST /rooms/` with
  `{"ai_enabled": true, "ai_persona": "Professional"}` →
  `POST /rooms/join-by-name` → connect to
  `ws://localhost:8000/ws/{room_id}?token=<jwt>` and send a text
  `WSMessage` containing `@assistant`. Within a few seconds the AI
  should reply on the same WebSocket.

## Environment

`.env` is gitignored. Required variables (see `scripts/create_env.sh` for the full template):

- `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_HOST`, `MYSQL_DB`
- `SECRET_KEY` (JWT), `ALGORITHM` (HS256), `ACCESS_TOKEN_EXPIRE_MINUTES`
- `ROOM_SECRET_KEY` (Fernet) — `python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"`. Rotating this key invalidates every stored room pass phrase.
- `MAIL_HOST`, `MAIL_PORT`, `MAIL_USER`, `MAIL_PASSWORD`, `MAIL_FROM`, `MAIL_USE_TLS`
- `OLLAMA_HOST`, `OLLAMA_PORT`, `OLLAMA_MODEL` — Ollama endpoint for the
  AI assistant (consumed by `app/ai.py`). `OLLAMA_HOST` must include
  scheme and may already include a port; `OLLAMA_PORT` is only appended
  when no port is present. See the "AI assistant" section above.

## AI assistant

Rooms with `ai_enabled=true` get a synthetic `@assistant` participant.
The assistant is implemented as a single `users` row with
`username='assistant'` and a persona selected from a fixed enum:
Professional, Funny, Chaotic, Sarcastic, Anime-girlfriend,
Peter-Griffin, Stewie-Griffin (the API values are hyphenated; the
frontend `<select>` shows friendly labels).

Trigger: when a user sends a text message containing the whole-word
mention `@assistant` (case-insensitive, regex `(?<![\w])@assistant(?![\w])`
so `admin@assistant.com` does NOT trigger), `app/ai.py::maybe_reply`
runs as a background `asyncio` task. The task reads the last 30 messages
for context, builds an Ollama chat prompt with the room's persona system
prompt + history, and POSTs to `OLLAMA_HOST/api/chat`. If the message
also contains a `/search <query>` keyword (same word-boundary regex),
DuckDuckGo snippets are added as additional context before the LLM
call. The reply is persisted to MySQL and broadcast via the existing
WebSocket manager, so every connected client sees it like any other
message.

The AI does NOT reply to image/file/video messages (it observes them
silently — they appear in its context as one-line notes like
`"bob sent an image: cat.jpg"`). The AI does NOT reply to its own
messages (loop prevention in `maybe_reply`). The AI is a `RoomMember`
of every AI-enabled room; its membership is created at room creation,
so no separate join API is needed.

Frontend: create-room modal has an "Enable AI assistant" checkbox + a
persona dropdown. Messages from the AI render with a purple bubble
border and a 🤖-prefixed author line.

## Conventions / things that are easy to miss

- The WS message broadcast and the HTTP POST response carry the same message `id`; the frontend dedupes the WS echo against the HTTP response using it.
- `MessageResponse.data` and `.thumbnail` are declared as `str` but `Message.data` is `LargeBinary`. Always go through `messages._serialize`, never call `MessageResponse.model_validate(orm_msg)` directly on a row with binary data.
- `_truncate_password` in `app/utils.py` truncates to 72 bytes on a UTF-8 boundary so multi-byte passwords aren't split mid-codepoint.
- CORS is wide-open (`allow_origins=["*"]`); tighten before deploying.
- `DELETE /rooms/{id}` is owner-only and removes the caller's `RoomMember` row, not the room — other members keep their access.
- Room `name` is the user-facing identifier and is unique; the join-by-name flow uses it, and invite emails render it directly.