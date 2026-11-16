"""A streamed worker call gets a per-attempt deadline in minutes (fleet-ops#12065).

Pi streams every worker call, so the router's per-attempt deadline for a worker
call is router_settings.stream_timeout, not router_settings.timeout. On the pinned
1.105.0, Router._get_timeout asks _get_stream_timeout first when the call is a
stream and falls through to _get_non_stream_timeout (self.timeout) only when
stream_timeout is unset (litellm/router.py). The resolved seconds reach the
provider SDK's HTTP client as its read timeout, so the deadline is per read, not
per call.

Measured on the pinned wheel against a local SSE stub that sends headers and then
nothing: with stream_timeout=1, timeout=30 the call fails in about 1.2 s with
APIConnectionError "Timeout on reading data from socket"; with only timeout=1 it
fails at about 1.0 s (the fallthrough the closed PR read as a no-op). A stub that
keeps sending a chunk every 0.5 s runs to its own end, so the deadline is idle,
not total: it bounds a leg that goes silent, and a leg that keeps dribbling is not
a stall any read deadline can see (the job's timeout-minutes stays the outer
bound for that shape). The router does not retry a mid-stream read timeout:
retry_policy.TimeoutErrorRetries: 1 did not re-POST the stub, so one attempt is
bounded by the value itself.

The live value is 180 s, under pi's own stock 300 s client idle
(dist/core/http-dispatcher.js DEFAULT_HTTP_IDLE_TIMEOUT_MS; measured with
pi --print against the same stub: "terminated" after 3.0 s at
httpIdleTimeoutMs 3000), so a silent leg fails on the router's row with the
proxy's own error instead of as a client abort two minutes later. Pi's retry
ladder (live retry.maxRetries: 6) is a per-run budget this setting does not move.

Run with the pinned wheel:
  uvx --with "litellm==$(python tests/router_litellm_pin.py)" --with pytest==8.3.5
      --with pyyaml --with httpx python -m pytest -q -p no:cacheprovider
      tests/test_router_worker_stream_timeout.py
"""

from __future__ import annotations

import asyncio
import http.server
import json
import socketserver
import threading
import time
from pathlib import Path

from router_litellm_pin import require_pinned_litellm

require_pinned_litellm(__file__)

import litellm
import yaml
from litellm import Router

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "config/litellm-proxy.yaml"
WORKFLOW = ROOT / ".github/workflows/agent.yml"
# pi's stock HTTP idle timeout, dist/core/http-dispatcher.js DEFAULT_HTTP_IDLE_TIMEOUT_MS.
PI_CLIENT_IDLE_MS = 300_000

CHUNK = {
    "id": "chatcmpl-stub",
    "object": "chat.completion.chunk",
    "created": 1,
    "model": "stub",
    "choices": [{"index": 0, "delta": {"content": "."}, "finish_reason": None}],
}


class _SseStub(http.server.BaseHTTPRequestHandler):
    """Sends SSE headers at once, then a chunk every 0.5 s (trickle) or nothing."""

    protocol_version = "HTTP/1.1"
    mode = "silent"
    seconds = 3.0

    def do_POST(self):
        length = int(self.headers.get("content-length") or 0)
        if length:
            self.rfile.read(length)
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        started = time.monotonic()
        try:
            while time.monotonic() - started < self.seconds:
                if self.mode == "trickle":
                    self.wfile.write(f"data: {json.dumps(CHUNK)}\n\n".encode())
                    self.wfile.flush()
                time.sleep(0.5)
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True

    def log_message(self, *args):
        pass


class _SseServer:
    def __init__(self, mode):
        handler = type("_Handler", (_SseStub,), {"mode": mode})
        self.server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), handler)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.port = self.server.server_address[1]

    def close(self):
        self.server.shutdown()
        self.server.server_close()


async def _consume(port, router_kwargs):
    router = Router(
        model_list=[
            {
                "model_name": "worker-capable",
                "litellm_params": {
                    "model": "openai/stub",
                    "api_base": f"http://127.0.0.1:{port}/v1",
                    "api_key": "stub",
                },
            }
        ],
        num_retries=0,
        **router_kwargs,
    )
    stream = await router.acompletion(
        model="worker-capable",
        messages=[{"role": "user", "content": "hi"}],
        stream=True,
    )
    async for _ in stream:
        pass


def _run(port, **router_kwargs):
    """Seconds the call took, and the exception it raised (None if it completed)."""

    async def bounded():
        await asyncio.wait_for(_consume(port, router_kwargs), timeout=12)

    started = time.monotonic()
    error = None
    try:
        asyncio.run(bounded())
    except (litellm.APIConnectionError, litellm.Timeout, TimeoutError) as exc:
        error = exc
    return time.monotonic() - started, error


def test_the_live_stream_deadline_is_pinned_in_minutes():
    settings = yaml.safe_load(CONFIG.read_text(encoding="utf-8"))["router_settings"]
    assert settings["stream_timeout"] == 180
    # Under pi's client idle, so the router's own error reaches the run first.
    assert settings["stream_timeout"] * 1000 < PI_CLIENT_IDLE_MS
    # A job still has its own wall; the per-attempt bound must leave room for it.
    assert settings["stream_timeout"] * 1000 < 90 * 60 * 1000
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    assert workflow["jobs"]["work"]["timeout-minutes"] == 90


def test_a_silent_streamed_leg_fails_at_stream_timeout():
    stub = _SseServer("silent")
    try:
        elapsed, error = _run(stub.port, timeout=30, stream_timeout=1)
    finally:
        stub.close()
    assert isinstance(error, litellm.APIConnectionError), error
    assert elapsed < 5, elapsed


def test_a_silent_streamed_leg_falls_through_to_timeout_without_stream_timeout():
    stub = _SseServer("silent")
    try:
        elapsed, error = _run(stub.port, timeout=1)
    finally:
        stub.close()
    assert isinstance(error, litellm.APIConnectionError), error
    assert elapsed < 5, elapsed


def test_a_trickling_leg_outlives_the_idle_deadline():
    """The honest limit: read deadlines see silence, not total time."""
    stub = _SseServer("trickle")
    try:
        elapsed, error = _run(stub.port, timeout=30, stream_timeout=1)
    finally:
        stub.close()
    assert error is None, error
    assert elapsed >= 2.0, elapsed
