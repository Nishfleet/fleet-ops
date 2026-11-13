"""The lane answers the reviewer bot or the repository owner on its own PRs, at most 3 rounds,
and obeys the pause.

global-standing-rules.md: the builder answers each finding, the same reviewer signs off, a
finding it keeps open goes to the owner, hard cap 3 review rounds per PR. While
FLEET_DISPATCH_PAUSED is true only gardener and alert issues run (owner, 2026-11-04).
The steps run here as written in agent.yml, under bash, with a fake `gh` that answers from
canned REST data and logs every call.
https://docs.github.com/en/rest/pulls/reviews#list-reviews-for-a-pull-request
"""
import json
import os
import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
WF = yaml.safe_load((ROOT / ".github/workflows/agent.yml").read_text())
HOP = yaml.safe_load((ROOT / ".github/workflows/answer.yml").read_text())

FAKE_GH = r"""#!/usr/bin/env python3
import json, os, subprocess, sys
args = sys.argv[1:]
with open(os.environ["GH_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")
if args[0] != "api" or "-f" in args:
    sys.exit(0)
data = json.load(open(os.environ["GH_DATA"]))
out = json.dumps(data[args[1]])
if "--jq" in args:
    out = subprocess.run(["jq", "-r", args[args.index("--jq") + 1]], input=out, capture_output=True, text=True, check=True).stdout
sys.stdout.write(out if out.endswith("\n") else out + "\n")
"""


def step(job, step_id):
    return next(s for s in WF["jobs"][job]["steps"] if s.get("id") == step_id)["run"]


def run_step(tmp_path, script, data, stubs=(), **env):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for name in ("gh", *stubs):
        (bin_dir / name).write_text(FAKE_GH)
        (bin_dir / name).chmod(0o755)
    (tmp_path / "data.json").write_text(json.dumps(data))
    out, log = tmp_path / "out", tmp_path / "gh.log"
    out.touch()
    log.touch()
    proc = subprocess.run(
        ["bash", "-e", "-c", script],
        env={"PATH": f"{bin_dir}:{os.environ['PATH']}", "GH_DATA": str(tmp_path / "data.json"), "GH_LOG": str(log),
             "GITHUB_OUTPUT": str(out), "RUNNER_TEMP": str(tmp_path), "REPO": "o/r", "GITHUB_REPOSITORY": "o/r",
             "GITHUB_SERVER_URL": "https://github.com", "GITHUB_RUN_ID": "1", **env},
        capture_output=True, text=True, check=False)
    calls = [json.loads(line) for line in log.read_text().splitlines()]
    return proc, out.read_text(), calls


@pytest.mark.parametrize(("paused", "labels", "run"), [
    ("true", [], "false"),
    ("true", [{"name": "agent-ready"}], "false"),
    ("true", [{"name": "gardener"}], "true"),
    ("true", [{"name": "alert"}], "true"),
    ("", [], "true"),
])
def test_the_pause_lets_only_gardener_and_alert_through(tmp_path, paused, labels, run):
    proc, out, _ = run_step(tmp_path, step("gate", "labels"), {"repos/o/r/issues/7": {"labels": labels}}, ISSUE="7", PAUSED=paused)
    assert proc.returncode == 0, proc.stderr
    assert out == f"run={run}\n"


def test_the_round_step_passes_the_same_gate():
    assert WF["env"]["ISSUE"] == "${{ github.event.issue.number || inputs.issue }}"
    assert WF["jobs"]["claim"]["needs"] == "gate"


SHA, OLD, OLDER = "a" * 40, "b" * 40, "c" * 40


def review(state, sha=SHA, body="finding", user="nishfleet-approver", association=None):
    r = {"user": {"login": user}, "state": state, "commit_id": sha, "body": body}
    if association:
        r["author_association"] = association
    return r


def owner_review(state, sha=SHA, body="finding"):
    # On an org repo GitHub reports the owner's reviews as MEMBER, never OWNER
    # (https://docs.github.com/en/graphql/reference/enums#commentauthorassociation),
    # so the lane goes by the login: the fixture is MEMBER nish3451.
    return review(state, sha, body, user="nish3451", association="MEMBER")


