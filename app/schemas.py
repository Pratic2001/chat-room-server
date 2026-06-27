from pydantic import BaseModel, ConfigDict, EmailStr, Field, field_validator
from typing import Optional, List, Literal
from datetime import datetime

# Per-class `model_config` so Pydantic actually picks it up at validator
# construction time. The earlier module-level assignment did nothing.

# AI assistant persona values. These are the canonical keys used in the
# database, the API, and the Ollama system prompt lookup (app/ai.py).
# The frontend <select> uses friendly labels ("Peter Griffin") with these
# hyphenated strings as the option `value`.
ALLOWED_PERSONAS = (
    "Professional",
    "Funny",
    "Chaotic",
    "Sarcastic",
    "Anime-girlfriend",
    "Peter-Griffin",
    "Stewie-Griffin",
)
AIPersona = Literal[
    "Professional", "Funny", "Chaotic", "Sarcastic",
    "Anime-girlfriend", "Peter-Griffin", "Stewie-Griffin",
]

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
    # AI assistant config (set at creation; not editable later). ai_enabled
    # defaults False so existing callers and the smoke test keep working.
    ai_enabled: bool = False
    ai_persona: Optional[AIPersona] = None

    @field_validator("ai_persona")
    @classmethod
    def _persona_must_match(cls, v, info):
        # info.data is a dict of previously-validated fields on the same
        # model instance. The Literal type already enforces "one of the
        # allowed values" — this validator additionally enforces "required
        # when ai_enabled=True" and raises a clearer error than Pydantic's
        # default "Input should be ..." message when both fields conflict.
        ai_enabled = info.data.get("ai_enabled", False)
        if ai_enabled and v is None:
            raise ValueError("ai_persona is required when ai_enabled is True")
        if v is not None and v not in ALLOWED_PERSONAS:
            raise ValueError(f"ai_persona must be one of {list(ALLOWED_PERSONAS)}")
        return v

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
    # Echo AI config back to the client so the UI can label AI-enabled
    # rooms in the sidebar. The trigger flow itself only reads these from
    # the server-side ORM, but echoing them avoids a second round-trip.
    ai_enabled: bool = False
    ai_persona: Optional[str] = None

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
    # Lowercase usernames mentioned in `content` that are actual room
    # members. Empty list (NOT null) when no mentions. The frontend
    # uses this to highlight mentions in the bubble.
    mentions: List[str] = []
    # Caption typed alongside a file/image/video. NULL on text-only
    # messages and on attachment messages sent without a caption.
    caption: Optional[str] = None

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
    # Echo of the server-extracted mentions list (lowercase usernames
    # that are actual room members). Empty list when no mentions.
    mentions: List[str] = []
    # Caption typed alongside a file/image/video attachment.
    caption: Optional[str] = None


# ---------- Room members / bans ----------

class RoomMemberOut(BaseModel):
    """Row in the members list. Used by the mention autocomplete and
    by the moderation popover. `is_owner` and `is_ai` are computed in
    the router (they're not ORM columns)."""
    model_config = ConfigDict(from_attributes=True)

    user_id: int
    username: str
    joined_at: datetime
    is_owner: bool
    is_ai: bool


class BanCreate(BaseModel):
    """Body for POST /rooms/{id}/bans. Reason is optional and capped
    so a malicious owner can't dump a wall of text into the DB."""
    user_id: int
    reason: Optional[str] = Field(default=None, max_length=500)


class BanOut(BaseModel):
    """Row in the ban list. `username` is joined in the router so the
    frontend can render the ban list without a second round-trip per
    row."""
    model_config = ConfigDict(from_attributes=True)

    id: int
    room_id: int
    user_id: int
    username: str
    banned_by: Optional[int] = None
    banned_at: datetime
    reason: Optional[str] = None
