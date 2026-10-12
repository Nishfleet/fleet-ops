"""fleet-ops#9596: the senior group falls back to senior-backup on a 429.

Runs the live config/litellm-proxy.yaml fallbacks on a real litellm Router with a
plain http.server standing in for both providers: the senior row answers 429
"Insufficient credits", the senior-backup row answers 200. Run with the pinned litellm venv's python:

  python -m pytest tests/test_router_senior_fallback.py
"""
from __future__ import annotations

import asyncio
import http.server
import json
import socketserver
import threading

import pytest

pytest.importorskip("litellm")

import litellm  # noqa: E402
import yaml  # noqa: E402
from litellm import Router  # noqa: E402

CONFIG_PATH = "config/litellm-proxy.yaml"
HITS: list = []
# Groups whose stand-in provider answers 429 "Insufficient credits".
WALLED = {"senior", "judge"}


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


def test_live_config_senior_has_one_fallback_and_no_cycle():
    cfg = _config()
    fallbacks = {k: v for entry in cfg["router_settings"]["fallbacks"] for k, v in entry.items()}
    assert fallbacks["senior"] == ["senior-backup"]
    assert "senior-backup" not in fallbacks
    groups = {row["model_name"] for row in cfg["model_list"]}
    assert "senior-backup" in groups
    # The fallback only helps if it is another provider and key: a copy of the primary's wall is no fallback.
    params = {row["model_name"]: row["litellm_params"] for row in cfg["model_list"] if row["model_name"] in ("senior", "senior-backup")}
    assert params["senior"]["api_base"] != params["senior-backup"]["api_base"]
    assert params["senior"]["api_key"] != params["senior-backup"]["api_key"]
    # judge -> senior -> senior-backup ends there: no group named in a chain returns to judge/senior.
    assert not set(fallbacks["senior"]) & {"judge", "senior"}


def test_synthetic_key_stays_under_its_measured_concurrency():
    # 12 parallel calls on the Synthetic key gave 8x200 and 4x429, so senior-backup takes one of 7 slots, not an 8th.
    rows = [row for row in _config()["model_list"]
            if row["litellm_params"].get("api_base") == "https://api.synthetic.new/openai/v1"]
    assert "synthetic-glm53flash-senior-backup" in {row["model_info"]["id"] for row in rows}
    assert sum(row["litellm_params"]["max_parallel_requests"] for row in rows) <= 7


def _route(model: str) -> list:
    """Send one call for `model` through a real Router on the live fallbacks; return the groups hit, in order."""
    HITS.clear()
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
                for group in ("judge", "senior", "senior-backup")],
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


def test_a_429_on_senior_is_answered_by_senior_backup():
    # retry_policy RateLimitErrorRetries 1: the walled primary is tried twice, then the backup answers once.
    assert _route("senior") == ["senior", "senior", "senior-backup"]


def test_a_judge_call_reaches_senior_backup_through_senior():
    # judge names only senior; the second hop is LiteLLM re-entering fallbacks for the senior group
    # (v1.98.0 fallback_event_handlers.run_async_fallback, fallback_depth + 1).
    assert _route("judge") == ["judge", "judge", "senior", "senior", "senior-backup"]
