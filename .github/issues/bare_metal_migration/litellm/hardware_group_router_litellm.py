import litellm
from litellm.types.router import RoutingContext
from typing import Optional, List, Dict, Any
import logging
import sys
import httpx
import urllib.parse
import asyncio

# ----------------------------------------------------------------------
# Real-Time Logger Setup (Forwarded to stdout / journalctl)
# ----------------------------------------------------------------------
logger = logging.getLogger("hardware_group_router")
logger.setLevel(logging.INFO)

if not logger.handlers:
    handler = logging.StreamHandler(sys.stdout)
    handler.setLevel(logging.INFO)
    formatter = logging.Formatter(
        fmt="%(asctime)s [%(levelname)s] [HardwareGroupRouter] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S"
    )
    handler.setFormatter(formatter)
    logger.addHandler(handler)
    logger.propagate = False

# ----------------------------------------------------------------------
# Configuration & Weight Matrix (Capacity Budget: 100 per node)
# ----------------------------------------------------------------------
NODE_MAX_CAPACITY = 100

# Priority ordered list: lowest index is highest priority
NODE_PRIORITY_ORDER: List[str] = [
    "NODE_MBP",  # Apple silicon is still the best price / performance; always use it first
    "NODE_RYZEN_ONE",
    "NODE_RYZEN_TWO"
]

MODEL_WEIGHTS: Dict[str, int] = {
    "gemma": 80,    # Heavy (80) - Mutual exclusion with Qwen and Gemma
    "qwen": 60,     # Medium-Heavy (60) - Mutual exclusion with Gemma and Qwen
    "ornith": 15,   # Lightweight (15) - Can co-run with Gemma or Qwen (up to 6 concurrent)
    "orinth": 15,   # Lightweight (15) - Alias
}
DEFAULT_MODEL_WEIGHT = 50

def get_model_weight(model_name: Optional[str]) -> int:
    if not model_name:
        return DEFAULT_MODEL_WEIGHT
    norm = str(model_name).lower()
    for key, weight in MODEL_WEIGHTS.items():
        if key in norm:
            return weight
    return DEFAULT_MODEL_WEIGHT

def get_node_from_api_base(api_base: str) -> str:
    if not api_base:
        return "UNKNOWN"
    if "amd-ai-core-one.lan" in api_base or "192.168.1.101" in api_base:
        return "NODE_RYZEN_ONE"
    elif "amd-ai-core-two.lan" in api_base or "192.168.1.102" in api_base:
        return "NODE_RYZEN_TWO"
    elif "mbp-ai-core.lan" in api_base or "192.168.1.103" in api_base:
        return "NODE_MBP"
    return "UNKNOWN"

def get_health_url(api_base: str) -> str:
    if not api_base: return ""
    parsed = urllib.parse.urlparse(api_base)
    return f"{parsed.scheme}://{parsed.netloc}/health"

def select_highest_priority_node(candidates: List[str]) -> str:
    """Pick the highest priority node from the candidates list according to NODE_PRIORITY_ORDER."""
    for node in NODE_PRIORITY_ORDER:
        if node in candidates:
            return node
    return candidates[0] if candidates else "UNKNOWN"

