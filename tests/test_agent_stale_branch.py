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


# fleet-ops#12004: a fix round on a branch behind its default branch starts with the default
# branch already merged in by the Worker step itself, before any engine runs (run 43473108129:
# the senior builder's sandbox keeps .claude/skills read-only and the packet-told `git merge`
# died on it, so nothing was committed and the push failed with "the worker changed nothing").
# A merge is deterministic and needs no model; only resolving a conflict does. The Worker step
# and the Bundle step run here as written in agent.yml, with real git against the claim bundle
# and a stub engine on PATH, the same way test_agent_worker_engine_output.py runs the step.
# https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/proposing-changes-to-your-work-with-pull-requests/keeping-your-pull-request-in-sync-with-the-base-branch
# https://git-scm.com/docs/git-merge
CONFLICT_SENTENCE = ("A merge of the default branch is in progress and has conflicts. Resolve every conflicted "
                     "file, keeping both sides' entries in shared lists such as sitemaps and fingerprint "
                     "files, then commit the merge. Do not abort it and do not rebase.")


def worker_step():
    return next(s for s in WF["jobs"]["work"]["steps"] if s.get("name") == "Worker")["run"]


def fix_round(tmp_path, *, conflict=False, up_to_date=False):
    """A fix round ($PR set): a checkout whose branch is behind the default branch (conflict:
    in one shared file, sitemap.txt) or cut from its tip (up_to_date). The claim bundle step
    runs as written to build repo.bundle; the runner then runs the Worker step as written with
    a stub pi engine that first records what it starts on."""
    remote, src = tmp_path / "remote.git", tmp_path / "src"
    git("init", "-q", "--bare", str(remote))
    git("init", "-q", "-b", "main", str(src))
    if conflict:
        (src / "sitemap.txt").write_text("base\n")
        git("add", "sitemap.txt", cwd=src)
    else:
        (src / "base-file").write_text("base\n")
        git("add", "base-file", cwd=src)
    git("commit", "-qm", "base", cwd=src)
    main_tip = git("rev-parse", "HEAD", cwd=src)
    git("checkout", "-q", "-B", "agent/issue-7", main_tip, cwd=src)
    if conflict:
        (src / "sitemap.txt").write_text("branch side\n")
        git("commit", "-qam", "branch side", cwd=src)
    else:
        (src / "branch-file").write_text("branch\n")
        git("add", "branch-file", cwd=src)
        git("commit", "-qm", "branch side", cwd=src)
    old = git("rev-parse", "HEAD", cwd=src)
    git("push", "-q", str(remote), "agent/issue-7", cwd=src)
    if not up_to_date:
        git("checkout", "-q", "main", cwd=src)
        if conflict:
            (src / "sitemap.txt").write_text("main side\n")
            git("commit", "-qam", "main side", cwd=src)
        else:
            (src / "main-file").write_text("main\n")
            git("add", "main-file", cwd=src)
            git("commit", "-qm", "main side", cwd=src)
        main_tip = git("rev-parse", "HEAD", cwd=src)
        git("push", "-q", str(remote), "main", cwd=src)
    # the claim checkout holds the default branch as a remote-tracking ref (fetch-depth: 0)
    git("update-ref", "refs/remotes/origin/main", main_tip, cwd=src)
    git("checkout", "-q", "agent/issue-7", cwd=src)

    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    (bin_dir / "gh").write_text(FAKE_GH)
    (bin_dir / "gh").chmod(0o755)
    (tmp_path / "data.json").write_text(json.dumps({"repos/o/r": {"default_branch": "main"}}))
    (tmp_path / "gh.log").touch()
    (tmp_path / "out").touch()
    (tmp_path / "github_env").touch()
    (tmp_path / "home").mkdir()
    env = {"PATH": f"{bin_dir}:{os.environ['PATH']}", "GH_DATA": str(tmp_path / "data.json"),
           "GH_LOG": str(tmp_path / "gh.log"), "GITHUB_OUTPUT": str(tmp_path / "out"),
           "RUNNER_TEMP": str(tmp_path), "REPO": "o/r", "GITHUB_REPOSITORY": "o/r", "ISSUE": "7"}
    proc = subprocess.run(["bash", "-e", "-c", claim_bundle_step()], cwd=str(src), env=env,
                          capture_output=True, text=True, check=False)
    assert proc.returncode == 0, proc.stderr

    def run(engine_script, pr="12"):
        stub = bin_dir / "pi"
        stub.write_text(f"#!/bin/sh\ncat > /dev/null\n{engine_script}\necho verdict\n")
        stub.chmod(0o755)
        return subprocess.run(["bash", "-e", "-c", worker_step()],
                              env={**env, "GITHUB_ENV": str(tmp_path / "github_env"), "HOME": str(tmp_path / "home"),
                                   "GITHUB_RUN_ID": "1", "ENGINE": "pi", "PR": pr, "ISSUE_TEXT": "the task\n",
                                   "DEFAULT_BRANCH": "main", "BASE": old},
                              capture_output=True, text=True, check=False)

    return {"tmp": tmp_path, "old": old, "main_tip": main_tip, "run": run}


