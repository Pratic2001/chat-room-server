from fastapi import APIRouter, WebSocket, WebSocketDisconnect, Depends, HTTPException, status
from sqlalchemy.orm import Session
from app import crud, models, schemas
from app.ai import stream_reply
from app.database import get_db
from app.mentions import contains_mention, extract_mentions
from app.thumbnails import make_thumbnail
from app.utils import SECRET_KEY, ALGORITHM
from app.ws_manager import manager
from jose import JWTError, jwt
import asyncio
import json
import base64
import uuid

# Allowed file types for upload
ALLOWED_IMAGE_TYPES = {'image/jpeg', 'image/png', 'image/gif', 'image/webp'}
ALLOWED_VIDEO_TYPES = {'video/mp4', 'video/webm', 'video/ogg'}
ALLOWED_FILE_TYPES = {'application/pdf', 'text/plain', 'application/zip'}

router = APIRouter()

async def get_current_user_ws(websocket: WebSocket, db: Session):
    """Authenticate user for WebSocket connection"""
    # Try to get token from query parameters
    token = websocket.query_params.get("token")
    if not token:
        # Try to get from headers
        auth_header = websocket.headers.get("Authorization")
        if auth_header and auth_header.startswith("Bearer "):
            token = auth_header[7:]
    if not token:
        await websocket.close(code=status.WS_1008_POLICY_VIOLATION)
        return None
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        username: str = payload.get("sub")
        if username is None:
            await websocket.close(code=status.WS_1008_POLICY_VIOLATION)
            return None
    except JWTError:
        await websocket.close(code=status.WS_1008_POLICY_VIOLATION)
        return None
    user = crud.get_user_by_username(db, username=username)
    if user is None:
        await websocket.close(code=status.WS_1008_POLICY_VIOLATION)
        return None
    return user

