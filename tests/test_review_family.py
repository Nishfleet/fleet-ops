"""The reviewer is never the builder's AI family (decisions ledger 2026-11-04).

Runs the real shell of review.yml's pick step over the records GitHub keeps (the branch's push
log and the agent.yml run names), never the PR body, and checks the router rows that make the
pick true: the lane's worker groups hold no Claude or Grok row, and review-claude is Claude
alone with no fallback, so it cannot answer from a builder's family.
"""
import itertools
import json
import os
import re
import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
ROUTER = yaml.safe_load((ROOT / "config/litellm-proxy.yaml").read_text())
LANE_GROUPS = {"worker-capable", "worker-cheap"}
SHA = "0cd15f0bcd48220494314db680061c143bd641b1"
LANE_APP = "nishfleet-worker[bot]"
CLAUDE = ("litellm", "review-claude")
GROK = ("xai-oauth", "grok-4.7")


def workflow(name):
    return yaml.safe_load((ROOT / ".github/workflows" / name).read_text())


def push(actor=LANE_APP, after=SHA):
    return {"activity_type": "branch_creation", "actor": {"login": actor}, "after": after}


def run(issue, engine):
    return {"display_title": f"agent #{issue} engine={engine}"}


def pick(tmp_path, branch, pushes=(), runs=(), body="builder: pi litellm/worker-capable"):
    (tmp_path / "body.md").write_text(body)
    (tmp_path / "pushes.json").write_text(json.dumps(list(pushes)))
    (tmp_path / "runs.json").write_text(json.dumps(list(runs)))
    out = tmp_path / "out"
    out.write_text("")
    script = next(s for s in workflow("review.yml")["jobs"]["review"]["steps"] if s.get("id") == "pick")["run"]
    env = {"PATH": os.environ["PATH"], "BRANCH": branch, "SHA": SHA, "RUNNER_TEMP": str(tmp_path), "GITHUB_OUTPUT": str(out)}
    subprocess.run(["bash", "-c", script], env=env, check=True)
    return dict(line.split("=", 1) for line in out.read_text().splitlines())


def test_agent_run_names_carry_the_issue_and_engine_the_picker_reads():
    assert workflow("agent.yml")["run-name"].startswith("agent #${{ github.event.issue.number || inputs.issue }} engine=")


def test_a_lane_head_from_a_pi_run_is_reviewed_by_claude(tmp_path):
    got = pick(tmp_path, "agent/issue-7", [push()], [run(7, "pi"), run(77, "claude")])
    assert ((got["provider"], got["model"]), got["name"]) == (CLAUDE, "Claude Sonnet 5.5")
    assert "note" not in got


def test_a_claude_build_is_never_reviewed_by_claude_whatever_the_body_says(tmp_path):
    for branch, runs in [("lead/review-family", []), ("agent/issue-7", [run(7, "claude")])]:
        got = pick(tmp_path, branch, [push()], runs, body="builder: pi litellm/worker-capable")
        assert (got["provider"], got["model"]) == GROK, branch
        assert "note" not in got


@pytest.mark.parametrize("pushes, runs", [
    ([], [run(7, "pi")]),
    ([push(actor="nish3451")], [run(7, "pi")]),
    ([push(after="f" * 40), push()], [run(7, "pi")]),
    ([push()], []),
    ([push()], [run(7, "pi"), run(7, "claude")]),
], ids=["no-push", "human-push", "head-moved", "no-run", "mixed-engines"])
def test_an_unproven_builder_falls_back_to_grok_and_says_so(tmp_path, pushes, runs):
    got = pick(tmp_path, "agent/issue-7", pushes, runs)
    assert (got["provider"], got["model"]) == GROK
    assert got["note"]


def test_the_reviewer_is_only_ever_claude_or_grok(tmp_path):
    branches = ["agent/issue-7", "lead/x", "nish/hotfix", "agent/issue-7x", ""]
    pushes = [[], [push()], [push(actor="nish3451")]]
    engines = ["pi", "claude", "minimax", "glm", "deepseek", "", "pi claude"]
    bodies = ["builder: minimax", "builder: pi", "builder: claude", "garbage"]
    for branch, p, engine, body in itertools.product(branches, pushes, engines, bodies):
        got = pick(tmp_path, branch, p, [run(7, engine)], body)
        assert (got["provider"], got["model"]) in {CLAUDE, GROK}, (branch, p, engine, body)


def test_the_lane_builders_are_neither_claude_nor_grok():
    rows = [r for r in ROUTER["model_list"] if r["model_name"] in LANE_GROUPS]
    assert rows
    assert [r["model_info"]["id"] for r in rows if re.search("claude|grok|xai",r["litellm_params"]["model"], re.IGNORECASE)] == []


def test_review_claude_is_claude_alone_and_never_falls_back():
    rows = [r for r in ROUTER["model_list"] if r["model_name"] == "review-claude"]
    assert rows and all("claude" in r["litellm_params"]["model"].lower() for r in rows)
    fallbacks = {k: v for entry in ROUTER["router_settings"]["fallbacks"] for k, v in entry.items()}
    assert "review-claude" not in fallbacks
    assert not any("review-claude" in v for v in fallbacks.values())
