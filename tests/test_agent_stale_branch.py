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
           "BASE": lane["base"], "DEFAULT_BRANCH": "main", "PROOF": "run-proof: x -> 1 passed",
           "REMOTE": str(lane["remote"]), "MOVE_TO": move_to}
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


def test_a_review_round_pushes_fast_forward_only(lane):
    proc, head = push(lane, [], pr="12")
    assert proc.returncode != 0
    assert head == lane["old"]


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


def repo_step():
    return next(s for s in WF["jobs"]["claim"]["steps"] if s.get("id") == "repo")["run"]


# A fix round on a pull request whose branch predates a newer default-branch commit: main
# moved on after the branch's old round (W1) forked, so a merge of the default branch puts
# commits in the work bundle whose prerequisites reach below BASE (fleet-ops#11973,
# run 43378639058: "Repository lacks these prerequisite commits").
@pytest.fixture
def conflict(tmp_path):
    remote, src, c = tmp_path / "remote.git", tmp_path / "src", tmp_path / "checkout"
    git("init", "-q", "--bare", "-b", "main", str(remote))
    git("init", "-q", "-b", "main", str(src))
    commit(src, "base")
    git("push", "-q", str(remote), "main", cwd=src)
    git("clone", "-q", str(remote), str(c))
    git("switch", "-qC", "agent/issue-7", cwd=c)
    base = commit(c, "old-round")
    git("push", "-q", str(remote), "agent/issue-7", cwd=c)
    commit(src, "new-main-1")
    main_tip = commit(src, "new-main-2")
    git("push", "-q", str(remote), "main", cwd=src)
    # The fix round checks out the PR head with the full history (fetch-depth: 0), so
    # origin/main is at the moved-on tip while HEAD stays on the branch.
    git("fetch", "-q", "origin", cwd=c)
    return {"tmp": tmp_path, "remote": remote, "checkout": c, "base": base, "main": main_tip}


def bundle_step(lane):
    """Run the claim job's bundle step as written, in the checkout, against a fake gh."""
    bin_dir, out = lane["tmp"] / "claim-bin", lane["tmp"] / "claim-out"
    bin_dir.mkdir()
    (bin_dir / "gh").write_text(FAKE_GH)
    (bin_dir / "gh").chmod(0o755)
    (lane["tmp"] / "data.json").write_text(json.dumps({"repos/o/r": {"default_branch": "main"}}))
    out.touch()
    env = {"PATH": f"{bin_dir}:{os.environ['PATH']}", "GH_DATA": str(lane["tmp"] / "data.json"),
           "GH_LOG": str(lane["tmp"] / "gh.log"), "GITHUB_OUTPUT": str(out), "RUNNER_TEMP": str(lane["tmp"]),
           "REPO": "o/r", "GITHUB_REPOSITORY": "o/r", "GITHUB_SERVER_URL": "https://github.com",
           "GITHUB_RUN_ID": "1", "ISSUE": "7"}
    proc = subprocess.run(["bash", "-e", "-c", repo_step()], env=env, cwd=lane["checkout"],
                          capture_output=True, text=True, check=False)
    return proc, out.read_text()


def worker(lane, merge):
    """The worker's clone from the bundle, then its work bundle, as the work job bundles it."""
    work = lane["tmp"] / "work"
    git("clone", "-q", "--branch", "agent/issue-7", str(lane["tmp"] / "repo.bundle"), str(work))
    if merge:
        # What the packet asks for: merge origin/<default branch>, no rebase. The clone maps
        # only the bundle's refs/heads/*, so the default branch arrives by the extra fetch.
        git("fetch", "-q", str(lane["tmp"] / "repo.bundle"),
            "refs/remotes/origin/main:refs/remotes/origin/main", cwd=work)
        git("merge", "-q", "--no-edit", "origin/main", cwd=work)
    head = commit(work, "the-fix")
    git("bundle", "create", str(lane["tmp"] / "work.bundle"), f"^{lane['base']}", "agent/issue-7", cwd=work)
    return head


def test_a_conflict_fix_that_merges_the_default_branch_pushes_fast_forward(conflict):
    proc, out = bundle_step(conflict)
    assert proc.returncode == 0, proc.stderr
    assert out == f"base={conflict['base']}\ndefault_branch=main\n"
    heads = git("bundle", "list-heads", str(conflict["tmp"] / "repo.bundle"))
    assert "refs/remotes/origin/main" in heads
    assert conflict["main"] in heads
    head = worker(conflict, merge=True)
    # PR=12 pushes without force, so a success is a fast-forward by construction.
    proc, pushed = push(conflict, [], pr="12")
    assert proc.returncode == 0, proc.stderr
    assert pushed == head


def test_the_plain_case_without_a_merge_still_pushes(conflict):
    bundle_step(conflict)
    head = worker(conflict, merge=False)
    proc, pushed = push(conflict, [], pr="12")
    assert proc.returncode == 0, proc.stderr
    assert pushed == head


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
