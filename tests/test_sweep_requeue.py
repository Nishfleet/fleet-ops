"""Parked hand-offs in agent-dispatch.yml (fleet-ops#10963, #10420, #10475): the list job's
selection step and the parked job's write step, their real `run:` block and REQUEUE program (read
out with yq), against a fake gh.

An orchestrator-tried issue idle over 6 h goes back to needs-orchestrator. A labelled idle one with
no orch/issue-N PR is re-fired by writing needs-orchestrator again, with a marker comment. A closed
blocker releases a parked hand-off the same way, with no marker. At most 5 minus the live orchestrate
runs a sweep. Three ended or re-fired hand-offs give needs-nish-decision.

The list job selects and the parked job writes, because the list job runs on a GitHub-hosted
runner: the sweep token there fires no issues event, so a label write re-queues nothing, and no
fleet credential exists, so both writes were refused on every run and 51 hand-offs sat on
handoff-ended (fleet-ops#10963). The write job runs on the runner selection the orchestrate job uses (the fleet-ops runner group on fleet-ops, the agent pool elsewhere) and writes on the worker App
token, the same two steps admit uses: writing needs-orchestrator fires the labeled event the
orchestrate job waits for, and the App sender is on its allowlist. A refused write fails the job
and posts no marker, so the sweep's strike counts only a write that landed.

The fake gh answers `issue list` from a file, so it proves the request, not the order GitHub
answers in. A refused write is FAIL_EDIT, which is what a login-less runner and a token without
issues: write both look like. A refused comment is FAIL_COMMENT, and a read failure is FAIL_ISSUES. A comment read returns the App as `nishfleet-worker` with no `[bot]` suffix, so the strike counter names that login too.
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
PARKED = ".jobs.parked.steps[] | select(.env.PARKED)"
REFIRED = "orchestrator re-fired by the sweep: https://example.invalid/runs/"
ENDED = "orchestrator hand-off ended without a PR: https://example.invalid/runs/"

FAKE_GH = r"""#!/usr/bin/env bash
case "$1 $2" in
  "issue list") [ -z "$FAIL_ISSUES" ] || exit 1; cat "$FAKE_DIR/issues.json" ;;
  "pr list") [ -z "$FAIL_PRS" ] || exit 1; cat "$FAKE_DIR/prs.json" ;;
  "api repos/o/r/actions/workflows/stub.yml/runs?status=in_progress&per_page=100")
    [ -z "$FAIL_RUNS" ] || exit 1
    jq -r "$4" "$FAKE_DIR/runs.json" ;;
  "api repos/o/r/actions/runs/"*)
    [ -z "$FAIL_JOBS" ] || exit 1
    id=${2#repos/o/r/actions/runs/}; id=${id%/jobs}
    jq --arg id "$id" '.[$id]' "$FAKE_DIR/jobs.json" | jq -r "$4" ;;
  "issue edit") [ -z "$FAIL_EDIT" ] || exit 1; echo "$*" >> "$FAKE_DIR/writes.log" ;;
  "issue comment") [ -z "$FAIL_EDIT$FAIL_COMMENT" ] || exit 1; echo "$*" >> "$FAKE_DIR/writes.log" ;;
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


def _fake_gh(tmp_path, issues, queued=0, prs=(), other_jobs=()):
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


def _bash(tmp_path, script, env, out=False):
    w = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", script],
                       env=env, capture_output=True, text=True)
    log = tmp_path / "writes.log"
    lines = log.read_text().splitlines() if log.exists() else []
    return (lines, w.stdout + w.stderr, w.returncode) if out else lines


def write(tmp_path, parked="[]", released="[]", fail=None, out=False):
    """The parked job's write step alone, for the released case the selection step cannot model:
    the list step that collects a released hand-off also reads every claim PR in the repo."""
    if not (tmp_path / "gh").exists():
        _fake_gh(tmp_path, [])
    env = {**os.environ, "PATH": f"{tmp_path}:{os.environ['PATH']}", "FAKE_DIR": str(tmp_path),
           "GH_TOKEN": "x", "PARKED": parked, "RELEASED": released, "REPO": "o/r",
           "RUN_URL": REFIRED + "40786326904", **(fail or {})}
    return _bash(tmp_path, _y(f"{PARKED} | .run"), env, out)


