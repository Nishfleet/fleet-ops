"""fleet-ops#9469: a 404 lane parks on the FIRST 404 and the job falls through.

The failure this guards (2026-10-08 23:03 IST, fo9459-approver.service): a pi job
picked a CommandCode ling-3.0-flash-sante:free row whose free tier had ended. The
provider answered 404 "This model is unavailable for free. The paid version is
available now - use this slug instead: inclusionai/ling-3.0-flash-sante". LiteLLM
v1.98.0 maps 404 to NotFoundError, which Router.should_retry_this_error
hard-raises on and no retry_policy key covers, so the call itself still leaves the
group - it falls through via router_settings.fallbacks. What did not happen is the
DEAD ROW leaving rotation: without a matching allowed_fails_policy entry the
per-exception threshold falls back to the router-level allowed_fails (1), so the
row needed a SECOND 404 to park and leaked one 404 to a caller on every other
pick.

This test pins the mechanism against the pinned proxy image
(ghcr.io/berriai/litellm:v1.98.0, containers/quadlet/fleet-litellm-proxy.container),
not against a mock of it:

  * _should_cooldown_based_on_deployment_policy returns None when the policy
    covers neither the exception type nor the model, which makes
    _should_cooldown_deployment fall through to the router-level policy
    (types/router.py, Router.get_allowed_fails_from_policy). That fall-through is
    what lets one router-level key reach all 81 rows, every one of which carries
    its own deployment-level allowed_fails_policy.
  * The cooldown a 404 applies is the ROW's own cooldown_time
    (_first_present(model_info, litellm_params, key="cooldown_time")), not the
    router-level 60 s - measured below on a row set to 21600 s.
  * The cooldown is written inside the failing acompletion call, before it
    raises, so the test reads it back with the router's own reader
    (CooldownCache.get_active_cooldowns) instead of sleeping on a clock.
  * The row stays in the router. It comes back when the cooldown expires and
    re-probes itself, which is what picks up a quota reset or a restored model.

Shape: the dead lane is the group's only order-1 row and the live lane is its
order-2 overflow row, so the first call deterministically picks the dead lane and
every later call falls to the overflow - the same "cooled row leaves the
candidate list, the next row in the group takes the job" path the fleet gets.
With two rows on the same order, simple-shuffle picks between them and the test
would be a coin flip.

No network beyond 127.0.0.1, no Redis, no API key. Run:
    python tests/test_router_404_fallthrough.py
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
import threading
import time
import warnings
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

pytest.importorskip("litellm")

import litellm  # noqa: E402
import yaml  # noqa: E402
from litellm import Router  # noqa: E402
from litellm.router_utils.cooldown_handlers import (  # noqa: E402
    _resolve_allowed_fails_from_policy,
)

ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "config" / "litellm-proxy.yaml"

DEAD_MODEL = "dead-lane"
LIVE_MODEL = "live-lane"

# The router-level policy config/litellm-proxy.yaml ships, minus the key under
# test. #9468, #9122 and #9248 set the other four.
BASE_POLICY = {
    "AuthenticationErrorAllowedFails": 0,
    "RateLimitErrorAllowedFails": 1,
    "TimeoutErrorAllowedFails": 1,
    "InternalServerErrorAllowedFails": 1,
}

# A worker call as the fleet makes it (Pi always streams upstream, but the
# parking decision is taken before the body is read, so a plain call exercises it).
MESSAGES = [{"role": "user", "content": "hello"}]

# How often the two cooldown polls below look again. Both are deadlines, not
# sleeps: the write lands inside the failing acompletion call, so the first read
# normally already sees it.
POLL_INTERVAL = 0.01

_LOCK = threading.Lock()
_HITS: dict[str, int] = {"dead": 0, "live": 0}


class _Handler(BaseHTTPRequestHandler):
    """A dead lane (404) and a live lane (200) on one loopback server."""

    def log_message(self, *args):  # keep the drill output readable
        pass

    def _reply(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
        if "/dead/" in self.path:
            with _LOCK:
                _HITS["dead"] += 1
            # The exact shape a provider answers when a free tier has ended
            # (CommandCode, 2026-10-08): HTTP 404, model_not_found in the body.
            self._reply(
                404,
                {
                    "error": {
                        "message": "This model is unavailable for free. The paid "
                        "version is available now - use this slug instead: "
                        "inclusionai/ling-3.0-flash-sante",
                        "type": "invalid_request_error",
                        "code": "model_not_found",
                    }
                },
            )
            return
        with _LOCK:
            _HITS["live"] += 1
        self._reply(
            200,
            {
                "id": "chatcmpl-test",
                "object": "chat.completion",
                "created": 0,
                "model": LIVE_MODEL,
                "choices": [
                    {
                        "index": 0,
                        "message": {"role": "assistant", "content": "ok"},
                        "finish_reason": "stop",
                    }
                ],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
            },
        )


@pytest.fixture(scope="module")
def server() -> ThreadingHTTPServer:
    """One loopback server with a dead lane and a live lane."""
    server = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield server
    server.shutdown()
    server.server_close()


@pytest.fixture(autouse=True)
def _reset_hits():
    _reset()
    yield


# Both the pytest path (the fixture above) and the drill at the bottom of this
# file go through _reset, so the two cannot drift apart.
def _reset() -> None:
    _HITS["dead"] = 0
    _HITS["live"] = 0


def _port(server: ThreadingHTTPServer) -> int:
    return server.server_address[1]


def _production_router_settings(policy: dict) -> dict:
    """router_settings as the shipped config sets them, with one policy.

    Read from the file rather than written out again, so the test follows the
    config: if a key is renamed or dropped, the test says which one instead of
    testing a setting the fleet no longer runs.
    """
    config = yaml.safe_load(CONFIG_PATH.read_text())
    settings = config["router_settings"]
    for key in ("routing_strategy", "cooldown_time", "allowed_fails", "num_retries", "fallbacks"):
        assert key in settings, f"router_settings.{key} is gone from {CONFIG_PATH.name}"
    return {
        "routing_strategy": settings["routing_strategy"],
        "cooldown_time": settings["cooldown_time"],
        "allowed_fails": settings["allowed_fails"],
        "num_retries": settings["num_retries"],
        "allowed_fails_policy": policy,
        # The shipped fallbacks, so the test runs the same fall-through the fleet
        # gets: worker-capable -> worker-cheap -> worker-capable. They never fire
        # here - the group's own order-2 row catches every call before the group
        # can be exhausted - and this router defines no worker-cheap group, so
        # they are carried for shape only and must stay unreachable.
        "fallbacks": settings["fallbacks"],
    }


def _production_row_policy() -> dict:
    """The deployment-level allowed_fails_policy a real row carries.

    All 81 rows in config/litellm-proxy.yaml carry one. If a future row does
    not, the test names that row instead of silently testing an empty policy.
    """
    config = yaml.safe_load(CONFIG_PATH.read_text())
    rows = config["model_list"]
    policies = [
        (row.get("model_info") or {}).get("allowed_fails_policy") for row in rows
    ]
    for row, policy in zip(rows, policies):
        name = (row.get("model_info") or {}).get("id", "<no id>")
        assert policy, f"row {name} carries no allowed_fails_policy"
    return policies[0]


def _router(server, *, policy, deployment_policy, cooldown_time=None):
    """One group, two rows: the dead lane first (order 1), the live lane second."""
    litellm_params_dead = {
        "model": f"openai/{DEAD_MODEL}",
        "api_base": f"http://127.0.0.1:{_port(server)}/dead/",
        "api_key": "not-used",
        "order": 1,
    }
    model_info_dead = {"id": DEAD_MODEL}
    if deployment_policy is not None:
        model_info_dead["allowed_fails_policy"] = deployment_policy
    if cooldown_time is not None:
        litellm_params_dead["cooldown_time"] = cooldown_time
    return Router(
        model_list=[
            {
                "model_name": "worker-capable",
                "litellm_params": litellm_params_dead,
                "model_info": model_info_dead,
            },
            {
                "model_name": "worker-capable",
                "litellm_params": {
                    "model": f"openai/{LIVE_MODEL}",
                    "api_base": f"http://127.0.0.1:{_port(server)}/live/",
                    "api_key": "not-used",
                    "order": 2,
                },
                "model_info": {"id": LIVE_MODEL},
            },
        ],
        **_production_router_settings(policy),
    )


def _cooldown(router, deployment_id: str, timeout: float = 10.0):
    """LiteLLM's own cooldown reader - the sync point this test waits on.

    CooldownCache.get_active_cooldowns is the read the next call makes, so
    waiting on it is waiting on the router's state rather than on a clock. The
    write lands inside the failing acompletion call, so the first read normally
    already sees it; the poll is a deadline, not a sleep.
    """
    deadline = time.monotonic() + timeout
    while True:
        active = router.cooldown_cache.get_active_cooldowns(
            [deployment_id], parent_otel_span=None
        )
        if active:
            return active[0][1]
        if time.monotonic() >= deadline:
            raise AssertionError(f"no cooldown for {deployment_id} within {timeout} s")
        time.sleep(POLL_INTERVAL)


def _cooldown_cleared(router, deployment_id: str, timeout: float = 10.0) -> None:
    """Wait until the router no longer reports this lane as parked."""
    deadline = time.monotonic() + timeout
    while True:
        if not router.cooldown_cache.get_active_cooldowns(
            [deployment_id], parent_otel_span=None
        ):
            return
        if time.monotonic() >= deadline:
            raise AssertionError(f"{deployment_id} stayed parked for {timeout} s")
        time.sleep(POLL_INTERVAL)


def _calls(router, count: int) -> list[str]:
    """`count` calls, each 200 or the raised exception name.

    The exception is the outcome under test, so a bare except is the point: the
    normal results are the live lane's name, and the abnormal one litellm raises
    when the group has no healthy row left (a 429 on an exhausted group, since
    NotFoundError itself is caught inside the group and falls through).
    """
    outcomes: list[str] = []

    async def _run() -> None:
        for _ in range(count):
            try:
                response = await router.acompletion(
                    model="worker-capable",
                    messages=MESSAGES,
                    stream=False,
                    timeout=30,
                )
                outcomes.append(str(response.model))
            except Exception as exc:  # noqa: BLE001 - the outcome IS the exception
                outcomes.append(type(exc).__name__)

    asyncio.run(_run())
    return outcomes


def _dead_hits(router, calls: int, deployment_id: str = DEAD_MODEL) -> tuple[int, list]:
    """Call `calls` times and wait for the dead lane's cooldown to land."""
    outcomes = _calls(router, calls)
    cooldown = _cooldown(router, deployment_id)
    return _HITS["dead"], (outcomes, cooldown)


