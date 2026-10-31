"""The gh-aw pilot's tunnel stays as narrow as fleet-ops#11311 says.

The connector carries the chat call and the model list for one hostname, and
everything else is a 404. Every row the pilot key can reach keeps a daily
spend cap, so a leaked key costs at most the sum of those caps.
"""
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def test_the_tunnel_carries_two_router_paths_and_nothing_else():
    ingress = yaml.safe_load((ROOT / "config/cloudflared/llm-gateway.yml").read_text())["ingress"]
    assert ingress == [
        {"hostname": "llm.nish.sh", "path": "^/v1/(chat/completions|models)$", "service": "http://127.0.0.1:4000"},
        {"service": "http_status:404"},
    ]


def test_every_pilot_row_keeps_a_daily_spend_cap():
    rows = [r for r in yaml.safe_load((ROOT / "config/litellm-proxy.yaml").read_text())["model_list"] if r["model_name"] == "pilot"]
    assert rows, "the pilot group has no rows"
    for row in rows:
        params = row["litellm_params"]
        assert params.get("max_budget") and params.get("budget_duration") == "1d", row["model_info"]["id"]
