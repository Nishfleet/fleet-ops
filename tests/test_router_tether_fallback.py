"""Tether's Claude row falls to `assistant` on every kind of Claude failure.

Runs the live config/litellm-proxy.yaml settings on a real litellm Router with a plain
http.server standing in for the providers: the tether group answers the chosen failure,
the assistant group answers 200. Run with the pinned litellm venv's python:

  python -m pytest tests/test_router_tether_fallback.py
"""
from __future__ import annotations

import asyncio
import http.server
import json
import socketserver
import threading
import time

import pytest

pytest.importorskip("litellm")

import litellm  # noqa: E402
import yaml  # noqa: E402
from litellm import Router  # noqa: E402

CONFIG_PATH = "config/litellm-proxy.yaml"
HITS: list = []
FAIL: dict = {}


class _Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        group = self.path.split("/")[1]
        HITS.append(group)
        failure = FAIL.get(group)
        if failure and failure[0] == "hang":
            time.sleep(failure[1])
        if failure and failure[0] != "hang":
            status, err = failure
            body = json.dumps({"error": err}).encode()
        else:
            status = 200
            body = json.dumps({
                "id": "x", "object": "chat.completion", "created": 0, "model": group,
                "choices": [{"index": 0, "message": {"role": "assistant", "content": "ok"},
                             "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}).encode()
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


def test_live_config_tether_is_one_claude_row_falling_to_assistant_only():
    cfg = _config()
    rows = [r for r in cfg["model_list"] if r["model_name"] == "tether"]
    assert len(rows) == 1
    assert rows[0]["litellm_params"]["model"] == "anthropic/claude-sonnet-5-5"
    assert rows[0]["litellm_params"]["api_key"] == "os.environ/ANTHROPIC_API_KEY"
    # the Claude key serves no other group, and `assistant` (shared with the Hermes chat agent) has no Claude row
    assert [r["model_name"] for r in cfg["model_list"]
            if r["litellm_params"].get("api_key") == "os.environ/ANTHROPIC_API_KEY"] == ["tether"]
    fallbacks = {k: v for entry in cfg["router_settings"]["fallbacks"] for k, v in entry.items()}
    assert fallbacks["tether"] == ["assistant"]
    assert not any("tether" in v for v in fallbacks.values())
    # no group-specific lists: they would stop the general fallbacks being the default for every other group
    assert "content_policy_fallbacks" not in cfg["router_settings"]
    assert "context_window_fallbacks" not in cfg["router_settings"]


def _router(port: int, budget: bool = False) -> Router:
    cfg = _config()
    settings = cfg["router_settings"]
    tether = next(r for r in cfg["model_list"] if r["model_name"] == "tether")
    tether_params = {"model": "openai/claude", "api_base": f"http://127.0.0.1:{port}/tether", "api_key": "k",
                     "cooldown_time": tether["litellm_params"]["cooldown_time"]}
    if budget:
        tether_params["max_budget"] = tether["litellm_params"]["max_budget"]
        tether_params["budget_duration"] = tether["litellm_params"]["budget_duration"]
    return Router(
        model_list=[
            {"model_name": "tether",
             "litellm_params": tether_params,
             "model_info": {"id": tether["model_info"]["id"],
                            "allowed_fails_policy": tether["model_info"]["allowed_fails_policy"]}},
            {"model_name": "assistant",
             "litellm_params": {"model": "openai/ds", "api_base": f"http://127.0.0.1:{port}/assistant", "api_key": "k"},
             "model_info": {"id": "assistant-row"}},
        ],
        num_retries=settings["num_retries"],
        cooldown_time=settings["cooldown_time"],
        allowed_fails=settings["allowed_fails"],
        allowed_fails_policy=settings["allowed_fails_policy"],
        fallbacks=settings["fallbacks"],
        retry_policy=settings["retry_policy"],
        timeout=1,
    )


CASES = {
    "rate_limit": (429, {"message": "rate limited", "type": "rate_limit_error"}),
    "credit_exhausted": (400, {"message": "Your credit balance is too low to access the Anthropic API.", "type": "invalid_request_error"}),
    "auth": (401, {"message": "invalid x-api-key", "type": "authentication_error"}),
    "outage": (500, {"message": "Internal server error", "type": "api_error"}),
    "overloaded": (529, {"message": "Overloaded", "type": "overloaded_error"}),
    "context_window": (400, {"message": "This model's maximum context length is 1 tokens", "type": "invalid_request_error", "code": "context_length_exceeded"}),
    "content_policy": (400, {"message": "content filtered", "type": "invalid_request_error", "code": "content_policy_violation"}),
    "timeout": ("hang", 3),
}


@pytest.mark.parametrize("case", sorted(CASES))
def test_a_claude_failure_is_answered_by_assistant(case):
    HITS.clear()
    FAIL.clear()
    FAIL["tether"] = CASES[case]
    srv = socketserver.ThreadingTCPServer(("127.0.0.1", 0), _Handler)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    saved = litellm.callbacks
    litellm.callbacks = []
    try:
        router = _router(srv.server_address[1])
        resp = asyncio.run(router.acompletion(model="tether", messages=[{"role": "user", "content": "hi"}]))
        assert resp.choices[0].message.content == "ok"
        assert HITS[0] == "tether" and HITS[-1] == "assistant"
        assert resp._hidden_params["model_id"] == "assistant-row"
        # the next call, whatever state the Claude row is in (parked or not), is still answered
        resp2 = asyncio.run(router.acompletion(model="tether", messages=[{"role": "user", "content": "again"}]))
        assert resp2.choices[0].message.content == "ok"
    finally:
        litellm.callbacks = saved
        srv.shutdown()
        srv.server_close()


def test_claude_healthy_answers_without_touching_assistant():
    HITS.clear()
    FAIL.clear()
    srv = socketserver.ThreadingTCPServer(("127.0.0.1", 0), _Handler)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    saved = litellm.callbacks
    litellm.callbacks = []
    try:
        resp = asyncio.run(_router(srv.server_address[1]).acompletion(model="tether", messages=[{"role": "user", "content": "hi"}]))
        assert HITS == ["tether"]
        assert resp._hidden_params["model_id"] == "anthropic-sonnet55-tether"
    finally:
        litellm.callbacks = saved
        srv.shutdown()
        srv.server_close()


def test_tether_daily_budget_trip_falls_to_assistant_until_the_window_resets():
    HITS.clear()
    FAIL.clear()
    srv = socketserver.ThreadingTCPServer(("127.0.0.1", 0), _Handler)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    port = srv.server_address[1]
    saved = litellm.callbacks
    tether_row = next(r for r in _config()["model_list"] if r["model_name"] == "tether")
    spend_key = f"deployment_spend:{tether_row['model_info']['id']}:{tether_row['litellm_params']['budget_duration']}"
    daily_budget = tether_row["litellm_params"]["max_budget"]

    async def scenario():
        router = _router(port, budget=True)
        limiter = router._get_router_deployment_budget_limiter()
        litellm.callbacks = [limiter]
        await limiter.dual_cache.in_memory_cache.async_set_cache(key=spend_key, value=daily_budget)
        resp = await router.acompletion(model="tether", messages=[{"role": "user", "content": "hi"}])
        assert resp.choices[0].message.content == "ok"
        assert HITS == ["assistant"]
        assert resp._hidden_params["model_id"] == "assistant-row"
        resp2 = await router.acompletion(model="tether", messages=[{"role": "user", "content": "still out of budget"}])
        assert resp2.choices[0].message.content == "ok"
        assert HITS == ["assistant"] * 2
        await limiter.dual_cache.in_memory_cache.async_set_cache(key=spend_key, value=0.0)
        resp3 = await router.acompletion(model="tether", messages=[{"role": "user", "content": "window rolled over"}])
        assert resp3.choices[0].message.content == "ok"
        assert HITS == ["assistant"] * 2 + ["tether"]
        assert resp3._hidden_params["model_id"] == "anthropic-sonnet55-tether"

    try:
        asyncio.run(scenario())
    finally:
        litellm.callbacks = saved
        srv.shutdown()
        srv.server_close()
