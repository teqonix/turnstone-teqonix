"""Tests for the unified proxy event bus + SSE streaming endpoint."""

import asyncio
import json
import os
import time
from unittest.mock import AsyncMock, patch, MagicMock

import pytest

# Set env vars before importing the module for deterministic testing.
os.environ["NODE_RYZEN_ONE"] = "http://ryzen1"
os.environ["NODE_RYZEN_TWO"] = "http://ryzen2"
os.environ["NODE_MBP_OLLAMA"] = "http://mac"
os.environ["COOLDOWN_SECONDS"] = "30.0"

import unified_proxy
from unified_proxy import (
    EventHub,
    event_hub,
    emit_event,
    emit_node_state_change,
    _node_state_for_url,
    _now_iso,
    EVENT_TYPES,
    app,
)


# ---------------------------------------------------------------------------
# EventHub unit tests
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_hub_publish_and_snapshot():
    hub = EventHub(max_events=5)
    for i in range(7):
        await hub.publish({"ts": "t", "type": "request_start", "node": "n", "payload": {"i": i}})
    snap = hub.snapshot()
    assert len(snap) == 5  # ring buffer capped at 5
    assert snap[0]["payload"]["i"] == 2  # oldest two dropped
    assert snap[-1]["payload"]["i"] == 6


@pytest.mark.asyncio
async def test_hub_fan_out_to_subscribers():
    hub = EventHub()
    q1 = await hub.subscribe()
    q2 = await hub.subscribe()
    ev = {"ts": "t", "type": "request_start", "node": "n", "payload": {}}
    await hub.publish(ev)
    assert await q1.get() is ev
    assert await q2.get() is ev
    await hub.unsubscribe(q1)
    await hub.unsubscribe(q2)


@pytest.mark.asyncio
async def test_hub_unsubscribe_stops_delivery():
    hub = EventHub()
    q = await hub.subscribe()
    await hub.unsubscribe(q)
    await hub.publish({"ts": "t", "type": "x", "node": "n", "payload": {}})
    assert q.empty()


def test_emit_event_sync_context():
    """emit_event outside an event loop appends to the buffer only."""
    before = len(event_hub)
    emit_event("request_start", node="http://n1", model="gemma")
    assert len(event_hub) == before + 1
    ev = event_hub.snapshot()[-1]
    assert ev["type"] == "request_start"
    assert ev["node"] == "http://n1"
    assert ev["payload"]["model"] == "gemma"
    assert ev["ts"]  # non-empty ISO timestamp


@pytest.mark.asyncio
async def test_emit_event_async_context_fans_out():
    q = await event_hub.subscribe()
    emit_event("capacity_rejected", node="cluster", model="qwen")
    ev = await asyncio.wait_for(q.get(), timeout=2.0)
    assert ev["type"] == "capacity_rejected"
    await event_hub.unsubscribe(q)


# ---------------------------------------------------------------------------
# Node state derivation
# ---------------------------------------------------------------------------

def test_node_state_derivation():
    assert _node_state_for_url("u", {"offline": True}) == "OFFLINE"
    assert _node_state_for_url("u", {"is_computing": True, "in_flight": 3}) == "BUSY"
    assert _node_state_for_url("u", {"is_computing": True, "in_flight": 1}) == "ACTIVE"
    assert _node_state_for_url("u", {"is_computing": False, "in_flight": 1}) == "ACTIVE"
    assert _node_state_for_url("u", {"is_computing": False, "in_flight": 0}) == "IDLE"


def test_emit_node_state_change_only_on_transition():
    # Reset tracking state.
    unified_proxy._last_node_state.clear()
    before = len(event_hub)

    stats = {"is_computing": True, "in_flight": 2}
    emit_node_state_change("http://n1", stats)
    assert len(event_hub) == before + 1  # IDLE -> BUSY (first observation)
    assert event_hub.snapshot()[-1]["type"] == "node_state_change"

    # Same state again: no new event.
    emit_node_state_change("http://n1", stats)
    assert len(event_hub) == before + 1

    # Transition to offline also emits node_offline.
    emit_node_state_change("http://n1", {"offline": True})
    snap = event_hub.snapshot()[-2:]
    types = [e["type"] for e in snap]
    assert "node_offline" in types


