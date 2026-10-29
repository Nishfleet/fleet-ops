#!/usr/bin/env python3
"""Parked hand-offs in agent-dispatch.yml (fleet-ops#9354, #10420, #10475): the list job's selection
step and the parked job's write step, their real `run:` block and REQUEUE program (read out with yq),
against a fake gh.

An orchestrator-tried issue idle over 6 h goes back to needs-orchestrator. A labelled idle one with
no orch/issue-N PR (the class the daily cap parks, #9351) is re-fired by writing needs-orchestrator
again, with a marker comment. A label write, not a task=orchestrate dispatch: a called workflow
cannot escalate past its caller's grant, the caller stubs hold this file at actions: read, and
gh workflow run needs actions: write (fleet-ops#10638, #10657). The list job selects and the parked
job writes, because the list job runs hosted, where the sweep token fires no label event and no fleet
credential exists, so the write job runs on the agent pool with the worker App token.

At most 5 minus the live orchestrate runs a sweep, oldest created first: gh issue list answers
newest created first by default, so the selection step asks GitHub's own search sort for
sort:created-asc and the bounded batch takes the hand-off that has waited longest. Three ended or
re-fired hand-offs give needs-nish-decision. The marker is the sweep's strike, so it is posted only
for a re-fire whose label write landed: a refused write posts no marker, counts no strike, and fails
the job.

The fake gh answers `issue list` from a file and so proves the request (it fails without
sort:created-asc), not the order GitHub answers in; the order is GitHub's own search sort.
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
STEP = ".jobs.list.steps[] | select(.env.REQUEUE)"           # the selection step
PARKED = ".jobs.parked.steps[] | select(.env.PARKED)"        # the write step
REFIRED = "orchestrator re-fired by the sweep: https://example.invalid/runs/"
ENDED = "orchestrator hand-off ended without a PR: https://example.invalid/runs/"

FAKE_GH = r"""#!/usr/bin/env bash
case "$1 $2" in
  "issue list")
    case "$*" in *"sort:created-asc"*) ;; *) echo "fake gh: issue list without sort:created-asc" >&2; exit 1 ;; esac
    cat "$FAKE_DIR/issues.json" ;;
  "pr list") [ -z "$FAIL_PRS" ] || exit 1; cat "$FAKE_DIR/prs.json" ;;
  "api repos/o/r/actions/workflows/stub.yml/runs?status=in_progress&per_page=100")
    [ -z "$FAIL_RUNS" ] || exit 1
    jq -r "$4" "$FAKE_DIR/runs.json" ;;
  "api repos/o/r/actions/runs/"*)
    [ -z "$FAIL_JOBS" ] || exit 1
    id=${2#repos/o/r/actions/runs/}; id=${id%/jobs}
    jq --arg id "$id" '.[$id]' "$FAKE_DIR/jobs.json" | jq -r "$4" ;;
  "issue edit"|"issue comment") [ -z "$FAIL_EDIT" ] || exit 1; echo "$*" >> "$FAKE_DIR/writes.log" ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 1 ;;