def test_a_stale_fix_round_merges_the_default_branch_before_the_engine(tmp_path):
    world = fix_round(tmp_path)
    record = 'git rev-list --parents -n1 HEAD > "$RUNNER_TEMP/at-engine"'
    proc = world["run"](record)
    assert proc.returncode == 0, proc.stderr
    # the engine started on the merge commit, whose second parent is the default branch tip
    head, first, second = (world["tmp"] / "at-engine").read_text().split()
    assert [first, second] == [world["old"], world["main_tip"]]
    assert git("rev-parse", "HEAD", cwd=world["tmp"] / "work") == head  # the merge is committed
    packet = (world["tmp"] / "packet.md").read_text()
    assert "Never rebase; the push is fast-forward only." in packet
    assert "merge origin/main into this branch" not in packet
    assert CONFLICT_SENTENCE not in packet


def test_a_conflicting_fix_round_hands_the_engine_the_merge_in_progress(tmp_path):
    world = fix_round(tmp_path, conflict=True)
    record = ('git rev-parse -q --verify MERGE_HEAD > "$RUNNER_TEMP/merge-head" 2>/dev/null || true\n'
              'git diff --name-only --diff-filter=U > "$RUNNER_TEMP/unmerged"')
    proc = world["run"](record)
    # the step survives the conflicted merge, so the engine can resolve it
    assert proc.returncode == 0, proc.stderr
    assert (world["tmp"] / "merge-head").read_text().strip()  # the merge is in progress
    assert (world["tmp"] / "unmerged").read_text().splitlines() == ["sitemap.txt"]
    packet = (world["tmp"] / "packet.md").read_text()
    assert "Never rebase; the push is fast-forward only." in packet
    assert packet.index(CONFLICT_SENTENCE) < packet.index("the task\n")  # the sentence rides ahead of the task


def test_an_engine_that_leaves_a_conflict_unresolved_fails_the_bundle_step(tmp_path):
    world = fix_round(tmp_path, conflict=True)
    proc = world["run"]("")  # the engine prints a verdict and resolves nothing
    assert proc.returncode == 0, proc.stderr
    (world["tmp"] / "bundle-out").touch()
    proc = subprocess.run(["bash", "-e", "-c", work_bundle_step()],
                          env={"PATH": os.environ["PATH"], "RUNNER_TEMP": str(world["tmp"]),
                               "GITHUB_OUTPUT": str(world["tmp"] / "bundle-out"), "dir": str(world["tmp"] / "work"),
                               "BASE": world["old"], "ISSUE": "7"},
                          capture_output=True, text=True, check=False)
    assert proc.returncode != 0
    assert "::error::the worker left merge conflicts unresolved in: sitemap.txt" in proc.stdout
    assert not (world["tmp"] / "work.bundle").exists()  # no bundle: nothing to push


@pytest.mark.parametrize(("behind", "pr"), [(True, ""), (False, "12")],
                         ids=("a first run is never merged", "an up-to-date fix round is never merged"))
def test_no_merge_without_a_pr_or_without_a_stale_branch(tmp_path, behind, pr):
    world = fix_round(tmp_path) if behind else fix_round(tmp_path, up_to_date=True)
    record = 'git rev-list --parents -n1 HEAD > "$RUNNER_TEMP/at-engine"'
    proc = world["run"](record, pr=pr)
    assert proc.returncode == 0, proc.stderr
    # the engine starts on the plain branch tip, one parent: not a merge commit
    fields = (world["tmp"] / "at-engine").read_text().split()
    assert len(fields) == 2 and fields[0] == world["old"]
    packet = (world["tmp"] / "packet.md").read_text()
    assert "Never rebase; the push is fast-forward only." in packet
    assert "merge origin/main into this branch" not in packet
    assert CONFLICT_SENTENCE not in packet