def run(tmp_path, issues, queued=0, prs=(), fail=None, other_jobs=(), out=False):
    _fake_gh(tmp_path, issues, queued, prs, other_jobs)
    (tmp_path / "github_output").write_text("")
    env = {**os.environ, "PATH": f"{tmp_path}:{os.environ['PATH']}", "FAKE_DIR": str(tmp_path),
           "GITHUB_REPOSITORY": "o/r", "GH_TOKEN": "x", "GITHUB_OUTPUT": str(tmp_path / "github_output"),
           "WORKFLOW_REF": "o/r/.github/workflows/stub.yml@refs/heads/main", **(fail or {}),
           "REQUEUE": _y(f"{STEP} | .env.REQUEUE")}
    r = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", _y(f"{STEP} | .run")],
                       env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    out_map = dict(l.split("=", 1) for l in (tmp_path / "github_output").read_text().splitlines()
                   if "=" in l)
    assert isinstance(json.loads(out_map["parked"]), list), out_map["parked"]
    lines, text, code = write(tmp_path, out_map["parked"], out_map.get("released", "[]"), fail, True)
    return (lines, r.stdout + r.stderr + text, code) if out else lines


def edits(lines, label):
    return sorted(int(l.split()[2]) for l in lines if l.startswith("issue edit") and label in l)


def test_idle_six_hours_requeues_and_fresh_waits(tmp_path):
    w = run(tmp_path, [issue(1, 7), issue(2, 5)])
    assert edits(w, "--add-label needs-orchestrator") == [1]


def test_a_quiet_priority_now_issue_waits_thirty_minutes_not_six_hours(tmp_path):
    """#10681 carried priority-now and needs-orchestrator and nothing ran for an hour, because this
    waited 6 h (fleet-ops#10716)."""
    labelled = ("orchestrator-tried", "priority-now")
    w = run(tmp_path, [issue(1, hours_idle=0.6, labels=labelled),
                       issue(2, hours_idle=0.4, labels=labelled)])
    assert edits(w, "--add-label needs-orchestrator") == [1]


def test_a_priority_now_issue_still_waits_when_it_needs_nish(tmp_path):
    labelled = ("needs-orchestrator", "needs-nish-decision", "priority-now")
    w = run(tmp_path, [issue(1, hours_idle=7, labels=labelled)])
    assert w == []


def test_the_thirty_minute_wait_is_only_for_a_priority_now_issue(tmp_path):
    w = run(tmp_path, [issue(1, hours_idle=0.6), issue(2, hours_idle=7)])
    assert edits(w, "--add-label needs-orchestrator") == [2]


def test_a_priority_now_issue_takes_a_slot_ahead_of_the_parked_backlog(tmp_path):
    """Five 7-hour hand-offs filled every slot of the sweep, so a priority-now issue queued behind
    them however short its wait (fleet-ops#10716: #10681 sat that way for 16 h)."""
    backlog = [issue(n, hours_idle=7) for n in range(1, 6)]
    w = run(tmp_path, backlog + [issue(9, hours_idle=0.6, labels=("orchestrator-tried", "priority-now"))])
    sel = edits(w, "--add-label needs-orchestrator")
    assert 9 in sel, sel
    assert len(sel) == 5, sel


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
    marker = REFIRED.split("https")[0]
    assert [l for l in w if l.startswith("issue comment 1 ") and marker in l]
    assert marker in _y(f"{STEP} | .env.REQUEUE"), "the counter and the posted marker must share one prefix"


def _case(marker, end="# A closed blocker releases"):
    """One case of the parked job's write step, cut at the comment that names the next one."""
    return _y(f"{PARKED} | .run").split(marker, 1)[1].split(end)[0]


