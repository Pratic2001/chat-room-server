from sqlalchemy.orm import Session
from sqlalchemy import and_
from sqlalchemy.exc import IntegrityError
from app import models, schemas
from app.utils import (
    encrypt_secret,
    decrypt_secret,
    constant_time_equal,
    get_password_hash,
    verify_password,
)
from datetime import datetime
import secrets


# Raised by `create_room` when the requested name collides with an
# existing room. The DB layer stays free of FastAPI imports; the router
# catches this and turns it into a 409 response.
class RoomNameConflict(Exception):
    """A room with the requested name already exists."""

    def __init__(self, name: str):
        self.name = name
        super().__init__(f"A room with the name {name!r} already exists")

# User CRUD
# Synthetic account used as the sender for AI-generated messages.
# Created lazily by `get_or_create_ai_user` on first AI use; never logged
# into via /auth/login (the random password is never revealed). Frontend
# keys AI messages off this username (see app/static/script.js and
# app/ai.py::contains_mention for the matching trigger regex).
AI_USERNAME = "assistant"
# Sentinel email so the row satisfies users.email UNIQUE NOT NULL. Stable
# across re-runs so a second call to get_or_create_ai_user does not try
# to create a duplicate. Cannot collide with a real signup because of the
# `.internal` TLD.
AI_USER_EMAIL = "assistant@chatroom.internal"

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

def get_or_create_ai_user(db: Session):
    """Return the AI assistant's User row, creating it on first call.

    Idempotent in normal use: a second call after creation returns the
    cached row. Race-safe: if two requests try to create the row at the
    same time, the `users.username` UNIQUE constraint catches the loser,
    which rolls back and re-reads.

    The hashed password is a random URL-safe token that nobody knows —
    login via /auth/login is intentionally broken for this account.
    """
    existing = db.query(models.User).filter(models.User.username == AI_USERNAME).first()
    if existing:
        return existing
    random_pw = secrets.token_urlsafe(48)  # ~64 chars, well under bcrypt's 72-byte limit
    ai_user = models.User(
        username=AI_USERNAME,
        email=AI_USER_EMAIL,
        hashed_password=get_password_hash(random_pw),
    )
    db.add(ai_user)
    try:
        db.commit()
    except IntegrityError:
        # Another request created the AI user between our read and write.
        # Roll back, re-read, return the winner's row.
        db.rollback()
        return db.query(models.User).filter(models.User.username == AI_USERNAME).first()
    db.refresh(ai_user)
    return ai_user

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
    # Empty / None phrase means the room has no pass phrase; we store NULL
    # so anyone who finds the room can join. Otherwise encrypt the phrase
    # so we can later include the exact text in an invitation email.
    phrase = (room.secret_phrase or "").strip()
    if phrase:
        secret_phrase_hash = encrypt_secret(phrase)
    else:
        secret_phrase_hash = None
    db_room = models.Room(
        name=room.name,
        secret_phrase_hash=secret_phrase_hash,
        owner_id=owner_id,
        # AI assistant config (validated upstream by RoomBase._persona_must_match).
        # ai_persona is ignored unless ai_enabled is True — normalize to NULL
        # so the column reflects the real intent rather than carrying a
        # misleading string on a disabled room.
        ai_enabled=bool(room.ai_enabled),
        ai_persona=room.ai_persona if room.ai_enabled else None,
    )
    db.add(db_room)
    try:
        db.commit()
    except IntegrityError:
        # `rooms.name` has a UNIQUE index. Race condition: two requests
        # pick the same name at the same time, or the user typed a name
        # that already exists. Either way the DB rejects the insert;
        # rollback so the session is reusable, then surface a clean
        # conflict so the router can return 409 instead of leaking a 500.
        db.rollback()
        raise RoomNameConflict(room.name)
    db.refresh(db_room)
    # Owner is automatically a member of the room they created
    db.add(models.RoomMember(room_id=db_room.id, user_id=owner_id))
    # If the room has AI enabled, add the assistant as a member too. This
    # keeps /rooms/my consistent (the AI shows up in member counts) and
    # means future features that key off RoomMember (e.g. notification
    # fan-out) include the AI without a separate code path.
    if db_room.ai_enabled:
        ai_user = get_or_create_ai_user(db)
        already = db.query(models.RoomMember).filter(
            and_(
                models.RoomMember.room_id == db_room.id,
                models.RoomMember.user_id == ai_user.id,
            )
        ).first()
        if not already:
            db.add(models.RoomMember(room_id=db_room.id, user_id=ai_user.id))
    db.commit()
    db.refresh(db_room)
    return db_room