def round_data(reviews, ref="agent/issue-7", failing=(), red_answers=0, head=SHA):
    # The round step reads the check runs of the head sha too, so a red CI head can be
    # answered (failing = names of failed check runs). A green head by default.
    return {"repos/o/r/pulls/12": {"head": {"ref": ref, "sha": head}},
            "repos/o/r/pulls/12/reviews?per_page=100": reviews,
            f"repos/o/r/commits/{SHA}/check-runs?per_page=100":
                {"check_runs": [{"name": n, "status": "completed", "conclusion": "failure"}
                                for n in failing]},
            "repos/o/r/issues/12/comments?per_page=100":
                [{"body": f"agent: answering red CI on {OLD} (ci): x"}] * red_answers}


def labelled(calls):
    return [c for c in calls if c[:2] == ["api", "repos/o/r/issues/12/labels"]]


def test_the_task_carries_the_latest_open_change_request_per_reviewer(tmp_path):
    reviews = [review("CHANGES_REQUESTED", OLD, "old finding"), review("COMMENTED", OLD, "stranger", user="someone"),
               review("CHANGES_REQUESTED", body="fix the gate")]
    proc, out, calls = run_step(tmp_path, step("claim", "round"), round_data(reviews), ISSUE="7", PR="12")
    assert proc.returncode == 0, proc.stderr
    assert "go=true" in out and "ref=agent/issue-7" in out
    task = out.split("\n", 1)[1]
    assert task.startswith("Answer review round 1 on #12\n\nFrom nishfleet-approver:\nfix the gate\n")
    assert "old finding" not in out and "stranger" not in out
    assert labelled(calls) == []


def test_an_owners_change_request_runs_the_worker_on_the_owners_text(tmp_path):
    reviews = [review("APPROVED", OLD), owner_review("CHANGES_REQUESTED", body="set the limit to 30 per 5 minutes")]
    proc, out, calls = run_step(tmp_path, step("claim", "round"), round_data(reviews), ISSUE="7", PR="12")
    assert proc.returncode == 0, proc.stderr
    assert "go=true" in out and "ref=agent/issue-7" in out
    task = out.split("\n", 1)[1]
    assert task.startswith("Answer review round 1 on #12\n\nFrom nish3451:\nset the limit to 30 per 5 minutes\n")
    assert labelled(calls) == []


# The task carries each open change request under its own "From <login>:" line: the bot's
# findings next to the owner's, even when the two reviews sit on different heads, because
# what is open is each reviewer's latest review that still asks for changes.
# https://docs.github.com/en/rest/pulls/reviews#list-reviews-for-a-pull-request
@pytest.mark.parametrize("head", [SHA, OLD], ids=("one-head", "owner-on-the-older-head"))
def test_bot_and_owner_findings_both_reach_the_builder(tmp_path, head):
    reviews = ([review("CHANGES_REQUESTED", SHA), owner_review("CHANGES_REQUESTED", SHA, "owner finding")]
               if head == SHA else
               [owner_review("CHANGES_REQUESTED", OLD, "owner finding"), review("CHANGES_REQUESTED")])
    proc, out, calls = run_step(tmp_path, step("claim", "round"), round_data(reviews), ISSUE="7", PR="12")
    assert proc.returncode == 0, proc.stderr
    assert "go=true" in out and "ref=agent/issue-7" in out
    task = out.split("\n", 1)[1]
    assert "From nishfleet-approver:\nfinding" in task
    assert "From nish3451:\nowner finding" in task
    # A round is a distinct head among the open change requests: the bot and the owner
    # asking on one head count once; the owner's on the older head counts a second one.
    assert task.startswith(f"Answer review round {1 if head == SHA else 2} on #12")
    assert labelled(calls) == []


