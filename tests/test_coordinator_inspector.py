"""Unit tests for scripts/coordinator_inspector.py."""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path
import unittest
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from scripts.coordinator_inspector import (
    _extract_from_env_file,
    _extract_from_toml_file,
    _resolve_config,
    fetch_active_coordinators,
    fetch_workstream_history,
    fetch_workstream_tasks,
    inspect_coordinators,
    send_nudge,
)


class TestCoordinatorInspector(unittest.TestCase):
    def test_resolve_config_explicit_args(self):
        url, token = _resolve_config("http://custom-host:8090", "custom-token", probe_candidates=False)
        self.assertEqual(url, "http://custom-host:8090")
        self.assertEqual(token, "custom-token")

    def test_resolve_config_env_vars(self):
        with patch.dict(os.environ, {"TURNSTONE_CONSOLE_URL": "http://env-host:9000", "TURNSTONE_API_TOKEN": "tok-123"}):
            url, token = _resolve_config(probe_candidates=False)
            self.assertEqual(url, "http://env-host:9000")
            self.assertEqual(token, "tok-123")

    def test_resolve_config_coordinator_ip(self):
        with patch.dict(os.environ, {"COORDINATOR_IP": "10.0.0.50"}, clear=True):
            url, _ = _resolve_config(probe_candidates=False)
            self.assertEqual(url, "http://10.0.0.50:8090")

    def test_extract_from_env_file(self):
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write("TURNSTONE_CONSOLE_URL=http://envfile-host:8090\n")
            f.write("TURNSTONE_TOKEN=\"secret-token-456\"\n")
            f.flush()
            temp_path = Path(f.name)

        try:
            res = _extract_from_env_file(temp_path)
            self.assertEqual(res.get("TURNSTONE_CONSOLE_URL"), "http://envfile-host:8090")
            self.assertEqual(res.get("TURNSTONE_TOKEN"), "secret-token-456")
        finally:
            temp_path.unlink(missing_ok=True)

    def test_extract_from_toml_file(self):
        with tempfile.NamedTemporaryFile("w", delete=False, suffix=".toml") as f:
            f.write('[coordinator]\nurl = "http://toml-coordinator:8090"\n[auth]\njwt_secret = "toml-secret"\n')
            f.flush()
            temp_path = Path(f.name)

        try:
            url, token = _extract_from_toml_file(temp_path)
            self.assertEqual(url, "http://toml-coordinator:8090")
            self.assertEqual(token, "toml-secret")
        finally:
            temp_path.unlink(missing_ok=True)

    def test_fetch_active_coordinators(self):
        mock_response = {
            "workstreams": [
                {"ws_id": "coord1", "name": "Coord 1", "kind": "coordinator", "state": "idle", "updated": "2026-09-02T12:00:00Z"},
                {"ws_id": "interactive1", "name": "Interactive 1", "kind": "interactive", "state": "idle"},
                {"ws_id": "coord2", "name": "Coord 2", "kind": "coordinator", "state": "running", "updated": "2026-09-02T14:00:00Z"},
            ]
        }

        with patch("scripts.coordinator_inspector._http_request", return_value=mock_response) as mock_http:
            coords = fetch_active_coordinators("http://test.local", token="secret")
            self.assertEqual(len(coords), 2)
            # Most recently updated comes first (coord2 at 14:00 > coord1 at 12:00)
            self.assertEqual(coords[0]["ws_id"], "coord2")
            self.assertEqual(coords[1]["ws_id"], "coord1")
            self.assertEqual(mock_http.call_count, 3)
            # Check auth header was supplied on requests
            for call_item in mock_http.call_args_list:
                args, kwargs = call_item
                self.assertEqual(args[0], "GET")
                self.assertEqual(kwargs["headers"]["Authorization"], "Bearer secret")

    def test_fetch_workstream_history(self):
        mock_history = {
            "ws_id": "coord1",
            "messages": [
                {"role": "user", "content": "Start work"},
                {"role": "assistant", "content": "Working on it..."},
            ],
        }

        with patch("scripts.coordinator_inspector._http_request", return_value=mock_history) as mock_http:
            messages = fetch_workstream_history("coord1", limit=15, base_url="http://test.local")
            self.assertEqual(len(messages), 2)
            self.assertEqual(messages[0]["role"], "user")
            mock_http.assert_called_once()
            self.assertIn("coord1/history?limit=15", mock_http.call_args[0][1])

    def test_fetch_workstream_tasks(self):
        mock_tasks = {
            "version": 1,
            "tasks": [
                {"id": "t1", "title": "Deploy service", "status": "pending"},
                {"id": "t2", "title": "Run tests", "status": "done"},
            ],
        }

        with patch("scripts.coordinator_inspector._http_request", return_value=mock_tasks):
            tasks = fetch_workstream_tasks("coord1", base_url="http://test.local")
            self.assertEqual(len(tasks), 2)
            self.assertEqual(tasks[0]["id"], "t1")
            self.assertEqual(tasks[0]["status"], "pending")

    def test_inspect_coordinators(self):
        mock_workstreams = {
            "workstreams": [
                {"ws_id": "coord1", "name": "Coord 1", "kind": "coordinator", "state": "idle"},
            ]
        }
        mock_history = {
            "messages": [{"role": "assistant", "content": "I will wait for child tasks."}]
        }
        mock_tasks = {
            "tasks": [
                {"id": "t1", "title": "Pending job", "status": "in_progress"},
                {"id": "t2", "title": "Completed job", "status": "done"},
            ]
        }

        def fake_http_request(method, url, **kwargs):
            if url.endswith("/v1/api/workstreams"):
                return mock_workstreams
            if "/history" in url:
                return mock_history
            if "/tasks" in url:
                return mock_tasks
            return {}

        with patch("scripts.coordinator_inspector._http_request", side_effect=fake_http_request):
            results = inspect_coordinators(base_url="http://test.local", history_limit=15)
            self.assertEqual(len(results), 1)
            coord = results[0]
            self.assertEqual(coord["ws_id"], "coord1")
            self.assertTrue(coord["is_idle"])
            self.assertTrue(coord["has_open_tasks"])
            self.assertEqual(coord["open_tasks_count"], 1)
            self.assertEqual(len(coord["open_tasks"]), 1)
            self.assertEqual(coord["open_tasks"][0]["id"], "t1")
            self.assertEqual(len(coord["messages"]), 1)

    def test_send_nudge_success(self):
        mock_resp = {"status": "ok", "attached_ids": []}

        with patch("scripts.coordinator_inspector._http_request", return_value=mock_resp) as mock_http:
            res = send_nudge("coord1", message="Please resume", base_url="http://test.local", token="token123")
            self.assertTrue(res["success"])
            self.assertEqual(res["ws_id"], "coord1")
            self.assertEqual(res["response"]["status"], "ok")
            mock_http.assert_called_once()
            args, kwargs = mock_http.call_args
            self.assertEqual(args[0], "POST")
            self.assertIn("coord1/send", args[1])
            self.assertEqual(kwargs["json_data"], {"message": "Please resume"})

    def test_send_nudge_failure(self):
        with patch("scripts.coordinator_inspector._http_request", side_effect=RuntimeError("HTTP 404")):
            res = send_nudge("coord_unknown", base_url="http://test.local")
            self.assertFalse(res["success"])
            self.assertIn("HTTP 404", res["error"])

    def test_fetch_active_coordinators_fallback_to_cluster(self):
        mock_cluster_response = {
            "workstreams": [
                {"ws_id": "coord_cluster1", "name": "Cluster Coord 1", "kind": "coordinator", "updated": "2026-09-02T22:00:00Z"},
                {"ws_id": "coord_cluster2", "name": "Cluster Coord 2", "node": "console", "updated": "2026-09-02T22:10:00Z"},
            ]
        }

        def fake_http_request(method, url, **kwargs):
            if url.endswith("/v1/api/workstreams"):
                return {"workstreams": []}  # in-memory empty
            if "/cluster/workstreams" in url:
                return mock_cluster_response
            return {}

        with patch("scripts.coordinator_inspector._http_request", side_effect=fake_http_request):
            coords = fetch_active_coordinators("http://test.local", token="secret", limit=5)
            self.assertEqual(len(coords), 2)
            # coord_cluster2 is more recently updated (22:10 vs 22:00)
            self.assertEqual(coords[0]["ws_id"], "coord_cluster2")
            self.assertEqual(coords[1]["ws_id"], "coord_cluster1")

    def test_fetch_active_coordinators_recency_sorting_and_limit(self):
        mock_workstreams = {
            "workstreams": [
                {"ws_id": "c1", "name": "C1", "kind": "coordinator", "updated": "2026-09-02T10:00:00Z"},
                {"ws_id": "c2", "name": "C2", "kind": "coordinator", "updated": "2026-09-02T14:00:00Z"},
                {"ws_id": "c3", "name": "C3", "kind": "coordinator", "updated": "2026-09-02T12:00:00Z"},
                {"ws_id": "c4", "name": "C4", "kind": "coordinator", "updated": "2026-09-02T16:00:00Z"},
                {"ws_id": "c5", "name": "C5", "kind": "coordinator", "updated": "2026-09-02T15:00:00Z"},
                {"ws_id": "c6", "name": "C6", "kind": "coordinator", "updated": "2026-09-02T11:00:00Z"},
                {"ws_id": "c7", "name": "C7", "kind": "coordinator", "created": "2026-09-02T09:00:00Z"},
            ]
        }

        with patch("scripts.coordinator_inspector._http_request", return_value=mock_workstreams):
            coords = fetch_active_coordinators("http://test.local", limit=5)
            self.assertEqual(len(coords), 5)
            # Expected top 5 newest-first: c4 (16:00), c5 (15:00), c2 (14:00), c3 (12:00), c6 (11:00)
            self.assertEqual([c["ws_id"] for c in coords], ["c4", "c5", "c2", "c3", "c6"])

    def test_inspect_coordinators_custom_max_workstreams(self):
        mock_workstreams = {
            "workstreams": [
                {"ws_id": f"coord_{i}", "name": f"Coord {i}", "kind": "coordinator", "updated": f"2026-09-02T{10+i:02d}:00:00Z"}
                for i in range(10)
            ]
        }

        def fake_http(method, url, **kwargs):
            if url.endswith("/v1/api/workstreams"):
                return mock_workstreams
            return {}

        with patch("scripts.coordinator_inspector._http_request", side_effect=fake_http):
            results = inspect_coordinators("http://test.local", max_workstreams=3)
            self.assertEqual(len(results), 3)
            self.assertEqual(results[0]["ws_id"], "coord_9")
            self.assertEqual(results[1]["ws_id"], "coord_8")
            self.assertEqual(results[2]["ws_id"], "coord_7")

    def test_active_coordinators_ranked_above_closed(self):
        mock_workstreams = {
            "workstreams": [
                {"ws_id": "closed_recent", "name": "Closed Recent", "kind": "coordinator", "state": "closed", "updated": "2026-08-25T11:00:00Z"},
                {"ws_id": "idle_no_ts", "name": "Live Idle No TS", "kind": "coordinator", "state": "idle", "updated": ""},
                {"ws_id": "idle_same_ts", "name": "Live Idle Same TS", "kind": "coordinator", "state": "idle", "updated": "2026-08-25T11:00:00Z"},
                {"ws_id": "running_today", "name": "Running Today", "kind": "coordinator", "state": "running", "updated": "2026-09-02T10:00:00Z"},
            ]
        }
        with patch("scripts.coordinator_inspector._http_request", return_value=mock_workstreams):
            coords = fetch_active_coordinators("http://test.local", limit=5)
            # Most recent timestamp first
            self.assertEqual(coords[0]["ws_id"], "running_today")
            # For equal timestamps, active/idle precedes closed
            self.assertEqual(coords[1]["ws_id"], "idle_same_ts")
            self.assertEqual(coords[2]["ws_id"], "closed_recent")
            # Sessions missing timestamps sort after real timestamps
            self.assertEqual(coords[3]["ws_id"], "idle_no_ts")

    def test_fetch_active_coordinators_active_only(self):
        mock_workstreams = {
            "workstreams": [
                {"ws_id": "c_closed", "name": "Closed", "kind": "coordinator", "state": "closed"},
                {"ws_id": "c_idle", "name": "Idle", "kind": "coordinator", "state": "idle"},
                {"ws_id": "c_running", "name": "Running", "kind": "coordinator", "state": "running"},
            ]
        }
        with patch("scripts.coordinator_inspector._http_request", return_value=mock_workstreams):
            coords = fetch_active_coordinators("http://test.local", active_only=True, limit=5)
            self.assertEqual(len(coords), 2)
            self.assertEqual({c["ws_id"] for c in coords}, {"c_idle", "c_running"})

    def test_inspect_coordinators_timestamp_backfill(self):
        mock_workstreams = {
            "workstreams": [
                {"ws_id": "coord_live", "name": "Coord Live", "kind": "coordinator", "state": "idle"}
            ]
        }
        mock_history = {
            "messages": [
                {"role": "assistant", "content": "Working", "timestamp": "2026-09-02T22:30:00Z"}
            ]
        }
        mock_tasks = {
            "tasks": [
                {"id": "t1", "title": "Investigate", "status": "in_progress", "updated": "2026-09-02T22:35:00Z"}
            ]
        }

        def fake_http(method, url, **kwargs):
            if "/history" in url:
                return mock_history
            if "/tasks" in url:
                return mock_tasks
            return mock_workstreams

        with patch("scripts.coordinator_inspector._http_request", side_effect=fake_http):
            results = inspect_coordinators("http://test.local", max_workstreams=1)
            self.assertEqual(len(results), 1)
            # updated timestamp should be backfilled from tasks (22:35)
            self.assertEqual(results[0]["updated"], "2026-09-02T22:35:00Z")

    def test_inspect_coordinators_pulls_all_and_orders_most_recent_top_5(self):
        # 10 workstreams in memory without timestamp on list API
        mock_workstreams = {
            "workstreams": [
                {"ws_id": f"ws_{i}", "name": f"WS {i}", "kind": "coordinator", "state": "idle"}
                for i in range(10)
            ]
        }

        # Each workstream has a task with a distinct timestamp
        def fake_http(method, url, **kwargs):
            if "/tasks" in url:
                for i in range(10):
                    if f"ws_{i}/tasks" in url:
                        return {
                            "tasks": [
                                {
                                    "id": f"t_{i}",
                                    "title": f"Task {i}",
                                    "status": "done",
                                    "updated": f"2026-09-02T{10+i:02d}:00:00Z",
                                }
                            ]
                        }
                return {"tasks": []}
            if "/history" in url:
                return {"messages": []}
            return mock_workstreams

        with patch("scripts.coordinator_inspector._http_request", side_effect=fake_http):
            results = inspect_coordinators("http://test.local", max_workstreams=5)
            self.assertEqual(len(results), 5)
            # Should have inspected all 10, backfilled timestamps, and returned top 5 newest: ws_9 (19:00), ws_8 (18:00), ws_7 (17:00), ws_6 (16:00), ws_5 (15:00)
            self.assertEqual([r["ws_id"] for r in results], ["ws_9", "ws_8", "ws_7", "ws_6", "ws_5"])


if __name__ == "__main__":
    unittest.main()
