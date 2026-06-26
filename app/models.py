from sqlalchemy import Column, Integer, String, DateTime, ForeignKey, Text, LargeBinary, Enum, Boolean
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import relationship
from datetime import datetime

Base = declarative_base()

class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, index=True)
    username = Column(String, unique=True, index=True, nullable=False)
    email = Column(String, unique=True, index=True, nullable=False)
    hashed_password = Column(String, nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow)

    # Relationships
    rooms = relationship("RoomMember", back_populates="user")
    messages = relationship("Message", back_populates="user")

class Room(Base):
    __tablename__ = "rooms"

    id = Column(Integer, primary_key=True, index=True)
    # Room name is the user-facing identifier (used in invite emails, the
    # join-by-name flow, and the sidebar). Enforce uniqueness so lookups
    # by name are unambiguous.
    name = Column(String, nullable=False, unique=True, index=True)
    # Stores an encrypted (Fernet) token for the secret phrase, or NULL when
    # the room has no pass phrase and anyone with the room name may join.
    secret_phrase_hash = Column(String, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    owner_id = Column(Integer, ForeignKey("users.id"), nullable=False)

    # Per-room AI assistant config. Set at room creation; not editable later.
    # Existing rooms created before these columns existed have ai_enabled=NULL
    # which evaluates falsy in the trigger check, so they default to "AI off".
    ai_enabled = Column(Boolean, nullable=False, default=False)
    # Persona key (one of ALLOWED_PERSONAS in app/schemas.py). NULL when
    # ai_enabled is False. VARCHAR(32) is plenty — longest key is "Anime-girlfriend".
    ai_persona = Column(String(32), nullable=True)

    # Relationships
    owner = relationship("User", foreign_keys=[owner_id])
    members = relationship("RoomMember", back_populates="room")
    messages = relationship("Message", back_populates="room")

class RoomMember(Base):
    __tablename__ = "room_members"

    id = Column(Integer, primary_key=True, index=True)
    room_id = Column(Integer, ForeignKey("rooms.id"), nullable=False)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    joined_at = Column(DateTime, default=datetime.utcnow)

    # Relationships
    room = relationship("Room", back_populates="members")
    user = relationship("User", back_populates="rooms")

class Message(Base):
    __tablename__ = "messages"

    id = Column(Integer, primary_key=True, index=True)
    room_id = Column(Integer, ForeignKey("rooms.id"), nullable=False)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    message_type = Column(Enum('text', 'image', 'file', 'video', name='messagetype'), nullable=False)
    content = Column(Text)  # for text messages
    data = Column(LargeBinary)  # for binary data (image, file, video)
    thumbnail = Column(LargeBinary)  # for image thumbnail
    file_name = Column(String)
    mime_type = Column(String)
    created_at = Column(DateTime, default=datetime.utcnow)

    # Relationships
    room = relationship("Room", back_populates="messages")
    user = relationship("User", back_populates="messages")