# --------------------------------------------------------------------------- #
# the mechanism
# --------------------------------------------------------------------------- #


def test_one_404_parks_the_lane_and_the_call_falls_through(server):
    """The shipped policy parks on the first 404; the call still gets a 200."""
    router = _router(
        server,
        policy={**BASE_POLICY, "NotFoundErrorAllowedFails": 0},
        deployment_policy=None,
    )
    dead, (outcomes, cooldown) = _dead_hits(router, calls=3)

    assert dead == 1, f"the dead lane was picked {dead} times, expected 1"
    assert outcomes == [LIVE_MODEL] * 3, outcomes
    assert _HITS["live"] == 3
    # The parked row records the 404 it was parked for.
    assert cooldown["status_code"] == "404"


def test_two_404s_when_the_threshold_is_one(server):
    """Before #9469 the key was unset, so the router default of 1 applied."""
    router = _router(
        server,
        policy={**BASE_POLICY, "NotFoundErrorAllowedFails": 1},
        deployment_policy=None,
    )
    dead, (outcomes, cooldown) = _dead_hits(router, calls=3)

    assert dead == 2, f"the dead lane was picked {dead} times, expected 2"
    assert outcomes == [LIVE_MODEL] * 3
    assert cooldown["status_code"] == "404"


def test_the_router_key_reaches_a_row_with_its_own_deployment_policy(server):
    """Every production row carries a deployment-level policy.

    That is the merge-vs-replace question: if a deployment policy replaced the
    router policy, one router-level key could not reach any production row and
    the fix would be a no-op. v1.98.0 resolves the threshold PER EXCEPTION TYPE
    (Router.get_allowed_fails_from_policy reads _should_cooldown_based_on_deployment_policy
    first, then the router policy), so the row's own keys still apply and the
    router-level NotFoundErrorAllowedFails reaches the row.
    """
    deployment_policy = _production_row_policy()
    assert "NotFoundErrorAllowedFails" not in deployment_policy, (
        "the fixture must match production: no row names NotFoundError"
    )

    router = _router(
        server,
        policy={**BASE_POLICY, "NotFoundErrorAllowedFails": 0},
        deployment_policy=deployment_policy,
    )
    dead, (outcomes, cooldown) = _dead_hits(router, calls=3)
    assert dead == 1, f"the dead lane was picked {dead} times, expected 1"
    assert outcomes == [LIVE_MODEL] * 3
    assert cooldown["status_code"] == "404"

    # The row's policy is not discarded, it is read PER EXCEPTION TYPE: a 400 is
    # still the row's own threshold, and only a 404 (which the row does not name)
    # falls through to the router policy.
    assert _resolve_allowed_fails_from_policy(
        deployment_policy, litellm.BadRequestError(message="x", model="y", llm_provider="z")
    ) == 1
    assert _resolve_allowed_fails_from_policy(
        deployment_policy, litellm.NotFoundError(message="x", model="y", llm_provider="z")
    ) is None
    assert router.get_allowed_fails_from_policy(
        litellm.NotFoundError(message="x", model="y", llm_provider="z")
    ) == 0

    _reset()
    router_one = _router(
        server,
        policy={**BASE_POLICY, "NotFoundErrorAllowedFails": 1},
        deployment_policy=deployment_policy,
    )
    dead_one, _ = _dead_hits(router_one, calls=3)
    assert dead_one == 2, (
        f"with NotFoundErrorAllowedFails: 1 the dead lane was picked "
        f"{dead_one} times, expected 2 - the deployment policy would be "
        "replacing the router policy"
    )


