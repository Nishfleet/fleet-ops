"""GitHub "blocked by" in the coordinator path (fleet-ops#10489): the real `run:` blocks of
agent-dispatch.yml against a fake gh.

The orchestrate issue step skips a blocked issue. When an issue closes, the list job collects each
unblocked needs-orchestrator dependent and the parked job re-labels it (remove, then add) on the
worker App token, because the list job runs hosted, where no login exists (fleet-ops#10963).
"""
import json
import os
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
WF = str(ROOT / ".github/workflows/agent-dispatch.yml")
ISSUE_STEP = '.jobs.orchestrate.steps[] | select(.id == "issue")'
LIST_STEP = '.jobs.list.steps[] | select(.id == "list")'
PARKED_STEP = '.jobs.parked.steps[] | select(.env.PARKED)'

FAKE_GH = r"""#!/usr/bin/env bash
q=.; for ((i = 1; i <= $#; i++)); do [ "${!i}" = --jq ] && { j=$((i + 1)); q=${!j}; }; done
case "$*" in
  "issue edit"*) echo "$*|token=${GH_TOKEN:-none}" >> "$FAKE_DIR/writes.log" ;;
  "issue view"*) jq -r "$q" "$FAKE_DIR/issue.json" ;;
  *"/dependencies/blocking"*) jq -r "$q" "$FAKE_DIR/blocking.json" ;;
  *"/parent"*) exit 1 ;;
  *git/ref/heads/*) exit 1 ;;
  "issue comment"*) ;;
  *issues/comments*) echo '[]' | jq -c "$q" ;;
  "api repos/o/r/issues/"*) n=${2##*/}; jq -r "$q" "$FAKE_DIR/issue-$n.json" 2>/dev/null || jq -r "$q" "$FAKE_DIR/issue.json" ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 99 ;;
esac
"""


def _y(expr):
    return subprocess.run(["yq", expr, WF], check=True, capture_output=True, text=True).stdout


def _fake(tmp_path):
    gh = tmp_path / "gh"
    gh.write_text(FAKE_GH)
    gh.chmod(0o755)
    return {**os.environ, "PATH": f"{tmp_path}:{os.environ['PATH']}", "FAKE_DIR": str(tmp_path)}


def orchestrate(tmp_path, blocked_by):
    (tmp_path / "issue.json").write_text(json.dumps({
        "state": "OPEN", "labels": [{"name": "needs-orchestrator"}],
        "issue_dependencies_summary": {"blocked_by": blocked_by}}))
    (tmp_path / "out").write_text("")
    env = {**_fake(tmp_path), "REPO": "o/r", "ISSUE": "5", "GH_TOKEN": "x", "GITHUB_SERVER_URL": "https://github.com",
           "GITHUB_RUN_ID": "1", "GITHUB_OUTPUT": str(tmp_path / "out"), "DAILY_MAX": "5"}
    r = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", _y(f"{ISSUE_STEP} | .run")],
                       env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    return r.stdout, (tmp_path / "out").read_text()


def test_blocked_issue_is_skipped_and_says_so(tmp_path):
    log, out = orchestrate(tmp_path, blocked_by=1)
    assert "blocked" in log and "go=true" not in out


def test_unblocked_issue_still_goes(tmp_path):
    _, out = orchestrate(tmp_path, blocked_by=0)
    assert "go=true" in out


def close(tmp_path, dependents):
    """Run the list step for a closed issue 1 that blocks `dependents` ({n: (labels, blocked_by)})."""
    (tmp_path / "blocking.json").write_text(json.dumps([{"number": n, "state": "open"} for n in dependents]))
    for n, (labels, blocked_by) in dependents.items():
        (tmp_path / f"issue-{n}.json").write_text(json.dumps({
            "number": n, "state": "open", "created_at": "2026-10-27T00:00:00Z",
            "labels": [{"name": l} for l in labels],
            "issue_dependencies_summary": {"blocked_by": blocked_by}}))
    (tmp_path / "out").write_text("")
    env = {**_fake(tmp_path), "GITHUB_REPOSITORY": "o/r", "GH_TOKEN": "x", "CLOSED": "1", "ISSUE": "",
           "GITHUB_OUTPUT": str(tmp_path / "out"), "CHECK_DEFS": "", "RUN_LIVE_JQ": ""}
    r = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", _y(f"{LIST_STEP} | .run")],
                       env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    out = (tmp_path / "out").read_text()
    log = tmp_path / "writes.log"
    return (log.read_text().splitlines() if log.exists() else []), out


def release(tmp_path, out):
    """The parked job's write step, for the released numbers the list step published."""
    released = dict(l.split("=", 1) for l in out.splitlines() if "=" in l)["released"]
    (tmp_path / "writes.log").write_text("")
    env = {**_fake(tmp_path), "GH_TOKEN": "app", "PARKED": "[]", "RELEASED": released, "REPO": "o/r",
           "RUN_URL": "https://example.invalid/runs/1"}
    r = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", _y(f"{PARKED_STEP} | .run")],
                       env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    log = tmp_path / "writes.log"
    return log.read_text().splitlines() if log.exists() else []


def test_closing_a_blocker_refires_the_unblocked_dependent(tmp_path):
    w, out = close(tmp_path, {2: (["needs-orchestrator"], 0)})
    assert w == [], "the list job runs hosted, where no login exists, so it cannot write it itself"
    assert 'released=["2"]' in out, out
    w = release(tmp_path, out)
    assert [l.split("|")[0] for l in w] == [
        "issue edit 2 -R o/r --remove-label needs-orchestrator",
        "issue edit 2 -R o/r --add-label needs-orchestrator"]
    assert all(l.endswith("token=app") for l in w), "the re-fire must run on the App token, whose label event starts a workflow"


def test_still_blocked_or_unparked_dependents_are_left_alone(tmp_path):
    w, out = close(tmp_path, {2: (["needs-orchestrator"], 1), 3: (["agent-ready"], 0)})
    assert w == []
    assert 'released=[]' in out, out
    assert release(tmp_path, out) == []