class HardwareGroupPlugin:
    async def fetch_node_health(self, client: httpx.AsyncClient, node: str, url: str) -> tuple[str, dict]:
        try:
            res = await client.get(url, timeout=1.0)
            if res.status_code == 200:
                return node, res.json()
        except Exception as e:
            logger.debug(f"Failed to fetch health for {node} at {url}: {e}")
        return node, {}

    def get_node_load_from_health(self, health_data: dict) -> int:
        in_flight = health_data.get("in_flight_requests", 0)
        if in_flight <= 0:
            return 0
            
        weight = 0
        if "active_model" in health_data and health_data["active_model"]:
            weight = get_model_weight(health_data["active_model"])
        elif "current_heavy_model" in health_data and health_data["current_heavy_model"]:
            weight = get_model_weight(health_data["current_heavy_model"])
        elif "all_models_loaded" in health_data:
            for m_name in health_data["all_models_loaded"].keys():
                w = get_model_weight(m_name)
                if w > weight: weight = w
                
        if weight == 0:
            weight = DEFAULT_MODEL_WEIGHT
            
        return weight * in_flight

    async def run(self, context: RoutingContext) -> RoutingContext:
        deployments = context.candidate_models
        if not deployments:
            return context

        requested_model = getattr(context, "model_name", None)
        if not requested_model and isinstance(deployments[0], dict):
            requested_model = deployments[0].get("model_name")
        req_weight = get_model_weight(requested_model)

        node_deployments: Dict[str, list] = {
            "NODE_RYZEN_ONE": [],
            "NODE_RYZEN_TWO": [],
            "NODE_MBP": [],
            "UNKNOWN": []
        }
        
        health_urls = {}

        for deployment in deployments:
            litellm_params = deployment.get("litellm_params", {}) if isinstance(deployment, dict) else {}
            api_base = litellm_params.get("api_base", "")
            node = get_node_from_api_base(api_base)
            node_deployments[node].append(deployment)
            if node != "UNKNOWN" and not health_urls.get(node):
                h_url = get_health_url(api_base)
                if h_url:
                    health_urls[node] = h_url

        node_healths = {}
        async with httpx.AsyncClient() as client:
            tasks = [self.fetch_node_health(client, n, u) for n, u in health_urls.items()]
            results = await asyncio.gather(*tasks, return_exceptions=True)
            for res in results:
                if isinstance(res, tuple):
                    n, data = res
                    node_healths[n] = data

        current_loads = {n: self.get_node_load_from_health(node_healths.get(n, {})) for n in NODE_PRIORITY_ORDER}
        in_flight = {n: node_healths.get(n, {}).get("in_flight_requests", 0) for n in NODE_PRIORITY_ORDER}

        load_str = " | ".join([f"{n}: {current_loads[n]}/{NODE_MAX_CAPACITY} (reqs: {in_flight[n]})" for n in NODE_PRIORITY_ORDER])

        # Step 1: Find eligible nodes (have capacity budget)
        eligible_nodes = []
        for node in NODE_PRIORITY_ORDER:
            if node_deployments[node]:
                if current_loads[node] + req_weight <= NODE_MAX_CAPACITY:
                    eligible_nodes.append(node)

        # Strict Capacity Check: return empty list to trigger LiteLLM queueing
        if not eligible_nodes:
            logger.warning(f"[REJECT] Model='{requested_model}' (Weight={req_weight}). No nodes have capacity! {load_str}")
            sys.stdout.flush()
            context.candidate_models = [] 
            return context

        # Step 2: Check for TRULY idle nodes (in_flight_requests == 0) among eligible nodes
        idle_nodes = [n for n in eligible_nodes if in_flight[n] == 0]
        
        if idle_nodes:
            chosen_node = select_highest_priority_node(idle_nodes)
            logger.info(f"[ROUTE-IDLE] Model='{requested_model}' (Weight={req_weight}) -> Selected '{chosen_node}' | {load_str}")
            sys.stdout.flush()
            context.candidate_models = [node_deployments[chosen_node][0]]
            return context
            
        # Step 3: If no idle nodes, pack onto eligible node with least load (tie-breaking by priority)
        eligible_nodes.sort(key=lambda n: current_loads[n])
        min_load = current_loads[eligible_nodes[0]]
        candidates_with_min_load = [n for n in eligible_nodes if current_loads[n] == min_load]
        chosen_node = select_highest_priority_node(candidates_with_min_load)
        
        logger.info(f"[ROUTE-PACK] Model='{requested_model}' (Weight={req_weight}) -> Selected '{chosen_node}' | {load_str}")
        sys.stdout.flush()
        context.candidate_models = [node_deployments[chosen_node][0]]
        return context

# Note: HardwareGroupTrackerLogger was removed; we do dynamic polling instead.
hardware_group_plugin = HardwareGroupPlugin()