def test_a_404_cooldown_lasts_the_rows_own_cooldown_time(server):
    """The cooldown is the row's, not the router-level 60 s.

    fleet-ops#9122 and #9248 park quota-walled rows for 21600 s so a daily or
    monthly wall outlasts the park. A 404 on such a row therefore parks it for
    6 h. That is the measured consequence of #9469: a 404 on a row with a long
    cooldown_time keeps that row out of rotation for that long. It is the same
    trade the 429 rows already make, and the row stays live and re-probes
    (test_the_lane_comes_back_after_its_cooldown_and_re_probes), so a model that
    comes back is picked up again. The alternative - two 404s - is the bug.
    """
    router = _router(
        server,
        policy={**BASE_POLICY, "NotFoundErrorAllowedFails": 0},
        deployment_policy=None,
        cooldown_time=21600,
    )
    dead, (outcomes, cooldown) = _dead_hits(router, calls=1)

    assert dead == 1
    assert cooldown["cooldown_time"] == 21600
    assert cooldown["status_code"] == "404"
    # The row is parked, not deleted: it is still a deployment of the group.
    assert DEAD_MODEL in [mid for mid in router.get_model_ids()]


def test_the_lane_comes_back_after_its_cooldown_and_re_probes(server):
    """A parked lane re-probes when its cooldown expires.

    This is the path that picks up a restored model or a reset quota, and the
    reason a long park is not a removal. Both waits are on the router's own
    cooldown cache: parked, then cleared.
    """
    router = _router(
        server,
        policy={**BASE_POLICY, "NotFoundErrorAllowedFails": 0},
        deployment_policy=None,
        cooldown_time=1,
    )

    async def _run() -> tuple[list[str], list[int]]:
        outcomes: list[str] = []
        parks: list[int] = []
        for _ in range(2):
            try:
                response = await router.acompletion(
                    model="worker-capable", messages=MESSAGES, stream=False, timeout=30
                )
                outcomes.append(str(response.model))
            except Exception as exc:  # noqa: BLE001 - the outcome IS the exception
                outcomes.append(type(exc).__name__)
            # Parked (the router's own reader), then the park expired (a clock,
            # because expiry is the one thing about a cooldown that is one).
            parks.append(_cooldown(router, DEAD_MODEL)["cooldown_time"])
            deadline = time.monotonic() + 10.0
            while router.cooldown_cache.get_active_cooldowns(
                [DEAD_MODEL], parent_otel_span=None
            ):
                assert time.monotonic() < deadline, f"{DEAD_MODEL} stayed parked"
                await asyncio.sleep(0.02)
        return outcomes, parks

    outcomes, parks = asyncio.run(_run())

    assert _HITS["dead"] == 2, (
        f"the lane was probed {_HITS['dead']} times, expected 2 - it did not "
        "come back after its cooldown"
    )
    assert outcomes == [LIVE_MODEL, LIVE_MODEL]
    # Each 404 parked it again, for the row's own cooldown_time.
    assert parks == [1, 1]


