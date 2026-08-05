"""AI assistant for the chat room: a tool-calling agent backed by Ollama.

When a user mentions @assistant in a text message, a background task builds
a conversation (persona system prompt + recent history + the current ask)
and calls Ollama. If the configured model supports native function calling
(detected via Ollama's `/api/show`), the assistant runs as a **proper agent**:
it can decide to call tools — `web_search`, `web_news`, `room_users`,
`current_time`, `calculate` (see app/agent_tools.py) — the server executes
them and feeds the results back, looping until the model produces a final
answer. If the model does NOT support tools (e.g. the default `llama3.2`),
it falls back to the legacy single-shot streaming reply, so nothing breaks
until a tools-capable model is configured.

Key design decisions
---------------------
- Fire-and-forget: the routers call `asyncio.create_task(stream_reply(...))`
  and return immediately. The AI's HTTP calls to Ollama run on a background
  task and do NOT block the WebSocket receive loop.
- Two paths, one UX:
  - Agent path (model supports tools): a non-streaming tool-use loop. Each
    tool execution broadcasts an `ai_tool` envelope so the client can show
    "🔍 searching the web…" progress. The final answer is then replayed
    through the same coalesced `ai_chunk` stream as the legacy path, so the
    typewriter effect is identical either way.
  - Legacy path (no tools): a single streaming `/api/chat` call, exactly as
    before this change.
- Streaming: `stream_reply` emits `ai_start` / `ai_tool` / `ai_chunk` /
  `ai_end` envelopes over the WebSocket as work progresses. A final persisted
  `WSMessage` is broadcast at the end so non-streaming clients still see the
  bubble.
- Loop prevention: triggering_user_id is checked against the AI user's id
  at the top. AI messages are never reprocessed.
- Empty-reply filter: if Ollama returns an empty content string (or only
  whitespace) — or the tool loop exhausts its iteration budget — we skip the
  persist+broadcast step. No empty bubbles.
- Failure UX: on error we broadcast an `ai_error` envelope with a
  human-readable reason. The client renders a dedicated error bubble with a
  retry affordance.
- Context window: only the last 30 messages are sent to Ollama, ordered
  oldest → newest. Binary messages (image/file/video) are summarized as
  "[User X sent an image: filename.jpg]" rather than including the bytes.
  History is role-aware: user text → `role:"user"`, AI text →
  `role:"assistant"`, so the model sees who said what.
- Mention regex: a lookbehind/lookahead `(?<![\\w])@assistant(?![\\w])`
  case-insensitive, so `admin@assistant.com` does NOT trigger.
- Room disable: rooms with ai_enabled=False skip the trigger entirely.
- Crash isolation: the entire body of `stream_reply` is wrapped in a
  try/except that logs and swallows. A failed AI reply must never take
  down the WS receive loop on any pod.
"""

import asyncio
import json
import logging
import re
import time
from typing import Optional

import httpx

from app import crud, schemas
from app.agent_tools import TOOLS, run_tool, tool_label, tool_result_count
from app.crud import AI_USERNAME
from app.database import (
    OLLAMA_HOST,
    OLLAMA_PORT,
    OLLAMA_MODEL,
    WriteSessionLocal,
)
from app.schemas import ALLOWED_PERSONAS
from app.ws_manager import manager

log = logging.getLogger("uvicorn.error")

# Cache the AI user's id at module-load so the trigger check is a cheap
# int compare. Populated on the first call to `maybe_reply`; cleared on
# process restart (the row is in MySQL, so a re-read will succeed).
_AI_USER_ID_CACHE: Optional[int] = None


# ---------- Mention detection ----------

# Note: `\b@assistant\b` does NOT work the way you'd hope. `@` is not
# a word character in Python's `\b`, so the boundary between, e.g., `n`
# and `@` in `admin@assistant.com` is a word→non-word transition that
# satisfies `\b`, and `@assistant\b` is followed by `.` (non-word → word)
# which also satisfies `\b`. Net effect: `\b@assistant\b` matches the
# substring inside `admin@assistant.com`, which is the opposite of what
# we want.
#
# The right shape is an explicit lookbehind/lookahead: the character
# immediately before `@` must not be a word char (or must be the start
# of the string), and the character immediately after the trailing `t`
# must not be a word char (or must be the end of the string). That
# excludes `admin@assistant.com` (preceded by `n`, a word char) while
# still matching `@assistant`, `@assistant.`, `(@assistant)`, and
# `@ASSISTANT` (case-insensitive).
_MENTION_RE = re.compile(r"(?<![\w])@assistant(?![\w])", re.IGNORECASE)


