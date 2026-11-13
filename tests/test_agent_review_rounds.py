"""The lane answers the reviewer bot or the repository owner on its own PRs, at most 3 rounds
answered (rounds 1 and 2 by the regular builder, round 3 by the senior builder, engine=claude,
fleet-ops#11964; a fourth labels the PR needs-owner), and obeys the pause.

fleet-ops#11964: the senior round's work job reads engine=claude and lands on the Claude pool's
`senior` runner, and review.yml reads the PR's "agent: senior builder" comment to pick review-fable.

global-standing-rules.md: the builder answers each finding, the same reviewer signs off, a
finding it keeps open goes to the owner, hard cap 3 review rounds per PR. While
FLEET_DISPATCH_PAUSED is true only gardener and alert issues run (owner, 2026-11-04).
What is open on the PR is each reviewer's latest review that is a verdict at all —
APPROVED, CHANGES_REQUESTED or DISMISSED, the rule branch protection uses; a comment review
is not a verdict — and it is open while it asks for changes. A round is a distinct change
request head, so the bot and the owner asking on one head count once (fleet-ops#11987).
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


def test_a_review_round_passes_the_same_gate():
    assert WF["env"]["ISSUE"] == "${{ github.event.issue.number || inputs.issue }}"
    assert WF["jobs"]["claim"]["needs"] == "gate"


# fleet-ops#11987: the group holds the whole run, so a run that queues behind another
# reads the branch head only after the previous run's push instead of bundling a head
# that run is about to replace; `queue: max` keeps a run that skips on the issue's other
# labels from replacing a pending one.
def test_one_group_holds_the_whole_run():
    assert WF["concurrency"] == {
        "group": "agent-${{ github.repository }}-${{ github.event.issue.number || inputs.issue }}",
        "cancel-in-progress": False,
        "queue": "max",
    }
    assert "concurrency" not in WF["jobs"]["work"]


# The key is GitHub's (workflow syntax, "concurrency"); actionlint 1.7.12 does not know it
# (rhysd/actionlint#654, #657), so the ignore stays this one message, on this one file.
def test_actionlint_ignores_only_the_real_queue_key():
    cfg = yaml.safe_load((ROOT / ".github/actionlint.yaml").read_text())
    assert cfg["paths"][".github/workflows/agent.yml"]["ignore"] == \
        ['unexpected key "queue" for "concurrency" section']


SHA, OLD, OLDER, ELDEST = "a" * 40, "b" * 40, "c" * 40, "d" * 40


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


def round_data(reviews, ref="agent/issue-7", failing=(), red_answers=0):
    # The round step reads the check runs of the head sha too, so a red CI head can be
    # answered (failing = names of failed check runs). A green head by default.
    return {"repos/o/r/pulls/12": {"head": {"ref": ref, "sha": SHA}},
            "repos/o/r/pulls/12/reviews?per_page=100": reviews,
            f"repos/o/r/commits/{SHA}/check-runs?per_page=100":
                {"check_runs": [{"name": n, "status": "completed", "conclusion": "failure"}
                                for n in failing]},
            "repos/o/r/issues/12/comments?per_page=100":
                [{"body": f"agent: answering red CI on {OLD} (ci): x"}] * red_answers}


def labelled(calls):
    return [c for c in calls if c[:2] == ["api", "repos/o/r/issues/12/labels"]]


SENIOR_TASK = "Two earlier answers did not close this. Fix every open finding below, or say in the commit message why a finding is wrong."


def senior_comment(calls):
    return any(c[:2] == ["api", "repos/o/r/issues/12/comments"]
               and c[-1].startswith("body=agent: senior builder takes round 3") for c in calls)


def test_the_bots_latest_verdict_runs_on_that_verdict_only(tmp_path):
    # The bot's latest look is the change request on this head, so the older one is
    # superseded; a stranger's comment review never reaches the step at all, because the
    # API call keeps only the bot and the owner.
    reviews = [review("CHANGES_REQUESTED", OLD, "old finding"), review("COMMENTED", OLD, "stranger", user="someone"),
               review("CHANGES_REQUESTED", body="fix the gate")]
    proc, out, calls = run_step(tmp_path, step("claim", "round"), round_data(reviews), ISSUE="7", PR="12")
    assert proc.returncode == 0, proc.stderr
    assert "go=true" in out and "ref=agent/issue-7" in out
    task = out.split("\n", 1)[1]
    assert task.startswith("Answer review round 2 on #12\n\nFrom nishfleet-approver:\nfix the gate\n")
    assert "old finding" not in out and "stranger" not in out
    assert labelled(calls) == []


def test_the_owner_alone_runs_the_worker_on_the_owners_text(tmp_path):
    reviews = [review("APPROVED", OLD), owner_review("CHANGES_REQUESTED", body="set the limit to 30 per 5 minutes")]
    proc, out, calls = run_step(tmp_path, step("claim", "round"), round_data(reviews), ISSUE="7", PR="12")
    assert proc.returncode == 0, proc.stderr
    assert "go=true" in out and "ref=agent/issue-7" in out
    task = out.split("\n", 1)[1]
    assert task.startswith("Answer review round 1 on #12\n\nFrom nish3451:\nset the limit to 30 per 5 minutes\n")
    assert labelled(calls) == []


def test_the_bot_and_the_owner_on_one_head_count_once_and_both_findings_run(tmp_path):
    reviews = [review("CHANGES_REQUESTED", body="fix the gate"),
               owner_review("CHANGES_REQUESTED", body="set the limit to 30 per 5 minutes")]
    proc, out, calls = run_step(tmp_path, step("claim", "round"), round_data(reviews), ISSUE="7", PR="12")
    assert proc.returncode == 0, proc.stderr
    task = out.split("\n", 1)[1]
    # One head, one round; the task carries every open change request, each under the
    # reviewer's login (fleet-ops#11987).
    assert task.startswith("Answer review round 1 on #12\n\nFrom nish3451:\nset the limit to 30 per 5 minutes\n\n"
                           "From nishfleet-approver:\nfix the gate\n")
    assert labelled(calls) == []


def test_the_owners_request_on_an_older_head_runs_next_to_the_bots_on_this_head(tmp_path):
    reviews = [owner_review("CHANGES_REQUESTED", OLD, "old finding"), review("CHANGES_REQUESTED", body="fix the gate")]
    proc, out, calls = run_step(tmp_path, step("claim", "round"), round_data(reviews), ISSUE="7", PR="12")
    assert proc.returncode == 0, proc.stderr
    assert "go=true" in out and "ref=agent/issue-7" in out
    task = out.split("\n", 1)[1]
    # Two heads, two rounds: the owner's request on the old head is still open next to the
    # bot's on this one, because each reviewer's latest verdict is what counts.
    assert task.startswith("Answer review round 2 on #12\n\nFrom nish3451:\nold finding\n\n"
                           "From nishfleet-approver:\nfix the gate\n")
    assert labelled(calls) == []


@pytest.mark.parametrize(("last", "login"), [
    (review("CHANGES_REQUESTED"), "nishfleet-approver"),
    (owner_review("CHANGES_REQUESTED"), "nish3451"),
], ids=("bot", "owner"))
def test_three_change_request_heads_go_to_the_senior_builder(tmp_path, last, login):
    # fleet-ops#11964: three change-request heads are three answered rounds, and round 3
    # runs the senior builder (engine=claude); only a fourth labels the PR needs-owner.
    reviews = [review("CHANGES_REQUESTED", OLDER, "first"), review("CHANGES_REQUESTED", OLD, "second"), last]
    proc, out, calls = run_step(tmp_path, step("claim", "round"), round_data(reviews), ISSUE="7", PR="12")
    assert proc.returncode == 0, proc.stderr
    # engine=claude rides GITHUB_OUTPUT ahead of the task block.
    lines = out.split("\n")
    assert lines[0] == "engine=claude" and "go=true" in out and "ref=agent/issue-7" in out
    task = "\n".join(lines[1:]).split("\n", 1)[1]
    assert task.startswith(f"{SENIOR_TASK}\n\nAnswer review round 3 on #12\n\nFrom {login}:\n")
    assert senior_comment(calls)
    assert labelled(calls) == []


def test_four_change_request_heads_go_to_the_owner_instead_of_running(tmp_path):
    # fleet-ops#11964: only a fourth round goes to the owner, and it runs nothing.
    reviews = [review("CHANGES_REQUESTED", ELDEST, "first"), review("CHANGES_REQUESTED", OLDER, "second"),
               review("CHANGES_REQUESTED", OLD, "third"), review("CHANGES_REQUESTED")]
    proc, out, calls = run_step(tmp_path, step("claim", "round"), round_data(reviews), ISSUE="7", PR="12")
    assert proc.returncode == 0, proc.stderr
    assert out == "go=false\n"
    assert labelled(calls) == [["api", "repos/o/r/issues/12/labels", "-f", "labels[]=needs-owner"]]
    assert any(c[:2] == ["api", "repos/o/r/issues/12/comments"] and "owner decides" in c[-1] for c in calls)
    assert not senior_comment(calls)


def test_change_requests_from_both_on_two_heads_leave_a_third_round_of_room(tmp_path):
    # The bot and the owner on one head count once, so four change-request reviews are
    # still only two rounds (fleet-ops#11987).
    reviews = [review("CHANGES_REQUESTED", OLD, "old"), owner_review("CHANGES_REQUESTED", OLD, "old"),
               review("CHANGES_REQUESTED", body="new"), owner_review("CHANGES_REQUESTED", body="new")]
    proc, out, calls = run_step(tmp_path, step("claim", "round"), round_data(reviews), ISSUE="7", PR="12")
    assert proc.returncode == 0, proc.stderr
    assert "go=true" in out and "Answer review round 2 on #12" in out
    assert labelled(calls) == []


@pytest.mark.parametrize(("last", "go"), [
    (review("APPROVED"), "false"),
    (review("DISMISSED"), "false"),
    (review("COMMENTED"), "true"),
], ids=("approved", "dismissed", "commented"))
def test_the_bots_latest_verdict_opens_the_round_and_a_comment_closes_nothing(tmp_path, last, go):
    # The rule branch protection uses: a comment review is not a verdict, so a comment
    # after a change request leaves it open; an approval or a dismissal closes it.
    proc, out, _ = run_step(tmp_path, step("claim", "round"), round_data([review("CHANGES_REQUESTED", OLD, "old finding"), last]),
                            ISSUE="7", PR="12")
    assert proc.returncode == 0, proc.stderr
    assert out.endswith(f"go={go}\n")
    if go == "true":
        assert out.split("\n", 1)[1].startswith("Answer review round 1 on #12\n\nFrom nishfleet-approver:\nold finding\n")


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
    # The open change request rides along with the red CI: the worker answers both.
    assert "From nishfleet-approver:\nfinding" in task
    assert RED_COMMENT in calls
    assert labelled(calls) == []


def test_a_red_head_on_a_fresh_pr_runs_too(tmp_path):
    proc, out, calls = run_step(tmp_path, step("claim", "round"), round_data([], failing=("ci",)), ISSUE="7", PR="12")
    assert proc.returncode == 0, proc.stderr
    assert out.endswith("go=true\n") and RED_COMMENT in calls and labelled(calls) == []


def test_a_red_head_after_two_change_request_heads_runs_the_senior_builder(tmp_path):
    # Two change-request heads plus this red head are three answered rounds: the senior
    # builder answers them (engine=claude, fleet-ops#11964).
    reviews = [review("CHANGES_REQUESTED", OLDER, "first"), review("CHANGES_REQUESTED", OLD, "second")]
    proc, out, calls = run_step(tmp_path, step("claim", "round"), round_data(reviews, failing=("ci",)), ISSUE="7", PR="12")
    assert proc.returncode == 0, proc.stderr
    lines = out.split("\n")
    assert lines[0] == "engine=claude" and "go=true" in out and "ref=agent/issue-7" in out
    task = "\n".join(lines[1:]).split("\n", 1)[1]
    assert task.startswith(f"{SENIOR_TASK}\n\nThe CI on #12 is red on {SHA}; the failed jobs are: ci")
    assert RED_COMMENT in calls
    assert senior_comment(calls)
    assert labelled(calls) == []


def test_a_fourth_red_head_in_a_row_goes_to_the_owner(tmp_path):
    proc, out, calls = run_step(tmp_path, step("claim", "round"), round_data([], failing=("ci",), red_answers=3), ISSUE="7", PR="12")
    assert proc.returncode == 0 and out == "go=false\n"
    assert labelled(calls) == [["api", "repos/o/r/issues/12/labels", "-f", "labels[]=needs-owner"]]
    assert RED_COMMENT not in calls


def test_a_third_red_head_in_a_row_runs_the_senior_builder(tmp_path):
    # Two earlier "answering red CI" rounds plus this red head are three answered rounds:
    # the senior builder answers them (engine=claude, fleet-ops#11964).
    proc, out, calls = run_step(tmp_path, step("claim", "round"), round_data([], failing=("ci",), red_answers=2), ISSUE="7", PR="12")
    assert proc.returncode == 0, proc.stderr
    assert "go=true" in out and "engine=claude" in out
    assert RED_COMMENT in calls and senior_comment(calls)
    assert labelled(calls) == []


def test_a_green_head_without_a_change_request_still_runs_nothing(tmp_path):
    reviews = [review("APPROVED")]
    proc, out, calls = run_step(tmp_path, step("claim", "round"), round_data(reviews), ISSUE="7", PR="12")
    assert proc.returncode == 0 and out == "go=false\n"
    assert labelled(calls) == [] and RED_COMMENT not in calls


def test_only_a_go_starts_the_worker():
    assert WF["jobs"]["work"]["if"] == "needs.claim.outputs.go == 'true'"


# fleet-ops#11964: a senior round is engine=claude on the Claude pool's `senior` runner;
# the claim job carries the engine the round step chose, ahead of a dispatched input.
def test_a_senior_round_runs_the_claude_engine_on_the_senior_runner():
    work = WF["jobs"]["work"]
    assert WF["jobs"]["claim"]["outputs"]["engine"] == "${{ steps.round.outputs.engine }}"
    assert work["env"]["ENGINE"] == "${{ needs.claim.outputs.engine || inputs.engine || 'pi' }}"
    assert work["runs-on"] == ["self-hosted", "${{ (needs.claim.outputs.engine || inputs.engine) == 'claude' && 'senior' || 'agent' }}"]


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
    proc, _, calls = run_step(tmp_path, push_step(), data, stubs=("git",), ISSUE="7", PR="12", BASE=SHA, DEFAULT="main", PROOF=proof)
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
    # The ticket check (fleet-ops#11949, report only) is the one exception: its call needs
    # contents: read to fetch the ticket and docs/review-bar.md, and issues: write to post
    # the verdict as one comment on the ticket. A product stub that calls the lane grants
    # the same on its calling job; until then the check fails red there and, report only,
    # building carries on.
    allowed = ({}, {"issues": "read"}, {"contents": "read", "issues": "write"})
    asked = [(name, job.get("permissions")) for name, job in WF["jobs"].items()
             if job.get("permissions") not in allowed]
    assert asked == []
