"""The ticket check (fleet-ops#11949, report only) really runs and posts its verdict.

The steps run here as written in review.yml, under bash -e, with a fake `gh` that answers
from canned REST data and logs every call, and a stub `pi` that answers a canned verdict.
A real Actions run is not possible before merge: agent.yml calls this workflow on main,
where the callee job does not exist yet, and the worker lane holds no GitHub token.
https://docs.github.com/en/actions/reference/workflows-and-actions/contexts#context-availability
"""
import json
import os
import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
WF = yaml.safe_load((ROOT / ".github/workflows/review.yml").read_text())

FAKE_GH = r"""#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["GH_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")
if args[0] != "api":
    sys.exit(0)
path = next(a for a in args[1:] if a.startswith("repos/"))
data = json.load(open(os.environ["GH_DATA"]))
value = data[path]
if "/contents/" in path:  # raw content endpoint: the file, not its JSON envelope
    sys.stdout.write(value)
else:
    sys.stdout.write(json.dumps(value) + "\n")
"""

FAKE_PI = r"""#!/usr/bin/env python3
import os, sys
sys.stdin.read()  # the prompt: consumed like the real seat does
sys.stdout.write(os.environ["PI_VERDICT"])
"""

TICKET = {"title": "Speed up deploys", "body": "Deploys feel slow. Use a queue."}
BAR = "You are the reviewer.\n"
PASS_VERDICT = "The ticket is fine.\nVERDICT: PASS\n"
FAIL_VERDICT = "Question 2 fails.\nVERDICT: FAIL 2: use a built-in\n"


def steps():
    return {s.get("name"): s["run"] for s in WF["jobs"]["ticket-check"]["steps"]}


def run_step(tmp_path, script, data, verdict="", **env):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    for name, body in (("gh", FAKE_GH), ("pi", FAKE_PI)):
        (bin_dir / name).write_text(body)
        (bin_dir / name).chmod(0o755)
    (tmp_path / "data.json").write_text(json.dumps(data))
    (tmp_path / "verdict.txt").write_text(verdict)
    out, log = tmp_path / "out", tmp_path / "gh.log"
    out.touch()
    log.touch()
    proc = subprocess.run(
        ["bash", "-e", "-c", script],
        env={"PATH": f"{bin_dir}:{os.environ['PATH']}", "GH_DATA": str(tmp_path / "data.json"),
             "GH_LOG": str(log), "PI_VERDICT": verdict, "GITHUB_OUTPUT": str(out),
             "RUNNER_TEMP": str(tmp_path), "REPO": "o/r", "ISSUE": "7",
             "GITHUB_REPOSITORY": "o/r", "GITHUB_SERVER_URL": "https://github.com",
             "GITHUB_RUN_ID": "1", "GH_TOKEN": "t", **env},
        capture_output=True, text=True, check=False)
    calls = [json.loads(line) for line in log.read_text().splitlines()]
    return proc, out.read_text(), calls


def check_data():
    return {"repos/o/r/issues/7": TICKET,
            "repos/Nishfleet/fleet-ops/contents/docs/review-bar.md?ref=main": BAR}


def comment_calls(calls):
    return [c for c in calls if c[:2] == ["issue", "comment"]]


# In a called workflow the github context is the caller's, so event_name is never
# 'workflow_call' and an event test would skip the job on every call (fleet-ops#11955).
def test_the_job_gates_on_the_input_alone():
    cond = WF["jobs"]["ticket-check"]["if"]
    assert cond == "inputs.issue != ''"
    assert "github.event_name" not in cond


# Finding 2: both steps use $REPO; the workflow-level env defines it, no step redefines it.
def test_the_ticket_steps_read_repos_from_the_workflow_level_env():
    assert WF["env"]["REPO"] == "${{ github.repository }}"
    assert all("REPO" not in (s.get("env") or {}) for s in WF["jobs"]["ticket-check"]["steps"])


def test_a_pass_runs_the_seat_and_posts_one_pass_comment(tmp_path):
    proc, out, calls = run_step(tmp_path, steps()["Check the ticket with the reviewer's seat"],
                                check_data(), PASS_VERDICT)
    assert proc.returncode == 0, proc.stderr
    assert out.startswith("pass=true\nverdict<<TICKET_") and "VERDICT: PASS" in out
    proc, _, calls = run_step(tmp_path, steps()["One comment on the ticket with the verdict"],
                              {}, PASS_VERDICT, VERDICT=out.split("verdict<<", 1)[1].rsplit("\nTICKET_", 1)[0])
    assert proc.returncode == 0, proc.stderr
    assert comment_calls(calls) == [["issue", "comment", "7", "-R", "o/r", "--body",
                                     "ticket check: PASS (report only, fleet-ops#11949): https://github.com/o/r/actions/runs/1"]]


def test_a_fail_posts_the_verdict_and_what_to_change(tmp_path):
    proc, out, _ = run_step(tmp_path, steps()["Check the ticket with the reviewer's seat"],
                            check_data(), FAIL_VERDICT)
    assert proc.returncode == 0, proc.stderr
    assert out.startswith("verdict<<TICKET_") and "pass=" not in out
    proc, _, calls = run_step(tmp_path, steps()["One comment on the ticket with the verdict"],
                              {}, FAIL_VERDICT, VERDICT=FAIL_VERDICT)
    assert proc.returncode == 0, proc.stderr
    body = comment_calls(calls)[0][-1]
    assert body.startswith("ticket check: FAIL (report only, fleet-ops#11949):\n\n") and body.endswith(
        "\n\nhttps://github.com/o/r/actions/runs/1") and "VERDICT: FAIL 2" in body


def test_no_verdict_fails_the_step_loudly(tmp_path):
    proc, out, calls = run_step(tmp_path, steps()["Check the ticket with the reviewer's seat"],
                                check_data(), "no clear verdict\n")
    assert proc.returncode != 0 and "::error::the reviewer gave no PASS or FAIL verdict" in proc.stdout
    assert comment_calls(calls) == []


def test_the_seat_reads_the_ticket_from_the_workflow_level_repo(tmp_path):
    proc, out, calls = run_step(tmp_path, steps()["Check the ticket with the reviewer's seat"], check_data(), PASS_VERDICT)
    assert proc.returncode == 0, proc.stderr
    assert "repos/o/r/issues/7" in calls[1] and "repos/Nishfleet/fleet-ops/contents/docs/review-bar.md?ref=main" in calls[0]