def contains_mention(text: str) -> bool:
    """True iff @assistant appears as a whole word in `text`."""
    return bool(text and _MENTION_RE.search(text))


# ---------- Persona system prompts ----------

# Each persona is a short paragraph the model uses to set tone. Defined
# in code (not DB) so we can tweak without a migration. Keep these
# terse — long system prompts eat into the context window and degrade
# answer quality.
PERSONA_PROMPTS: dict[str, str] = {
    "Professional": (
        "You are a helpful, concise AI assistant in a chat room. "
        "Answer questions accurately and politely. Use plain language, "
        "avoid slang, and keep replies under 150 words unless the user "
        "explicitly asks for a longer explanation."
    ),
    "Funny": (
        "You are a witty AI assistant in a chat room. Use humor, "
        "punchlines, and the occasional pun to keep replies light, "
        "but still answer the underlying question. Keep replies under "
        "150 words."
    ),
    "Chaotic": (
        "You are a delightfully chaotic AI assistant in a chat room. "
        "Embrace tangents, random observations, and unexpected "
        "connections. Be entertaining, surprising, and creative — "
        "while still answering the question if there is one."
    ),
    "Sarcastic": (
        "You are a dry, sarcastic AI assistant in a chat room. Reply "
        "with dry wit and playful skepticism. Don't be mean; be "
        "smugly amused. Keep replies under 150 words."
    ),
    "Anime-girlfriend": (
        "You are a sweet, supportive anime-style girlfriend character "
        "in a chat room. Use affectionate language, occasional kaomoji "
        "((つ◕‿◕)つ, (っ◕‿◕)っ) and enthusiastic encouragement. "
        "Stay in character while still being helpful."
    ),
    "Peter-Griffin": (
        "You are Peter Griffin from Family Guy, chatting in a chat "
        "room. Reply in his voice: short, blunt, often distracted, "
        "with sudden non-sequiturs and a love of beer and TV. Use "
        "lowercase, occasional typos, and stream-of-consciousness "
        "asides. Be funny but do answer the question."
    ),
    "Stewie-Griffin": (
        "You are Stewie Griffin from Family Guy, chatting in a chat "
        "room. Reply in his voice: eloquent British-accented "
        "baby-talk, grandiose vocabulary, disdain for the other "
        "chatters, occasional scheming. Use dramatic phrasing and "
        "elevated diction. Be funny but do answer the question."
    ),
}

# Persona drift guard: a typo in ALLOWED_PERSONAS or a missed
# PERSONA_PROMPTS key would otherwise surface as a 500 at first use.
assert set(PERSONA_PROMPTS.keys()) == set(ALLOWED_PERSONAS), (
    f"PERSONA_PROMPTS keys {set(PERSONA_PROMPTS.keys())} "
    f"!= ALLOWED_PERSONAS {set(ALLOWED_PERSONAS)}"
)


def _system_prompt_for(persona: str | None) -> str:
    """Resolve a persona key to a system prompt, with a safe default."""
    if persona and persona in PERSONA_PROMPTS:
        return PERSONA_PROMPTS[persona]
    return PERSONA_PROMPTS["Professional"]


# ---------- Ollama calls ----------

def _ollama_url() -> str:
    """Build the Ollama API base URL.

    OLLAMA_HOST may already include scheme + port (e.g.
    "http://1.2.3.4:11434") or just host ("http://ollama"). Only append
    ":PORT" when no port is present in the host. We do NOT prepend a
    scheme — OLLAMA_HOST must include one.
    """
    host = (OLLAMA_HOST or "http://ollama").rstrip("/")
    # Split off the optional "scheme://" prefix and check the hostpart for ":".
    hostpart = host.split("//", 1)[-1]
    if ":" in hostpart:
        return host
    port = (OLLAMA_PORT or "11434").strip() or "11434"
    return f"{host}:{port}"


# How long (seconds) we trust a cached tool-capability answer before asking
# Ollama `/api/show` again. Long enough that a request per reply is never
# needed; short enough that switching OLLAMA_MODEL takes effect quickly.
TOOLS_CAPABILITY_TTL_S = 600.0

# Cached result of `_model_supports_tools()`. Separate sentinel from a real
# False so we can tell "never checked" from "checked, no tools".
_TOOLS_SUPPORT_CACHE: Optional[bool] = None
_TOOLS_SUPPORT_AT: float = 0.0


