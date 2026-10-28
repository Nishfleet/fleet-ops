"""Nish 2026-10-13: "OC has 2 keys, and both are unlimited usage along with cc but
only on ds4.1 flash". Key 2 left on 2026-10-26 (Nish: "Don't renew OpenCode Go
key 2"), so one OpenCode Go ds41flash row per worker group carries a weight in
config/litellm-proxy.yaml so simple-shuffle sends about a third of each worker
group's picks to them, with no row removed or benched.

Runs the real Router of the pinned LiteLLM v1.98.0 on the shipped worker rows
(litellm/router_strategy/simple_shuffle.py:43-59 weights the pick only when the
first healthy row has a weight, and reads a missing weight as 0) and counts
2000 picks per group. Share = k*w / (k*w + n - k).
"""
import asyncio
import random
import re
from pathlib import Path

import yaml
from litellm import Router

CONFIG_PATH = Path(__file__).resolve().parent.parent / "config" / "litellm-proxy.yaml"
PREFERRED = re.compile(r"^opencodego-ds41flash-worker-(capable|cheap)$")
GROUPS = ("worker-capable", "worker-cheap")
PICKS = 2000


def _rows(group):
    config = yaml.safe_load(CONFIG_PATH.read_text())
    return [r for r in config["model_list"] if r["model_name"] == group]


def _router(group):
    rows = [
        {
            "model_name": r["model_name"],
            "litellm_params": {
                "model": "openai/x",
                "api_base": "http://127.0.0.1:1",
                "api_key": "k",
                "order": r["litellm_params"]["order"],
                "weight": r["litellm_params"]["weight"],
            },
            "model_info": {"id": r["model_info"]["id"]},
        }
        for r in _rows(group)
    ]
    return Router(model_list=rows, routing_strategy="simple-shuffle", num_retries=0)


async def _share(group):
    router = _router(group)
    preferred = 0
    for _ in range(PICKS):
        d = await router.async_get_available_deployment(model=group, request_kwargs={})
        preferred += bool(PREFERRED.match(d["model_info"]["id"]))
    return preferred / PICKS


def test_every_worker_row_has_an_integer_weight_and_one_is_preferred():
    for group in GROUPS:
        rows = _rows(group)
        weights = {r["model_info"]["id"]: r["litellm_params"].get("weight") for r in rows}
        assert all(isinstance(w, int) and w >= 1 for w in weights.values()), weights
        heavy = {i for i, w in weights.items() if w > 1}
        assert len(heavy) == 1 and all(PREFERRED.match(i) for i in heavy), heavy


def test_preferred_rows_take_about_a_third_of_each_group():
    random.seed(20261013)
    for group in GROUPS:
        rows = _rows(group)
        n = len(rows)
        heavy = [r["litellm_params"]["weight"] for r in rows if r["litellm_params"]["weight"] > 1]
        k, w = len(heavy), heavy[0]
        expected = k * w / (k * w + n - k)
        measured = asyncio.run(_share(group))
        print(f"{group}: n={n} k={k} w={w} expected {expected:.3f} measured {measured:.3f}")
        assert 0.30 <= expected <= 0.60, (group, expected)
        assert abs(measured - expected) < 0.05, (group, measured, expected)


if __name__ == "__main__":
    test_every_worker_row_has_an_integer_weight_and_one_is_preferred()
    test_preferred_rows_take_about_a_third_of_each_group()
    print("PASS")