# --------------------------------------------------------------------------- #
# the shipped configuration
# --------------------------------------------------------------------------- #


def test_production_config_parks_on_the_first_404():
    """config/litellm-proxy.yaml ships the key that does this."""
    config = yaml.safe_load(CONFIG_PATH.read_text())
    policy = config["router_settings"]["allowed_fails_policy"]
    assert policy["NotFoundErrorAllowedFails"] == 0, (
        "router_settings.allowed_fails_policy.NotFoundErrorAllowedFails must be 0: "
        "a 404 is a withdrawn model and must park the row on the first one"
    )


def test_no_production_row_overrides_the_router_404_threshold():
    """No row's own allowed_fails_policy re-opens the two-404 leak.

    v1.98.0 resolves the threshold per exception type, row first, router second
    (Router.get_allowed_fails_from_policy), so a row naming
    NotFoundErrorAllowedFails: 1 needs two 404s to park and re-opens the leak on
    that row even with the router-level 0 (PR 9472 coordinator risk). The
    schema pins the row-level key to 0; this test pins the shipped config to
    the same rule for every row, not just the first one.
    """
    config = yaml.safe_load(CONFIG_PATH.read_text())
    for row in config["model_list"]:
        info = row.get("model_info") or {}
        name = info.get("id", "<no id>")
        policy = info.get("allowed_fails_policy")
        assert policy, f"row {name} carries no allowed_fails_policy"
        value = policy.get("NotFoundErrorAllowedFails")
        assert value in (None, 0), (
            f"row {name} sets NotFoundErrorAllowedFails: {value}: a row-level "
            "threshold resolves before the router policy, so only 0 keeps the "
            "first-404 park on that row"
        )