async def _model_supports_tools() -> bool:
    """True iff the configured Ollama model advertises tool-calling.

    Asks Ollama's `/api/show` for the model's `capabilities` list and caches
    the answer for TOOLS_CAPABILITY_TTL_S. Any failure (network, 404 for an
    unpulled model, malformed JSON) resolves to False so we fall back to the
    legacy single-shot path rather than erroring.
    """
    global _TOOLS_SUPPORT_CACHE, _TOOLS_SUPPORT_AT
    now = time.monotonic()
    if _TOOLS_SUPPORT_CACHE is not None and (now - _TOOLS_SUPPORT_AT) < TOOLS_CAPABILITY_TTL_S:
        return _TOOLS_SUPPORT_CACHE

    supports = False
    try:
        url = f"{_ollama_url()}/api/show"
        payload = {"model": OLLAMA_MODEL or "llama3.2"}
        async with httpx.AsyncClient(timeout=10.0) as client:
            r = await client.post(url, json=payload)
        if r.status_code == 200:
            caps = r.json().get("capabilities") or []
            supports = "tools" in caps
        else:
            log.warning("Ollama /api/show returned HTTP %s; assuming no tools.", r.status_code)
    except Exception as e:
        log.warning("Ollama /api/show failed (%s); assuming no tools.", e)

    _TOOLS_SUPPORT_CACHE = supports
    _TOOLS_SUPPORT_AT = time.monotonic()
    return supports


async def _chat_ollama(
    messages: list[dict],
    tools: list[dict] | None = None,
    timeout_s: float = 120.0,
) -> dict:
    """Non-streaming Ollama chat. Returns the full `message` dict.

    Returns `{"content": str, "tool_calls": list}`. On any failure (timeout,
    non-2xx, malformed JSON) it returns an all-empty placeholder so the agent
    loop can decide what to do instead of raising.
    """
    url = f"{_ollama_url()}/api/chat"
    payload = {
        "model": OLLAMA_MODEL or "llama3.2",
        "messages": messages,
        "stream": False,
    }
    if tools:
        payload["tools"] = tools
    try:
        async with httpx.AsyncClient(timeout=timeout_s) as client:
            r = await client.post(url, json=payload)
    except Exception as e:
        log.warning("Ollama chat POST failed: %s", e)
        return {"content": "", "tool_calls": []}
    if r.status_code != 200:
        log.warning("Ollama chat returned HTTP %s: %s", r.status_code, r.text[:200])
        return {"content": "", "tool_calls": []}
    try:
        body = r.json()
    except Exception as e:
        log.warning("Ollama chat JSON parse failed: %s", e)
        return {"content": "", "tool_calls": []}
    msg = body.get("message") or {}
    return {
        "content": (msg.get("content") or "").strip(),
        "tool_calls": msg.get("tool_calls") or [],
    }


async def _stream_ollama(messages: list[dict], timeout_s: float = 90.0):
    """Streaming Ollama chat. Async generator yielding content chunks.

    Sends `stream: True` and parses the `application/x-ndjson` body
    line-by-line. Each line is `{"message": {"content": "tok"}, "done": false}`
    until a final `{"done": true, ...}` arrives. Yields each `content`
    string verbatim — caller accumulates the full reply.

    Failures (timeout, non-2xx, malformed line, network error) are
    logged but do NOT raise: the iterator simply ends. The caller
    decides what "empty stream" means (broadcast ai_error vs ai_end
    with empty content).

    Used only by the legacy fallback path (models without tool support).
    """
    url = f"{_ollama_url()}/api/chat"
    payload = {
        "model": OLLAMA_MODEL or "llama3.2",
        "messages": messages,
        "stream": True,
    }
    try:
        client = httpx.AsyncClient(timeout=timeout_s)
    except Exception as e:
        log.warning("Ollama streaming client init failed: %s", e)
        return

    try:
        async with client.stream("POST", url, json=payload) as response:
            if response.status_code != 200:
                # Drain the body so the connection closes cleanly,
                # but don't bother buffering it — we already know
                # the request failed.
                try:
                    await response.aread()
                except Exception:
                    pass
                log.warning("Ollama streaming returned HTTP %s", response.status_code)
                return
            # `aiter_lines()` splits on \n and skips empty lines. Each
            # line is a JSON object — parse incrementally so a partial
            # stream (cut off mid-line) is discarded cleanly.
            async for raw in response.aiter_lines():
                if not raw:
                    continue
                try:
                    obj = json.loads(raw)
                except json.JSONDecodeError:
                    # Tolerate partial/fractured lines; just skip them.
                    continue
                if obj.get("done"):
                    # Terminal frame — Ollama's final summary line.
                    # Any `done_reason` / metrics are not surfaced
                    # to the caller; we're done streaming tokens.
                    return
                chunk = ((obj.get("message") or {}).get("content")) or ""
                if chunk:
                    yield chunk
    except Exception as e:
        # Network error mid-stream (DNS, connection reset, server
        # closed early, etc.). Log and end the iterator; the caller
        # will see "empty buffer" and broadcast ai_error.
        log.warning("Ollama streaming failed: %s", e)
        return


