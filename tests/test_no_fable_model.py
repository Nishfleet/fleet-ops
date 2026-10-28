"""Fable is never a default model: it is the second reviewer of guard and workflow heads only.

Sonnet 5.5 is the worker; Opus 5.5 is the senior escalation and the first reviewer.
As the default first reviewer, Fable 5.1 used 44% of a seat's weekly Fable limit
in about 2 days, so it reviews only the heads that need three reviews (Nish
2026-10-28, fleet-ops#10608). These checks read the workflow text itself.
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOWS = sorted((ROOT / ".github/workflows").glob("*.yml"))
AGENT = (ROOT / ".github/workflows/agent.yml").read_text()


def test_fable_is_named_once_as_the_guard_second_reviewer():
    hits = [(w.name, line.strip()) for w in WORKFLOWS if not w.name.startswith("ci") for line in w.read_text().splitlines() if re.search(r"claude-fable", line, re.I)]
    assert hits == [("agent.yml", "SECOND_MODEL: claude-fable-5-1")]


def test_first_review_model_is_opus_for_claude_built_and_other_work():
    models = dict(re.findall(r"^\s+(FIRST_MODEL_[A-Z_]+): (\S+)$", AGENT, re.M))
    assert models == {
        "FIRST_MODEL_OTHER": "claude-opus-5-5",
        "FIRST_MODEL_CLAUDE_BUILT": "claude-opus-5-5",
    }


def test_worker_gate_only_picks_sonnet_or_opus():
    picked = set(re.findall(r"^\s+claude_model=(claude-[a-z0-9-]+)", AGENT, re.M))
    picked |= set(re.findall(r"claude_model=(claude-[a-z0-9-]+) ;;", AGENT))
    assert picked == {"claude-sonnet-5-5", "claude-opus-5-5"}
