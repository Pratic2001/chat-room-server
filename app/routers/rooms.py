from fastapi import APIRouter, Depends, HTTPException, status, Response
from sqlalchemy.orm import Session
from app import crud, models, schemas
from app.utils import get_password_hash
from app.database import get_db
from app.routers.auth import get_current_user
from typing import List

router = APIRouter()

@router.post("/", response_model=schemas.RoomResponse)
def create_room(room: schemas.RoomCreate, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)):
    return crud.create_room(db=db, room=room, owner_id=current_user.id)

@router.get("/my", response_model=List[schemas.RoomResponse])
def get_my_rooms(db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)):
    rooms = crud.get_rooms_by_user(db, user_id=current_user.id)
    return rooms

@router.post("/{room_id}/join", response_model=schemas.RoomResponse)
def join_room(
    room_id: int,
    body: schemas.RoomJoin,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
):
    success = crud.join_room(
        db=db, room_id=room_id, user_id=current_user.id, secret_phrase=body.secret_phrase
    )
    if not success:
        raise HTTPException(status_code=400, detail="Invalid secret phrase or room not found")
    room = crud.get_room_by_id(db, room_id)
    return room

@router.delete("/{room_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_room(
    room_id: int,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
):
    room = crud.get_room_by_id(db, room_id)
    if not room:
        raise HTTPException(status_code=404, detail="Room not found")
    if room.owner_id != current_user.id:
        raise HTTPException(status_code=403, detail="Only the room owner can delete it")
    # Per the chosen semantics, "delete" for the owner removes their
    # membership. The room row and other members are left intact so
    # other users can still see and use the room.
    db.query(models.RoomMember).filter(
        models.RoomMember.room_id == room_id,
        models.RoomMember.user_id == current_user.id,
    ).delete()
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
