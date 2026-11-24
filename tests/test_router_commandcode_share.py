"""CommandCode's rows carry a real share of new worker-capable sessions (fleet-ops#12135).

The plan is on the paid-plan roster and its rows are healthy, but PaidPlanIdle
paged on 2026-11-24 because the fleet's few new sessions had gone a whole day
without landing on it; the next worker run then drew 115 calls from it with no
manual probe. The draw, not the plan, was the defect: 2 of 7 healthy rows made
an unpicked day easy. The two CommandCode rows now carry litellm_params.weight 2
against weight 1 on the other five, so simple-shuffle sends 4/9 = 44.4% of new
sessions to the plan instead of 2/7 = 28.6%.

LiteLLM reads a missing weight as 0 once any row in the group carries one
(litellm/router_strategy/simple_shuffle.py, the proxy image's v1.105.0), so a
row without a weight would silently lose the draw. Every worker-capable row must
carry an integer >= 1. Runs the pinned Router on the shipped rows and counts
picks; no provider is called.
"""
from __future__ import annotations

import asyncio
import random
from pathlib import Path

from router_litellm_pin import require_pinned_litellm

require_pinned_litellm(__file__)

import yaml  # noqa: E402
from litellm import Router  # noqa: E402

CONFIG = Path(__file__).resolve().parents[1] / "config" / "litellm-proxy.yaml"
GROUP = "worker-capable"
COMMANDCODE = {
    "commandcode-glm53flash-worker-capable",
    "commandcode-glm53flashb-worker-capable",
}
PICKS = 2000


def _rows():
    config = yaml.safe_load(CONFIG.read_text(encoding="utf-8"))
    return [r for r in config["model_list"] if r["model_name"] == GROUP]


async def _count(router):
    hits = 0
    for _ in range(PICKS):
        picked = await router.async_get_available_deployment(model=GROUP, request_kwargs={})
        hits += picked["model_info"]["id"] in COMMANDCODE
    return hits


def test_every_worker_row_carries_its_weight():
    weights = {r["model_info"]["id"]: r["litellm_params"].get("weight") for r in _rows()}
    missing = sorted(i for i, w in weights.items() if not isinstance(w, int) or w < 1)
    assert not missing, f"weight missing or < 1, so simple-shuffle reads it as 0: {missing}"
    assert {i for i, w in weights.items() if w > 1} == COMMANDCODE, weights


def test_commandcode_takes_about_its_weighted_share():
    rows = _rows()
    total = sum(r["litellm_params"]["weight"] for r in rows)
    expected = sum(r["litellm_params"]["weight"] for r in rows
                   if r["model_info"]["id"] in COMMANDCODE) / total
    router = Router(
        model_list=[{
            "model_name": GROUP,
            "litellm_params": {"model": "openai/x", "api_base": "http://127.0.0.1:1",
                               "api_key": "k", "weight": r["litellm_params"]["weight"]},
            "model_info": {"id": r["model_info"]["id"]},
        } for r in rows],
        routing_strategy="simple-shuffle",
    )
    random.seed(20261124)
    measured = asyncio.run(_count(router)) / PICKS
    print(f"{GROUP}: expected {expected:.3f} measured {measured:.3f}")
    assert 0.30 <= expected <= 0.60, expected
    assert abs(measured - expected) < 0.05, (measured, expected)


if __name__ == "__main__":
    test_every_worker_row_carries_its_weight()
    test_commandcode_takes_about_its_weighted_share()
    print("PASS")
