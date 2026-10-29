"""Parked hand-offs in agent-dispatch.yml's list job (fleet-ops#10420, #10475, #10455): the step's real
`run:` block and REQUEUE program (read out with yq) against a fake gh.

An agent-blocked issue idle over 6 h goes back to needs-orchestrator, at most 5 a sweep and none while
5 live orchestrate jobs run. A needs-orchestrator issue with no orch/issue-N PR is re-fired by a
task=orchestrate dispatch of the calling workflow file, with a marker comment and no label write.
Three ended or re-fired hand-offs give needs-nish-decision.
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
REFIRED = "orchestrator re-fired by the sweep: https://example.invalid/runs/"
ENDED = "orchestrator hand-off ended without a PR: https://example.invalid/runs/"

FAKE_GH = r"""#!/usr/bin/env bash
case "$1 $2" in
  "issue list") cat "$FAKE_DIR/issues.json" ;;
  "pr list") [ -z "$FAIL_PRS" ] || exit 1; cat "$FAKE_DIR/prs.json" ;;
  "api repos/o/r/actions/workflows/stub.yml/runs?status=in_progress&per_page=100")
    [ -z "$FAIL_RUNS" ] || exit 1
    jq -r "$4" "$FAKE_DIR/runs.json" ;;
  "api repos/o/r/actions/runs/"*)
    [ -z "$FAIL_JOBS" ] || exit 1
    id=${2#repos/o/r/actions/runs/}; id=${id%/jobs}
    jq --arg id "$id" '.[$id]' "$FAKE_DIR/jobs.json" | jq -r "$4" ;;
  "workflow run") [ -z "$FAIL_DISPATCH" ] || exit 1; echo "$*" >> "$FAKE_DIR/writes.log" ;;
  "issue edit"|"issue comment") echo "$*" >> "$FAKE_DIR/writes.log" ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 1 ;;
