"""Per-pod WebSocket connection registry.

Each pod keeps its own `room_id -> [WebSocket]` list: only the WS
connections that landed on *this* pod are tracked here. To broadcast a
message to every connected client across the cluster, the routers call
`manager.broadcast(...)`, which in turn publishes to the Redis
pub/sub bus (`app/redis_bus.py`). Every pod's subscriber task pulls
the message off the bus and calls `local_dispatch(...)`, which is what
actually iterates the local sockets and writes the payload.

Why the indirection
-------------------
If `broadcast` iterated local sockets directly, a message broadcast
from pod A would only reach the WS connections that landed on pod A.
Connections on every other pod would silently miss the message and
the user would have to refresh. The bus is what makes fan-out
cross-pod: every pod's local sockets receive every published message
because the subscriber on each pod calls `local_dispatch` for every
message it sees.

Single-pod fallback
-------------------
When `REDIS_URL` is unset the bus runs in degraded mode and
`broadcast` invokes `local_dispatch` directly. That's the same code
path as before this module existed — local dev (uvicorn) keeps working
without Redis.
"""

from fastapi import WebSocket

from app import redis_bus


class ConnectionManager:
    def __init__(self):
        # room_id -> list of websockets. Per-pod only.
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
            # Drop empty lists so the dict doesn't grow without bound
            # when rooms are abandoned.
            if not self.active_connections[room_id]:
                del self.active_connections[room_id]

    async def broadcast(self, message: str, room_id: int):
        # Hand off to the bus. The bus is responsible for getting the
        # payload to every pod; this pod's local fan-out will happen
        # via `local_dispatch` once the subscriber task receives it.
        await redis_bus.publish(room_id, message)

    async def local_dispatch(self, room_id: int, message: str) -> None:
        """Fan a payload out to this pod's locally-tracked sockets.

        Called by the bus subscriber task on every pod (including the
        publishing pod). Rooms with no local connections on this pod
        are a no-op.
        """
        sockets = self.active_connections.get(room_id)
        if not sockets:
            return
        # Snapshot the list — a failing `send_text` shouldn't be
        # skipped over because another socket disconnected mid-loop.
        for connection in list(sockets):
            try:
                await connection.send_text(message)
            except Exception:
                # A broken socket gets cleaned up by the WS endpoint's
                # disconnect path on its next event-loop turn; we just
                # don't want one bad socket to take down the whole
                # room's broadcast.
                pass


# Module-level singleton shared across routers. The routers import this
# name; the bus callback registered in `app/main.py`'s lifespan grabs
# the same instance to wire the local-dispatch hook.
manager = ConnectionManager()
