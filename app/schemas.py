from pydantic import BaseModel, ConfigDict, EmailStr, Field
from typing import Optional, List
from datetime import datetime

# Per-class `model_config` so Pydantic actually picks it up at validator
# construction time. The earlier module-level assignment did nothing.

# User schemas
class UserBase(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    username: str
    email: EmailStr

class UserCreate(UserBase):
    password: str = Field(..., min_length=6)

class UserLogin(BaseModel):
    username: str
    password: str

class UserResponse(UserBase):
    id: int
    created_at: datetime

# Token schemas
class Token(BaseModel):
    access_token: str
    token_type: str

class AuthResponse(BaseModel):
    access_token: str
    token_type: str
    user_id: int
    username: str
    email: str

class TokenData(BaseModel):
    username: Optional[str] = None

# Room schemas
class RoomBase(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    name: str
    # Optional: leave empty / null for rooms anyone with the room name can join.
    secret_phrase: Optional[str] = None

class RoomCreate(RoomBase):
    pass

class RoomJoin(BaseModel):
    # Optional: must match the room's pass phrase if one is set; ignored if
    # the room has no pass phrase.
    secret_phrase: Optional[str] = None

class RoomJoinByName(BaseModel):
    # Used by the "Join room" flow in the sidebar. The user types the name
    # (and optional pass phrase) from the invite email; the server looks
    # the room up by name and adds the caller as a member.
    name: str = Field(..., min_length=1, max_length=255)
    # Optional: same rules as RoomJoin.secret_phrase above.
    secret_phrase: Optional[str] = None

class RoomInvite(BaseModel):
    email: EmailStr
    # Optional personal note from the inviter, included above the join
    # instructions in the email body.
    message: Optional[str] = Field(default=None, max_length=2000)

class RoomInviteResponse(BaseModel):
    sent: bool
    message: str

class RoomResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    name: str
    owner_id: int
    created_at: datetime

# Message schemas
class MessageBase(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    message_type: str
    content: Optional[str] = None
    file_name: Optional[str] = None
    mime_type: Optional[str] = None

class MessageCreate(MessageBase):
    pass

class MessageResponse(MessageBase):
    id: int
    room_id: int
    user_id: int
    username: Optional[str] = None
    created_at: datetime
    data: Optional[str] = None  # base64 encoded binary data
    thumbnail: Optional[str] = None  # base64 encoded thumbnail

# WebSocket message schemas (for sending/receiving over WS)
class WSMessage(BaseModel):
    # Message id (set by server when broadcasting, ignored when received).
    # The client uses this to dedupe the WS echo against the HTTP POST
    # response, which carries the same id.
    id: Optional[int] = None
    message_type: str
    content: Optional[str] = None
    file_name: Optional[str] = None
    mime_type: Optional[str] = None
    # For binary data, we will send base64 encoded string in the data field
    data: Optional[str] = None  # base64 encoded binary data
    thumbnail: Optional[str] = None  # base64 encoded thumbnail (for images)
    # Sender info (set by server when broadcasting, ignored when received)
    user_id: Optional[int] = None
    username: Optional[str] = None
    created_at: Optional[datetime] = None
