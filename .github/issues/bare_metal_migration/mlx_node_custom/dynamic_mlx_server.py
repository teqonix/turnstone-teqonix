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

# Try importing MLX dependencies with fallback across mlx_lm versions
MLX_IMPORT_ERROR = None
try:
    import mlx.core as mx
    import mlx_lm
    from mlx_lm.utils import load

    # make_sampler resolution across mlx_lm versions
    try:
        from mlx_lm.sample_utils import make_sampler
    except ImportError:
        try:
            from mlx_lm.generate import make_sampler
        except ImportError:
            try:
                from mlx_lm.utils import make_sampler
            except ImportError:
                make_sampler = None

    # generate_step resolution across mlx_lm versions
    try:
        from mlx_lm.generate import generate_step
    except ImportError:
        try:
            from mlx_lm.utils import generate_step
        except ImportError:
            try:
                from mlx_lm import generate_step
            except ImportError:
                generate_step = None

    MLX_AVAILABLE = True
except Exception as e:
    MLX_AVAILABLE = False
    MLX_IMPORT_ERROR = str(e)
    logger.error(f"Failed to import MLX dependencies (mlx, mlx_lm): {e}", exc_info=True)

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
        if not MLX_AVAILABLE:
            raise HTTPException(status_code=500, detail=f"MLX engine not available on host: {MLX_IMPORT_ERROR}")

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
            try:
                model, tokenizer = load(target_path)
                if hasattr(mx, "synchronize"):
                    mx.synchronize()
                self.model = model
                self.tokenizer = tokenizer
                self.current_model_name = target_path
                logger.info(f"Successfully loaded '{target_path}'.")
                return self.model, self.tokenizer
            except Exception as e:
                logger.error(f"Failed to load MLX model '{target_path}': {e}", exc_info=True)
                await self.unload_current_model()
                raise HTTPException(status_code=500, detail=f"Failed to load MLX model '{target_path}': {str(e)}")

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

import re
import ast
import uuid

# -----------------------------------------------------------------------------
# Request & Response Schemas
# -----------------------------------------------------------------------------
class ChatMessage(BaseModel):
    role: str
    content: Optional[Union[str, List[Any]]] = ""
    name: Optional[str] = None
    tool_calls: Optional[List[Dict[str, Any]]] = None
    tool_call_id: Optional[str] = None

class ChatCompletionRequest(BaseModel):
    model: str
    messages: List[ChatMessage]
    tools: Optional[List[Dict[str, Any]]] = None
    tool_choice: Optional[Union[str, Dict[str, Any]]] = None
    temperature: Optional[float] = 0.7
    top_p: Optional[float] = 1.0
    max_tokens: Optional[int] = 2048
    stream: Optional[bool] = False
    stop: Optional[Union[str, List[str]]] = None

def normalize_tool_payload(raw_call: str) -> str:
    """Normalizes quote tokens like <|"|> or unicode quotes to standard quotes."""
    return raw_call.replace('<|"|>', '"').replace("<|'|>", "'").strip()

