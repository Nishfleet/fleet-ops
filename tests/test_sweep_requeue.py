"""Parked hand-offs in agent-dispatch.yml's list job (fleet-ops#10420): the step's real
`run:` block and REQUEUE program (read out with yq) against a fake gh.

An orchestrator-tried issue idle over 6 h goes back to needs-orchestrator, at most 3 a
sweep and none while 3 already wait; after 3 ended hand-offs it gets needs-nish-decision.
"""
import datetime
import json
import os
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
WF = str(ROOT / ".github/workflows/agent-dispatch.yml")
STEP = ".jobs.list.steps[] | select(.env.REQUEUE)"
ENDED = "orchestrator hand-off ended without a PR: https://example.invalid/runs/"

FAKE_GH = r"""#!/usr/bin/env bash
case "$1 $2" in
  "issue list")
    case "$*" in *needs-orchestrator*) cat "$FAKE_DIR/queued" ;; *) cat "$FAKE_DIR/tried.json" ;; esac ;;
  "issue edit"|"issue comment") echo "$*" >> "$FAKE_DIR/writes.log" ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 1 ;;
esac
"""


def _y(expr):
    return subprocess.run(["yq", expr, WF], check=True, capture_output=True, text=True).stdout


def issue(number, hours_idle=7, ended=1, labels=("orchestrator-tried",)):
    t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=hours_idle)
    return {
        "number": number, "updatedAt": t.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "labels": [{"name": n} for n in labels],
        "comments": [{"body": f"{ENDED}{number}{i}"} for i in range(ended)],
    }


def run(tmp_path, issues, queued=0):
    (tmp_path / "tried.json").write_text(json.dumps(issues))
    (tmp_path / "queued").write_text(str(queued))
    gh = tmp_path / "gh"
    gh.write_text(FAKE_GH)
    gh.chmod(0o755)
    env = {**os.environ, "PATH": f"{tmp_path}:{os.environ['PATH']}", "FAKE_DIR": str(tmp_path),
           "GITHUB_REPOSITORY": "o/r", "GH_TOKEN": "x", "REQUEUE": _y(f"{STEP} | .env.REQUEUE")}
    r = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", _y(f"{STEP} | .run")],
                       env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    log = tmp_path / "writes.log"
    return log.read_text().splitlines() if log.exists() else []


def edits(lines, label):
    return sorted(int(l.split()[2]) for l in lines if l.startswith("issue edit") and label in l)


def test_idle_six_hours_requeues_and_fresh_waits(tmp_path):
    w = run(tmp_path, [issue(1, 7), issue(2, 5)])
    assert edits(w, "--add-label needs-orchestrator") == [1]


def test_batch_is_three(tmp_path):
    w = run(tmp_path, [issue(n) for n in range(1, 8)])
    assert len(edits(w, "--add-label needs-orchestrator")) == 3


def test_queued_items_use_up_the_batch(tmp_path):
    w = run(tmp_path, [issue(n) for n in range(1, 5)], queued=2)
    assert len(edits(w, "--add-label needs-orchestrator")) == 1


def test_three_tries_escalate_not_requeue(tmp_path):
    w = run(tmp_path, [issue(1, ended=3), issue(2, ended=2)])
    assert edits(w, "--add-label needs-nish-decision") == [1]
    assert edits(w, "--add-label needs-orchestrator") == [2]
    assert any(l.startswith("issue comment 1 ") and "runs/10" in l and "runs/12" in l for l in w)


def test_escalated_and_queued_issues_are_left_alone(tmp_path):
    w = run(tmp_path, [issue(1, ended=3, labels=("orchestrator-tried", "needs-nish-decision")),
                       issue(2, labels=("orchestrator-tried", "needs-orchestrator"))])
    assert w == []


def test_full_queue_requeues_nothing_but_still_escalates(tmp_path):
    w = run(tmp_path, [issue(1), issue(2, ended=3)], queued=3)
    assert edits(w, "--add-label needs-orchestrator") == []
    assert edits(w, "--add-label needs-nish-decision") == [2]
