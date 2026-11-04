"""Each review comes from another AI family than the builder's, and never from MiniMax (owner 2026-11-04).

Runs the review step's real shell with a fake `gh` and `pi` over the records GitHub keeps (the
branch's push log and the agent.yml run names), and checks the router rows, the one review
fallback and the schema guards that keep a review away from a builder's row.
https://docs.litellm.ai/docs/proxy/reliability#fallbacks
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
ROUTER = yaml.safe_load((ROOT / "config/litellm-proxy.yaml").read_text())
SCHEMA = ROOT / "config/litellm-proxy.schema.json"
STEP = yaml.safe_load((ROOT / ".github/workflows/review.yml").read_text())["jobs"]["review"]["steps"][0]
SHA = "0cd15f0bcd48220494314db680061c143bd641b1"
LANE_APP = "nishfleet-worker[bot]"

FAKE_GH = r'''
import json, os, subprocess, sys
args = sys.argv[1:]
jq = args[args.index("--jq") + 1] if "--jq" in args else None
if args[:2] == ["run", "list"]:
    data = [{"displayTitle": t} for t in json.loads(os.environ["RUNS"])]
elif any("/activity" in a for a in args):
    data = json.loads(os.environ["PUSHES"])
elif args[:2] == ["pr", "view"]:
    data = {"title": "t", "body": "b", "author": {"login": "a"}, "reviews": [], "comments": []}
else:
    print("diff or bar"); sys.exit(0)
out = json.dumps(data)
print(subprocess.run(["jq", "-r", jq], input=out, capture_output=True, text=True, check=True).stdout if jq else out)
'''

FAKE_PI = r'''
import os, sys
sys.stdin.read()
open(os.path.join(os.environ["RUNNER_TEMP"], "model"), "w").write(sys.argv[sys.argv.index("--model") + 1])
print("Looks fine.\nVERDICT: APPROVE")
'''


def push(actor=LANE_APP, after=SHA):
    return {"actor": {"login": actor}, "after": after}


def reviewer(tmp_path, branch, pushes=(), runs=()):
    for name, body in (("gh", FAKE_GH), ("pi", FAKE_PI)):
        (tmp_path / name).write_text(f"#!{sys.executable}\n{body}")
        (tmp_path / name).chmod(0o755)
    (tmp_path / "out").write_text("")
    env = {"PATH": f"{tmp_path}:{os.environ['PATH']}", "RUNNER_TEMP": str(tmp_path), "GITHUB_OUTPUT": str(tmp_path / "out"),
           "REPO": "o/r", "PR": "9", "SHA": SHA, "BRANCH": branch, "PR_TEXT": STEP["env"]["PR_TEXT"],
           "PUSHES": json.dumps(list(pushes)), "RUNS": json.dumps([f"agent #{i} engine={e}" for i, e in runs])}
    subprocess.run(["bash", "-c", STEP["run"]], env=env, check=True, capture_output=True, text=True)
    assert "VERDICT: APPROVE" in (tmp_path / "out").read_text()
    return (tmp_path / "model").read_text()


def test_a_lane_head_from_a_pi_run_goes_to_claude(tmp_path):
    assert reviewer(tmp_path, "agent/issue-7", [push()], [(7, "pi"), (77, "claude")]) == "review-claude"


@pytest.mark.parametrize("branch, pushes, runs", [
    ("lead/x", [push()], []),
    ("agent/issue-7", [push()], [(7, "claude")]),
    ("agent/issue-7", [], [(7, "pi")]),
    ("agent/issue-7", [push(actor="nish3451")], [(7, "pi")]),
    ("agent/issue-7", [push(after="f" * 40)], [(7, "pi")]),
    ("agent/issue-7", [push()], []),
    ("agent/issue-7", [push()], [(7, "pi"), (7, "claude")]),
], ids=["lead", "claude-run", "no-push", "human-push", "head-moved", "no-run", "mixed-engines"])
def test_anything_but_a_proven_pi_build_goes_to_qwen(tmp_path, branch, pushes, runs):
    assert reviewer(tmp_path, branch, pushes, runs) == "review-qwen"


def test_agent_run_names_carry_the_issue_and_engine_the_review_reads():
    agent = yaml.safe_load((ROOT / ".github/workflows/agent.yml").read_text())
    assert agent["run-name"].startswith("agent #${{ github.event.issue.number || inputs.issue }} engine=")


def test_the_lane_builders_are_neither_claude_nor_qwen():
    rows = [r for r in ROUTER["model_list"] if r["model_name"] in {"worker-capable", "worker-cheap"}]
    assert rows
    assert [r["model_info"]["id"] for r in rows if re.search("claude|qwen", r["litellm_params"]["model"], re.IGNORECASE)] == []


def test_the_review_groups_hold_one_family_each():
    groups = {g: [r["litellm_params"]["model"] for r in ROUTER["model_list"] if r["model_name"] == g] for g in ("review-claude", "review-qwen")}
    assert groups == {"review-claude": ["anthropic/claude-sonnet-5-5"], "review-qwen": ["openai/qwen3.8-max"]}


def test_claude_falls_back_to_qwen_and_nothing_else_touches_a_review_group():
    edges = [(k, v) for entry in ROUTER["router_settings"]["fallbacks"] for k, vs in entry.items() for v in vs]
    assert [e for e in edges if any(n.startswith("review-") for n in e)] == [("review-claude", "review-qwen")]
    assert not any(k.startswith("review-") or v.startswith("review-") for k, v in ROUTER["router_settings"]["model_group_alias"].items())


def builder_row(group):
    row = json.loads(json.dumps(next(r for r in ROUTER["model_list"] if r["model_info"]["id"] == "minimax-m31-worker-cheap")))
    row["model_name"] = group
    row["model_info"]["id"] = f"bad-{group}"
    return row


def anthropic_row(group):
    row = json.loads(json.dumps(next(r for r in ROUTER["model_list"] if r["model_name"] == "review-qwen")))
    row["litellm_params"]["api_key"] = "os.environ/ANTHROPIC_API_KEY"
    row["model_info"]["id"] = "bad-anthropic"
    return row


@pytest.mark.parametrize("change", [
    lambda c: c["model_list"].append(builder_row("review-qwen")),
    lambda c: c["model_list"].append(builder_row("review-claude")),
    lambda c: c["model_list"].append(anthropic_row("review-qwen")),
    lambda c: c["router_settings"]["fallbacks"].append({"review-claude": ["worker-capable"]}),
    lambda c: c["router_settings"]["fallbacks"].append({"review-qwen": ["review-claude"]}),
    lambda c: c["router_settings"]["fallbacks"].append({"review-qwen": ["tether"]}),
    lambda c: c["router_settings"]["fallbacks"].append({"review-qwen": ["assistant"]}),
    lambda c: c["router_settings"]["fallbacks"].append({"worker-cheap": ["worker-capable", "review-qwen"]}),
], ids=["minimax-in-review-qwen", "minimax-in-review-claude", "anthropic-key-on-review-qwen", "review-falls-to-worker",
        "qwen-falls-to-claude", "review-falls-to-tether", "review-falls-to-assistant", "worker-falls-to-review"])
def test_the_schema_rejects_a_review_that_could_reach_a_builder_or_the_claude_credit(change):
    jsonschema = pytest.importorskip("jsonschema")
    validator = jsonschema.Draft202012Validator(json.loads(SCHEMA.read_text(encoding="utf-8")))
    config = json.loads(json.dumps(ROUTER))
    assert [e.message for e in validator.iter_errors(config)] == []
    change(config)
    assert list(validator.iter_errors(config))


def test_claude_over_its_max_budget_falls_back_to_qwen():
    litellm = pytest.importorskip("litellm")
    import asyncio

    row = json.loads(json.dumps(next(r for r in ROUTER["model_list"] if r["model_name"] == "review-claude")))
    row["litellm_params"].update(input_cost_per_token=1.0, output_cost_per_token=1.0, mock_response="claude answered", api_key="test")
    row["model_info"]["id"] = "review-claude-budget-drill"
    qwen = json.loads(json.dumps(next(r for r in ROUTER["model_list"] if r["model_name"] == "review-qwen")))
    qwen["litellm_params"].update(mock_response="qwen answered", api_key="test")
    messages = [{"role": "user", "content": "review this diff please"}]

    async def drill():
        router = litellm.Router(model_list=[row, qwen], fallbacks=ROUTER["router_settings"]["fallbacks"], num_retries=0)
        first = await router.acompletion(model="review-claude", messages=messages)
        await asyncio.sleep(0.5)
        second = await router.acompletion(model="review-claude", messages=messages)
        return first.choices[0].message.content, second.choices[0].message.content

    assert asyncio.run(drill()) == ("claude answered", "qwen answered")
