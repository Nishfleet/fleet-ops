"""worker-capable answers while most of its rows are out of credit (fleet-ops#11723).

Runs the live config/litellm-proxy.yaml rows and router_settings on a real litellm
Router, with a plain http.server standing in for the providers. The z.ai and
Command Code rows answer 429 (their plan limits, 2026-11-04), the rest answer 200.

  uvx --with litellm==1.105.0 --with pytest==8.3.5 --with jsonschema --with httpx \
      python -m pytest -q tests/test_router_dead_rows_walk.py
"""
from __future__ import annotations

import asyncio
import http.server
import json
import random
import socketserver
import threading
from pathlib import Path

import pytest
from router_litellm_pin import require_pinned_litellm

require_pinned_litellm(__file__)

pytest.importorskip("litellm")

import litellm
import yaml
from litellm import Router
from litellm.router_utils.pre_call_checks.deployment_affinity_check import (
    DeploymentAffinityCheck,
)

CONFIG = Path(__file__).resolve().parents[1] / "config/litellm-proxy.yaml"
OUT_OF_CREDIT = ("https://api.z.ai/", "https://api.commandcode.ai/")
REDIS_KEYS = {"redis_host", "redis_port", "redis_password"}
CALLS_PER_WINDOW = 30
HITS: list[str] = []


class _Provider(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        row = self.path.split("/")[2]
        HITS.append(row)
        if self.path.startswith("/dead/"):
            status, body = 429, {"error": {"message": "Weekly usage limit reached",
                                           "type": "rate_limit_error", "code": "rate_limit_exceeded"}}
        else:
            status, body = 200, {
                "id": "x", "object": "chat.completion", "created": 0,
                "choices": [{"index": 0, "message": {"role": "assistant", "content": "ok"},
                             "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


def _live():
    return yaml.safe_load(CONFIG.read_text(encoding="utf-8"))


def _worker_rows(config, port):
    rows = []
    for row in config["model_list"]:
        if row["model_name"] not in ("worker-capable", "worker-cheap"):
            continue
        row_id = row["model_info"]["id"]
        lane = "dead" if row["litellm_params"]["api_base"].startswith(OUT_OF_CREDIT) else "ok"
        rows.append({
            "model_name": row["model_name"],
            "litellm_params": {"model": f"openai/{row_id}", "api_key": "k",
                               "api_base": f"http://127.0.0.1:{port}/{lane}/{row_id}"},
            "model_info": {"id": row_id, "supports_prompt_caching": True},
        })
    return rows


def _router(config, port):
    settings = {k: v for k, v in config["router_settings"].items() if k not in REDIS_KEYS}
    settings["fallbacks"] = [f for f in settings["fallbacks"] if "worker-cheap" in f]
    return Router(model_list=_worker_rows(config, port), **settings)


def _worker_capable_names(config):
    aliases = config["router_settings"].get("model_group_alias", {})
    return ["worker-capable", *sorted(a for a, g in aliases.items() if g == "worker-capable")]


async def _window(router, names, pinned_row):
    for name in names:
        key = DeploymentAffinityCheck.get_session_affinity_cache_key(
            model_group=name, session_id=f"s-{name}", user_key=None)
        await router.cache.async_set_cache(key=key, value={"model_id": pinned_row}, ttl=600)
    failures = []
    for i in range(CALLS_PER_WINDOW):
        name = names[i % len(names)]
        try:
            await router.acompletion(model=name, messages=[{"role": "user", "content": "hi"}],
                                     metadata={"session_id": f"s-{name}"})
        except Exception as e:  # noqa: BLE001
            failures.append((name, type(e).__name__))
    return failures


async def _windows(router, names, dead_rows):
    results = []
    for window in range(2):
        router.cache.flush_cache()
        HITS.clear()
        failures = await _window(router, names, dead_rows[window])
        results.append((failures, list(HITS)))
    return results


def test_every_worker_capable_name_retries_a_429_once_per_other_row():
    config = _live()
    rows = sum(1 for r in config["model_list"] if r["model_name"] == "worker-capable")
    policies = config["router_settings"].get("model_group_retry_policy", {})
    assert config["router_settings"].get("allowed_fails_policy", {}).get("RateLimitErrorAllowedFails") == 0
    for name in _worker_capable_names(config):
        assert policies.get(name, {}).get("RateLimitErrorRetries", 0) >= rows - 1, name


def test_worker_capable_walks_past_out_of_credit_rows_across_cooldown_expiry():
    config = _live()
    srv = socketserver.ThreadingTCPServer(("127.0.0.1", 0), _Provider)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    saved_callbacks = litellm.callbacks
    litellm.callbacks = []
    random.seed(11723)
    try:
        router = _router(config, srv.server_address[1])
        names = _worker_capable_names(config)
        dead_rows = [d["model_info"]["id"] for d in router.model_list
                     if "/dead/" in d["litellm_params"]["api_base"] and d["model_name"] == "worker-capable"]
        cheap_rows = {d["model_info"]["id"] for d in router.model_list if d["model_name"] == "worker-cheap"}
        windows = asyncio.run(_windows(router, names, dead_rows))
        for window, (failures, hits) in enumerate(windows):
            assert failures == [], (window, failures, hits)
            assert not cheap_rows & set(hits), hits
            repeats = {r: hits.count(r) for r in dead_rows if hits.count(r) > 1}
            assert repeats == {}, repeats
    finally:
        litellm.callbacks = saved_callbacks
        srv.shutdown()
        srv.server_close()
