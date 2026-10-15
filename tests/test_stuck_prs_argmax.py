"""stuck-prs sweep in agent-dispatch.yml: the job's real `run:` block and STUCK
program (read out with yq, never copied) against a fake gh.

A PR whose comments JSON passes the 131072-byte single-argument limit is
judged like any other, and one PR whose verdict errors is skipped with a
warning while the rest are judged and the job still fails at the end.
"""
import json
import os
import pathlib
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
WF = str(ROOT / ".github/workflows/agent-dispatch.yml")
STEP = '.jobs.stuck-prs.steps[] | select(.id == "find")'
MAX_ARG_STRLEN = 131072
OLD = "2026-01-01T00:00:00Z"

FAKE_GH = r"""#!/usr/bin/env bash
case "$1 $2" in
  "api graphql") echo '[]' ;;
  "pr list") cat "$FAKE_DIR/prs.json" ;;
  "pr checks") echo '[]' ;;
  "pr comment") echo "$*" >> "$FAKE_DIR/writes.log" ;;
  "issue list")
    case "$*" in *'Stuck PR'*) echo 0 ;; *) echo '[]' ;; esac ;;
  "api --paginate")
    n=${3#*/issues/}; n=${n%%/*}
    cat "$FAKE_DIR/comments-$n.json" ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 1 ;;
esac
"""


def _y(expr):
    out = subprocess.run(["yq", expr, WF], check=True, capture_output=True, text=True).stdout
    assert out.strip() and out.strip() != "null", expr
    return out


def pr(number):
    return {
        "number": number, "author": {"login": "nish3451"}, "headRefName": f"feature/p{number}",
        "headRefOid": f"{number:040x}", "isDraft": False, "isCrossRepository": False,
        "autoMergeRequest": None, "mergeable": "MERGEABLE", "updatedAt": OLD,
    }


def approval(number):
    return {
        "user": {"login": "github-actions[bot]"}, "body": f"coordinator-approval: {number:040x}",
        "created_at": OLD, "updated_at": OLD, "html_url": f"https://example.invalid/{number}",
    }


def filler(size):
    return {"user": {"login": "someone"}, "body": "x" * size, "created_at": OLD, "updated_at": OLD}


def _run(tmp_path, comments):
    fake = tmp_path / "fake"
    fake.mkdir()
    runner_temp = tmp_path / "runner-temp"
    runner_temp.mkdir()
    home = tmp_path / "home"
    home.mkdir()
    (fake / "prs.json").write_text(json.dumps([pr(n) for n in comments]))
    for n, c in comments.items():
        (fake / f"comments-{n}.json").write_text(json.dumps(c))
    gh = fake / "gh"
    gh.write_text(FAKE_GH)
    gh.chmod(0o755)
    out = tmp_path / "github-output"
    out.write_text("")
    env = {
        **os.environ, "HOME": str(home), "PATH": f"{fake}:{os.environ['PATH']}", "FAKE_DIR": str(fake),
        "GITHUB_REPOSITORY": "o/r", "GH_TOKEN": "x", "RUNNER_TEMP": str(runner_temp), "GITHUB_OUTPUT": str(out),
        "APPROVERS": _y(f"{STEP} | .env.APPROVERS").strip(), "STUCK": _y(f"{STEP} | .env.STUCK"),
    }
    r = subprocess.run(
        ["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", _y(f"{STEP} | .run")],
        env=env, capture_output=True, text=True,
    )
    outputs = dict(line.split("=", 1) for line in out.read_text().splitlines() if "=" in line)
    return r, outputs


def _armed(outputs):
    return sorted(int(x["pr"]) for x in json.loads(outputs["arm"]))


def test_comments_json_over_the_argument_limit_is_judged(tmp_path):
    big = [filler(70000), filler(70000), approval(101)]
    assert len(json.dumps(big)) > MAX_ARG_STRLEN
    r, outputs = _run(tmp_path, {101: big})
    assert r.returncode == 0, r.stdout + r.stderr
    assert "Argument list too long" not in r.stdout + r.stderr
    assert _armed(outputs) == [101]


def test_pr_after_an_oversized_one_is_still_judged(tmp_path):
    big = [filler(70000), filler(70000), approval(101)]
    r, outputs = _run(tmp_path, {101: big, 102: [approval(102)]})
    assert r.returncode == 0, r.stdout + r.stderr
    assert _armed(outputs) == [101, 102]


def test_one_failed_verdict_is_skipped_loudly_and_fails_the_job(tmp_path):
    bad = [{"user": {"login": "someone"}, "body": 5, "created_at": OLD, "updated_at": OLD}]
    r, outputs = _run(tmp_path, {101: [approval(101)], 102: bad, 103: [approval(103)]})
    assert r.returncode != 0
    assert "::warning::#102: verdict failed, skipped" in r.stdout
    assert "::error::1 of 3 waiting PRs errored and were skipped" in r.stdout
    assert _armed(outputs) == [101, 103]


@pytest.mark.parametrize("job", ["stuck-review", "stuck-arm", "stuck-rework", "stuck-file"])
def test_dispatch_jobs_run_after_a_failed_sweep(job):
    cond = " ".join(_y(f'.jobs."{job}".if').split())
    assert cond.startswith("!cancelled() && ")
    assert "needs.stuck-prs.outputs." in cond
