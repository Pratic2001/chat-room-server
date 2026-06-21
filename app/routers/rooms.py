from fastapi import APIRouter, Depends, HTTPException, status
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
