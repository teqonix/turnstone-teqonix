import pytest
import asyncio
import os
import time
from unittest.mock import AsyncMock, patch, MagicMock

os.environ["NODE_RYZEN_ONE"] = "http://ryzen1:13305"
os.environ["NODE_RYZEN_TWO"] = "http://ryzen2:13305"
os.environ["NODE_MBP_OLLAMA"] = "http://mac:11434"
os.environ["COOLDOWN_SECONDS"] = "30.0"

from service_watchdog import (
    LlmServiceWatchdog,
    _normalize_url,
    _extract_host,
)
from unified_proxy import app, manager


def test_normalize_url():
    assert _normalize_url("http://amd-ai-core-one.lan:13305/") == "http://amd-ai-core-one.lan:13305"
    assert _normalize_url("http://amd-ai-core-one.lan:13305/v1") == "http://amd-ai-core-one.lan:13305"
    assert _normalize_url("http://amd-ai-core-one.lan:13305/v1/") == "http://amd-ai-core-one.lan:13305"


def test_extract_host():
    assert _extract_host("http://amd-ai-core-one.lan:13305/v1") == "amd-ai-core-one.lan"
    assert _extract_host("http://192.168.1.50:8000") == "192.168.1.50"
    assert _extract_host("mbp-ai-core.lan") == "mbp-ai-core.lan"


def test_is_macos_backend():
    watchdog = LlmServiceWatchdog()
    assert watchdog.is_macos_backend("http://mbp-ai-core.lan:11434") is True
    assert watchdog.is_macos_backend("http://mac:11434") is True
    assert watchdog.is_macos_backend("http://mac:8000") is True
    assert watchdog.is_macos_backend("http://amd-ai-core-one.lan:13305") is False


def test_build_ssh_command():
    watchdog = LlmServiceWatchdog(ssh_user="turnstone")
    ryzen_cmd = watchdog.build_ssh_command("http://amd-ai-core-one.lan:13305/v1")
    assert "ssh " in ryzen_cmd
    assert "turnstone@amd-ai-core-one.lan" in ryzen_cmd
    assert "systemctl restart lemond.service" in ryzen_cmd

    mac_cmd = watchdog.build_ssh_command("http://mbp-ai-core.lan:11434")
    assert "turnstone@mbp-ai-core.lan" in mac_cmd
    assert "launchctl kickstart" in mac_cmd


def test_cooldown_logic():
    watchdog = LlmServiceWatchdog(cooldown_seconds=10.0)
    url = "http://amd-ai-core-one.lan:13305"
    assert watchdog.is_in_cooldown(url) is False
    assert watchdog.get_remaining_cooldown(url) == 0.0

    watchdog.last_restart_time[url] = time.time()
    assert watchdog.is_in_cooldown(url) is True
    assert watchdog.get_remaining_cooldown(url) > 0.0


@pytest.mark.asyncio
async def test_probe_node_health_ryzen():
    mock_client = AsyncMock()
    watchdog = LlmServiceWatchdog(http_client=mock_client)

    # 1. Healthy probe
    mock_res_ok = MagicMock()
    mock_res_ok.status_code = 200
    mock_res_ok.json.return_value = {"all_models_loaded": []}
    mock_client.get = AsyncMock(return_value=mock_res_ok)

    assert await watchdog.probe_node_health("http://ryzen1:13305") is True

    # 2. Wedged / unresponsive probe (HTTP 500 or timeout)
    mock_res_bad = MagicMock()
    mock_res_bad.status_code = 500
    mock_client.get = AsyncMock(return_value=mock_res_bad)

    assert await watchdog.probe_node_health("http://ryzen1:13305") is False

    # 3. Model still stuck after unload
    mock_res_stuck = MagicMock()
    mock_res_stuck.status_code = 200
    mock_res_stuck.json.return_value = {
        "all_models_loaded": [{"model_name": "gemma-4-31B"}]
    }
    mock_client.get = AsyncMock(return_value=mock_res_stuck)

    assert await watchdog.probe_node_health("http://ryzen1:13305", expected_unloaded_model="gemma-4-31B") is False


@pytest.mark.asyncio
async def test_restart_node_service_flow():
    mock_client = AsyncMock()
    watchdog = LlmServiceWatchdog(
        http_client=mock_client, cooldown_seconds=60.0, recovery_timeout=5.0
    )

    mock_proc = AsyncMock()
    mock_proc.returncode = 0
    mock_proc.communicate = AsyncMock(return_value=(b"Restarted", b""))

    # Initial probe succeeds after restart
    mock_res_ok = MagicMock()
    mock_res_ok.status_code = 200
    mock_res_ok.json.return_value = {"all_models_loaded": []}
    mock_client.get = AsyncMock(return_value=mock_res_ok)

    with patch("asyncio.create_subprocess_shell", return_value=mock_proc), \
         patch("asyncio.sleep", return_value=None):
        cb_called = False
        def on_rec():
            nonlocal cb_called
            cb_called = True

        success = await watchdog.restart_node_service(
            "http://ryzen1:13305", reason="Unit test restart", on_recovered_cb=on_rec
        )
        assert success is True
        assert cb_called is True
        assert watchdog.is_in_cooldown("http://ryzen1:13305") is True

        # Second restart immediately suppressed by cooldown
        success_suppressed = await watchdog.restart_node_service(
            "http://ryzen1:13305", reason="Second attempt"
        )
        assert success_suppressed is False


@pytest.mark.asyncio
async def test_handle_unload_failure():
    mock_client = AsyncMock()
    watchdog = LlmServiceWatchdog(http_client=mock_client, recovery_timeout=5.0)

    # If probe confirms node is wedged -> trigger restart
    with patch.object(watchdog, "probe_node_health", return_value=False), \
         patch.object(watchdog, "restart_node_service", return_value=True) as mock_restart:
        recovered = await watchdog.handle_unload_failure(
            "http://ryzen1:13305", "gemma", Exception("Unload timeout")
        )
        assert recovered is True
        mock_restart.assert_called_once()


@pytest.mark.asyncio
async def test_handle_runaway_request():
    mock_client = AsyncMock()
    mock_client.post = AsyncMock()
    watchdog = LlmServiceWatchdog(http_client=mock_client)

    with patch.object(watchdog, "restart_node_service", return_value=True) as mock_restart, \
         patch("service_watchdog.logger.warning") as mock_warning:
        recovered = await watchdog.handle_runaway_request(
            "http://ryzen1:13305", in_flight=2, stuck_seconds=650.0
        )
        assert recovered is True
        mock_restart.assert_not_called()
        mock_client.post.assert_not_called()
        mock_warning.assert_called_once()
        assert "Watchdog timer passed" in mock_warning.call_args[0][0]



def test_watchdog_endpoints():
    from fastapi.testclient import TestClient
    client = TestClient(app)

    res = client.get("/watchdog/status")
    assert res.status_code == 200
    data = res.json()
    assert "cooldown_seconds" in data
    assert "nodes" in data

    # Test manual restart endpoint
    with patch.object(manager.watchdog, "restart_node_service", return_value=True) as mock_restart:
        post_res = client.post("/watchdog/restart", json={"node": "http://ryzen1:13305", "reason": "Admin test"})
        assert post_res.status_code == 200
        assert post_res.json()["ok"] is True
