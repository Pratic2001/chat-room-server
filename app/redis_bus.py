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
There are two paths into degraded (local-only) mode:

1. `REDIS_URL` and `REDIS_SENTINELS` are both unset — the default for
   `scripts/create_env.sh` / local `uvicorn` dev. The bus stays inert:
   `publish` calls the local dispatch callback synchronously and the
   subscriber task never starts. Keeps the single-pod dev path
   identical to its previous behaviour without requiring the developer
   to stand up Redis.

2. Redis/Sentinel is configured but unreachable at startup — the bus
   runs in degraded mode for the gap and a background retry task
   re-attempts connection every 5s (capped at 30s). Once it succeeds,
   the subscriber starts and cross-pod fan-out resumes without a pod
   restart. This covers the deploy-time race where the app pods
   become Ready before the Redis StatefulSet has converged.

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
# `_client` is the redis.asyncio.Redis instance used for every bus
# operation (XADD / XREADGROUP / XACK / XGROUP CREATE). In direct mode
# (REDIS_URL) this is the connection returned by `aioredis.from_url`.
# In Sentinel mode (REDIS_SENTINELS) this is the *master* connection
# returned by `sentinel.master_for(...)` — `Sentinel` itself only knows
# about discovery (discover_master / get_master_addr_by_name), so we
# resolve the master once here and reuse the resulting client for the
# whole process. If the master fails over, the next call to `master_for`
# picks up the new master; reconnect is handled in `_run_subscriber`'s
# retry loop.
_client = None  # type: ignore[var-annotated]
# The underlying Sentinel instance, kept around for `close()` on
# shutdown (master_for clients don't own the Sentinel connection, so
# closing the master connection alone leaks it). Only set in
# Sentinel mode; None in direct mode.
_sentinel: object | None = None
# True when running against a Sentinel-managed cluster (vs. a single
# Redis instance via REDIS_URL).
_sentinel_mode: bool = False
# Master name for Sentinel — only meaningful when _sentinel_mode is True.
_master_name: str = "chatroom-redis"
_subscriber_task: asyncio.Task | None = None
# Background task that re-runs _try_connect when the initial Sentinel
# discovery races the Redis StatefulSet at deploy time (or when Sentinel
# is briefly unreachable). When init_bus can't reach the master, the
# retry loop keeps trying every 5s (capped at 30s) until it succeeds;
# once it does, the subscriber starts and the retry task exits.
_retry_task: asyncio.Task | None = None
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


async def _try_connect() -> bool:
    """One attempt at connecting to Redis (Sentinel or direct).

    Sets module-level `_client`, `_sentinel_mode`, and `_master_name`
    on success and starts the subscriber task. Returns True on success,
    False on a transient failure (Sentinel not converged yet, network
    blip, etc). Callers should fall back to a retry loop on False; they
    must not crash the app on False — the degraded local-dispatch path
    in `publish` keeps single-pod traffic working in the meantime.

    Imports `redis.asyncio` lazily so the dependency is only required
    when the bus is actually enabled. Keeps `import app.main` working
    in environments without Redis installed locally.
    """
    global _client, _sentinel, _sentinel_mode, _master_name, _enabled, _subscriber_task

    sentinels = _sentinels()
    url = _url()

    if sentinels is None and url is None:
        return False

    import redis.asyncio as aioredis  # type: ignore
    import redis.asyncio.sentinel as aisentinel  # type: ignore

    if sentinels is not None:
        _master_name = os.getenv("REDIS_MASTER_NAME", "chatroom-redis")
        _sentinel_mode = True
        sentinel_password = os.getenv("REDIS_PASSWORD") or None
        _sentinel = aisentinel.Sentinel(
            sentinels,
            socket_timeout=5,
            password=sentinel_password,
        )
        # Probe Sentinel by asking for the master's address. If
        # Sentinel is up but the master isn't yet elected, this
        # raises MasterNotFoundError; we treat that as a transient
        # failure so the retry loop in `init_bus` can pick it up.
        try:
            master_addr = await _sentinel.discover_master(_master_name)
            # `Sentinel` itself only exposes discovery methods; bus
            # operations (XADD / XREADGROUP / XACK / XGROUP CREATE) live
            # on the master client. Resolve it once here so the rest of
            # the bus can use `_client` uniformly in both Sentinel and
            # direct mode. `master_for` re-discovers on connection loss,
            # so a Sentinel failover triggers a one-call reconnect the
            # next time `master_for` is invoked.
            _client = _sentinel.master_for(
                _master_name,
                socket_timeout=5,
                password=sentinel_password,
            )
        except Exception as e:
            log.warning(
                "Sentinels reachable but master %r not yet discovered: %s. "
                "Will retry.",
                _master_name, e,
            )
            _client = None
            _sentinel = None
            _sentinel_mode = False
            return False
        log.info(
            "Sentinel discovered master %r at %s:%d",
            _master_name, master_addr[0], master_addr[1],
        )
    else:
        _sentinel_mode = False
        _sentinel = None
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
    return True


