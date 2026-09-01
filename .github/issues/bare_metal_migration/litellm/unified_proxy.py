import os
import json
import random
import logging
import asyncio
import time
from collections import deque
from typing import Dict, Any, List, Optional
from enum import Enum
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import StreamingResponse
import httpx
import uvicorn

from service_watchdog import LlmServiceWatchdog, _normalize_url

# Configure Logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [UnifiedProxy] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S"
)
logger = logging.getLogger("unified_proxy")


class NodeState(Enum):
    AVAILABLE = "AVAILABLE"       # RAM > 30%, no heavy model, or no load
    SMALL_ONLY = "SMALL_ONLY"     # RAM > 30%, 1 heavy model running
    AT_CAPACITY = "AT_CAPACITY"   # RAM < 30% with heavy model OR 1 heavy + 1 small


# ---------------------------------------------------------------------------
# Event bus - ring buffer + async fan-out for streaming subscribers
# ---------------------------------------------------------------------------
# Event types emitted by the proxy:
#
#   request_start      - a request was routed to a node
#   request_end        - a request completed (ok / error)
#   node_state_change  - a node's state transitioned (IDLE → ACTIVE → BUSY …)
#   node_offline       - a node became unreachable
#   capacity_rejected  - all nodes were at capacity; request was rejected
#   model_swap         - a heavy model was unloaded to make room for a new one
#   runaway_detected   - a runaway request was detected and killed
#   watchdog_restart   - watchdog initiated service restart on a wedged node
#   node_recovered     - node recovered and confirmed responsive after restart
#
# Each event is a JSON object with at least:
#   ts       - ISO-8601 UTC timestamp
#   type     - one of the event types above
#   node     - node URL, or "cluster" for cluster-wide events
#   payload  - type-specific fields (dict)

EVENT_TYPES = (
    "request_start",
    "request_end",
    "node_state_change",
    "node_offline",
    "capacity_rejected",
    "model_swap",
    "runaway_detected",
    "watchdog_restart",
    "node_recovered",
)

#: Max events kept in the in-memory ring buffer (for late-joining subscribers).
EVENT_BUFFER_SIZE = int(os.getenv("PROXY_EVENT_BUFFER_SIZE", "500"))

#: Seconds between keep-alive comments on the SSE stream.
EVENT_KEEPALIVE_INTERVAL = 15.0


class EventHub:
    """In-memory ring buffer with async fan-out to SSE subscribers.

    A bounded ``deque`` holds the most recent events; every connected
    subscriber receives each new event via an ``asyncio.Queue``.  The same
    pattern used by the monitoring app's ``LogHub``.
    """

    def __init__(self, max_events: int = EVENT_BUFFER_SIZE):
        self._buffer: deque = deque(maxlen=max_events)
        self._subscribers: set = set()
        self._lock = asyncio.Lock()

    async def subscribe(self) -> "asyncio.Queue":
        q: "asyncio.Queue" = asyncio.Queue()
        async with self._lock:
            self._subscribers.add(q)
        return q

    async def unsubscribe(self, q: "asyncio.Queue") -> None:
        async with self._lock:
            self._subscribers.discard(q)

    async def publish(self, event: dict) -> None:
        """Append to the ring buffer and fan out to all subscribers."""
        self._buffer.append(event)
        async with self._lock:
            dead = []
            for q in self._subscribers:
                try:
                    q.put_nowait(event)
                except asyncio.QueueFull:
                    dead.append(q)
            for q in dead:
                self._subscribers.discard(q)

    def snapshot(self) -> list:
        """Return the current buffer contents (oldest → newest)."""
        return list(self._buffer)

    def __len__(self) -> int:
        return len(self._buffer)


#: Process-wide singleton.
event_hub = EventHub()


def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def emit_event(event_type: str, node: str = "cluster", **payload) -> None:
    """Emit a proxy event to the event hub.

    Safe to call from both sync and async contexts.  When called from within
    a running event loop the fan-out to subscriber queues is scheduled as a
    task (preserving synchronous buffer append for ordering); otherwise the
    event is appended directly to the ring buffer only.
    """
    event = {"ts": _now_iso(), "type": event_type, "node": node, "payload": payload}
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        event_hub._buffer.append(event)
        return
    event_hub._buffer.append(event)
    loop.create_task(_fan_out_event(event_hub, event))


async def _fan_out_event(hub: "EventHub", event: dict) -> None:
    """Deliver an already-buffered event to all subscriber queues."""
    async with hub._lock:
        dead = []
        for q in hub._subscribers:
            try:
                q.put_nowait(event)
            except asyncio.QueueFull:
                dead.append(q)
        for q in dead:
            hub._subscribers.discard(q)


# ---------------------------------------------------------------------------
# Node state tracking - emits node_state_change / node_offline on transitions
# ---------------------------------------------------------------------------