def parse_single_tool_call(raw_call: str) -> Optional[Dict[str, Any]]:
    raw_call = normalize_tool_payload(raw_call)
    func_name = None
    arguments_json = "{}"

    # Match call:func_name{...} or call:func_name(...) or func_name(...)
    call_match = re.match(r"^(?:call:)?([a-zA-Z0-9_\-\.]+)\s*([\(\{\[])(.*)[\)\}\]]$", raw_call, flags=re.DOTALL)
    if call_match:
        func_name = call_match.group(1).strip()
        bracket = call_match.group(2)
        body = call_match.group(3).strip()

        if bracket == "(":
            # Python style: func(a='val', b=1)
            args_dict = {}
            try:
                parsed_ast = ast.parse(f"dummy({body})")
                if parsed_ast.body and isinstance(parsed_ast.body[0].value, ast.Call):
                    for kw in parsed_ast.body[0].value.keywords:
                        try:
                            args_dict[kw.arg] = ast.literal_eval(kw.value)
                        except Exception:
                            args_dict[kw.arg] = ast.unparse(kw.value)
                arguments_json = json.dumps(args_dict)
            except Exception:
                try:
                    fixed_json = re.sub(r'([{,]\s*)([a-zA-Z0-9_\-]+)\s*:', r'\1"\2":', "{" + body + "}")
                    args_dict = json.loads(fixed_json)
                    arguments_json = json.dumps(args_dict)
                except Exception:
                    arguments_json = json.dumps({"raw_args": body})
        else:
            # Curly brace style: {action: "add", title: "..."}
            json_candidate = "{" + body + "}" if not body.startswith("{") else body
            try:
                fixed_json = re.sub(r'([{,]\s*)([a-zA-Z0-9_\-]+)\s*:', r'\1"\2":', json_candidate)
                args_dict = json.loads(fixed_json)
                arguments_json = json.dumps(args_dict)
            except Exception:
                try:
                    args_dict = json.loads(json_candidate)
                    arguments_json = json.dumps(args_dict)
                except Exception:
                    arguments_json = json.dumps({"raw_args": body})
    else:
        # Try JSON format: {"name": "...", "arguments": ...}
        try:
            call_json = json.loads(raw_call)
            func_name = call_json.get("name") or call_json.get("function", {}).get("name")
            args = call_json.get("arguments") or call_json.get("parameters") or {}
            if isinstance(args, dict):
                arguments_json = json.dumps(args)
            else:
                arguments_json = str(args)
        except Exception:
            logger.warning(f"Could not parse tool call payload: {raw_call}")
            return None

    if func_name:
        return {
            "id": f"call_{uuid.uuid4().hex[:8]}",
            "type": "function",
            "function": {
                "name": func_name,
                "arguments": arguments_json
            }
        }
    return None

RE_OPEN_THOUGHT = re.compile(r"<\|?channel\|?>[a-zA-Z0-9_\-]*|<think>|<thought>|<\|thought\|?>", re.IGNORECASE)
RE_CLOSE_THOUGHT = re.compile(r"<\|?/channel\|?>|</think>|</thought>|<\|?endofthought\|?>", re.IGNORECASE)
RE_OPEN_TOOL = re.compile(r"<\|?tool_call\|?>|<\|?tool_code\|?>", re.IGNORECASE)
RE_CLOSE_TOOL = re.compile(r"<\|?/tool_call\|?>|<\|?/tool_code\|?>", re.IGNORECASE)

def parse_model_output(raw_text: str):
    """
    Parses raw LLM generation for:
    1) Reasoning / thought channels
    2) Tool calls
    Returns: (clean_content, reasoning_content, tool_calls_list, finish_reason)
    """
    clean_text = raw_text
    reasoning_content = None
    tool_calls = []
    finish_reason = "stop"

    # 1. Extract Reasoning / Thoughts
    thought_matches = re.finditer(r"(?:<\|?channel\|?>[a-zA-Z0-9_\-]*|<think>|<thought>|<\|thought\|?>)(.*?)(?:<\|?/channel\|?>|</think>|</thought>|<\|?endofthought\|?>|$)", clean_text, flags=re.DOTALL | re.IGNORECASE)
    thought_parts = []
    for m in thought_matches:
        t = m.group(1).strip()
        if t:
            thought_parts.append(t)
    if thought_parts:
        reasoning_content = "\n\n".join(thought_parts)

    # Remove all thoughts from clean_text
    clean_text = re.sub(r"(?:<\|?channel\|?>[a-zA-Z0-9_\-]*|<think>|<thought>|<\|thought\|?>)(.*?)(?:<\|?/channel\|?>|</think>|</thought>|<\|?endofthought\|?>|$)", "", clean_text, flags=re.DOTALL | re.IGNORECASE)

    # 2. Extract Tool Calls
    tool_matches = re.finditer(r"(?:<\|?tool_call\|?>|<\|?tool_code\|?>)(.*?)(?:<\|?/tool_call\|?>|<\|?/tool_code\|?>|$)", clean_text, flags=re.DOTALL | re.IGNORECASE)
    for m in tool_matches:
        parsed = parse_single_tool_call(m.group(1))
        if parsed:
            tool_calls.append(parsed)

    # Remove all tool calls from clean_text
    clean_text = re.sub(r"(?:<\|?tool_call\|?>|<\|?tool_code\|?>)(.*?)(?:<\|?/tool_call\|?>|<\|?/tool_code\|?>|$)", "", clean_text, flags=re.DOTALL | re.IGNORECASE)

    # 3. Final scrub of any dangling wrapper tags
    clean_text = re.sub(r"<\|?channel\|?>[a-zA-Z0-9_\-]*", "", clean_text, flags=re.IGNORECASE)
    clean_text = re.sub(r"<\|?/channel\|?>", "", clean_text, flags=re.IGNORECASE)
    clean_text = re.sub(r"<\|?tool_call\|?>", "", clean_text, flags=re.IGNORECASE)
    clean_text = re.sub(r"<\|?/tool_call\|?>", "", clean_text, flags=re.IGNORECASE)
    clean_text = re.sub(r"<\|?thought\|?>", "", clean_text, flags=re.IGNORECASE)
    clean_text = re.sub(r"<\|?/thought\|?>", "", clean_text, flags=re.IGNORECASE)
    clean_text = re.sub(r"</?think>", "", clean_text, flags=re.IGNORECASE)
    clean_text = clean_text.strip()

    if tool_calls:
        finish_reason = "tool_calls"
        if not clean_text:
            clean_text = None

    return clean_text, reasoning_content, tool_calls, finish_reason

