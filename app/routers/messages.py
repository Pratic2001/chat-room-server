import base64
import asyncio
import json
import uuid
from typing import List

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from app import crud, models, schemas
from app.ai import stream_reply
from app.database import get_db, get_read_db
from app.mentions import contains_mention, extract_mentions
from app.routers.auth import get_current_user
from app.thumbnails import make_thumbnail
from app.ws_manager import manager

router = APIRouter()

ALLOWED_IMAGE_TYPES = {'image/jpeg', 'image/png', 'image/gif', 'image/webp'}
ALLOWED_VIDEO_TYPES = {'video/mp4', 'video/webm', 'video/ogg'}
ALLOWED_FILE_TYPES = {'application/pdf', 'text/plain', 'application/zip'}
MAX_FILE_SIZE = 10 * 1024 * 1024  # 10 MB


def _serialize(msg):
    """Convert a Message ORM instance into a MessageResponse with base64 data.

    We build the dict by hand rather than calling MessageResponse.model_validate
    on the ORM instance, because `Message.data` / `Message.thumbnail` are
    `LargeBinary` (bytes) columns while MessageResponse declares them as `str`.
    Pydantic v2 won't auto-coerce bytes to str and raises "Expected valid
    string, error parsing unicode" — which is exactly the error attachments
    hit on upload.
    """
    # `mentions` is a JSON column → SQLAlchemy gives us back a Python
    # list (or None). Normalize to [] so the response field is never
    # null and the frontend can index it without a guard.
    mentions = msg.mentions if isinstance(msg.mentions, list) else []
    return schemas.MessageResponse(
        id=msg.id,
        room_id=msg.room_id,
        user_id=msg.user_id,
        username=msg.user.username if msg.user else None,
        message_type=msg.message_type,
        content=msg.content,
        file_name=msg.file_name,
        mime_type=msg.mime_type,
        created_at=msg.created_at,
        data=base64.b64encode(msg.data).decode("utf-8") if msg.data else None,
        thumbnail=base64.b64encode(msg.thumbnail).decode("utf-8") if msg.thumbnail else None,
        mentions=mentions,
        caption=msg.caption,
    )


@router.get("/{room_id}/messages", response_model=List[schemas.MessageResponse])
def get_messages_for_room(
    room_id: int,
    skip: int = 0,
    limit: int = 100,
    db: Session = Depends(get_read_db),
    current_user: models.User = Depends(get_current_user),
):
    member = db.query(models.RoomMember).filter(
        models.RoomMember.room_id == room_id,
        models.RoomMember.user_id == current_user.id,
    ).first()
    if not member:
        raise HTTPException(status_code=403, detail="Not a member of this room")
    messages = crud.get_messages_by_room(db, room_id=room_id, skip=skip, limit=limit)
    return [_serialize(m) for m in messages]


