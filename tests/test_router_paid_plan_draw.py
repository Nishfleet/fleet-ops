"""The plain-row draw, and the prompt-cache funnel that broke it (fleet-ops#12143).

PaidPlanIdle paged z.ai with 0 of hundreds of worker-capable calls on plainly
busy days (2026-11-23: 529 calls, all on the MiniMax rows) while plain shuffle
gives the two z.ai rows 2 of 7 picks. The cause is the prompt_caching optional
pre-call check (fleet-ops#8567): PromptCachingDeploymentCheck pins the row that
last served a repeated prompt prefix (PROMPT_CACHE_PIN_TTL_SECONDS 300,
refreshed by every successful call; litellm/router_utils/prompt_caching_cache.py,
v1.105.0). Every worker call re-sends the same big system block marked
cache_control by the client, so the first row to answer a cacheable call holds
the whole group until a 300-second lull expires the pin. The one-sentence probe
draws that cleared the alert sit under the 1024-token gate
(get_prompt_cache_min_tokens), which is why they drew both z.ai rows on a day
busy traffic drew none.

The fix drops prompt_caching from optional_pre_call_checks (fleet-ops#12143;
session_affinity stays, fleet-ops#9015). These drills run the live
config/litellm-proxy.yaml on the pinned litellm with a plain http.server for
the providers, as tests/test_router_dead_rows_walk.py does:

  uvx --with "litellm==$(python tests/router_litellm_pin.py)" --with pytest==8.3.5 \
      --with jsonschema --with httpx python -m pytest -q tests/test_router_paid_plan_draw.py
"""
from __future__ import annotations

import asyncio
import collections
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

CONFIG = Path(__file__).resolve().parents[1] / "config/litellm-proxy.yaml"
REDIS_KEYS = {"redis_host", "redis_port", "redis_password"}
LIVE_CHECKS = ["session_affinity"]
SHIPPED_BEFORE_CHECKS = ["prompt_caching", "session_affinity"]
ZAI_ROWS = {"zai-glm53flashi-worker-capable", "zai-glm53flash-worker-capable"}
# The shape Pi sends: one big system block, marked cache_control by the client,
# re-sent on every call of every session (2000 words clears the 1024-token gate).
SYSTEM = " ".join(f"tok{i}" for i in range(2000))
PREFIX = [
    {"role": "system", "content": [{"type": "text", "text": SYSTEM,
                                    "cache_control": {"type": "ephemeral"}}]},
    {"role": "user", "content": "hi"},
]
HITS: list[str] = []


class _Provider(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        HITS.append(self.path.lstrip("/").split("/")[0])
        if "/v1/messages" in self.path:  # the anthropic-provider rows
            body = {"id": "msg_x", "type": "message", "role": "assistant",
                    "model": "MiniMax-M3.1-Flash-Preview",
                    "content": [{"type": "text", "text": "ok"}], "stop_reason": "end_turn",
                    "usage": {"input_tokens": 2000, "output_tokens": 2}}
        else:
            body = {"id": "x", "object": "chat.completion", "created": 0, "model": "m",
                    "choices": [{"index": 0, "message": {"role": "assistant", "content": "ok"},
                                 "finish_reason": "stop"}],
                    "usage": {"prompt_tokens": 2000, "completion_tokens": 2, "total_tokens": 2002}}
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


def _live():
    return yaml.safe_load(CONFIG.read_text(encoding="utf-8"))


def _settings(config):
    return {k: v for k, v in config["router_settings"].items() if k not in REDIS_KEYS}


def _rows(config, port):
    out = []
    for row in config["model_list"]:
        if row["model_name"] != "worker-capable":
            continue
        row_id = row["model_info"]["id"]
        out.append({
            "model_name": "worker-capable",
            "litellm_params": {"model": row["litellm_params"]["model"], "api_key": "k",
                               "api_base": f"http://127.0.0.1:{port}/{row_id}"},
            "model_info": {"id": row_id, "supports_prompt_caching": True},
        })
    return out


async def _drill(rows, settings, checks, calls, session):
    saved_callbacks = litellm.callbacks
    litellm.callbacks = []
    random.seed(12143)
    try:
        router = Router(model_list=rows, **{**settings, "optional_pre_call_checks": checks})
        HITS.clear()
        for i in range(calls):
            await router.acompletion(model="worker-capable",
                                     messages=json.loads(json.dumps(PREFIX)),
                                     metadata={"session_id": session.format(i=i)})
        return list(HITS)
    finally:
        litellm.callbacks = saved_callbacks


def _run(calls, session="fresh-{i}", checks=None):
    config = _live()
    srv = socketserver.ThreadingTCPServer(("127.0.0.1", 0), _Provider)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        return asyncio.run(_drill(_rows(config, srv.server_address[1]), _settings(config),
                                  checks or LIVE_CHECKS, calls, session))
    finally:
        srv.shutdown()
        srv.server_close()


def test_the_live_config_keeps_session_affinity_and_drops_the_funnel():
    settings = _settings(_live())["optional_pre_call_checks"]
    assert settings == LIVE_CHECKS


def test_the_prompt_cache_check_held_a_shared_prefix_on_one_row():
    hits = _run(60, checks=SHIPPED_BEFORE_CHECKS)
    share = collections.Counter(hits)
    assert not ZAI_ROWS & set(hits), share  # the 529-call shape: z.ai draws nothing
    _, taken = share.most_common(1)[0]
    assert taken / len(hits) >= 0.9, share  # one row holds the group on the prefix pin


def test_a_shared_worker_prefix_draws_every_row_including_both_z_ai_rows():
    hits = _run(140)
    drawn = collections.Counter(hits)
    assert len(drawn) == 7 and min(drawn.values()) >= 2, drawn
    zai = sum(n for row, n in drawn.items() if row in ZAI_ROWS) / len(hits)
    assert 0.15 <= zai <= 0.45, drawn  # 2 of 7 rows, plus/minus four sigma
    assert max(drawn.values()) / len(hits) < 0.45, drawn  # no row holds the group


def test_session_affinity_still_pins_a_session_to_one_row():
    hits = _run(6, session="same-session")
    assert len(set(hits)) == 1, hits
