"""PaidPlanIdle's recurring pages are draw cadence, not a routing fault (fleet-ops#12136).

The review on #12139 read #12128's one bad day ("529 worker-capable calls, all
on the MiniMax rows") as the steady state and asked for a routing weight so
"real worker calls reach the CommandCode and z.ai GLM-5.3-Flash rows". Two
facts, both measured, say the routing already does that and a weight bump
cannot improve it:

- v1.105.0's simple-shuffle (the pinned image's litellm/router_strategy/
  simple_shuffle.py) reads litellm_params.weight per row and reads a missing
  weight as 0, so the weighted branch engages only when some candidate row
  carries one - and then every unweighted row is never picked. With no weight
  anywhere (the owner roster's plain rows, fleet-ops#10935) the pick is
  random.choice over the healthy rows: uniform. Each GLM plan's two
  worker-capable rows therefore draw ~2/7 of the session picks with no weight
  at all, and a partial weight would silently bench every unweighted row.
- The live 7-day counters (Prometheus, 2026-11-24) put 613 CommandCode and
  235 z.ai successes among 2960 worker-capable calls, ~29% to the two GLM
  plans, with real pinned sessions on 5 of 7 days each; z.ai's only drought is
  the 2 straight days the two #12132/#12136 pages cover. At the measured ~26
  pinned sessions a week, a 2-row plan misses a 24-hour window with
  probability (5/7)^3.7 ~ 29% a day - the page cadence the tickets record.
  Uniform is the minimum-miss allocation over the group, so any GLM weight
  above its neighbour's trades the drought onto MiniMax or OpenCode instead
  of removing it.

This module holds those two facts: the live config keeps its plain rows (no
partial weights anywhere), and the pinned litellm draws the live worker-capable
rows uniformly per pick while a single weighted row takes every pick from its
unweighted peers.

  uvx --with "litellm==$(python tests/router_litellm_pin.py)" --with pytest==8.3.5 \
      --with jsonschema --with httpx python -m pytest -q tests/test_router_paid_plan_draws.py
"""
from __future__ import annotations

import collections
import json
import pathlib
import shutil
import subprocess

import pytest
from router_litellm_pin import require_pinned_litellm

require_pinned_litellm(__file__)

pytest.importorskip("litellm")

from litellm.router_strategy.simple_shuffle import simple_shuffle

ROOT = pathlib.Path(__file__).resolve().parents[1]
CONFIG = ROOT / "config/litellm-proxy.yaml"
YQ = shutil.which("yq")
PICKS = 7000


def _model_list() -> list[dict]:
    assert YQ, "yq must be on PATH to read the router config"
    out = subprocess.run(
        [YQ, "-o=json", ".model_list", str(CONFIG)], capture_output=True, text=True, check=True
    ).stdout
    return json.loads(out)


def _rows(group: str) -> list[dict]:
    return [row for row in _model_list() if row["model_name"] == group]


def _as_candidates(rows: list[dict]) -> list[dict]:
    """The shape simple_shuffle consumes: litellm_params plus model_info.id."""
    return [{"litellm_params": row["litellm_params"], "model_info": dict(row["model_info"])} for row in rows]


def test_no_router_group_mixes_weighted_and_unweighted_rows():
    """A partial weight is a silent bench: the weighted branch reads a missing
    weight as 0 and never picks that row again (simple_shuffle, pinned v1.105.0;
    drilled by test_one_weighted_row_takes_every_pick_from_unweighted_peers).
    The owner roster's plain rows (fleet-ops#10935) keep every group unweighted,
    so every row stays in the draw and PaidPlanIdle's draw share stays uniform."""
    mixed = []
    for group in sorted({row["model_name"] for row in _model_list()}):
        rows = _rows(group)
        weighted = [row for row in rows if "weight" in row["litellm_params"]]
        if weighted and len(weighted) != len(rows):
            mixed.append(f"{group}: {len(weighted)}/{len(rows)} rows carry a weight")
    assert not mixed, f"groups mixing weighted and unweighted rows (the unweighted ones are never picked): {mixed}"


def test_one_weighted_row_takes_every_pick_from_unweighted_peers():
    """The vendor fact the config guard leans on: with one row carrying a weight,
    simple_shuffle's weighted branch engages and the missing-weight rows read 0 -
    70k picks never leave the weighted row."""
    rows = _as_candidates(_rows("worker-capable"))
    weighted = [dict(row, litellm_params={**row["litellm_params"], "weight": 5}) if i == 3 else row
                for i, row in enumerate(rows)]
    picked = collections.Counter(
        simple_shuffle(lambda model: None, weighted, "worker-capable", {})["model_info"]["id"]
        for _ in range(PICKS)
    )
    assert set(picked) == {rows[3]["model_info"]["id"]}, f"unweighted peers were picked: {set(picked)}"


def test_the_live_worker_capable_rows_draw_uniformly_so_the_glm_plans_get_real_picks():
    """With the plain rows (no weight), the pinned litellm's simple_shuffle is
    random.choice over the healthy rows: each of the 7 worker-capable rows draws
    ~1/7 per pick, so the two GLM-5.3-Flash plans (CommandCode, z.ai) draw ~2/7
    of the session picks with no routing change. Measured live over 7 days to
    2026-11-24: 848 of 2960 worker-capable successes on the GLM rows, ~29%."""
    rows = _as_candidates(_rows("worker-capable"))
    assert len(rows) == 7, f"worker-capable row count changed: {len(rows)}; redo the share sums"
    assert all("weight" not in row["litellm_params"] for row in rows), "weights appeared; redo this drill"
    picked = collections.Counter(
        simple_shuffle(lambda model: None, rows, "worker-capable", {})["model_info"]["id"]
        for _ in range(PICKS)
    )
    off = {row_id: count for row_id, count in picked.items() if not 0.115 <= count / PICKS <= 0.170}
    assert not off, f"pick is not uniform across the live rows (expected ~{PICKS // 7} each): {off}"
