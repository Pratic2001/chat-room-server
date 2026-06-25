"""Redis Streams bus for cross-pod chat message broadcasts.

Why this exists
---------------
`app/ws_manager.py` keeps a per-pod `room_id -> [WebSocket]` registry.
On a single-pod setup that registry is global and `broadcast` reaches
every connected client. The k8s deployment scales `chatroom-app` to
one replica per cluster node (`scripts/deploy_k8s.sh`), so each pod
only sees the WS connections that landed on it. A broadcast from one
pod only reaches that pod's subscribers; everyone on the other pods
silently misses the message.

This module wires every pod to a shared Redis Streams key on the chatroom
Redis cluster (managed by Sentinel). Each pod publishes every chat event
with `XADD` and runs a long-lived `XREADGROUP` consumer that pulls new
entries off the stream and asks the local manager to fan them out to
its WS connections. Per-consumer-group state lives in Redis, so a
Sentinel-managed failover preserves delivery: every published event
gets at-least-once delivery to every consumer group, even if the
master dies mid-broadcast.

Why Streams instead of pub/sub
------------------------------
Pub/sub works on a single Redis broker. The chatroom deployment now runs
multiple Redis pods (master + replicas, sentinel-managed) — but pub/sub
only fans out within the broker that received the publish. A publish
that lands on a replica is broadcast only to subscribers of that
replica's pub/sub channel; subscribers on the master never see it.
Streams with consumer groups fix this: `XADD` writes to the stream on
the master (via Sentinel), and every consumer group on every pod reads
from the same key. The Streams data is replicated master→replica by
Redis's standard replication, so consumers see a consistent view.

Degraded mode
-------------
If `REDIS_URL` is unset (the default for `scripts/create_env.sh` /
local `uvicorn` dev), the bus stays inert: `publish` calls the local
dispatch callback synchronously and the subscriber task never starts.
That keeps the single-pod dev path identical to its previous behaviour
without requiring the developer to stand up Redis.

Sentinel mode
-------------
If `REDIS_SENTINELS` is set (comma-separated host:port list), the bus
uses `redis.asyncio.sentinel.Sentinel` to discover the master. All
operations (XADD, XREADGROUP, XACK, XGROUP CREATE) flow through the
Sentinel client so they automatically target the current master. If
the master fails over, the Sentinel client reconnects on the next
call — at most a few seconds of failed publishes during the failover
window. The publish path logs warnings on failure rather than raising,
so a transient Redis blip never breaks a chat send.

The local-dev path (no `REDIS_URL`) is unaffected.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import socket
from typing import Awaitable, Callable

log = logging.getLogger(__name__)


# Single stream for every room. Payloads carry the room_id, so the
# subscriber can look up the right local list. A stream-per-room
# scheme would let pods skip work for rooms they have no subscribers
# for, but it also needs bookkeeping for XADD / XREADGROUP per room —
# not worth the complexity for a chat app of this size.
STREAM_KEY = "chatroom:room_events"

# One consumer group shared by every chatroom-app pod. Every pod joins
# the same group with a unique consumer-name (POD_NAME or hostname);
# the group as a whole gets every message at least once (XREADGROUP
# with `>` returns messages that no consumer in the group has acked
# yet, and once a message is acked, it's removed from the pending list
# for that group). Each pod sees each message exactly once because
# XREADGROUP delivers each pending entry to exactly one consumer in
# the group.
CONSUMER_GROUP = "chatroom-app"

# Module-level handles. init_bus fills these in; everyone else imports
# the names below.
_local_dispatch: Callable[[int, str], Awaitable[None]] | None = None
# `_client` is the redis.asyncio.Redis instance for direct connections
# (local dev), or the redis.asyncio.sentinel.Sentinel instance for
# Sentinel-managed deployments. The bus uses it to call XADD / XREADGROUP
# etc. transparently in both modes.
_client = None  # type: ignore[var-annotated]
# True when running against a Sentinel-managed cluster (vs. a single
# Redis instance via REDIS_URL).
_sentinel_mode: bool = False
# Master name for Sentinel — only meaningful when _sentinel_mode is True.
_master_name: str = "chatroom-redis"
_subscriber_task: asyncio.Task | None = None
_enabled: bool = False


def _url() -> str | None:
    """Read REDIS_URL from the environment. Empty string = disabled."""
    url = os.getenv("REDIS_URL")
    if url is None or url.strip() == "":
        return None
    return url.strip()


def _sentinels() -> list[tuple[str, int]] | None:
    """Read REDIS_SENTINELS (comma-separated host:port) from env.

    Returns None if unset (single-pod mode), or a list of (host, port)
    tuples suitable for `redis.asyncio.sentinel.Sentinel(sentinels=...)`.
    Empty values, missing ports, or malformed entries are silently
    skipped — the caller logs and falls back to degraded mode.
    """
    raw = os.getenv("REDIS_SENTINELS")
    if raw is None or raw.strip() == "":
        return None
    out: list[tuple[str, int]] = []
    for entry in raw.split(","):
        entry = entry.strip()
        if not entry:
            continue
        if ":" in entry:
            host, port_s = entry.rsplit(":", 1)
            try:
                port = int(port_s)
            except ValueError:
                log.warning("REDIS_SENTINELS entry %r has non-integer port; skipping.", entry)
                continue
        else:
            host, port = entry, 26379
        out.append((host.strip(), port))
    return out or None


def _consumer_name() -> str:
    """Identify this pod uniquely within the consumer group.

    Uses POD_NAME (downward API) or hostname as a fallback. The name
    just has to be unique per pod — when a pod restarts and rejoins
    the group with the same name, it inherits its own pending entries
    (Redis tracks pending entries by consumer name). This is what
    gives us at-least-once delivery: if a pod crashes mid-XREADGROUP,
    the next pod with the same name picks up the unacked entries on
    PEL recovery (see _run_subscriber below).
    """
    return os.getenv("POD_NAME") or socket.gethostname() or "unknown"


async def init_bus(local_dispatch: Callable[[int, str], Awaitable[None]]) -> None:
    """Wire the bus to a local-dispatch callback and start the subscriber.

    `local_dispatch(room_id, json_payload)` is called for every message
    the bus receives. The implementation in `ws_manager.py` walks its
    locally-tracked sockets for `room_id` and sends the payload down
    each one.
    """
    global _local_dispatch, _client, _sentinel_mode, _master_name
    global _subscriber_task, _enabled

    _local_dispatch = local_dispatch

    sentinels = _sentinels()
    url = _url()

    if sentinels is None and url is None:
        log.warning(
            "Neither REDIS_URL nor REDIS_SENTINELS is set; running in single-pod mode. "
            "Cross-pod WebSocket broadcasts will be lost on a multi-replica "
            "deployment. Set REDIS_URL (e.g. redis://chatroom-redis:6379/0) "
            "or REDIS_SENTINELS (e.g. chatroom-redis-sentinel:26379) "
            "to enable fan-out."
        )
        _enabled = False
        return

    # Imported lazily so the dependency is only required when the
    # bus is actually enabled. Keeps `import app.main` working in
    # environments without Redis installed locally.
    import redis.asyncio as aioredis  # type: ignore
    import redis.asyncio.sentinel as aisentinel  # type: ignore

    try:
        if sentinels is not None:
            _master_name = os.getenv("REDIS_MASTER_NAME", "chatroom-redis")
            _sentinel_mode = True
            _client = aisentinel.Sentinel(
                sentinels,
                socket_timeout=5,
                password=os.getenv("REDIS_PASSWORD") or None,
            )
            # Probe Sentinel by asking for the master's address. If
            # Sentinel is up but the master isn't yet elected, this
            # raises MasterNotFoundError; we treat that as a transient
            # failure and fall back to degraded mode.
            try:
                master_addr = await _client.discover_master(_master_name)
            except Exception as e:
                log.warning(
                    "Sentinels reachable but master %r not yet discovered: %s. "
                    "Falling back to degraded mode (no fan-out until Sentinel converges).",
                    _master_name, e,
                )
                _enabled = False
                _client = None
                return
            log.info(
                "Sentinel discovered master %r at %s:%d",
                _master_name, master_addr[0], master_addr[1],
            )
        else:
            _sentinel_mode = False
            _client = aioredis.from_url(url, encoding="utf-8", decode_responses=True)
            await _client.ping()

        # Ensure the consumer group exists. MKSTREAM creates the stream
        # if it doesn't exist yet (so the very first publish doesn't
        # fail with NOGROUP). BUSYGROUP means the group already exists
        # — race with another pod during a cold start; we ignore it.
        try:
            await _client.xgroup_create(
                name=STREAM_KEY,
                groupname=CONSUMER_GROUP,
                id="0",  # start from id 0 so a fresh group sees the backlog
                mkstream=True,
            )
        except Exception as e:
            if "BUSYGROUP" in str(e):
                pass  # already exists, fine
            else:
                raise

        _enabled = True
        _subscriber_task = asyncio.create_task(_run_subscriber(), name="redis-bus-subscriber")
        log.info("Redis bus connected (%s); cross-pod broadcast enabled.",
                 "Sentinel-managed" if _sentinel_mode else f"direct @ {url}")
    except Exception as e:
        # Don't crash the app if Redis is briefly unavailable at startup.
        # The next message will retry via the publisher; if Redis stays
        # down the symptom is "messages don't reach other pods", which
        # is the same failure mode a missing Redis would have.
        log.warning("Could not connect to Redis: %s. Falling back to single-pod mode.", e)
        _enabled = False
        _client = None
        _sentinel_mode = False


async def shutdown_bus() -> None:
    """Cancel the subscriber and close the Redis client. Idempotent."""
    global _client, _subscriber_task, _enabled, _local_dispatch, _sentinel_mode

    _enabled = False
    if _subscriber_task is not None:
        _subscriber_task.cancel()
        try:
            await _subscriber_task
        except (asyncio.CancelledError, Exception):
            pass
        _subscriber_task = None
    if _client is not None:
        try:
            if _sentinel_mode:
                await _client.close()
            else:
                await _client.aclose()
        except Exception:
            pass
        _client = None
    _sentinel_mode = False
    _local_dispatch = None


def is_enabled() -> bool:
    return _enabled


async def _publish_stream(room_id: int, payload: str) -> None:
    """XADD a message to the stream. Used by both Sentinel and direct modes."""
    assert _client is not None
    envelope = json.dumps({"room_id": room_id, "payload": payload})
    # XADD key * field value [field value ...]
    await _client.xadd(STREAM_KEY, {"data": envelope})


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

    assert _client is not None
    try:
        await _publish_stream(room_id, payload)
    except Exception as e:
        # A transient publish failure shouldn't break the user's
        # request. The message is already persisted to MySQL, so a
        # refresh will pick it up.
        log.warning("Redis XADD failed for room %s: %s", room_id, e)


async def _run_subscriber() -> None:
    """Long-lived subscriber task. One per pod.

    Uses XREADGROUP to pull entries from the shared stream. Each entry
    is dispatched to the local WS sockets and then XACK'd so it's
    removed from this consumer's pending list. If a message fails to
    dispatch (e.g. all local sockets are broken), we still XACK so the
    pending list doesn't grow without bound — the message is also in
    MySQL via the REST/WS upload path, so a refresh recovers it.
    """
    assert _client is not None
    consumer = _consumer_name()
    backoff = 1.0
    while True:
        try:
            # XREADGROUP GROUP <group> <consumer> COUNT N BLOCK 5000 STREAMS <key> >
            # `>` means "messages not yet delivered to any consumer in
            # this group". BLOCK 5000 returns after 5s of inactivity so
            # the loop can be cancelled promptly on shutdown.
            streams = await _client.xreadgroup(
                groupname=CONSUMER_GROUP,
                consumername=consumer,
                streams={STREAM_KEY: ">"},
                count=16,
                block=5000,
            )
            backoff = 1.0  # reset on successful read
            if not streams:
                continue
            # `streams` is a list of (key, [(id, {field: value}), ...])
            # tuples. We have one stream so unpack the first element.
            for _stream_key, entries in streams:
                for entry_id, fields in entries:
                    try:
                        envelope = json.loads(fields.get("data", "{}"))
                        room_id = int(envelope["room_id"])
                        payload = envelope["payload"]
                    except (ValueError, KeyError, TypeError, json.JSONDecodeError) as e:
                        log.warning("Discarding malformed bus envelope %s: %s", entry_id, e)
                        # Ack so we don't loop on a poison-pill message.
                        await _safe_xack(entry_id)
                        continue
                    if _local_dispatch is not None:
                        try:
                            await _local_dispatch(room_id, payload)
                        except Exception as e:
                            # A failing local socket shouldn't take down
                            # the subscriber for the whole room. We still
                            # ack the entry below; the message lives in
                            # MySQL so a refresh will re-fetch it.
                            log.warning("Local dispatch failed for room %s (entry %s): %s",
                                        room_id, entry_id, e)
                    await _safe_xack(entry_id)
        except asyncio.CancelledError:
            # Normal shutdown.
            raise
        except Exception as e:
            # Connection lost (Sentinel failover, network blip, etc.).
            # Back off and try again. Cap at 30s so a permanently-down
            # Redis doesn't pin a tight loop.
            log.warning("Redis subscriber error: %s. Retrying in %.1fs.", e, backoff)
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 30.0)


async def _safe_xack(entry_id: str) -> None:
    """Best-effort XACK. A failure here is logged but never raised."""
    assert _client is not None
    try:
        await _client.xack(STREAM_KEY, CONSUMER_GROUP, entry_id)
    except Exception as e:
        log.warning("Redis XACK failed for entry %s: %s", entry_id, e)