def get_rooms_by_user(db: Session, user_id: int):
    return db.query(models.Room).join(models.RoomMember).filter(models.RoomMember.user_id == user_id).all()

def join_room(db: Session, room_id: int, user_id: int, secret_phrase: str | None):
    room = get_room_by_id(db, room_id)
    if not room:
        return False
    provided = (secret_phrase or "").strip()
    if room.secret_phrase_hash is None:
        # Room has no pass phrase. Accept empty input, reject a non-empty
        # one — supplying a phrase when none is required is almost always
        # a user error worth surfacing.
        if provided:
            return False
    else:
        # Room has a phrase. The provided value must match.
        if not provided:
            return False
        try:
            actual = decrypt_secret(room.secret_phrase_hash)
        except ValueError:
            return False
        if not constant_time_equal(provided, actual):
            return False
    # Ban check: refuse before touching the membership table. Returning
    # False here is ambiguous from the caller's perspective ("wrong
    # phrase" or "banned") — the router handles the disambiguation by
    # calling `is_user_banned` separately and returning a distinct
    # 403 with "You are banned from this room." when applicable.
    if is_user_banned(db, room_id, user_id):
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
                   data: bytes = None, thumbnail: bytes = None, file_name: str = None, mime_type: str = None,
                   caption: str | None = None, mentions: list[str] | None = None):
    db_message = models.Message(
        room_id=room_id,
        user_id=user_id,
        message_type=message.message_type,
        content=message.content,
        data=data,
        thumbnail=thumbnail,
        file_name=file_name,
        mime_type=mime_type,
        # `mentions` is a JSON column. Pass through whatever the
        # caller extracted (already filtered to room members on the
        # router side). None → NULL in MySQL.
        mentions=mentions if mentions else None,
        caption=caption,
    )
    db.add(db_message)
    db.commit()
    db.refresh(db_message)
    return db_message

def get_messages_by_room(db: Session, room_id: int, skip: int = 0, limit: int = 100):
    return db.query(models.Message).filter(models.Message.room_id == room_id).order_by(models.Message.created_at.desc()).offset(skip).limit(limit).all()


# ---------- Member / ban / delete helpers ----------

def list_room_members(db: Session, room_id: int):
    """Return (User, joined_at) tuples for every member of `room_id`,
    sorted by username (case-insensitive). Used by the members
    endpoint (mention autocomplete + moderation popover).
    """
    # Join users → room_members and project joined_at alongside the
    # user columns so the caller can render the row without a second
    # round-trip. `joined_at` is added as a column on the User row via
    # a label so callers can read `row.joined_at` uniformly.
    from sqlalchemy.orm import aliased
    rm = aliased(models.RoomMember)
    rows = (
        db.query(models.User, rm.joined_at.label("joined_at"))
        .join(rm, rm.user_id == models.User.id)
        .filter(rm.room_id == room_id)
        .order_by(models.User.username.asc())
        .all()
    )
    return rows


def is_user_banned(db: Session, room_id: int, user_id: int) -> bool:
    """True iff `user_id` is in the room_bans table for `room_id`.
    Used by the join flow (refuse rejoin) and by the moderation UI
    (don't show 'Ban' for an already-banned user)."""
    return (
        db.query(models.RoomBan)
        .filter(
            models.RoomBan.room_id == room_id,
            models.RoomBan.user_id == user_id,
        )
        .first()
        is not None
    )


