"""
Turnstone Dynamic Lemonade / LLM Manager (AMD Ryzen AI Halo)
Supports two operational deployment modes:
1. 'watchdog' (default): Out-of-band observer that checks lemond.service (port 13305)
   system stats and health. If memory usage exceeds 75% of node RAM (128GB), it inspects
   'all_models_loaded' via /v1/health, tracks 'last_use' idle timestamps, and evicts
   conflicting or idle heavy models via POST /v1/unload.
2. 'proxy': In-line reverse proxy (port 13306) intercepting inference traffic to enforce
   immediate lazy eviction before requests reach lemond.service.
"""

import os
import time
import asyncio
import logging
from datetime import datetime
from contextlib import asynccontextmanager
from typing import Optional, Dict, Any, List

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import StreamingResponse, Response, JSONResponse
import httpx
import uvicorn

# Configure Logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [DynamicLemonadeManager] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S"
)
logger = logging.getLogger("dynamic_lemonade_manager")

# Configuration & Deployment Modes
MANAGER_MODE = os.getenv("LEMONADE_MANAGER_MODE", "watchdog").strip().lower()
LEMONADE_BACKEND_URL = os.getenv("LEMONADE_BACKEND_URL", "http://127.0.0.1:13305").rstrip("/")
WATCHDOG_POLL_INTERVAL = int(os.getenv("LEMONADE_WATCHDOG_POLL_INTERVAL_SECONDS", "60"))
IDLE_TTL_SECONDS = int(os.getenv("LEMONADE_IDLE_TTL_SECONDS", "180"))  # 3 minutes

# Memory Threshold Settings (128GB node default, 75% threshold = 96GB)
TOTAL_RAM_GB = float(os.getenv("NODE_TOTAL_RAM_GB", "128.0"))
MEMORY_THRESHOLD_PERCENT = float(os.getenv("LEMONADE_MEMORY_THRESHOLD_PERCENT", "75.0"))
MEMORY_THRESHOLD_GB = (MEMORY_THRESHOLD_PERCENT / 100.0) * TOTAL_RAM_GB

# Heavy Model Canonical Families
HEAVY_MODELS = ["gemma", "qwen"]

def get_heavy_family(model_name: Optional[str]) -> Optional[str]:
    if not model_name:
        return None
    norm = model_name.lower()
    for h in HEAVY_MODELS:
        if h in norm:
            return h
    return None


