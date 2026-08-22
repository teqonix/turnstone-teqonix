import litellm
from litellm.integrations.custom_logger import CustomLogger
from litellm.types.router import RoutingContext
from typing import Optional, List, Dict, Any
import threading
import logging
import sys

# ----------------------------------------------------------------------
# Real-Time Logger Setup (Forwarded to stdout / journalctl)
# ----------------------------------------------------------------------
logger = logging.getLogger("hardware_group_router")
logger.setLevel(logging.INFO)

# Ensure a dedicated stream handler outputs directly to stdout with flush
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

class WeightedRequestTracker:
    def __init__(self):
        self.node_loads: Dict[str, int] = {
            "NODE_RYZEN_ONE": 0,
            "NODE_RYZEN_TWO": 0,
            "NODE_MBP": 0,
            "UNKNOWN": 0
        }
        self.active_calls: Dict[str, tuple[str, int]] = {}
        self.lock = threading.Lock()

    def get_model_weight(self, model_name: Optional[str]) -> int:
        if not model_name:
            return DEFAULT_MODEL_WEIGHT
        norm = str(model_name).lower()
        for key, weight in MODEL_WEIGHTS.items():
            if key in norm:
                return weight
        return DEFAULT_MODEL_WEIGHT

    def format_loads(self) -> str:
        r1 = self.node_loads.get("NODE_RYZEN_ONE", 0)
        r2 = self.node_loads.get("NODE_RYZEN_TWO", 0)
        mbp = self.node_loads.get("NODE_MBP", 0)
        return f"[Ryzen1: {r1}/{NODE_MAX_CAPACITY} | Ryzen2: {r2}/{NODE_MAX_CAPACITY} | MBP: {mbp}/{NODE_MAX_CAPACITY}]"

    def format_available(self) -> str:
        r1 = max(0, NODE_MAX_CAPACITY - self.node_loads.get("NODE_RYZEN_ONE", 0))
        r2 = max(0, NODE_MAX_CAPACITY - self.node_loads.get("NODE_RYZEN_TWO", 0))
        mbp = max(0, NODE_MAX_CAPACITY - self.node_loads.get("NODE_MBP", 0))
        return f"[Ryzen1: {r1} cap left | Ryzen2: {r2} cap left | MBP: {mbp} cap left]"

    def increment(self, call_id: Optional[str], node: str, weight: int):
        with self.lock:
            if node in self.node_loads:
                self.node_loads[node] += weight
            if call_id:
                self.active_calls[call_id] = (node, weight)
            logger.info(f"[START] +{weight} on {node} (call_id={call_id}) | Active: {self.format_loads()}")
            sys.stdout.flush()

    def decrement(self, call_id: Optional[str], node: str, event_type: str = "COMPLETE", weight: Optional[int] = None):
        with self.lock:
            actual_node = node
            actual_weight = weight
            if call_id and call_id in self.active_calls:
                saved_node, saved_weight = self.active_calls.pop(call_id)
                actual_node = saved_node
                if actual_weight is None:
                    actual_weight = saved_weight
            
            if actual_weight is None:
                actual_weight = DEFAULT_MODEL_WEIGHT

            if actual_node in self.node_loads:
                self.node_loads[actual_node] = max(0, self.node_loads[actual_node] - actual_weight)
            logger.info(f"[{event_type}] -{actual_weight} on {actual_node} (call_id={call_id}) | Active: {self.format_loads()}")
            sys.stdout.flush()

    def get_loads(self) -> Dict[str, int]:
        with self.lock:
            return self.node_loads.copy()

tracker = WeightedRequestTracker()

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

def select_highest_priority_node(candidates: List[str]) -> str:
    """Pick the highest priority node from the candidates list according to NODE_PRIORITY_ORDER."""
    for node in NODE_PRIORITY_ORDER:
        if node in candidates:
            return node
    return candidates[0] if candidates else "UNKNOWN"