def ban_user(db: Session, room_id: int, user_id: int, banned_by: int, reason: str | None = None) -> models.RoomBan:
    """Insert (or refresh) a ban row. Idempotent: if a row already
    exists for (room_id, user_id), update the reason and banned_by in
    place so re-banning with new context overwrites the old. Also
    removes any active membership so the banned user is gone from the
    room immediately, not just on next reconnect.
    """
    existing = (
        db.query(models.RoomBan)
        .filter(
            models.RoomBan.room_id == room_id,
            models.RoomBan.user_id == user_id,
        )
        .first()
    )
    if existing:
        existing.reason = reason
        existing.banned_by = banned_by
        # Bump banned_at so the UI's "banned since" display reflects
        # the most recent action, not the original ban.
        from datetime import datetime as _dt
        existing.banned_at = _dt.utcnow()
        # Drop the membership if present (ban == kick + block).
        db.query(models.RoomMember).filter(
            models.RoomMember.room_id == room_id,
            models.RoomMember.user_id == user_id,
        ).delete()
        db.commit()
        db.refresh(existing)
        return existing

    # Drop the membership if present before inserting the ban so the
    # ban row's UNIQUE(room_id, user_id) doesn't have to fight a
    # membership row for the user's "slot" in the room.
    db.query(models.RoomMember).filter(
        models.RoomMember.room_id == room_id,
        models.RoomMember.user_id == user_id,
    ).delete()
    ban = models.RoomBan(
        room_id=room_id,
        user_id=user_id,
        banned_by=banned_by,
        reason=reason,
    )
    db.add(ban)
    db.commit()
    db.refresh(ban)
    return ban


def unban_user(db: Session, room_id: int, user_id: int) -> bool:
    """Remove the ban row for (room_id, user_id). Returns True if a
    row was actually deleted, False if there was no ban to clear."""
    deleted = (
        db.query(models.RoomBan)
        .filter(
            models.RoomBan.room_id == room_id,
            models.RoomBan.user_id == user_id,
        )
        .delete()
    )
    db.commit()
    return deleted > 0


def list_room_bans(db: Session, room_id: int):
    """Return all ban rows for `room_id`, joined to User so the
    router can fill in `username` without a second round-trip."""
    return (
        db.query(models.RoomBan, models.User.username.label("username"))
        .join(models.User, models.User.id == models.RoomBan.user_id)
        .filter(models.RoomBan.room_id == room_id)
        .order_by(models.RoomBan.banned_at.desc())
        .all()
    )


def kick_member(db: Session, room_id: int, user_id: int) -> bool:
    """Remove the (room_id, user_id) membership row. Returns True if
    a row was actually deleted (i.e. the user was a member to begin
    with). Leaves any ban row alone — kick and ban are orthogonal;
    a kicked user can rejoin unless they're also banned.
    """
    deleted = (
        db.query(models.RoomMember)
        .filter(
            models.RoomMember.room_id == room_id,
            models.RoomMember.user_id == user_id,
        )
        .delete()
    )
    db.commit()
    return deleted > 0


def delete_room_cascade(db: Session, room_id: int) -> int:
    """Wipe a room and everything attached to it: messages first
    (FK), then memberships, then bans (the room_bans.room_id FK has
    ON DELETE CASCADE so the cascade actually fires from the DB
    side, but we delete here explicitly so the count returned to
    the caller is accurate and so the operation is symmetric with
    the in-memory cleanup the router does). Finally the room row
    itself. Returns the number of messages deleted (the most useful
    number to surface in a debug log).
    """
    msg_deleted = (
        db.query(models.Message)
        .filter(models.Message.room_id == room_id)
        .delete()
    )
    db.query(models.RoomMember).filter(
        models.RoomMember.room_id == room_id
    ).delete()
    db.query(models.RoomBan).filter(
        models.RoomBan.room_id == room_id
    ).delete()
    db.query(models.Room).filter(models.Room.id == room_id).delete()
    db.commit()
    return msg_deleted