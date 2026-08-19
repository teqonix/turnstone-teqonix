from __future__ import annotations

from unittest.mock import MagicMock, patch

import pytest

from turnstone.core.healthcheck import HealthTrackerRegistry
from turnstone.core.session import ChatSession, _StreamTurnConsumer
from turnstone.core.trajectory import Turn


from tests._session_helpers import make_session


class MockConfigStore:
    def __init__(self, values: dict[str, object] | None = None) -> None:
        self._values = dict(values or {})

    def get(self, key: str) -> object | None:
        return self._values.get(key)


def test_get_max_retries_default() -> None:
    session = make_session()
    assert session._get_max_retries() == 3


def test_get_max_retries_from_config_store() -> None:
    config_store = MockConfigStore({"health.failure_threshold": 20})
    session = make_session(config_store=config_store)
    assert session._get_max_retries() == 20


def test_get_max_retries_from_health_registry() -> None:
    health_reg = HealthTrackerRegistry(failure_threshold=15)
    session = make_session(health_registry=health_reg)
    assert session._get_max_retries() == 15


def test_get_max_retries_instance_override_precedence() -> None:
    config_store = MockConfigStore({"health.failure_threshold": 20})
    session = make_session(config_store=config_store)
    session._MAX_RETRIES = 0  # e.g., fast-failing test
    assert session._get_max_retries() == 0


def test_retry_backoff_capped_at_max_delay() -> None:
    session = make_session()
    assert session._RETRY_MAX_DELAY == 30.0

    # Attempts 0..4: 1s, 2s, 4s, 8s, 16s
    delays = [
        min(session._RETRY_BASE_DELAY * (2**attempt), session._RETRY_MAX_DELAY)
        for attempt in range(10)
    ]
    assert delays == [1.0, 2.0, 4.0, 8.0, 16.0, 30.0, 30.0, 30.0, 30.0, 30.0]


def test_model_turn_with_retry_attempts_count() -> None:
    class RateLimitError(Exception):
        pass

    config_store = MockConfigStore({"health.failure_threshold": 5})
    session = make_session(config_store=config_store)

    lane = MagicMock()
    lane.provider.retryable_error_names = frozenset({"RateLimitError"})

    calls = 0

    def mock_model_turn(*args, **kwargs):
        nonlocal calls
        calls += 1
        raise RateLimitError("Rate limit exceeded")

    consumer = _StreamTurnConsumer(session, 1)

    with (
        patch("turnstone.core.session.model_turn", side_effect=mock_model_turn),
        patch("turnstone.core.session.require_lane_capabilities"),
        patch("turnstone.core.session.lane_diagnostics", return_value=MagicMock(base_url="http://test", provider_type="mock", model="test")),
        patch.object(session, "_activate_token_calibration"),
        patch.object(session, "_ensure_mcp_projection_current"),
        patch.object(session, "_backoff_or_cancelled"),
        patch.object(session, "_publish_for_generation", return_value=True),
    ):
        with pytest.raises(RateLimitError):
            session._model_turn_with_retry(
                lane=lane,
                tracker=None,
                consumer=consumer,
                prepare_wire=lambda wire, lane: wire,
            )

    # 1 initial attempt + 5 retries = 6 total attempts
    assert calls == 6
