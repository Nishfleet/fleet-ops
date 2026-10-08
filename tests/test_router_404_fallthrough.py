"""fleet-ops#9469: a 404 lane drops out of rotation on the first 404 and the
call falls through to the next lane in the group.

Runs against the pinned LiteLLM v1.98.0 Router with the proxy's production
router settings (cooldown_time 60, allowed_fails 1, num_retries 0,
simple-shuffle). LiteLLM v1.98.0's `_is_cooldown_required`
(litellm/router_utils/cooldown_handlers.py) accepts 404, so the failure
callback runs, but `should_cooldown_based_on_allowed_fails_policy` resolves the
threshold from `router_settings.allowed_fails_policy`. With the key unset it
falls back to the router-level `allowed_fails` (1) and the lane needs TWO 404s
to park; `router_settings.allowed_fails_policy.NotFoundErrorAllowedFails: 0`
parks it on the FIRST. The `dead_hits == 2` count below depends on that v1.98.0
rule (`updated_fails > allowed_fails`); a LiteLLM bump that changes it moves the
number. `test_production_config_parks_on_first_404` reads the shipped config so
the drill cannot pass on a policy the config does not carry.

The failure does not retry in-group: `Router.should_retry_this_error` hard-raises
on `litellm.NotFoundError` and `retry_policy` has no 404 field in v1.98.0. The
job leaves the group through the order-based fallback
(`Router.async_function_with_fallbacks_common_utils`, "ORDER-BASED FALLBACKS"),
which retargets the same model group to the next order level. That is the
production path: `worker-capable` has 49 order-1 rows and 2 order-2 rows, so a
404 on an order-1 free lane retargets to an order-2 paid lane; the explicit
`router_settings.fallbacks` (`worker-capable -> worker-cheap`) is the
cross-group net behind it. This test pins the order shape: a dead order-1 lane,
a live order-2 lane, and real `router.acompletion` calls through LiteLLM's own
failure path.

The upstream is a local HTTP server so the drill is deterministic and spends
nothing. It answers `/dead/chat/completions` with the OpenAI 404 body and
`/ok/chat/completions` with a valid chat completion, and counts hits. The lane
being "out of rotation" is measured the only way that matters: the next real
call does not reach the dead path again.
"""
import asyncio
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from litellm import Router

DEAD_MODEL = "fleet-ops-9469-promo-ended-probe"
LIVE_MODEL = "fleet-ops-9469-live-lane"
CALLS = 3


class _Upstream:
    """Local OpenAI-compatible upstream: one 404 path and one 200 path."""

    def __init__(self):
        self.hits = {"dead": 0, "ok": 0}
        self._server = None
        self._thread = None
        self.port = None

    def start(self):
        upstream = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):  # keep the drill output clean
                pass

            def _reply(self, status, payload):
                body = json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self):
                self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
                if "/dead/" in self.path:
                    upstream.hits["dead"] += 1
                    self._reply(
                        404,
                        {
                            "error": {
                                "message": "This model is unavailable for free. The paid version is available now.",
                                "type": "invalid_request_error",
                                "code": "model_not_found",
                            }
                        },
                    )
                elif "/ok/" in self.path:
                    upstream.hits["ok"] += 1
                    self._reply(
                        200,
                        {
                            "id": "chatcmpl-9469",
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
                else:
                    self._reply(500, {"error": {"message": f"unexpected path {self.path}"}})

        self._server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self._server.server_address[1]
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()
        return self

    def stop(self):
        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()


def _row(mid, order, path, port):
    return {
        "model_name": "worker-capable",
        "litellm_params": {
            "model": f"openai/{mid}",
            "api_base": f"http://127.0.0.1:{port}/{path}",
            "api_key": "k",
            "order": order,
        },
        "model_info": {"id": mid},
    }


def _router(port, not_found_policy):
    """Production router settings, plus the #9469 knob when asked for."""
    policy = {
        "AuthenticationErrorAllowedFails": 0,
        "RateLimitErrorAllowedFails": 1,
        "TimeoutErrorAllowedFails": 1,
        "InternalServerErrorAllowedFails": 1,
    }
    if not_found_policy is not None:
        policy["NotFoundErrorAllowedFails"] = not_found_policy
    return Router(
        model_list=[
            _row(DEAD_MODEL, 1, "dead", port),
            _row(LIVE_MODEL, 2, "ok", port),
        ],
        routing_strategy="simple-shuffle",
        cooldown_time=60,
        allowed_fails=1,
        num_retries=0,
        allowed_fails_policy=policy,
    )


async def _calls(router, upstream, n):
    """N real calls in one event loop, so cooldown tasks finish before the next."""
    answered = []
    for _ in range(n):
        try:
            resp = await router.acompletion(
                model="worker-capable",
                messages=[{"role": "user", "content": "reply with the single word: ok"}],
                stream=False,
                timeout=30,
            )
            answered.append(resp.model)
        except Exception as exc:  # a failed job is the bug: record, do not raise
            answered.append(f"{type(exc).__name__}: {str(exc)[:80]}")
        # 0.2s was measured sufficient on v1.98.0 for the failure callback's
        # cooldown task to land before the next pick.
        await asyncio.sleep(0.2)
    return answered


def _run_case(not_found_policy):
    upstream = _Upstream().start()
    try:
        router = _router(upstream.port, not_found_policy)
        answered = asyncio.run(_calls(router, upstream, CALLS))
        return {"answered": answered, "dead_hits": upstream.hits["dead"], "ok_hits": upstream.hits["ok"]}
    finally:
        upstream.stop()


def test_one_404_parks_the_lane_and_the_call_falls_through():
    """Origin/main leaks a 404 on the 2nd call; the branch parks on the first."""
    before = _run_case(not_found_policy=None)
    after = _run_case(not_found_policy=0)

    # Every call answers from the live order-2 lane: the order-based fallback
    # carries the job there after the dead order-1 lane 404s. LiteLLM may
    # prefix the id, so match on the lane name, not the exact string.
    for case in (before, after):
        assert all(LIVE_MODEL in a for a in case["answered"]), case
        assert not any(DEAD_MODEL in a for a in case["answered"]), case

    # Origin/main: the lane stays in rotation until its second 404, so the 2nd
    # call reaches the dead path again; only then does it park.
    assert before["dead_hits"] == 2, before
    assert before["ok_hits"] == CALLS, before

    # Branch: the first 404 parks the lane, so calls 2 and 3 never reach it.
    assert after["dead_hits"] == 1, after
    assert after["ok_hits"] == CALLS, after


def test_production_config_parks_on_first_404():
    """The shipped config carries the key, so the drill above matches it."""
    import yaml

    config = yaml.safe_load(
        (Path(__file__).resolve().parent.parent / "config" / "litellm-proxy.yaml").read_text()
    )
    policy = config["router_settings"]["allowed_fails_policy"]
    assert policy["NotFoundErrorAllowedFails"] == 0, policy


if __name__ == "__main__":
    for label, policy in (("origin/main (no NotFoundErrorAllowedFails)", None), ("branch (NotFoundErrorAllowedFails: 0)", 0)):
        case = _run_case(policy)
        print(f"{label}:")
        print(f"  answered by:   {case['answered']}")
        print(f"  dead-path hits: {case['dead_hits']} of {CALLS} calls")
    test_one_404_parks_the_lane_and_the_call_falls_through()
    test_production_config_parks_on_first_404()
    print("PASS one 404 parks the lane and the call falls through")
