import base64
from typing import List

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from app import crud, models, schemas
from app.database import get_db
from app.routers.auth import get_current_user
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
    )


@router.get("/{room_id}/messages", response_model=List[schemas.MessageResponse])
def get_messages_for_room(
    room_id: int,
    skip: int = 0,
    limit: int = 100,
    db: Session = Depends(get_db),
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
        file_name=body.file_name,
        mime_type=body.mime_type,
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
        )
    await manager.broadcast(ws_msg.model_dump_json(), room_id)

    return schemas.MessageResponse(**payload)
