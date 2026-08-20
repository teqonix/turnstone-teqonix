import os
import re
import time
import asyncio
import logging
from typing import Dict, Optional, Callable, Any
from urllib.parse import urlparse
import httpx

logger = logging.getLogger("service_watchdog")

# Environment configurations with sensible defaults
WATCHDOG_SSH_USER = os.getenv("WATCHDOG_SSH_USER", os.getenv("TURNSTONE_USER", "turnstone"))
WATCHDOG_SSH_KEY = os.getenv("WATCHDOG_SSH_KEY", "")
WATCHDOG_COOLDOWN_SECONDS = float(os.getenv("WATCHDOG_COOLDOWN_SECONDS", "120.0"))
WATCHDOG_PROBE_TIMEOUT = float(os.getenv("WATCHDOG_PROBE_TIMEOUT", "5.0"))
WATCHDOG_RECOVERY_TIMEOUT = float(os.getenv("WATCHDOG_RECOVERY_TIMEOUT", "30.0"))
NODE_MBP_HOSTNAME = os.getenv("MBP_HOSTNAME", "mbp-ai-core.lan")


class LlmServiceWatchdog:
    def __init__(
        self,
        http_client: Optional[httpx.AsyncClient] = None,
        ssh_user: str = WATCHDOG_SSH_USER,
        ssh_key: str = WATCHDOG_SSH_KEY,
        cooldown_seconds: float = WATCHDOG_COOLDOWN_SECONDS,
        probe_timeout: float = WATCHDOG_PROBE_TIMEOUT,
        recovery_timeout: float = WATCHDOG_RECOVERY_TIMEOUT,
    ):
        self.http_client = http_client
        self.ssh_user = ssh_user
        self.ssh_key = ssh_key
        self.cooldown_seconds = cooldown_seconds
        self.probe_timeout = probe_timeout
        self.recovery_timeout = recovery_timeout
        self.last_restart_time: Dict[str, float] = {}

    def set_http_client(self, client: httpx.AsyncClient):
        self.http_client = client

    def is_in_cooldown(self, backend_url: str) -> bool:
        last = self.last_restart_time.get(backend_url, 0.0)
        return (time.time() - last) < self.cooldown_seconds

    def get_remaining_cooldown(self, backend_url: str) -> float:
        last = self.last_restart_time.get(backend_url, 0.0)
        remaining = self.cooldown_seconds - (time.time() - last)
        return max(0.0, remaining)

    def is_macos_backend(self, backend_url: str) -> bool:
        parsed = urlparse(backend_url)
        host = parsed.hostname or ""
        port = parsed.port or 80
        if port == 11434 or "mbp" in host.lower() or host.lower() == NODE_MBP_HOSTNAME.lower():
            return True
        return False

    def build_ssh_command(self, backend_url: str) -> str:
        parsed = urlparse(backend_url)
        host = parsed.hostname or backend_url.replace("http://", "").replace("https://", "").split(":")[0]
        ssh_target = f"{self.ssh_user}@{host}"

        ssh_opts = ["-o BatchMode=yes", "-o StrictHostKeyChecking=no", "-o ConnectTimeout=5"]
        if self.ssh_key:
            ssh_opts.append(f"-i {self.ssh_key}")
        opts_str = " ".join(ssh_opts)

        if self.is_macos_backend(backend_url):
            # macOS: Ollama launchd kickstart or pkill fallback
            remote_cmd = (
                "sudo /bin/launchctl kickstart -k system/com.turnstone.ollama 2>/dev/null "
                "|| sudo /usr/bin/pkill -f ollama"
            )
        else:
            # Ryzen: Lemonade systemd unit restart
            remote_cmd = "sudo /bin/systemctl restart lemond.service"

        return f"ssh {opts_str} {ssh_target} '{remote_cmd}'"

    async def probe_node_health(
        self, backend_url: str, expected_unloaded_model: Optional[str] = None
    ) -> bool:
        """
        Probes a node to check if its API is responsive.
        If expected_unloaded_model is provided, also verifies that the model is
        no longer reported as loaded. If it is still present, the node is considered wedged.
        """
        if not self.http_client:
            logger.warning("No HTTP client configured on watchdog; cannot probe node health.")
            return False

        try:
            if self.is_macos_backend(backend_url):
                # macOS Ollama endpoint
                res = await self.http_client.get(
                    f"{backend_url.rstrip('/')}/api/tags", timeout=self.probe_timeout
                )
                if res.status_code != 200:
                    return False
                if expected_unloaded_model:
                    try:
                        data = res.json()
                        models = data.get("models", [])
                        loaded = [m.get("name", "") for m in models if isinstance(m, dict)]
                        if any(expected_unloaded_model in m for m in loaded):
                            logger.warning(
                                f"Probe: Model {expected_unloaded_model} is still present in {backend_url} tags."
                            )
                            return False
                    except Exception:
                        pass
                return True
            else:
                # Ryzen Lemonade endpoint
                res = await self.http_client.get(
                    f"{backend_url.rstrip('/')}/v1/health", timeout=self.probe_timeout
                )
                if res.status_code != 200:
                    return False

                if expected_unloaded_model:
                    try:
                        data = res.json()
                        raw_loaded = data.get("all_models_loaded", [])
                        loaded = [
                            m.get("model_name", "") for m in raw_loaded if isinstance(m, dict)
                        ]
                        if any(expected_unloaded_model == m for m in loaded):
                            logger.warning(
                                f"Probe: Model {expected_unloaded_model} still loaded on {backend_url} after failed unload."
                            )
                            return False
                    except Exception:
                        pass
                return True
        except Exception as e:
            logger.warning(f"Probe health check failed on {backend_url}: {e}")
            return False

    async def restart_node_service(
        self,
        backend_url: str,
        reason: str,
        on_recovered_cb: Optional[Callable[[], Any]] = None,
    ) -> bool:
        """
        Executes remote restart via SSH and verifies recovery with polling.
        Enforces cooldown to prevent restart storms.
        """
        if self.is_in_cooldown(backend_url):
            remaining = self.get_remaining_cooldown(backend_url)
            logger.warning(
                f"Watchdog restart for {backend_url} suppressed: in cooldown for another {remaining:.1f}s (Reason: {reason})"
            )
            return False

        logger.error(
            f"[WATCHDOG] Node {backend_url} is unresponsive or wedged. Initiating forced service restart. Reason: {reason}"
        )
        self.last_restart_time[backend_url] = time.time()

        cmd = self.build_ssh_command(backend_url)
        logger.info(f"[WATCHDOG] Executing restart command: {cmd}")

        try:
            proc = await asyncio.create_subprocess_shell(
                cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
            )
            stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=15.0)
            if proc.returncode != 0:
                err_msg = stderr.decode().strip() if stderr else f"exit code {proc.returncode}"
                logger.error(f"[WATCHDOG] Failed to execute restart on {backend_url}: {err_msg}")
                return False
            logger.info(f"[WATCHDOG] Restart signal dispatched successfully to {backend_url}.")
        except asyncio.TimeoutError:
            logger.error(f"[WATCHDOG] SSH restart command timed out for {backend_url}.")
            return False
        except Exception as e:
            logger.error(f"[WATCHDOG] Error dispatching restart command to {backend_url}: {e}")
            return False

        # Poll for recovery
        logger.info(
            f"[WATCHDOG] Polling {backend_url} for recovery (up to {self.recovery_timeout}s)..."
        )
        start_poll = time.time()
        # Brief pause to let the service stop and start initializing
        await asyncio.sleep(3.0)

        recovered = False
        while (time.time() - start_poll) < self.recovery_timeout:
            healthy = await self.probe_node_health(backend_url)
            if healthy:
                elapsed = time.time() - start_poll
                logger.info(
                    f"[WATCHDOG] Node {backend_url} successfully recovered and responded in {elapsed:.1f}s."
                )
                recovered = True
                break
            await asyncio.sleep(2.0)

        if not recovered:
            logger.error(
                f"[WATCHDOG] Node {backend_url} did not recover within {self.recovery_timeout}s timeout."
            )
            return False

        if on_recovered_cb:
            try:
                res = on_recovered_cb()
                if asyncio.iscoroutine(res):
                    await res
            except Exception as e:
                logger.warning(f"[WATCHDOG] Error executing on_recovered_cb: {e}")

        return True

    async def handle_unload_failure(
        self,
        backend_url: str,
        model_name: str,
        error: Exception,
        on_recovered_cb: Optional[Callable[[], Any]] = None,
    ) -> bool:
        """
        Invoked when an idle model unload call fails.
        Performs confirmation probe and restarts node if wedged.
        """
        logger.warning(
            f"[WATCHDOG] Unload failed for model '{model_name}' on {backend_url}: {error}. Running confirmation probe..."
        )

        is_responsive = await self.probe_node_health(
            backend_url, expected_unloaded_model=model_name
        )
        if not is_responsive:
            logger.error(
                f"[WATCHDOG] Confirmation probe failed on {backend_url} (model stuck or server dead). Triggering restart."
            )
            return await self.restart_node_service(
                backend_url,
                reason=f"Failed to unload idle model '{model_name}': {error}",
                on_recovered_cb=on_recovered_cb,
            )
        else:
            logger.info(
                f"[WATCHDOG] Node {backend_url} confirmed responsive and model unloaded. No restart required."
            )
            return True

    async def handle_runaway_request(
        self,
        backend_url: str,
        in_flight: int,
        stuck_seconds: float,
        on_recovered_cb: Optional[Callable[[], Any]] = None,
    ) -> bool:
        """
        Invoked when in-flight requests on a node exceed timeout threshold.
        Attempts soft unload if possible, then verifies and forces restart.
        """
        logger.error(
            f"[WATCHDOG] Runaway request detected on {backend_url}. In-flight: {in_flight}, stuck for {stuck_seconds:.1f}s."
        )

        # Attempt soft unload if supported
        if not self.is_macos_backend(backend_url) and self.http_client:
            try:
                await self.http_client.post(
                    f"{backend_url.rstrip('/')}/v1/unload_all", timeout=5.0
                )
            except Exception:
                pass
            await asyncio.sleep(5.0)

        return await self.restart_node_service(
            backend_url,
            reason=f"Runaway requests ({in_flight}) stuck for {stuck_seconds:.1f}s",
            on_recovered_cb=on_recovered_cb,
        )
