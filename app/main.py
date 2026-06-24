import sys
import os
import logging
from contextlib import asynccontextmanager

sys.path.append(os.path.join(os.path.dirname(__file__), ".."))

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import HTMLResponse

from app import redis_bus
from app.routers import auth, rooms, chats, messages
from app.ws_manager import manager

log = logging.getLogger("uvicorn.error")


@asynccontextmanager
async def lifespan(app: FastAPI):
    # The bus's local-dispatch callback is the manager's per-pod fan-out
    # helper. Wiring it here (instead of at import time) keeps `ws_manager`
    # importable from contexts where the bus hasn't been initialised
    # yet (e.g. some test setups).
    await redis_bus.init_bus(manager.local_dispatch)
    try:
        yield
    finally:
        await redis_bus.shutdown_bus()


app = FastAPI(title="Chat Room API", lifespan=lifespan)

# CORS middleware to allow frontend to connect
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # In production, replace with specific origin
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include routers
app.include_router(auth.router, prefix="/auth", tags=["auth"])
app.include_router(rooms.router, prefix="/rooms", tags=["rooms"])
app.include_router(chats.router, prefix="/ws", tags=["websocket"])
app.include_router(messages.router, prefix="/messages", tags=["messages"])

# Mount static files
static_dir = os.path.join(os.path.dirname(__file__), "static")
if os.path.exists(static_dir):
    app.mount("/static", StaticFiles(directory=static_dir), name="static")

@app.get("/", response_class=HTMLResponse)
def read_root():
    # Serve the frontend index.html (chat app)
    index_path = os.path.join(static_dir, "index.html")
    if os.path.exists(index_path):
        with open(index_path, "r") as f:
            content = f.read()
        return HTMLResponse(content=content)
    else:
        return {"message": "Welcome to the Chat Room API. Frontend not found."}

@app.get("/login", response_class=HTMLResponse)
def login_page():
    login_path = os.path.join(static_dir, "login.html")
    if os.path.exists(login_path):
        with open(login_path, "r") as f:
            content = f.read()
        return HTMLResponse(content=content)
    else:
        return {"message": "Login page not found."}

@app.get("/signup", response_class=HTMLResponse)
def signup_page():
    signup_path = os.path.join(static_dir, "signup.html")
    if os.path.exists(signup_path):
        with open(signup_path, "r") as f:
            content = f.read()
        return HTMLResponse(content=content)
    else:
        return {"message": "Signup page not found."}

@app.get("/healthz")
def healthz():
    # Cheap JSON ping used by k8s liveness/readiness/startup probes.
    # Deliberately does NOT touch the database — a transient DB blip
    # must not cause Kubernetes to kill the pod.
    return {"status": "ok"}

if __name__ == "__main__":
    uvicorn.run("app.main:app", host="0.0.0.0", port=8000, reload=True)
