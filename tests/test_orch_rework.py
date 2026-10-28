"""fleet-ops#10435, #10573: a PR whose review blocked goes back to the orchestrator, on its own branch.

Runs the real `run:` blocks (read out with yq) against a stub `gh` and a real git mirror:
the orchestrate job's `issue` step (continue an open PR that closes the issue, on any branch,
instead of skipping) and its worktree step (start from the PR head). The send-back rules
themselves are review/pr_rot.py's, tested in tests/test_pr_rot.py."""
import json
import os
import pathlib
import stat
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
GH_STUB = """#!/bin/bash
echo "$*" >> "$GH_LOG"
case "$*" in
  "pr view"*) while [ $# -gt 0 ] && [ "$1" != --jq ]; do shift; done; jq -r "$2" <<<"$GH_PR_JSON" ;;
  "api --paginate"*) printf '%b' "$GH_REVIEWS" ;;
  "issue view"*) echo "$GH_LABELS" ;;
  "api repos/"*"/git/ref/heads/"*) exit "$GH_REF_EXISTS" ;;
  "api repos/"*"/issues/"*) echo 0 ;;
  "api repos/"*"/pulls"*) [ "${GH_PULLS_FAIL:-0}" = 0 ] || exit 1; echo "$GH_OPEN_PRS" ;;
esac
exit 0
"""
SYSTEMCTL_STUB = """#!/bin/bash
if [ -n "${SYSTEMCTL_STUB:-}" ]; then
  case "$*" in
    *list-units*) printf '%b' "$SYSTEMCTL_STUB" ;;
    *show*WorkingDirectory*) echo "$SYSTEMCTL_WD" ;;
  esac
  exit 0
fi
exec /usr/bin/systemctl "$@"
"""


def _block(workflow, job, step):
    out = subprocess.run(
        ["yq", f'.jobs.{job}.steps[] | select(.name == "{step}") | .run', str(ROOT / ".github/workflows" / workflow)],
        check=True, capture_output=True, text=True,
    ).stdout
    assert out.strip(), f"step {step!r} not found"
    return out


def _run(block, env):
    return subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", block], env=env, capture_output=True, text=True)


def _env(tmp_path, **extra):
    bin_ = tmp_path / "bin"
    bin_.mkdir(exist_ok=True)
    gh = bin_ / "gh"
    gh.write_text(GH_STUB)
    gh.chmod(gh.stat().st_mode | stat.S_IXUSR)
    log = tmp_path / "gh.log"
    log.touch()
    env = {**os.environ, "PATH": f"{bin_}:{os.environ['PATH']}", "GH_LOG": str(log), "REPO": "Nishfleet/fleet-ops", "GITHUB_SERVER_URL": "https://github.com"}
    env.update(extra)
    return env, log


SHA = "a" * 40
OTHER = "b" * 40


SEND = ("agent.yml", "review", "Send a blocked orch PR back to the orchestrator")


def test_the_send_back_runs_the_rot_program_from_main_with_the_runner_login():
    block = _block(*SEND)
    assert "env -u GH_TOKEN -u GITHUB_TOKEN python3 -I" in block
    assert "fleet-ops-deploy-clone/review/pr_rot.py\" --blocked" in block


def _issue_env(tmp_path, exists, open_prs, pulls_fail=False, closing="", pr=None):
    env, log = _env(tmp_path, ISSUE="77", GH_REF_EXISTS=str(0 if exists else 1), GH_OPEN_PRS=str(open_prs), GH_CLOSING=closing, GH_PR_JSON=json.dumps(pr or {}),
                    GH_LABELS="needs-orchestrator", RUN_ID="1", DAILY_MAX="0", MODEL_VAR="", RUNNER_VAR="", GITHUB_OUTPUT=str(tmp_path / "out"))
    gh = tmp_path / "bin/gh"
    gh.write_text(gh.read_text().replace('"issue view"*) echo "$GH_LABELS" ;;', '"issue view"*"state"*) echo OPEN ;;\n  "issue view"*"closedBy"*) echo "$GH_CLOSING" ;;\n  "issue view"*) echo "$GH_LABELS" ;;'))
    if pulls_fail:
        env["GH_PULLS_FAIL"] = "1"
    return env, log


ISSUE_STEP = ("agent-dispatch.yml", "orchestrate", "Check the issue is still parked")


@pytest.mark.parametrize("exists,open_prs,go", [(True, 1, True), (True, 0, False), (False, 0, True)])
def test_issue_step_continues_on_a_branch_with_an_open_pr_and_skips_one_without(tmp_path, exists, open_prs, go):
    env, _ = _issue_env(tmp_path, exists, open_prs)
    r = _run(_block(*ISSUE_STEP), env)
    assert r.returncode == 0, r.stderr
    out = (tmp_path / "out").read_text() if (tmp_path / "out").exists() else ""
    assert ("go=true" in out) is go, r.stdout


def test_issue_step_skips_a_branch_whose_pr_list_cannot_be_read(tmp_path):
    env, log = _issue_env(tmp_path, True, 1, pulls_fail=True)
    r = _run(_block(*ISSUE_STEP), env)
    assert r.returncode == 0, r.stderr
    out = tmp_path / "out"
    assert not out.exists() or "go=true" not in out.read_text()
    assert "the PR list for orch/issue-77 failed; skip" in log.read_text() + r.stdout