@router.websocket("/{room_id}")
async def websocket_endpoint(websocket: WebSocket, room_id: int, db: Session = Depends(get_db)):
    # Authenticate user
    user = await get_current_user_ws(websocket, db)
    if user is None:
        return

    # Check if user is a member of the room
    member = db.query(models.RoomMember).filter(
        models.RoomMember.room_id == room_id,
        models.RoomMember.user_id == user.id
    ).first()
    if not member:
        await websocket.close(code=status.WS_1008_POLICY_VIOLATION)
        return

    # Stash user.id on the scope so ws_manager.disconnect_user can find
    # the sockets owned by this user when they're kicked or banned.
    websocket.scope["user_id"] = user.id
    # Typing state: monotonic seq incremented every time this user
    # sends a `typing` envelope. The auto-expire task reads this when
    # it wakes up and bails if a newer typing has arrived — so we
    # never broadcast a stale stop_typing.
    websocket.scope["typing_seq"] = 0
    # Active auto-expire tasks for this connection; cancelled on disconnect.
    websocket.scope["typing_tasks"] = set()

    await manager.connect(websocket, room_id)
    try:
        # Send chat history (last 50 messages, newest first from DB)
        messages = crud.get_messages_by_room(db, room_id=room_id, limit=50)
        # Reverse to get chronological order (oldest first)
        messages.reverse()
        for msg in messages:
            # Convert to WSMessage format
            common = {
                "id": msg.id,
                "user_id": msg.user_id,
                "username": msg.user.username if msg.user else None,
                "created_at": msg.created_at,
            }
            # `mentions` is a JSON column → list or None. Normalize to
            # [] so the wire shape matches the HTTP path.
            mentions = msg.mentions if isinstance(msg.mentions, list) else []
            if msg.message_type == "text":
                ws_msg = schemas.WSMessage(
                    message_type=msg.message_type,
                    content=msg.content,
                    mentions=mentions,
                    **common,
                )
            else:
                ws_msg = schemas.WSMessage(
                    message_type=msg.message_type,
                    file_name=msg.file_name,
                    mime_type=msg.mime_type,
                    data=base64.b64encode(msg.data).decode('utf-8') if msg.data is not None else None,
                    thumbnail=base64.b64encode(msg.thumbnail).decode('utf-8') if msg.thumbnail is not None else None,
                    caption=msg.caption,
                    mentions=mentions,
                    **common,
                )
            await websocket.send_text(ws_msg.model_dump_json())

        while True:
            data = await websocket.receive_text()
            # Typing envelopes are not chat messages — they're ephemeral
            # presence hints. We accept them as a JSON object with a
            # `type` field, validate they don't carry chat content, and
            # broadcast them through the same bus as chat messages so
            # every pod's subscribers see them. No DB write, no Ollama
            # trigger. Using `manager.broadcast` means cross-pod fan-out
            # is automatic via the existing Redis Streams bus.
            try:
                raw_obj = json.loads(data)
            except json.JSONDecodeError:
                await websocket.send_text(json.dumps({"error": "Invalid JSON format"}))
                continue
            if isinstance(raw_obj, dict) and raw_obj.get("type") in ("typing", "stop_typing"):
                envelope = {
                    "type": raw_obj["type"],
                    "user_id": user.id,
                    "username": user.username,
                }
                await manager.broadcast(json.dumps(envelope), room_id)
                # On `typing`, schedule an auto-expire stop_typing in 6s
                # if no newer typing has arrived by then. Covers the
                # "user closed the tab mid-sentence" case without a
                # server-side presence table.
                if raw_obj["type"] == "typing":
                    websocket.scope["typing_seq"] += 1
                    seq = websocket.scope["typing_seq"]
                    task = asyncio.create_task(
                        _typing_ttl(room_id, user.id, user.username, seq, websocket)
                    )
                    websocket.scope["typing_tasks"].add(task)
                    task.add_done_callback(websocket.scope["typing_tasks"].discard)
                continue
            # Anything else must conform to the chat-message schema.
            try:
                msg = schemas.WSMessage.model_validate_json(data)
            except Exception:
                await websocket.send_text(json.dumps({"error": "Invalid message format"}))
                continue

            # Save message to DB
            db_msg = None
            extracted_mentions: list[str] = []
            if msg.message_type == "text":
                # Intersect @-mentions in the content with the room's
                # actual members so we don't persist (or highlight)
                # mentions of users not in the room.
                # `list_room_members` returns (User, joined_at) tuples
                # so the members endpoint can render joined_at without
                # a second round-trip — unpack accordingly.
                member_usernames = [
                    user.username for user, _joined_at in crud.list_room_members(db, room_id)
                ]
                extracted_mentions = extract_mentions(msg.content or "", member_usernames)
                db_msg = crud.create_message(
                    db=db,
                    message=schemas.MessageCreate(message_type="text", content=msg.content),
                    room_id=room_id,
                    user_id=user.id,
                    mentions=extracted_mentions,
                )
            else:
                # For binary messages, we expect data to be base64 encoded
                if msg.data is None:
                    await websocket.send_text(json.dumps({"error": "Binary data is required for non-text messages"}))
                    continue

                # File size limit (10MB)
                MAX_FILE_SIZE = 10 * 1024 * 1024  # 10MB
                try:
                    binary_data = base64.b64decode(msg.data)
                    if len(binary_data) > MAX_FILE_SIZE:
                        await websocket.send_text(json.dumps({"error": "File too large (max 10MB)"}))
                        continue
                except Exception as e:
                    await websocket.send_text(json.dumps({"error": "Invalid base64 data"}))
                    continue

                # File type validation
                if msg.mime_type:
                    if msg.message_type == "image" and msg.mime_type not in ALLOWED_IMAGE_TYPES:
                        await websocket.send_text(json.dumps({"error": "Invalid image file type"}))
                        continue
                    elif msg.message_type == "video" and msg.mime_type not in ALLOWED_VIDEO_TYPES:
                        await websocket.send_text(json.dumps({"error": "Invalid video file type"}))
                        continue
                    elif msg.message_type == "file" and msg.mime_type not in ALLOWED_FILE_TYPES:
                        await websocket.send_text(json.dumps({"error": "Invalid file type"}))
                        continue

                thumbnail_data = None
                if msg.message_type == "image":
                    # Delegate to the shared helper so the REST upload
                    # path produces identical records.
                    thumbnail_data = make_thumbnail(binary_data)
                    if thumbnail_data is None:
                        await websocket.send_text(json.dumps({"error": "Invalid image data"}))
                        continue
                # For files and videos, we don't generate thumbnails

                db_msg = crud.create_message(
                    db=db,
                    message=schemas.MessageCreate(
                        message_type=msg.message_type,
                        file_name=msg.file_name,
                        mime_type=msg.mime_type
                    ),
                    room_id=room_id,
                    user_id=user.id,
                    data=binary_data,
                    thumbnail=thumbnail_data,
                    file_name=msg.file_name,
                    mime_type=msg.mime_type,
                    # Caption is a non-text-only field; the WS path
                    # mirrors the HTTP one. Empty caption → NULL.
                    caption=(msg.caption or "").strip() or None,
                )

            # Broadcast to all connections in the room
            if db_msg:
                common = {
                    "id": db_msg.id,
                    "user_id": db_msg.user_id,
                    "username": user.username,
                    "created_at": db_msg.created_at,
                }
                if db_msg.message_type == "text":
                    ws_msg = schemas.WSMessage(
                        message_type=db_msg.message_type,
                        content=db_msg.content,
                        mentions=extracted_mentions,
                        **common,
                    )
                else:
                    ws_msg = schemas.WSMessage(
                        message_type=db_msg.message_type,
                        file_name=db_msg.file_name,
                        mime_type=db_msg.mime_type,
                        data=base64.b64encode(db_msg.data).decode('utf-8') if db_msg.data is not None else None,
                        thumbnail=base64.b64encode(db_msg.thumbnail).decode('utf-8') if db_msg.thumbnail is not None else None,
                        caption=db_msg.caption,
                        mentions=extracted_mentions,
                        **common,
                    )
                await manager.broadcast(ws_msg.model_dump_json(), room_id)

                # Sending a message implicitly ends typing. Broadcast
                # a stop_typing for the sender so every other client
                # clears its indicator immediately rather than
                # waiting for the 6s server-side TTL. The sender's
                # own client ignores their own typing envelopes
                # (script.js::_handleTypingEnvelope drops anything
                # where env.user_id === this.user.id), so the echo
                # is harmless.
                await manager.broadcast(json.dumps({
                    "type": "stop_typing",
                    "user_id": user.id,
                    "username": user.username,
                }), room_id)

                # AI trigger: fire-and-forget. Runs in the background so
                # the WS receive loop is never blocked by Ollama latency.
                # The task opens its own DB session (see app/ai.py) so
                # the request-scoped session is not held open across the
                # HTTP call. Gated by ai_enabled so non-AI rooms skip the
                # cheap DB read; gated by username match so the AI never
                # replies to its own messages.
                if msg.message_type == "text" and contains_mention(msg.content or ""):
                    ai_room = crud.get_room_by_id(db, room_id)
                    if ai_room and ai_room.ai_enabled and user.username != crud.AI_USERNAME:
                        # Generate a request id locally so the streaming
                        # envelopes broadcast by stream_reply can be
                        # correlated to a placeholder bubble the client
                        # opens in response to the same id. A uuid4 is
                        # overkill but unambiguous across pods.
                        request_id = str(uuid.uuid4())
                        asyncio.create_task(stream_reply(
                            room_id=room_id,
                            triggering_user_id=user.id,
                            triggering_message_id=db_msg.id,
                            triggering_text=msg.content or "",
                            request_id=request_id,
                        ))

    except WebSocketDisconnect:
        manager.disconnect(websocket, room_id)
    except Exception as e:
        # In a production app, you might want to log this error
        print(f"WebSocket error: {e}")
        await websocket.close(code=status.WS_1011_INTERNAL_ERROR)
    finally:
        # Cancel any pending typing-TTL tasks for this connection so
        # we don't try to broadcast on a closed socket. Also broadcast
        # a final stop_typing so other clients see the indicator clear
        # the moment the user disconnects (the tab-close case) instead
        # of waiting up to 6s for the TTL to expire.
        tasks = websocket.scope.get("typing_tasks") or set()
        for t in tasks:
            t.cancel()
        user_id = websocket.scope.get("user_id")
        if user_id is not None:
            try:
                await manager.broadcast(json.dumps({
                    "type": "stop_typing",
                    "user_id": user_id,
                    "username": user.username,
                }), room_id)
            except Exception:
                # Best-effort — the broadcast path may already be torn
                # down if the manager itself raised during disconnect.
                pass
            # Broadcast a member_change "left" so the remaining
            # clients update their members list in real time. We
            # de-dupe against kick/ban: the moderation paths in
            # `app/routers/rooms.py` close the socket via
            # `manager.disconnect_user` AFTER removing the membership
            # row, so by the time this finally block runs the user
            # is no longer a member and we must NOT emit "left" —
            # the kick/ban broadcast has already done so with the
            # right change value. A "natural" leave (tab close,
            # network drop, explicit Leave) leaves the membership
            # row intact, so the check below distinguishes the two.
            try:
                still_member = db.query(models.RoomMember).filter(
                    models.RoomMember.room_id == room_id,
                    models.RoomMember.user_id == user_id,
                ).first() is not None
            except Exception:
                # DB session may already be closed on this request
                # path; skip the broadcast rather than risk a 500
                # swallowing the disconnect cleanup.
                still_member = False
            if still_member and user.username != crud.AI_USERNAME:
                try:
                    await manager.broadcast(json.dumps({
                        "type": "member_change",
                        "room_id": room_id,
                        "user_id": user_id,
                        "username": user.username,
                        "change": "left",
                    }), room_id)
                except Exception:
                    pass


