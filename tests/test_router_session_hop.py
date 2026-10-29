"""fleet-ops#9412 item 3: the session-hop drill on the pinned litellm.

The question the drill answers: a worker session is pinned to one row, that row
starts 429ing, the router cools it, and the session sends 100 more calls. How
many of those calls land on a row other than the one the call before used?

Measured on litellm 1.105.0, the pin in
containers/quadlet/fleet-litellm-proxy.container, with the router settings
config/litellm-proxy.yaml ships (session_affinity, cooldown_time 60,
allowed_fails 1, deployment_affinity_ttl_seconds 600): 62 of 99 hops, across 3 distinct
rows. Re-claim the pin to a healthy row - which is what the #9411 fix does - and the
same 100 calls hop 0 of 99 times; the drill's 2% gate is met by that one change and
by nothing else in this file.
The gate in the drill is the 2% #9412 asks for, so the drill is red on this
release and carries xfail(strict=True) - the same "documents the leak without
blocking a PR queue" the issue asks a continue-on-error job for, in the one
form CI already runs. The image bump in #9411 makes the session pinned to a
cooled row re-claim a healthy row instead of re-shuffling the group, and then
this test XPASSes; strict xfail turns that into a failure, so the same PR must
drop the marker and the gate is hard.

Why a test and not the ci.yml job #9412 asked for: `ratchet / ratchet` allows 0
or fewer net added code lines under .github/workflows, .github/actions, scripts
and bin. The job as first written (PR #10698) measured net +74, and a new job
cannot bring that number down. tests/test_router_*.py already runs in ci's
`unit` job inside the pinned litellm interpreter (the step reads the same
version this file asserts through tests/router_litellm_pin.py), so the drill
costs no workflow line, needs no redis-server and no image pull, and runs on
every PR instead of behind a path gate.

What this does NOT exercise, so nothing here is a claim about it: the Redis Lua
claim across proxy replicas (prod sets redis_url, this file does not, so the
claim runs on the in-memory cache the same first-writer-wins way), and the
image's own config load. It asserts the routing decision, which is the code the
drill is about.
"""
from __future__ import annotations

import asyncio
import http.server
import json
import random
import socketserver
import threading
from typing import List

from router_litellm_pin import require_pinned_litellm

require_pinned_litellm(__file__)

import litellm  # noqa: E402
import pytest  # noqa: E402
import yaml  # noqa: E402
from litellm import Router  # noqa: E402
from litellm.router_utils.pre_call_checks.deployment_affinity_check import (  # noqa: E402
    DeploymentAffinityCheck,
)

CONFIG_PATH = "config/litellm-proxy.yaml"
CALLS = 100
MAX_HOP_SHARE = 0.02


class _Handler(http.server.BaseHTTPRequestHandler):
    """Answers a walled lane with a real 429 body, everything else 200."""

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
        # method' - no hit is recorded, so a real hop is silently dropped from
        # the count this drill is built on.
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        server = _CURRENT_SERVER[0]
        server.hits.append(self.path)
        if any(self.path.startswith(lane) for lane in server.walled):
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
    """Tiny HTTP mock that records the path of every upstream POST."""

    def __init__(self):
        srv = socketserver.ThreadingTCPServer(("127.0.0.1", 0), _Handler)
        srv.daemon_threads = True
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.port = srv.server_address[1]
        self.hits: List[str] = []
        self.walled: set = set()
        self._srv = srv

    def close(self):
        self._srv.shutdown()
        self._srv.server_close()


_CURRENT_SERVER: List[_Server] = []


def _rows(port):
    """Four rows of the group, one lane each, so the answering row is the path."""
    return [{"model_name": "worker-capable",
             "litellm_params": {"model": f"openai/seat-{name}",
                                "api_base": f"http://127.0.0.1:{port}/row-{name}",
                                "api_key": "k"},
             "model_info": {"id": f"seat-{name}", "supports_prompt_caching": True}}
            for name in ("a", "b", "c", "d")]


def _router_settings():
    with open(CONFIG_PATH, "rb") as fh:
        settings = yaml.safe_load(fh)["router_settings"]
    return settings