def test_production_config_keeps_the_fallthrough_shape():
    """The parked lane's job has somewhere to go.

    A parked row only helps if the group has another row: worker-capable and
    worker-cheap each need at least one order-2 overflow row (order filtering is
    applied after the cooldown filter in v1.98.0 router.py, proven by
    tests/test_router_order2_overflow.py) and router_settings.fallbacks must
    carry the worker net both ways so a parked lane is left, not retried.
    """
    config = yaml.safe_load(CONFIG_PATH.read_text())
    rows = config["model_list"]

    for group in ("worker-capable", "worker-cheap"):
        overflow = [
            row
            for row in rows
            if row["model_name"] == group
            and (row.get("litellm_params") or {}).get("order") == 2
        ]
        assert overflow, f"no order-2 row in the {group} group"

    fallbacks = config["router_settings"]["fallbacks"]
    assert {"worker-capable": ["worker-cheap"]} in fallbacks
    assert {"worker-cheap": ["worker-capable"]} in fallbacks


if __name__ == "__main__":  # the drill: python tests/test_router_404_fallthrough.py
    # litellm's global logging worker is bound to the first event loop in the
    # process, so the second asyncio.run in one process leaves one coroutine
    # un-awaited. It is litellm's, not this test's, and it is noise here.
    warnings.filterwarnings("ignore", message="coroutine .* was never awaited")

    failures = 0
    server = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    def check(label: str, fn) -> tuple[int, int]:
        global failures
        _reset()
        try:
            fn(server)
            print(f"PASS  {label}")
        except AssertionError as exc:
            failures += 1
            print(f"FAIL  {label}: {exc}")
        return _HITS["dead"], _HITS["live"]

    picks = {}
    picks["one 404"] = check(
        "one 404 parks the lane and the call falls through",
        test_one_404_parks_the_lane_and_the_call_falls_through,
    )
    picks["two 404s (before #9469)"] = check(
        "two 404s when the threshold is 1",
        test_two_404s_when_the_threshold_is_one,
    )
    picks["router key + row policy"] = check(
        "the router key reaches a row with its own deployment policy",
        test_the_router_key_reaches_a_row_with_its_own_deployment_policy,
    )
    check(
        "a 404 cooldown lasts the row's own cooldown_time",
        test_a_404_cooldown_lasts_the_rows_own_cooldown_time,
    )
    picks["re-probe after cooldown"] = check(
        "the lane comes back after its cooldown and re-probes",
        test_the_lane_comes_back_after_its_cooldown_and_re_probes,
    )
    check(
        "production config parks on the first 404",
        lambda _s: test_production_config_parks_on_the_first_404(),
    )
    check(
        "no production row overrides the router 404 threshold",
        lambda _s: test_no_production_row_overrides_the_router_404_threshold(),
    )
    check(
        "production config keeps the fallthrough shape",
        lambda _s: test_production_config_keeps_the_fallthrough_shape(),
    )

    for label, (dead, live) in picks.items():
        print(f"  {label}: dead-lane picks={dead} live-lane calls={live}")
    print(f"file: {os.path.relpath(CONFIG_PATH, ROOT)}")
    print("DRILL FAILED" if failures else "ALL PASS")
    server.shutdown()
    server.server_close()
    sys.exit(1 if failures else 0)
