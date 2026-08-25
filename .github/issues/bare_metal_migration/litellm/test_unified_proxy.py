import pytest
import asyncio
from unittest.mock import AsyncMock, patch, MagicMock

# We need to set env vars before importing the module to ensure deterministic testing
import os
os.environ["NODE_RYZEN_ONE"] = "http://ryzen1"
os.environ["NODE_RYZEN_TWO"] = "http://ryzen2"
os.environ["NODE_MBP_OLLAMA"] = "http://mac"
os.environ["COOLDOWN_SECONDS"] = "30.0"

from unified_proxy import UnifiedProxyManager, is_heavy_model, COOLDOWN_SECONDS

@pytest.fixture
def manager():
    mgr = UnifiedProxyManager()
    mgr.http_client = AsyncMock()
    return mgr

@pytest.mark.asyncio
async def test_metric_parsing_ryzen(manager):
    # Mock httpx GET responses
    mock_stats_res = MagicMock()
    mock_stats_res.status_code = 200
    mock_stats_res.json.return_value = {
        "memory_gb": 32.0,
        "gpu_percent": 85.5
    }

    mock_health_res = MagicMock()
    mock_health_res.status_code = 200
    mock_health_res.json.return_value = {
        "all_models_loaded": [
            {"model_name": "gemma-4-31B-it-GGUF-UD-Q4_K_XL"}
        ]
    }

    async def mock_get(url, timeout):
        if "system-stats" in url:
            return mock_stats_res
        elif "health" in url:
            return mock_health_res
        return MagicMock(status_code=404)

    manager.http_client.get = AsyncMock(side_effect=mock_get)
    
    with patch("os.getenv", return_value="128.0"):
        stats = await manager.fetch_ryzen_stats("http://ryzen1")
        
        assert stats["mem_utilization"] == 32.0 / 128.0
        assert stats["gpu_usage"] == 85.5
        assert stats["power_draw"] == 0.0
        assert stats["num_heavy"] == 1
        assert stats["num_small"] == 0
        assert stats["backend_url"] == "http://ryzen1"
        assert not stats["is_mac"]

@pytest.mark.asyncio
async def test_metric_parsing_mac(manager):
    # Mock SSH command response
    mock_proc = AsyncMock()
    mock_proc.returncode = 0
    
    # Simulate all-smi json structure
    all_smi_json = """
    {
        "memory": [{"utilization": 65.0}],
        "gpus": [{"utilization": 22.5}],
        "chassis": [{"total_power_watts": 45.2}]
    }
    """
    mock_proc.communicate.return_value = (all_smi_json.encode(), b"")

    # Mock Ollama API
    mock_ollama_res = MagicMock()
    mock_ollama_res.status_code = 200
    mock_ollama_res.json.return_value = {
        "models": [{"name": "qwen3.8-27B-GGUF-Q4_0"}]
    }
    manager.http_client.get = AsyncMock(return_value=mock_ollama_res)

    with patch("asyncio.create_subprocess_shell", return_value=mock_proc):
        stats = await manager.fetch_macos_stats()
        
        assert stats["mem_utilization"] == 0.65  # 65.0 / 100
        assert stats["gpu_usage"] == 22.5
        assert stats["power_draw"] == 45.2
        assert stats["num_heavy"] == 1
        assert stats["num_small"] == 0
        assert stats["backend_url"] == "http://mac"
        assert stats["is_mac"]

@pytest.mark.asyncio
async def test_routing_heavy_model_strict_limit(manager):
    # Scenario: User requests a heavy model (gemma).
    # Mac has 1 heavy model and is busy.
    # Ryzen 1 has 1 heavy model but is NOT busy.
    # Ryzen 2 has 0 models.
    # Expected: Should route to Ryzen 2 (safest, no swap needed) OR Ryzen 1 (swap allowed).
    # According to our priority, Ryzen 1 (swap) is lower priority than Ryzen 2 (empty).

    with patch.object(manager, "fetch_macos_stats") as mock_mac, \
         patch.object(manager, "fetch_ryzen_stats") as mock_ryzen:
        
        mock_mac.return_value = {
            "is_mac": True, "backend_url": "http://mac",
            "mem_utilization": 0.80, "gpu_usage": 90.0, "power_draw": 50,
            "num_heavy": 1, "num_small": 0, "loaded_models": ["qwen"],
            "in_flight": 1, "time_since_active": 5.0
        }
        
        # We need distinct mock returns for Ryzen 1 and 2
        async def mock_ryzen_stats(url):
            if url == "http://ryzen1":
                return {
                    "is_mac": False, "backend_url": "http://ryzen1",
                    "mem_utilization": 0.40, "gpu_usage": 0.0, "power_draw": 20,
                    "num_heavy": 1, "num_small": 0, "loaded_models": ["qwen"],
                    "in_flight": 0, "time_since_active": 60.0,
                    "has_matching_model": False, "is_computing": False, "cooldown_passed": True
                }
            else:
                return {
                    "is_mac": False, "backend_url": "http://ryzen2",
                    "mem_utilization": 0.10, "gpu_usage": 0.0, "power_draw": 15,
                    "num_heavy": 0, "num_small": 0, "loaded_models": [],
                    "in_flight": 0, "time_since_active": 999.0,
                    "has_matching_model": False, "is_computing": False, "cooldown_passed": True
                }
        
        mock_ryzen.side_effect = mock_ryzen_stats

        best = await manager.get_best_node("gemma-4")
        assert best is not None
        assert best["backend_url"] == "http://ryzen2"

