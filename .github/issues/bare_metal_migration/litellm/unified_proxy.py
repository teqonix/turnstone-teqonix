import os
import json
import random
import logging
import asyncio
from typing import Dict, Any, List, Optional
from enum import Enum
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import StreamingResponse
import httpx
import uvicorn

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


# Pull from environment variables set in deploy script
NODE_RYZEN_ONE = os.getenv("NODE_RYZEN_ONE", "http://amd-ai-core-one.lan:13305")
NODE_RYZEN_TWO = os.getenv("NODE_RYZEN_TWO", "http://amd-ai-core-two.lan:13305")
NODE_MBP_SSH_USER = os.getenv("TURNSTONE_USER", "turnstone")
NODE_MBP_HOSTNAME = os.getenv("MBP_HOSTNAME", "mbp-ai-core.lan")
NODE_MBP_OLLAMA = os.getenv("NODE_MBP_OLLAMA", f"http://{NODE_MBP_HOSTNAME}:11434")
NODE_MBP_SSH = os.getenv("NODE_MBP_SSH", f"{NODE_MBP_SSH_USER}@{NODE_MBP_HOSTNAME}")

HEAVY_MODELS = ["gemma", "qwen"]

def is_heavy_model(model_name: str) -> bool:
    norm = model_name.lower()
    return any(h in norm for h in HEAVY_MODELS)


class UnifiedProxyManager:
    def __init__(self):
        self.http_client: Optional[httpx.AsyncClient] = None
        self.model_map: Dict[str, Dict[str, str]] = {}

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

    async def close_client(self):
        if self.http_client:
            await self.http_client.aclose()

    async def fetch_ryzen_stats(self, url: str) -> Dict[str, Any]:
        try:
            res_stats = await self.http_client.get(f"{url}/v1/system-stats", timeout=5.0)
            res_health = await self.http_client.get(f"{url}/v1/health", timeout=5.0)

            stats = res_stats.json() if res_stats.status_code == 200 else {}
            health = res_health.json() if res_health.status_code == 200 else {}

            memory_gb = stats.get("memory_gb", 0.0)
            total_ram = float(os.getenv("NODE_TOTAL_RAM_GB", "128.0"))
            mem_utilization = (memory_gb / total_ram) if total_ram > 0 else 0

            gpu_usage = stats.get("gpu_usage_percent", 0.0)
            power_draw = stats.get("power_draw_w", 0.0)

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
                "backend_url": url,
                "is_mac": False,
                "offline": True
            }

    async def fetch_macos_stats(self) -> Dict[str, Any]:
        try:
            proc = await asyncio.create_subprocess_shell(
                f"ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 {NODE_MBP_SSH} 'all-smi snapshot'",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
            stdout, stderr = await proc.communicate()
            if proc.returncode == 0:
                stats = json.loads(stdout.decode())

                mem_utilization = stats.get("memory_utilization", 0.0)
                gpu_usage = stats.get("gpu_utilization", 0.0)
                power_draw = stats.get("power_w", 0.0)

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
                "is_mac": True,
                "offline": True
            }

    async def get_best_node(self, model_name: str) -> Optional[str]:
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

            is_valid = False
            reason = ""
            if has_matching_model:
                is_valid = True
                reason = "Model already loaded in memory"
            elif is_heavy:
                if mem < 0.85 and (num_heavy + num_small <= 2):
                    is_valid = True
                    reason = "Eligible for heavy model swap"
                else:
                    reason = f"At capacity (RAM: {mem*100:.1f}%, Models: {num_heavy}h/{num_small}s)"
            else:
                if mem < 0.85:
                    is_valid = True
                    reason = "Eligible for light model"
                else:
                    reason = f"At capacity (RAM: {mem*100:.1f}%)"

            status_str = "VALID" if is_valid else "REJECTED"
            logger.info(f"  [{node_name}] {status_str} ({reason}) | RAM: {mem*100:.1f}%, GPU: {gpu:.1f}%, Power: {power:.1f}W | Loaded: {loaded}")

            if is_valid:
                valid_nodes.append(n)

        if not valid_nodes:
            logger.warning(f"No valid nodes available for '{model_name}'.")
            return None

        # Sort factors:
        # 1. Model already loaded in memory (highest priority to avoid cold swap)
        # 2. Busy penalty (demote busy nodes; if Mac is working on something, use available Ryzen nodes)
        # 3. Mac priority only when idle and model is heavy
        # 4. Resource metrics (GPU load, RAM utilization, power draw)
        def sort_key(n):
            loaded = n.get("loaded_models", [])
            has_model = any(norm_model in m.lower() or m.lower() in norm_model for m in loaded)
            gpu = n.get("gpu_usage", 0.0)
            num_models = n.get("num_heavy", 0) + n.get("num_small", 0)
            is_mac = n.get("is_mac", False)
            
            # Node is considered busy if GPU is actively computing or models are loaded
            is_busy = (gpu > 15.0) or (num_models > 0 and not has_model)

            # If Mac is busy, demote it so other available nodes take precedence
            mac_penalty = 1 if (is_mac and is_busy) else 0

            # If Mac is completely idle, give it priority for heavy models
            mac_idle_priority = 0 if (is_mac and not is_busy and is_heavy) else 1

            return (
                not has_model,          # 1. In-memory model match
                mac_penalty,            # 2. Avoid Mac if it is already working on something
                is_busy,                # 3. Prefer non-busy nodes
                mac_idle_priority,      # 4. Idle Mac priority for heavy models
                round(gpu, -1),         # 5. Lowest GPU load
                round(n.get("mem_utilization", 1.0), 2), # 6. Lowest RAM usage
                n.get("power_draw", 1000.0)
            )

        # Shuffle candidates first to distribute load evenly when all metrics are tied
        random.shuffle(valid_nodes)
        valid_nodes.sort(key=sort_key)
        best = valid_nodes[0]

        target = best.get("backend_url")
        best_name = "Mac (MBP - Ollama)" if best.get("is_mac") else best.get("backend_url")
        logger.info(f"--- Routing Decision: Selected [{best_name}] -> {target} ---")
        return target