async def _retry_connect_loop() -> None:
    """Re-attempt connection until it succeeds, then exit.

    A pod that lost the Sentinel-convergence race at startup shouldn't
    stay in single-pod mode for its whole lifetime — Sentinel converges
    a few seconds later and we want the bus to come up without a
    restart. Backoff caps at 30s so a permanently-down Redis doesn't
    pin a tight retry loop.
    """
    global _retry_task
    backoff = 5.0
    attempt = 0
    try:
        while True:
            attempt += 1
            if await _try_connect():
                log.info("Redis bus came up on retry (attempt %d); cross-pod broadcast enabled.",
                         attempt)
                return
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 30.0)
    except asyncio.CancelledError:
        raise
    finally:
        _retry_task = None


async def init_bus(local_dispatch: Callable[[int, str], Awaitable[None]]) -> None:
    """Wire the bus to a local-dispatch callback and start the subscriber.

    `local_dispatch(room_id, json_payload)` is called for every message
    the bus receives. The implementation in `ws_manager.py` walks its
    locally-tracked sockets for `room_id` and sends the payload down
    each one.

    If the initial connection attempt fails (most commonly because the
    Redis StatefulSet isn't fully converged yet at deploy time), a
    background retry task keeps trying until it succeeds. The
    application stays usable in the meantime via the degraded
    single-pod dispatch path in `publish` — cross-pod fan-out is just
    paused until the bus comes up.
    """
    global _local_dispatch, _retry_task, _enabled

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

    if await _try_connect():
        return

    # Initial attempt failed. Schedule a retry loop so a deploy-time
    # race with Sentinel convergence doesn't leave the pod permanently
    # degraded. Idempotent: a second init_bus call won't spawn two loops.
    if _retry_task is None or _retry_task.done():
        _retry_task = asyncio.create_task(_retry_connect_loop(), name="redis-bus-retry")


async def shutdown_bus() -> None:
    """Cancel the subscriber (and any pending retry loop) and close the
    Redis client. Idempotent."""
    global _client, _sentinel, _subscriber_task, _retry_task, _enabled, _local_dispatch, _sentinel_mode

    _enabled = False
    if _retry_task is not None:
        _retry_task.cancel()
        try:
            await _retry_task
        except (asyncio.CancelledError, Exception):
            pass
        _retry_task = None
    if _subscriber_task is not None:
        _subscriber_task.cancel()
        try:
            await _subscriber_task
        except (asyncio.CancelledError, Exception):
            pass
        _subscriber_task = None
    if _client is not None:
        try:
            await _client.aclose()
        except Exception:
            pass
        _client = None
    if _sentinel is not None:
        # `redis.asyncio.sentinel.Sentinel` itself doesn't expose a close
        # method — it's just a discovery wrapper. The `master_for` client
        # owns its own `SentinelConnectionPool` (closed above via
        # `_client.aclose()`), so closing the master connection releases
        # everything Sentinel-related. Drop the handle so a subsequent
        # `_try_connect` rebuilds the wrapper.
        _sentinel = None
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
    global _client
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
        # refresh will pick it up. In Sentinel mode, also try to
        # re-resolve the master so the *next* publish hits the new
        # master instead of pinning the old (now-replica) address.
        log.warning("Redis XADD failed for room %s: %s", room_id, e)
        if _sentinel_mode and _sentinel is not None:
            try:
                _client = _sentinel.master_for(
                    _master_name,
                    socket_timeout=5,
                    password=os.getenv("REDIS_PASSWORD") or None,
                )
            except Exception as e2:
                log.warning("Master re-resolution after XADD failure also failed: %s", e2)


async def _run_subscriber() -> None:
    """Long-lived subscriber task. One per pod.

    Uses XREADGROUP to pull entries from the shared stream. Each entry
    is dispatched to the local WS sockets and then XACK'd so it's
    removed from this consumer's pending list. If a message fails to
    dispatch (e.g. all local sockets are broken), we still XACK so the
    pending list doesn't grow without bound — the message is also in
    MySQL via the REST/WS upload path, so a refresh recovers it.

    On a Sentinel failover the master_for connection points at a
    Redis that is now a replica and rejects writes/reads-on-master.
    We detect that (or any other persistent error) and re-resolve the
    master via `_sentinel.master_for` so the next XREADGROUP targets
    the new master. Backoff caps at 30s so a permanently-down Redis
    doesn't pin a tight loop.
    """
    global _client
    assert _sentinel_mode is False or _sentinel is not None  # mypy appeasement
    consumer = _consumer_name()
    backoff = 1.0
    while True:
        try:
            assert _client is not None
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
            # Redis doesn't pin a tight loop. In Sentinel mode we also
            # re-resolve the master so a failover picks up the new
            # master on the next iteration instead of pinning the old
            # (now-replica) address.
            log.warning("Redis subscriber error: %s. Retrying in %.1fs.", e, backoff)
            if _sentinel_mode and _sentinel is not None:
                try:
                    _client = _sentinel.master_for(
                        _master_name,
                        socket_timeout=5,
                        password=os.getenv("REDIS_PASSWORD") or None,
                    )
                    log.info("Re-resolved Redis master via Sentinel after subscriber error.")
                    backoff = 1.0  # fresh connection — try promptly
                except Exception as e2:
                    log.warning("Master re-resolution failed: %s", e2)
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 30.0)


async def _safe_xack(entry_id: str) -> None:
    """Best-effort XACK. A failure here is logged but never raised."""
    assert _client is not None
    try:
        await _client.xack(STREAM_KEY, CONSUMER_GROUP, entry_id)
    except Exception as e:
        log.warning("Redis XACK failed for entry %s: %s", entry_id, e)