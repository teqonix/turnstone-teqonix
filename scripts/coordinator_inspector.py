#!/usr/bin/env python3
"""Turnstone Coordinator Inspector and Nudge Tool.

This tool provides programmatic inspection of active Turnstone coordinator sessions,
their conversation history, and their task envelopes. It also provides a function
to send a nudge message to any coordinator session to resume stalled or idled work.

Coordinator URL and Auth Token Resolution:
    1. Direct parameter / CLI argument (`--url` / `--token`)
    2. Environment variables (`TURNSTONE_CONSOLE_URL`, `TURNSTONE_COORDINATOR_URL`,
       `COORDINATOR_IP`, `TURNSTONE_BASE_URL`, `TURNSTONE_API_TOKEN`, etc.)
    3. TOML configuration files (`$TURNSTONE_CONFIG`, `~/.config/turnstone/config.toml`,
       `/etc/turnstone/turnstone.toml`, `turnstone.toml`)
    4. System environment files (`/etc/turnstone/coordinator.env`,
       `/etc/turnstone/postgres_admin.env`, `.env`)
    5. Local / network host auto-discovery probing.

Usage:
    # Inspect all active coordinators (auto-discovering coordinator URL)
    python scripts/coordinator_inspector.py inspect

    # Inspect passing explicit URL or token
    python scripts/coordinator_inspector.py inspect --url http://127.0.0.1:8090 --limit 20

    # Inspect a single coordinator session by ID
    python scripts/coordinator_inspector.py inspect --ws-id <ws_id>

    # Send a nudge to a stalled coordinator
    python scripts/coordinator_inspector.py nudge --ws-id <ws_id> --message "Please resume work on open tasks."
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

try:
    import tomllib  # Python 3.11+
except ImportError:
    try:
        import tomli as tomllib  # type: ignore
    except ImportError:
        tomllib = None  # type: ignore

FALLBACK_COORDINATOR_URL = "http://turnstone-coordinator-nerd-projects.lan:8090"
DEFAULT_COORDINATOR_LIMIT = 5
DEFAULT_HISTORY_LIMIT = 15
DEFAULT_NUDGE_MESSAGE = (
    "System Nudge: All child workstreams and tasks are currently idle with open tasks remaining. "
    "Please check task status and resume execution where you left off."
)


def _workstream_sort_key(ws: dict[str, Any]) -> tuple[int, str, str, int, int]:
    """Sort key to order workstreams: valid timestamps newest-first descending.

    Priority order:
      1. has_ts (1 if updated or created timestamp exists, 0 if missing)
      2. latest_ts (updated or created ISO string descending)
      3. cr (secondary created timestamp descending)
      4. is_active (active/idle sessions prioritized if timestamps match)
      5. max_event_id (higher event/message activity for equal/missing timestamps)
    """
    up = str(ws.get("updated") or "").strip()
    cr = str(ws.get("created") or "").strip()
    latest_ts = up or cr
    has_ts = 1 if latest_ts else 0

    state = str(ws.get("state") or "").lower()
    is_active = 1 if state in ("running", "thinking", "attention", "idle", "busy", "waiting") else 0

    max_eid = int(ws.get("max_event_id") or 0)
    return (has_ts, latest_ts, cr, is_active, max_eid)


def _is_coordinator_workstream(ws: dict[str, Any]) -> bool:
    """Check whether a workstream metadata object represents a coordinator."""
    kind = ws.get("kind")
    if kind == "coordinator":
        return True
    if kind == "interactive":
        return False
    node = ws.get("node")
    if node == "console":
        return True
    if node and node != "console":
        return False
    # If kind is omitted and no parent workstream is referenced, assume coordinator
    return kind is None and ws.get("parent_ws_id") is None


def _extract_from_env_file(filepath: Path) -> dict[str, str]:
    """Parse key-value pairs from an env file without external dependencies."""
    res: dict[str, str] = {}
    try:
        if filepath.is_file():
            with open(filepath, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#") and "=" in line:
                        k, v = line.split("=", 1)
                        # strip quotes
                        cleaned_val = v.strip().strip("\"'")
                        res[k.strip()] = cleaned_val
    except Exception:
        pass
    return res


def _extract_from_toml_file(filepath: Path) -> tuple[str | None, str | None]:
    """Extract coordinator URL and auth token from a Turnstone TOML config file."""
    if tomllib is None:
        return None, None
    try:
        if filepath.is_file():
            with open(filepath, "rb") as f:
                data = tomllib.load(f)
                url = None
                token = None

                # Search sections: [coordinator], [console], [cluster], [api]
                for section in ("coordinator", "console", "cluster", "api"):
                    sec = data.get(section, {})
                    if isinstance(sec, dict):
                        url_val = sec.get("url") or sec.get("console_url") or sec.get("base_url")
                        if url_val and not url:
                            url = str(url_val).strip()
                        tok_val = sec.get("token") or sec.get("api_key") or sec.get("jwt_secret")
                        if tok_val and not token:
                            token = str(tok_val).strip()

                auth_sec = data.get("auth", {})
                if isinstance(auth_sec, dict) and not token:
                    tok_val = auth_sec.get("jwt_secret") or auth_sec.get("token")
                    if tok_val:
                        token = str(tok_val).strip()

                return url, token
    except Exception:
        pass
    return None, None


def _probe_url(url: str, timeout: float = 0.8) -> bool:
    """Check if a candidate coordinator URL is responsive."""
    test_url = f"{url.rstrip('/')}/v1/api/auth/status"
    req = urllib.request.Request(
        test_url,
        headers={"User-Agent": "TurnstoneInspector/1.0", "Accept": "application/json"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status in (200, 401, 403)
    except urllib.error.HTTPError as e:
        return e.code in (200, 401, 403)
    except Exception:
        return False


def _resolve_config(
    base_url: str | None = None,
    token: str | None = None,
    *,
    probe_candidates: bool = True,
) -> tuple[str, str]:
    """Resolve base URL and auth token dynamically using a multi-tiered search ladder.

    Search Priority for Base URL:
        1. Explicit argument `base_url`
        2. Environment variables: `TURNSTONE_CONSOLE_URL`, `TURNSTONE_COORDINATOR_URL`,
           `COORDINATOR_URL`, `TURNSTONE_BASE_URL`
        3. Derived from `COORDINATOR_IP` env var (e.g. `http://${COORDINATOR_IP}:8090`)
        4. TOML configuration files:
           - `$TURNSTONE_CONFIG`
           - `~/.config/turnstone/config.toml`
           - `/etc/turnstone/turnstone.toml`
           - `/opt/turnstone-coordinator/turnstone.toml`
           - `./turnstone.toml`
        5. Environment files:
           - `/etc/turnstone/coordinator.env`
           - `/etc/turnstone/postgres_admin.env`
           - `/etc/turnstone/turnstone.env`
           - `.env`
        6. Live probing of common candidate endpoints (if probe_candidates=True):
           - `http://127.0.0.1:8090` (local coordinator console)
           - `http://localhost:8090`
           - `http://turnstone-coordinator-nerd-projects.lan:8090`
           - `http://turnstone-coordinator-nerd-projects.lan`
        7. Hardcoded fallback: `http://turnstone-coordinator-nerd-projects.lan:8090`
    """
    resolved_url = base_url.strip() if base_url else ""
    resolved_token = token.strip() if token else ""

    # 1. Environment Variables
    if not resolved_url:
        env_url = (
            os.environ.get("TURNSTONE_CONSOLE_URL")
            or os.environ.get("TURNSTONE_COORDINATOR_URL")
            or os.environ.get("COORDINATOR_URL")
            or os.environ.get("TURNSTONE_BASE_URL")
        )
        if env_url:
            resolved_url = env_url.strip()
        elif os.environ.get("COORDINATOR_IP"):
            coord_ip = os.environ["COORDINATOR_IP"].strip()
            resolved_url = f"http://{coord_ip}:8090"

    if not resolved_token:
        resolved_token = (
            os.environ.get("TURNSTONE_API_TOKEN")
            or os.environ.get("TURNSTONE_TOKEN")
            or os.environ.get("COORDINATOR_TOKEN")
            or os.environ.get("JWT_SECRET")
            or os.environ.get("TURNSTONE_JWT_SECRET")
            or ""
        ).strip()

    # 2. TOML Configuration Files
    if not resolved_url or not resolved_token:
        toml_paths = []
        if os.environ.get("TURNSTONE_CONFIG"):
            toml_paths.append(Path(os.environ["TURNSTONE_CONFIG"]))
        toml_paths.extend([
            Path("~/.config/turnstone/config.toml").expanduser(),
            Path("/etc/turnstone/turnstone.toml"),
            Path("/opt/turnstone-coordinator/turnstone.toml"),
            Path("turnstone.toml"),
        ])

        for p in toml_paths:
            file_url, file_token = _extract_from_toml_file(p)
            if file_url and not resolved_url:
                resolved_url = file_url
            if file_token and not resolved_token:
                resolved_token = file_token
            if resolved_url and resolved_token:
                break

    # 3. Environment / Secret Files
    if not resolved_url or not resolved_token:
        env_paths = [
            Path("/etc/turnstone/coordinator.env"),
            Path("/etc/turnstone/postgres_admin.env"),
            Path("/etc/turnstone/turnstone.env"),
            Path("/opt/turnstone-coordinator/.env"),
            Path(".env"),
        ]
        for ep in env_paths:
            env_dict = _extract_from_env_file(ep)
            if not resolved_url:
                url_candidate = (
                    env_dict.get("TURNSTONE_CONSOLE_URL")
                    or env_dict.get("TURNSTONE_COORDINATOR_URL")
                    or env_dict.get("COORDINATOR_URL")
                )
                if not url_candidate and env_dict.get("COORDINATOR_IP"):
                    url_candidate = f"http://{env_dict['COORDINATOR_IP']}:8090"
                if url_candidate:
                    resolved_url = url_candidate
            if not resolved_token:
                tok_candidate = (
                    env_dict.get("TURNSTONE_API_TOKEN")
                    or env_dict.get("TURNSTONE_TOKEN")
                    or env_dict.get("TURNSTONE_JWT_SECRET")
                    or env_dict.get("JWT_SECRET")
                )
                if tok_candidate:
                    resolved_token = tok_candidate
            if resolved_url and resolved_token:
                break

    # 4. Token file fallback
    if not resolved_token:
        for token_path in (
            "/etc/turnstone/admin.token",
            "/etc/turnstone/token",
            "/opt/turnstone-coordinator/secrets/admin.token",
        ):
            if os.path.isfile(token_path):
                try:
                    with open(token_path, "r", encoding="utf-8") as f:
                        content = f.read().strip()
                        if content:
                            resolved_token = content
                            break
                except Exception:
                    pass

    # 5. Live Probing of Candidate Endpoints
    if not resolved_url:
        candidates = [
            "http://127.0.0.1:8090",
            "http://localhost:8090",
            "http://turnstone-coordinator-nerd-projects.lan:8090",
            "http://turnstone-coordinator-nerd-projects.lan",
            "http://127.0.0.1:8000",
            "http://localhost:8000",
        ]
        if probe_candidates:
            for cand in candidates:
                if _probe_url(cand):
                    resolved_url = cand
                    break

    # 6. Default Fallback
    if not resolved_url:
        resolved_url = FALLBACK_COORDINATOR_URL

    resolved_url = resolved_url.rstrip("/")
    if not resolved_url.startswith(("http://", "https://")):
        resolved_url = f"http://{resolved_url}"

    return resolved_url, resolved_token


def _http_request(
    method: str,
    url: str,
    headers: dict[str, str] | None = None,
    json_data: dict[str, Any] | None = None,
    timeout: float = 10.0,
) -> dict[str, Any]:
    """Execute an HTTP request using urllib and return the parsed JSON response."""
    req_headers = {
        "Accept": "application/json",
        "User-Agent": "TurnstoneCoordinatorInspector/1.0",
    }
    if headers:
        req_headers.update(headers)

    body_bytes: bytes | None = None
    if json_data is not None:
        body_bytes = json.dumps(json_data).encode("utf-8")
        req_headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, data=body_bytes, headers=req_headers, method=method)

    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            content = resp.read().decode("utf-8")
            if not content:
                return {}
            return json.loads(content)
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", errors="replace")
        try:
            err_json = json.loads(err_body)
            msg = err_json.get("error") or err_json.get("detail") or err_body
        except Exception:
            msg = err_body or str(e)
        raise RuntimeError(f"HTTP {e.code} from {url}: {msg}") from e
    except urllib.error.URLError as e:
        raise RuntimeError(f"Network error connecting to {url}: {e.reason}") from e


def fetch_active_coordinators(
    base_url: str | None = None,
    token: str | None = None,
    limit: int | None = None,
    active_only: bool = False,
) -> list[dict[str, Any]]:
    """Fetch all coordinator workstreams across Turnstone API endpoints.

    Queries candidate endpoints:
      1. GET /v1/api/workstreams/saved (persisted coordinators with storage created & updated timestamps)
      2. GET /v1/api/cluster/workstreams?per_page=100 (cluster-wide live + persisted workstreams)
      3. GET /v1/api/workstreams (active in-memory workstreams)

    Aggregates and deduplicates by `ws_id`, merging timestamps and metadata across
    endpoints, backfills timestamps from tasks for active coordinators lacking them,
    orders newest-first descending by recency, and returns workstreams.
    """
    resolved_url, resolved_token = _resolve_config(base_url, token)
    headers = {}
    if resolved_token:
        headers["Authorization"] = f"Bearer {resolved_token}"

    candidate_endpoints = [
        f"{resolved_url}/v1/api/workstreams/saved",
        f"{resolved_url}/v1/api/cluster/workstreams?per_page=100",
        f"{resolved_url}/v1/api/workstreams",
    ]

    all_workstreams: dict[str, dict[str, Any]] = {}
    last_error: Exception | None = None

    for url in candidate_endpoints:
        try:
            data = _http_request("GET", url, headers=headers)
            ws_list = data.get("workstreams", [])
            for ws in ws_list:
                cid = ws.get("ws_id") or ws.get("id") or ""
                if cid and _is_coordinator_workstream(ws):
                    if cid not in all_workstreams:
                        all_workstreams[cid] = dict(ws)
                    else:
                        # Merge properties from richer endpoint (e.g. created/updated/name/title)
                        for k, v in ws.items():
                            if v is not None and v != "" and all_workstreams[cid].get(k) in (None, ""):
                                all_workstreams[cid][k] = v
        except Exception as exc:
            last_error = exc
            continue

    if not all_workstreams and last_error is not None:
        raise last_error

    # For active coordinators lacking timestamps, perform a fast concurrent task probe to backfill timestamps
    unresolved_cids = [
        cid for cid, ws in all_workstreams.items()
        if not ws.get("updated") and str(ws.get("state") or "").lower() in ("running", "thinking", "attention", "idle", "busy", "waiting")
    ]
    if unresolved_cids:
        from concurrent.futures import ThreadPoolExecutor

        def _probe_tasks(cid: str) -> None:
            try:
                tasks_url = f"{resolved_url}/v1/api/workstreams/{urllib.parse.quote(cid)}/tasks"
                t_data = _http_request("GET", tasks_url, headers=headers, timeout=2.0)
                ws = all_workstreams[cid]
                for t in t_data.get("tasks", []):
                    t_up = t.get("updated") or t.get("created")
                    if t_up and t_up > (ws.get("updated") or ""):
                        ws["updated"] = t_up
                    if t_up and not ws.get("created"):
                        ws["created"] = t.get("created") or t_up
            except Exception:
                pass

        with ThreadPoolExecutor(max_workers=min(len(unresolved_cids), 10)) as executor:
            list(executor.map(_probe_tasks, unresolved_cids))

    workstreams = list(all_workstreams.values())
    if active_only:
        workstreams = [
            ws for ws in workstreams
            if str(ws.get("state") or "").lower() not in ("closed", "deleted")
        ]

    sorted_coordinators = sorted(
        workstreams,
        key=_workstream_sort_key,
        reverse=True,
    )

    if limit is not None and limit > 0:
        return sorted_coordinators[:limit]
    return sorted_coordinators


# Backward-compatible alias
fetch_recent_coordinators = fetch_active_coordinators


def fetch_workstream_history(
    ws_id: str,
    limit: int = DEFAULT_HISTORY_LIMIT,
    base_url: str | None = None,
    token: str | None = None,
) -> list[dict[str, Any]]:
    """Fetch the tail of reconstructed messages from GET /v1/api/workstreams/{ws_id}/history."""
    resolved_url, resolved_token = _resolve_config(base_url, token)
    headers = {}
    if resolved_token:
        headers["Authorization"] = f"Bearer {resolved_token}"

    url = f"{resolved_url}/v1/api/workstreams/{urllib.parse.quote(ws_id)}/history?limit={limit}"
    try:
        data = _http_request("GET", url, headers=headers)
        return data.get("messages", [])
    except Exception as e:
        sys.stderr.write(f"[WARN] Failed fetching history for {ws_id}: {e}\n")
        return []


def fetch_workstream_tasks(
    ws_id: str,
    base_url: str | None = None,
    token: str | None = None,
) -> list[dict[str, Any]]:
    """Fetch tasks from GET /v1/api/workstreams/{ws_id}/tasks."""
    resolved_url, resolved_token = _resolve_config(base_url, token)
    headers = {}
    if resolved_token:
        headers["Authorization"] = f"Bearer {resolved_token}"

    url = f"{resolved_url}/v1/api/workstreams/{urllib.parse.quote(ws_id)}/tasks"
    try:
        data = _http_request("GET", url, headers=headers)
        return data.get("tasks", [])
    except Exception as e:
        sys.stderr.write(f"[WARN] Failed fetching tasks for {ws_id}: {e}\n")
        return []


def inspect_coordinators(
    base_url: str | None = None,
    token: str | None = None,
    history_limit: int = DEFAULT_HISTORY_LIMIT,
    ws_id: str | None = None,
    max_workstreams: int = DEFAULT_COORDINATOR_LIMIT,
    active_only: bool = False,
    only_open_tasks: bool = False,
) -> list[dict[str, Any]]:
    """Inspect coordinator workstreams, pull all workstreams, order by recency descending, and return top limit."""
    resolved_url, resolved_token = _resolve_config(base_url, token)

    if ws_id:
        headers = {}
        if resolved_token:
            headers["Authorization"] = f"Bearer {resolved_token}"
        detail_url = f"{resolved_url}/v1/api/workstreams/{urllib.parse.quote(ws_id)}"
        try:
            ws_meta = _http_request("GET", detail_url, headers=headers)
        except Exception:
            ws_meta = {"ws_id": ws_id, "kind": "coordinator", "state": "unknown"}
        candidates = [ws_meta]
    else:
        # Pull candidate coordinators globally sorted by recency descending
        # If only_open_tasks is requested, pull a wider candidate window to find open tasks
        fetch_limit = None if only_open_tasks else (max_workstreams * 3 if max_workstreams else None)
        candidates = fetch_active_coordinators(
            resolved_url,
            resolved_token,
            limit=fetch_limit,
            active_only=active_only,
        )

    results: list[dict[str, Any]] = []

    for coord in candidates:
        cid = coord.get("ws_id") or coord.get("id") or ""
        if not cid:
            continue

        tasks = fetch_workstream_tasks(
            cid,
            base_url=resolved_url,
            token=resolved_token,
        )

        open_tasks = [
            t for t in tasks
            if t.get("status") in ("pending", "in_progress", "blocked", "needs_user")
        ]

        if only_open_tasks and len(open_tasks) == 0:
            continue

        messages = fetch_workstream_history(
            cid,
            limit=history_limit,
            base_url=resolved_url,
            token=resolved_token,
        )

        state = coord.get("state", "unknown")
        is_idle = state.lower() in ("idle", "attention")

        # Backfill updated / created timestamp from messages or tasks if missing
        updated = coord.get("updated") or ""
        created = coord.get("created") or ""
        if not updated:
            for t in tasks:
                t_up = t.get("updated") or t.get("created") or ""
                if t_up and t_up > updated:
                    updated = t_up
            for m in messages:
                m_ts = m.get("timestamp") or m.get("created") or ""
                if isinstance(m_ts, str) and m_ts > updated:
                    updated = m_ts
        if not created and updated:
            created = updated

        max_eid = max((m.get("event_id") or 0) for m in messages) if messages else 0

        results.append(
            {
                "ws_id": cid,
                "name": coord.get("name") or coord.get("title") or coord.get("alias") or f"coord-{cid[:6]}",
                "state": state,
                "kind": coord.get("kind", "coordinator"),
                "user_id": coord.get("user_id"),
                "project_id": coord.get("project_id"),
                "persona": coord.get("persona"),
                "created": created or None,
                "updated": updated or None,
                "max_event_id": max_eid,
                "persistence_state": coord.get("persistence_state", "healthy"),
                "is_idle": is_idle,
                "has_open_tasks": len(open_tasks) > 0,
                "open_tasks_count": len(open_tasks),
                "tasks": tasks,
                "open_tasks": open_tasks,
                "messages": messages,
            }
        )

        # Early exit if we've satisfied max_workstreams and not filtering for open tasks
        if max_workstreams is not None and max_workstreams > 0 and len(results) >= max_workstreams and not only_open_tasks:
            break

    # Order all results from most to least recent (descending)
    results.sort(key=_workstream_sort_key, reverse=True)

    # Return the DEFAULT_COORDINATOR_LIMIT (or max_workstreams) most recent from this list
    if max_workstreams is not None and max_workstreams > 0 and len(results) > max_workstreams:
        results = results[:max_workstreams]

    return results


def send_nudge(
    ws_id: str,
    message: str = DEFAULT_NUDGE_MESSAGE,
    base_url: str | None = None,
    token: str | None = None,
) -> dict[str, Any]:
    """Send a nudge message to a coordinator workstream to resume execution."""
    resolved_url, resolved_token = _resolve_config(base_url, token)
    headers = {}
    if resolved_token:
        headers["Authorization"] = f"Bearer {resolved_token}"

    url = f"{resolved_url}/v1/api/workstreams/{urllib.parse.quote(ws_id)}/send"
    payload = {"message": message}

    try:
        response = _http_request("POST", url, headers=headers, json_data=payload)
        return {
            "success": True,
            "ws_id": ws_id,
            "response": response,
        }
    except Exception as exc:
        return {
            "success": False,
            "ws_id": ws_id,
            "error": str(exc),
        }


def main() -> None:
    common_parser = argparse.ArgumentParser(add_help=False)
    common_parser.add_argument(
        "--url",
        "-u",
        dest="base_url",
        help="Coordinator base URL (default: auto-detected from env/configs/network)",
    )
    common_parser.add_argument(
        "--token",
        "-t",
        dest="token",
        help="Auth token / API key (default: auto-detected from env/configs)",
    )

    parser = argparse.ArgumentParser(
        description="Inspect active Turnstone coordinator sessions and send nudges.",
        parents=[common_parser],
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    # inspect subcommand
    inspect_parser = subparsers.add_parser(
        "inspect",
        parents=[common_parser],
        help="Inspect coordinator workstreams",
    )
    inspect_parser.add_argument(
        "--limit",
        "-l",
        type=int,
        default=DEFAULT_HISTORY_LIMIT,
        help=f"Number of recent messages to fetch per workstream (default: {DEFAULT_HISTORY_LIMIT})",
    )
    inspect_parser.add_argument(
        "--max-workstreams",
        "--count",
        "-n",
        dest="max_workstreams",
        type=int,
        default=DEFAULT_COORDINATOR_LIMIT,
        help=f"Number of most recent coordinator workstreams to inspect (default: {DEFAULT_COORDINATOR_LIMIT})",
    )
    inspect_parser.add_argument(
        "--ws-id",
        dest="ws_id",
        help="Inspect a specific coordinator workstream ID only",
    )
    inspect_parser.add_argument(
        "--active-only",
        "--exclude-closed",
        dest="active_only",
        action="store_true",
        help="Filter results to only active / non-closed workstreams",
    )
    inspect_parser.add_argument(
        "--only-open-tasks",
        action="store_true",
        help="Filter results to only workstreams with open tasks",
    )
    inspect_parser.add_argument(
        "--pretty",
        action="store_true",
        help="Pretty-print JSON output",
    )

    # nudge subcommand
    nudge_parser = subparsers.add_parser(
        "nudge",
        parents=[common_parser],
        help="Send a nudge message to a workstream",
    )
    nudge_parser.add_argument(
        "--ws-id",
        required=True,
        dest="ws_id",
        help="Target coordinator workstream ID",
    )
    nudge_parser.add_argument(
        "--message",
        "-m",
        default=DEFAULT_NUDGE_MESSAGE,
        help="Nudge message text to send",
    )

    args = parser.parse_args()

    if args.command == "inspect":
        try:
            results = inspect_coordinators(
                base_url=args.base_url,
                token=args.token,
                history_limit=args.limit,
                ws_id=args.ws_id,
                max_workstreams=args.max_workstreams,
                active_only=args.active_only,
                only_open_tasks=args.only_open_tasks,
            )
            if args.only_open_tasks:
                results = [r for r in results if r.get("has_open_tasks")]

            resolved_url, _ = _resolve_config(args.base_url, args.token)
            output = {
                "status": "ok",
                "coordinator_url": resolved_url,
                "count": len(results),
                "coordinators": results,
            }
            indent = 2 if args.pretty else None
            print(json.dumps(output, indent=indent))
        except Exception as e:
            sys.stderr.write(f"[ERROR] Inspection failed: {e}\n")
            print(json.dumps({"status": "error", "error": str(e)}))
            sys.exit(1)

    elif args.command == "nudge":
        try:
            res = send_nudge(
                ws_id=args.ws_id,
                message=args.message,
                base_url=args.base_url,
                token=args.token,
            )
            print(json.dumps(res, indent=2))
            if not res.get("success"):
                sys.exit(1)
        except Exception as e:
            sys.stderr.write(f"[ERROR] Nudge failed: {e}\n")
            print(json.dumps({"status": "error", "error": str(e)}))
            sys.exit(1)


if __name__ == "__main__":
    main()
