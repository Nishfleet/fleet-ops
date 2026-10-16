import asyncio
import copy
import json
import random
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import litellm
import pytest
import yaml
from litellm import Router
from litellm.litellm_core_utils.duration_parser import duration_in_seconds

CONFIG = yaml.safe_load((Path(__file__).resolve().parent.parent / "config" / "litellm-proxy.yaml").read_text())
STRAITLY_BASE = "https://api.straitly.ai/v1"
BALANCE_USD = 20.0
PICKS = 2000


def _straitly_rows():
    return [r for r in CONFIG["model_list"] if r["litellm_params"].get("api_base") == STRAITLY_BASE]


def _fallbacks():
    return CONFIG["router_settings"]["fallbacks"]


def test_straitly_is_two_worker_public_rows_on_the_one_key():
    rows = _straitly_rows()
    assert len(rows) == 2
    assert {r["model_name"] for r in rows} == {"worker-public"}
    assert len({r["model_info"]["id"] for r in rows}) == 2
    for r in rows:
        params = r["litellm_params"]
        assert params["model"] == "openai/deepseek/deepseek-v4-1-flash"
        assert params["api_key"] == "os.environ/STRAITLY_API_KEY"


def test_every_worker_public_row_has_an_integer_weight():
    rows = [r for r in CONFIG["model_list"] if r["model_name"] == "worker-public"]
    assert rows
    for r in rows:
        weight = r["litellm_params"].get("weight")
        assert isinstance(weight, int) and weight >= 1, r["model_info"]["id"]


def test_straitly_rows_carry_the_listed_prices():
    for r in _straitly_rows():
        params = r["litellm_params"]
        assert params["input_cost_per_token"] == 3.82e-08
        assert params["cache_read_input_token_cost"] == 3.8e-09
        assert params["output_cost_per_token"] == 1.529e-07


def test_budgets_are_a_lifetime_cap_below_the_balance_and_the_account_limit():
    rows = _straitly_rows()
    for r in rows:
        params = r["litellm_params"]
        assert params["budget_duration"] == "30d"
        assert duration_in_seconds(params["budget_duration"]) >= 30 * 86400
    assert sum(r["litellm_params"]["max_budget"] for r in rows) <= BALANCE_USD - 1.0
    assert sum(r["litellm_params"]["max_parallel_requests"] for r in rows) * 2 <= 64


def test_worker_public_falls_back_to_worker_capable_and_the_old_pair_is_intact():
    fallbacks = _fallbacks()
    assert {"worker-public": ["worker-capable"]} in fallbacks
    assert [f for f in fallbacks if "worker-public" in f] == [{"worker-public": ["worker-capable"]}]
    assert {"worker-capable": ["worker-cheap"]} in fallbacks
    assert {"worker-cheap": ["worker-capable"]} in fallbacks
    assert not any("worker-public" in names for f in fallbacks for names in f.values())


def test_pi_offers_the_worker_public_seat():
    import json

    pi = json.loads((Path(__file__).resolve().parent.parent / "config" / "pi-models.json").read_text())
    ids = [m["id"] for m in pi["providers"]["litellm"]["models"]]
    assert "worker-public" in ids


def test_both_rows_share_the_pick_evenly():
    rows = [r for r in CONFIG["model_list"] if r["model_name"] == "worker-public"]

    async def run():
        model_list = [
            {
                "model_name": "worker-public",
                "litellm_params": {
                    "model": "openai/x",
                    "api_base": "http://127.0.0.1:1",
                    "api_key": "k",
                    "order": r["litellm_params"]["order"],
                    "weight": r["litellm_params"]["weight"],
                },
                "model_info": {"id": r["model_info"]["id"]},
            }
            for r in rows
        ]
        router = Router(model_list=model_list, routing_strategy="simple-shuffle", num_retries=0)
        first = 0
        for _ in range(PICKS):
            d = await router.async_get_available_deployment(model="worker-public", request_kwargs={})
            first += d["model_info"]["id"] == rows[0]["model_info"]["id"]
        return first / PICKS

    random.seed(20261015)
    assert 0.45 <= asyncio.run(run()) <= 0.55


class _Upstream(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        reply = {
            "id": "c1",
            "object": "chat.completion",
            "created": 1,
            "model": body["model"],
            "choices": [{"index": 0, "message": {"role": "assistant", "content": body["model"]}, "finish_reason": "stop"}],
            "usage": {
                "prompt_tokens": 20000,
                "completion_tokens": 10,
                "total_tokens": 20010,
                "prompt_tokens_details": {"cached_tokens": 10000},
            },
        }
        data = json.dumps(reply).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


@pytest.fixture(scope="module")
def upstream():
    server = HTTPServer(("127.0.0.1", 0), _Upstream)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{server.server_port}/v1"
    server.shutdown()


STRAITLY_MODEL = "deepseek/deepseek-v4-1-flash"
ONE_CALL_USD = 10000 * 3.82e-08 + 10000 * 3.8e-09 + 10 * 1.529e-07


def _budget_router(suffix, upstream, drop=()):
    litellm.logging_callback_manager._reset_all_callbacks()
    rows = []
    for i, r in enumerate(_straitly_rows()):
        params = copy.deepcopy(r["litellm_params"])
        params["api_base"] = upstream
        params["api_key"] = "k"
        params["max_budget"] = ONE_CALL_USD * 1.5
        for key in drop:
            params.pop(key, None)
        rows.append({"model_name": "worker-public", "litellm_params": params, "model_info": {"id": f"{suffix}-straitly-{i}"}})
    rows.append(
        {
            "model_name": "worker-capable",
            "litellm_params": {"model": "openai/capable", "api_base": "http://127.0.0.1:1/v1", "api_key": "k"},
            "model_info": {"id": f"{suffix}-capable"},
        }
    )
    rows.append(
        {
            "model_name": "worker-cheap",
            "litellm_params": {"model": "openai/cheap", "api_base": upstream, "api_key": "k"},
            "model_info": {"id": f"{suffix}-cheap"},
        }
    )
    return Router(model_list=rows, fallbacks=_fallbacks(), num_retries=0)


async def _answers(router, calls):
    seen = []
    for _ in range(calls):
        reply = await router.acompletion(model="worker-public", messages=[{"role": "user", "content": "x"}])
        seen.append(reply.choices[0].message.content)
        await asyncio.sleep(0.4)
    return seen


def test_upstream_model_and_cost_follow_the_production_row(upstream):
    async def run():
        router = _budget_router("cost", upstream)
        reply = await router.acompletion(model="worker-public", messages=[{"role": "user", "content": "x"}])
        return reply.choices[0].message.content, reply._hidden_params["response_cost"]

    model, cost = asyncio.run(run())
    assert model == STRAITLY_MODEL
    assert abs(cost - ONE_CALL_USD) < 1e-9


def test_the_budget_trip_moves_the_job_down_the_fallback_chain(upstream):
    async def run():
        return await _answers(_budget_router("trip", upstream), 10)

    seen = asyncio.run(run())
    assert seen[:4] == [STRAITLY_MODEL] * 4
    assert seen.count(STRAITLY_MODEL) == 4
    assert seen[4:] == ["cheap"] * 6


def test_a_row_without_budget_duration_is_never_capped(upstream):
    async def run():
        return await _answers(_budget_router("nodur", upstream, drop=("budget_duration",)), 10)

    assert set(asyncio.run(run())) == {STRAITLY_MODEL}
