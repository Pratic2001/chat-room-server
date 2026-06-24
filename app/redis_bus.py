"""Redis pub/sub bus for cross-pod chat message broadcasts.

Why this exists
---------------
`app/ws_manager.py` keeps a per-pod `room_id -> [WebSocket]` registry.
On a single-pod setup that registry is global and `broadcast` reaches
every connected client. The k8s deployment scales `chatroom-app` to
one replica per cluster node (`scripts/deploy_k8s.sh`), so each pod
only sees the WS connections that landed on it. A broadcast from one
pod only reaches that pod's subscribers; everyone on the other pods
silently misses the message.

This module wires every pod to a shared Redis pub/sub channel. When a
pod wants to broadcast a message it calls `publish(...)`, which puts
the payload on the channel. Every pod (including the publishing pod)
has a long-lived subscriber task that pulls the payload off the
channel and asks the local manager to fan it out to its own WS
connections. The publisher never iterates sockets directly — that
work is owned by the subscriber so there's only one fan-out path and
no "skip self" logic to maintain.

Degraded mode
-------------
If `REDIS_URL` is unset (the default for `scripts/create_env.sh` /
local `uvicorn` dev), the bus stays inert: `publish` calls the local
dispatch callback synchronously and the subscriber task never starts.
That keeps the single-pod dev path identical to its previous behaviour
without requiring the developer to stand up Redis.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
from typing import Awaitable, Callable

log = logging.getLogger(__name__)


# Single channel for every room. Payloads carry the room_id, so the
# subscriber can look up the right local list. A channel-per-room
# scheme would let pods skip work for rooms they have no subscribers
# for, but it also needs bookkeeping for subscribe/unsubscribe — not
# worth the complexity for a chat app of this size.
CHANNEL = "chatroom:room_events"

# One module-level handle. `init_bus` fills it in; everyone else
# imports the name.
_local_dispatch: Callable[[int, str], Awaitable[None]] | None = None
_redis = None  # redis.asyncio.Redis instance, or None when degraded
_subscriber_task: asyncio.Task | None = None
_enabled: bool = False


def _url() -> str | None:
    """Read REDIS_URL from the environment. Empty string = disabled."""
    url = os.getenv("REDIS_URL")
    if url is None or url.strip() == "":
        return None
    return url.strip()


async def init_bus(local_dispatch: Callable[[int, str], Awaitable[None]]) -> None:
    """Wire the bus to a local-dispatch callback and start the subscriber.

    `local_dispatch(room_id, json_payload)` is called for every message
    the bus receives. The implementation in `ws_manager.py` walks its
    locally-tracked sockets for `room_id` and sends the payload down
    each one.
    """
    global _local_dispatch, _redis, _subscriber_task, _enabled

    _local_dispatch = local_dispatch
    url = _url()
    if url is None:
        log.warning(
            "REDIS_URL is not set; running in single-pod mode. "
            "Cross-pod WebSocket broadcasts will be lost on a multi-replica "
            "deployment. Set REDIS_URL (e.g. redis://chatroom-redis:6379/0) "
            "to enable fan-out."
        )
        _enabled = False
        return

    try:
        # Imported lazily so the dependency is only required when the
        # bus is actually enabled. Keeps `import app.main` working in
        # environments without Redis installed locally.
        import redis.asyncio as aioredis  # type: ignore

        _redis = aioredis.from_url(url, encoding="utf-8", decode_responses=True)
        await _redis.ping()
        _enabled = True
        _subscriber_task = asyncio.create_task(_run_subscriber(), name="redis-bus-subscriber")
        log.info("Redis bus connected to %s; cross-pod broadcast enabled.", url)
    except Exception as e:
        # Don't crash the app if Redis is briefly unavailable at startup.
        # The next message will retry via the publisher; if Redis stays
        # down the symptom is "messages don't reach other pods", which
        # is the same failure mode a missing Redis would have.
        log.warning("Could not connect to Redis at %s: %s. Falling back to single-pod mode.", url, e)
        _enabled = False
        _redis = None


async def shutdown_bus() -> None:
    """Cancel the subscriber and close the Redis client. Idempotent."""
    global _redis, _subscriber_task, _enabled, _local_dispatch

    _enabled = False
    if _subscriber_task is not None:
        _subscriber_task.cancel()
        try:
            await _subscriber_task
        except (asyncio.CancelledError, Exception):
            pass
        _subscriber_task = None
    if _redis is not None:
        try:
            await _redis.aclose()
        except Exception:
            pass
        _redis = None
    _local_dispatch = None


def is_enabled() -> bool:
    return _enabled


async def publish(room_id: int, payload: str) -> None:
    """Broadcast `payload` (a JSON string) to every pod's local subscribers.

    In the degraded (no-Redis) mode this just calls the local dispatch
    callback directly so a single-pod setup behaves exactly as it did
    before this module existed.
    """
    if not _enabled:
        if _local_dispatch is not None:
            try:
                await _local_dispatch(room_id, payload)
            except Exception as e:
                log.warning("Local dispatch failed (degraded mode): %s", e)
        return

    assert _redis is not None
    try:
        # The envelope is small (room_id + JSON payload). Wrapping it in
        # a dict keeps the wire format self-describing if we ever need
        # to add fields (origin pod id, message kind, etc.).
        envelope = json.dumps({"room_id": room_id, "payload": payload})
        await _redis.publish(CHANNEL, envelope)
    except Exception as e:
        # A transient publish failure shouldn't break the user's
        # request. The message is already persisted to MySQL, so a
        # refresh will pick it up.
        log.warning("Redis publish failed for room %s: %s", room_id, e)


async def _run_subscriber() -> None:
    """Long-lived subscriber task. One per pod."""
    assert _redis is not None
    backoff = 1.0
    while True:
        try:
            pubsub = _redis.pubsub()
            await pubsub.subscribe(CHANNEL)
            log.info("Subscribed to %s", CHANNEL)
            backoff = 1.0  # reset on successful subscribe
            async for message in pubsub.listen():
                # message is one of {"type": "subscribe", ...} or
                # {"type": "message", "channel": ..., "data": <envelope>}.
                if message.get("type") != "message":
                    continue
                try:
                    envelope = json.loads(message["data"])
                    room_id = int(envelope["room_id"])
                    payload = envelope["payload"]
                except (ValueError, KeyError, TypeError, json.JSONDecodeError) as e:
                    log.warning("Discarding malformed bus envelope: %s", e)
                    continue
                if _local_dispatch is not None:
                    try:
                        await _local_dispatch(room_id, payload)
                    except Exception as e:
                        # A failing local socket shouldn't take down
                        # the subscriber for the whole room.
                        log.warning("Local dispatch failed for room %s: %s", room_id, e)
        except asyncio.CancelledError:
            # Normal shutdown.
            raise
        except Exception as e:
            # Connection lost — back off and try again. Cap at 30s so
            # a permanently-down Redis doesn't pin a tight loop.
            log.warning("Redis subscriber error: %s. Retrying in %.1fs.", e, backoff)
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 30.0)
