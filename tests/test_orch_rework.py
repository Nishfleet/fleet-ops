"""fleet-ops#10435: a coordinator PR (orch/issue-N) whose review blocked goes back to the orchestrator.

Runs the real `run:` blocks (read out with yq) against a stub `gh` and a real git mirror:
the review job's send-back step, the orchestrate job's `issue` step (continue on an open PR, or on a branch with no PR at all,
instead of skipping) and its worktree step (start from the branch head)."""
import json
import os
import pathlib
import stat
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
GH_STUB = """#!/bin/bash
echo "$*" >> "$GH_LOG"
if [ "${GH_ISSUE_VIEW_FAIL:-0}" != 0 ]; then case "$*" in "issue view"*) exit 1 ;; esac; fi
case "$*" in
  "pr view"*) while [ $# -gt 0 ] && [ "$1" != --jq ]; do shift; done; jq -r "$2" <<<"$GH_PR_JSON" ;;
  "api --paginate"*) printf '%b' "$GH_REVIEWS" ;;
  "issue view"*) echo "$GH_LABELS" ;;
  "api repos/"*"/git/ref/heads/"*) exit "$GH_REF_EXISTS" ;;
  "api repos/"*"/issues/"*) echo 0 ;;
  "api repos/"*"/pulls"*) [ "${GH_PULLS_FAIL:-0}" = 0 ] || exit 1; while [ $# -gt 0 ] && [ "$1" != --jq ]; do shift; done; jq -r "$2" <<<"$GH_PULLS" ;;
  "issue edit"*|"issue comment"*) if [ -n "${ISSUE_TOKEN:-}" ] && [ "${GH_TOKEN:-}" != "$ISSUE_TOKEN" ]; then echo "403 the write must carry the App token, so its label fires the dispatch: $*" >&2; exit 1; fi
    # Real gh refuses the whole edit when the label is not on the repo: GH_HAS_LABELS is that repo's labels, and a label this run created counts too.
    for ((i = 1; i <= $#; i++)); do
      [ "${!i}" != --remove-label ] || { j=$((i + 1)); l=${!j}
        grep -q "^label create $l " "$GH_LOG" && continue
        case " ${GH_HAS_LABELS-needs-orchestrator handoff-ended agent-ready needs-nish-decision} " in *" $l "*) continue ;; esac
        echo "'$l' not found" >&2; exit 1; }
    done ;;
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


def _y(expr):
    out = subprocess.run(["yq", expr, str(ROOT / ".github/workflows/agent.yml")], check=True, capture_output=True, text=True).stdout.strip()
    assert out and out != "null", expr
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
    env = {**os.environ, "PATH": f"{bin_}:{os.environ['PATH']}", "GH_LOG": str(log), "REPO": "Nishfleet/fleet-ops", "GITHUB_SERVER_URL": "https://github.com", "GH_TOKEN": "the-app-token"}
    env.update(extra)
    return env, log


SHA = "a" * 40
OTHER = "b" * 40


def _review(tmp_path, ref="orch/issue-77", reviews=(SHA,), labels="", cross=False, **extra):
    body = "".join(f"{s}\n" for s in reviews)
    pr = json.dumps({"headRefName": ref, "isCrossRepository": cross})
    return _env(tmp_path, PR="5", SHA=SHA, GH_PR_JSON=pr, GH_REVIEWS=body, GH_LABELS=labels,
                GH_TOKEN="job-token", ISSUE_TOKEN="app-token", **extra)


SEND = ("agent.yml", "review", "Send a blocked orch PR back to the orchestrator")


def _issue_env(tmp_path, exists, pulls, pulls_fail=False):
    env, log = _env(tmp_path, ISSUE="77", GH_REF_EXISTS=str(0 if exists else 1), GH_PULLS=json.dumps([{"state": x, "number": i + 1} for i, x in enumerate(pulls)]),
                    GH_LABELS="needs-orchestrator", GITHUB_RUN_ID="1", DAILY_MAX="0", MODEL_VAR="", RUNNER_VAR="", GITHUB_OUTPUT=str(tmp_path / "out"))
    gh = tmp_path / "bin/gh"
    gh.write_text(gh.read_text().replace('"issue view"*) echo "$GH_LABELS" ;;', '"issue view"*"state"*) echo OPEN ;;\n  "issue view"*) echo "$GH_LABELS" ;;'))
    if pulls_fail:
        env["GH_PULLS_FAIL"] = "1"
    return env, log


def test_the_stub_refuses_a_parking_write_that_does_not_carry_the_app_token(tmp_path):
    env, _ = _env(tmp_path, ISSUE="77", ISSUE_TOKEN="app-token", GH_TOKEN="the-jobs-token")
    refused = subprocess.run([str(tmp_path / "bin/gh"), "issue", "edit", "77"], env=env, capture_output=True, text=True)
    assert refused.returncode == 1 and "403" in refused.stderr
    env["GH_TOKEN"] = "app-token"
    assert subprocess.run([str(tmp_path / "bin/gh"), "issue", "edit", "77"], env=env).returncode == 0


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

