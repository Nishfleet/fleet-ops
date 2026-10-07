"""fleet-ops#9375: cut the in-router retry budget for a pinned worker session.

Before the change the `retry_policy` block shipped AuthenticationErrorRetries:2 /
RateLimitErrorRetries:2 / InternalServerErrorRetries:2. On a pinned seat that
fail-fast 429s, the router then spent its second in-group attempt on a *different*
seat, re-sending the whole cold prompt, and a third after that. The fix cuts the
counts to 0 (401, which can never recover) / 1 (429), so the worker group spends
exactly one in-group retry - which litellm sends back to the row that just failed -
before the call reaches the fallback group or Pi's own retry. Pi keeps
x-litellm-session-id and the session pin is first-writer-wins, so a pinned seat
that recovers is re-picked on the next call.

What this does NOT do (the honest limits, each pinned by a test below):

- Backoff. `Router._time_to_sleep_before_retry` returns 0 as soon as the group has
  one healthy row left, so the same-row retry is instant. "retry the same row once
  after the backoff" is met in *which row*, not in *when*.
- A hard-down row. Once the in-group budget is spent, litellm 1.98.0 runs the
  fallback group on the same call, so one cold re-send on the fallback seat stays.
  Cutting it needs litellm to suppress the fallback for a retryable error.
- 500. `RetryPolicy` ships `InternalServerErrorRetries`, but 1.98.0's
  `get_num_retries_from_retry_policy` has no `InternalServerError` branch, so that
  field is dead config until litellm adds the handler.

Measured on this host, litellm 1.98.0, one call into a pinned seat that 429s:

  shipped 2/2/2 -> 3 in-group picks (/fail, /fail, /failcapable) + 1 fallback
  fixed   0/1/1 -> 2 in-group picks (/fail, /fail - the same row) + 1 fallback
  fixed, the 429 clears on the 2nd call -> 2 in-group picks, 0 fallbacks

Two cross-seat re-sends become one, and a briefly-limited row is no longer kicked
to another seat at all.

These tests run in-process against litellm 1.98.0 (the version pinned for prod)
and need no Redis: with `optional_pre_call_checks: ["session_affinity"]` and no
redis_url the DeploymentAffinityCheck degrades to a pod-local pin. The affinity
lookup the routing decision depends on is the same code path the proxy uses, and
the routing decision itself is what these tests assert; the Redis Lua-script
claim (first-writer-wins across proxy replicas) is NOT exercised here, so nothing
below is a claim about it. They also run without a network - a plain
http.server answers one row 429 and the peers 200.

CI does not run this file yet: https://github.com/Nishfleet/fleet-ops/issues/9427
carries the job, and the worker App token has no Workflows permission, so a
worker cannot push the ci.yml change that would run it. Until that lands, the
pick counts below are only as live as the last hand run, and the run command is:

  /home/nish/.local/venvs/litellm/bin/python tests/test_router_retry_policy_no_cross_seat.py

It runs under pytest from the repo root too, with that interpreter on the path.
"""
from __future__ import annotations

import asyncio
import http.client
import http.server
import importlib.metadata
import json
import socketserver
import threading
from typing import List

import litellm
from litellm import Router
from litellm.exceptions import AuthenticationError, InternalServerError, RateLimitError
from litellm.router_utils.get_retry_from_policy import get_num_retries_from_retry_policy
from litellm.router_utils.pre_call_checks.deployment_affinity_check import DeploymentAffinityCheck
from litellm.types.router import RetryPolicy

import yaml

CONFIG_PATH = "config/litellm-proxy.yaml"

# The litellm the proxy runs, as of this commit. Every behavioural number in this
# file and in the retry_policy comment in config/litellm-proxy.yaml is a
# measurement of this version, so the version is asserted rather than described:
# a bump that changes the same-row retry, the fallback timing, or the inert
# InternalServerErrorRetries field fails here instead of quietly making those
# comments wrong. Bump it in the same PR that re-measures, never on its own.
# This constant is also the one home for the version: the CI job that will run
# this file reads the pin from here (issue 9427), so the pin and the test cannot
# drift apart.
PINNED_LITELLM = "1.98.0"

