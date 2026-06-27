from fastapi import APIRouter, Depends, HTTPException, status, Response
from sqlalchemy.orm import Session
from app import crud, models, schemas
from app.utils import get_password_hash, decrypt_secret, send_invite_email
from app.database import get_db, get_read_db
from app.routers.auth import get_current_user
from app.ws_manager import manager
from typing import List
from html import escape

router = APIRouter()

AI_USERNAME = "assistant"  # mirrored from crud; used to recognize the AI member in popovers

def _is_ai_user(user: models.User) -> bool:
    return bool(user and user.username == AI_USERNAME)


@router.post("/", response_model=schemas.RoomResponse)
def create_room(room: schemas.RoomCreate, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)):
    try:
        return crud.create_room(db=db, room=room, owner_id=current_user.id)
    except crud.RoomNameConflict:
        # `rooms.name` is UNIQUE; on a duplicate insert the DB layer
        # raises `RoomNameConflict` after rolling back. Return 409 so
        # the frontend `_handleCreateRoom` can show the message in
        # `#create-room-error` (it pipes `detail` through
        # `extractErrorMessage` and renders the string).
        raise HTTPException(status_code=409, detail="A room with that name already exists")

@router.get("/my", response_model=List[schemas.RoomResponse])
def get_my_rooms(db: Session = Depends(get_read_db), current_user: models.User = Depends(get_current_user)):
    rooms = crud.get_rooms_by_user(db, user_id=current_user.id)
    return rooms

@router.post("/{room_id}/join", response_model=schemas.RoomResponse)
def join_room(
    room_id: int,
    body: schemas.RoomJoin,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
):
    # Check banned status first so the error message is unambiguous
    # even when the user would have failed the pass-phrase check too.
    # (Both checks returning False from crud.join_room would otherwise
    # collapse into one indistinguishable 400.)
    if crud.is_user_banned(db, room_id, current_user.id):
        raise HTTPException(status_code=403, detail="You are banned from this room")
    success = crud.join_room(
        db=db, room_id=room_id, user_id=current_user.id, secret_phrase=body.secret_phrase
    )
    if not success:
        raise HTTPException(status_code=400, detail="Invalid secret phrase or room not found")
    room = crud.get_room_by_id(db, room_id)
    return room

@router.post("/join-by-name", response_model=schemas.RoomResponse)
def join_room_by_name(
    body: schemas.RoomJoinByName,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
):
    """Look up a room by its (unique) name and add the caller as a member.

    This is the endpoint behind the "Join room" sidebar button — the user
    pastes the room name and (optional) pass phrase from an invitation
    email. We look the room up first so we can return a precise 404 when
    the name doesn't match, before doing the pass-phrase check.
    """
    room = crud.get_room_by_name(db, body.name.strip())
    if not room:
        raise HTTPException(status_code=404, detail="No room with that name")
    if crud.is_user_banned(db, room.id, current_user.id):
        raise HTTPException(status_code=403, detail="You are banned from this room")
    # Delegate to the same join logic used by /rooms/{id}/join so the
    # pass-phrase rules and idempotency are identical.
    success = crud.join_room(
        db=db, room_id=room.id, user_id=current_user.id, secret_phrase=body.secret_phrase
    )
    if not success:
        raise HTTPException(status_code=400, detail="Invalid secret phrase")
    return room


