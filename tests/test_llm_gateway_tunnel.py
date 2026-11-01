"""The gh-aw pilot's tunnel stays as narrow as fleet-ops#11311 says.

The connector carries the chat call and the model list for one hostname, and
everything else is a 404.
"""
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def test_the_tunnel_carries_two_router_paths_and_nothing_else():
    ingress = yaml.safe_load((ROOT / "config/cloudflared/llm-gateway.yml").read_text())["ingress"]
    assert [{k: v for k, v in rule.items() if k != "originRequest"} for rule in ingress] == [
        {"hostname": "llm.nish.sh", "path": "^/v1/(chat/completions|models)$", "service": "http://127.0.0.1:4000"},
        {"service": "http_status:404"},
    ]


def test_the_connector_requires_a_valid_access_token():
    access = yaml.safe_load((ROOT / "config/cloudflared/llm-gateway.yml").read_text())["ingress"][0]["originRequest"]["access"]
    assert access["required"] is True and access["teamName"] and len(access["audTag"]) == 1