# fleet-ops#9375 as written in this PR (the "old" values the audit measured).
RP_SHIPPED = {
    "AuthenticationErrorRetries": 2,
    "RateLimitErrorRetries": 2,
    "TimeoutErrorRetries": 1,
    "InternalServerErrorRetries": 2,
    "BadRequestErrorRetries": 1,
    "ContentPolicyViolationErrorRetries": 0,
}
# fleet-ops#9375 as the fix ships it.
RP_PROPOSED = {
    "AuthenticationErrorRetries": 0,
    "RateLimitErrorRetries": 1,
    "TimeoutErrorRetries": 1,
    "InternalServerErrorRetries": 1,
    "BadRequestErrorRetries": 1,
    "ContentPolicyViolationErrorRetries": 0,
}

# A zeroed-out budget, for the contrast tests only.
RP_ZERO = {k: 0 for k in RP_PROPOSED}


def _pin_key(session_id: str) -> str:
    """The exact pin key litellm's DeploymentAffinityCheck reads and writes, taken
    from litellm itself so a key-shape change cannot silently pass this test."""
    return DeploymentAffinityCheck.get_session_affinity_cache_key(
        model_group="worker-capable", session_id=session_id, user_key=None)


def _counts(paths: List[str]) -> dict:
    counts: dict = {}
    for path in paths:
        counts[path] = counts.get(path, 0) + 1
    return counts


