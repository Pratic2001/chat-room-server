from fastapi import APIRouter, WebSocket, WebSocketDisconnect, Depends, HTTPException, status
from sqlalchemy.orm import Session
from app import crud, models, schemas
from app.database import get_db
from app.utils import SECRET_KEY, ALGORITHM
from jose import JWTError, jwt
import json
from PIL import Image, UnidentifiedImageError
import io
import base64

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

class ConnectionManager:
    def __init__(self):
        # room_id -> list of websockets
        self.active_connections: dict[int, list[WebSocket]] = {}

    async def connect(self, websocket: WebSocket, room_id: int):
        await websocket.accept()
        if room_id not in self.active_connections:
            self.active_connections[room_id] = []
        self.active_connections[room_id].append(websocket)

    def disconnect(self, websocket: WebSocket, room_id: int):
        if room_id in self.active_connections:
            if websocket in self.active_connections[room_id]:
                self.active_connections[room_id].remove(websocket)

    async def broadcast(self, message: str, room_id: int):
        if room_id in self.active_connections:
            for connection in self.active_connections[room_id]:
                await connection.send_text(message)

manager = ConnectionManager()

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

    await manager.connect(websocket, room_id)
    try:
        # Send chat history (last 50 messages, newest first from DB)
        messages = crud.get_messages_by_room(db, room_id=room_id, limit=50)
        # Reverse to get chronological order (oldest first)
        messages.reverse()
        for msg in messages:
            # Convert to WSMessage format
            common = {
                "user_id": msg.user_id,
                "username": msg.user.username if msg.user else None,
                "created_at": msg.created_at,
            }
            if msg.message_type == "text":
                ws_msg = schemas.WSMessage(
                    message_type=msg.message_type,
                    content=msg.content,
                    **common,
                )
            else:
                ws_msg = schemas.WSMessage(
                    message_type=msg.message_type,
                    file_name=msg.file_name,
                    mime_type=msg.mime_type,
                    data=base64.b64encode(msg.data).decode('utf-8') if msg.data is not None else None,
                    thumbnail=base64.b64encode(msg.thumbnail).decode('utf-8') if msg.thumbnail is not None else None,
                    **common,
                )
            await websocket.send_text(ws_msg.model_dump_json())

        while True:
            data = await websocket.receive_text()
            try:
                msg = schemas.WSMessage.model_validate_json(data)
            except json.JSONDecodeError:
                await websocket.send_text(json.dumps({"error": "Invalid JSON format"}))
                continue
            except Exception:
                await websocket.send_text(json.dumps({"error": "Invalid message format"}))
                continue

            # Save message to DB
            db_msg = None
            if msg.message_type == "text":
                db_msg = crud.create_message(
                    db=db,
                    message=schemas.MessageCreate(message_type="text", content=msg.content),
                    room_id=room_id,
                    user_id=user.id
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
                try:
                    if msg.message_type == "image":
                        # Generate thumbnail for images
                        image = Image.open(io.BytesIO(binary_data))
                        image.thumbnail((200, 200))
                        thumb_io = io.BytesIO()
                        image.save(thumb_io, format=image.format if image.format else 'PNG')
                        thumbnail_data = thumb_io.getvalue()
                    # For files and videos, we don't generate thumbnails
                except UnidentifiedImageError:
                    await websocket.send_text(json.dumps({"error": "Invalid image data"}))
                    continue
                except Exception as e:
                    await websocket.send_text(json.dumps({"error": f"Failed to process image: {str(e)}"}))
                    continue

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
                    mime_type=msg.mime_type
                )

            # Broadcast to all connections in the room
            if db_msg:
                common = {
                    "user_id": db_msg.user_id,
                    "username": user.username,
                    "created_at": db_msg.created_at,
                }
                if db_msg.message_type == "text":
                    ws_msg = schemas.WSMessage(
                        message_type=db_msg.message_type,
                        content=db_msg.content,
                        **common,
                    )
                else:
                    ws_msg = schemas.WSMessage(
                        message_type=db_msg.message_type,
                        file_name=db_msg.file_name,
                        mime_type=db_msg.mime_type,
                        data=base64.b64encode(db_msg.data).decode('utf-8') if db_msg.data is not None else None,
                        thumbnail=base64.b64encode(db_msg.thumbnail).decode('utf-8') if db_msg.thumbnail is not None else None,
                        **common,
                    )
                await manager.broadcast(ws_msg.model_dump_json(), room_id)

    except WebSocketDisconnect:
        manager.disconnect(websocket, room_id)
    except Exception as e:
        # In a production app, you might want to log this error
        print(f"WebSocket error: {e}")
        await websocket.close(code=status.WS_1011_INTERNAL_ERROR)