manager = UnifiedProxyManager()

@asynccontextmanager
async def lifespan(app: FastAPI):
    manager.load_model_map()
    await manager.init_client()
    yield
    await manager.close_client()

app = FastAPI(title="Turnstone Unified Hardware Proxy", lifespan=lifespan)

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

    best_url = await manager.get_best_node(model_name)

    if not best_url:
        logger.warning(f"All nodes are busy (AT_CAPACITY). Rejecting request for {model_name}.")
        raise HTTPException(status_code=429, detail="All nodes are currently at capacity. Please try again later.")

    target_url = f"{best_url}/{path.lstrip('/')}"
    logger.info(f"Routing request for {model_name} to {target_url}")

    # Rewrite model name based on target node to prevent 404s
    if isinstance(body, dict) and "model" in body:
        norm_model = model_name.lower()
        backend_type = "mac_ollama" if NODE_MBP_OLLAMA in best_url else "lemonade"
            
        mapping = manager.model_map.get(backend_type, {})
        for key, target_model in mapping.items():
            if key in norm_model:
                body["model"] = target_model
                break

    headers = {k: v for k, v in request.headers.items() if k.lower() not in ["host", "content-length"]}

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
                        yield (line + "\n").encode("utf-8")
                finally:
                    await backend_res.aclose()
                    elapsed = asyncio.get_event_loop().time() - start_time
                    logger.info(f"Stream finished for {model_name} on {target_url} in {elapsed:.2f}s (Status: {backend_res.status_code})")
            return StreamingResponse(stream_generator(), status_code=backend_res.status_code, media_type="text/event-stream")
        else:
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

    except Exception as e:
        elapsed = asyncio.get_event_loop().time() - start_time
        logger.error(f"Error proxying request to {target_url} after {elapsed:.2f}s: {e}")
        raise HTTPException(status_code=502, detail=f"Backend communication failure: {str(e)}")


if __name__ == "__main__":
    port = int(os.getenv("PORT", "13306"))
    host = os.getenv("HOST", "0.0.0.0")
    logger.info(f"Starting Unified Hardware Proxy on {host}:{port}")
    uvicorn.run("unified_proxy:app", host=host, port=port, log_level="info")
