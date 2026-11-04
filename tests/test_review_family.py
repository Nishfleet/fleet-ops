"""Each review tries every allowed family in order, never the builder's and never MiniMax (owner 2026-11-04).

Runs the real shell of review.yml's steps over the records GitHub keeps (the branch's push log and
the agent.yml run names), never the PR body: the pick step's order, each reviewer step with a stand-in
pi, and the step that names who answered. Checks the router rows and the schema guards that keep a
review away from a builder's row, and drills on the proxy's litellm that a row over its max_budget
fails the call instead of answering from another group.
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
SCHEMA = ROOT / "config/litellm-proxy.schema.json"
LANE_GROUPS = {"worker-capable", "worker-cheap"}
SHA = "0cd15f0bcd48220494314db680061c143bd641b1"
LANE_APP = "nishfleet-worker[bot]"
PI_ORDER = ["claude", "grok", "qwen"]
CLAUDE_ORDER = ["grok", "qwen"]
BUILDER_FAMILIES = re.compile("minimax|glm|deepseek", re.IGNORECASE)


def workflow(name):
    return yaml.safe_load((ROOT / ".github/workflows" / name).read_text())


def step(step_id):
    return next(s for s in workflow("review.yml")["jobs"]["review"]["steps"] if s.get("id") == step_id)


def push(actor=LANE_APP, after=SHA):
    return {"activity_type": "branch_creation", "actor": {"login": actor}, "after": after}


def run(issue, engine):
    return {"display_title": f"agent #{issue} engine={engine}"}


def outputs(path):
    blocks = re.compile(r"^(\w+)<<(\w+)\n(.*?)\n\2$", re.DOTALL | re.MULTILINE)
    text = path.read_text()
    found = {key: value for key, _, value in blocks.findall(text)}
    found.update(line.split("=", 1) for line in blocks.sub("", text).splitlines() if "=" in line)
    return found


def shell(tmp_path, script, **env):
    out = tmp_path / "out"
    out.write_text("")
    full = {"PATH": f"{tmp_path}:{os.environ['PATH']}", "SHA": SHA, "RUNNER_TEMP": str(tmp_path), "GITHUB_OUTPUT": str(out), **env}
    done = subprocess.run(["bash", "-c", script], check=False, env=full, capture_output=True, text=True)
    return done.returncode, outputs(out)


def pick(tmp_path, branch, pushes=(), runs=(), body="builder: pi litellm/worker-capable"):
    (tmp_path / "body.md").write_text(body)
    (tmp_path / "pushes.json").write_text(json.dumps(list(pushes)))
    (tmp_path / "runs.json").write_text(json.dumps(list(runs)))
    code, got = shell(tmp_path, step("pick")["run"], BRANCH=branch)
    assert code == 0
    return got["order"].split(), got.get("note")


def test_agent_run_names_carry_the_issue_and_engine_the_picker_reads():
    assert workflow("agent.yml")["run-name"].startswith("agent #${{ github.event.issue.number || inputs.issue }} engine=")


def test_a_lane_head_from_a_pi_run_tries_claude_then_grok_then_qwen(tmp_path):
    assert pick(tmp_path, "agent/issue-7", [push()], [run(7, "pi"), run(77, "claude")]) == (PI_ORDER, None)


def test_a_claude_build_tries_grok_then_qwen_whatever_the_body_says(tmp_path):
    for branch, runs in [("lead/review-family", []), ("agent/issue-7", [run(7, "claude")])]:
        assert pick(tmp_path, branch, [push()], runs, body="builder: pi litellm/worker-capable") == (CLAUDE_ORDER, None), branch


@pytest.mark.parametrize("pushes, runs", [
    ([], [run(7, "pi")]),
    ([push(actor="nish3451")], [run(7, "pi")]),
    ([push(after="f" * 40), push()], [run(7, "pi")]),
    ([push()], []),
    ([push()], [run(7, "pi"), run(7, "claude")]),
], ids=["no-push", "human-push", "head-moved", "no-run", "mixed-engines"])
def test_an_unproven_builder_tries_grok_then_qwen_and_says_so(tmp_path, pushes, runs):
    order, note = pick(tmp_path, "agent/issue-7", pushes, runs)
    assert order == CLAUDE_ORDER
    assert note


def test_every_builder_gets_one_of_the_two_orders_and_never_minimax(tmp_path):
    branches = ["agent/issue-7", "lead/x", "nish/hotfix", "agent/issue-7x", ""]
    pushes = [[], [push()], [push(actor="nish3451")]]
    engines = ["pi", "claude", "minimax", "glm", "deepseek", "", "pi claude"]
    bodies = ["builder: minimax", "builder: pi", "builder: claude", "garbage"]
    for branch, p, engine, body in itertools.product(branches, pushes, engines, bodies):
        order, _ = pick(tmp_path, branch, p, [run(7, engine)], body)
        assert order in (PI_ORDER, CLAUDE_ORDER), (branch, p, engine, body)


def test_the_reviewer_steps_run_in_order_each_only_after_every_earlier_one_failed():
    steps = [step(i) for i in PI_ORDER]
    assert [(s["env"]["PROVIDER"], s["env"]["MODEL"]) for s in steps] == [
        ("litellm", "review-claude"), ("xai-oauth", "grok-4.7"), ("litellm", "review-qwen")]
    assert [s["if"] for s in steps] == [
        "contains(steps.pick.outputs.order, 'claude')",
        "steps.claude.outcome != 'success'",
        "steps.claude.outcome != 'success' && steps.grok.outcome != 'success'"]
    assert [s.get("continue-on-error", False) for s in steps] == [True, True, False]
    assert len({s["run"] for s in steps}) == 1


def stand_in_pi(tmp_path, answers):
    (tmp_path / "answers.json").write_text(json.dumps(answers))
    pi = tmp_path / "pi"
    pi.write_text(
        "#!/usr/bin/env python3\n"
        "import json, sys\n"
        "argv = sys.argv\n"
        "model = argv[argv.index('--model') + 1]\n"
        f"kind = json.load(open({str(tmp_path / 'answers.json')!r}))[model]\n"
        "sys.stdin.read()\n"
        "if kind == 'ok': print('Looks fine.\\nVERDICT: APPROVE'); sys.exit(0)\n"
        "if kind == 'no-verdict': print('I think it is fine.'); sys.exit(0)\n"
        "msg = {'budget': '400: No deployments available - crossed budget: Exceeded budget for deployment', 'error': '500: upstream connect error'}[kind]\n"
        "print(msg, file=sys.stderr); sys.exit(1)\n")
    pi.chmod(0o755)
    (tmp_path / "bar.md").write_text("bar")
    (tmp_path / "prompt.md").write_text("diff")


@pytest.mark.parametrize("answers, reviewer, notes", [
    ({"review-claude": "ok"}, "Claude Sonnet 5.5", []),
    ({"review-claude": "budget", "grok-4.7": "ok"}, "Grok 4.7", ["Claude Sonnet 5.5 did not answer (budget)."]),
    ({"review-claude": "error", "grok-4.7": "no-verdict", "review-qwen": "ok"}, "Qwen 3.8 Max",
     ["Claude Sonnet 5.5 did not answer (error).", "Grok 4.7 did not answer (error)."]),
    ({"review-claude": "budget", "grok-4.7": "error", "review-qwen": "error"}, None, None),
], ids=["claude-answers", "claude-over-budget", "two-fail", "all-fail"])
def test_the_review_names_who_answered_and_why_earlier_ones_did_not(tmp_path, answers, reviewer, notes):
    stand_in_pi(tmp_path, answers)
    script = step("claude")["run"]
    outcomes = []
    for sid in PI_ORDER:
        if any(o == "success" for o in outcomes):
            outcomes.append("skipped")
            continue
        code, _ = shell(tmp_path, script, GITHUB_ACTION=sid, **step(sid)["env"])
        outcomes.append("success" if code == 0 else "failure")
    if reviewer is None:
        assert outcomes == ["failure"] * 3
        return
    code, got = shell(tmp_path, step("ai")["run"], NOTE="",
                      OUTCOMES=" ".join(f"{i}={o}" for i, o in zip(PI_ORDER, outcomes)))
    assert code == 0
    assert got["reviewer"] == reviewer
    assert got["review"] == "".join(f"{n}\n\n" for n in [" ".join(notes)] if notes) + "Looks fine.\nVERDICT: APPROVE"
    assert "Exceeded" not in got["review"] and "upstream" not in got["review"]


def test_the_lane_builders_are_neither_claude_nor_grok_nor_qwen():
    rows = [r for r in ROUTER["model_list"] if r["model_name"] in LANE_GROUPS]
    assert rows
    assert [r["model_info"]["id"] for r in rows if re.search("claude|grok|xai|qwen", r["litellm_params"]["model"], re.IGNORECASE)] == []


def test_the_review_groups_hold_one_family_each_and_never_a_builders_row():
    groups = {g: [r["litellm_params"]["model"] for r in ROUTER["model_list"] if r["model_name"] == g] for g in ("review-claude", "review-qwen")}
    assert groups == {"review-claude": ["anthropic/claude-sonnet-5-5"], "review-qwen": ["openai/qwen3.8-max"]}
    review_rows = [r for r in ROUTER["model_list"] if r["model_name"].startswith("review-")]
    assert [r["model_info"]["id"] for r in review_rows if BUILDER_FAMILIES.search(r["litellm_params"]["model"])] == []


def test_no_review_group_falls_back_or_is_fallen_into():
    edges = [(k, v) for entry in ROUTER["router_settings"]["fallbacks"] for k, vs in entry.items() for v in vs]
    assert [e for e in edges if any(n.startswith("review-") for n in e)] == []
    for key in ("default_fallbacks", "content_policy_fallbacks", "context_window_fallbacks"):
        assert key not in ROUTER["router_settings"]
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
    lambda c: c["router_settings"]["fallbacks"].append({"review-qwen": ["tether"]}),
    lambda c: c["router_settings"]["fallbacks"].append({"review-qwen": ["assistant"]}),
    lambda c: c["router_settings"]["fallbacks"].append({"worker-cheap": ["worker-capable", "review-qwen"]}),
], ids=["minimax-in-review-qwen", "minimax-in-review-claude", "anthropic-key-on-review-qwen",
        "review-falls-to-worker", "review-falls-to-tether", "review-falls-to-assistant", "worker-falls-to-review"])
def test_the_schema_rejects_a_review_that_could_reach_a_builder_or_the_claude_credit(change):
    jsonschema = pytest.importorskip("jsonschema")
    validator = jsonschema.Draft202012Validator(json.loads(SCHEMA.read_text(encoding="utf-8")))
    config = json.loads(json.dumps(ROUTER))
    assert [e.message for e in validator.iter_errors(config)] == []
    change(config)
    assert list(validator.iter_errors(config))


def test_a_review_row_over_its_max_budget_fails_the_call_and_nothing_else_answers():
    litellm = pytest.importorskip("litellm")
    import asyncio

    row = json.loads(json.dumps(next(r for r in ROUTER["model_list"] if r["model_name"] == "review-claude")))
    row["litellm_params"].update(input_cost_per_token=1.0, output_cost_per_token=1.0, mock_response="VERDICT: APPROVE", api_key="test")
    row["model_info"]["id"] = "review-claude-budget-drill"
    qwen = json.loads(json.dumps(next(r for r in ROUTER["model_list"] if r["model_name"] == "review-qwen")))
    qwen["litellm_params"].update(mock_response="qwen answered", api_key="test")
    messages = [{"role": "user", "content": "review this diff please"}]

    async def drill():
        router = litellm.Router(model_list=[row, qwen], fallbacks=ROUTER["router_settings"]["fallbacks"], num_retries=0)
        first = await router.acompletion(model="review-claude", messages=messages)
        await asyncio.sleep(0.5)
        with pytest.raises(Exception, match="budget") as wall:
            await router.acompletion(model="review-claude", messages=messages)
        return first, wall

    first, _ = asyncio.run(drill())
    assert first.choices[0].message.content == "VERDICT: APPROVE"