def test_the_re_fire_removes_the_label_before_it_adds_it_back(tmp_path):
    """Two writes, in this order. One call that adds and removes the same label leaves the label set
    unchanged, and GitHub fires no labeled event for a label set that did not change."""
    w = run(tmp_path, [issue(1, ended=0, labels=("needs-orchestrator",))])
    assert edits(w, "--remove-label needs-orchestrator") == [1]
    assert edits(w, "--add-label needs-orchestrator") == [1]
    block = _case("else\n")
    assert block.index("--remove-label needs-orchestrator") < block.index("--add-label needs-orchestrator")


def test_a_failed_add_back_puts_the_label_back_on():
    """The churn takes the label off before it adds it, so an add that fails must re-add it:
    an issue the sweep's label search cannot find is a hand-off nobody sees."""
    block = _case("else\n")
    assert block.count("--add-label needs-orchestrator") == 2, block
    assert "the re-add failed too" in block, block


def test_a_requeue_swaps_orchestrator_tried_for_needs_orchestrator_in_one_call(tmp_path):
    w = run(tmp_path, [issue(1, ended=0, labels=("orchestrator-tried",))])
    assert edits(w, "--remove-label orchestrator-tried --add-label needs-orchestrator") == [1]
    assert "--remove-label orchestrator-tried --add-label needs-orchestrator" in _y(f"{PARKED} | .run")


def test_a_refused_write_fails_the_job_and_counts_no_strike(tmp_path):
    """The marker is the sweep's strike, and three of them escalate a hand-off to
    needs-nish-decision, so a write that never landed may not be counted as one: the job fails,
    writes the error and posts no marker."""
    i = [issue(1, ended=0, labels=("needs-orchestrator",))]
    w, text, code = run(tmp_path, i, fail={"FAIL_EDIT": "1"}, out=True)
    assert code != 0, "a refused write must fail the job, not pass silently"
    assert "::error::#1: re-fire refused" in text
    assert not [l for l in w if l.startswith("issue comment")], "no marker for a write that never landed"
    assert edits(w, "--add-label needs-orchestrator") == []


def test_three_refused_writes_do_not_escalate(tmp_path):
    """The escalation counts markers, so a sweep that cannot write at all never parks a hand-off it
    could not start as three dead ones."""
    i = [issue(1, ended=0, labels=("needs-orchestrator",))]
    for _ in range(3):
        run(tmp_path, i, fail={"FAIL_EDIT": "1"})
    log = tmp_path / "writes.log"
    w = log.read_text().splitlines() if log.exists() else []
    assert edits(w, "--add-label needs-orchestrator") == [], "no write landed, so no re-fire"
    assert not edits(w, "--add-label needs-nish-decision"), "three refused writes do not escalate to a human"


def test_a_refused_marker_fails_the_job_though_the_write_landed(tmp_path):
    """A landed re-fire write whose marker is refused still fails the job.

    The re-fire is two label writes plus a comment marker. When only the comment is refused the
    label writes land and the issue is re-queued, but the strike counter will not see a marker,
    so the job must fail on a non-zero exit to keep a re-fired issue countable (fleet-ops#10963).
    """
    w, text, code = run(tmp_path, [issue(1, ended=0, labels=("needs-orchestrator",))],
                       fail={"FAIL_COMMENT": "1"}, out=True)
    assert edits(w, "--add-label needs-orchestrator") == [1], "the re-fire write landed"
    assert edits(w, "--remove-label needs-orchestrator") == [1], "the churn removed the label first"
    assert not [l for l in w if l.startswith("issue comment")], "the refused marker left no comment"
    assert code != 0, "a re-fire without its marker fails the job even though the write landed"
    assert "re-fire marker refused" in text