@router.post("", response_model=schemas.MessageResponse)
async def create_message(
    room_id: int,
    body: schemas.WSMessage,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
):
    member = db.query(models.RoomMember).filter(
        models.RoomMember.room_id == room_id,
        models.RoomMember.user_id == current_user.id,
    ).first()
    if not member:
        raise HTTPException(status_code=403, detail="Not a member of this room")

    binary_data = None
    thumbnail_data = None
    if body.data:
        try:
            binary_data = base64.b64decode(body.data)
        except Exception:
            raise HTTPException(status_code=400, detail="Invalid base64 data")
        if len(binary_data) > MAX_FILE_SIZE:
            raise HTTPException(status_code=400, detail="File too large (max 10MB)")

    # Type allowlist for binary messages
    if body.message_type != "text":
        if binary_data is None:
            raise HTTPException(status_code=400, detail="Binary data is required for non-text messages")
        if body.mime_type:
            if body.message_type == "image" and body.mime_type not in ALLOWED_IMAGE_TYPES:
                raise HTTPException(status_code=400, detail="Invalid image file type")
            if body.message_type == "video" and body.mime_type not in ALLOWED_VIDEO_TYPES:
                raise HTTPException(status_code=400, detail="Invalid video file type")
            if body.message_type == "file" and body.mime_type not in ALLOWED_FILE_TYPES:
                raise HTTPException(status_code=400, detail="Invalid file type")

        # Generate a thumbnail for image uploads so receivers on any pod
        # see the same shape as a WS-originated image. The WS path in
        # `app/routers/chats.py` does the same; we keep the helper in
        # `app/thumbnails.py` so the two paths can't drift.
        if body.message_type == "image":
            thumb = make_thumbnail(binary_data)
            if thumb is None:
                raise HTTPException(status_code=400, detail="Invalid image data")
            thumbnail_data = thumb

    # Extract @mentions from text content. We intersect with the
    # room's actual member list so we don't persist (or highlight)
    # `@randomname` for someone not in the room. Read the list once
    # here; the WS path does the same and the membership list is
    # tiny in practice. `list_room_members` returns (User, joined_at)
    # tuples so the members endpoint can render joined_at without a
    # second round-trip — unpack accordingly.
    mentions: list[str] = []
    if body.message_type == "text" and body.content:
        member_usernames = [
            user.username for user, _joined_at in crud.list_room_members(db, room_id)
        ]
        mentions = extract_mentions(body.content, member_usernames)

    # Captions only apply to non-text messages. The composer stages a
    # file and the typed text together; if the text is empty, the
    # caption is empty (don't persist a "" caption — looks like
    # noise in the bubble).
    caption = (
        (body.caption or "").strip()
        if body.message_type != "text" and body.caption
        else None
    )

    db_msg = crud.create_message(
        db=db,
        message=schemas.MessageCreate(
            message_type=body.message_type,
            content=body.content,
            file_name=body.file_name,
            mime_type=body.mime_type,
        ),
        room_id=room_id,
        user_id=current_user.id,
        data=binary_data,
        thumbnail=thumbnail_data,
        file_name=body.file_name,
        mime_type=body.mime_type,
        caption=caption,
        mentions=mentions,
    )
    serialized = _serialize(db_msg)
    # Include the sender's username so the client can render the bubble
    # without an extra round-trip.
    payload = serialized.model_dump()
    payload["username"] = current_user.username

    # Build a WSMessage with the same shape we send over the WebSocket so the
    # client can render the HTTP response and the WS echo uniformly. Carry
    # the message id so the client can dedupe the echo against the HTTP
    # response it just rendered.
    if body.message_type == "text":
        ws_msg = schemas.WSMessage(
            id=db_msg.id,
            message_type=body.message_type,
            content=body.content,
            user_id=current_user.id,
            username=current_user.username,
            created_at=db_msg.created_at,
            mentions=mentions,
        )
    else:
        ws_msg = schemas.WSMessage(
            id=db_msg.id,
            message_type=body.message_type,
            file_name=body.file_name,
            mime_type=body.mime_type,
            data=payload.get("data"),
            thumbnail=payload.get("thumbnail"),
            user_id=current_user.id,
            username=current_user.username,
            created_at=db_msg.created_at,
            mentions=mentions,
            caption=caption,
        )
    await manager.broadcast(ws_msg.model_dump_json(), room_id)

    # AI trigger: fire-and-forget. Runs in the background so the HTTP
    # response is not delayed by Ollama latency. The task opens its own
    # DB session (see app/ai.py) so the request-scoped session is not
    # held open across the HTTP call. Streams via the same envelope
    # protocol the WebSocket path uses, so the user sees a typing
    # indicator + progressive bubble even when sending via REST.
    if body.message_type == "text" and contains_mention(body.content or ""):
        ai_room = crud.get_room_by_id(db, room_id)
        if ai_room and ai_room.ai_enabled and current_user.username != crud.AI_USERNAME:
            request_id = str(uuid.uuid4())
            asyncio.create_task(stream_reply(
                room_id=room_id,
                triggering_user_id=current_user.id,
                triggering_message_id=db_msg.id,
                triggering_text=body.content or "",
                request_id=request_id,
            ))

    return schemas.MessageResponse(**payload)
