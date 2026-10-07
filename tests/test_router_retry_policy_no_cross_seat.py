"""fleet-ops#9375: cut the in-router retry budget for a pinned worker session.

Before the change the `retry_policy` block shipped AuthenticationErrorRetries:2 /
RateLimitErrorRetries:2 / InternalServerErrorRetries:2. On a pinned seat that
fail-fast 429s, the router spent a second (and third) in-group attempt on a fresh
seat, re-sending the whole cold prompt. The fix cuts the counts to 0 (401, which
can never recover) / 1 (429, 500) so the worker group spends at most one attempt
before the call reaches the fallback group or Pi's own retry. Pi keeps
x-litellm-session-id and the session pin is first-writer-wins, so a pinned seat
that recovers is re-picked on the next call.

What this does NOT do: stock litellm 1.98.0 runs the fallback group on the first
retryable error, so a briefly-failing pinned seat is not guaranteed a same-row
retry. These tests measure the in-group pick count, not a same-seat retry.

These tests run in-process against litellm 1.98.0 (the version pinned for prod)
and need no Redis: with `optional_pre_call_checks: ["session_affinity"]` and no
redis_url the DeploymentAffinityCheck degrades to a pod-local pin. The affinity
lookup is the same code path the proxy uses; only the Redis Lua-script claim
differs, not the routing decision. They also run without a network - a plain
http.server answers one row 429 and the peers 200.

Run with the interpreter that has litellm 1.98.0 installed:
  <litellm-python> tests/test_router_retry_policy_no_cross_seat.py
or under pytest from the repo root if litellm is on the path.
"""
from __future__ import annotations

import asyncio
import http.server
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
        if _CURRENT_SERVER:
            _CURRENT_SERVER[0].hits.append(self.path)
        path = self.path
        if "/fail" in path:
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
        # Pin seat-a the way a first successful call does. This router is
        # in-memory (no redis_url) while prod uses redis_url, but the affinity
        # lookup the routing decision depends on is the same.
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
    """The production retry_policy must carry the fleet-ops#9375 values; if someone
    flips AuthenticationErrorRetries back to >=1 or RateLimit/InternalServerError
    back to 2, the audit numbers regress and this gate fails."""
    rp = _load_retry_policy()
    assert rp["AuthenticationErrorRetries"] == 0
    assert rp["RateLimitErrorRetries"] == 1
    assert rp["InternalServerErrorRetries"] == 1


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


def test_internal_server_error_is_inert_on_litellm_1_98_0():
    # litellm 1.98.0's get_num_retries_from_retry_policy has no InternalServerError
    # branch (litellm.types.router.RetryPolicy ships the field but the lookup omits
    # it), so InternalServerErrorRetries is dead config until litellm adds the handler:
    # it resolves to None and the Router falls back to num_retries (0) -> exactly one
    # attempt before the fallback group, never an in-group hop.
    rp = RetryPolicy(**RP_PROPOSED)
    exc = InternalServerError(message="x", llm_provider="openai", model="m", response=None)
    assert get_num_retries_from_retry_policy(exc, rp) is None


# --------------------------------------------------------------------------- #
# End-to-end: a pinned seat that 429s on every attempt (a rate-limited wall).
# --------------------------------------------------------------------------- #
def test_shipped_policy_makes_two_in_group_picks_on_a_429_wall():
    server = _Server()
    try:
        attempts, outcome, pin = asyncio.run(_run(server, RP_SHIPPED, "s-shipped-wall"))
    finally:
        server.close()
    # shipped: the pinned seat 429s, the router spends a second in-group attempt on
    # seat-c (another cold re-send), then the worker-cheap fallback answers. Counts,
    # not order, are asserted because the in-group pick is a shuffle.
    assert _counts(attempts) == {
        "/fail/chat/completions": 1,
        "/failcapable/chat/completions": 1,
        "/okcheap/chat/completions": 1,
    }, attempts
    assert outcome == "ok"
    assert pin == {"model_id": "seat-a"}, pin


def test_proposed_policy_makes_one_in_group_pick_on_a_429_wall():
    server = _Server()
    try:
        attempts, outcome, pin = asyncio.run(_run(server, RP_PROPOSED, "s-proposed-wall"))
    finally:
        server.close()
    # proposed: the capped budget leaves a single in-group attempt (the pinned seat)
    # before the worker-cheap fallback. One fewer in-group pick -> one fewer cold re-send.
    assert _counts(attempts) == {
        "/fail/chat/completions": 1,
        "/okcheap/chat/completions": 1,
    }, attempts
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
        test_config_retry_policy_is_the_fleet_ops_9375_fix,
        test_authentication_error_gets_zero_retries,
        test_rate_limit_gets_one_retry,
        test_internal_server_error_is_inert_on_litellm_1_98_0,
        test_shipped_policy_makes_two_in_group_picks_on_a_429_wall,
        test_proposed_policy_makes_one_in_group_pick_on_a_429_wall,
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