# ---------- Context assembly ----------

# Number of historical messages to include as conversation context.
# 30 is a reasonable balance between "fresh enough" and "fits in the
# LLM context window" for most Ollama models. Worst case ≈ 30 × 4KB ≈
# 120KB of text + persona ≈ 1KB — well within any Ollama context.
CONTEXT_WINDOW = 30


def _build_history(db, room_id: int) -> list[dict]:
    """Read the last CONTEXT_WINDOW messages for `room_id` and turn them
    into an Ollama-compatible, role-aware chat history.

    - human text messages → `role:"user"` with a `"username: content"`
      prefix so the model knows who's speaking;
    - the AI's own text messages → `role:"assistant"` (this is important for
      the tool loop: assistant turns must be labelled as such, not flattened
      into user turns);
    - binary messages (image/file/video) → a single-line `role:"user"` note
      so the model knows a non-text happened without receiving bytes it
      can't render.
    """
    # crud.get_messages_by_room orders DESC by created_at and applies
    # limit/offset; we reverse for chronological (oldest → newest).
    msgs = crud.get_messages_by_room(db, room_id=room_id, limit=CONTEXT_WINDOW)
    msgs = list(reversed(msgs))
    history: list[dict] = []
    for m in msgs:
        username = m.user.username if m.user else "unknown"
        if m.message_type == "text":
            if username == AI_USERNAME:
                history.append({"role": "assistant", "content": m.content or ""})
            else:
                history.append({"role": "user", "content": f"{username}: {m.content or ''}"})
        else:
            label = {
                "image": "sent an image",
                "video": "sent a video",
                "file": "sent a file",
            }.get(m.message_type, "sent a message")
            fname = m.file_name or ""
            tail = f": {fname}" if fname else ""
            history.append({"role": "user", "content": f"{username} {label}{tail}"})
    return history


# ---------- The main entry point ----------

async def maybe_reply(
    room_id: int,
    triggering_user_id: int,
    triggering_message_id: int,
    triggering_text: str,
) -> None:
    """Compatibility shim — wraps the streaming reply path.

    Kept so existing callers (and tests) that pass no `request_id`
    still get a sensible reply. Internally it now goes through
    `stream_reply` with a generated request_id; the streaming
    envelopes are broadcast as usual, and a final persisted message
    is sent. If you don't need streaming UX, prefer this entry point.
    """
    import uuid
    await stream_reply(
        room_id=room_id,
        triggering_user_id=triggering_user_id,
        triggering_message_id=triggering_message_id,
        triggering_text=triggering_text,
        request_id=str(uuid.uuid4()),
    )


