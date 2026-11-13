"""A fresh issue run replaces its lane's old branch unless an open PR uses it.

Run 41846745347 (issue 11723) lost its push to "(fetch first)": agent/issue-11723 still held
the head of closed PR #11730. The push step runs here as written in agent.yml, with real git
against a local bare repo (github.com rewritten by url.<base>.insteadOf) and a fake `gh`.
Run 43378639058 then lost its push to "Repository lacks these prerequisite commits": a fix
round whose worker merged the default branch makes the work bundle's prerequisites the
branch's boundary commits, so the push repo needs the default branch's history too, and the
claim bundle must hand the worker origin/<default> without network (fleet-ops#11973). The
claim bundle step, the worker's clone and merge, the work bundle step and the push step run
here as written, the same way.
https://git-scm.com/docs/git-push#Documentation/git-push.txt---force-with-leaseltrefnamegt
https://git-scm.com/docs/git-config#Documentation/git-config.txt-urlltbasegtinsteadOf
https://git-scm.com/docs/git-bundle
https://git-scm.com/docs/partial-clone
https://docs.github.com/en/rest/pulls/pulls#list-pull-requests
"""
import json
import os
import subprocess
from pathlib import Path

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
           "BASE": lane["base"], "DEFAULT": "main", "PROOF": "run-proof: x -> 1 passed",
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


def claim_bundle_step():
    return next(s for s in WF["jobs"]["claim"]["steps"] if s.get("id") == "repo")["run"]


def work_bundle_step():
    return next(s for s in WF["jobs"]["work"]["steps"] if s.get("name", "").startswith("Bundle what the worker left"))["run"]


@pytest.fixture
def stale(tmp_path):
    """A fix round on a stale PR: main moved after agent/issue-7 was cut, so a worker that
    merges the default branch carries commits the push repo has never seen (fleet-ops#11973)."""
    remote, src = tmp_path / "remote.git", tmp_path / "src"
    git("init", "-q", "--bare", str(remote))
    # the bare remote opts into object filters the way GitHub does, for the blob-less fetch
    git("-C", str(remote), "config", "uploadpack.allowFilter", "true")
    git("init", "-q", "-b", "main", str(src))
    base = commit(src, "base")
    git("checkout", "-q", "-b", "agent/issue-7", cwd=src)
    old = commit(src, "old-run")
    git("push", "-q", str(remote), "agent/issue-7", cwd=src)
    git("checkout", "-q", "main", cwd=src)
    newer = commit(src, "newer-main")
    git("push", "-q", str(remote), "main", cwd=src)
    # the claim checkout holds the default branch as a remote-tracking ref (fetch-depth: 0),
    # the branch tip is its head, and there is no local main on a PR run
    git("update-ref", "refs/remotes/origin/main", newer, cwd=src)
    git("checkout", "-q", "agent/issue-7", cwd=src)
    return {"tmp": tmp_path, "remote": remote, "src": src, "base": base, "old": old, "newer": newer}