@pytest.mark.asyncio
async def test_routing_heavy_model_swap(manager):
    # Scenario: Both Ryzen nodes have 1 heavy model loaded.
    # We want to load a NEW heavy model.
    # Mac is busy.
    # Ryzen 1 is idle and cooldown passed.
    # Ryzen 2 is computing.
    # Expected: Route to Ryzen 1 (it will perform a swap).

    with patch.object(manager, "fetch_macos_stats") as mock_mac, \
         patch.object(manager, "fetch_ryzen_stats") as mock_ryzen:
        
        mock_mac.return_value = {
            "is_mac": True, "backend_url": "http://mac",
            "mem_utilization": 0.80, "gpu_usage": 90.0, "power_draw": 50,
            "num_heavy": 1, "num_small": 0, "loaded_models": ["qwen"],
            "in_flight": 1, "time_since_active": 5.0,
            "has_matching_model": False, "is_computing": True, "cooldown_passed": False
        }
        
        async def mock_ryzen_stats(url):
            if url == "http://ryzen1":
                return {
                    "is_mac": False, "backend_url": "http://ryzen1",
                    "mem_utilization": 0.40, "gpu_usage": 0.0, "power_draw": 20,
                    "num_heavy": 1, "num_small": 0, "loaded_models": ["gemma-v1"],
                    "in_flight": 0, "time_since_active": 60.0,
                    "has_matching_model": False, "is_computing": False, "cooldown_passed": True
                }
            else:
                return {
                    "is_mac": False, "backend_url": "http://ryzen2",
                    "mem_utilization": 0.40, "gpu_usage": 80.0, "power_draw": 120,
                    "num_heavy": 1, "num_small": 0, "loaded_models": ["qwen-v1"],
                    "in_flight": 1, "time_since_active": 2.0,
                    "has_matching_model": False, "is_computing": True, "cooldown_passed": False
                }
        
        mock_ryzen.side_effect = mock_ryzen_stats

        best = await manager.get_best_node("llama3")  # A heavy model? Wait, llama is not in HEAVY_MODELS by default.
        # HEAVY_MODELS = ["gemma", "qwen"]
        # So I need to request gemma or qwen.
        best = await manager.get_best_node("gemma-4")
        assert best is not None
        assert best["backend_url"] == "http://ryzen1"
        assert best["is_computing"] is False
        assert best["cooldown_passed"] is True

@pytest.mark.asyncio
async def test_routing_at_capacity(manager):
    # Scenario: Request heavy model, but ALL nodes are busy computing.
    # Expected: get_best_node returns None.

    with patch.object(manager, "fetch_macos_stats") as mock_mac, \
         patch.object(manager, "fetch_ryzen_stats") as mock_ryzen:
        
        mock_mac.return_value = {
            "is_mac": True, "backend_url": "http://mac",
            "mem_utilization": 0.80, "gpu_usage": 90.0, "power_draw": 50,
            "num_heavy": 1, "num_small": 0, "loaded_models": ["qwen"],
            "in_flight": 1, "time_since_active": 5.0,
            "has_matching_model": False, "is_computing": True, "cooldown_passed": False
        }
        
        async def mock_ryzen_stats(url):
            return {
                "is_mac": False, "backend_url": url,
                "mem_utilization": 0.40, "gpu_usage": 90.0, "power_draw": 150,
                "num_heavy": 1, "num_small": 0, "loaded_models": ["qwen"],
                "in_flight": 1, "time_since_active": 5.0,
                "has_matching_model": False, "is_computing": True, "cooldown_passed": False
            }
        
        mock_ryzen.side_effect = mock_ryzen_stats

        best = await manager.get_best_node("gemma-4")
        assert best is None