# -----------------------------------------------------------------------------
# Endpoints
# -----------------------------------------------------------------------------
@app.get("/health")
@app.get("/health/readiness")
@app.get("/health/liveliness")
async def health():
    return {
        "status": "healthy" if MLX_AVAILABLE else "degraded",
        "mlx_available": MLX_AVAILABLE,
        "import_error": MLX_IMPORT_ERROR,
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
        if model is None or tokenizer is None:
            raise HTTPException(status_code=500, detail=f"Model '{req.model}' could not be loaded into memory.")

        # Format messages using Jinja chat template if available on tokenizer
        messages_dicts = []
        for m in req.messages:
            msg = {"role": m.role, "content": m.content or ""}
            if m.tool_calls:
                msg["tool_calls"] = m.tool_calls
            if m.tool_call_id:
                msg["tool_call_id"] = m.tool_call_id
            if m.name:
                msg["name"] = m.name
            messages_dicts.append(msg)

        if hasattr(tokenizer, "apply_chat_template"):
            try:
                if req.tools:
                    prompt = tokenizer.apply_chat_template(
                        messages_dicts,
                        tools=req.tools,
                        tokenize=False,
                        add_generation_prompt=True
                    )
                else:
                    prompt = tokenizer.apply_chat_template(
                        messages_dicts,
                        tokenize=False,
                        add_generation_prompt=True
                    )
            except Exception:
                prompt = tokenizer.apply_chat_template(
                    messages_dicts,
                    tokenize=False,
                    add_generation_prompt=True
                )
        else:
            prompt = "\n".join([f"{m['role']}: {m['content']}" for m in messages_dicts]) + "\nassistant: "

        sampler = make_sampler(temp=req.temperature, top_p=req.top_p) if make_sampler else None

        if req.stream:
            async def stream_generator():
                try:
                    created_ts = int(time.time())
                    generator = None
                    if hasattr(mlx_lm, "stream_generate"):
                        kwargs = {"max_tokens": req.max_tokens or 2048}
                        if sampler:
                            kwargs["sampler"] = sampler
                        else:
                            kwargs["temp"] = req.temperature
                            kwargs["top_p"] = req.top_p

                        generator = mlx_lm.stream_generate(
                            model=model,
                            tokenizer=tokenizer,
                            prompt=prompt,
                            **kwargs
                        )
                    elif generate_step is not None:
                        generator = generate_step(
                            prompt=tokenizer.encode(prompt),
                            model=model,
                            temp=req.temperature,
                            top_p=req.top_p,
                            max_tokens=req.max_tokens or 2048,
                            sampler=sampler
                        )

                    # Robust state machine for streaming
                    mode = "CONTENT"  # "CONTENT", "THOUGHT", "TOOL"
                    buf = ""
                    tool_buf = ""
                    accumulated_raw = []
                    tool_calls_emitted = []

                    for response in (generator or []):
                        if hasattr(response, "text"):
                            token_text = response.text
                        elif isinstance(response, tuple):
                            token_text = response[1]
                        else:
                            token_text = str(response)

                        accumulated_raw.append(token_text)
                        buf += token_text

                        # Process transitions
                        while buf:
                            if mode == "CONTENT":
                                # Check for thought open
                                m_thought = RE_OPEN_THOUGHT.search(buf)
                                m_tool = RE_OPEN_TOOL.search(buf)

                                if m_thought and (not m_tool or m_thought.start() < m_tool.start()):
                                    before = buf[:m_thought.start()]
                                    if before:
                                        chunk = {"id": f"chatcmpl-{created_ts}", "object": "chat.completion.chunk", "created": created_ts, "model": req.model, "choices": [{"index": 0, "delta": {"content": before}, "finish_reason": None}]}
                                        yield f"data: {json.dumps(chunk)}\n\n"
                                    mode = "THOUGHT"
                                    buf = buf[m_thought.end():]
                                elif m_tool:
                                    before = buf[:m_tool.start()]
                                    if before:
                                        chunk = {"id": f"chatcmpl-{created_ts}", "object": "chat.completion.chunk", "created": created_ts, "model": req.model, "choices": [{"index": 0, "delta": {"content": before}, "finish_reason": None}]}
                                        yield f"data: {json.dumps(chunk)}\n\n"
                                    mode = "TOOL"
                                    tool_buf = ""
                                    buf = buf[m_tool.end():]
                                else:
                                    # Hold back buffer if it contains an unclosed '<'
                                    lt_idx = buf.find("<")
                                    if lt_idx != -1:
                                        if lt_idx > 0:
                                            before = buf[:lt_idx]
                                            chunk = {"id": f"chatcmpl-{created_ts}", "object": "chat.completion.chunk", "created": created_ts, "model": req.model, "choices": [{"index": 0, "delta": {"content": before}, "finish_reason": None}]}
                                            yield f"data: {json.dumps(chunk)}\n\n"
                                            buf = buf[lt_idx:]
                                        # If buf has '<' and length < 35 and no '>', wait for next token
                                        if ">" not in buf and len(buf) < 35:
                                            break
                                        else:
                                            # Tag closed but didn't match special tags, emit
                                            chunk = {"id": f"chatcmpl-{created_ts}", "object": "chat.completion.chunk", "created": created_ts, "model": req.model, "choices": [{"index": 0, "delta": {"content": buf}, "finish_reason": None}]}
                                            yield f"data: {json.dumps(chunk)}\n\n"
                                            buf = ""
                                    else:
                                        chunk = {"id": f"chatcmpl-{created_ts}", "object": "chat.completion.chunk", "created": created_ts, "model": req.model, "choices": [{"index": 0, "delta": {"content": buf}, "finish_reason": None}]}
                                        yield f"data: {json.dumps(chunk)}\n\n"
                                        buf = ""

                            elif mode == "THOUGHT":
                                m_close = RE_CLOSE_THOUGHT.search(buf)
                                if m_close:
                                    thought_txt = buf[:m_close.start()]
                                    if thought_txt:
                                        chunk = {"id": f"chatcmpl-{created_ts}", "object": "chat.completion.chunk", "created": created_ts, "model": req.model, "choices": [{"index": 0, "delta": {"reasoning_content": thought_txt}, "finish_reason": None}]}
                                        yield f"data: {json.dumps(chunk)}\n\n"
                                    mode = "CONTENT"
                                    buf = buf[m_close.end():]
                                else:
                                    lt_idx = buf.find("<")
                                    if lt_idx != -1:
                                        if lt_idx > 0:
                                            before = buf[:lt_idx]
                                            chunk = {"id": f"chatcmpl-{created_ts}", "object": "chat.completion.chunk", "created": created_ts, "model": req.model, "choices": [{"index": 0, "delta": {"reasoning_content": before}, "finish_reason": None}]}
                                            yield f"data: {json.dumps(chunk)}\n\n"
                                            buf = buf[lt_idx:]
                                        if ">" not in buf and len(buf) < 35:
                                            break
                                        else:
                                            chunk = {"id": f"chatcmpl-{created_ts}", "object": "chat.completion.chunk", "created": created_ts, "model": req.model, "choices": [{"index": 0, "delta": {"reasoning_content": buf}, "finish_reason": None}]}
                                            yield f"data: {json.dumps(chunk)}\n\n"
                                            buf = ""
                                    else:
                                        chunk = {"id": f"chatcmpl-{created_ts}", "object": "chat.completion.chunk", "created": created_ts, "model": req.model, "choices": [{"index": 0, "delta": {"reasoning_content": buf}, "finish_reason": None}]}
                                        yield f"data: {json.dumps(chunk)}\n\n"
                                        buf = ""

                            elif mode == "TOOL":
                                tool_buf += buf
                                buf = ""
                                m_tool_close = RE_CLOSE_TOOL.search(tool_buf)
                                if m_tool_close:
                                    call_txt = tool_buf[:m_tool_close.start()]
                                    parsed = parse_single_tool_call(call_txt)
                                    if parsed:
                                        tool_calls_emitted.append(parsed)
                                        chunk = {"id": f"chatcmpl-{created_ts}", "object": "chat.completion.chunk", "created": created_ts, "model": req.model, "choices": [{"index": 0, "delta": {"tool_calls": [parsed]}, "finish_reason": None}]}
                                        yield f"data: {json.dumps(chunk)}\n\n"
                                    mode = "CONTENT"
                                    buf = tool_buf[m_tool_close.end():]
                                    tool_buf = ""

                        await asyncio.sleep(0)

                    # Flush remaining buffer cleanly
                    if buf and mode == "CONTENT":
                        clean_buf = re.sub(r"<\|?[a-zA-Z0-9_\-]+(?:\|?>|/?>)", "", buf)
                        if clean_buf:
                            chunk = {"id": f"chatcmpl-{created_ts}", "object": "chat.completion.chunk", "created": created_ts, "model": req.model, "choices": [{"index": 0, "delta": {"content": clean_buf}, "finish_reason": None}]}
                            yield f"data: {json.dumps(chunk)}\n\n"
                    elif buf and mode == "THOUGHT":
                        clean_buf = re.sub(r"<\|?[a-zA-Z0-9_\-]+(?:\|?>|/?>)", "", buf)
                        if clean_buf:
                            chunk = {"id": f"chatcmpl-{created_ts}", "object": "chat.completion.chunk", "created": created_ts, "model": req.model, "choices": [{"index": 0, "delta": {"reasoning_content": clean_buf}, "finish_reason": None}]}
                            yield f"data: {json.dumps(chunk)}\n\n"

                    # Calculate finish reason from whole output
                    full_text = "".join(accumulated_raw)
                    _, _, total_tool_calls, finish_reason = parse_model_output(full_text)
                    final_chunk = {
                        "id": f"chatcmpl-{created_ts}",
                        "object": "chat.completion.chunk",
                        "created": created_ts,
                        "model": req.model,
                        "choices": [{
                            "index": 0,
                            "delta": {},
                            "finish_reason": finish_reason
                        }]
                    }
                    yield f"data: {json.dumps(final_chunk)}\n\n"
                    yield "data: [DONE]\n\n"
                finally:
                    manager.in_flight_requests -= 1

            return StreamingResponse(stream_generator(), media_type="text/event-stream")
        else:
            kwargs = {"max_tokens": req.max_tokens or 2048}
            if sampler:
                kwargs["sampler"] = sampler
            else:
                kwargs["temp"] = req.temperature
                kwargs["top_p"] = req.top_p

            generated_text = mlx_lm.generate(
                model=model,
                tokenizer=tokenizer,
                prompt=prompt,
                **kwargs
            )
            if hasattr(mx, "synchronize"):
                mx.synchronize()

            clean_content, reasoning_content, tool_calls, finish_reason = parse_model_output(generated_text)

            message_payload: Dict[str, Any] = {
                "role": "assistant",
                "content": clean_content
            }
            if reasoning_content:
                message_payload["reasoning_content"] = reasoning_content
            if tool_calls:
                message_payload["tool_calls"] = tool_calls

            return {
                "id": f"chatcmpl-{int(time.time())}",
                "object": "chat.completion",
                "created": int(time.time()),
                "model": req.model,
                "choices": [{
                    "index": 0,
                    "message": message_payload,
                    "finish_reason": finish_reason
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