def run_pipeline(stale, merge):
    """The claim bundle step, the worker's clone and task, the work bundle step and the push
    step, each as written in agent.yml, with real git and a fake `gh`."""
    tmp = stale["tmp"]
    bin_dir = tmp / "bin"
    bin_dir.mkdir()
    (bin_dir / "gh").write_text(FAKE_GH)
    (bin_dir / "git").write_text(MOVE_THEN_GIT)
    for f in ("gh", "git"):
        (bin_dir / f).chmod(0o755)
    (tmp / "data.json").write_text(json.dumps({
        OPEN: [], "repos/o/r": {"default_branch": "main"},
        "repos/o/r/issues/7": {"title": "t"}, "repos/o/r/pulls/12": {"body": ""}}))
    (tmp / "gh.log").touch()
    (tmp / "issue.md").write_text("the task\n")
    (tmp / "run-proof.md").write_text("run-proof: pytest -> 1 passed\n")
    env = {"PATH": f"{bin_dir}:{os.environ['PATH']}", "REAL_PATH": os.environ["PATH"], "HOME": str(tmp),
           "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": f"url.file://{stale['remote']}.insteadOf",
           "GIT_CONFIG_VALUE_0": "https://github.com/o/r.git", "GH_DATA": str(tmp / "data.json"),
           "GH_LOG": str(tmp / "gh.log"), "RUNNER_TEMP": str(tmp), "REPO": "o/r", "GITHUB_REPOSITORY": "o/r",
           "GITHUB_SERVER_URL": "https://github.com", "GITHUB_RUN_ID": "1", "ISSUE": "7", "PR": "12",
           "MOVE_TO": "", "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
    out = tmp / "out"
    out.touch()

    def run(script, cwd=None, **extra):
        return subprocess.run(["bash", "-e", "-c", script], cwd=cwd,
                              env={**env, "GITHUB_OUTPUT": str(out), **extra},
                              capture_output=True, text=True, check=False)

    # claim: the bundle step, on the checkout it left (branch checked out, origin/* fetched)
    proc = run(claim_bundle_step(), cwd=str(stale["src"]))
    assert proc.returncode == 0, proc.stderr
    claim = dict(line.split("=", 1) for line in out.read_text().splitlines())
    assert claim == {"base": stale["old"], "default": "main"}

    # the worker: clone from the bundle, as the Worker step clones, then do the task
    work = tmp / "work"
    git("clone", "-q", "--branch", "agent/issue-7", str(tmp / "repo.bundle"), str(work))
    # the bundle gave the worker the default branch without any network
    assert git("rev-parse", "refs/remotes/origin/main", cwd=work) == stale["newer"]
    if merge:
        git("merge", "-q", "--no-edit", "origin/main", cwd=work)
        # a merge, not a rebase: the branch tip keeps the old remote head as its first parent
        assert git("rev-list", "--parents", "-n1", "HEAD", cwd=work).split()[1:] == [stale["old"], stale["newer"]]
    else:
        (work / "worker-change").write_text("worker-change")
        git("add", "worker-change", cwd=work)
        git("commit", "-qm", "worker change", cwd=work)

    # the work job bundles what the worker left; the push job pushes it
    proc = run(work_bundle_step(), dir=str(work), BASE=claim["base"])
    assert proc.returncode == 0, proc.stderr
    proc = run(push_step(), BASE=claim["base"], DEFAULT=claim["default"], PROOF="run-proof: pytest -> 1 passed")
    assert proc.returncode == 0, proc.stderr
    # the push repo holds the default branch's history, fetched without file contents
    assert git("rev-parse", "refs/heads/default", cwd=tmp / "push") == stale["newer"]
    return git("rev-parse", "HEAD", cwd=work), git("--git-dir", str(stale["remote"]), "rev-parse", BRANCH)


def test_a_fix_round_that_merged_the_default_branch_pushes_a_fast_forward(stale):
    tip, head = run_pipeline(stale, merge=True)
    assert head == tip  # the pushed head is the merge, so the push was a fast-forward
    assert head != stale["old"]


def test_the_plain_case_without_a_merge_still_pushes(stale):
    tip, head = run_pipeline(stale, merge=False)
    assert head == tip


ENV_KEYS = ("PATH", "REAL_PATH", "HOME", "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0",
            "GIT_CONFIG_VALUE_0", "GH_DATA", "GH_LOG", "RUNNER_TEMP", "REPO",
            "GITHUB_REPOSITORY", "GITHUB_SERVER_URL", "GITHUB_RUN_ID", "ISSUE", "PR",
            "MOVE_TO", "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME",
            "GIT_COMMITTER_EMAIL")


@pytest.fixture
def env(stale, tmp_path):
    """The claim job's env, with a fake `gh` on PATH, as run_pipeline's."""
    tmp = stale["tmp"]
    bin_dir = tmp / "bin"
    bin_dir.mkdir()
    (bin_dir / "gh").write_text(FAKE_GH)
    (bin_dir / "git").write_text(MOVE_THEN_GIT)
    for f in ("gh", "git"):
        (bin_dir / f).chmod(0o755)
    (tmp / "data.json").write_text(json.dumps({
        OPEN: [], "repos/o/r": {"default_branch": "main"},
        "repos/o/r/issues/7": {"title": "t"}, "repos/o/r/pulls/12": {"body": ""}}))
    (tmp / "gh.log").touch()
    (tmp / "issue.md").write_text("the task\n")
    (tmp / "run-proof.md").write_text("run-proof: pytest -> 1 passed\n")
    return {"PATH": f"{bin_dir}:{os.environ['PATH']}", "REAL_PATH": os.environ["PATH"], "HOME": str(tmp),
            "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": f"url.file://{stale['remote']}.insteadOf",
            "GIT_CONFIG_VALUE_0": "https://github.com/o/r.git", "GH_DATA": str(tmp / "data.json"),
            "GH_LOG": str(tmp / "gh.log"), "RUNNER_TEMP": str(tmp), "REPO": "o/r",
            "GITHUB_REPOSITORY": "o/r", "GITHUB_SERVER_URL": "https://github.com",
            "GITHUB_RUN_ID": "1", "ISSUE": "7", "PR": "12", "MOVE_TO": "",
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
            "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}


def run_in(env, script, cwd, **extra):
    out = Path(env["RUNNER_TEMP"]) / "outputs"
    out.write_text("")
    proc = subprocess.run(["bash", "-e", "-c", script], cwd=cwd,
                          env={**env, "GITHUB_OUTPUT": str(out), **extra},
                          capture_output=True, text=True, check=False)
    outputs = dict(line.split("=", 1) for line in out.read_text().splitlines() if line)
    return proc, outputs


# fleet-ops#12008: the round-3 task says "say in the commit message why a finding is
# wrong", so a worker may deliver its answer as a commit that changes no file. The bundle
# step counts the commits the branch carries, not tree differences: a zero-diff verdict
# commit is a delivered answer that bundles and pushes, and only a branch with no commit
# at all is "the worker changed nothing".
# https://git-scm.com/docs/git-rev-list
def test_a_verdict_commit_is_an_answer_the_bundle_pushes(stale, env):
    proc, claim = run_in(env, claim_bundle_step(), cwd=str(stale["src"]))
    assert proc.returncode == 0, proc.stderr
    git("commit", "-q", "--allow-empty", "-m", "the findings are already addressed",
        cwd=stale["src"])
    proc, outputs = run_in(env, work_bundle_step(), cwd=stale["src"], dir=str(stale["src"]),
                           BASE=claim["base"])
    assert proc.returncode == 0, proc.stderr
    assert outputs == {"proof": "run-proof: pytest -> 1 passed"}
    heads = subprocess.run(["git", "bundle", "list-heads", str(stale["tmp"] / "work.bundle")],
                           check=True, capture_output=True, text=True).stdout
    assert "agent/issue-7" in heads


def test_a_worker_that_left_no_commit_is_still_nochange(stale, env):
    proc, claim = run_in(env, claim_bundle_step(), cwd=str(stale["src"]))
    assert proc.returncode == 0, proc.stderr
    proc, outputs = run_in(env, work_bundle_step(), cwd=stale["src"], dir=str(stale["src"]),
                           BASE=claim["base"])
    assert proc.returncode == 0, proc.stderr
    assert outputs == {"proof": "run-proof: pytest -> 1 passed", "nochange": "true"}
    assert not (stale["tmp"] / "work.bundle").exists()