class HardwareGroupTrackerLogger(CustomLogger):
    def _extract_call_info(self, kwargs: dict) -> tuple[Optional[str], str, int]:
        call_id = kwargs.get("litellm_call_id") or kwargs.get("call_id")
        api_base = kwargs.get("api_base") or (kwargs.get("litellm_params") or {}).get("api_base")
        node = get_node_from_api_base(api_base)
        model = kwargs.get("model") or (kwargs.get("litellm_params") or {}).get("model") or kwargs.get("model_group")
        weight = tracker.get_model_weight(model)
        return call_id, node, weight

    def log_pre_api_call(self, kwargs, completion_kwargs):
        call_id, node, weight = self._extract_call_info(kwargs)
        tracker.increment(call_id, node, weight)

    def log_success_event(self, kwargs, response_obj, start_time, end_time):
        call_id, node, weight = self._extract_call_info(kwargs)
        tracker.decrement(call_id, node, event_type="SUCCESS", weight=weight)

    def log_failure_event(self, kwargs, response_obj, start_time, end_time):
        call_id, node, weight = self._extract_call_info(kwargs)
        tracker.decrement(call_id, node, event_type="FAILURE", weight=weight)

if not getattr(litellm, "callbacks", None):
    litellm.callbacks = []
litellm.callbacks.append(HardwareGroupTrackerLogger())

class HardwareGroupPlugin:
    async def run(self, context: RoutingContext) -> RoutingContext:
        deployments = context.candidate_models
        if not deployments:
            return context

        # Identify requested model name & weight
        requested_model = getattr(context, "model_name", None)
        if not requested_model and isinstance(deployments[0], dict):
            requested_model = deployments[0].get("model_name")
        weight = tracker.get_model_weight(requested_model)

        node_deployments: Dict[str, list] = {
            "NODE_RYZEN_ONE": [],
            "NODE_RYZEN_TWO": [],
            "NODE_MBP": [],
            "UNKNOWN": []
        }

        for deployment in deployments:
            litellm_params = deployment.get("litellm_params", {}) if isinstance(deployment, dict) else {}
            api_base = litellm_params.get("api_base", "")
            node = get_node_from_api_base(api_base)
            node_deployments[node].append(deployment)

        current_loads = tracker.get_loads()

        # Step 1: Find eligible nodes that have capacity budget: current_load + weight <= NODE_MAX_CAPACITY
        eligible_nodes = []
        for node in NODE_PRIORITY_ORDER:
            if node_deployments[node]:
                if current_loads[node] + weight <= NODE_MAX_CAPACITY:
                    eligible_nodes.append(node)

        # Step 2: If eligible nodes exist, pick the least-loaded node, tie-breaking by NODE_PRIORITY_ORDER
        if eligible_nodes:
            eligible_nodes.sort(key=lambda n: current_loads[n])
            min_load = current_loads[eligible_nodes[0]]
            candidates_with_min_load = [n for n in eligible_nodes if current_loads[n] == min_load]
            chosen_node = select_highest_priority_node(candidates_with_min_load)
            
            logger.info(
                f"[ROUTE] Model='{requested_model}' (Weight={weight}) -> Selected '{chosen_node}' "
                f"| Eligible: {eligible_nodes} | {tracker.format_available()}"
            )
            sys.stdout.flush()
            context.candidate_models = [node_deployments[chosen_node][0]]
            return context

        # Step 3: If no node is below capacity, fallback to node with least current load, tie-breaking by priority
        all_available_nodes = [n for n in NODE_PRIORITY_ORDER if node_deployments[n]]
        if all_available_nodes:
            all_available_nodes.sort(key=lambda n: current_loads[n])
            min_load = current_loads[all_available_nodes[0]]
            candidates_with_min_load = [n for n in all_available_nodes if current_loads[n] == min_load]
            chosen_node = select_highest_priority_node(candidates_with_min_load)
            
            logger.warning(
                f"[OVER-BUDGET ROUTE] Model='{requested_model}' (Weight={weight}) exceeds headroom on all nodes! "
                f"Routing to '{chosen_node}' | {tracker.format_loads()}"
            )
            sys.stdout.flush()
            context.candidate_models = [node_deployments[chosen_node][0]]
            return context

        return context

hardware_group_plugin = HardwareGroupPlugin()
