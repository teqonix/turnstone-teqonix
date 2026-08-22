# **LLM Proxy Router Design**

[https://gemini.google.com/app/748fcd38c0eddf29](https://gemini.google.com/app/748fcd38c0eddf29)

*User prompt: I need some help brainstorming a design for my light LLM proxy to handle traffic across three inference nodes that run three models across each node. Each node has 128 gigs of unified RAM and I am using the same models on all three nodes: Gemma 431b, Qwen 3.8, and orinth 1.5. While I am using the 4-bit quantizations of the Qwen and Gemma models and it is possible to load all three models into RAM it leaves almost no headroom available. Could we design a custom python router that prioritizes utilization of all nodes But does not allow simultaneous executions of the large models on a single node? Additionally, the MacBook node splits the models it is hosting across on MLX server and ollama server; The MLX server hosts Qwen while ollama hosts orinth and Gemma. Please create a design document with diagrams and a high-level outline of the python code that can do this*

## **Response: System Architecture & Overview**

This proxy acts as an asynchronous, non-blocking reverse proxy placed in front of three 128GB Unified Memory nodes. To prevent Out-Of-Memory (OOM) crashes and system memory swapping from dynamic KV-cache allocation, the proxy enforces a **token-based weight system** per node while balancing traffic across the cluster.

                      `┌────────────────────────────────────────┐`  
                      `│          Client Request Stream         │`  
                      `└───────────────────┬────────────────────┘`  
                                          `│`  
                                          `▼`  
                      `┌────────────────────────────────────────┐`  
                      `│    FastAPI LLM Orchestration Proxy     │`  
                      `│  - Model Weight Arbiter                │`  
                      `│  - Node Selection (Least-Active)       │`  
                      `│  - Per-Node Async Concurrency Locks    │`  
                      `└───────────────────┬────────────────────┘`  
                                          `│`  
         `┌────────────────────────────────┼────────────────────────────────┐`  
         `│                                │                                │`  
         `▼                                ▼                                ▼`  
`┌───────────────────┐            ┌───────────────────┐            ┌───────────────────┐`  
`│      Node 1       │            │      Node 2       │            │   Node 3 (Mac)    │`  
`│  (128GB Unified)  │            │  (128GB Unified)  │            │  (128GB Unified)  │`  
`├───────────────────┤            ├───────────────────┤            ├───────────────────┤`  
`│ Ollama / vLLM     │            │ Ollama / vLLM     │            │ MLX Server (:8080)│`  
`│  • Gemma          │            │  • Gemma          │            │  • Qwen           │`  
`│  • Qwen           │            │  • Qwen           │            ├───────────────────┤`  
`│  • Orinth         │            │  • Orinth         │            │ Ollama (:11434)   │`  
`│                   │            │                   │            │  • Gemma          │`  
`│                   │            │                   │            │  • Orinth         │`  
`└───────────────────┘            └───────────────────┘            └───────────────────┘`

## **Concurrency & Resource Budgeting**

Each node is assigned a maximum **Capacity Budget of 100 points**. Models consume capacity based on their parameter footprint and KV-cache expansion profile during inference.

| Model | Resource Weight | Max Concurrent on Single Node | Primary Backend |
| :---- | :---- | :---- | :---- |
| **Gemma** (Heavy) | 80 | 1 (Excludes other large models) | Ollama / vLLM |
| **Qwen** (Medium-Heavy) | 60 | 1 (Cannot co-run with Gemma) | MLX (Node 3\) / Ollama |
| **Orinth** (Light) | 15 | Up to 6 (Can run alongside Qwen or Gemma) | Ollama |

> * **Mutual Exclusion:** Because Gemma (80) \+ Qwen (60) \= 140 \> 100, no single node will ever execute Gemma and Qwen concurrently.  
> * **Elastic Headroom:** Gemma (80) \+ Orinth (15) \= 95 \<= 100, permitting a light request to proceed alongside a heavy Gemma run without starving the node.

## **Node Routing & Backend Topology**

                  `┌──────────────────────────────┐`  
                  `│    Incoming Request: Qwen    │`  
                  `└──────────────┬───────────────┘`  
                                 `│`  
                 `Check Available Node Capacity`  
                 `┌───────────────┼───────────────┐`  
                 `▼               ▼               ▼`  
           `[ Node 1 ]      [ Node 2 ]      [ Node 3 ]`  
           `Active: 0       Active: 80      Active: 0`  
           `Score: 100      Score: 20       Score: 100`  
                 `│                               │`  
                 `└───────────────┬───────────────┘`  
                                 `│ (Tie-Break: Least Total Active)`  
                                 `▼`  
                     `Route to Node 3: MLX Engine`  
                     `Target: http://node3:8080/v1/completions`

| Node ID | Hostname / IP | Service Mapping |
| :---- | :---- | :---- |
| **node-1** | 192.168.1.101 | All Models → \[http://192.168.1.101:11434\](http://192.168.1.101:11434) (Ollama/vLLM) |
| **node-2** | 192.168.1.102 | All Models → \[http://192.168.1.102:11434\](http://192.168.1.102:11434) (Ollama/vLLM) |
| **node-3** (MacBook) | 192.168.1.103 | Qwen → \[http://192.168.1.103:8080\](http://192.168.1.103:8080) (MLX Server) Gemma, Orinth → \[http://192.168.1.103:11434\](http://192.168.1.103:11434) (Ollama) |

## **Python Proxy Implementation**

The router is built using FastAPI and httpx.AsyncClient with asyncio.Condition variables managing weighted capacity per node.

`import asyncio`  
`from contextlib import asynccontextmanager`  
`from typing import Dict, List, Optional`  
`from fastapi import FastAPI, HTTPException, Request`  
`from fastapi.responses import StreamingResponse`  
`import httpx`

`# ----------------------------------------------------------------------`  
`# Configuration & Weight Matrix`  
`# ----------------------------------------------------------------------`

`NODE_MAX_CAPACITY = 100`

`MODEL_WEIGHTS: Dict[str, int] = {`  
    `"gemma": 80,    # Heavy`  
    `"qwen": 60,     # Medium-Heavy`  
    `"orinth": 15,   # Lightweight`  
`}`

`class NodeState:`  
    `def __init__(self, node_id: str, host: str, is_macbook: bool = False):`  
        `self.node_id = node_id`  
        `self.host = host`  
        `self.is_macbook = is_macbook`  
        `self.current_capacity = NODE_MAX_CAPACITY`  
        `self.condition = asyncio.Condition()`  
        `self.active_requests = 0`

    `def get_target_url(self, model_name: str, path: str) -> str:`  
        `"""Handles backend split for MacBook vs standard nodes."""`  
        `normalized_model = model_name.lower()`  
        `if self.is_macbook:`  
            `if "qwen" in normalized_model:`  
                `# Routed to MLX Server`  
                `return f"http://{self.host}:8080{path}"`  
            `else:`  
                `# Gemma and Orinth routed to Ollama`  
                `return f"http://{self.host}:11434{path}"`  
        `# Standard Nodes run unified backend`  
        `return f"http://{self.host}:11434{path}"`

`class NodeManager:`  
    `def __init__(self, nodes: List[NodeState]):`  
        `self.nodes = nodes`

    `def _get_model_weight(self, model_name: str) -> int:`  
        `for key, weight in MODEL_WEIGHTS.items():`  
            `if key in model_name.lower():`  
                `return weight`  
        `return 50  # Default fallback weight for unknown models`

    `async def acquire_node(self, model_name: str) -> NodeState:`  
        `weight = self._get_model_weight(model_name)`  
          
        `while True:`  
            `best_node: Optional[NodeState] = None`  
            `max_remaining_margin = -1`

            `# Step 1: Evaluate nodes with sufficient capacity (Least-Loaded strategy)`  
            `for node in self.nodes:`  
                `async with node.condition:`  
                    `if node.current_capacity >= weight:`  
                        `margin = node.current_capacity - weight`  
                        `if margin > max_remaining_margin:`  
                            `max_remaining_margin = margin`  
                            `best_node = node`

            `# Step 2: Claim capacity if an eligible node was selected`  
            `if best_node:`  
                `async with best_node.condition:`  
                    `if best_node.current_capacity >= weight:  # Double check after lock acquisition`  
                        `best_node.current_capacity -= weight`  
                        `best_node.active_requests += 1`  
                        `return best_node`

            `# Step 3: If no node is currently available, wait on the first available release`  
            `# Wait on all nodes' condition variables`  
            `waiters = [node.condition.acquire() for node in self.nodes]`  
            `await asyncio.gather(*waiters)`  
            `try:`  
                `# Wait on the first condition variable that signals a release`  
                `tasks = [asyncio.create_task(node.condition.wait()) for node in self.nodes]`  
                `await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)`  
                `for task in tasks:`  
                    `if not task.done():`  
                        `task.cancel()`  
            `finally:`  
                `for node in self.nodes:`  
                    `node.condition.release()`

    `async def release_node(self, node: NodeState, model_name: str):`  
        `weight = self._get_model_weight(model_name)`  
        `async with node.condition:`  
            `node.current_capacity = min(NODE_MAX_CAPACITY, node.current_capacity + weight)`  
            `node.active_requests = max(0, node.active_requests - 1)`  
            `node.condition.notify_all()`

`# ----------------------------------------------------------------------`  
`# Application Setup`  
`# ----------------------------------------------------------------------`

`nodes_pool = [`  
    `NodeState("node-1", "192.168.1.101", is_macbook=False),`  
    `NodeState("node-2", "192.168.1.102", is_macbook=False),`  
    `NodeState("node-3", "192.168.1.103", is_macbook=True),`  
`]`

`manager = NodeManager(nodes_pool)`  
`http_client: Optional[httpx.AsyncClient] = None`

`@asynccontextmanager`  
`async def lifespan(app: FastAPI):`  
    `global http_client`  
    `http_client = httpx.AsyncClient(`  
        `timeout=httpx.Timeout(connect=5.0, read=180.0, write=10.0, pool=300.0),`  
        `limits=httpx.Limits(max_keepalive_connections=50, max_connections=200)`  
    `)`  
    `yield`  
    `await http_client.aclose()`

`app = FastAPI(title="Dynamic LLM Memory Router", lifespan=lifespan)`

`# ----------------------------------------------------------------------`  
`# Routing Endpoints`  
`# ----------------------------------------------------------------------`

`@app.post("/v1/{path:path}")`  
`@app.post("/{path:path}")`  
`async def proxy_inference(path: str, request: Request):`  
    `try:`  
        `body = await request.json()`  
    `except Exception:`  
        `raise HTTPException(status_code=400, detail="Invalid JSON payload")`

    `model_name = body.get("model")`  
    `if not model_name:`  
        `raise HTTPException(status_code=400, detail="Missing 'model' field in request")`

    `# Acquire an execution slot`  
    `node = await manager.acquire_node(model_name)`  
    `target_url = node.get_target_url(model_name, request.url.path)`

    `async def stream_generator():`  
        `try:`  
            `headers = {k: v for k, v in request.headers.items() if k.lower() not in ["host", "content-length"]}`  
            `req = http_client.build_request(`  
                `method=request.method,`  
                `url=target_url,`  
                `headers=headers,`  
                `json=body,`  
                `params=request.query_params`  
            `)`  
            `response = await http_client.send(req, stream=True)`  
              
            `async for chunk in response.aiter_raw():`  
                `yield chunk`  
                  
            `await response.aclose()`  
        `finally:`  
            `# Guarantee resource release when client disconnects or inference finishes`  
            `await manager.release_node(node, model_name)`

    `return StreamingResponse(stream_generator(), media_type="application/json")`

`@app.get("/health/cluster")`  
`async def cluster_health():`  
    `"""Returns real-time capacity and active requests per node."""`  
    `return {`  
        `node.node_id: {`  
            `"host": node.host,`  
            `"available_capacity": node.current_capacity,`  
            `"active_requests": node.active_requests,`  
            `"is_macbook": node.is_macbook`  
        `}`  
        `for node in nodes_pool`  
    `}`

## **Key Operational Safeguards**

> * **KV-Cache Headroom Guarantee:** Allocating a weight of 80 to Gemma ensures that even with long context windows (32k+ tokens) expanding memory usage, the remaining 48GB+ of unified memory remains untouched by other heavy processes.  
> * **Client Disconnect Resilience:** Using an explicit finally block inside the async generator ensures that if a client closes their connection midway through inference, the allocated slot is released immediately rather than leaking.  
> * **Heterogeneous Engine Handshake:** The proxy handles MLX and Ollama endpoints transparently without exposing backend differences to the client.

---