async def check_lemond_service() -> Dict[str, Any]:
    """Check systemd status of lemond.service and HTTP reachability."""
    is_active = False
    try:
        proc = await asyncio.create_subprocess_exec(
            "systemctl", "is-active", "--quiet", "lemond.service",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        await proc.communicate()
        is_active = (proc.returncode == 0)
    except Exception as e:
        logger.debug(f"Could not query systemctl for lemond.service: {e}")

    backend_reachable = False
    try:
        async with httpx.AsyncClient(timeout=2.0) as client:
            res = await client.get(f"{LEMONADE_BACKEND_URL}/v1/health")
            backend_reachable = (res.status_code < 500)
    except Exception:
        try:
            async with httpx.AsyncClient(timeout=2.0) as client:
                res = await client.get(f"{LEMONADE_BACKEND_URL}/health")
                backend_reachable = (res.status_code < 500)
        except Exception:
            backend_reachable = False

    return {
        "systemd_active": is_active,
        "backend_reachable": backend_reachable,
        "backend_url": LEMONADE_BACKEND_URL
    }


async def ensure_lemond_service_running():
    """Ensure lemond.service is active; trigger start via systemctl if needed."""
    status = await check_lemond_service()
    if status["backend_reachable"]:
        logger.info(f"Connected to OOtB lemond backend at {LEMONADE_BACKEND_URL}")
        return

    logger.warning(f"lemond backend at {LEMONADE_BACKEND_URL} not reachable. Checking systemd lemond.service...")
    if not status["systemd_active"]:
        logger.info("lemond.service is not active. Attempting systemctl start lemond.service...")
        try:
            proc = await asyncio.create_subprocess_exec(
                "systemctl", "start", "lemond.service",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
            await proc.communicate()
            if proc.returncode == 0:
                logger.info("Triggered systemctl start lemond.service successfully.")
                await asyncio.sleep(2)
            else:
                logger.warning(f"systemctl start lemond.service exited with code {proc.returncode}.")
        except Exception as e:
            logger.warning(f"Failed to start lemond.service via systemctl: {e}")


class LemonadeLifecycleManager:
    def __init__(self, backend_url: str, mode: str):
        self.backend_url = backend_url
        self.mode = mode
        self.http_client: Optional[httpx.AsyncClient] = None
        self.lock = asyncio.Lock()

        # State tracking
        self.active_models: Dict[str, Dict[str, Any]] = {}
        self.current_heavy_model: Optional[str] = None
        self.last_active_time: float = time.time()
        self.last_poll_time: Optional[float] = None
        self.last_poll_status: Optional[str] = None
        self.latest_system_stats: Dict[str, Any] = {}
        self.eviction_history: List[Dict[str, Any]] = []

    async def init_client(self):
        self.http_client = httpx.AsyncClient(
            timeout=httpx.Timeout(connect=10.0, read=300.0, write=30.0, pool=300.0),
            limits=httpx.Limits(max_keepalive_connections=50, max_connections=200)
        )

    async def close_client(self):
        if self.http_client:
            await self.http_client.aclose()

    def record_eviction(self, model_name: str, reason: str, success: bool):
        entry = {
            "timestamp": datetime.utcnow().isoformat() + "Z",
            "model": model_name,
            "reason": reason,
            "success": success
        }
        self.eviction_history.append(entry)
        if len(self.eviction_history) > 50:
            self.eviction_history.pop(0)

    async def evict_model(self, model_name: str, reason: str) -> bool:
        """Issue unload command via POST /v1/unload to lemond backend."""
        logger.info(f"Evicting model '{model_name}' from lemond RAM (Reason: {reason})...")
        success = False
        try:
            res = await self.http_client.post(
                f"{self.backend_url}/v1/unload",
                json={"model_name": model_name},
                timeout=10.0
            )
            success = (res.status_code < 400)
            logger.info(f"lemond POST /v1/unload response for '{model_name}': {res.status_code}")
        except Exception as e:
            logger.warning(f"Error issuing POST /v1/unload for '{model_name}': {e}")
            success = False

        self.record_eviction(model_name, reason, success)
        if self.current_heavy_model == model_name:
            self.current_heavy_model = None
        if model_name in self.active_models:
            del self.active_models[model_name]
        return success

    # -------------------------------------------------------------------------
    # Watchdog Mode Logic (Out-of-Band Polling & System Stats Supervision)
    # -------------------------------------------------------------------------
    async def fetch_system_stats(self) -> Optional[Dict[str, Any]]:
        """Query /v1/system-stats to check RAM and GPU utilization."""
        try:
            res = await self.http_client.get(f"{self.backend_url}/v1/system-stats", timeout=5.0)
            if res.status_code == 200:
                stats = res.json()
                self.latest_system_stats = stats
                return stats
        except Exception as e:
            logger.debug(f"Watchdog failed to fetch /v1/system-stats: {e}")
        return None

    async def fetch_loaded_models_from_health(self) -> List[Dict[str, Any]]:
        """Query /v1/health to fetch active in-memory models from 'all_models_loaded'."""
        try:
            res = await self.http_client.get(f"{self.backend_url}/v1/health", timeout=5.0)
            if res.status_code == 200:
                data = res.json()
                loaded_list = data.get("all_models_loaded", [])
                if isinstance(loaded_list, list):
                    return loaded_list
        except Exception as e:
            logger.debug(f"Watchdog failed to fetch /v1/health: {e}")
        return []

    async def watchdog_iteration(self):
        """Perform one periodic watchdog inspection of lemond."""
        self.last_poll_time = time.time()
        now = time.time()

        # Step 1: Query System Stats and Check Memory Safety Window
        stats = await self.fetch_system_stats()
        current_memory_gb = stats.get("memory_gb", 0.0) if stats else 0.0
        memory_percent = (current_memory_gb / TOTAL_RAM_GB) * 100.0 if TOTAL_RAM_GB > 0 else 0.0

        if current_memory_gb <= MEMORY_THRESHOLD_GB:
            self.last_poll_status = (
                f"Memory Safe: {current_memory_gb:.1f}GB / {TOTAL_RAM_GB:.0f}GB "
                f"({memory_percent:.1f}% <= {MEMORY_THRESHOLD_PERCENT:.0f}% threshold). Eviction skipped."
            )
            logger.debug(f"[Watchdog] {self.last_poll_status}")
            return

        logger.warning(
            f"[Watchdog] High RAM utilization detected: {current_memory_gb:.1f}GB / {TOTAL_RAM_GB:.0f}GB "
            f"({memory_percent:.1f}% > {MEMORY_THRESHOLD_PERCENT:.0f}% threshold). Inspecting loaded models..."
        )

        # Step 2: Fetch Active Loaded Models from /v1/health
        loaded_models = await self.fetch_loaded_models_from_health()
        if not loaded_models:
            self.last_poll_status = f"High Memory ({current_memory_gb:.1f}GB) but no active models in all_models_loaded."
            return

        async with self.lock:
            # Map of model_name -> model metadata
            current_loaded_names = set()
            heavy_loaded: Dict[str, Dict[str, Any]] = {}

            for m in loaded_models:
                m_name = m.get("model_name") or m.get("checkpoint") or ""
                if not m_name:
                    continue
                current_loaded_names.add(m_name)
                last_use_val = m.get("last_use")
                pid = m.get("pid")
                family = get_heavy_family(m_name)

                # Initialize or update tracking
                if m_name not in self.active_models:
                    self.active_models[m_name] = {
                        "first_seen": now,
                        "last_active_time": now,
                        "last_use": last_use_val,
                        "pid": pid,
                        "family": family
                    }
                    logger.info(f"[Watchdog] Discovered in-memory model in lemond: '{m_name}' (Family: {family}, last_use: {last_use_val}, PID: {pid})")
                else:
                    prev_last_use = self.active_models[m_name].get("last_use")
                    if last_use_val != prev_last_use:
                        # Activity occurred on model, reset last active time
                        self.active_models[m_name]["last_active_time"] = now
                        self.active_models[m_name]["last_use"] = last_use_val
                        logger.debug(f"[Watchdog] Activity detected on '{m_name}' (last_use changed: {prev_last_use} -> {last_use_val}).")

                if family:
                    heavy_loaded[m_name] = {
                        "family": family,
                        "last_active_time": self.active_models[m_name]["last_active_time"],
                        "last_use": last_use_val,
                        "pid": pid
                    }

            # Remove models from active_models that are no longer reported by lemond
            for m_name in list(self.active_models.keys()):
                if m_name not in current_loaded_names:
                    del self.active_models[m_name]

            # Step 3: Eviction Trigger A - Conflict: Multiple Heavy Model Families Loaded
            unique_families = {meta["family"]: m_name for m_name, meta in heavy_loaded.items()}
            if len(unique_families) > 1:
                logger.warning(f"[Watchdog] Heavy model conflict detected under memory pressure! Loaded families: {list(unique_families.keys())}")
                # Sort heavy models by last_active_time ascending (oldest first)
                sorted_heavy = sorted(
                    heavy_loaded.items(),
                    key=lambda item: item[1]["last_active_time"]
                )
                # Evict all except the newest active heavy model
                for old_model_name, _ in sorted_heavy[:-1]:
                    await self.evict_model(
                        old_model_name,
                        reason=f"High RAM ({current_memory_gb:.1f}GB > {MEMORY_THRESHOLD_GB:.1f}GB) & Heavy model conflict"
                    )

            # Step 4: Eviction Trigger B - Idle TTL Reached for Heavy Model
            for m_name, meta in list(heavy_loaded.items()):
                last_act = self.active_models.get(m_name, {}).get("last_active_time", now)
                idle_duration = now - last_act
                if idle_duration >= IDLE_TTL_SECONDS:
                    logger.info(f"[Watchdog] Model '{m_name}' reached Idle TTL under memory pressure ({idle_duration:.0f}s >= {IDLE_TTL_SECONDS}s).")
                    await self.evict_model(
                        m_name,
                        reason=f"High RAM ({current_memory_gb:.1f}GB > {MEMORY_THRESHOLD_GB:.1f}GB) & Idle TTL ({idle_duration:.0f}s >= {IDLE_TTL_SECONDS}s)"
                    )

            self.last_poll_status = f"Evaluated: {len(loaded_models)} models in RAM, {len(heavy_loaded)} heavy. RAM: {current_memory_gb:.1f}GB."

    async def watchdog_loop(self):
        logger.info(
            f"Starting Watchdog loop (Polling: {WATCHDOG_POLL_INTERVAL}s, Idle TTL: {IDLE_TTL_SECONDS}s, "
            f"RAM Threshold: {MEMORY_THRESHOLD_PERCENT:.0f}% / {MEMORY_THRESHOLD_GB:.1f}GB of {TOTAL_RAM_GB:.0f}GB)..."
        )
        while True:
            try:
                await self.watchdog_iteration()
            except Exception as e:
                logger.error(f"Unexpected error in Watchdog loop: {e}")
            await asyncio.sleep(WATCHDOG_POLL_INTERVAL)

    # -------------------------------------------------------------------------
    # Proxy Mode Logic (Inline Request Interception)
    # -------------------------------------------------------------------------
    async def prepare_for_request(self, model_name: str):
        async with self.lock:
            self.last_active_time = time.time()
            family = get_heavy_family(model_name)
            if family:
                if self.current_heavy_model and self.current_heavy_model != family:
                    logger.info(f"[Proxy] Lazy Eviction: Switching active heavy model from '{self.current_heavy_model}' to '{family}'...")
                    await self.evict_model(self.current_heavy_model, reason="Proxy Lazy Eviction: Conflict with new requested model")
                self.current_heavy_model = family

    async def idle_cleanup_loop(self):
        logger.info(f"Starting Proxy Idle Reaper loop (Interval: 15s, TTL: {IDLE_TTL_SECONDS}s)...")
        while True:
            await asyncio.sleep(15)
            if self.current_heavy_model is not None:
                idle_duration = time.time() - self.last_active_time
                if idle_duration >= IDLE_TTL_SECONDS:
                    async with self.lock:
                        if self.current_heavy_model is not None and (time.time() - self.last_active_time >= IDLE_TTL_SECONDS):
                            logger.info(f"[Proxy] Idle TTL reached ({idle_duration:.0f}s >= {IDLE_TTL_SECONDS}s). Evicting idle model.")
                            await self.evict_model(self.current_heavy_model, reason=f"Proxy Idle TTL ({idle_duration:.0f}s >= {IDLE_TTL_SECONDS}s)")


manager = LemonadeLifecycleManager(LEMONADE_BACKEND_URL, MANAGER_MODE)

@asynccontextmanager
async def lifespan(app: FastAPI):
    await manager.init_client()
    await ensure_lemond_service_running()
    
    if manager.mode == "proxy":
        task = asyncio.create_task(manager.idle_cleanup_loop())
    else:
        task = asyncio.create_task(manager.watchdog_loop())
        
    yield
    task.cancel()
    await manager.close_client()

app = FastAPI(title=f"Turnstone Dynamic Lemonade Manager ({MANAGER_MODE.upper()})", lifespan=lifespan)

# -----------------------------------------------------------------------------
# Endpoints
# -----------------------------------------------------------------------------
@app.get("/health")
@app.get("/health/readiness")
@app.get("/health/liveliness")
@app.get("/status")
async def health():
    backend_status = await check_lemond_service()
    now = time.time()
    
    # Enrich active models with idle seconds
    active_models_summary = {}
    for m_name, meta in manager.active_models.items():
        last_act = meta.get("last_active_time", now)
        active_models_summary[m_name] = {
            "family": meta.get("family"),
            "pid": meta.get("pid"),
            "last_use": meta.get("last_use"),
            "idle_seconds": int(now - last_act)
        }

    return {
        "status": "healthy",
        "manager_mode": manager.mode,
        "lemond_backend": LEMONADE_BACKEND_URL,
        "lemond_status": backend_status,
        "system_memory": {
            "total_ram_gb": TOTAL_RAM_GB,
            "threshold_percent": MEMORY_THRESHOLD_PERCENT,
            "threshold_gb": round(MEMORY_THRESHOLD_GB, 2),
            "latest_stats": manager.latest_system_stats
        },
        "watchdog_poll_interval_seconds": WATCHDOG_POLL_INTERVAL,
        "idle_ttl_seconds": IDLE_TTL_SECONDS,
        "last_poll_status": manager.last_poll_status,
        "all_models_loaded": active_models_summary,
        "current_heavy_model": manager.current_heavy_model,
        "recent_evictions": manager.eviction_history[-10:]
    }

@app.get("/v1/models")
async def list_models(request: Request):
    try:
        req = manager.http_client.build_request("GET", f"{manager.backend_url}/v1/models")
        res = await manager.http_client.send(req)
        return Response(content=res.content, status_code=res.status_code, headers=dict(res.headers))
    except Exception as e:
        logger.warning(f"Error fetching /v1/models from lemond backend: {e}")
        return {
            "object": "list",
            "data": [
                {"id": "gemma-4-31b", "object": "model", "owned_by": "turnstone-lemonade"},
                {"id": "qwen-3.8-27b", "object": "model", "owned_by": "turnstone-lemonade"},
                {"id": "ornith-1.5-9b", "object": "model", "owned_by": "turnstone-lemonade"}
            ]
        }

@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "OPTIONS", "HEAD", "PATCH"])
async def proxy_or_handle(path: str, request: Request):
    if manager.mode == "watchdog":
        logger.debug(f"[Watchdog Notice] Proxy request received for /{path}. Direct port 13305 is primary.")

    body = None
    if request.method in ["POST", "PUT", "PATCH"]:
        try:
            body = await request.json()
            if isinstance(body, dict):
                model_name = body.get("model", "")
                if model_name:
                    await manager.prepare_for_request(model_name)
        except Exception:
            body = await request.body()

    headers = {k: v for k, v in request.headers.items() if k.lower() not in ["host", "content-length"]}
    target_url = f"{manager.backend_url}/{path.lstrip('/')}"

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
                    async for chunk in backend_res.aiter_raw():
                        yield chunk
                finally:
                    await backend_res.aclose()
            return StreamingResponse(stream_generator(), status_code=backend_res.status_code, media_type="text/event-stream")
        else:
            content = await backend_res.aread()
            await backend_res.aclose()
            return Response(content=content, status_code=backend_res.status_code, headers=dict(backend_res.headers))
    except Exception as e:
        logger.error(f"Error proxying request to lemond ({target_url}): {e}")
        raise HTTPException(status_code=502, detail=f"Backend communication failure with lemond: {str(e)}")

if __name__ == "__main__":
    port = int(os.getenv("PORT", "13306"))
    host = os.getenv("HOST", "0.0.0.0")
    logger.info(f"Starting Dynamic Lemonade Manager ({MANAGER_MODE.upper()} mode) on {host}:{port} -> Backend: {LEMONADE_BACKEND_URL}")
    uvicorn.run("dynamic_lemonade_manager:app", host=host, port=port, log_level="info")
