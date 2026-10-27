"""fleet-ops#10435: a coordinator PR (orch/issue-N) whose review blocked goes back to the orchestrator.

Runs the real `run:` blocks (read out with yq) against a stub `gh` and a real git mirror:
the review job's send-back step, the orchestrate job's `issue` step (continue on an open PR
instead of skipping) and its worktree step (start from the PR head)."""
import os
import pathlib
import stat
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
GH_STUB = """#!/bin/bash
echo "$*" >> "$GH_LOG"
case "$*" in
  "pr view"*) echo "$GH_REF" ;;
  "api --paginate"*) printf '%b' "$GH_REVIEWS" ;;
  "issue view"*) echo "$GH_LABELS" ;;
  "pr list"*) echo "$GH_OPEN_PRS" ;;
  "api repos/"*"/git/ref/heads/"*) exit "$GH_REF_EXISTS" ;;
esac
exit 0
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


def _review(tmp_path, ref="orch/issue-77", reviews=(SHA,), labels=""):
    body = "".join(f"{s}\n" for s in reviews)
    return _env(tmp_path, PR="5", SHA=SHA, GH_REF=ref, GH_REVIEWS=body, GH_LABELS=labels)


SEND = ("agent.yml", "review", "Send a blocked orch PR back to the orchestrator")


def test_a_blocked_orch_pr_puts_needs_orchestrator_back_on_its_issue(tmp_path):
    env, log = _review(tmp_path)
    r = _run(_block(*SEND), env)
    assert r.returncode == 0, r.stderr
    calls = log.read_text()
    assert "issue edit 77 -R Nishfleet/fleet-ops --add-label needs-orchestrator" in calls
    assert "issue comment 77" in calls and "pull/5" in calls


@pytest.mark.parametrize("case", ["not-orch", "no-block-for-this-head", "already-labelled"])
def test_nothing_is_sent_back_when_it_does_not_apply(tmp_path, case):
    kw = {"not-orch": {"ref": "claim/issue-77"}, "no-block-for-this-head": {"reviews": (OTHER,)}, "already-labelled": {"labels": "1"}}[case]
    env, log = _review(tmp_path, **kw)
    assert _run(_block(*SEND), env).returncode == 0
    assert "issue edit" not in log.read_text()


def test_the_fourth_block_goes_to_nish_not_back_to_the_orchestrator(tmp_path):
    env, log = _review(tmp_path, reviews=(OTHER, OTHER, OTHER, SHA))
    assert _run(_block(*SEND), env).returncode == 0
    calls = log.read_text()
    assert "--add-label needs-nish-decision" in calls
    assert "--add-label needs-orchestrator" not in calls


def test_three_blocks_still_get_a_rework_round(tmp_path):
    env, log = _review(tmp_path, reviews=(OTHER, OTHER, SHA))
    assert _run(_block(*SEND), env).returncode == 0
    assert "--add-label needs-orchestrator" in log.read_text()


def _issue_env(tmp_path, exists, open_prs):
    env, log = _env(tmp_path, ISSUE="77", GH_REF_EXISTS=str(0 if exists else 1), GH_OPEN_PRS=str(open_prs),
                    GH_LABELS="needs-orchestrator", RUN_ID="1", DAILY_MAX="0", MODEL_VAR="", RUNNER_VAR="", GITHUB_OUTPUT=str(tmp_path / "out"))
    # `gh issue view --json state` and `--json labels` both print GH_LABELS; the step wants OPEN first.
    gh = tmp_path / "bin/gh"
    gh.write_text(gh.read_text().replace('"issue view"*) echo "$GH_LABELS" ;;', '"issue view"*"state"*) echo OPEN ;;\n  "issue view"*) echo "$GH_LABELS" ;;'))
    return env, log


ISSUE_STEP = ("agent-dispatch.yml", "orchestrate", "Check the issue is still parked")


@pytest.mark.parametrize("exists,open_prs,go", [(True, 1, True), (True, 0, False), (False, 0, True)])
def test_issue_step_continues_on_a_branch_with_an_open_pr_and_skips_one_without(tmp_path, exists, open_prs, go):
    env, _ = _issue_env(tmp_path, exists, open_prs)
    r = _run(_block(*ISSUE_STEP), env)
    assert r.returncode == 0, r.stderr
    out = (tmp_path / "out").read_text() if (tmp_path / "out").exists() else ""
    assert ("go=true" in out) is go, r.stdout


def _git(*args, cwd):
    subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *args], cwd=cwd, check=True, capture_output=True)


def test_worktree_step_starts_from_the_pr_head_on_origin(tmp_path):
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
    env = {**os.environ, "HOME": str(home), "REPO": "Nishfleet/fleet-ops", "ISSUE": "77", "GITHUB_OUTPUT": str(tmp_path / "out"),
           "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": f"url.{seed}.insteadOf", "GIT_CONFIG_VALUE_0": "https://github.com/Nishfleet/fleet-ops.git"}
    block = _block("agent-dispatch.yml", "orchestrate", "Fresh worktree on origin/main")
    for _ in range(2):  # second run: the local branch exists already and is reset to the origin head
        r = _run(block, env)
        assert r.returncode == 0, r.stderr
        wt = home / "workspaces/agent-worktrees/orch-fleet-ops-77"
        log = subprocess.run(["git", "log", "--format=%s", "-1"], cwd=wt, capture_output=True, text=True, check=True).stdout.strip()
        assert log == "pushed fix attempt"
