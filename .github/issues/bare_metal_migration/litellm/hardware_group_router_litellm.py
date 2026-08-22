import litellm
from litellm.integrations.custom_logger import CustomLogger
from litellm.types.router import RoutingContext
from typing import Optional, List, Dict, Union
import random
import threading
import logging

logger = logging.getLogger(__name__)

class ActiveRequestTracker:
    def __init__(self):
        self.node_loads = {"NODE_RYZEN_ONE": 0, "NODE_RYZEN_TWO": 0, "NODE_MBP": 0, "UNKNOWN": 0}
        self.lock = threading.Lock()

    def increment(self, node: str):
        if node in self.node_loads:
            with self.lock:
                self.node_loads[node] += 1

    def decrement(self, node: str):
        if node in self.node_loads:
            with self.lock:
                self.node_loads[node] = max(0, self.node_loads[node] - 1)

    def get_loads(self):
        with self.lock:
            return self.node_loads.copy()

tracker = ActiveRequestTracker()

def get_node_from_api_base(api_base: str) -> str:
    if not api_base:
        return "UNKNOWN"
    if "amd-ai-core-one.lan" in api_base:
        return "NODE_RYZEN_ONE"
    elif "amd-ai-core-two.lan" in api_base:
        return "NODE_RYZEN_TWO"
    elif "mbp-ai-core.lan" in api_base:
        return "NODE_MBP"
    return "UNKNOWN"

class HardwareGroupTrackerLogger(CustomLogger):
    def log_pre_api_call(self, kwargs, completion_kwargs):
        api_base = kwargs.get("api_base") or (kwargs.get("litellm_params") or {}).get("api_base")
        node = get_node_from_api_base(api_base)
        tracker.increment(node)

    def log_success_event(self, kwargs, response_obj, start_time, end_time):
        api_base = kwargs.get("api_base") or (kwargs.get("litellm_params") or {}).get("api_base")
        node = get_node_from_api_base(api_base)
        tracker.decrement(node)

    def log_failure_event(self, kwargs, response_obj, start_time, end_time):
        api_base = kwargs.get("api_base") or (kwargs.get("litellm_params") or {}).get("api_base")
        node = get_node_from_api_base(api_base)
        tracker.decrement(node)

if not getattr(litellm, "callbacks", None):
    litellm.callbacks = []
litellm.callbacks.append(HardwareGroupTrackerLogger())

class HardwareGroupPlugin:
    async def run(self, context: RoutingContext) -> RoutingContext:
        deployments = context.candidate_models
        if not deployments:
            return context

        node_deployments = {"NODE_RYZEN_ONE": [], "NODE_RYZEN_TWO": [], "NODE_MBP": [], "UNKNOWN": []}

        for deployment in deployments:
            litellm_params = deployment.get("litellm_params", {})
            api_base = litellm_params.get("api_base", "")
            node = get_node_from_api_base(api_base)
            node_deployments[node].append(deployment)

        current_loads = tracker.get_loads()
        logger.info(f"HardwareGroupPlugin loads: {current_loads}")

        mbp_deployments = node_deployments.get("NODE_MBP", [])
        if mbp_deployments and current_loads["NODE_MBP"] == 0:
            context.candidate_models = [mbp_deployments[0]]
            return context

        ryzen_one = node_deployments.get("NODE_RYZEN_ONE", [])
        ryzen_two = node_deployments.get("NODE_RYZEN_TWO", [])
        
        valid_fallback_nodes = []
        if ryzen_one:
            valid_fallback_nodes.append("NODE_RYZEN_ONE")
        if ryzen_two:
            valid_fallback_nodes.append("NODE_RYZEN_TWO")
            
        if not valid_fallback_nodes:
            if mbp_deployments:
                context.candidate_models = [mbp_deployments[0]]
                return context
            context.candidate_models = [deployments[0]]
            return context
            
        least_busy_node = valid_fallback_nodes[0]
        min_load = current_loads[least_busy_node]
        
        for node in valid_fallback_nodes[1:]:
            if current_loads[node] < min_load:
                min_load = current_loads[node]
                least_busy_node = node

        if len(valid_fallback_nodes) == 2 and current_loads["NODE_RYZEN_ONE"] == current_loads["NODE_RYZEN_TWO"]:
            least_busy_node = random.choice(["NODE_RYZEN_ONE", "NODE_RYZEN_TWO"])
            
        context.candidate_models = [node_deployments[least_busy_node][0]]
        return context

hardware_group_plugin = HardwareGroupPlugin()