@router.get("/{room_id}/members", response_model=List[schemas.RoomMemberOut])
def list_members(
    room_id: int,
    db: Session = Depends(get_read_db),
    current_user: models.User = Depends(get_current_user),
):
    """Return the room's member list. Any current member may read it
    (the mention autocomplete and the moderation popover both need it).
    Members only — non-members get a 403 so the endpoint doesn't leak
    the membership roster of rooms the caller isn't in."""
    room = crud.get_room_by_id(db, room_id)
    if not room:
        raise HTTPException(status_code=404, detail="Room not found")
    caller_member = (
        db.query(models.RoomMember)
        .filter(
            models.RoomMember.room_id == room_id,
            models.RoomMember.user_id == current_user.id,
        )
        .first()
    )
    if not caller_member:
        raise HTTPException(status_code=403, detail="Not a member of this room")
    rows = crud.list_room_members(db, room_id)
    out: list[schemas.RoomMemberOut] = []
    for user, joined_at in rows:
        out.append(schemas.RoomMemberOut(
            user_id=user.id,
            username=user.username,
            joined_at=joined_at,
            is_owner=(user.id == room.owner_id),
            is_ai=_is_ai_user(user),
        ))
    return out


@router.delete("/{room_id}/members/{user_id}", status_code=status.HTTP_204_NO_CONTENT)
async def kick_member(
    room_id: int,
    user_id: int,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
):
    """Owner-only kick: removes the target's membership row. The
    target's WebSocket(s) for this room are closed so they stop
    receiving messages immediately. Kicked users can rejoin (unless
    they're also banned); ban is a separate verb."""
    room = crud.get_room_by_id(db, room_id)
    if not room:
        raise HTTPException(status_code=404, detail="Room not found")
    if room.owner_id != current_user.id:
        raise HTTPException(status_code=403, detail="Only the room owner can kick members")
    if user_id == room.owner_id:
        raise HTTPException(status_code=400, detail="Cannot kick the room owner")
    target = crud.get_user(db, user_id)
    if not target:
        raise HTTPException(status_code=404, detail="User not found")
    if _is_ai_user(target):
        raise HTTPException(status_code=400, detail="Cannot kick the AI assistant")
    # No-op (200/204) if the target wasn't a member — kicking a
    # non-member doesn't make sense but failing noisily here would
    # break the UI flow that re-fetches the list.
    crud.kick_member(db, room_id, user_id)
    # Close the target's WS so they stop receiving messages. Done
    # AFTER the DB delete so a fast reconnect won't see a "you're
    # not a member" close from the WS endpoint while the membership
    # is still being torn down.
    await manager.disconnect_user(user_id, room_id, code=1000)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/{room_id}/bans", response_model=schemas.BanOut, status_code=status.HTTP_201_CREATED)
async def ban_member(
    room_id: int,
    body: schemas.BanCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
):
    """Owner-only ban: removes the target's membership AND prevents
    rejoin until the ban is lifted. Idempotent — re-banning the
    same user with a new reason updates the reason in place."""
    room = crud.get_room_by_id(db, room_id)
    if not room:
        raise HTTPException(status_code=404, detail="Room not found")
    if room.owner_id != current_user.id:
        raise HTTPException(status_code=403, detail="Only the room owner can ban members")
    if body.user_id == room.owner_id:
        raise HTTPException(status_code=400, detail="Cannot ban the room owner")
    target = crud.get_user(db, body.user_id)
    if not target:
        raise HTTPException(status_code=404, detail="User not found")
    if _is_ai_user(target):
        raise HTTPException(status_code=400, detail="Cannot ban the AI assistant")
    ban = crud.ban_user(db, room_id, body.user_id, banned_by=current_user.id, reason=body.reason)
    # Close the target's WS so they stop receiving messages immediately.
    await manager.disconnect_user(body.user_id, room_id, code=1000)
    return schemas.BanOut(
        id=ban.id,
        room_id=ban.room_id,
        user_id=ban.user_id,
        username=target.username,
        banned_by=ban.banned_by,
        banned_at=ban.banned_at,
        reason=ban.reason,
    )