#: Last derived state per node URL.
_last_node_state: Dict[str, str] = {}


def _node_state_for_url(url: str, stats: dict) -> str:
    """Derive a coarse state label from a stats dict."""
    if stats.get("offline"):
        return "OFFLINE"
    is_computing = stats.get("is_computing", False)
    in_flight = stats.get("in_flight", 0)
    if is_computing and in_flight >= 2:
        return "BUSY"
    if is_computing or in_flight > 0:
        return "ACTIVE"
    return "IDLE"


def emit_node_state_change(url: str, stats: dict) -> None:
    """Emit a node_state_change event if the node's state transitioned.

    Called from ``get_best_node`` after each stats fetch so that state
    transitions (IDLE → ACTIVE → BUSY → IDLE, or → OFFLINE) are observable
    by streaming subscribers in near-real-time.
    """
    new_state = _node_state_for_url(url, stats)
    old_state = _last_node_state.get(url)
    if old_state != new_state:
        _last_node_state[url] = new_state
        emit_event(
            "node_state_change",
            node=url,
            old_state=old_state,
            new_state=new_state,
            in_flight=stats.get("in_flight", 0),
            gpu_usage=stats.get("gpu_usage", 0.0),
            mem_utilization=stats.get("mem_utilization", 0.0),
            is_computing=stats.get("is_computing", False),
            loaded_models=stats.get("loaded_models", []),
        )
        logger.info(f"Node state change: {url} {old_state} → {new_state}")
    if stats.get("offline") and old_state != "OFFLINE":
        emit_event("node_offline", node=url, reason="unreachable")
        _last_node_state[url] = "OFFLINE"


# Pull from environment variables set in deploy script
NODE_RYZEN_ONE = os.getenv("NODE_RYZEN_ONE", "http://amd-ai-core-one.lan:13305")
NODE_RYZEN_TWO = os.getenv("NODE_RYZEN_TWO", "http://amd-ai-core-two.lan:13305")
NODE_MBP_SSH_USER = os.getenv("TURNSTONE_USER", "turnstone")
NODE_MBP_HOSTNAME = os.getenv("MBP_HOSTNAME", "mbp-ai-core.lan")
NODE_MBP_OLLAMA = os.getenv("NODE_MBP_OLLAMA", f"http://{NODE_MBP_HOSTNAME}:11434")
NODE_MBP_SSH = os.getenv("NODE_MBP_SSH", f"{NODE_MBP_SSH_USER}@{NODE_MBP_HOSTNAME}")

COOLDOWN_SECONDS = float(os.getenv("NODE_COOLDOWN_SECONDS", os.getenv("COOLDOWN_SECONDS", "30.0")))
HEAVY_MODELS = ["gemma", "qwen"]


def is_heavy_model(model_name: str) -> bool:
    norm = model_name.lower()
    return any(h in norm for h in HEAVY_MODELS)


