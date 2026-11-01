"""Parked hand-offs in agent-dispatch.yml's list job (fleet-ops#10420, #10475): the step's real
`run:` block and REQUEUE program (read out with yq) against a fake gh.

A handoff-ended issue idle over 6 h goes back to needs-orchestrator (and an agent-blocked one, even with
old end markers, is left alone). A labelled idle one with no orch/issue-N PR is re-fired by a task=orchestrate
dispatch of the calling workflow file, with a marker comment and no label write. At most 12 minus the live
orchestrate runs a sweep, and a closed blocker releases at most 12. Three ended or re-fired hand-offs give
needs-nish-decision.
"""
import datetime
import json
import os
import pathlib
import re
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
WF = str(ROOT / ".github/workflows/agent-dispatch.yml")
STEP = ".jobs.list.steps[] | select(.env.REQUEUE)"
LIST = '.jobs.list.steps[] | select(.id == "list")'
REFIRED = "orchestrator re-fired by the sweep: https://example.invalid/runs/"
ENDED = "orchestrator hand-off ended without a PR: https://example.invalid/runs/"
INFRA = "orchestrator hand-off ended on infrastructure: https://example.invalid/runs/"

FAKE_GH = r"""#!/usr/bin/env bash
cred() { [ -n "$GH_TOKEN" ] || [ -e "$FAKE_DIR/login" ] || { echo "gh: no credential: $*" >&2; exit 4; }; }
case "$1 $2" in
  "issue list") case "$*" in *"-S label:handoff-ended,needs-orchestrator "*) ;; *) echo "fake gh: unexpected search: $*" >&2; exit 1 ;; esac; cat "$FAKE_DIR/issues.json" ;;
  "pr list") [ -z "$FAIL_PRS" ] || exit 1; cat "$FAKE_DIR/prs.json" ;;
  "api repos/o/r/actions/workflows/stub.yml/runs?status=in_progress&per_page=100")
    [ -z "$FAIL_RUNS" ] || exit 1
    jq -r "$4" "$FAKE_DIR/runs.json" ;;
  "api repos/o/r/actions/runs/"*)
    [ -z "$FAIL_JOBS" ] || exit 1
    id=${2#repos/o/r/actions/runs/}; id=${id%/jobs}
    jq --arg id "$id" '.[$id]' "$FAKE_DIR/jobs.json" | jq -r "$4" ;;
  "workflow run") [ -z "$FAIL_DISPATCH" ] || exit 1; cred "$@"; echo "$*" >> "$FAKE_DIR/writes.log" ;;
  "issue edit"|"issue comment") cred "$@"; echo "$*" >> "$FAKE_DIR/writes.log" ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 1 ;;
esac
"""

FAKE_LIST_GH = r"""#!/usr/bin/env bash
case "$1 $2" in
  "api repos/o/r/issues/"*"/parent") exit 1 ;;
  "api repos/o/r/issues/"*"/dependencies/blocking") jq -r "$4" "$FAKE_DIR/dependents.json" ;;
  "api repos/o/r/issues/"*) jq --arg n "${2##*/}" '.[$n]' "$FAKE_DIR/issues.json" ;;
  "issue edit") echo "$*" >> "$FAKE_DIR/writes.log" ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 1 ;;
esac
"""


def _y(expr):
    return subprocess.run(["yq", expr, WF], check=True, capture_output=True, text=True).stdout


def _yj(expr):
    return json.loads(subprocess.run(["yq", "-o=json", expr, WF], check=True,
                                     capture_output=True, text=True).stdout)


def issue(number, hours_idle=7, ended=1, labels=("handoff-ended",), refired=0, infra=0):
    t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=hours_idle)
    comments = [{"body": f"{INFRA}{number}{i}", "authorAssociation": "OWNER", "author": {"login": "nish3451"}}
                for i in range(infra)]
    comments += [{"body": f"{ENDED}{number}{i}", "authorAssociation": "OWNER", "author": {"login": "nish3451"}}
                for i in range(ended)]
    comments += [{"body": f"{REFIRED}{number}{i}", "authorAssociation": "NONE", "author": {"login": "github-actions"}}
                 for i in range(refired)]
    return {
        "number": number, "updatedAt": t.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "labels": [{"name": n} for n in labels], "comments": comments,
    }


def job(name, status="in_progress"):
    return {"name": name, "status": status}


