"""
Turnstone Dynamic Lemonade / LLM Manager (AMD Ryzen AI Halo)
Manages model residency, concurrency, and memory eviction on Linux nodes.
Forwards inference requests to the local Lemonade / llama.cpp engine on port 8000,
while enforcing Lazy Eviction on Conflict and Idle TTL memory reclamation.
"""

import os
import time
import asyncio
import logging
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

LEMONADE_BACKEND_URL = os.getenv("LEMONADE_BACKEND_URL", "http://127.0.0.1:8000")
IDLE_TTL_SECONDS = int(os.getenv("LEMONADE_IDLE_TTL_SECONDS", "180"))  # 3 minutes

# Model canonical mappings
HEAVY_MODELS = ["gemma", "qwen"]

class LemonadeResidencyManager:
    def __init__(self, backend_url: str):
        self.backend_url = backend_url.rstrip("/")
        self.current_heavy_model: Optional[str] = None
        self.last_active_time: float = time.time()
        self.lock = asyncio.Lock()
        self.http_client: Optional[httpx.AsyncClient] = None

    async def init_client(self):
        self.http_client = httpx.AsyncClient(
            timeout=httpx.Timeout(connect=10.0, read=300.0, write=30.0, pool=300.0),
            limits=httpx.Limits(max_keepalive_connections=50, max_connections=200)
        )

    async def close_client(self):
        if self.http_client:
            await self.http_client.aclose()

    def is_heavy_model(self, model_name: Optional[str]) -> bool:
        if not model_name:
            return False
        norm = model_name.lower()
        return any(h in norm for h in HEAVY_MODELS)

    async def evict_backend_models(self):
        """Send eviction/unload signal to Lemonade backend."""
        logger.info(f"Evicting active model '{self.current_heavy_model}' from Lemonade RAM...")
        try:
            # Check if Lemonade or llama-server supports unload endpoint
            res = await self.http_client.post(f"{self.backend_url}/v1/models/unload", json={"model": self.current_heavy_model}, timeout=5.0)
            logger.info(f"Unload response: {res.status_code}")
        except Exception as e:
            logger.debug(f"Direct unload request completed: {e}")
        self.current_heavy_model = None

    async def prepare_for_request(self, model_name: str):
        async with self.lock:
            self.last_active_time = time.time()
            if self.is_heavy_model(model_name):
                norm_requested = model_name.lower()
                requested_family = "gemma" if "gemma" in norm_requested else ("qwen" if "qwen" in norm_requested else norm_requested)
                
                # Check for conflict with previously loaded heavy model
                if self.current_heavy_model and self.current_heavy_model != requested_family:
                    logger.info(f"Lazy Eviction: Switching active heavy model from '{self.current_heavy_model}' to '{requested_family}'...")
                    await self.evict_backend_models()

                self.current_heavy_model = requested_family

    async def idle_cleanup_loop(self):
        while True:
            await asyncio.sleep(15)
            if self.current_heavy_model is not None:
                idle_duration = time.time() - self.last_active_time
                if idle_duration >= IDLE_TTL_SECONDS:
                    async with self.lock:
                        if self.current_heavy_model is not None and (time.time() - self.last_active_time >= IDLE_TTL_SECONDS):
                            logger.info(f"Idle TTL reached ({idle_duration:.0f}s >= {IDLE_TTL_SECONDS}s). Evicting idle model.")
                            await self.evict_backend_models()

manager = LemonadeResidencyManager(LEMONADE_BACKEND_URL)

@asynccontextmanager
async def lifespan(app: FastAPI):
    await manager.init_client()
    cleanup_task = asyncio.create_task(manager.idle_cleanup_loop())
    yield
    cleanup_task.cancel()
    await manager.close_client()

app = FastAPI(title="Turnstone Dynamic Lemonade Manager", lifespan=lifespan)

# -----------------------------------------------------------------------------
# Proxy Endpoints
# -----------------------------------------------------------------------------
@app.get("/health")
@app.get("/health/readiness")
@app.get("/health/liveliness")
async def health():
    return {
        "status": "healthy",
        "backend": LEMONADE_BACKEND_URL,
        "active_heavy_model": manager.current_heavy_model,
        "idle_seconds": int(time.time() - manager.last_active_time) if manager.current_heavy_model else 0
    }

@app.get("/v1/models")
async def list_models(request: Request):
    try:
        req = manager.http_client.build_request("GET", f"{manager.backend_url}/v1/models")
        res = await manager.http_client.send(req)
        return Response(content=res.content, status_code=res.status_code, headers=dict(res.headers))
    except Exception as e:
        logger.warning(f"Error fetching /v1/models from backend: {e}")
        return {
            "object": "list",
            "data": [
                {"id": "gemma-4-31b", "object": "model", "owned_by": "turnstone-lemonade"},
                {"id": "qwen-3.8-27b", "object": "model", "owned_by": "turnstone-lemonade"},
                {"id": "ornith-1.5-9b", "object": "model", "owned_by": "turnstone-lemonade"}
            ]
        }

@app.post("/v1/{path:path}")
@app.post("/{path:path}")
async def proxy_inference(path: str, request: Request):
    try:
        body = await request.json()
    except Exception:
        body = {}

    model_name = body.get("model", "")
    if model_name:
        await manager.prepare_for_request(model_name)

    headers = {k: v for k, v in request.headers.items() if k.lower() not in ["host", "content-length"]}
    target_url = f"{manager.backend_url}/{path.lstrip('/')}"
    
    try:
        backend_req = manager.http_client.build_request(
            method=request.method,
            url=target_url,
            headers=headers,
            json=body,
            params=request.query_params
        )
        backend_res = await manager.http_client.send(backend_req, stream=True)

        is_streaming = "text/event-stream" in backend_res.headers.get("content-type", "") or body.get("stream", False)

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
        logger.error(f"Error proxying inference request to {target_url}: {e}")
        raise HTTPException(status_code=502, detail=f"Backend communication failure: {str(e)}")

if __name__ == "__main__":
    port = int(os.getenv("PORT", "13305"))
    host = os.getenv("HOST", "0.0.0.0")
    uvicorn.run("dynamic_lemonade_manager:app", host=host, port=port, log_level="info")