async def _typing_ttl(room_id: int, user_id: int, username: str, seq: int, websocket: WebSocket):
    """Sleep `TYPING_TTL` seconds, then broadcast a stop_typing.

    Used to auto-clear a stale typing indicator when the user closed
    their tab mid-keystroke. Each `typing` envelope increments the
    connection's seq counter; if a newer typing has bumped it by the
    time this task wakes, the task exits silently — only the
    most-recent TTL ever fires its stop_typing broadcast.

    Cancellation-safe: if the socket disconnects, the surrounding
    `finally` block cancels us and we exit without broadcasting.
    """
    try:
        await asyncio.sleep(TYPING_TTL_S)
    except asyncio.CancelledError:
        return
    # Bail if a newer typing has bumped the seq.
    if websocket.scope.get("typing_seq") != seq:
        return
    try:
        await manager.broadcast(json.dumps({
            "type": "stop_typing",
            "user_id": user_id,
            "username": username,
        }), room_id)
    except Exception:
        # Manager may be torn down mid-flight; not our problem.
        pass


# Auto-expire window: how long after the last `typing` envelope we wait
# before broadcasting stop_typing on the user's behalf. Picked to be
# longer than the client's 2s throttle + the 5s client-side debounce,
# so the server-side TTL is the backstop, not the primary mechanism.
TYPING_TTL_S = 6.0