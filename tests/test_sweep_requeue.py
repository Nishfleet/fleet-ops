"""Parked hand-offs in agent-dispatch.yml's list job (fleet-ops#10420): the step's real
`run:` block and REQUEUE program (read out with yq) against a fake gh.

An orchestrator-tried issue idle over 6 h goes back to needs-orchestrator, and a labelled idle
one with no orch/issue-N PR is re-fired (label removed, added again), at most 5 - live
orchestrate runs a sweep (fleet-ops#10475); after 3 ended hand-offs it gets needs-nish-decision.
"""
import datetime
import json
import os
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
WF = str(ROOT / ".github/workflows/agent-dispatch.yml")
STEP = ".jobs.list.steps[] | select(.env.REQUEUE)"
ENDED = "orchestrator hand-off ended without a PR: https://example.invalid/runs/"

FAKE_GH = r"""#!/usr/bin/env bash
case "$1 $2" in
  "issue list") cat "$FAKE_DIR/issues.json" ;;
  "pr list") cat "$FAKE_DIR/prs.json" ;;
  "api repos/o/r/actions/workflows/agent-dispatch.yml/runs?status=queued&per_page=100") cat "$FAKE_DIR/runs" ;;
  "api repos/o/r/actions/workflows/agent-dispatch.yml/runs?status=in_progress&per_page=100") ;;
  "api repos/o/r/actions/runs/"*) echo 1 ;;
  "issue edit"|"issue comment") echo "$*" >> "$FAKE_DIR/writes.log" ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 1 ;;
esac
"""


def _y(expr):
    return subprocess.run(["yq", expr, WF], check=True, capture_output=True, text=True).stdout


def _yj(expr):
    return json.loads(subprocess.run(["yq", "-o=json", expr, WF], check=True,
                                     capture_output=True, text=True).stdout)


def issue(number, hours_idle=7, ended=1, labels=("orchestrator-tried",)):
    t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=hours_idle)
    return {
        "number": number, "updatedAt": t.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "labels": [{"name": n} for n in labels],
        "comments": [{"body": f"{ENDED}{number}{i}", "authorAssociation": "OWNER"} for i in range(ended)],
    }


def run(tmp_path, issues, queued=0, prs=(), api_ok=True):
    """queued = live orchestrate runs; prs = open PR head branches."""
    (tmp_path / "issues.json").write_text(json.dumps(issues))
    (tmp_path / "runs").write_text("".join(f"{100 + i}\n" for i in range(queued)))
    (tmp_path / "prs.json").write_text(json.dumps(list(prs)))
    gh = tmp_path / "gh"
    gh.write_text(FAKE_GH if api_ok else FAKE_GH.replace('cat "$FAKE_DIR/runs" ;;', "exit 1 ;;"))
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


def test_batch_is_five(tmp_path):
    w = run(tmp_path, [issue(n) for n in range(1, 8)])
    assert len(edits(w, "--add-label needs-orchestrator")) == 5


def test_live_runs_use_up_the_batch(tmp_path):
    w = run(tmp_path, [issue(n) for n in range(1, 5)], queued=3)
    assert len(edits(w, "--add-label needs-orchestrator")) == 2


def test_labelled_issues_are_not_queued_runs(tmp_path):
    """22 issues already labelled (fleet-ops#10475) must not eat the batch."""
    labelled = [issue(n, ended=0, labels=("needs-orchestrator",), hours_idle=2) for n in range(10, 32)]
    w = run(tmp_path, labelled + [issue(1), issue(2)])
    assert edits(w, "--add-label needs-orchestrator") == [1, 2]


def test_labelled_idle_issue_is_refired(tmp_path):
    w = run(tmp_path, [issue(1, ended=0, labels=("needs-orchestrator",)),
                       issue(2, ended=0, labels=("needs-orchestrator",), hours_idle=5),
                       issue(3, ended=0, labels=("needs-orchestrator",)),
                       issue(4, ended=0, labels=("needs-orchestrator", "needs-nish-decision"))],
              prs=["orch/issue-3"])
    assert edits(w, "--remove-label needs-orchestrator") == [1]
    assert edits(w, "--add-label needs-orchestrator") == [1]
    assert [l.split()[2] for l in w if l.startswith("issue edit")] == ["1", "1"]
    assert "--remove-label" in w[0]


def test_open_pr_blocks_requeue_of_a_tried_issue(tmp_path):
    w = run(tmp_path, [issue(1), issue(2, ended=3)], prs=["orch/issue-1", "orch/issue-2"])
    assert w == []


def test_api_error_requeues_nothing(tmp_path):
    w = run(tmp_path, [issue(1), issue(2, ended=3)], api_ok=False)
    assert edits(w, "--add-label needs-orchestrator") == []


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
    w = run(tmp_path, [issue(1), issue(2, ended=3)], queued=5)
    assert edits(w, "--add-label needs-orchestrator") == []
    assert edits(w, "--add-label needs-nish-decision") == [2]


def test_requeue_counts_the_prefix_the_orchestrate_job_posts():
    """REQUEUE's counter and the comment that feeds it are one string shared by two jobs:
    editing either alone leaves every ended hand-off uncounted, so the issue loops."""
    counted = re.search(r'startswith\("([^"]+)"\)', _y(f"{STEP} | .env.REQUEUE"))
    assert counted, "REQUEUE no longer counts ended hand-offs with a startswith() prefix"
    prefix = counted.group(1)
    posted = [m for line in _y(".jobs.orchestrate.steps[] | select(.run) | .run").splitlines()
              for m in re.findall(r'--body "([^"]*)"', line) if "gh issue comment" in line]
    assert prefix in [body.split("$")[0] for body in posted], (prefix, posted)


def test_requeue_step_runs_only_on_the_sweep_events():
    """pull_request_target and workflow_run reach this workflow too, so a gate phrased as
    "not issues" would run the sweep's writes for them; only the two sweep triggers may."""
    expr = _y(f"{STEP} | .if")
    allowed = set(re.findall(r"github\.event_name\s*==\s*['\"]([a-z_]+)['\"]", expr))
    rest = re.sub(r"github\.event_name\s*==\s*['\"][a-z_]+['\"]", "", expr)
    assert re.sub(r"[\s()|]", "", rest) == "", expr
    assert allowed == {"schedule", "workflow_dispatch"}, expr
    assert allowed <= set(_yj(".on | keys")), expr


def test_a_stranger_cannot_escalate_an_issue(tmp_path):
    i = issue(1, ended=3)
    for c in i["comments"]:
        c["authorAssociation"] = "NONE"
    w = run(tmp_path, [i])
    assert edits(w, "--add-label needs-nish-decision") == []
    assert edits(w, "--add-label needs-orchestrator") == [1]