@pytest.mark.parametrize("last", [
    review("CHANGES_REQUESTED", SHA, "third"),
    owner_review("CHANGES_REQUESTED", SHA, "third"),
], ids=("bot", "owner"))
def test_round_three_goes_to_the_owner_instead_of_running(tmp_path, last):
    # Three rounds to the cap: the bot's and the owner's change requests on two heads, and
    # one "answering red CI" comment the lane left. A round is a distinct head among the
    # open change requests, not a review, so same-head requests do not stack the count.
    reviews = [review("CHANGES_REQUESTED", OLD), owner_review("CHANGES_REQUESTED", OLD), last]
    proc, out, calls = run_step(tmp_path, step("claim", "round"), round_data(reviews, red_answers=1), ISSUE="7", PR="12")
    assert proc.returncode == 0, proc.stderr
    assert out == "go=false\n"
    assert labelled(calls) == [["api", "repos/o/r/issues/12/labels", "-f", "labels[]=needs-owner"]]


def test_two_bot_requests_and_the_owners_on_one_head_count_two_rounds_not_three(tmp_path):
    # PR 11979 lost its push after one real fix because every change-request review counted
    # a round; now the bot's and the owner's asks on one head count once, and a reviewer's
    # latest review supersedes its own older ones, so three bot reviews are one open round.
    reviews = [review("CHANGES_REQUESTED", OLD), owner_review("CHANGES_REQUESTED", OLD), review("CHANGES_REQUESTED"), review("CHANGES_REQUESTED", OLDER)]
    proc, out, calls = run_step(tmp_path, step("claim", "round"), round_data(reviews), ISSUE="7", PR="12")
    assert proc.returncode == 0, proc.stderr
    task = out.split("\n", 1)[1]
    assert task.startswith("Answer review round 2 on #12")
    assert "go=true" in out and labelled(calls) == []


@pytest.mark.parametrize("last", [review("APPROVED"), review("COMMENTED")], ids=("approved", "commented"))
def test_no_run_unless_some_latest_review_still_requests_changes_or_the_head_is_red(tmp_path, last):
    # The go check is any open change request, or red checks on this head; the bot's latest
    # review that no longer asks for changes closes its earlier request.
    proc, out, calls = run_step(tmp_path, step("claim", "round"), round_data([review("CHANGES_REQUESTED", OLD), last]), ISSUE="7", PR="12")
    assert proc.returncode == 0, proc.stderr
    assert out == "go=false\n" and labelled(calls) == []


def test_a_change_request_open_on_an_older_head_still_runs(tmp_path):
    # The go check is any open change request, not only one on this head: the owner's or the
    # bot's latest review asking for changes on an earlier commit still waits for an answer.
    proc, out, calls = run_step(tmp_path, step("claim", "round"), round_data([review("CHANGES_REQUESTED", OLD)]), ISSUE="7", PR="12")
    assert proc.returncode == 0, proc.stderr
    task = out.split("\n", 1)[1]
    assert task.startswith("Answer review round 1 on #12\n\nFrom nishfleet-approver:\nfinding\n")
    assert "go=true" in out and labelled(calls) == []


def test_a_pr_off_the_issues_branch_is_refused(tmp_path):
    proc, _, _ = run_step(tmp_path, step("claim", "round"), round_data([review("CHANGES_REQUESTED")], ref="feature"), ISSUE="7", PR="12")
    assert proc.returncode != 0


# A red head can never carry the bot's change request (the reviewer reads green CI only), so
# the round step answers a failed check run on it instead, under the same cap.
# https://docs.github.com/en/rest/checks/runs#list-check-runs-for-a-git-reference
RED_COMMENT = ["api", "repos/o/r/issues/12/comments", "-f",
               f"body=agent: answering red CI on {SHA} (ci): https://github.com/o/r/actions/runs/1"]


