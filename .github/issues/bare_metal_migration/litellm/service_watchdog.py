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


def _normalize_url(backend_url: str) -> str:
    """Strips trailing slashes and redundant /v1 suffixes."""
    clean = backend_url.rstrip("/")
    if clean.endswith("/v1"):
        clean = clean[:-3]
    return clean


def _extract_host(backend_url: str) -> str:
    """Extracts hostname or IP address safely from backend URL."""
    parsed = urlparse(backend_url)
    if parsed.hostname:
        return parsed.hostname
    stripped = backend_url.replace("http://", "").replace("https://", "")
    return stripped.split("/")[0].split(":")[0]


class LlmServiceWatchdog:
    def __init__(
        self,
        http_client: Optional[httpx.AsyncClient] = None,
        ssh_user: str = WATCHDOG_SSH_USER,
        ssh_key: str = WATCHDOG_SSH_KEY,
        cooldown_seconds: float = WATCHDOG_COOLDOWN_SECONDS,
        probe_timeout: float = WATCHDOG_PROBE_TIMEOUT,
        recovery_timeout: float = WATCHDOG_RECOVERY_TIMEOUT,
        event_callback: Optional[Callable[[str, str, Dict[str, Any]], None]] = None,
    ):
        self.http_client = http_client
        self.ssh_user = ssh_user
        self.ssh_key = ssh_key
        self.cooldown_seconds = cooldown_seconds
        self.probe_timeout = probe_timeout
        self.recovery_timeout = recovery_timeout
        self.event_callback = event_callback
        self.last_restart_time: Dict[str, float] = {}
        self.health_unresponsive_since: Dict[str, float] = {}

    def set_http_client(self, client: httpx.AsyncClient):
        self.http_client = client

    def set_event_callback(self, callback: Callable[[str, str, Dict[str, Any]], None]):
        self.event_callback = callback

    def _emit(self, event_type: str, node: str, **payload):
        if self.event_callback:
            try:
                self.event_callback(event_type, node, payload)
            except Exception as e:
                logger.debug(f"Failed to emit watchdog event: {e}")

    def is_in_cooldown(self, backend_url: str) -> bool:
        norm_url = _normalize_url(backend_url)
        last = self.last_restart_time.get(norm_url, 0.0)
        return (time.time() - last) < self.cooldown_seconds

    def get_remaining_cooldown(self, backend_url: str) -> float:
        norm_url = _normalize_url(backend_url)
        last = self.last_restart_time.get(norm_url, 0.0)
        remaining = self.cooldown_seconds - (time.time() - last)
        return max(0.0, remaining)

    def is_macos_backend(self, backend_url: str) -> bool:
        parsed = urlparse(backend_url)
        host = parsed.hostname or _extract_host(backend_url)
        port = parsed.port or 80
        if (
            port == 11434
            or port == 8000
            or "mbp" in host.lower()
            or host.lower() == NODE_MBP_HOSTNAME.lower()
        ):
            return True
        return False

    def _resolve_ssh_key(self) -> str:
        if self.ssh_key and os.path.exists(self.ssh_key):
            return self.ssh_key
        # Check standard key locations
        candidate_paths = [
            "/etc/litellm/turnstone_ssh_key",
            os.path.expanduser("~/.ssh/id_ed25519"),
            os.path.expanduser("~/.ssh/id_rsa"),
        ]
        for p in candidate_paths:
            if os.path.isfile(p):
                return p
        return self.ssh_key or ""

    def build_ssh_command(self, backend_url: str) -> str:
        host = _extract_host(backend_url)
        ssh_target = f"{self.ssh_user}@{host}"

        ssh_opts = ["-o BatchMode=yes", "-o StrictHostKeyChecking=no", "-o ConnectTimeout=5"]
        key_to_use = self._resolve_ssh_key()
        if key_to_use:
            ssh_opts.append(f"-i {key_to_use}")
        opts_str = " ".join(ssh_opts)

        if self.is_macos_backend(backend_url):
            # macOS: Ollama launchd kickstart or pkill fallback
            remote_cmd = (
                "sudo /bin/launchctl kickstart -k system/com.turnstone.ollama 2>/dev/null "
                "|| sudo /usr/bin/pkill -f ollama"
            )
        else:
            # Ryzen: Lemonade systemd unit restart with fallbacks
            remote_cmd = (
                "sudo /bin/systemctl restart lemond.service 2>/dev/null "
                "|| sudo /bin/systemctl restart lemonade.service 2>/dev/null "
                "|| sudo /usr/bin/pkill -9 -f lemond"
            )

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

        clean_url = _normalize_url(backend_url)

        try:
            if self.is_macos_backend(clean_url):
                # macOS Ollama endpoint
                res = await self.http_client.get(
                    f"{clean_url}/api/tags", timeout=self.probe_timeout
                )
                if res.status_code != 200:
                    return False
                if expected_unloaded_model:
                    try:
                        data = res.json()
                        models = data.get("models", [])
                        loaded = [m.get("name", "") for m in models if isinstance(m, dict)]
                        if any(expected_unloaded_model.lower() in m.lower() for m in loaded):
                            logger.warning(
                                f"Probe: Model {expected_unloaded_model} is still present in {clean_url} tags."
                            )
                            return False
                    except Exception:
                        pass
                return True
            else:
                # Ryzen Lemonade endpoint
                health_ok = False
                health_data = None
                try:
                    res = await self.http_client.get(
                        f"{clean_url}/v1/health", timeout=self.probe_timeout
                    )
                    if res.status_code == 200:
                        health_ok = True
                        health_data = res.json()
                except Exception:
                    pass

                now = time.time()
                if health_ok:
                    self.health_unresponsive_since.pop(clean_url, None)
                else:
                    if clean_url not in self.health_unresponsive_since:
                        self.health_unresponsive_since[clean_url] = now
                    
                    unresponsive_time = now - self.health_unresponsive_since[clean_url]
                    if unresponsive_time >= 8 * 60:
                        logger.warning(
                            f"[WATCHDOG] Health endpoint /v1/health on {clean_url} has been inaccessible for {unresponsive_time:.1f}s (>= 8 minutes)."
                        )
                    
                    # Fallback to /live endpoint
                    try:
                        live_res = await self.http_client.get(
                            f"{clean_url}/live", timeout=self.probe_timeout
                        )
                        if live_res.status_code == 200:
                            live_data = live_res.json()
                            if live_data.get("status") != "ok":
                                return False
                        else:
                            return False
                    except Exception as e:
                        logger.warning(f"Probe health and live checks failed on {clean_url}: {e}")
                        return False

                if expected_unloaded_model and health_data:
                    try:
                        raw_loaded = health_data.get("all_models_loaded", [])
                        loaded = [
                            m.get("model_name", "") for m in raw_loaded if isinstance(m, dict)
                        ]
                        if any(expected_unloaded_model.lower() == m.lower() for m in loaded):
                            logger.warning(
                                f"Probe: Model {expected_unloaded_model} still loaded on {clean_url} after failed unload."
                            )
                            return False
                    except Exception:
                        pass
                return True
        except Exception as e:
            logger.warning(f"Probe health check failed on {clean_url}: {e}")
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
        norm_url = _normalize_url(backend_url)
        if self.is_in_cooldown(norm_url):
            remaining = self.get_remaining_cooldown(norm_url)
            logger.warning(
                f"[WATCHDOG] Restart for {norm_url} suppressed: in cooldown for another {remaining:.1f}s (Reason: {reason})"
            )
            return False

        logger.error(
            f"[WATCHDOG] Node {norm_url} is unresponsive or wedged. Initiating forced service restart. Reason: {reason}"
        )
        self.last_restart_time[norm_url] = time.time()
        self._emit("watchdog_restart", norm_url, reason=reason)

        cmd = self.build_ssh_command(norm_url)
        logger.info(f"[WATCHDOG] Executing restart command: {cmd}")

        try:
            proc = await asyncio.create_subprocess_shell(
                cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
            )
            stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=15.0)
            if proc.returncode != 0:
                err_msg = stderr.decode().strip() if stderr else f"exit code {proc.returncode}"
                logger.error(f"[WATCHDOG] Failed to execute restart on {norm_url}: {err_msg}")
                return False
            logger.info(f"[WATCHDOG] Restart signal dispatched successfully to {norm_url}.")
        except asyncio.TimeoutError:
            logger.error(f"[WATCHDOG] SSH restart command timed out for {norm_url}.")
            return False
        except Exception as e:
            logger.error(f"[WATCHDOG] Error dispatching restart command to {norm_url}: {e}")
            return False

        # Poll for recovery
        logger.info(
            f"[WATCHDOG] Polling {norm_url} for recovery (up to {self.recovery_timeout}s)..."
        )
        start_poll = time.time()
        # Brief pause to let the service stop and start initializing
        await asyncio.sleep(3.0)

        recovered = False
        while (time.time() - start_poll) < self.recovery_timeout:
            healthy = await self.probe_node_health(norm_url)
            if healthy:
                elapsed = time.time() - start_poll
                logger.info(
                    f"[WATCHDOG] Node {norm_url} successfully recovered and responded in {elapsed:.1f}s."
                )
                recovered = True
                self._emit("node_recovered", norm_url, reason=reason, elapsed_s=round(elapsed, 1))
                break
            await asyncio.sleep(2.0)

        if not recovered:
            logger.error(
                f"[WATCHDOG] Node {norm_url} did not recover within {self.recovery_timeout}s timeout."
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
        norm_url = _normalize_url(backend_url)
        logger.warning(
            f"[WATCHDOG] Unload failed for model '{model_name}' on {norm_url}: {error}. Running confirmation probe..."
        )

        is_responsive = await self.probe_node_health(
            norm_url, expected_unloaded_model=model_name
        )
        if not is_responsive:
            logger.error(
                f"[WATCHDOG] Confirmation probe failed on {norm_url} (model stuck or server dead). Triggering restart."
            )
            return await self.restart_node_service(
                norm_url,
                reason=f"Failed to unload model '{model_name}': {error}",
                on_recovered_cb=on_recovered_cb,
            )
        else:
            logger.info(
                f"[WATCHDOG] Node {norm_url} confirmed responsive and model unloaded. No restart required."
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
        Logs a WARNING message that the watchdog timer has passed (unload/restart suppressed).
        """
        norm_url = _normalize_url(backend_url)
        logger.warning(
            f"[WATCHDOG] Watchdog timer passed: Runaway request detected on {norm_url}. "
            f"In-flight: {in_flight}, active for {stuck_seconds:.1f}s. Model unload and service restart suppressed."
        )
        return True