# --------------------------------------------------------------------------- #
# HTTP mock: /fail -> 429 wall, /okcapable -> 200, /okcheap -> 200
# --------------------------------------------------------------------------- #
class _Handler(http.server.BaseHTTPRequestHandler):
    """Answers the /fail rows with a real 429 JSON body so LiteLLM raises
    RateLimitError (an HTML/empty 429 body is re-read as OpenAIException ->
    APIError 501, which is a different code path)."""

    protocol_version = "HTTP/1.1"

    def do_POST(self):
        # No server registered: a future test that forgets the push would watch
        # its assertions pass against a mock that answers everything 200, which
        # is the quiet way to prove nothing.
        if not _CURRENT_SERVER:
            raise RuntimeError("_Handler fired with no _CURRENT_SERVER registered; "
                               "append the server in the test's try block")
        # The body must be read before the response is written. litellm holds the
        # connection open (HTTP/1.1), so if those bytes stay in the socket buffer
        # the next request on this connection is parsed as
        # '<body>POST /path HTTP/1.1' and the stdlib answers 501 'Unsupported
        # method' - no hit is recorded, so a real retry is silently dropped from
        # the count these tests are built on. See
        # test_the_mock_reads_the_request_body.
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        _CURRENT_SERVER[0].hits.append(self.path)
        path = self.path
        if "/fail" in path:
            server = _CURRENT_SERVER[0]
            # fail_first_only: the /fail row 429s once then answers 200, to probe
            # whether litellm retries the same row. /failcapable always 429s.
            transient = bool(getattr(server, "fail_first_only", False)
                             and path.startswith("/fail/") and "failcapable" not in path)
            fail_hits = sum(1 for h in server.hits
                            if h.startswith("/fail/") and "failcapable" not in h)
            if not transient or fail_hits == 1:
                body = json.dumps({"error": {
                    "message": "rate limit reached", "type": "rate_limit_error",
                    "code": "rate_limit_exceeded",
                }}).encode()
                self.send_response(429)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
        body = json.dumps({
            "id": "x", "object": "chat.completion", "created": 0,
            "choices": [{"index": 0, "message": {"role": "assistant", "content": "ok"}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 100, "completion_tokens": 2, "total_tokens": 102},
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class _Server:
    """Tiny per-call HTTP mock that records the path of every upstream POST."""

    def __init__(self):
        srv = socketserver.ThreadingTCPServer(("127.0.0.1", 0), _Handler)
        srv.daemon_threads = True
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.port = srv.server_address[1]
        self.hits: List[str] = []
        self.fail_first_only = False
        self._srv = srv

    def close(self):
        self._srv.shutdown()
        self._srv.server_close()


_CURRENT_SERVER: List[_Server] = []


def _rows(port):
    return [
        {"model_name": "worker-capable",
         "litellm_params": {"model": "openai/seat-a", "api_base": f"http://127.0.0.1:{port}/fail", "api_key": "k"},
         "model_info": {"id": "seat-a", "supports_prompt_caching": True}},
        {"model_name": "worker-capable",
         "litellm_params": {"model": "openai/seat-c", "api_base": f"http://127.0.0.1:{port}/failcapable", "api_key": "k"},
         "model_info": {"id": "seat-c", "supports_prompt_caching": True}},
        {"model_name": "worker-cheap",
         "litellm_params": {"model": "openai/seat-b", "api_base": f"http://127.0.0.1:{port}/okcheap", "api_key": "k"},
         "model_info": {"id": "seat-b", "supports_prompt_caching": True}},
    ]


async def _run(server, retry_policy, sid):
    server.hits.clear()
    _CURRENT_SERVER.append(server)
    litellm.callbacks = []
    try:
        router = Router(
            model_list=_rows(server.port),
            routing_strategy="simple-shuffle",
            num_retries=0, cooldown_time=60, allowed_fails=1,
            optional_pre_call_checks=["prompt_caching", "session_affinity"],
            fallbacks=[{"worker-capable": ["worker-cheap"]}],
            deployment_affinity_ttl_seconds=3600,
            retry_policy=retry_policy,
        )
        # Pin seat-a the way a first successful call does. These Router values
        # mirror prod router_settings: num_retries 0, allowed_fails 1,
        # cooldown_time 60, optional_pre_call_checks ["prompt_caching",
        # "session_affinity"], and the default deployment_affinity_ttl_seconds
        # (3600). The one difference is redis_url (prod uses it, this test does
        # not), so what is exercised is the affinity lookup the routing decision
        # depends on and the routing decision itself - not the Redis Lua-script
        # claim, which is out of scope for these tests.
        await router.cache.async_set_cache(
            key=_pin_key(sid), value={"model_id": "seat-a"}, ttl=3600)
        outcome = "ok"
        try:
            await router.acompletion(model="worker-capable",
                                     messages=[{"role": "user", "content": "hi"}],
                                     metadata={"session_id": sid})
        except Exception as e:  # noqa: BLE001
            outcome = type(e).__name__
        attempts = list(server.hits)
        pin = await router.cache.async_get_cache(key=_pin_key(sid))
        return attempts, outcome, pin
    finally:
        _CURRENT_SERVER.pop()
        litellm.callbacks = []


# --------------------------------------------------------------------------- #
# Config gate
# --------------------------------------------------------------------------- #
def _load_retry_policy():
    with open(CONFIG_PATH, "rb") as fh:
        cfg = yaml.safe_load(fh)
    return cfg["router_settings"]["retry_policy"]


def test_config_retry_policy_is_the_fleet_ops_9375_fix():
    """The production retry_policy must carry the fleet-ops#9375 values; the schema
    bounds the whole block and this gate holds the actual numbers. If someone
    flips AuthenticationErrorRetries back to >=1, or RateLimit / Timeout /
    InternalServerError back to 2, the audit numbers regress and this gate fails."""
    rp = _load_retry_policy()
    assert rp == RP_PROPOSED, rp


def test_the_pinned_litellm_is_the_one_these_numbers_were_measured_on():
    # The behavioural tests below assert pick counts and a same-row retry, which
    # are litellm-version facts. A silent bump invalidates every number in this
    # file and in the retry_policy comment in config/litellm-proxy.yaml, so the
    # version is a gate, not prose.
    assert importlib.metadata.version("litellm") == PINNED_LITELLM, (
        f"litellm {importlib.metadata.version('litellm')} != {PINNED_LITELLM}; "
        "re-measure the picks and update PINNED_LITELLM in the same PR")


# --------------------------------------------------------------------------- #
# Unit-level: the retry count the Router actually resolves per error class.
# --------------------------------------------------------------------------- #
def test_authentication_error_gets_zero_retries():
    rp = RetryPolicy(**RP_PROPOSED)
    assert get_num_retries_from_retry_policy(AuthenticationError("401", "openai", "m", None), rp) == 0


def test_rate_limit_gets_one_retry():
    rp = RetryPolicy(**RP_PROPOSED)
    exc = RateLimitError(message="x", llm_provider="openai", model="m")
    assert get_num_retries_from_retry_policy(exc, rp) == 1


def test_the_same_row_retry_has_no_backoff():
    # Router._time_to_sleep_before_retry returns 0 the moment the group still has
    # one healthy row (litellm/router.py: "return 0" when healthy_deployments is
    # non-empty), so the retry the issue asks for lands immediately. That is why
    # the fix counts rows and not seconds, and why "after the backoff" is only
    # half satisfied: the backoff sits in Pi's own retry, not in the router.
    router = Router(model_list=_rows(0), routing_strategy="simple-shuffle", num_retries=0,
                    retry_policy=RP_PROPOSED)
    exc = RateLimitError(message="x", llm_provider="openai", model="m")
    sleep = router._time_to_sleep_before_retry(
        e=exc, remaining_retries=1, num_retries=1,
        healthy_deployments=_rows(0), all_deployments=_rows(0))
    assert sleep == 0, sleep


def test_the_mock_reads_the_request_body():
    # Pin the bug this file shipped with once already. A handler that never reads
    # the request body leaves it in the socket buffer and the next request on the
    # same keep-alive connection is answered 501 with no hit recorded, so the
    # router's real in-group pick count came out one lower than it is.
    server = _Server()
    try:
        _CURRENT_SERVER.append(server)
        conn = http.client.HTTPConnection("127.0.0.1", server.port, timeout=30)
        payload = json.dumps({"messages": [{"role": "user", "content": "hi"}], "model": "seat-a"})
        for _ in range(2):
            conn.request("POST", "/fail/chat/completions", body=payload,
                         headers={"Content-Type": "application/json"})
            resp = conn.getresponse()
            assert resp.status == 429, (resp.status, resp.read())
            resp.read()
        conn.close()
        assert server.hits == ["/fail/chat/completions", "/fail/chat/completions"], server.hits
    finally:
        _CURRENT_SERVER.pop()
        server.close()


def test_internal_server_error_is_inert_on_litellm_1_98_0():
    # litellm 1.98.0's get_num_retries_from_retry_policy has no InternalServerError
    # branch (litellm.types.router.RetryPolicy ships the field but the lookup omits
    # it), so InternalServerErrorRetries is dead config until litellm adds the handler:
    # it resolves to None and the Router falls back to num_retries (0) -> exactly one
    # attempt before the fallback group, never an in-group hop.
    #
    # This and the no-backoff test below read litellm internals, so both are the
    # litellm upgrade tripwires: a litellm bump that changes either shape fails CI
    # and the numbers in this file and in the config comment must be re-measured.
    rp = RetryPolicy(**RP_PROPOSED)
    exc = InternalServerError(message="x", llm_provider="openai", model="m", response=None)
    assert get_num_retries_from_retry_policy(exc, rp) is None


# --------------------------------------------------------------------------- #
# End-to-end: a pinned seat that 429s on every attempt (a rate-limited wall).
# --------------------------------------------------------------------------- #
def _in_group(attempts):
    """Picks that stayed in the worker-capable group (seat-a / seat-c) as opposed to
    the worker-cheap fallback."""
    return [p for p in attempts if "/fail" in p]


def test_shipped_policy_spends_two_retries_on_two_seats_on_a_429_wall():
    server = _Server()
    try:
        attempts, outcome, pin = asyncio.run(_run(server, RP_SHIPPED, "s-shipped-wall"))
    finally:
        server.close()
    # shipped: the pinned seat 429s, litellm spends retry #1 back on the same row,
    # then retry #2 hops to seat-c - a second seat, a second cold re-send - before
    # the worker-cheap fallback answers. Counts, not order, are asserted because
    # the in-group pick is a shuffle.
    ing = _in_group(attempts)
    assert len(ing) == 3, attempts
    assert len(set(ing)) == 2, attempts          # two different seats attempted
    assert attempts.count("/okcheap/chat/completions") == 1, attempts
    assert outcome == "ok"
    assert pin == {"model_id": "seat-a"}, pin


def test_the_fix_retries_the_row_that_failed_not_a_peer():
    server = _Server()
    try:
        attempts, outcome, pin = asyncio.run(_run(server, RP_PROPOSED, "s-proposed-wall"))
    finally:
        server.close()
    # proposed: the capped budget leaves exactly one retry and litellm sends it back
    # to the row that just 429d, so only the fallback hop is a cross-seat re-send.
    ing = _in_group(attempts)
    assert len(ing) == 2, attempts
    assert len(set(ing)) == 1, attempts
    # Held over 30 runs: the worker-capable group is a shuffle over seat-a and
    # seat-c, so which row the first (pinned) attempt picks is not fixed, but the
    # retry came back to the row that just failed in every one of them - the
    # affinity check re-scores the row in flight. Assert the property, not the
    # seat name, so a red CI here means the router really changed.
    assert attempts.count("/okcheap/chat/completions") == 1, attempts
    assert outcome == "ok"
    assert pin == {"model_id": "seat-a"}, pin


def test_a_transient_429_recovers_on_the_row_it_hit():
    # The headline the issue asks for. When the pinned seat's 429 clears on the
    # second call, the single retry the fix allows lands on that same row and
    # answers 200, so the worker-cheap fallback never fires and no cold prompt is
    # re-sent to another seat. Zero retries (not the fix) would kick the call to
    # the fallback instead - see test_zero_retries_hit_the_fallback_on_a_transient_429.
    server = _Server()
    server.fail_first_only = True
    try:
        attempts, outcome, pin = asyncio.run(_run(server, RP_PROPOSED, "s-transient-429"))
    finally:
        server.close()
    assert _in_group(attempts) == [
        "/fail/chat/completions", "/fail/chat/completions"], attempts
    assert attempts.count("/okcheap/chat/completions") == 0, attempts
    assert outcome == "ok"
    assert pin == {"model_id": "seat-a"}, pin


def test_zero_retries_hit_the_fallback_on_a_transient_429():
    # The contrast that shows the retry is doing the work: with no retry at all the
    # one transient 429 costs a cold re-send on the fallback seat.
    server = _Server()
    server.fail_first_only = True
    try:
        attempts, outcome, pin = asyncio.run(_run(server, RP_ZERO, "s-transient-zero"))
    finally:
        server.close()
    assert _in_group(attempts) == ["/fail/chat/completions"], attempts
    assert attempts.count("/okcheap/chat/completions") == 1, attempts
    assert outcome == "ok"
    assert pin == {"model_id": "seat-a"}, pin


def test_pin_survives_a_failed_then_fallback_success():
    # First-writer-wins: the fallback success on seat-b must NOT overwrite the pin
    # (seat-a). Pi's own retry keeps the session id, so the next call re-pins to
    # seat-a and, once it is healthy, lands on the same seat again.
    server = _Server()
    try:
        _, _, pin = asyncio.run(_run(server, RP_PROPOSED, "s-pin-survives"))
    finally:
        server.close()
    assert pin == {"model_id": "seat-a"}


if __name__ == "__main__":
    fns = [
        test_the_pinned_litellm_is_the_one_these_numbers_were_measured_on,
        test_config_retry_policy_is_the_fleet_ops_9375_fix,
        test_authentication_error_gets_zero_retries,
        test_rate_limit_gets_one_retry,
        test_internal_server_error_is_inert_on_litellm_1_98_0,
        test_the_same_row_retry_has_no_backoff,
        test_the_mock_reads_the_request_body,
        test_shipped_policy_spends_two_retries_on_two_seats_on_a_429_wall,
        test_the_fix_retries_the_row_that_failed_not_a_peer,
        test_a_transient_429_recovers_on_the_row_it_hit,
        test_zero_retries_hit_the_fallback_on_a_transient_429,
        test_pin_survives_a_failed_then_fallback_success,
    ]
    failures = 0
    for fn in fns:
        try:
            fn()
        except AssertionError as e:
            failures += 1
            print(f"FAIL {fn.__name__}: {e}")
        except Exception as e:  # noqa: BLE001
            failures += 1
            print(f"ERROR {fn.__name__}: {type(e).__name__}: {e}")
        else:
            print(f"ok   {fn.__name__}")
    print(f"\n{len(fns) - failures}/{len(fns)} passed")
    raise SystemExit(1 if failures else 0)