# ---------------------------------------------------------------------------
# SSE endpoint (via FastAPI TestClient)
# ---------------------------------------------------------------------------

def test_events_snapshot_endpoint():
    from fastapi.testclient import TestClient
    client = TestClient(app)
    emit_event("request_start", node="http://n1", model="gemma")
    res = client.get("/events")
    assert res.status_code == 200
    body = res.json()
    assert body["count"] >= 1
    assert any(e["type"] == "request_start" for e in body["events"])


def test_events_ingest_endpoint():
    from fastapi.testclient import TestClient
    client = TestClient(app)
    res = client.post("/events/ingest", json={
        "type": "request_end",
        "node": "http://n1",
        "payload": {"model": "gemma", "status": 200, "ok": True},
    })
    assert res.status_code == 200
    assert res.json()["ok"] is True

    # Invalid type rejected.
    res = client.post("/events/ingest", json={"type": "bogus"})
    assert res.status_code == 422


@pytest.mark.asyncio
async def test_sse_generator_replay_and_live():
    """Drive the SSE generator logic directly: replay history, then a live event."""
    # Seed one replayable event.
    emit_event("request_end", node="http://n1", model="gemma", ok=True)

    queue = await event_hub.subscribe()
    replayed = event_hub.snapshot()
    replayed_ids = {id(e) for e in replayed}

    async def gen():
        for ev in replayed:
            yield f"event: proxy\ndata: {json.dumps(ev, separators=(',', ':'))}\n\n"
        while True:
            ev = await queue.get()
            if ev is None:
                break
            if id(ev) in replayed_ids:
                replayed_ids.discard(id(ev))
                continue
            yield f"event: proxy\ndata: {json.dumps(ev, separators=(',', ':'))}\n\n"

    g = gen()
    first = await asyncio.wait_for(g.__anext__(), timeout=5.0)
    assert first.startswith("event: proxy")
    saw_seeded = "request_end" in first
    while not saw_seeded:
        chunk = await asyncio.wait_for(g.__anext__(), timeout=5.0)
        saw_seeded = "request_end" in chunk
    assert saw_seeded

    # Now emit a LIVE event and confirm it arrives via the subscriber queue.
    emit_event("runaway_detected", node="http://n1", in_flight=4, stuck_seconds=610.0)
    got_live = False
    for _ in range(5):
        chunk = await asyncio.wait_for(g.__anext__(), timeout=5.0)
        if "runaway_detected" in chunk:
            got_live = True
            break
    assert got_live

    # Sentinel closes the stream cleanly.
    await queue.put(None)
    with pytest.raises(StopAsyncIteration):
        await asyncio.wait_for(g.__anext__(), timeout=5.0)
    await event_hub.unsubscribe(queue)


def test_sse_endpoint_live_via_real_server():
    """End-to-end SSE over HTTP against a real uvicorn server.

    TestClient cannot host an infinite StreamingResponse (its portal blocks
    while the stream task never yields), so we spawn uvicorn in a thread and
    consume the stream with httpx.
    """
    import threading
    import time
    import uvicorn
    import httpx

    config = uvicorn.Config(app, host="127.0.0.1", port=13999, log_level="error")
    server = uvicorn.Server(config)
    t = threading.Thread(target=server.run, daemon=True)
    t.start()
    deadline = time.time() + 15
    while not server.started and time.time() < deadline:
        time.sleep(0.1)
    assert server.started, "uvicorn did not start"

    try:
        # Seed an event so the replay delivers a data payload immediately.
        emit_event("request_start", node="http://n1", model="qwen")
        with httpx.Client(timeout=10.0) as client:
            with client.stream("GET", "http://127.0.0.1:13999/events/stream") as res:
                assert res.status_code == 200
                assert res.headers["content-type"].startswith("text/event-stream")
                assert res.headers.get("x-accel-buffering") == "no"
                data_seen = False
                for line in res.iter_lines():
                    if line.startswith("data:"):
                        ev = json.loads(line[5:].strip())
                        assert set(ev) >= {"ts", "type", "node", "payload"}
                        data_seen = True
                        break
                assert data_seen, "no data event received on SSE stream"
    finally:
        server.should_exit = True
        t.join(timeout=10)