esac
"""


def _y(expr):
    return subprocess.run(["yq", expr, WF], check=True, capture_output=True, text=True).stdout


def _yj(expr):
    return json.loads(subprocess.run(["yq", "-o=json", expr, WF], check=True,
                                     capture_output=True, text=True).stdout)


def issue(number, hours_idle=7, ended=1, labels=("orchestrator-tried",), refired=0):
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


def run(tmp_path, issues, queued=0, prs=(), fail=None, other_jobs=(), out=False):
    """Every live run is titled differently (sweep, stub); only its job names say orchestrate."""
    (tmp_path / "issues.json").write_text(json.dumps(issues))
    jobs = {str(i): {"jobs": [job("orchestrate" if i % 2 else "stub / orchestrate")]} for i in range(queued)}
    for i, j in enumerate(other_jobs):
        jobs[str(100 + i)] = {"jobs": [j]}
    (tmp_path / "runs.json").write_text(json.dumps({"workflow_runs": [{"id": int(k)} for k in jobs]}))
    (tmp_path / "jobs.json").write_text(json.dumps(jobs))
    (tmp_path / "prs.json").write_text(json.dumps(list(prs)))
    (tmp_path / "github_output").write_text("")
    gh = tmp_path / "gh"
    gh.write_text(FAKE_GH)
    gh.chmod(0o755)
    env = {**os.environ, "PATH": f"{tmp_path}:{os.environ['PATH']}", "FAKE_DIR": str(tmp_path),
           "GITHUB_REPOSITORY": "o/r", "GH_TOKEN": "x", "GITHUB_OUTPUT": str(tmp_path / "github_output"),
           "WORKFLOW_REF": "o/r/.github/workflows/stub.yml@refs/heads/main", **(fail or {}),
           "REQUEUE": _y(f"{STEP} | .env.REQUEUE")}
    r = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", _y(f"{STEP} | .run")],
                       env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    parked = dict(l.split("=", 1) for l in (tmp_path / "github_output").read_text().splitlines()
                  if "=" in l)["parked"]
    wenv = {k: v for k, v in env.items() if k not in ("REQUEUE", "WORKFLOW_REF", "GITHUB_OUTPUT")}
    wenv.update(PARKED=parked, REPO="o/r", RUN_URL=REFIRED + "40786326904")
    w = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", _y(f"{PARKED} | .run")],
                       env=wenv, capture_output=True, text=True)
    log = tmp_path / "writes.log"
    lines = log.read_text().splitlines() if log.exists() else []
    text = r.stdout + r.stderr + w.stdout + w.stderr
    return (lines, text, w.returncode) if out else lines


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


def test_labelled_idle_issue_is_re_fired_by_the_label_write(tmp_path):
    """The class the daily cap parks (fleet-ops#9351): no orchestrator-tried, so the re-fire is
    needs-orchestrator written again, and that write fires the labeled event the orchestrate job
    waits for. The marker follows only the write that landed."""
    labelled = ("needs-orchestrator",)
    w = run(tmp_path, [issue(1, ended=0, labels=labelled),
                       issue(2, ended=0, labels=labelled, hours_idle=5),
                       issue(3, ended=0, labels=labelled),
                       issue(4, ended=0, labels=labelled + ("needs-nish-decision",))],
            prs=["orch/issue-3"])
    assert edits(w, "--remove-label needs-orchestrator") == [1]
    assert edits(w, "--add-label needs-orchestrator") == [1]
    assert not [l for l in w if l.startswith("workflow run")], "a label write needs no dispatch grant"
    marker = REFIRED.split("https")[0]
    assert [l for l in w if l.startswith("issue comment 1 ") and marker in l]
    assert marker in _y(f"{STEP} | .env.REQUEUE"), "the counter and the posted marker must share one prefix"


def test_the_re_fire_removes_the_label_before_it_adds_it_back(tmp_path):
    """Two writes, in this order. One call that adds and removes the same label leaves the label set
    unchanged, and GitHub fires no labeled event for a label set that did not change."""
    w = run(tmp_path, [issue(1, ended=0, labels=("needs-orchestrator",))])
    assert edits(w, "--remove-label needs-orchestrator") == [1]
    assert edits(w, "--add-label needs-orchestrator") == [1]
    block = _y(f"{PARKED} | .run").rsplit("else", 1)[1]
    assert block.index("--remove-label needs-orchestrator") < block.index("--add-label needs-orchestrator")


def test_a_failed_add_back_puts_the_label_back_on():
    """The churn takes the label off before it adds it, so an add that fails must re-add it:
    an issue the sweep's label search cannot find is a hand-off nobody sees."""
    block = _y(f"{PARKED} | .run").rsplit("else", 1)[1]
    assert block.count("--add-label needs-orchestrator") == 2, block
    assert "the re-add failed too" in block, block


def test_a_requeue_swaps_orchestrator_tried_for_needs_orchestrator_in_one_call(tmp_path):
    w = run(tmp_path, [issue(1, ended=0, labels=("orchestrator-tried",))])
    assert edits(w, "--remove-label orchestrator-tried --add-label needs-orchestrator") == [1]
    assert "--remove-label orchestrator-tried --add-label needs-orchestrator" in _y(f"{PARKED} | .run")


def test_capped_issues_are_re_fired_oldest_created_first(tmp_path):
    """The daily cap parks a hand-off with needs-orchestrator and no orchestrator-tried (#9351), so
    this is the class #9354 re-dispatches. The selection step asks GitHub's own search sort for
    sort:created-asc, which answers oldest created first, so the bounded batch takes the parked
    hand-offs from the front and the newest one waits for the next sweep instead of starving the
    one that has waited longest. The list below is in the order that sort answers, so the newest
    entry, which is also the most idle, must be the one left behind."""
    labelled = ("needs-orchestrator",)
    w = run(tmp_path, [issue(n, ended=0, labels=labelled, hours_idle=20 + n) for n in range(1, 8)])
    assert edits(w, "--add-label needs-orchestrator") == [1, 2, 3, 4, 5]


def test_the_issue_list_asks_github_for_the_oldest_first_sort(tmp_path):
    """The ordering is GitHub's own search sort, not a sort added in the step (fleet-ops#9614):
    without the qualifier the API answers newest created first and the bound takes the newest
    parked hand-off every hour."""
    assert "sort:created-asc" in _y(f"{STEP} | .run")
    step = _y(f"{STEP} | .run") + _y(f"{STEP} | .env.REQUEUE")
    assert "sort_by" not in step, "the stock search sort carries the order, not a sort in the step"


def test_live_orchestrate_runs_bound_the_dispatch_batch(tmp_path):
    labelled = ("needs-orchestrator",)
    w = run(tmp_path, [issue(n, ended=0, labels=labelled, hours_idle=20 + n) for n in range(1, 5)], queued=4)
    assert edits(w, "--add-label needs-orchestrator") == [1]


def test_a_capped_issue_the_sweep_just_fired_waits_six_hours(tmp_path):
    """The day-1 guard (#9354): the sweep's own marker comment moves updatedAt, so a hand-off the cap
    parked is not re-fired again until it has been idle 6 h. Without the floor the hourly sweep
    re-fires it all day, the cap parks it again, and the issue loops."""
    w = run(tmp_path, [issue(1, ended=0, labels=("needs-orchestrator",), hours_idle=5)])
    assert w == []


def test_a_refused_dispatch_writes_no_marker_and_no_strike(tmp_path):
    """The marker is the sweep's strike, and three of them escalate a hand-off to needs-nish-decision, so a
    re-fire that never landed may not be counted as one: the job fails, writes the error and no marker (#10773)."""
    i = [issue(1, ended=0, labels=("needs-orchestrator",))]
    w, text, code = run(tmp_path, i, fail={"FAIL_EDIT": "1"}, out=True)
    assert code != 0, "a refused write must fail the job, not pass silently"
    assert "::error::#1: re-fire refused" in text
    assert not [l for l in w if l.startswith("issue comment")], "no marker for a re-fire that never landed"
    assert edits(w, "--add-label needs-orchestrator") == []


def test_three_refused_dispatches_do_not_escalate(tmp_path):
    """The escalation counts markers, so a sweep that cannot re-fire at all never parks a hand-off it
    could not start as three dead ones (#10773)."""
    i = [issue(1, ended=0, labels=("needs-orchestrator",))]
    for _ in range(3):
        run(tmp_path, i, fail={"FAIL_EDIT": "1"})
    log = tmp_path / "writes.log"
    w = log.read_text().splitlines() if log.exists() else []
    assert edits(w, "--add-label needs-orchestrator") == []


def test_refires_count_toward_the_three_strikes(tmp_path):
    """A re-fired run that dies with its runner posts no ended comment, so the sweep's own marker counts."""
    labelled = ("needs-orchestrator",)
    w = run(tmp_path, [issue(1, ended=0, labels=labelled, refired=3), issue(2, ended=1, labels=labelled, refired=1)])
    assert edits(w, "--add-label needs-nish-decision") == [1]
    assert edits(w, "--add-label needs-orchestrator") == [2]
    assert [l for l in w if l.startswith("issue comment 2 ") and "runs/40786326904" in l]


@pytest.mark.parametrize("login", ["github-actions", "github-actions[bot]", "nishfleet-worker[bot]"])
def test_actions_token_marker_counts_under_graphql_and_rest_login(tmp_path, login):
    """gh issue list (GraphQL) names the Actions token github-actions, the REST API
    github-actions[bot], and the worker App token the parked job writes on nishfleet-worker[bot]."""
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
    allowed = set(re.findall(r"github\.event_name\s*==\s*['\"]([a-z_]+)['\"]", _y(f"{STEP} | .if")))
    assert allowed == {"schedule", "workflow_dispatch"}
    assert allowed <= set(_yj(".on | keys")), allowed
    gate = _y(".jobs.parked.if")
    assert allowed == set(re.findall(r"github\.event_name\s*==\s*['\"]([a-z_]+)['\"]", gate)), gate
    assert "vars.FLEET_DISPATCH_PAUSED != 'true'" in gate, "the list job's off-switch must close the write job too"
    assert "needs.list.outputs.parked != '[]'" in gate, "nothing parked means nothing to write"


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


def test_the_write_job_is_its_own_job_that_nothing_depends_on():
    """A refused write fails the parked job, and nothing needs it, so the sweep, its dispatch jobs
    and its escalations stay green (fleet-ops#10773)."""
    needs = {j: v.get("needs") for j, v in _yj(".jobs").items()}
    assert needs["parked"] == "list"
    assert "parked" not in [n if isinstance(n, str) else n for n in needs.values() if isinstance(n, list)]
    assert not any(n == "parked" for n in needs.values()), needs


def test_the_write_job_writes_on_the_worker_app_token():
    """The list job runs hosted, where the sweep token fires no label event and no fleet credential
    exists, so the write job runs on the agent pool and mints the worker App token: the same write
    admit makes, the sender the orchestrate job's allowlist names."""
    assert _yj(".jobs.parked.runs-on") == ["self-hosted", "agent"]
    assert _yj(".jobs.parked.permissions") == {}
    assert "create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510" in _y(".jobs.parked.steps[] | select(.uses) | .uses")
    assert _y(f"{PARKED} | .env.GH_TOKEN") == "${{ steps.app-token.outputs.token }}\n"
    assert _y(f"{PARKED} | .env.PARKED").startswith("${{ needs.list.outputs.parked")


def test_the_re_fire_is_a_label_write_not_a_dispatch():
    """A called workflow cannot escalate past its caller's grant: the caller stubs hold this file
    at actions: read and gh workflow run needs actions: write (fleet-ops#10638, #10657)."""
    assert "gh workflow run" not in _y(f"{PARKED} | .run")
    assert "--add-label needs-orchestrator" in _y(f"{PARKED} | .run")


def test_the_list_job_publishes_the_selection_as_its_parked_output():
    assert _y(".jobs.list.outputs.parked") == "${{ steps.list.outputs.parked }}\n"
    assert 'echo "parked=${rows:-[]}" >> "$GITHUB_OUTPUT"' in _y(f"{STEP} | .run")


def test_a_config_case_covers_the_day_one_cap_and_the_day_two_re_dispatch():
    """#9354: the sweep re-dispatches what the daily cap parked, so the config CI runs the real cap
    script against must carry both halves of that day: the day the cap parks the hand-off, and the
    next IST day, when yesterday's hand-offs no longer count."""
    caps = json.loads((pathlib.Path(ROOT) / "config" / "orchestrate-events.json").read_text())["cap_cases"]
    by_id = {c["id"]: c for c in caps}
    assert by_id["at-cap"]["want_go"] is False, "day 1: two hand-offs against a cap of 2 is parked"
    day2 = by_id["capped-issue-goes-on-the-next-ist-day"]
    assert day2["want_go"] is True, "day 2: yesterday's hand-offs no longer count, so it runs"
    assert all(h.get("when") == "YESTERDAY" for h in day2["handoffs"])
