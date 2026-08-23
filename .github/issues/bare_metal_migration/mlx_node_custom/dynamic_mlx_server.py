"""
Turnstone Dynamic MLX Model Server
OpenAI-compatible inference server for Apple Silicon (MLX Engine).
Supports dynamic model swapping, Lazy Eviction on Conflict, Metal memory cache clearing, and Idle TTL.
"""

import os
import gc
import time
import asyncio
import logging
import json
from contextlib import asynccontextmanager
from typing import Optional, Dict, Any, List, Union

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, Field
import uvicorn

# Configure Logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [DynamicMLXServer] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S"
)
logger = logging.getLogger("dynamic_mlx_server")

# Try importing MLX dependencies
try:
    import mlx.core as mx
    import mlx_lm
    from mlx_lm.utils import load, generate_step
    from mlx_lm.sample_utils import make_sampler
    MLX_AVAILABLE = True
except ImportError:
    MLX_AVAILABLE = False
    logger.warning("mlx or mlx_lm not found in environment; running in stub/dry-run mode.")

# -----------------------------------------------------------------------------
# Model Aliases & Configuration
# -----------------------------------------------------------------------------
IDLE_TTL_SECONDS = int(os.getenv("MLX_IDLE_TTL_SECONDS", "180"))  # 3 minutes

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_MODELS_PATH = os.path.join(SCRIPT_DIR, "..", "models.json")
MODELS_CONFIG_PATH = os.getenv("MODELS_CONFIG_PATH", DEFAULT_MODELS_PATH)
MODELS_REGISTRY: List[Dict[str, Any]] = []
try:
    with open(MODELS_CONFIG_PATH, "r") as f:
        data = json.load(f)
        MODELS_REGISTRY = data.get("models", [])
except Exception as e:
    logger.error(f"Failed to load models config from {MODELS_CONFIG_PATH}: {e}")

def resolve_model_path(model_name: str) -> str:
    norm = model_name.replace("openai/", "").lower().strip()
    
    # Exact match on litellm_name or mlx_target
    for m in MODELS_REGISTRY:
        if m.get("litellm_name", "").lower() == norm:
            return m.get("mlx_target", model_name)
        if m.get("mlx_target", "").lower() == norm:
            return m.get("mlx_target", model_name)
            
    # Fallback to substring
    for m in MODELS_REGISTRY:
        targ = m.get("mlx_target", "").lower()
        alias = m.get("litellm_name", "").lower()
        if (alias and alias in norm) or (targ and targ in norm):
            return m.get("mlx_target", model_name)
            
    return model_name

# -----------------------------------------------------------------------------
# Model Manager (Dynamic Swapping + Memory Eviction)
# -----------------------------------------------------------------------------
class DynamicMLXManager:
    def __init__(self):
        self.current_model_name: Optional[str] = None
        self.model = None
        self.tokenizer = None
        self.lock = asyncio.Lock()
        self.last_active_time: float = time.time()
        self.in_flight_requests: int = 0

    def clear_cache(self):
        gc.collect()
        if MLX_AVAILABLE and hasattr(mx, "metal") and hasattr(mx.metal, "clear_cache"):
            mx.metal.clear_cache()
            logger.info("Cleared MLX Metal cache.")

    async def unload_current_model(self):
        if self.model is not None:
            logger.info(f"Unloading model '{self.current_model_name}' from Unified Memory...")
            self.model = None
            self.tokenizer = None
            self.current_model_name = None
            self.clear_cache()
            logger.info("Model unloaded successfully.")

    async def get_or_load_model(self, requested_name: str):
        target_path = resolve_model_path(requested_name)
        async with self.lock:
            self.last_active_time = time.time()
            if self.current_model_name == target_path and self.model is not None:
                return self.model, self.tokenizer

            # Evict previous model if different
            if self.model is not None:
                logger.info(f"Lazy Eviction: Replacing active '{self.current_model_name}' with requested '{target_path}'...")
                await self.unload_current_model()

            logger.info(f"Loading MLX model '{target_path}' into Apple Silicon Unified Memory...")
            if MLX_AVAILABLE:
                loop = asyncio.get_running_loop()
                model, tokenizer = await loop.run_in_executor(None, lambda: load(target_path))
                self.model = model
                self.tokenizer = tokenizer
                self.current_model_name = target_path
                logger.info(f"Successfully loaded '{target_path}'.")
            else:
                self.current_model_name = target_path
                logger.info(f"[Stub] Loaded '{target_path}'.")

            return self.model, self.tokenizer

    async def idle_cleanup_loop(self):
        while True:
            await asyncio.sleep(15)
            if self.model is not None:
                idle_duration = time.time() - self.last_active_time
                if idle_duration >= IDLE_TTL_SECONDS and self.in_flight_requests == 0:
                    async with self.lock:
                        if self.model is not None and self.in_flight_requests == 0 and (time.time() - self.last_active_time >= IDLE_TTL_SECONDS):
                            logger.info(f"Idle TTL reached ({idle_duration:.0f}s >= {IDLE_TTL_SECONDS}s). Evicting idle model.")
                            await self.unload_current_model()

manager = DynamicMLXManager()

