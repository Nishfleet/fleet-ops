"""fleet-ops#10943: the risky-path hold list and the two programs that read it agree.

Every case in config/risky-paths.json must classify as its "want" through
agent-dispatch.yml's own CLASSIFY and APPROVAL programs, read out of the workflow, so
the list and the programs cannot drift from what the hold job and the
coordinator-approval gate read. A case with "paths": null stands for an unreadable
list, which must hold. An approval case feeds APPROVAL {sha, statuses, comments},
the shape the gate builds from the head sha, its statuses and the PR's comments.
"""
import json
import pathlib
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/agent-dispatch.yml"
LIST = ROOT / "config/risky-paths.json"


def _env(name):
    out = subprocess.run(
        ["yq", f".env.{name}", str(WORKFLOW)],
        check=True, capture_output=True, text=True, timeout=120)
    value = out.stdout.strip()
    assert value and value != "null", f"agent-dispatch.yml env {name} is missing"
    return value


@pytest.fixture(scope="module")
def config():
    return json.loads(LIST.read_text())


@pytest.fixture(scope="module")
def classify():
    program, label = _env("CLASSIFY"), _env("LABEL")
    assert label == "needs-coordinator"

    def run(case, cfg):
        done = subprocess.run(
            ["jq", "-c", "--argjson", "cfg", json.dumps(cfg), "--arg", "label", label, program],
            input=json.dumps(case), capture_output=True, text=True, timeout=120)
        assert done.returncode == 0, done.stderr
        return json.loads(done.stdout)

    return run


@pytest.fixture(scope="module")
def approve():
    program, context = _env("APPROVAL"), _env("CONTEXT")
    assert context == "coordinator-approval"

    def run(case):
        assert "approvers" in case, f"{case['id']}: no approvers list"
        done = subprocess.run(
            ["jq", "-r", "--arg", "c", context, "--arg", "who", " ".join(case["approvers"]), program],
            input=json.dumps({k: case.get(k) for k in ("sha", "statuses", "comments")}),
            capture_output=True, text=True, timeout=120)
        assert done.returncode == 0, done.stderr
        return done.stdout.strip()

    return run


def test_every_case_classifies_as_its_want(config, classify):
    assert config.get("paths", {}).get("*"), "risky-paths.json holds no '*' path, so nothing is held"
    assert config["cases"], "risky-paths.json holds no case, so the classifier is untested"
    wrong = []
    for case in config["cases"]:
        cfg = {"paths": case["paths"]} if "paths" in case else config
        got = classify(case, cfg)
        if got["risky"] != case["want"]:
            wrong.append(f"{case['id']}: got {json.dumps(got)}")
    assert not wrong, "\n".join(wrong)


def test_every_approval_case_answers_its_want(config, approve):
    assert config["approval_cases"], "risky-paths.json holds no approval case, so the program is untested"
    wrong = []
    for case in config["approval_cases"]:
        assert isinstance(case["want"], bool), f"{case['id']}: want is not a bool"
        got = approve(case)
        if got != json.dumps(case["want"]):
            wrong.append(f"{case['id']}: got {got}")
    assert not wrong, "\n".join(wrong)
