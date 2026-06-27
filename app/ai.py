"""AI assistant that replies when a user mentions @assistant in a text
message. Backed by Ollama (configurable via OLLAMA_HOST / OLLAMA_PORT /
OLLAMA_MODEL); can call DuckDuckGo for /search-triggered queries.

Key design decisions
---------------------
- Fire-and-forget: the routers call `asyncio.create_task(stream_reply(...))`
  and return immediately. The AI's HTTP call to Ollama runs on a background
  task and does NOT block the WebSocket receive loop.
- Streaming: `stream_reply` opens an `ndjson` stream to Ollama and emits
  `ai_start` / `ai_chunk` / `ai_end` envelopes over the WebSocket as
  tokens arrive, so the UI can render progressively. A final persisted
  `WSMessage` is broadcast at the end so non-streaming clients still see
  the bubble.
- Loop prevention: triggering_user_id is checked against the AI user's id
  at the top. AI messages are never reprocessed.
- Empty-reply filter: if Ollama returns an empty content string (or only
  whitespace), we skip the persist+broadcast step — no empty bubbles
  in the chat.
- Failure UX: when the stream errors before producing content we broadcast
  an `ai_error` envelope with a human-readable reason. The client renders
  a dedicated error bubble with a retry affordance.
- Context window: only the last 30 messages are sent to Ollama, ordered
  oldest → newest. Binary messages (image/file/video) are summarized as
  "[User X sent an image: filename.jpg]" rather than including the bytes.
- Mention regex: \\b@assistant\\b case-insensitive (Python's re.IGNORECASE).
- Room disable: rooms with ai_enabled=False skip the trigger entirely.
- Crash isolation: the entire body of `stream_reply` is wrapped in a
  try/except that logs and swallows. A failed AI reply must never take
  down the WS receive loop on any pod.
"""

import asyncio
import logging
import json
import re
from typing import Optional

import httpx

from app import crud, schemas
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


# ---------- Web search (optional) ----------

# /search at the start of a message (or after @assistant) triggers a
# DuckDuckGo search; the LLM gets the snippets as additional context.
# This is the v1 explicit-keyword path. Future work could add native
# tool calling; for now we keep the model-agnostic surface tiny.
# Same boundary gotcha as _MENTION_RE: `\b` doesn't behave intuitively
# around `/` (a non-word char). Use explicit lookbehind/lookahead so we
# only match `/search` as a whole token, not a substring of `my-url/search`.
_SEARCH_RE = re.compile(r"(?<![\w])/search(?![\w])", re.IGNORECASE)


def _maybe_run_search(query: str) -> str:
    """Run DuckDuckGo for `query` and return a short snippet block.
    Returns "" on any failure so the chat continues even if the search
    library isn't installed or the network is down.
    """
    # Lazy import so missing duckduckgo-search doesn't break the import
    # of this module (which would take down the whole app).
    try:
        from duckduckgo_search import DDGS
    except ImportError:
        log.warning("duckduckgo-search not installed; skipping /search.")
        return ""
    try:
        with DDGS() as ddgs:
            results = list(ddgs.text(query, max_results=5))
    except Exception as e:
        # DuckDuckGo occasionally rate-limits or returns unexpected HTML;
        # treat any exception as a no-result rather than failing the reply.
        log.warning("DuckDuckGo search failed: %s", e)
        return ""
    if not results:
        return ""
    parts = ["Search results for: " + query, ""]
    for r in results:
        title = r.get("title") or ""
        href = r.get("href") or r.get("url") or ""
        body = r.get("body") or r.get("snippet") or ""
        parts.append(f"- {title} ({href})")
        if body:
            parts.append(f"  {body}")
    return "\n".join(parts)


# ---------- Ollama call ----------

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


