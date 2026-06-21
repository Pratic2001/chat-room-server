from sqlalchemy.orm import Session
from sqlalchemy import and_
from app import models, schemas
from app.utils import get_password_hash, verify_password
from datetime import datetime

# User CRUD
def get_user_by_username(db: Session, username: str):
    return db.query(models.User).filter(models.User.username == username).first()

def get_user_by_email(db: Session, email: str):
    return db.query(models.User).filter(models.User.email == email).first()

def get_user(db: Session, user_id: int):
    return db.query(models.User).filter(models.User.id == user_id).first()

def create_user(db: Session, user: schemas.UserCreate):
    hashed_password = get_password_hash(user.password)
    db_user = models.User(
        username=user.username,
        email=user.email,
        hashed_password=hashed_password
    )
    db.add(db_user)
    db.commit()
    db.refresh(db_user)
    return db_user

def authenticate_user(db: Session, username: str, password: str):
    user = get_user_by_username(db, username)
    if not user:
        return False
    if not verify_password(password, user.hashed_password):
        return False
    return user

# Room CRUD
def get_room_by_id(db: Session, room_id: int):
    return db.query(models.Room).filter(models.Room.id == room_id).first()

def get_room_by_name(db: Session, name: str):
    return db.query(models.Room).filter(models.Room.name == name).first()

def create_room(db: Session, room: schemas.RoomCreate, owner_id: int):
    secret_phrase_hash = get_password_hash(room.secret_phrase)
    db_room = models.Room(
        name=room.name,
        secret_phrase_hash=secret_phrase_hash,
        owner_id=owner_id
    )
    db.add(db_room)
    db.commit()
    db.refresh(db_room)
    # Owner is automatically a member of the room they created
    db.add(models.RoomMember(room_id=db_room.id, user_id=owner_id))
    db.commit()
    db.refresh(db_room)
    return db_room

def get_rooms_by_user(db: Session, user_id: int):
    return db.query(models.Room).join(models.RoomMember).filter(models.RoomMember.user_id == user_id).all()

def join_room(db: Session, room_id: int, user_id: int, secret_phrase: str):
    room = get_room_by_id(db, room_id)
    if not room:
        return False
    if not verify_password(secret_phrase, room.secret_phrase_hash):
        return False
    # Check if already a member
    existing = db.query(models.RoomMember).filter(
        and_(
            models.RoomMember.room_id == room_id,
            models.RoomMember.user_id == user_id
        )
    ).first()
    if existing:
        return True  # Already a member
    # Add as member
    member = models.RoomMember(room_id=room_id, user_id=user_id)
    db.add(member)
    db.commit()
    return True

def get_room_members(db: Session, room_id: int):
    return db.query(models.User).join(models.RoomMember).filter(models.RoomMember.room_id == room_id).all()

# Message CRUD
def create_message(db: Session, message: schemas.MessageCreate, room_id: int, user_id: int,
                   data: bytes = None, thumbnail: bytes = None, file_name: str = None, mime_type: str = None):
    db_message = models.Message(
        room_id=room_id,
        user_id=user_id,
        message_type=message.message_type,
        content=message.content,
        data=data,
        thumbnail=thumbnail,
        file_name=file_name,
        mime_type=mime_type
    )
    db.add(db_message)
    db.commit()
    db.refresh(db_message)
    return db_message

def get_messages_by_room(db: Session, room_id: int, skip: int = 0, limit: int = 100):
    return db.query(models.Message).filter(models.Message.room_id == room_id).order_by(models.Message.created_at.desc()).offset(skip).limit(limit).all()