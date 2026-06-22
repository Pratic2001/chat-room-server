"""Shared WebSocket connection manager.

Used by the WebSocket route (app/routers/chats.py) and the HTTP message
route (app/routers/messages.py) so both paths can broadcast to every
client currently connected to a room.
"""

from fastapi import WebSocket


class ConnectionManager:
    def __init__(self):
        # room_id -> list of websockets
        self.active_connections: dict[int, list[WebSocket]] = {}

    async def connect(self, websocket: WebSocket, room_id: int):
        await websocket.accept()
        if room_id not in self.active_connections:
            self.active_connections[room_id] = []
        self.active_connections[room_id].append(websocket)

    def disconnect(self, websocket: WebSocket, room_id: int):
        if room_id in self.active_connections:
            if websocket in self.active_connections[room_id]:
                self.active_connections[room_id].remove(websocket)

    async def broadcast(self, message: str, room_id: int):
        if room_id in self.active_connections:
            for connection in self.active_connections[room_id]:
                await connection.send_text(message)


# Module-level singleton shared across routers.
manager = ConnectionManager()