def test_a_red_head_with_a_stale_change_request_still_runs_the_worker(tmp_path):
    reviews = [review("CHANGES_REQUESTED", OLD)]
    proc, out, calls = run_step(tmp_path, step("claim", "round"), round_data(reviews, failing=("ci",)), ISSUE="7", PR="12")
    assert proc.returncode == 0, proc.stderr
    assert "go=true" in out and "ref=agent/issue-7" in out
    task = out.split("\n", 1)[1]
    assert task.startswith(f"The CI on #12 is red on {SHA}; the failed jobs are: ci")
    assert "run-proof" in task
    assert RED_COMMENT in calls
    assert labelled(calls) == []


def test_a_red_head_on_a_fresh_pr_runs_too(tmp_path):
    proc, out, calls = run_step(tmp_path, step("claim", "round"), round_data([], failing=("ci",)), ISSUE="7", PR="12")
    assert proc.returncode == 0, proc.stderr
    assert out.endswith("go=true\n") and RED_COMMENT in calls and labelled(calls) == []


def test_a_third_red_answer_after_two_open_heads_goes_to_the_owner(tmp_path):
    # Two distinct heads among the open change requests and one red answer reach the cap of 3.
    reviews = [review("CHANGES_REQUESTED", OLD), owner_review("CHANGES_REQUESTED", SHA)]
    proc, out, calls = run_step(tmp_path, step("claim", "round"), round_data(reviews, failing=("ci",), red_answers=1), ISSUE="7", PR="12")
    assert proc.returncode == 0 and out == "go=false\n"
    assert labelled(calls) == [["api", "repos/o/r/issues/12/labels", "-f", "labels[]=needs-owner"]]
    assert RED_COMMENT not in calls


def test_a_third_red_head_in_a_row_goes_to_the_owner(tmp_path):
    proc, out, calls = run_step(tmp_path, step("claim", "round"), round_data([], failing=("ci",), red_answers=2), ISSUE="7", PR="12")
    assert proc.returncode == 0 and out == "go=false\n"
    assert labelled(calls) == [["api", "repos/o/r/issues/12/labels", "-f", "labels[]=needs-owner"]]
    assert RED_COMMENT not in calls


def test_a_green_head_without_a_change_request_still_runs_nothing(tmp_path):
    reviews = [review("APPROVED")]
    proc, out, calls = run_step(tmp_path, step("claim", "round"), round_data(reviews), ISSUE="7", PR="12")
    assert proc.returncode == 0 and out == "go=false\n"
    assert labelled(calls) == [] and RED_COMMENT not in calls


# One group holds the whole run, with a real queue: a second change request minutes after
# the first starts a second run, which then waits for the first to push before its claim
# bundles the head, so its push is not refused and the issue is not parked agent-blocked.
# Stock concurrency holds the queue by itself: with `cancel-in-progress: false` the group's
# pending runs wait and nothing pending is cancelled, so a run that skips in gate on the
# issue's other labels cannot cancel the waiting agent-ready run as a pending twin. (`queue`
# is not a concurrency key; only `group` and `cancel-in-progress` exist.)
# https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency
# https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#concurrency
def test_one_group_holds_the_whole_run_with_a_queue_and_nothing_pending_is_cancelled():
    assert WF["concurrency"] == {
        "group": "agent-${{ github.repository }}-${{ github.event.issue.number || inputs.issue }}",
        "cancel-in-progress": False,
    }
    assert "concurrency" not in WF["jobs"]["work"]


def test_only_a_go_starts_the_worker():
    assert WF["jobs"]["work"]["if"] == "needs.claim.outputs.go == 'true'"


# upstream: https://docs.github.com/en/actions/reference/workflows-and-actions/contexts#context-availability
def test_an_issue_run_is_a_go_from_the_always_run_round_step(tmp_path):
    claim = WF["jobs"]["claim"]
    assert claim["outputs"]["go"] == "${{ steps.round.outputs.go }}"
    assert "if" not in next(s for s in claim["steps"] if s.get("id") == "round")
    proc, out, calls = run_step(tmp_path, step("claim", "round"), {}, ISSUE="7", PR="")
    assert proc.returncode == 0, proc.stderr
    assert out == "go=true\n" and calls == []