async def stream_reply(
    room_id: int,
    triggering_user_id: int,
    triggering_message_id: int,
    triggering_text: str,
    request_id: str,
) -> None:
    """Background task: run the AI assistant and broadcast progress.

    Broadcasts the following envelopes to the room over the WebSocket:

    - `{"type": "ai_start", "id": request_id, "user_id": ai_user_id,
        "username": "assistant"}` once the room/persona check passes.
    - `{"type": "ai_tool", "id": request_id, "tool": name,
        "status": "start"|"done", "label": "...", "query": "..."}` per tool
        execution on the agent path (progress line in the placeholder bubble).
    - `{"type": "ai_chunk", "id": request_id, "delta": "tok"}` per
        coalesced chunk of the final answer (≤16 chars or ≤50ms legacy;
        fixed-size replay on the agent path).
    - `{"type": "ai_end", "id": request_id, "content": "..."}` when the
        reply finishes successfully, just before the persisted chat message
        is broadcast.
    - `{"type": "ai_error", "id": request_id, "reason": "..."}` if the
        reply fails or produces empty content.

    After `ai_end` (only on success), the same MessageCreate + broadcast
    path used by user messages persists the AI's reply and emits a regular
    WSMessage envelope so non-streaming clients (or clients that connected
    mid-stream) still see the bubble.

    Designed to be called via `asyncio.create_task` from the routers.
    Opens its own DB session so it outlives the request's session.
    Catches and logs every exception so the background task never crashes
    the event loop silently.
    """
    global _AI_USER_ID_CACHE
    try:
        db = WriteSessionLocal()
        try:
            # Lazy-resolve the AI user once per process.
            if _AI_USER_ID_CACHE is None:
                ai_user = crud.get_or_create_ai_user(db)
                _AI_USER_ID_CACHE = ai_user.id
            ai_user_id = _AI_USER_ID_CACHE

            # Loop prevention.
            if triggering_user_id == ai_user_id:
                return

            room = crud.get_room_by_id(db, room_id)
            if not room or not room.ai_enabled:
                return

            # Strip the @assistant mention before sending to the LLM so
            # it doesn't echo "@assistant: ..." in the response.
            final_user = _MENTION_RE.sub("", triggering_text).strip()
            # A bare "@assistant" with nothing else leaves an empty user
            # turn — nudge the model with a neutral prompt instead.
            if not final_user:
                final_user = "Hello!"

            messages: list[dict] = [
                {"role": "system", "content": _system_prompt_for(room.ai_persona)},
            ]
            messages.extend(_build_history(db, room_id))
            messages.append({"role": "user", "content": final_user})

            # Announce the bubble opening BEFORE any model work so the
            # client can render a placeholder immediately.
            await manager.broadcast(json.dumps({
                "type": "ai_start",
                "id": request_id,
                "user_id": ai_user_id,
                "username": AI_USERNAME,
            }), room_id)

            # Decide the path: agent (tools) vs legacy (single-shot stream).
            if await _model_supports_tools():
                content = await _run_agent_loop(room_id, request_id, messages, db)
            else:
                content = await _run_legacy_stream(room_id, request_id, messages)

            if content is None:
                return  # an ai_error was already broadcast by the path

            # Replay the final answer through the coalesced ai_chunk stream
            # so the client's typewriter effect is identical on both paths.
            await _broadcast_chunks(room_id, request_id, content)

            await manager.broadcast(json.dumps({
                "type": "ai_end",
                "id": request_id,
                "content": content,
            }), room_id)

            db_msg = crud.create_message(
                db=db,
                message=schemas.MessageCreate(
                    message_type="text",
                    content=content,
                ),
                room_id=room_id,
                user_id=ai_user_id,
            )
            ws_msg = schemas.WSMessage(
                id=db_msg.id,
                message_type="text",
                content=db_msg.content,
                user_id=ai_user_id,
                username=AI_USERNAME,
                created_at=db_msg.created_at,
            )
        finally:
            db.close()

        # Broadcast outside the DB transaction so a slow socket doesn't
        # hold an open DB connection.
        await manager.broadcast(ws_msg.model_dump_json(), room_id)

    except Exception as e:
        # Last-resort: log and swallow. A failed AI reply must not take
        # down the WS receive loop on any pod.
        log.exception("AI stream_reply crashed: %s", e)
        try:
            await manager.broadcast(json.dumps({
                "type": "ai_error",
                "id": request_id,
                "reason": "The assistant hit an unexpected error. Please try again.",
            }), room_id)
        except Exception:
            # If even the error broadcast fails, the user already saw
            # nothing — there's nothing else we can do.
            pass


# ---------- The agent (tool-calling) loop ----------

# Cap on consecutive model→tool→model iterations before we give up and
# report an error. 6 is plenty for a search + follow-up; anything more is
# almost certainly a model stuck in a loop.
MAX_TOOL_ITERATIONS = 6


