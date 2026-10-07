"""fleet-ops#9375: confine in-router retries to the same seat.

Before the change (`retry_policy` shipped with AuthenticationErrorRetries:2 /
RateLimitErrorRetries:2 / InternalServerErrorRetries:2) a mid-session 429/500
spun back up within the request and hopped to a different seat on the 2nd (or 3rd)
attempt, re-sending the whole prompt cold. The fix cuts the retry counts to
0 (401, which can never recover) / 1 (429, 500) so the router retries the pinned
seat at most once before the call falls back to Pi's own retry, which keeps the
session id and therefore the session pin - so the next pick still routes back to
the pinned seat once that seat is healthy again.

These tests run in-process against litellm 1.98.0 (the version pinned in this
repo's wheel cache / prod) and need no Redis: with `optional_pre_call_checks:
["session_affinity"]` and no redis_url the DeploymentAffinityCheck degrades to a
pod-local pin (the same code path the proxy uses; only the Lua-script claim
differs, not the routing decision). They also run without a network - a plain
http.server answers one row 429 and the peers 200.

Run directly with the pinned venv (no pytest there):
  /home/nish/.local/venvs/litellm/bin/python \
      tests/test_router_retry_policy_no_cross_seat.py
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

PIN_KEY = "deployment_affinity:v1:session:worker-capable:unscoped:{sid}"


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
        await router.cache.async_set_cache(
            key=PIN_KEY.format(sid=sid), value={"model_id": "seat-a"}, ttl=3600)
        outcome = "ok"
        try:
            await router.acompletion(model="worker-capable",
                                     messages=[{"role": "user", "content": "hi"}],
                                     metadata={"session_id": sid})
        except Exception as e:  # noqa: BLE001
            outcome = type(e).__name__
        attempts = list(server.hits)
        pin = router.cache.in_memory_cache.cache_dict.get(PIN_KEY.format(sid=sid))
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
def test_shipped_policy_makes_three_upstream_picks_on_a_429_wall():
    server = _Server()
    try:
        attempts, outcome, pin = asyncio.run(_run(server, RP_SHIPPED, "s-shipped-wall"))
    finally:
        server.close()
    # shipped: attempt-2 re-routes off the pinned seat after the 429 cooldown lands,
    # attempt-3 hops again; the request only survives via the worker-cheap fallback.
    assert attempts == ["/fail/chat/completions", "/failcapable/chat/completions", "/okcheap/chat/completions"], attempts
    assert outcome == "ok"
    assert pin == {"model_id": "seat-a"}, pin


def test_proposed_policy_makes_two_upstream_picks_on_a_429_wall():
    server = _Server()
    try:
        attempts, outcome, pin = asyncio.run(_run(server, RP_PROPOSED, "s-proposed-wall"))
    finally:
        server.close()
    # proposed: the single same-row retry is exhausted; the only remaining hop is the
    # single fallback to worker-cheap. One fewer in-group pick -> one fewer re-sent prompt.
    assert attempts == ["/fail/chat/completions", "/okcheap/chat/completions"], attempts
    assert outcome == "ok"
    assert pin == {"model_id": "seat-a"}, pin


def test_pin_survives_a_failed_then_fallback_success():
    # First-writer-wins: the successful fallback attempt (seat-b) must NOT overwrite
    # the original pin (seat-a). Pi's own retry keeps the session id, so the next call
    # re-pinned to seat-a and, once it is healthy again, lands on the same seat.
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
        test_shipped_policy_makes_three_upstream_picks_on_a_429_wall,
        test_proposed_policy_makes_two_upstream_picks_on_a_429_wall,
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