def _pin_key(session_id: str) -> str:
    """The exact pin key litellm's DeploymentAffinityCheck reads and writes, taken
    from litellm itself so a key-shape change cannot silently pass this drill."""
    return DeploymentAffinityCheck.get_session_affinity_cache_key(
        model_group="worker-capable", session_id=session_id, user_key=None)


async def _drill(server, calls=CALLS, reclaim=False):
    """Pin a row, wall it, then count the hops over `calls` more calls. reclaim
    drops the stale pin before the count, the way the #9411 fix re-claims it."""
    settings = _router_settings()
    saved_callbacks = litellm.callbacks
    # simple-shuffle draws from `random`; seed it so no draw can differ between runs.
    random.seed(9412)
    _CURRENT_SERVER.append(server)
    litellm.callbacks = []
    try:
        router = Router(
            model_list=_rows(server.port),
            routing_strategy=settings["routing_strategy"],
            num_retries=settings["num_retries"],
            cooldown_time=settings["cooldown_time"],
            allowed_fails=settings["allowed_fails"],
            optional_pre_call_checks=settings["optional_pre_call_checks"],
            deployment_affinity_ttl_seconds=settings["deployment_affinity_ttl_seconds"],
            retry_policy=settings["retry_policy"],
        )
        session_id = "hop-drill-9412"

        async def call():
            try:
                await router.acompletion(model="worker-capable",
                                         messages=[{"role": "user", "content": "hi"}],
                                         metadata={"session_id": session_id})
            except Exception:  # noqa: BLE001 - the answer is the row, not the outcome
                pass
            answered = server.hits[-1].split("/row-", 1)[-1].split("/", 1)[0] if server.hits else None
            server.hits.clear()
            return answered

        pinned = await call()
        server.walled = {f"/row-{pinned}"}
        await call()
        await call()
        if reclaim:
            await router.cache.async_delete_cache(key=_pin_key(session_id))

        answers = [await call() for _ in range(calls)]
        return pinned, answers
    finally:
        _CURRENT_SERVER.pop()
        litellm.callbacks = saved_callbacks


def _hop_share(answers: List[str]) -> float:
    hops = sum(1 for before, after in zip(answers, answers[1:]) if before != after)
    return hops / max(len(answers) - 1, 1)


def test_a_pinned_session_that_cools_does_not_re_shuffle_the_group():
    server = _Server()
    try:
        pinned, answers = asyncio.run(_drill(server))
    finally:
        server.close()
    assert pinned in {"a", "b", "c", "d"}, f"the first call answered {pinned!r}, not one of the four rows"
    share = _hop_share(answers)
    assert share <= MAX_HOP_SHARE, (
        f"{share:.0%} of {len(answers) - 1} hops between calls ({len(set(answers))} distinct rows "
        f"answered) on the pinned litellm {__import__('router_litellm_pin').pinned_litellm()}: "
        "a session pinned to a cooled row re-shuffles the group"
    )


drill_is_red = pytest.mark.xfail(
    strict=True,
    reason="litellm 1.105.0 re-shuffles a session pinned to a cooled row: 62 of 99 hops "
           "(fleet-ops#9412 item 3). Drop this marker in the PR that bumps the image (#9411).",
)
test_a_pinned_session_that_cools_does_not_re_shuffle_the_group = drill_is_red(
    test_a_pinned_session_that_cools_does_not_re_shuffle_the_group)


def test_a_re_claimed_pin_holds_the_same_calls_at_zero_hops():
    server = _Server()
    try:
        pinned, answers = asyncio.run(_drill(server, reclaim=True))
    finally:
        server.close()
    assert pinned in {"a", "b", "c", "d"}, f"the first call answered {pinned!r}, not one of the four rows"
    share = _hop_share(answers)
    assert share <= MAX_HOP_SHARE, (
        f"{share:.0%} of {len(answers) - 1} hops with the pin re-claimed to a healthy row "
        f"({len(set(answers))} distinct rows answered): the drill's gate is not reachable by "
        "re-claiming the pin, so the number above is not the pin's"
    )