async def _run_agent_loop(room_id: int, request_id: str, messages: list[dict], db) -> str | None:
    """Agent path: iterate model↔tool until a final answer arrives.

    Returns the final content string, or None if the loop failed (an
    `ai_error` envelope is broadcast by the caller's responsibility here —
    actually we broadcast it and return None).

    Each model response that contains `tool_calls` triggers one or more
    `ai_tool` envelopes + `run_tool` executions, with the results appended
    as `role:"tool"` messages so the model can continue.
    """
    for _ in range(MAX_TOOL_ITERATIONS):
        resp = await _chat_ollama(messages, tools=TOOLS)
        tool_calls = resp.get("tool_calls") or []
        content = resp.get("content") or ""

        if not tool_calls:
            if content:
                return content
            # No content and no tool calls — the model produced nothing.
            await _broadcast_ai_error(
                room_id, request_id,
                "The assistant didn't return a reply. Please try again.",
            )
            return None

        # The model wants to call tools. Record its turn (content is often
        # empty here, but some models emit a preamble alongside tool_calls —
        # keep it so the conversation stays coherent).
        messages.append({"role": "assistant", "content": content, "tool_calls": tool_calls})

        for call in tool_calls:
            fn = call.get("function") or {}
            name = fn.get("name", "")
            arguments = _parse_tool_arguments(fn.get("arguments"))
            if not name:
                messages.append({"role": "tool", "content": json.dumps({"error": "malformed tool call"})})
                continue

            query = arguments.get("query") if isinstance(arguments, dict) else None
            await manager.broadcast(json.dumps({
                "type": "ai_tool",
                "id": request_id,
                "tool": name,
                "status": "start",
                "label": tool_label(name),
                "query": query or None,
            }), room_id)

            result = await run_tool(name, arguments, {"room_id": room_id, "db": db})
            messages.append({"role": "tool", "content": result})

            # Brief "done" so the client can show ✓ / remove the status line.
            await manager.broadcast(json.dumps({
                "type": "ai_tool",
                "id": request_id,
                "tool": name,
                "status": "done",
                "label": tool_label(name),
                "query": query or None,
                "summary": _tool_summary(name, result),
            }), room_id)

    # Exhausted the iteration budget without a final answer.
    await _broadcast_ai_error(
        room_id, request_id,
        "The assistant couldn't finish the task. Please try again.",
    )
    return None


def _parse_tool_arguments(raw) -> dict:
    """Normalize Ollama's `arguments` field to a dict.

    Ollama serializes arguments as a JSON *string*; older/other backends may
    hand us an object already. Malformed strings become an empty dict (the
    tool handler then reports a clean error).
    """
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str) and raw.strip():
        try:
            parsed = json.loads(raw)
            return parsed if isinstance(parsed, dict) else {}
        except json.JSONDecodeError:
            return {}
    return {}


def _tool_summary(name: str, result: str) -> str:
    """Short human summary for the `ai_tool` done envelope."""
    count = tool_result_count(result)
    if count is not None:
        return f"found {count} result{'s' if count != 1 else ''}" if count else "no results"
    return "done"


# ---------- Legacy single-shot path (models without tool support) ----------

async def _run_legacy_stream(room_id: int, request_id: str, messages: list[dict]) -> str | None:
    """Legacy path: stream one Ollama reply, coalescing into ai_chunk frames.

    Returns the final content, or None if the stream produced nothing (an
    `ai_error` is broadcast in that case).
    """
    buffer = ""
    full = ""
    last_flush = asyncio.get_event_loop().time()
    async for chunk in _stream_ollama(messages):
        buffer += chunk
        full += chunk
        now = asyncio.get_event_loop().time()
        if len(buffer) >= 16 or (now - last_flush) >= 0.05:
            await manager.broadcast(json.dumps({
                "type": "ai_chunk",
                "id": request_id,
                "delta": buffer,
            }), room_id)
            buffer = ""
            last_flush = now

    # Flush any tail before signalling end.
    if buffer:
        await manager.broadcast(json.dumps({
            "type": "ai_chunk",
            "id": request_id,
            "delta": buffer,
        }), room_id)

    content = full.strip()
    if not content:
        await _broadcast_ai_error(
            room_id, request_id,
            "The assistant didn't return a reply. Please try again.",
        )
        return None
    return content


# ---------- Shared broadcast helpers ----------

async def _broadcast_chunks(room_id: int, request_id: str, content: str) -> None:
    """Replay a completed answer through the ai_chunk stream.

    The agent path computes the full answer in one (non-streaming) response,
    so there are no real tokens to stream — we replay the text in fixed-size
    frames to keep the client's typewriter effect identical to the legacy
    path. Frames are small enough to look incremental, big enough to finish
    quickly.
    """
    FRAME = 40  # chars per ai_chunk frame
    DELAY = 0.02  # seconds between frames
    for i in range(0, len(content), FRAME):
        await manager.broadcast(json.dumps({
            "type": "ai_chunk",
            "id": request_id,
            "delta": content[i:i + FRAME],
        }), room_id)
        await asyncio.sleep(DELAY)


async def _broadcast_ai_error(room_id: int, request_id: str, reason: str) -> None:
    """Broadcast an `ai_error` envelope, swallowing broadcast failures."""
    try:
        await manager.broadcast(json.dumps({
            "type": "ai_error",
            "id": request_id,
            "reason": reason,
        }), room_id)
    except Exception:
        pass