def run(tmp_path, issues, queued=0, prs=(), fail=None, out=False, other_jobs=(), login=True):
    """Every live run is titled differently (sweep, stub); only its job names say orchestrate. login
    models the runner's own ~/.config/gh, which every hosted runner lacks."""
    (tmp_path / "issues.json").write_text(json.dumps(issues))
    jobs = {str(i): {"jobs": [job("orchestrate" if i % 2 else "stub / orchestrate")]} for i in range(queued)}
    for i, j in enumerate(other_jobs):
        jobs[str(100 + i)] = {"jobs": [j]}
    (tmp_path / "runs.json").write_text(json.dumps({"workflow_runs": [{"id": int(k)} for k in jobs]}))
    (tmp_path / "jobs.json").write_text(json.dumps(jobs))
    (tmp_path / "prs.json").write_text(json.dumps(list(prs)))
    if login:
        (tmp_path / "login").touch()
    gh = tmp_path / "gh"
    gh.write_text(FAKE_GH)
    gh.chmod(0o755)
    env = {**os.environ, "PATH": f"{tmp_path}:{os.environ['PATH']}", "FAKE_DIR": str(tmp_path),
           "GITHUB_REPOSITORY": "o/r", "GH_TOKEN": "x",
           "WORKFLOW_REF": "o/r/.github/workflows/stub.yml@refs/heads/main", "GITHUB_SERVER_URL": "https://example.invalid", "GITHUB_RUN_ID": "7", **(fail or {}), "REQUEUE": _y(f"{STEP} | .env.REQUEUE")}
    r = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", _y(f"{STEP} | .run")],
                       env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    if out:
        return r.stdout
    log = tmp_path / "writes.log"
    return log.read_text().splitlines() if log.exists() else []


def edits(lines, label):
    return sorted(int(l.split()[2]) for l in lines if l.startswith("issue edit") and label in l)


def test_a_priority_now_issue_still_waits_when_it_needs_nish(tmp_path):
    labelled = ("needs-orchestrator", "needs-nish-decision", "priority-now")
    w = run(tmp_path, [issue(1, hours_idle=7, labels=labelled)])
    assert w == []


def released(tmp_path, numbers):
    """The list step on a closed blocker's path, over the open issues it released."""
    issues = {str(n): {"number": n, "state": "open", "labels": [{"name": "needs-orchestrator"}],
                       "issue_dependencies_summary": {"blocked_by": 0}} for n in numbers}
    (tmp_path / "issues.json").write_text(json.dumps(issues))
    (tmp_path / "dependents.json").write_text(json.dumps([{"number": n, "state": "open"} for n in numbers]))
    gh = tmp_path / "gh"
    gh.write_text(FAKE_LIST_GH)
    gh.chmod(0o755)
    out = tmp_path / "out"
    out.write_text("")
    env = {**os.environ, "PATH": f"{tmp_path}:{os.environ['PATH']}", "FAKE_DIR": str(tmp_path),
           "GITHUB_REPOSITORY": "o/r", "GH_TOKEN": "x", "GITHUB_OUTPUT": str(out),
           "CLOSED": "1", "ISSUE": "",
           "CHECK_DEFS": _y(f"{LIST} | .env.CHECK_DEFS"), "RED_REWORK": _y(f"{LIST} | .env.RED_REWORK")}
    r = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", _y(f"{LIST} | .run")],
                       env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    log = tmp_path / "writes.log"
    return log.read_text().splitlines() if log.exists() else []


def test_a_marker_from_another_author_is_not_counted(tmp_path):
    i = issue(1, ended=0, labels=("needs-orchestrator",), refired=3)
    for c in i["comments"]:
        c["author"] = {"login": "someone"}
    w = run(tmp_path, [i])
    assert edits(w, "--add-label needs-nish-decision") == []


def test_open_pr_blocks_requeue_of_a_tried_issue(tmp_path):
    w = run(tmp_path, [issue(1), issue(2, ended=3)], prs=["orch/issue-1", "orch/issue-2"])
    assert w == []


def test_escalated_and_queued_issues_are_left_alone(tmp_path):
    w = run(tmp_path, [issue(1, ended=3, labels=("handoff-ended", "needs-nish-decision")),
                       issue(2, labels=("handoff-ended", "needs-orchestrator"))])
    assert w == []


def test_an_agent_blocked_handoff_is_left_alone(tmp_path):
    """agent-blocked is a live block, not an ended hand-off: an old end marker is neither a re-queue nor a strike."""
    w = run(tmp_path, [issue(1, ended=3, labels=("handoff-ended", "agent-blocked"))])
    assert w == []