def push_step():
    return next(s for s in WF["jobs"]["push"]["steps"] if s.get("name", "").startswith("Push the branch"))["run"]


# upstream: https://docs.github.com/en/rest/pulls/pulls#update-a-pull-request
@pytest.mark.parametrize(("proof", "tail"), [
    ("run-proof: pytest -q -> 9 passed", "run-proof: pytest -q -> 9 passed"),
    ("", "The worker wrote no run-proof line, so the reviewer bot will not approve."),
])
def test_a_review_answer_appends_its_proof_to_the_body_before_the_push(tmp_path, proof, tail):
    data = {"repos/o/r/pulls/12": {"body": "Closes #7\n\nrun-proof: old -> 1 passed"}}
    (tmp_path / "push").mkdir()  # the stub git does not create it
    proc, _, calls = run_step(tmp_path, push_step(), data, stubs=("git",), ISSUE="7", PR="12", BASE=SHA, PROOF=proof)
    assert proc.returncode == 0, proc.stderr
    edit = calls.index(["api", "-X", "PATCH", "repos/o/r/pulls/12", "-f",
                        f"body=Closes #7\n\nrun-proof: old -> 1 passed\n\nReview answer by the agent lane: https://github.com/o/r/actions/runs/1\n\n{tail}"])
    push = next(i for i, c in enumerate(calls) if c[:1] == ["push"])
    assert edit < push
    assert not any(c[:2] == ["pr", "create"] for c in calls)


def test_the_hop_fires_only_on_a_change_request_from_the_bot_or_the_owner_and_holds_no_secret():
    hop = HOP["jobs"]["dispatch"]
    on = HOP.get("on", HOP.get(True))
    assert on["pull_request_review"] == {"types": ["submitted"]}
    # fleet-ops#11860: CI completing with a failure on an agent/issue-* head dispatches the
    # lane too, because the reviewer reads green CI only, so a red PR drew no review.
    assert on["workflow_run"] == {"workflows": ["CI"], "types": ["completed"]}
    for cond in ("github.event.review.state == 'changes_requested'", "github.event.review.user.login == 'nishfleet-approver'",
                 "github.event.review.user.login == 'nish3451'",
                 "startsWith(github.event.pull_request.head.ref, 'agent/issue-')",
                 "github.event.pull_request.head.repo.full_name == github.repository"):
        assert cond in hop["if"]
    for cond in ("github.event_name == 'workflow_run'",
                 "github.event.workflow_run.conclusion == 'failure'",
                 "github.event.workflow_run.event == 'pull_request'",
                 "github.event.workflow_run.head_repository.full_name == github.repository",
                 "startsWith(github.event.workflow_run.head_branch, 'agent/issue-')"):
        assert cond in hop["if"]
    assert hop["runs-on"] == "ubuntu-latest" and hop["permissions"] == {"actions": "write"}
    assert "environment" not in hop and "secrets." not in yaml.safe_dump(hop)


def test_the_hop_dispatches_the_round_on_main(tmp_path):
    hop = HOP["jobs"]["dispatch"]["steps"][0]["run"]
    proc, _, calls = run_step(tmp_path, hop, {}, HEAD_REF="agent/issue-7", NUMBER="12", MAIN="main")
    assert proc.returncode == 0, proc.stderr
    assert calls == [["workflow", "run", "agent.yml", "-R", "o/r", "--ref", "main", "-f", "issue=7", "-f", "pr=12"]]


def test_the_hop_refuses_a_branch_that_is_not_an_issue_number(tmp_path):
    hop = HOP["jobs"]["dispatch"]["steps"][0]["run"]
    proc, _, calls = run_step(tmp_path, hop, {}, HEAD_REF="agent/issue-7;x", NUMBER="12", MAIN="main")
    assert proc.returncode != 0 and calls == []


def test_agent_yml_asks_no_more_than_the_product_stubs_grant():
    asked = [(name, job.get("permissions")) for name, job in WF["jobs"].items()
             if job.get("permissions") not in ({}, {"issues": "read"})]
    assert asked == []
