import base64
from typing import List

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from app import crud, models, schemas
from app.database import get_db
from app.routers.auth import get_current_user

router = APIRouter()

ALLOWED_IMAGE_TYPES = {'image/jpeg', 'image/png', 'image/gif', 'image/webp'}
ALLOWED_VIDEO_TYPES = {'video/mp4', 'video/webm', 'video/ogg'}
ALLOWED_FILE_TYPES = {'application/pdf', 'text/plain', 'application/zip'}
MAX_FILE_SIZE = 10 * 1024 * 1024  # 10 MB


def _serialize(msg):
    """Convert a Message ORM instance into a MessageResponse with base64 data."""
    msg_dict = schemas.MessageResponse.model_validate(msg).model_dump()
    if msg.data:
        msg_dict["data"] = base64.b64encode(msg.data).decode("utf-8")
    if msg.thumbnail:
        msg_dict["thumbnail"] = base64.b64encode(msg.thumbnail).decode("utf-8")
    return schemas.MessageResponse(**msg_dict)


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
def create_message(
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
    return _serialize(db_msg)
