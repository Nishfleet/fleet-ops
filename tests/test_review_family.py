"""The reviewer is never the builder's AI family (decisions ledger 2026-11-04).

Runs the real shell from agent.yml (the `builder:` line it writes into the PR body) and from
review.yml (the step that picks the reviewer), and checks the router rows that make the
pick true: the lane's worker groups hold no Claude or Grok row, and review-claude is Claude
alone with no fallback, so it cannot answer from a builder's family.
"""
import os
import re
import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
ROUTER = yaml.safe_load((ROOT / "config/litellm-proxy.yaml").read_text())
LANE_GROUPS = {"worker-capable", "worker-cheap"}


def step(workflow, job, name):
    steps = yaml.safe_load((ROOT / ".github/workflows" / workflow).read_text())["jobs"][job]["steps"]
    return next(s for s in steps if s.get("name") == name)


def lane_builder_line(engine):
    run = step("agent.yml", "push", "Push the branch, open the PR and arm auto-merge")["run"]
    case = next(line for line in run.splitlines() if line.strip().startswith('case "$ENGINE"'))
    out = subprocess.run(["bash", "-c", case + '\nprintf %s "$builder"'], env={"ENGINE": engine},
                         capture_output=True, text=True, check=True)
    return out.stdout


def pick(tmp_path, branch, body):
    (tmp_path / "body.md").write_text(body)
    out = tmp_path / "out"
    out.write_text("")
    run = step("review.yml", "review", "Pick a reviewer from another family than the builder's")["run"]
    env = {"PATH": os.environ["PATH"], "BRANCH": branch, "RUNNER_TEMP": str(tmp_path), "GITHUB_OUTPUT": str(out)}
    subprocess.run(["bash", "-c", run], env=env, check=True)
    return dict(line.split("=", 1) for line in out.read_text().splitlines())


def lane_body(engine, proof="run-proof: pytest -q -> 3 passed"):
    return f"Closes #7\n\nBuilt by the agent lane: https://example.invalid/run\n{lane_builder_line(engine)}\n\n{proof}"


def is_claude(row):
    return "claude" in row["litellm_params"]["model"].lower()


def test_a_claude_built_pr_is_never_reviewed_by_claude(tmp_path):
    for branch, body in [("lead/review-family", "builder: pi litellm/worker-capable"),
                         ("agent/issue-7", lane_body("claude"))]:
        got = pick(tmp_path, branch, body)
        assert (got["provider"], got["model"]) == ("xai-oauth", "grok-4.7"), branch


@pytest.mark.parametrize("engine", ["pi", ""])
def test_a_glm_built_lane_pr_can_be_reviewed_by_claude(tmp_path, engine):
    got = pick(tmp_path, "agent/issue-7", lane_body(engine).replace("\n", "\r\n"))
    assert (got["provider"], got["model"], got["name"]) == ("litellm", "review-claude", "Claude Sonnet 5.5")
    assert "note" not in got


@pytest.mark.parametrize("branch, engine", [("agent/issue-7", None), ("nish/hotfix", "pi")])
def test_an_unknown_builder_falls_back_to_grok_and_says_so(tmp_path, branch, engine):
    body = lane_body(engine) if engine else "Closes #7\n\nrun-proof: echo builder: pi -> ok"
    got = pick(tmp_path, branch, body)
    assert (got["provider"], got["model"]) == ("xai-oauth", "grok-4.7")
    assert "could not be determined" in got["note"]


def test_the_lane_builders_are_neither_claude_nor_grok():
    rows = [r for r in ROUTER["model_list"] if r["model_name"] in LANE_GROUPS]
    assert rows
    assert [r["model_info"]["id"] for r in rows if is_claude(r) or re.search("grok|xai", r["litellm_params"]["model"], re.IGNORECASE)] == []


def test_review_claude_is_claude_alone_and_never_falls_back():
    rows = [r for r in ROUTER["model_list"] if r["model_name"] == "review-claude"]
    assert rows and all(is_claude(r) for r in rows)
    fallbacks = {k: v for entry in ROUTER["router_settings"]["fallbacks"] for k, v in entry.items()}
    assert "review-claude" not in fallbacks
    assert not any("review-claude" in v for v in fallbacks.values())