def test_a_sweep_that_cannot_read_its_candidates_goes_red(tmp_path):
    """A selection step that cannot read its candidates fails, it does not report empty success.

    The `gh issue list` read sits in a command substitution piped to jq. Before, a read failure
    fell back to `rows=[]`, so a broken sweep looked like a clean sweep with nothing selected and
    the re-queues never fired. The step must exit non-zero so the run is red (fleet-ops#10963).
    """
    _fake_gh(tmp_path, [issue(1)])
    (tmp_path / "github_output").write_text("")
    env = {**os.environ, "PATH": f"{tmp_path}:{os.environ['PATH']}", "FAKE_DIR": str(tmp_path),
           "GITHUB_REPOSITORY": "o/r", "GH_TOKEN": "x", "GITHUB_OUTPUT": str(tmp_path / "github_output"),
           "WORKFLOW_REF": "o/r/.github/workflows/stub.yml@refs/heads/main", "FAIL_ISSUES": "1",
           "REQUEUE": _y(f"{STEP} | .env.REQUEUE")}
    r = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", _y(f"{STEP} | .run")],
                       env=env, capture_output=True, text=True)
    assert r.returncode != 0, r.stdout + r.stderr
    assert "::error::issue list failed" in r.stdout + r.stderr


def test_refires_count_toward_the_three_strikes(tmp_path):
    """A re-fired run that dies with its runner posts no ended comment, so the sweep's own marker counts."""
    labelled = ("needs-orchestrator",)
    w = run(tmp_path, [issue(1, ended=0, labels=labelled, refired=3), issue(2, ended=1, labels=labelled, refired=1)])
    assert edits(w, "--add-label needs-nish-decision") == [1]
    assert edits(w, "--add-label needs-orchestrator") == [2]
    assert [l for l in w if l.startswith("issue comment 2 ") and "runs/40786326904" in l]


@pytest.mark.parametrize("login", ["github-actions", "github-actions[bot]", "nishfleet-worker", "nishfleet-worker[bot]"])
def test_actions_token_marker_counts_under_graphql_and_rest_login(tmp_path, login):
    """gh issue list (GraphQL) names the Actions token github-actions, the REST API
    github-actions[bot], and the worker App token the parked job writes on nishfleet-worker
    (no [bot] suffix). A marker the sweep itself writes must count under every spelling, or the
    strike cap never removes the label (fleet-ops#10963)."""
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
    expr = _y(f"{STEP} | .if")
    allowed = set(re.findall(r"github\.event_name\s*==\s*['\"]([a-z_]+)['\"]", expr))
    rest = re.sub(r"github\.event_name\s*==\s*['\"][a-z_]+['\"]", "", expr)
    assert re.sub(r"[\s()|]", "", rest) == "", expr
    assert allowed == {"schedule", "workflow_dispatch"}, expr
    assert allowed <= set(_yj(".on | keys")), expr


def test_the_write_job_needs_no_event_gate_of_its_own():
    """An issues:closed sweep releases parked hand-offs (fleet-ops#10489), and that event is not a
    sweep trigger, so a schedule-only gate here would strand every released hand-off for up to an
    hour. The list job's own if reaches only its triggers, and a skipped list job skips this one."""
    gate = _y(".jobs.parked.if")
    assert "github.event_name" not in gate, gate
    assert "vars.FLEET_DISPATCH_PAUSED != 'true'" in gate, "the list job's off-switch must close the write job too"
    assert "needs.list.outputs.released != '[]'" in gate, gate
    assert "needs.list.outputs.parked != '[]'" in gate, gate


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


def test_the_list_job_writes_nothing():
    """fleet-ops#10963: this job runs hosted, where no login exists, so `env -u GH_TOKEN` leaves gh
    on ~/.config/gh and both writes could only print their warning. 51 hand-offs sat on the ended
    label that way."""
    for step in _yj(".jobs.list.steps"):
        if not step.get("run"):
            continue
        assert "env -u GH_TOKEN" not in step["run"], step["name"]
        assert "re-queue refused" not in step["run"], step["name"]
        assert "re-fire refused" not in step["run"], step["name"]


def test_the_list_job_publishes_the_released_hand_offs():
    assert _y(".jobs.list.outputs.released") == "${{ steps.list.outputs.released }}\n"
    assert 'echo "released=${released:-[]}"' in _y('.jobs.list.steps[] | select(.id == "list") | .run')


