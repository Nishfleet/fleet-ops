"""A ready lane that says what it is (fleet-ops#11143): the real `run:` blocks of the
agent.yml Gate and the agent-dispatch.yml list step against a fake gh.

An issue labeled agent-ready that issue dependencies still block is admitted by
nothing, so it kept its label for weeks while every read said blocked. The Gate
renames it to agent-blocked when a dispatch hits that state, and the sweep does the
rename for the ready items no dispatch reaches. When a blocker closes, the sweep
renames the released agent-blocked slice back to agent-ready, so the label event
starts it. At most 12 issues per sweep move in either direction.
"""
import json
import os
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
DISPATCH = str(ROOT / ".github/workflows/agent-dispatch.yml")
AGENT = str(ROOT / ".github/workflows/agent.yml")
LIST_STEP = '.jobs.list.steps[] | select(.id == "list") | .run'
GATE_STEP = '.jobs.work.steps[] | select(.id == "gate") | .run'

FAKE_LIST_GH = r"""#!/usr/bin/env bash
case "$1 $2" in
  "issue list") case "$*" in
                  *"-l agent-in-progress"*) echo '[]' ;;
                  *"-l agent-ready"*) jq -r '.[] | .number' "$FAKE_DIR/ready.json" ;;
                  *) echo 2>/dev/null; jq -r "${@: -1}" <<< '[]' ;;
                esac ;;
  "pr list") echo '[]' ;;
  "api graphql"*) exit 1 ;;
  "issue edit") echo "$*" >> "$FAKE_DIR/writes.log" ;;
  "api repos/o/r/issues/"*"/parent") exit 1 ;;
  "api repos/o/r/issues/"*"/dependencies/blocking") jq -r "$4" "$FAKE_DIR/dependents.json" ;;
  "api repos/o/r/issues/"*) jq --arg n "${2##*/}" '.[$n]' "$FAKE_DIR/issues.json" ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 1 ;;
esac
"""

FAKE_GATE_GH = r"""#!/usr/bin/env bash
case "$1 $2" in
  "issue edit") echo "$*" >> "$FAKE_DIR/writes.log" ;;
  "api repos/o/r/issues/"*) jq -c . "$FAKE_DIR/issue.json" ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 1 ;;
esac
"""


def _y(expr, wf):
    return subprocess.run(["yq", expr, wf], check=True, capture_output=True, text=True).stdout


def _fake(tmp_path, gh):
    path = tmp_path / "gh"
    path.write_text(gh)
    path.chmod(0o755)
    return {**os.environ, "PATH": f"{tmp_path}:{os.environ['PATH']}", "FAKE_DIR": str(tmp_path)}


def issue_json(number, blocked_by, labels, state="open"):
    return dict(number=number, state=state,
                labels=[dict(name=n) for n in labels],
                issue_dependencies_summary=dict(blocked_by=blocked_by))


def sweep(tmp_path, numbers, labels, blocked_by, closed=""):
    """The list step's real program over ready issues. closed="1" is the closed-blocker path."""
    issues = dict((str(n), issue_json(n, blocked_by, labels)) for n in numbers)
    (tmp_path / "issues.json").write_text(json.dumps(issues))
    ready = [] if closed else [dict(number=n) for n in numbers]
    (tmp_path / "ready.json").write_text(json.dumps(ready))
    (tmp_path / "dependents.json").write_text(json.dumps([dict(number=n, state="open") for n in numbers]))
    out = tmp_path / "out"
    out.write_text("")
    env = {**_fake(tmp_path, FAKE_LIST_GH), "GITHUB_REPOSITORY": "o/r", "GH_TOKEN": "x",
           "GITHUB_OUTPUT": str(out), "CLOSED": closed, "ISSUE": "",
           "CHECK_DEFS": _y('.jobs.list.steps[] | select(.env.CHECK_DEFS) | .env.CHECK_DEFS', DISPATCH),
           "RED_REWORK": _y('.jobs.list.steps[] | select(.env.RED_REWORK) | .env.RED_REWORK', DISPATCH)}
    r = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", _y(LIST_STEP, DISPATCH)],
                       env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    log = tmp_path / "writes.log"
    return log.read_text().splitlines() if log.exists() else []