@asynccontextmanager
async def lifespan(app: FastAPI):
    cleanup_task = asyncio.create_task(manager.idle_cleanup_loop())
    yield
    cleanup_task.cancel()
    await manager.unload_current_model()

app = FastAPI(title="Turnstone Dynamic MLX Server", lifespan=lifespan)

# -----------------------------------------------------------------------------
# Request & Response Schemas
# -----------------------------------------------------------------------------
class ChatMessage(BaseModel):
    role: str
    content: str

class ChatCompletionRequest(BaseModel):
    model: str
    messages: List[ChatMessage]
    temperature: Optional[float] = 0.7
    top_p: Optional[float] = 1.0
    max_tokens: Optional[int] = 2048
    stream: Optional[bool] = False

# -----------------------------------------------------------------------------
# Endpoints
# -----------------------------------------------------------------------------
@app.get("/health")
@app.get("/health/readiness")
@app.get("/health/liveliness")
async def health():
    return {
        "status": "healthy",
        "active_model": manager.current_model_name,
        "in_flight_requests": manager.in_flight_requests,
        "idle_seconds": int(time.time() - manager.last_active_time) if manager.model else 0
    }

@app.get("/v1/models")
async def list_models():
    data = []
    for m in MODELS_REGISTRY:
        if m.get("mlx_target"):
            data.append({
                "id": m.get("litellm_name"),
                "object": "model",
                "created": int(time.time()),
                "owned_by": "turnstone-mlx",
                "root": m.get("mlx_target")
            })
    return {"object": "list", "data": data}

@app.post("/v1/chat/completions")
async def chat_completions(req: ChatCompletionRequest):
    manager.last_active_time = time.time()
    manager.in_flight_requests += 1
    try:
        model, tokenizer = await manager.get_or_load_model(req.model)

        if not MLX_AVAILABLE or model is None or tokenizer is None:
            # Stub response if MLX is not installed in local environment
            content = f"[MLX Stub Response] Handled request for model '{req.model}'."
            return {
                "id": f"chatcmpl-{int(time.time())}",
                "object": "chat.completion",
                "created": int(time.time()),
                "model": req.model,
                "choices": [{
                    "index": 0,
                    "message": {"role": "assistant", "content": content},
                    "finish_reason": "stop"
                }],
                "usage": {"prompt_tokens": 10, "completion_tokens": 10, "total_tokens": 20}
            }

        # Format messages using Jinja chat template if available on tokenizer
        messages_dicts = [{"role": m.role, "content": m.content} for m in req.messages]
        if hasattr(tokenizer, "apply_chat_template"):
            prompt = tokenizer.apply_chat_template(messages_dicts, tokenize=False, add_generation_prompt=True)
        else:
            prompt = "\n".join([f"{m.role}: {m.content}" for m in req.messages]) + "\nassistant: "

        sampler = make_sampler(temp=req.temperature, top_p=req.top_p)

        if req.stream:
            async def stream_generator():
                try:
                    created_ts = int(time.time())
                    for response in generate_step(
                        prompt=tokenizer.encode(prompt),
                        model=model,
                        temp=req.temperature,
                        top_p=req.top_p,
                        max_tokens=req.max_tokens or 2048,
                        sampler=sampler
                    ):
                        token, text = response
                        chunk = {
                            "id": f"chatcmpl-{created_ts}",
                            "object": "chat.completion.chunk",
                            "created": created_ts,
                            "model": req.model,
                            "choices": [{
                                "index": 0,
                                "delta": {"content": text},
                                "finish_reason": None
                            }]
                        }
                        yield f"data: {JSONResponse(content=chunk).body.decode('utf-8')}\n\n"
                        await asyncio.sleep(0)

                    yield "data: [DONE]\n\n"
                finally:
                    manager.in_flight_requests -= 1

            return StreamingResponse(stream_generator(), media_type="text/event-stream")
        else:
            loop = asyncio.get_running_loop()
            generated_text = await loop.run_in_executor(
                None,
                lambda: mlx_lm.generate(
                    model=model,
                    tokenizer=tokenizer,
                    prompt=prompt,
                    max_tokens=req.max_tokens or 2048,
                    temp=req.temperature,
                    top_p=req.top_p
                )
            )
            return {
                "id": f"chatcmpl-{int(time.time())}",
                "object": "chat.completion",
                "created": int(time.time()),
                "model": req.model,
                "choices": [{
                    "index": 0,
                    "message": {"role": "assistant", "content": generated_text},
                    "finish_reason": "stop"
                }],
                "usage": {
                    "prompt_tokens": len(tokenizer.encode(prompt)),
                    "completion_tokens": len(tokenizer.encode(generated_text)),
                    "total_tokens": len(tokenizer.encode(prompt)) + len(tokenizer.encode(generated_text))
                }
            }
    except Exception:
        manager.in_flight_requests -= 1
        raise
    finally:
        # If it was NOT a streaming request, we decrement here. 
        # For streaming, the stream_generator's finally block handles it.
        if not req.stream:
            manager.in_flight_requests -= 1

if __name__ == "__main__":
    port = int(os.getenv("PORT", "8000"))
    host = os.getenv("HOST", "0.0.0.0")
    uvicorn.run("dynamic_mlx_server:app", host=host, port=port, log_level="info")
