"""Opus, Fable and Qwen are reviewer and judge models, never a worker.

Sonnet 5.5 is the only worker model and the only model an orchestrate hand-off
runs. Opus 5.5 is the first reviewer, and Fable 5.1 is the second reviewer of
guard heads: as the default first reviewer it used 44% of a seat's weekly Fable
limit in about 2 days (Nish 2026-10-28, fleet-ops#10608), and the worker and
orchestrate paths stopped selecting it at all (fleet-ops#10750). These checks
read the workflow text itself.
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOWS = sorted((ROOT / ".github/workflows").glob("*.yml"))
AGENT = (ROOT / ".github/workflows/agent.yml").read_text()
DISPATCH = (ROOT / ".github/workflows/agent-dispatch.yml").read_text()


def test_fable_is_named_once_as_the_guard_second_reviewer():
    hits = [(w.name, line.strip()) for w in WORKFLOWS if w.name != "ci.yml" for line in w.read_text().splitlines() if re.search(r"claude-fable", line, re.I)]
    assert hits == [("agent.yml", "SECOND_MODEL: claude-fable-5-1")]


def test_opus_is_named_only_as_the_first_reviewer():
    hits = [(w.name, line.strip()) for w in WORKFLOWS if w.name != "ci.yml" for line in w.read_text().splitlines() if re.search(r"claude-opus", line, re.I)]
    assert hits == [("agent.yml", "FIRST_MODEL_OTHER: claude-opus-5-5"), ("agent.yml", "FIRST_MODEL_CLAUDE_BUILT: claude-opus-5-5")]


def test_first_review_model_is_opus_for_claude_built_and_other_work():
    models = dict(re.findall(r"^\s+(FIRST_MODEL_[A-Z_]+): (\S+)$", AGENT, re.M))
    assert models == {
        "FIRST_MODEL_OTHER": "claude-opus-5-5",
        "FIRST_MODEL_CLAUDE_BUILT": "claude-opus-5-5",
    }


def test_worker_gate_only_picks_sonnet():
    picked = set(re.findall(r"^\s+claude_model=(claude-[a-z0-9-]+)", AGENT, re.M))
    picked |= set(re.findall(r"claude_model=(claude-[a-z0-9-]+) ;;", AGENT))
    assert picked == {"claude-sonnet-5-5"}


def test_orchestrate_hand_off_can_only_run_sonnet():
    assert re.findall(r'echo "model=([^"$]*)"', DISPATCH) == ["claude-sonnet-5-5"]
    assert re.findall(r'echo "turns=([^"$]*)"', DISPATCH) == ["40"]
