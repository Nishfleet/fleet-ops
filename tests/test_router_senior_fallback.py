"""fleet-ops#10040: senior is one to three GLM-5.3-Flash rows with no fallback; judge falls to it.

Runs the live config/litellm-proxy.yaml fallbacks on a real litellm Router with a
plain http.server standing in for the providers: a walled group answers 429
"Insufficient credits", the others answer 200. Run with the pinned litellm venv's python:

  python -m pytest tests/test_router_senior_fallback.py
"""
from __future__ import annotations

import asyncio
import gc
import http.server
import json
import socketserver
import threading

import pytest

pytest.importorskip("litellm")

import litellm  # noqa: E402
from litellm.types.router import RouterRateLimitError  # noqa: E402
import yaml  # noqa: E402
from litellm import Router  # noqa: E402

CONFIG_PATH = "config/litellm-proxy.yaml"
HITS: list = []
WALLED: set = set()


class _Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        HITS.append(self.path)
        if self.path.split("/")[1] in WALLED:
            body = json.dumps({"error": {
                "message": "Insufficient credits", "type": "rate_limit_error",
                "code": "rate_limit_exceeded"}}).encode()
            status = 429
        else:
            body = json.dumps({
                "id": "x", "object": "chat.completion", "created": 0,
                "choices": [{"index": 0, "message": {"role": "assistant", "content": "ok"},
                             "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}).encode()
            status = 200
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def _config():
    with open(CONFIG_PATH, "rb") as fh:
        return yaml.safe_load(fh)


def test_live_config_senior_is_glm_only_with_no_fallback():
    cfg = _config()
    fallbacks = {k: v for entry in cfg["router_settings"]["fallbacks"] for k, v in entry.items()}
    assert "senior" not in fallbacks
    assert fallbacks["judge"] == ["senior"]
    groups = [row["model_name"] for row in cfg["model_list"]]
    assert 1 <= groups.count("senior") <= 2
    assert all(row["litellm_params"]["model"].lower().endswith("glm-5.3-flash") for row in cfg["model_list"] if row["model_name"] == "senior")
    assert "senior-backup" not in groups
    assert not any("pareto" in row["litellm_params"].get("api_base", "") for row in cfg["model_list"])


def test_synthetic_and_zai_rows_carry_no_slot_cap():
    # fleet-ops#10694: v1.105.0 never releases a stream's slot when the client is gone before the first chunk;
    # these two providers answer their own 429, so no row of theirs holds a slot count
    bases = ("https://api.synthetic.new/openai/v1", "https://api.z.ai/api/coding/paas/v4")
    rows = [row for row in _config()["model_list"] if row["litellm_params"].get("api_base") in bases]
    assert rows and all("max_parallel_requests" not in row["litellm_params"] for row in rows)


def _route(model: str, walled: set) -> list:
    """Send one call for `model` through a real Router on the live fallbacks; return the groups hit, in order."""
    HITS.clear()
    WALLED.clear()
    WALLED.update(walled)
    srv = socketserver.ThreadingTCPServer(("127.0.0.1", 0), _Handler)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    port = srv.server_address[1]
    settings = _config()["router_settings"]
    saved = litellm.callbacks
    litellm.callbacks = []
    try:
        router = Router(
            model_list=[
                {"model_name": group,
                 "litellm_params": {"model": "openai/glm", "api_base": f"http://127.0.0.1:{port}/{group}", "api_key": "k"},
                 "model_info": {"id": f"{group}-row"}}
                for group in ("judge", "senior")],
            num_retries=settings["num_retries"],
            cooldown_time=settings["cooldown_time"],
            allowed_fails=settings["allowed_fails"],
            fallbacks=settings["fallbacks"],
            retry_policy=settings["retry_policy"],
        )
        resp = asyncio.run(router.acompletion(model=model, messages=[{"role": "user", "content": "hi"}]))
        assert resp.choices[0].message.content == "ok"
        return [h.split("/")[1] for h in HITS]
    finally:
        litellm.callbacks = saved
        srv.shutdown()
        srv.server_close()


def test_a_walled_judge_call_is_answered_by_senior():
    assert _route("judge", {"judge"}) == ["judge", "judge", "senior"]


def test_a_429_on_senior_reaches_the_caller_with_no_other_group_hit():
    # fleet-ops#10178: the second RateLimit retry finds the one senior row parked,
    # so the caller sees the router's cooldown 429 (RouterRateLimitError) instead of
    # the upstream one. Still a 429, and still no other group is hit.
    with pytest.raises((litellm.RateLimitError, RouterRateLimitError)):
        _route("senior", {"senior"})
    assert set(h.split("/")[1] for h in HITS) == {"senior"}


class _StreamHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        chunk = {"id": "x", "object": "chat.completion.chunk", "created": 0, "model": "m",
                 "choices": [{"index": 0, "delta": {"content": "a"}, "finish_reason": None}]}
        try:
            for _ in range(3):
                self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
                self.wfile.flush()
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except OSError:
            pass

    def log_message(self, *args):
        pass


@pytest.mark.parametrize("cap, read_first_chunk", [(None, False), (None, True), (1, True)])
def test_a_row_answers_after_a_client_drops_its_stream(cap, read_first_chunk):
    # fleet-ops#10694: with the live senior litellm_params (no slot cap) a stream abandoned before or after
    # its first chunk leaves the row free; a max_parallel_requests=1 row does too once the client read a chunk
    # and closed. (cap 1, dropped unread) is the v1.105.0 leak and is not a test: it fails on that version.
    srv = socketserver.ThreadingTCPServer(("127.0.0.1", 0), _StreamHandler)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    live = next(r for r in _config()["model_list"] if r["model_name"] == "senior")["litellm_params"]
    params = {k: v for k, v in live.items() if k not in ("api_base", "api_key", "model", "tags")}
    if cap:
        params["max_parallel_requests"] = cap
    params.update({"model": "openai/glm", "api_base": f"http://127.0.0.1:{srv.server_address[1]}", "api_key": "k"})
    saved = litellm.callbacks
    litellm.callbacks = []

    async def scenario():
        router = Router(model_list=[{"model_name": "senior", "litellm_params": params, "model_info": {"id": "senior-row"}}],
                        num_retries=0)
        messages = [{"role": "user", "content": "hi"}]
        dropped = await router.acompletion(model="senior", messages=messages, stream=True)
        if read_first_chunk:
            async for _ in dropped:
                break
            await dropped.aclose()
        del dropped
        gc.collect()
        second = await router.acompletion(model="senior", messages=messages, stream=True)
        return [c async for c in second]

    try:
        assert asyncio.run(scenario())
    finally:
        litellm.callbacks = saved
        srv.shutdown()
        srv.server_close()