def test_a_released_hand_off_is_re_fired_by_the_two_label_writes(tmp_path):
    """fleet-ops#10489: a closed blocker releases a parked hand-off. The release is the same two
    writes as a re-fire, and no marker, because a release is not a re-fire that died."""
    w = write(tmp_path, released="[3, 4]")
    assert edits(w, "--remove-label needs-orchestrator") == [3, 4]
    assert edits(w, "--add-label needs-orchestrator") == [3, 4]
    assert not [l for l in w if l.startswith("issue comment")]


def test_the_release_removes_the_label_before_it_adds_it_back():
    block = _case("# A closed blocker releases")
    assert block.count("--add-label needs-orchestrator") == 2, block
    assert block.index("--remove-label needs-orchestrator") < block.index("--add-label needs-orchestrator")


def test_a_refused_release_fails_the_job(tmp_path):
    w, text, code = write(tmp_path, released="[3]", fail={"FAIL_EDIT": "1"}, out=True)
    assert code != 0, "a refused release must fail the job, not pass silently"
    assert "::error::#3: released hand-off re-fire refused" in text
    assert edits(w, "--add-label needs-orchestrator") == []


def test_the_list_job_publishes_the_selection_as_its_parked_output():
    """The list job publishes the parked selection as a job output the write job reads.

    `steps.<id>.outputs.<name>` reads only the step that holds that id, so the output must name
    the step that writes `parked`. Pointing it at the `list` step -- which writes only
    refs/stalled_refs/released -- leaves `parked` empty and the write job never fires, the very
    failure this change fixes. The detector ties the output to the step that writes it.
    """
    assert _y(".jobs.list.outputs.parked") == "${{ steps.requeue.outputs.parked }}\n"
    assert _y(f"{STEP} | .id").strip() == "requeue", "the selection step carries the id the output names"
    assert 'echo "parked=${rows:-[]}" >> "$GITHUB_OUTPUT"' in _y(f"{STEP} | .run")


def test_the_write_job_is_its_own_job_that_nothing_depends_on():
    """A refused write fails the parked job, and nothing needs it, so the sweep, its dispatch jobs
    and its escalations stay green."""
    needs = {j: v.get("needs") for j, v in _yj(".jobs").items()}
    assert needs["parked"] == "list"
    assert not any(n == "parked" for n in needs.values()), needs
    assert not any(isinstance(n, list) and "parked" in n for n in needs.values()), needs


def test_the_write_job_writes_on_the_worker_app_token():
    """The list job runs hosted, where the sweep token fires no label event and no fleet credential
    exists, so the write job mints the worker App token: the same write admit makes, the sender the
    orchestrate job's allowlist names. Its runner is orchestrate's selection -- the fleet-ops runner
    group on fleet-ops, the agent pool elsewhere -- because a bare `[self-hosted, agent]` label
    queues to a 24 h expiry on the fleet-ops runner (fleet-ops#10717)."""
    runs_on = _y(".jobs.parked.runs-on")
    assert runs_on == _y(".jobs.orchestrate.runs-on"), "the parked job uses orchestrate's runner selection"
    assert "github.repository == 'Nishfleet/fleet-ops'" in runs_on and '["self-hosted","fleet-ops"]' in runs_on
    assert _yj(".jobs.parked.permissions") == {}
    assert "create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510" in _y(".jobs.parked.steps[] | select(.uses) | .uses")
    assert _y(f"{PARKED} | .env.GH_TOKEN") == "${{ steps.app-token.outputs.token }}\n"
    assert _y(f"{PARKED} | .env.PARKED").startswith("${{ needs.list.outputs.parked")
    assert _y(f"{PARKED} | .env.RELEASED").startswith("${{ needs.list.outputs.released")


def test_the_re_fire_is_a_label_write_not_a_dispatch():
    """A called workflow cannot escalate past its caller's grant: the caller stubs hold this file
    at actions: read and gh workflow run needs actions: write (fleet-ops#10638, #10657)."""
    assert "gh workflow run" not in _y(f"{PARKED} | .run")
    assert "--add-label needs-orchestrator" in _y(f"{PARKED} | .run")