@pytest.mark.parametrize("pr,branch", [
    ({"state": "OPEN", "isCrossRepository": False, "headRefName": "strong/issue-77"}, "strong/issue-77"),
    ({"state": "OPEN", "isCrossRepository": True, "headRefName": "strong/issue-77"}, "orch/issue-77"),
    ({"state": "CLOSED", "isCrossRepository": False, "headRefName": "claim/issue-77"}, "orch/issue-77"),
])
def test_issue_step_continues_the_head_branch_of_an_open_pr_that_closes_the_issue(tmp_path, pr, branch):
    env, log = _issue_env(tmp_path, False, 0, closing="9", pr=pr)
    r = _run(_block(*ISSUE_STEP), env)
    assert r.returncode == 0, r.stderr
    out = (tmp_path / "out").read_text()
    assert "go=true" in out and f"branch={branch}\n" in out, r.stdout
    assert "pr view 9 -R Nishfleet/fleet-ops --json state,isCrossRepository,headRefName" in log.read_text()


def test_the_pr_list_asks_the_api_for_pulls_on_this_repo_only(tmp_path):
    env, log = _issue_env(tmp_path, True, 1)
    assert _run(_block(*ISSUE_STEP), env).returncode == 0
    assert "api repos/Nishfleet/fleet-ops/pulls?head=Nishfleet:orch/issue-77&state=open" in log.read_text()


def _git(*args, cwd):
    subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *args], cwd=cwd, check=True, capture_output=True)


def _mirror(tmp_path):
    home = tmp_path / "home"
    (home / "workspaces/agent-worktrees").mkdir(parents=True)
    work = tmp_path / "seed"
    work.mkdir()
    _git("init", "-q", "-b", "main", cwd=work)
    _git("commit", "-q", "--allow-empty", "-m", "base", cwd=work)
    _git("checkout", "-q", "-b", "orch/issue-77", cwd=work)
    _git("commit", "-q", "--allow-empty", "-m", "pushed fix attempt", cwd=work)
    seed = tmp_path / "seed.git"
    _git("clone", "-q", "--bare", str(work), str(seed), cwd=tmp_path)
    bin_ = tmp_path / "bin"
    bin_.mkdir(exist_ok=True)
    sc = bin_ / "systemctl"
    sc.write_text(SYSTEMCTL_STUB)
    sc.chmod(sc.stat().st_mode | stat.S_IXUSR)
    return home, work, seed, {**os.environ, "HOME": str(home), "PATH": f"{bin_}:{os.environ['PATH']}", "REPO": "Nishfleet/fleet-ops", "ISSUE": "77",
                                "GITHUB_OUTPUT": str(tmp_path / "out"), "GIT_CONFIG_COUNT": "1",
                                "GIT_CONFIG_KEY_0": f"url.{seed}.insteadOf", "GIT_CONFIG_VALUE_0": "https://github.com/Nishfleet/fleet-ops.git"}


WORKTREE_STEP = ("agent-dispatch.yml", "orchestrate", "Fresh worktree on origin/main")


def test_worktree_step_starts_from_the_pr_head_on_origin(tmp_path):
    home, _, _, env = _mirror(tmp_path)
    block = _block(*WORKTREE_STEP)
    for _ in range(2):
        r = _run(block, env)
        assert r.returncode == 0, r.stderr
        wt = home / "workspaces/agent-worktrees/orch-fleet-ops-77"
        log = subprocess.run(["git", "log", "--format=%s", "-1"], cwd=wt, capture_output=True, text=True, check=True).stdout.strip()
        assert log == "pushed fix attempt"


def test_worktree_step_checks_out_a_strong_branch_under_its_own_name(tmp_path):
    home, work, seed, env = _mirror(tmp_path)
    _git("checkout", "-q", "-b", "strong/issue-77", "main", cwd=work)
    _git("commit", "-q", "--allow-empty", "-m", "strong attempt", cwd=work)
    _git("push", "-q", str(seed), "strong/issue-77", cwd=work)
    r = _run(_block(*WORKTREE_STEP), {**env, "BRANCH": "strong/issue-77"})
    assert r.returncode == 0, r.stderr
    wt = home / "workspaces/agent-worktrees/orch-fleet-ops-77"
    git = lambda *a: subprocess.run(["git", *a], cwd=wt, capture_output=True, text=True, check=True).stdout.strip()
    assert git("rev-parse", "--abbrev-ref", "HEAD") == "strong/issue-77"
    assert git("log", "--format=%s", "-1") == "strong attempt"


def test_worktree_step_refuses_to_remove_a_tree_a_build_unit_is_building_in(tmp_path):
    home, _, _, env = _mirror(tmp_path)
    wt = str(home / "workspaces/agent-worktrees/orch-fleet-ops-77")
    env["SYSTEMCTL_STUB"] = "orch-fleet-ops-77-build.service loaded active running\n"
    env["SYSTEMCTL_WD"] = wt
    r = _run(_block(*WORKTREE_STEP), env)
    assert r.returncode != 0
    assert "is building in" in r.stderr + r.stdout and "fleet-ops#9377" in r.stderr + r.stdout
    assert not (tmp_path / "out").exists() or "worktree=" not in (tmp_path / "out").read_text()


def test_worktree_step_keeps_the_tree_when_no_unit_holds_it(tmp_path):
    home, _, _, env = _mirror(tmp_path)
    env["SYSTEMCTL_STUB"] = "orch-fleet-ops-77-build.service loaded active running\n"
    env["SYSTEMCTL_WD"] = str(tmp_path / "somewhere-else")
    r = _run(_block(*WORKTREE_STEP), env)
    assert r.returncode == 0, r.stderr
    assert (home / "workspaces/agent-worktrees/orch-fleet-ops-77").is_dir()