@router.delete("/{room_id}/bans/{user_id}", status_code=status.HTTP_204_NO_CONTENT)
def unban_member(
    room_id: int,
    user_id: int,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
):
    """Owner-only unban: removes the ban row so the user can rejoin."""
    room = crud.get_room_by_id(db, room_id)
    if not room:
        raise HTTPException(status_code=404, detail="Room not found")
    if room.owner_id != current_user.id:
        raise HTTPException(status_code=403, detail="Only the room owner can unban members")
    crud.unban_user(db, room_id, user_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/{room_id}/bans", response_model=List[schemas.BanOut])
def list_bans(
    room_id: int,
    db: Session = Depends(get_read_db),
    current_user: models.User = Depends(get_current_user),
):
    """Owner-only ban list."""
    room = crud.get_room_by_id(db, room_id)
    if not room:
        raise HTTPException(status_code=404, detail="Room not found")
    if room.owner_id != current_user.id:
        raise HTTPException(status_code=403, detail="Only the room owner can view the ban list")
    rows = crud.list_room_bans(db, room_id)
    return [
        schemas.BanOut(
            id=ban.id,
            room_id=ban.room_id,
            user_id=ban.user_id,
            username=username,
            banned_by=ban.banned_by,
            banned_at=ban.banned_at,
            reason=ban.reason,
        )
        for ban, username in rows
    ]


@router.delete("/{room_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_room(
    room_id: int,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
):
    """Real delete: removes the room and all of its data. Closes the
    WebSocket of every currently-connected member first so no client
    is still subscribed to a room that's about to disappear, then
    wipes messages / memberships / bans / room row in one DB call.

    The previous behavior was "remove the owner's membership" so
    other members could keep their access; that conflicted with
    `rooms.name UNIQUE` and made room-name reuse impossible."""
    room = crud.get_room_by_id(db, room_id)
    if not room:
        raise HTTPException(status_code=404, detail="Room not found")
    if room.owner_id != current_user.id:
        raise HTTPException(status_code=403, detail="Only the room owner can delete it")

    # Close every connected socket in the room across all users,
    # BEFORE the DB delete. We don't need a per-user loop here —
    # the room is going away, so the per-user distinction doesn't
    # matter; we just want nobody listening anymore.
    sockets = manager.active_connections.get(room_id, [])
    for ws in list(sockets):
        try:
            await ws.close(code=1000)
        except Exception:
            pass
    manager.active_connections.pop(room_id, None)

    crud.delete_room_cascade(db, room_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


def _build_invite_email(room: models.Room, inviter: models.User, message: str | None) -> tuple[str, str, str]:
    """Return (subject, html_body, text_body) for the invitation email."""
    safe_room = escape(room.name)
    safe_user = escape(inviter.username)
    has_phrase = bool(room.secret_phrase_hash)
    phrase_text = ""
    if has_phrase:
        try:
            phrase_text = escape(decrypt_secret(room.secret_phrase_hash))
        except ValueError:
            # Encryption key changed / corrupted — surface a generic note
            # rather than failing the whole invite.
            phrase_text = "(could not retrieve — please ask <em>" + safe_user + "</em> for it)"

    subject = f"You're invited to \"{room.name}\" on Chat"
    note_html = ""
    note_text = ""
    if message:
        note_html = (
            f'<p style="margin:0 0 20px;padding:14px 16px;border-left:4px solid #4f6df5;'
            f'background:#eef1ff;border-radius:8px;color:#1f2330;font-size:15px;line-height:1.5;">'
            f'<em>{escape(message).replace(chr(10), "<br>")}</em></p>'
        )
        note_text = f'\nA note from {inviter.username}:\n  {message}\n'

    if has_phrase:
        phrase_html = (
            f'<div style="margin:24px 0;padding:18px 20px;border:1px dashed #4f6df5;'
            f'border-radius:10px;background:#fafbfc;">'
            f'<div style="font-size:12px;letter-spacing:0.08em;text-transform:uppercase;'
            f'color:#6b7280;margin-bottom:6px;">Pass phrase</div>'
            f'<div style="font-family:Menlo,Consolas,monospace;font-size:18px;'
            f'color:#1f2330;font-weight:600;word-break:break-all;">{phrase_text}</div>'
            f'</div>'
        )
        phrase_text_plain = f'\nPass phrase: {phrase_text}\n'
    else:
        phrase_html = (
            '<p style="margin:24px 0;padding:14px 16px;border-radius:10px;'
            'background:#e8f7ee;color:#1f7a44;font-size:15px;">'
            '<strong>No pass phrase required.</strong> Anyone with the room name can join.'
            '</p>'
        )
        phrase_text_plain = "\nNo pass phrase required — anyone with the room name can join.\n"

    html = f"""<!DOCTYPE html>
<html><body style="margin:0;padding:0;background:#f5f6f8;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color:#1f2330;">
  <div style="max-width:560px;margin:0 auto;padding:32px 20px;">
    <div style="background:#ffffff;border-radius:14px;padding:32px;box-shadow:0 4px 16px rgba(15,23,42,0.08);">
      <div style="font-size:28px;line-height:1.2;margin-bottom:6px;">🐾 You're invited to chat!</div>
      <p style="margin:0 0 18px;color:#6b7280;font-size:15px;"><strong>{safe_user}</strong> has invited you to join the room:</p>
      <div style="margin:18px 0 4px;padding:18px 20px;background:#eef1ff;border-radius:10px;">
        <div style="font-size:12px;letter-spacing:0.08em;text-transform:uppercase;color:#4f6df5;margin-bottom:4px;">Room</div>
        <div style="font-size:22px;font-weight:700;color:#1f2330;">{safe_room}</div>
      </div>
      {note_html}
      {phrase_html}
      <p style="margin:24px 0 8px;font-size:15px;line-height:1.55;color:#1f2330;">To join:</p>
      <ol style="margin:0 0 24px;padding-left:20px;font-size:15px;line-height:1.6;color:#1f2330;">
        <li>Sign in (or create an account) on Chat.</li>
        <li>Open the room <strong>{safe_room}</strong> and paste the pass phrase above.</li>
      </ol>
      <p style="margin:24px 0 0;font-size:13px;color:#6b7280;">Sent by {safe_user} via Chat. If you weren't expecting this email you can safely ignore it.</p>
    </div>
  </div>
</body></html>"""

    text = (
        f"You're invited to chat!\n"
        f"\n"
        f"{inviter.username} has invited you to join the room:\n"
        f"  {room.name}\n"
        f"{note_text}"
        f"{phrase_text_plain}"
        f"\n"
        f"To join:\n"
        f"  1. Sign in (or create an account) on Chat.\n"
        f"  2. Open the room \"{room.name}\" and enter the pass phrase above.\n"
        f"\n"
        f"Sent by {inviter.username} via Chat.\n"
    )
    return subject, html, text


@router.post("/{room_id}/invite", response_model=schemas.RoomInviteResponse)
def invite_to_room(
    room_id: int,
    body: schemas.RoomInvite,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
):
    """Email an invitation to the recipient. Caller must be a member."""
    room = crud.get_room_by_id(db, room_id)
    if not room:
        raise HTTPException(status_code=404, detail="Room not found")
    member = (
        db.query(models.RoomMember)
        .filter(
            models.RoomMember.room_id == room_id,
            models.RoomMember.user_id == current_user.id,
        )
        .first()
    )
    if not member:
        raise HTTPException(status_code=403, detail="You must be a member of this room to invite others")

    subject, html, text = _build_invite_email(room, current_user, body.message)
    try:
        send_invite_email(body.email, subject, html, text)
    except Exception as e:
        # Surface SMTP errors to the client so the UI can show a useful toast.
        # Don't echo the full stack to the user; keep the message short.
        msg = str(e) or e.__class__.__name__
        raise HTTPException(status_code=502, detail=f"Could not send invite email: {msg}")

    return schemas.RoomInviteResponse(
        sent=True,
        message=f"Invite sent to {body.email}.",
    )
