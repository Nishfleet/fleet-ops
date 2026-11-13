"""A fresh issue run replaces its lane's old branch unless an open PR uses it.

Run 41846745347 (issue 11723) lost its push to "(fetch first)": agent/issue-11723 still held
the head of closed PR #11730. The push step runs here as written in agent.yml, with real git
against a local bare repo (github.com rewritten by url.<base>.insteadOf) and a fake `gh`.
https://git-scm.com/docs/git-push#Documentation/git-push.txt---force-with-leaseltrefnamegt
https://git-scm.com/docs/git-config#Documentation/git-config.txt-urlltbasegtinsteadOf
https://docs.github.com/en/rest/pulls/pulls#list-pull-requests
"""
import json
import os
import subprocess

import pytest
from test_agent_review_rounds import FAKE_GH, WF, push_step, run_step

BRANCH = "refs/heads/agent/issue-7"
OPEN = "repos/o/r/pulls?head=o:agent/issue-7&state=open"
MOVE_THEN_GIT = """#!/bin/sh
if [ "$1" = push ] && [ -n "$MOVE_TO" ]; then
  PATH="$REAL_PATH" git --git-dir="$REMOTE" update-ref refs/heads/agent/issue-7 "$MOVE_TO"
fi
PATH="$REAL_PATH" exec git "$@"
"""


def git(*args, cwd=None):
    return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def commit(repo, name):
    (repo / name).write_text(name)
    git("add", name, cwd=repo)
    git("commit", "-qm", name, cwd=repo)
    return git("rev-parse", "HEAD", cwd=repo)


@pytest.fixture
def lane(tmp_path):
    remote, src = tmp_path / "remote.git", tmp_path / "src"
    git("init", "-q", "--bare", str(remote))
    git("init", "-q", "-b", "main", str(src))
    base = commit(src, "base")
    git("push", "-q", str(remote), "main", cwd=src)
    old = commit(src, "old-run")
    git("push", "-q", str(remote), f"HEAD:{BRANCH}", cwd=src)
    git("checkout", "-q", "-B", "agent/issue-7", base, cwd=src)
    new = commit(src, "new-run")
    git("bundle", "create", str(tmp_path / "work.bundle"), f"^{base}", "agent/issue-7", cwd=src)
    other = git("commit-tree", "-p", old, "-m", "someone else", f"{old}^{{tree}}", cwd=src)
    git("push", "-q", str(remote), f"{other}:refs/heads/elsewhere", cwd=src)
    return {"tmp": tmp_path, "remote": remote, "base": base, "old": old, "new": new, "other": other}


def push(lane, open_prs, pr="", move_to=""):
    tmp = lane["tmp"]
    bin_dir = tmp / "bin"
    bin_dir.mkdir()
    (bin_dir / "gh").write_text(FAKE_GH)
    (bin_dir / "git").write_text(MOVE_THEN_GIT)
    for f in ("gh", "git"):
        (bin_dir / f).chmod(0o755)
    (tmp / "data.json").write_text(json.dumps({OPEN: open_prs, "repos/o/r/issues/7": {"title": "t"}, "repos/o/r/pulls/12": {"body": ""}}))
    (tmp / "gh.log").touch()
    env = {"PATH": f"{bin_dir}:{os.environ['PATH']}", "REAL_PATH": os.environ["PATH"], "HOME": str(tmp),
           "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": f"url.file://{lane['remote']}.insteadOf",
           "GIT_CONFIG_VALUE_0": "https://github.com/o/r.git", "GH_DATA": str(tmp / "data.json"),
           "GH_LOG": str(tmp / "gh.log"), "RUNNER_TEMP": str(tmp), "REPO": "o/r", "GITHUB_REPOSITORY": "o/r",
           "GITHUB_SERVER_URL": "https://github.com", "GITHUB_RUN_ID": "1", "ISSUE": "7", "PR": pr,
           "BASE": lane["base"], "PROOF": "run-proof: x -> 1 passed", "REMOTE": str(lane["remote"]), "MOVE_TO": move_to}
    proc = subprocess.run(["bash", "-e", "-c", push_step()], env=env, capture_output=True, text=True, check=False)
    return proc, git("--git-dir", str(lane["remote"]), "rev-parse", BRANCH)


def test_an_issue_run_replaces_a_branch_left_by_a_closed_pr(lane):
    proc, head = push(lane, [])
    assert proc.returncode == 0, proc.stderr
    assert head == lane["new"]


def test_an_issue_run_keeps_a_branch_an_open_pr_uses(lane):
    proc, head = push(lane, [{"number": 12}])
    assert proc.returncode != 0
    assert head == lane["old"]


def test_a_review_round_replays_on_a_moved_branch(lane):
    # c94e3e77 made a review round push fast-forward only, so a branch that moved since
    # the claim read it parked the answer: runs 43398695693 and 43400589073 both worked
    # agent/issue-11959, the second read "fetch first", and the alert
    # AgentRunFailureShare counted the run. The answer still forces nothing: it replays
    # on the moved branch, whose commits stay first.
    proc, head = push(lane, [], pr="12")
    assert proc.returncode == 0, proc.stderr
    assert head != lane["old"]
    assert git("--git-dir", str(lane["remote"]), "rev-parse", f"{BRANCH}^") == lane["old"]


def test_a_branch_moved_after_the_read_fails_the_lease(lane):
    proc, head = push(lane, [], move_to=lane["other"])
    assert proc.returncode != 0
    assert "stale info" in proc.stderr
    assert head == lane["other"]


def test_a_first_run_creates_the_branch(lane):
    git("--git-dir", str(lane["remote"]), "update-ref", "-d", BRANCH)
    proc, head = push(lane, [])
    assert proc.returncode == 0, proc.stderr
    assert head == lane["new"]


def claim_step():
    return next(s for s in WF["jobs"]["claim"]["steps"] if s.get("id") == "claim")["run"]


PULLS = "repos/o/r/pulls?head=o:agent/issue-7&state=open"
EDIT = ["issue", "edit", "7", "-R", "o/r", "--remove-label", "agent-ready", "--add-label", "agent-in-progress"]


def test_the_claim_stops_before_the_label_swap_when_an_open_pr_uses_the_branch(tmp_path):
    proc, _, calls = run_step(tmp_path, claim_step(), {PULLS: [{"number": 12}]}, ISSUE="7")
    assert proc.returncode != 0
    assert calls == [["api", PULLS, "--jq", "length"]]


def test_the_claim_labels_the_ticket_only_after_the_guard_clears(tmp_path):
    proc, _, calls = run_step(tmp_path, claim_step(), {PULLS: []}, ISSUE="7")
    assert proc.returncode == 0, proc.stderr
    assert calls[0] == ["api", PULLS, "--jq", "length"]
    assert calls[1] == EDIT
