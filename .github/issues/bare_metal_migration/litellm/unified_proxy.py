import os
import json
import logging
import asyncio
from typing import Dict, Any, List, Optional
from enum import Enum

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
NODE_MBP_MLX = os.getenv("NODE_MBP_MLX", "http://192.168.1.10:8000")
NODE_MBP_OLLAMA = os.getenv("NODE_MBP_OLLAMA", "http://192.168.1.10:11434")
NODE_RYZEN_ONE = os.getenv("NODE_RYZEN_ONE", "http://192.168.1.11:13305")
NODE_RYZEN_TWO = os.getenv("NODE_RYZEN_TWO", "http://192.168.1.12:13305")
NODE_MBP_SSH_USER = os.getenv("TURNSTONE_USER", "turnstone")
NODE_MBP_IP = os.getenv("MBP_IP", "192.168.1.10")
NODE_MBP_SSH = os.getenv("NODE_MBP_SSH", f"{NODE_MBP_SSH_USER}@{NODE_MBP_IP}")

HEAVY_MODELS = ["gemma", "qwen"]

def is_heavy_model(model_name: str) -> bool:
    norm = model_name.lower()
    return any(h in norm for h in HEAVY_MODELS)


class UnifiedProxyManager:
    def __init__(self):
        self.http_client: Optional[httpx.AsyncClient] = None

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

            loaded_models = health.get("all_models_loaded", [])
            num_heavy = sum(1 for m in loaded_models if is_heavy_model(m.get("model_name", "")))
            num_small = len(loaded_models) - num_heavy

            state = NodeState.AVAILABLE
            if num_heavy > 0:
                if mem_utilization > 0.7:  # < 30% available
                    state = NodeState.AT_CAPACITY
                elif num_small > 0:       # 1 heavy + 1 small
                    state = NodeState.AT_CAPACITY
                else:
                    state = NodeState.SMALL_ONLY

            return {
                "state": state,
                "gpu_usage": gpu_usage,
                "power_draw": power_draw,
                "backend_url": url
            }
        except Exception as e:
            logger.warning(f"Failed to fetch stats from {url}: {e}")
            return {"state": NodeState.AT_CAPACITY, "gpu_usage": 100, "power_draw": 1000, "backend_url": url}

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

                num_heavy = 0
                num_small = 0

                try:
                    mlx_res = await self.http_client.get(f"{NODE_MBP_MLX}/v1/models", timeout=2.0)
                    if mlx_res.status_code == 200:
                        mlx_models = mlx_res.json().get("data", [])
                        num_heavy += sum(1 for m in mlx_models if is_heavy_model(m.get("id", "")))
                        num_small += sum(1 for m in mlx_models if not is_heavy_model(m.get("id", "")))
                except Exception:
                    pass

                try:
                    ollama_res = await self.http_client.get(f"{NODE_MBP_OLLAMA}/api/ps", timeout=2.0)
                    if ollama_res.status_code == 200:
                        ollama_models = ollama_res.json().get("models", [])
                        num_heavy += sum(1 for m in ollama_models if is_heavy_model(m.get("name", "")))
                        num_small += sum(1 for m in ollama_models if not is_heavy_model(m.get("name", "")))
                except Exception:
                    pass

                state = NodeState.AVAILABLE
                if num_heavy > 0:
                    if mem_utilization > 0.7:
                        state = NodeState.AT_CAPACITY
                    elif num_small > 0:
                        state = NodeState.AT_CAPACITY
                    else:
                        state = NodeState.SMALL_ONLY

                return {
                    "state": state,
                    "gpu_usage": gpu_usage,
                    "power_draw": power_draw,
                    "backend_url_mlx": NODE_MBP_MLX,
                    "backend_url_ollama": NODE_MBP_OLLAMA,
                    "is_mac": True
                }
            else:
                logger.warning(f"Failed SSH to Mac: {stderr.decode()}")
                return {"state": NodeState.AT_CAPACITY, "is_mac": True}
        except Exception as e:
            logger.warning(f"Exception fetching Mac stats: {e}")
            return {"state": NodeState.AT_CAPACITY, "is_mac": True}

    async def get_best_node(self, model_name: str) -> Optional[str]:
        is_heavy = is_heavy_model(model_name)

        mac_task = self.fetch_macos_stats()
        ryzen1_task = self.fetch_ryzen_stats(NODE_RYZEN_ONE)
        ryzen2_task = self.fetch_ryzen_stats(NODE_RYZEN_TWO)

        mac_stats, ryzen1_stats, ryzen2_stats = await asyncio.gather(mac_task, ryzen1_task, ryzen2_task)

        nodes = [mac_stats, ryzen1_stats, ryzen2_stats]

        valid_nodes = []
        for n in nodes:
            if n.get("state") == NodeState.AVAILABLE:
                valid_nodes.append(n)
            elif n.get("state") == NodeState.SMALL_ONLY and not is_heavy:
                valid_nodes.append(n)

        if not valid_nodes:
            return None

        valid_nodes.sort(key=lambda x: (
            not x.get("is_mac", False),
            x.get("gpu_usage", 100),
            x.get("power_draw", 1000)
        ))

        best = valid_nodes[0]

        if best.get("is_mac"):
            if is_heavy:
                target_model = "mlx-community/Qwen3.8-27B-4bit" if "qwen" in model_name.lower() else "mlx-community/gemma-4-31B-it-4bit"
                logger.info(f"Issuing load command to MLX Server for {target_model}")
                try:
                    await self.http_client.post(
                        f"{best.get('backend_url_mlx')}/v1/chat/completions",
                        json={"model": target_model, "messages": [{"role": "user", "content": "load"}], "max_tokens": 1},
                        timeout=5.0
                    )
                except Exception as e:
                    logger.warning(f"Failed to issue pre-load command to Mac MLX: {e}")
                return best.get("backend_url_mlx")
            else:
                return best.get("backend_url_ollama")
        else:
            return best.get("backend_url")

manager = UnifiedProxyManager()

app = FastAPI(title="Turnstone Unified Hardware Proxy")

@app.on_event("startup")
async def startup():
    await manager.init_client()

@app.on_event("shutdown")
async def shutdown():
    await manager.close_client()

@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "OPTIONS", "HEAD", "PATCH"])
async def proxy_or_handle(path: str, request: Request):
    body = None
    model_name = ""

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
                    async for chunk in backend_res.aiter_raw():
                        yield chunk
                finally:
                    await backend_res.aclose()
            return StreamingResponse(stream_generator(), status_code=backend_res.status_code, media_type="text/event-stream")
        else:
            content = await backend_res.aread()
            await backend_res.aclose()
            headers = dict(backend_res.headers)
            headers.pop("content-length", None)
            headers.pop("content-encoding", None)
            return Response(content=content, status_code=backend_res.status_code, headers=headers)

    except Exception as e:
        logger.error(f"Error proxying request to {target_url}: {e}")
        raise HTTPException(status_code=502, detail=f"Backend communication failure: {str(e)}")


if __name__ == "__main__":
    port = int(os.getenv("PORT", "13306"))
    host = os.getenv("HOST", "0.0.0.0")
    logger.info(f"Starting Unified Hardware Proxy on {host}:{port}")
    uvicorn.run("unified_proxy:app", host=host, port=port, log_level="info")