esac
"""


def _y(expr):
    return subprocess.run(["yq", expr, WF], check=True, capture_output=True, text=True).stdout


def _yj(expr):
    return json.loads(subprocess.run(["yq", "-o=json", expr, WF], check=True,
                                     capture_output=True, text=True).stdout)


def issue(number, hours_idle=7, ended=1, labels=("agent-blocked",), refired=0):
    t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=hours_idle)
    comments = [{"body": f"{ENDED}{number}{i}", "authorAssociation": "OWNER", "author": {"login": "nish3451"}}
                for i in range(ended)]
    comments += [{"body": f"{REFIRED}{number}{i}", "authorAssociation": "NONE", "author": {"login": "github-actions"}}
                 for i in range(refired)]
    return {
        "number": number, "updatedAt": t.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "labels": [{"name": n} for n in labels], "comments": comments,
    }


def job(name, status="in_progress"):
    return {"name": name, "status": status}


def run(tmp_path, issues, queued=0, prs=(), fail=None, out=False, other_jobs=()):
    """Every live run is titled differently (sweep, stub); only its job names say orchestrate."""
    (tmp_path / "issues.json").write_text(json.dumps(issues))
    jobs = {str(i): {"jobs": [job("orchestrate" if i % 2 else "stub / orchestrate")]} for i in range(queued)}
    for i, j in enumerate(other_jobs):
        jobs[str(100 + i)] = {"jobs": [j]}
    (tmp_path / "runs.json").write_text(json.dumps({"workflow_runs": [{"id": int(k)} for k in jobs]}))
    (tmp_path / "jobs.json").write_text(json.dumps(jobs))
    (tmp_path / "prs.json").write_text(json.dumps(list(prs)))
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


def test_idle_six_hours_requeues_and_fresh_waits(tmp_path):
    w = run(tmp_path, [issue(1, 7), issue(2, 5)])
    assert edits(w, "--add-label needs-orchestrator") == [1]


def test_batch_is_five(tmp_path):
    w = run(tmp_path, [issue(n) for n in range(1, 8)])
    assert len(edits(w, "--add-label needs-orchestrator")) == 5


def test_live_runs_use_up_the_batch(tmp_path):
    """Live orchestrate jobs count, whatever the run is titled, plain or behind a stub; other jobs and
    finished orchestrate jobs do not (fleet-ops#10475)."""
    noise = [job("list") for _ in range(8)] + [job("orchestrate", "completed")]
    w = run(tmp_path, [issue(n) for n in range(1, 5)], queued=3, other_jobs=noise)
    assert len(edits(w, "--add-label needs-orchestrator")) == 2


def test_labelled_issues_are_not_queued_runs(tmp_path):
    """22 issues already labelled (fleet-ops#10475) must not eat the batch."""
    labelled = [issue(n, ended=0, labels=("needs-orchestrator",), hours_idle=2) for n in range(10, 32)]
    w = run(tmp_path, labelled + [issue(1), issue(2)])
    assert edits(w, "--add-label needs-orchestrator") == [1, 2]


def test_labelled_idle_issue_is_dispatched_not_relabelled(tmp_path):
    labelled = ("needs-orchestrator",)
    w = run(tmp_path, [issue(1, ended=0, labels=labelled),
                       issue(2, ended=0, labels=labelled, hours_idle=5),
                       issue(3, ended=0, labels=labelled),
                       issue(4, ended=0, labels=labelled + ("needs-nish-decision",))],
            prs=["orch/issue-3"])
    assert [l for l in w if l.startswith("workflow run")] == ["workflow run stub.yml -R o/r -f task=orchestrate -f issue=1"]
    assert not [l for l in w if l.startswith("issue edit")], "a dispatch needs no label write"
    marker = REFIRED.split("https")[0]
    assert [l for l in w if l.startswith("issue comment 1 ") and marker in l]
    assert marker in _y(f"{STEP} | .env.REQUEUE"), "the counter and the posted marker must share one prefix"


def test_failed_dispatch_fails_loud_and_counts_a_strike(tmp_path):
    """A stub without the task and issue inputs refuses every dispatch: the marker still posts, so
    the third sweep escalates instead of retrying forever."""
    i = [issue(1, ended=0, labels=("needs-orchestrator",))]
    out = run(tmp_path, i, fail={"FAIL_DISPATCH": "1"}, out=True)
    assert "::error::#1: re-fire refused" in out
    w = (tmp_path / "writes.log").read_text().splitlines()
    assert [l for l in w if l.startswith("issue comment 1 ") and REFIRED.split("https")[0] in l]
    assert not [l for l in w if l.startswith("issue edit")]


def test_refires_count_toward_the_three_strikes(tmp_path):
    """A re-fired run that dies with its runner posts no ended comment, so the sweep's own marker counts."""
    labelled = ("needs-orchestrator",)
    w = run(tmp_path, [issue(1, ended=0, labels=labelled, refired=3), issue(2, ended=1, labels=labelled, refired=1)])
    assert edits(w, "--add-label needs-nish-decision") == [1]
    assert [l for l in w if l.startswith("workflow run")] == ["workflow run stub.yml -R o/r -f task=orchestrate -f issue=2"]


@pytest.mark.parametrize("login", ["github-actions", "github-actions[bot]"])
def test_actions_token_marker_counts_under_graphql_and_rest_login(tmp_path, login):
    """gh issue list (GraphQL) names the Actions token github-actions, the REST API github-actions[bot]."""
    i = issue(1, ended=0, labels=("needs-orchestrator",), refired=3)
    for c in i["comments"]:
        c["author"] = {"login": login}
    w = run(tmp_path, [i])
    assert edits(w, "--add-label needs-nish-decision") == [1]


def test_a_marker_from_another_author_is_not_counted(tmp_path):
    i = issue(1, ended=0, labels=("needs-orchestrator",), refired=3)
    for c in i["comments"]:
        c["author"] = {"login": "someone"}
    w = run(tmp_path, [i])
    assert edits(w, "--add-label needs-nish-decision") == []


def test_open_pr_blocks_requeue_of_a_tried_issue(tmp_path):
    w = run(tmp_path, [issue(1), issue(2, ended=3)], prs=["orch/issue-1", "orch/issue-2"])
    assert w == []


@pytest.mark.parametrize("fail", ["FAIL_RUNS", "FAIL_JOBS", "FAIL_PRS"])
def test_partial_api_error_requeues_nothing_but_escalates(tmp_path, fail):
    w = run(tmp_path, [issue(1), issue(2, ended=3)], queued=2, fail={fail: "1"})
    assert edits(w, "--add-label needs-orchestrator") == []
    assert edits(w, "--add-label needs-nish-decision") == [2]


def test_three_tries_escalate_not_requeue(tmp_path):
    w = run(tmp_path, [issue(1, ended=3), issue(2, ended=2)])
    assert edits(w, "--add-label needs-nish-decision") == [1]
    assert edits(w, "--add-label needs-orchestrator") == [2]
    assert any(l.startswith("issue comment 1 ") and "runs/10" in l and "runs/12" in l for l in w)


def test_escalated_and_queued_issues_are_left_alone(tmp_path):
    w = run(tmp_path, [issue(1, ended=3, labels=("agent-blocked", "needs-nish-decision")),
                       issue(2, labels=("agent-blocked", "needs-orchestrator"))])
    assert w == []


def test_full_queue_requeues_nothing_but_still_escalates(tmp_path):
    w = run(tmp_path, [issue(1), issue(2, ended=3)], queued=5)
    assert edits(w, "--add-label needs-orchestrator") == []
    assert edits(w, "--add-label needs-nish-decision") == [2]


def test_blocked_issue_with_no_ended_hand_off_is_not_requeued(tmp_path):
    w = run(tmp_path, [issue(1, ended=0), issue(2, ended=1)])
    assert edits(w, "--add-label needs-orchestrator") == [2]


def test_worker_block_after_an_ended_hand_off_is_left_alone(tmp_path):
    i = issue(1, ended=1)
    i["comments"].append({"body": "blocked-on: senior-conference", "authorAssociation": "NONE"})
    assert run(tmp_path, [i]) == []


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


def test_list_job_asks_no_more_than_the_caller_stubs_grant():
    got = subprocess.run(["yq", ".jobs.list.permissions.actions", WF], capture_output=True, text=True, check=True).stdout.strip()
    assert got == "read"