class UnifiedProxyManager:
    def __init__(self):
        self.http_client: Optional[httpx.AsyncClient] = None
        self.model_map: Dict[str, Dict[str, str]] = {}
        self.in_flight_requests: Dict[str, int] = {}
        self.last_active_time: Dict[str, float] = {}
        self.last_access: Dict[str, Dict[str, float]] = {}
        self.watchdog: LlmServiceWatchdog = LlmServiceWatchdog(
            event_callback=lambda event_type, node, payload: emit_event(event_type, node=node, **payload)
        )

    def update_access_time(self, backend_url: str, model_name: str):
        if backend_url not in self.last_access:
            self.last_access[backend_url] = {}
        self.last_access[backend_url][model_name] = time.time()

    def load_model_map(self):
        config_path = os.getenv("MODELS_MAP_PATH", "models_map.json")
        try:
            if os.path.exists(config_path):
                with open(config_path, "r") as f:
                    self.model_map = json.load(f)
                logger.info(f"Loaded model mappings from {config_path}")
            else:
                logger.warning(f"Model map config {config_path} not found.")
        except Exception as e:
            logger.error(f"Failed to load model map: {e}")

    async def init_client(self):
        self.http_client = httpx.AsyncClient(
            timeout=httpx.Timeout(connect=10.0, read=300.0, write=30.0, pool=300.0),
            limits=httpx.Limits(max_keepalive_connections=50, max_connections=200)
        )
        self.watchdog.set_http_client(self.http_client)

    async def close_client(self):
        if self.http_client:
            await self.http_client.aclose()

    def record_request_start(self, backend_url: str):
        self.in_flight_requests[backend_url] = self.in_flight_requests.get(backend_url, 0) + 1
        self.last_active_time[backend_url] = asyncio.get_event_loop().time()

    def record_request_end(self, backend_url: str):
        current = self.in_flight_requests.get(backend_url, 0)
        self.in_flight_requests[backend_url] = max(0, current - 1)
        self.last_active_time[backend_url] = asyncio.get_event_loop().time()

    async def fetch_ryzen_stats(self, url: str) -> Dict[str, Any]:
        in_flight = self.in_flight_requests.get(url, 0)
        last_active = self.last_active_time.get(url, 0.0)
        now = asyncio.get_event_loop().time()
        time_since_active = (now - last_active) if last_active > 0 else 999999.0
        clean_url = _normalize_url(url)

        try:
            res_stats = await self.http_client.get(f"{clean_url}/v1/system-stats", timeout=5.0)
            res_health = await self.http_client.get(f"{clean_url}/v1/health", timeout=5.0)

            stats = res_stats.json() if res_stats.status_code == 200 else {}
            health = res_health.json() if res_health.status_code == 200 else {}

            memory_gb = stats.get("memory_gb", 0.0)
            total_ram = float(os.getenv("NODE_TOTAL_RAM_GB", "128.0"))
            mem_utilization = (memory_gb / total_ram) if total_ram > 0 else 0

            gpu_usage = stats.get("gpu_percent", 0.0)
            power_draw = 0.0

            raw_loaded = health.get("all_models_loaded", [])
            loaded_models = [m.get("model_name", "") for m in raw_loaded if isinstance(m, dict)]

            num_heavy = sum(1 for name in loaded_models if is_heavy_model(name))
            num_small = len(loaded_models) - num_heavy

            return {
                "mem_utilization": mem_utilization,
                "gpu_usage": gpu_usage,
                "power_draw": power_draw,
                "loaded_models": loaded_models,
                "num_heavy": num_heavy,
                "num_small": num_small,
                "in_flight": in_flight,
                "time_since_active": time_since_active,
                "backend_url": url,
                "is_mac": False
            }
        except Exception as e:
            logger.warning(f"Failed to fetch stats from {url}: {e}")
            return {
                "mem_utilization": 1.0,
                "gpu_usage": 100,
                "power_draw": 1000,
                "loaded_models": [],
                "num_heavy": 99,
                "num_small": 99,
                "in_flight": in_flight,
                "time_since_active": time_since_active,
                "backend_url": url,
                "is_mac": False,
                "offline": True
            }

    async def fetch_macos_stats(self) -> Dict[str, Any]:
        in_flight = self.in_flight_requests.get(NODE_MBP_OLLAMA, 0)
        last_active = self.last_active_time.get(NODE_MBP_OLLAMA, 0.0)
        now = asyncio.get_event_loop().time()
        time_since_active = (now - last_active) if last_active > 0 else 999999.0

        try:
            proc = await asyncio.create_subprocess_shell(
                f"ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 {NODE_MBP_SSH} 'all-smi snapshot'",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
            stdout, stderr = await proc.communicate()
            if proc.returncode == 0:
                stats = json.loads(stdout.decode())

                mem_utilization = 0.0
                if "memory" in stats and len(stats["memory"]) > 0:
                    mem_utilization = stats["memory"][0].get("utilization", 0.0) / 100.0

                gpu_usage = 0.0
                if "gpus" in stats and len(stats["gpus"]) > 0:
                    gpu_usage = stats["gpus"][0].get("utilization", 0.0)

                power_draw = 0.0
                if "chassis" in stats and len(stats["chassis"]) > 0:
                    power_draw = stats["chassis"][0].get("total_power_watts", 0.0)

                loaded_models = []

                try:
                    ollama_res = await self.http_client.get(f"{NODE_MBP_OLLAMA}/api/ps", timeout=2.0)
                    if ollama_res.status_code == 200:
                        ollama_models = ollama_res.json().get("models", [])
                        for m in ollama_models:
                            name = m.get("name", "")
                            if name:
                                loaded_models.append(name)
                except Exception:
                    pass

                num_heavy = sum(1 for name in loaded_models if is_heavy_model(name))
                num_small = len(loaded_models) - num_heavy

                return {
                    "mem_utilization": mem_utilization,
                    "gpu_usage": gpu_usage,
                    "power_draw": power_draw,
                    "loaded_models": loaded_models,
                    "num_heavy": num_heavy,
                    "num_small": num_small,
                    "in_flight": in_flight,
                    "time_since_active": time_since_active,
                    "backend_url": NODE_MBP_OLLAMA,
                    "is_mac": True
                }
            else:
                logger.warning(f"Failed SSH to Mac: {stderr.decode()}")
                return {
                    "mem_utilization": 1.0,
                    "gpu_usage": 100,
                    "power_draw": 1000,
                    "loaded_models": [],
                    "num_heavy": 99,
                    "num_small": 99,
                    "in_flight": in_flight,
                    "time_since_active": time_since_active,
                    "backend_url": NODE_MBP_OLLAMA,
                    "is_mac": True,
                    "offline": True
                }
        except Exception as e:
            logger.warning(f"Exception fetching Mac stats: {e}")
            return {
                "mem_utilization": 1.0,
                "gpu_usage": 100,
                "power_draw": 1000,
                "loaded_models": [],
                "num_heavy": 99,
                "num_small": 99,
                "in_flight": in_flight,
                "time_since_active": time_since_active,
                "backend_url": NODE_MBP_OLLAMA,
                "is_mac": True,
                "offline": True
            }

    async def get_best_node(self, model_name: str) -> Optional[Dict[str, Any]]:
        is_heavy = is_heavy_model(model_name)
        norm_model = model_name.lower().replace("openai/", "").strip()

        mac_task = self.fetch_macos_stats()
        ryzen1_task = self.fetch_ryzen_stats(NODE_RYZEN_ONE)
        ryzen2_task = self.fetch_ryzen_stats(NODE_RYZEN_TWO)

        mac_stats, ryzen1_stats, ryzen2_stats = await asyncio.gather(mac_task, ryzen1_task, ryzen2_task)

        nodes = [mac_stats, ryzen1_stats, ryzen2_stats]

        logger.info(f"--- Evaluating Node States for '{model_name}' (Heavy: {is_heavy}) ---")
        valid_nodes = []
        for n in nodes:
            node_name = "Mac (MBP)" if n.get("is_mac") else n.get("backend_url", "Unknown")
            if n.get("offline"):
                logger.warning(f"  [{node_name}] Status: OFFLINE / Unreachable")
                continue

            loaded = n.get("loaded_models", [])
            has_matching_model = any(norm_model in m.lower() or m.lower() in norm_model for m in loaded)
            mem = n.get("mem_utilization", 0.0)
            gpu = n.get("gpu_usage", 0.0)
            power = n.get("power_draw", 0.0)
            num_heavy = n.get("num_heavy", 0)
            num_small = n.get("num_small", 0)
            in_flight = n.get("in_flight", 0)
            time_since_active = n.get("time_since_active", 999999.0)

            # A node is actively computing if it has active in-flight requests or GPU > 15%
            is_computing = (gpu > 15.0) or (in_flight > 0)
            cooldown_passed = (not is_computing) and (time_since_active >= COOLDOWN_SECONDS)

            n["is_computing"] = is_computing
            n["cooldown_passed"] = cooldown_passed
            n["has_matching_model"] = has_matching_model

            # Emit state-change event if this node transitioned state.
            emit_node_state_change(n.get("backend_url", ""), n)

            is_valid = False
            reason = ""
            if has_matching_model:
                is_valid = True
                reason = "Model already loaded in memory"
            elif is_heavy:
                if num_heavy == 0 and mem < 0.85:
                    is_valid = True
                    reason = "Eligible for heavy model load (Node is empty of heavy models)"
                elif num_heavy >= 1:
                    if is_computing:
                        is_valid = False
                        reason = f"Actively computing other workload (In-flight: {in_flight}, GPU: {gpu:.1f}%)"
                    else:
                        is_valid = True
                        if cooldown_passed:
                            reason = "Eligible for heavy model swap (Cooldown passed)"
                        else:
                            reason = f"Eligible for heavy model swap (Within cooldown: {time_since_active:.1f}s < {COOLDOWN_SECONDS}s)"
                else:
                    reason = f"At capacity (RAM: {mem*100:.1f}%, Models: {num_heavy}h/{num_small}s)"
            else:
                if mem < 0.85:
                    is_valid = True
                    reason = "Eligible for light model"
                else:
                    reason = f"At capacity (RAM: {mem*100:.1f}%)"

            status_str = "VALID" if is_valid else "REJECTED"
            cooldown_str = "Cooldown: Passed" if cooldown_passed else f"Cooldown: {time_since_active:.1f}s"
            logger.info(f"  [{node_name}] {status_str} ({reason}) | RAM: {mem*100:.1f}%, GPU: {gpu:.1f}%, Power: {power:.1f}W, In-Flight: {in_flight}, {cooldown_str} | Loaded: {loaded}")

            if is_valid:
                valid_nodes.append(n)

        if not valid_nodes:
            logger.warning(f"No valid nodes available for '{model_name}'.")
            return None

        # Sort factors:
        # For Heavy Models:
        # 1. Prioritize idle Mac (rank 0) even if another node has the model in memory, to execute model swap
        # 2. Demote Mac if it is actively computing or within cooldown
        # 3. Prefer nodes that already have the model loaded in memory
        # 4. Prefer non-computing nodes
        # 5. Fewest in-flight requests
        # 6. Lowest GPU load, RAM utilization, power draw
        #
        # For Light Models:
        # 1. Prefer node with model already loaded in memory (avoid unnecessary swap/cold load)
        # 2. Prefer non-computing nodes
        # 3. Fewest in-flight requests
        # 4. Lowest GPU load, RAM utilization, power draw
        def sort_key(n):
            has_model = n.get("has_matching_model", False)
            gpu = n.get("gpu_usage", 0.0)
            is_mac = n.get("is_mac", False)
            is_computing = n.get("is_computing", False)
            cooldown_passed = n.get("cooldown_passed", True)
            in_flight = n.get("in_flight", 0)

            if is_heavy:
                # If Mac is valid, not computing, and cooldown has passed, give it top priority (rank 0)
                mac_heavy_priority = 0 if (is_mac and not is_computing and cooldown_passed) else 1
                mac_busy_penalty = 1 if (is_mac and (is_computing or not cooldown_passed)) else 0

                return (
                    mac_heavy_priority,      # 1. Prioritize idle Mac for heavy model swap & execution
                    mac_busy_penalty,        # 2. Demote Mac if busy or cooling down
                    not has_model,           # 3. Preloaded model match on alternative nodes
                    is_computing,            # 4. Prefer non-computing nodes
                    in_flight,               # 5. Fewest in-flight requests
                    round(gpu, -1),          # 6. Lowest GPU load
                    round(n.get("mem_utilization", 1.0), 2), # 7. Lowest RAM usage
                    n.get("power_draw", 1000.0)
                )
            else:
                return (
                    not has_model,           # 1. In-memory model match
                    is_computing,            # 2. Prefer non-computing nodes
                    in_flight,               # 3. Fewest in-flight requests
                    round(gpu, -1),          # 4. Lowest GPU load
                    round(n.get("mem_utilization", 1.0), 2), # 5. Lowest RAM usage
                    n.get("power_draw", 1000.0)
                )

        # Shuffle candidates first to distribute load evenly when all metrics are tied
        random.shuffle(valid_nodes)
        valid_nodes.sort(key=sort_key)
        best = valid_nodes[0]

        target = best.get("backend_url")
        best_name = "Mac (MBP - Ollama)" if best.get("is_mac") else best.get("backend_url")
        logger.info(f"--- Routing Decision: Selected [{best_name}] -> {target} ---")
        return best


manager = UnifiedProxyManager()


async def idle_watcher():
    logger.info("Starting idle model watcher with watchdog protection...")
    while True:
        await asyncio.sleep(60)
        try:
            current_time = time.time()
            for url in [NODE_RYZEN_ONE, NODE_RYZEN_TWO]:
                try:
                    if not manager.http_client:
                        continue
                    clean_url = _normalize_url(url)
                    res_health = await manager.http_client.get(f"{clean_url}/v1/health", timeout=5.0)
                    if res_health.status_code == 200:
                        health = res_health.json()
                        raw_loaded = health.get("all_models_loaded", [])
                        loaded_models = [m.get("model_name", "") for m in raw_loaded if isinstance(m, dict)]
                        
                        if url not in manager.last_access:
                            manager.last_access[url] = {}
                            
                        for model in loaded_models:
                            if not model:
                                continue
                            if model not in manager.last_access[url]:
                                manager.last_access[url][model] = current_time
                            
                            idle_time = current_time - manager.last_access[url][model]
                            if idle_time > 300:  # ~5 minutes
                                logger.info(f"Model {model} on {url} has been idle for {idle_time:.1f}s. Unloading to save power.")
                                try:
                                    res = await manager.http_client.post(
                                        f"{clean_url}/v1/unload", json={"model_name": model}, timeout=5.0
                                    )
                                    if res.status_code == 200:
                                        manager.last_access[url].pop(model, None)
                                        logger.info(f"Successfully unloaded idle model {model} from {url}")
                                    else:
                                        raise RuntimeError(f"Unload returned HTTP status {res.status_code}")
                                except Exception as e:
                                    logger.warning(
                                        f"Failed to unload idle model {model} from {url}: {e}. Triggering watchdog confirmation..."
                                    )
                                    await manager.watchdog.handle_unload_failure(
                                        url,
                                        model,
                                        e,
                                        on_recovered_cb=lambda u=url, m=model: manager.last_access.get(u, {}).pop(m, None),
                                    )
                except Exception as node_e:
                    logger.debug(f"Error checking node {url} in idle watcher: {node_e}")
        except asyncio.CancelledError:
            break
        except Exception as e:
            logger.error(f"Error in idle watcher: {e}")


async def runaway_watcher():
    logger.info("Starting runaway watcher with watchdog protection...")
    while True:
        await asyncio.sleep(60)
        try:
            now = asyncio.get_event_loop().time()
            for url, in_flight in list(manager.in_flight_requests.items()):
                if in_flight > 0:
                    last_active = manager.last_active_time.get(url, 0.0)
                    time_since_active = now - last_active
                    if time_since_active > 600:
                        logger.warning(
                            f"[WATCHDOG] Runaway watchdog timer passed: Node {url} has {in_flight} in-flight request(s) active for {time_since_active:.1f}s (> 600s). Restart suppressed."
                        )
                        emit_event(
                            "runaway_detected",
                            node=url,
                            in_flight=in_flight,
                            stuck_seconds=round(time_since_active, 1),
                        )
                        await manager.watchdog.handle_runaway_request(
                            url,
                            in_flight,
                            time_since_active,
                            on_recovered_cb=lambda u=url: manager.in_flight_requests.update({u: 0}),
                        )
        except asyncio.CancelledError:
            break
        except Exception as e:
            logger.error(f"Error in runaway watcher: {e}")


@asynccontextmanager
async def lifespan(app: FastAPI):
    manager.load_model_map()
    await manager.init_client()
    task1 = asyncio.create_task(idle_watcher())
    task2 = asyncio.create_task(runaway_watcher())
    yield
    task1.cancel()
    task2.cancel()
    try:
        await asyncio.gather(task1, task2, return_exceptions=True)
    except Exception:
        pass
    await manager.close_client()


app = FastAPI(title="Turnstone Unified Hardware Proxy", lifespan=lifespan)


@app.get("/events/stream")
async def events_stream(request: Request):
    """Server-Sent Events stream of proxy events.

    Subscribers receive:
    - A replay of the most recent events (up to ``EVENT_BUFFER_SIZE``)
    - Live events as they occur
    - Keep-alive comments every ``EVENT_KEEPALIVE_INTERVAL`` seconds

    Each event is a JSON object: ``{"ts","type","node","payload"}``.
    """
    queue = await event_hub.subscribe()
    logger.info(f"SSE subscriber connected ({len(event_hub._subscribers)} active, {len(event_hub)} buffered)")

    async def generate():
        # Replay history first.
        replayed = event_hub.snapshot()
        replayed_ids = {id(e) for e in replayed}
        for ev in replayed:
            yield f"event: proxy\ndata: {json.dumps(ev, separators=(',', ':'))}\n\n"

        # Stream live events.
        while True:
            try:
                ev = await asyncio.wait_for(queue.get(), timeout=EVENT_KEEPALIVE_INTERVAL)
            except asyncio.TimeoutError:
                yield ": keep-alive\n\n"
                continue

            if ev is None:
                break
            if id(ev) in replayed_ids:
                replayed_ids.discard(id(ev))
                continue
            yield f"event: proxy\ndata: {json.dumps(ev, separators=(',', ':'))}\n\n"

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache, no-transform",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


@app.post("/events/ingest")
async def events_ingest(request: Request):
    """Ingest a proxy event from an external component (e.g. a test harness).

    Body: ``{"type": "request_start", "node": "http://...", "payload": {...}}``
    """
    body = await request.json()
    event_type = body.get("type", "")
    if event_type not in EVENT_TYPES:
        raise HTTPException(status_code=422, detail=f"Invalid event type. Must be one of: {', '.join(EVENT_TYPES)}")
    event = {
        "ts": _now_iso(),
        "type": event_type,
        "node": body.get("node", "cluster"),
        "payload": body.get("payload", {}),
    }
    await event_hub.publish(event)
    logger.info(f"Event ingested: {event_type} node={event['node']}")
    return {"ok": True, "event": event}


@app.get("/events")
async def events_snapshot():
    """Return the most recent proxy events (up to ``EVENT_BUFFER_SIZE``)."""
    return {"events": event_hub.snapshot(), "count": len(event_hub)}


@app.get("/watchdog/status")
async def watchdog_status():
    """Returns status of LLM service watchdog, including cooldowns and last restarts."""
    nodes = [NODE_RYZEN_ONE, NODE_RYZEN_TWO, NODE_MBP_OLLAMA]
    statuses = {}
    for n in nodes:
        clean = _normalize_url(n)
        statuses[clean] = {
            "in_cooldown": manager.watchdog.is_in_cooldown(clean),
            "remaining_cooldown_s": round(manager.watchdog.get_remaining_cooldown(clean), 1),
            "last_restart_timestamp": manager.watchdog.last_restart_time.get(clean, 0.0),
            "is_mac": manager.watchdog.is_macos_backend(clean),
        }
    return {
        "cooldown_seconds": manager.watchdog.cooldown_seconds,
        "probe_timeout": manager.watchdog.probe_timeout,
        "recovery_timeout": manager.watchdog.recovery_timeout,
        "nodes": statuses,
    }


@app.post("/watchdog/restart")
async def watchdog_manual_restart(request: Request):
    """Manually trigger a watchdog service restart on a given node."""
    body = await request.json()
    node_url = body.get("node", "")
    if not node_url:
        raise HTTPException(status_code=400, detail="Missing 'node' parameter in request body.")
    reason = body.get("reason", "Manual admin restart request")
    clean = _normalize_url(node_url)
    success = await manager.watchdog.restart_node_service(
        clean,
        reason=reason,
        on_recovered_cb=lambda: manager.in_flight_requests.update({clean: 0}),
    )
    return {"ok": success, "node": clean, "reason": reason}


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "OPTIONS", "HEAD", "PATCH"])
async def proxy_or_handle(path: str, request: Request):
    body = None
    model_name = ""
    start_time = asyncio.get_event_loop().time()

    if request.method in ["POST", "PUT", "PATCH"]:
        try:
            body = await request.json()
            if isinstance(body, dict):
                model_name = body.get("model", "")
        except Exception:
            body = await request.body()

    if not model_name:
        if "models" in path:
             return {"object": "list", "data": []}
        return Response(content="Proxy is alive", status_code=200)

    best_node = await manager.get_best_node(model_name)

    if not best_node:
        logger.warning(f"All nodes are busy (AT_CAPACITY). Rejecting request for {model_name}.")
        emit_event(
            "capacity_rejected",
            node="cluster",
            model=model_name,
            is_heavy=is_heavy_model(model_name),
            reason="all nodes at capacity",
        )
        raise HTTPException(status_code=429, detail="All nodes are currently at capacity. Please try again later.")

    best_url = best_node.get("backend_url")
    is_heavy = is_heavy_model(model_name)
    has_matching_model = best_node.get("has_matching_model", False)

    # Perform Heavy Model Swap Unload if necessary
    if is_heavy and not has_matching_model and best_node.get("num_heavy", 0) >= 1:
        logger.info(f"Performing heavy model swap on {best_url}. Unloading existing heavy models.")
        if not best_node.get("is_mac"):
            clean_url = _normalize_url(best_url)
            for m in best_node.get("loaded_models", []):
                if is_heavy_model(m):
                    try:
                        res = await manager.http_client.post(
                            f"{clean_url}/v1/unload", json={"model_name": m}, timeout=10.0
                        )
                        if res.status_code == 200:
                            logger.info(f"Unloaded {m} from {best_url}")
                            emit_event(
                                "model_swap",
                                node=best_url,
                                unloaded_model=m,
                                incoming_model=model_name,
                            )
                        else:
                            raise RuntimeError(f"Swap unload returned HTTP status {res.status_code}")
                    except Exception as e:
                        logger.warning(
                            f"Failed to unload {m} for swap on {best_url}: {e}. Triggering watchdog recovery..."
                        )
                        recovered = await manager.watchdog.handle_unload_failure(
                            best_url,
                            m,
                            e,
                            on_recovered_cb=lambda u=best_url: manager.in_flight_requests.update({u: 0}),
                        )
                        if not recovered:
                            logger.error(
                                f"Node {best_url} could not be recovered after failed swap unload."
                            )
                            raise HTTPException(
                                status_code=503,
                                detail=f"Node {best_url} failed heavy model swap unload and could not be recovered by watchdog.",
                            )

    clean_best_url = _normalize_url(best_url)
    target_url = f"{clean_best_url}/{path.lstrip('/')}"
    logger.info(f"Routing request for {model_name} to {target_url}")

    # Rewrite model name based on target node to prevent 404s
    actual_model_name = model_name
    if isinstance(body, dict) and "model" in body:
        norm_model = model_name.lower()
        backend_type = "mac_ollama" if NODE_MBP_OLLAMA in best_url else "lemonade"
            
        mapping = manager.model_map.get(backend_type, {})
        for key, target_model in mapping.items():
            if key in norm_model:
                body["model"] = target_model
                actual_model_name = target_model
                break

    # Track access time for idle unloading
    if NODE_RYZEN_ONE in best_url or NODE_RYZEN_TWO in best_url:
        manager.update_access_time(best_url, actual_model_name)

    headers = {k: v for k, v in request.headers.items() if k.lower() not in ["host", "content-length"]}

    manager.record_request_start(best_url)
    emit_event(
        "request_start",
        node=best_url,
        model=model_name,
        actual_model=actual_model_name,
        is_heavy=is_heavy,
        has_matching_model=has_matching_model,
        in_flight=manager.in_flight_requests.get(best_url, 1),
    )
    try:
        if isinstance(body, dict):
            backend_req = manager.http_client.build_request(
                method=request.method,
                url=target_url,
                headers=headers,
                json=body,
                params=request.query_params
            )
        elif body:
            backend_req = manager.http_client.build_request(
                method=request.method,
                url=target_url,
                headers=headers,
                content=body,
                params=request.query_params
            )
        else:
            backend_req = manager.http_client.build_request(
                method=request.method,
                url=target_url,
                headers=headers,
                params=request.query_params
            )

        backend_res = await manager.http_client.send(backend_req, stream=True)

        is_streaming = "text/event-stream" in backend_res.headers.get("content-type", "") or (isinstance(body, dict) and body.get("stream", False))

        if is_streaming:
            async def stream_generator():
                try:
                    async for line in backend_res.aiter_lines():
                        if line.startswith("data: ") and line.strip() != "data: [DONE]":
                            data_str = line[6:].strip()
                            try:
                                chunk_json = json.loads(data_str)
                                choices = chunk_json.get("choices", [])
                                modified = False
                                for c in choices:
                                    delta = c.get("delta", {})
                                    if isinstance(delta, dict) and "reasoning" in delta and "reasoning_content" not in delta:
                                        delta["reasoning_content"] = delta["reasoning"]
                                        modified = True
                                if modified:
                                    line = f"data: {json.dumps(chunk_json)}"
                            except Exception:
                                pass
                        manager.last_active_time[best_url] = asyncio.get_event_loop().time()
                        yield (line + "\n").encode("utf-8")
                finally:
                    await backend_res.aclose()
                    manager.record_request_end(best_url)
                    elapsed = asyncio.get_event_loop().time() - start_time
                    logger.info(f"Stream finished for {model_name} on {target_url} in {elapsed:.2f}s (Status: {backend_res.status_code})")
                    emit_event(
                        "request_end",
                        node=best_url,
                        model=model_name,
                        actual_model=actual_model_name,
                        status=backend_res.status_code,
                        ok=backend_res.status_code < 400,
                        elapsed_s=round(elapsed, 2),
                        in_flight=manager.in_flight_requests.get(best_url, 0),
                    )
            return StreamingResponse(stream_generator(), status_code=backend_res.status_code, media_type="text/event-stream")
        else:
            try:
                content = await backend_res.aread()
                await backend_res.aclose()
                try:
                    data_json = json.loads(content.decode("utf-8"))
                    choices = data_json.get("choices", [])
                    modified = False
                    for c in choices:
                        msg = c.get("message", {})
                        if isinstance(msg, dict) and "reasoning" in msg and "reasoning_content" not in msg:
                            msg["reasoning_content"] = msg["reasoning"]
                            modified = True
                    if modified:
                        content = json.dumps(data_json).encode("utf-8")
                except Exception:
                    pass
                headers = dict(backend_res.headers)
                headers.pop("content-length", None)
                headers.pop("content-encoding", None)
                elapsed = asyncio.get_event_loop().time() - start_time
                logger.info(f"Request finished for {model_name} on {target_url} in {elapsed:.2f}s (Status: {backend_res.status_code})")
                return Response(content=content, status_code=backend_res.status_code, headers=headers)
            finally:
                manager.record_request_end(best_url)
                emit_event(
                    "request_end",
                    node=best_url,
                    model=model_name,
                    actual_model=actual_model_name,
                    status=backend_res.status_code,
                    ok=backend_res.status_code < 400,
                    elapsed_s=round(asyncio.get_event_loop().time() - start_time, 2),
                    in_flight=manager.in_flight_requests.get(best_url, 0),
                )

    except Exception as e:
        manager.record_request_end(best_url)
        elapsed = asyncio.get_event_loop().time() - start_time
        logger.error(f"Error proxying request to {target_url} after {elapsed:.2f}s: {e}")
        emit_event(
            "request_end",
            node=best_url,
            model=model_name,
            actual_model=actual_model_name,
            status=502,
            ok=False,
            error=str(e),
            elapsed_s=round(elapsed, 2),
            in_flight=manager.in_flight_requests.get(best_url, 0),
        )

        # If network error or timeout occurred, verify health and trigger background recovery
        if isinstance(e, (httpx.TimeoutException, httpx.NetworkError, httpx.RemoteProtocolError)):
            async def _check_and_recover_node(node_url: str, err_msg: str):
                try:
                    is_healthy = await manager.watchdog.probe_node_health(node_url)
                    if not is_healthy:
                        logger.error(
                            f"[WATCHDOG] Node {node_url} confirmed unresponsive after network error ({err_msg}). Initiating service restart."
                        )
                        await manager.watchdog.restart_node_service(
                            node_url,
                            reason=f"Node unresponsive after network error: {err_msg}",
                            on_recovered_cb=lambda: manager.in_flight_requests.update({node_url: 0}),
                        )
                except Exception as rec_err:
                    logger.error(f"[WATCHDOG] Error in background recovery check: {rec_err}")

            asyncio.create_task(_check_and_recover_node(best_url, str(e)))

        raise HTTPException(status_code=502, detail=f"Backend communication failure: {str(e)}")


if __name__ == "__main__":
    port = int(os.getenv("PORT", "13306"))
    host = os.getenv("HOST", "0.0.0.0")
    logger.info(f"Starting Unified Hardware Proxy on {host}:{port}")
    uvicorn.run("unified_proxy:app", host=host, port=port, log_level="info")
