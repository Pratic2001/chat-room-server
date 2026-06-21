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
    secret_phrase: str

class RoomCreate(RoomBase):
    pass

class RoomJoin(BaseModel):
    secret_phrase: str

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
    created_at: datetime
    data: Optional[str] = None  # base64 encoded binary data
    thumbnail: Optional[str] = None  # base64 encoded thumbnail

# WebSocket message schemas (for sending/receiving over WS)
class WSMessage(BaseModel):
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