async def _call_ollama(messages: list[dict], timeout_s: float = 60.0) -> str:
    """POST a chat request to Ollama and return the assistant content.

    Returns "" on any error (timeout, non-2xx, malformed JSON, empty
    content) so the caller can treat it as "no reply".

    Retained as the non-streaming fallback used by callers that need
    a single-shot reply (none today; left in place for tests and any
    future caller that wants a simple synchronous response).
    """
    url = f"{_ollama_url()}/api/chat"
    payload = {
        "model": OLLAMA_MODEL or "llama3.2",
        "messages": messages,
        "stream": False,
    }
    try:
        async with httpx.AsyncClient(timeout=timeout_s) as client:
            r = await client.post(url, json=payload)
    except Exception as e:
        log.warning("Ollama POST failed: %s", e)
        return ""
    if r.status_code != 200:
        log.warning("Ollama returned HTTP %s: %s", r.status_code, r.text[:200])
        return ""
    try:
        body = r.json()
        content = (body.get("message") or {}).get("content") or ""
    except Exception as e:
        log.warning("Ollama response JSON parse failed: %s", e)
        return ""
    return content.strip()


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
    """Read the last CONTEXT_WINDOW messages for `room_id` and turn
    them into an Ollama-compatible chat history.

    Binary messages (image/file/video) become a single-line note so the
    model knows a non-text happened without receiving bytes it can't
    render. Text messages keep their content.
    """
    # crud.get_messages_by_room orders DESC by created_at and applies
    # limit/offset; we reverse for chronological (oldest → newest).
    msgs = crud.get_messages_by_room(db, room_id=room_id, limit=CONTEXT_WINDOW)
    msgs = list(reversed(msgs))
    history: list[dict] = []
    for m in msgs:
        username = m.user.username if m.user else "unknown"
        if m.message_type == "text":
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
    """Background task: stream an Ollama reply and broadcast progress.

    Broadcasts the following envelopes to the room over the WebSocket:

    - `{"type": "ai_start", "id": request_id, "user_id": ai_user_id,
        "username": "assistant"}` once the room/persona check passes.
    - `{"type": "ai_chunk", "id": request_id, "delta": "tok"}` per
        coalesced chunk (≤16 chars or ≤50ms, whichever first).
    - `{"type": "ai_end", "id": request_id, "content": "..."}` when
        the stream finishes successfully, just before the persisted
        chat message is broadcast.
    - `{"type": "ai_error", "id": request_id, "reason": "..."}` if
        the stream fails or produces empty content.

    After `ai_end` (only on success), the same MessageCreate +
    broadcast path used by user messages persists the AI's reply
    and emits a regular WSMessage envelope so non-streaming clients
    (or clients that connected mid-stream) still see the bubble.

    Designed to be called via `asyncio.create_task` from the routers.
    Opens its own DB session so it outlives the request's session.
    Catches and logs every exception so the background task never
    crashes the event loop silently.
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
            cleaned = _MENTION_RE.sub("", triggering_text).strip()

            # Optional /search: if the cleaned text contains /search,
            # run DuckDuckGo once and prepend the snippets to the LLM
            # context as a system message.
            search_block = ""
            if _SEARCH_RE.search(cleaned):
                query = _SEARCH_RE.sub("", cleaned).strip()
                if query:
                    search_block = _maybe_run_search(query)

            history = _build_history(db, room_id)

            messages: list[dict] = [
                {"role": "system", "content": _system_prompt_for(room.ai_persona)},
            ]
            if search_block:
                messages.append({"role": "system", "content": search_block})
            messages.extend(history)
            # Final user-turn (without the @assistant prefix) so the
            # model has the explicit ask. If /search stripped the whole
            # message, fall back to the original text minus the keyword.
            final_user = cleaned or _SEARCH_RE.sub("", triggering_text).strip()
            if final_user:
                messages.append({"role": "user", "content": final_user})

            # Announce the bubble opening BEFORE we start consuming
            # the stream so the client can render a placeholder
            # immediately. Without this, the user would see nothing
            # until the first chunk arrived (~hundreds of ms).
            await manager.broadcast(json.dumps({
                "type": "ai_start",
                "id": request_id,
                "user_id": ai_user_id,
                "username": AI_USERNAME,
            }), room_id)

            # Coalesce Ollama's natural cadence (dozens of tokens/sec)
            # into ~50ms / 16-char windows so we don't flood the WS
            # with one frame per token. Anything below either threshold
            # buffers; once we cross either, flush and reset.
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
                # Empty / failed reply: tell the client the stream is
                # done but flag it as an error so the placeholder is
                # replaced with the error bubble (not left empty).
                await manager.broadcast(json.dumps({
                    "type": "ai_error",
                    "id": request_id,
                    "reason": "The assistant didn't return a reply. Please try again.",
                }), room_id)
                return

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