def edits(lines, flag, label):
    return sorted(int(l.split()[2]) for l in lines
                  if l.startswith("issue edit") and f"--{flag}-label {label}" in l)


def gate(tmp_path, blocked_by, labels):
    (tmp_path / "issue.json").write_text(json.dumps(issue_json(5, blocked_by, labels)))
    out = tmp_path / "out"
    out.write_text("")
    env = {**_fake(tmp_path, FAKE_GATE_GH), "REPO": "o/r", "GH_TOKEN": "x",
           "GITHUB_OUTPUT": str(out), "REF": "claim/issue-5"}
    r = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", _y(GATE_STEP, AGENT)],
                       env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    writes = tmp_path / "writes.log"
    return (writes.read_text().splitlines() if writes.exists() else []), out.read_text(), r.stdout


def test_a_blocked_ready_issue_renames_to_agent_blocked(tmp_path):
    w = sweep(tmp_path, [1, 2], ["agent-ready"], blocked_by=2)
    assert edits(w, "remove", "agent-ready") == [1, 2]
    assert edits(w, "add", "agent-blocked") == [1, 2]


def test_an_unblocked_ready_issue_keeps_its_label(tmp_path):
    w = sweep(tmp_path, [1], ["agent-ready"], blocked_by=0)
    assert w == []


def test_a_parked_issue_keeps_its_park_label(tmp_path):
    w = sweep(tmp_path, [1], ["needs-nish-decision"], blocked_by=1)
    assert w == []


def test_the_rename_batch_is_twelve(tmp_path):
    w = sweep(tmp_path, range(2, 32), ["agent-ready"], blocked_by=1)
    assert edits(w, "remove", "agent-ready") == list(range(2, 14))
    assert edits(w, "add", "agent-blocked") == list(range(2, 14))


def test_a_closed_blocker_relabels_its_blocked_slice_back_to_ready(tmp_path):
    w = sweep(tmp_path, [2, 3, 4], ["agent-blocked"], blocked_by=0, closed="1")
    assert edits(w, "remove", "agent-blocked") == [2, 3, 4]
    assert edits(w, "add", "agent-ready") == [2, 3, 4]


def test_a_closed_blocker_relabels_at_most_twelve(tmp_path):
    w = sweep(tmp_path, range(2, 32), ["agent-blocked"], blocked_by=0, closed="1")
    assert edits(w, "remove", "agent-blocked") == list(range(2, 14))
    assert edits(w, "add", "agent-ready") == list(range(2, 14))


def test_a_closed_blocker_leaves_an_already_ready_dependent_alone(tmp_path):
    w = sweep(tmp_path, [2], ["agent-ready"], blocked_by=0, closed="1")
    assert w == []


def test_the_gate_renames_a_blocked_ready_issue_and_skips(tmp_path):
    w, out, log = gate(tmp_path, blocked_by=2, labels=["agent-ready"])
    assert edits(w, "remove", "agent-ready") == [5]
    assert edits(w, "add", "agent-blocked") == [5]
    assert "skip (blocked)" in log and "go=true" not in out


def test_the_gate_leaves_a_parked_blocked_issue_alone(tmp_path):
    w, out, log = gate(tmp_path, blocked_by=2, labels=["agent-failed"])
    assert w == []
    assert "skip (blocked)" in log


def test_the_gate_leaves_an_already_blocked_ready_issue_alone(tmp_path):
    w, out, log = gate(tmp_path, blocked_by=2, labels=["agent-ready", "agent-blocked"])
    assert w == []
    assert "skip (blocked)" in log
