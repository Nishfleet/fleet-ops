"""agent-dispatch.yml's list job: the step's own `run:` block and its
CHECK_DEFS/RED_REWORK/RUN_LIVE_JQ programs, read out with yq and never copied,
driven against a fake gh.

The job runs under the runner's default shell, `bash -e` on Linux, which has no
pipefail. `conflicted`, `missing`, `orphans` and `red` are each a `for`/`while`
loop piped into jq, so the pipeline's status is jq's: the `|| exit 1` written
inside those loops could never fail the step. Nishfleet/drive proved it with a
token that lacked checks:read (run 37166163754, 2026-10-04): the step printed
`GraphQL: Resource not accessible by integration
(repository.pullRequest.statusCheckRollup.nodes.0)`, then
`claim PRs missing required checks: []`, and exited 0. Nothing may be listed or
published after a failed read, so every read fault below must fail the step.

Each fault is confined to one read site, because the sites mask each other: the
conflict read belongs to `conflicted`, the run read to `orphans`, and `red`
also reads every claim PR's status checks, so refusing them all would fail the
step for the wrong reason. The rollup fixture is therefore a fork PR, which
`red` skips on purpose.
"""

import json
import os
import pathlib
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
WF = str(ROOT / ".github/workflows/agent-dispatch.yml")
STEP = '.jobs.list.steps[] | select(.id == "list")'
GREEN = "2026-10-01T00:00:00Z"
ROLLUP_ERR = (
    "GraphQL: Resource not accessible by integration "
    "(repository.pullRequest.statusCheckRollup.nodes.0)"
)
RUN_URL = "https://github.com/o/r/actions/runs/424242"

FAKE_GH = """#!/usr/bin/env bash
q=
for ((i = 1; i <= $#; i++)); do if [ "${!i}" = --jq ]; then j=$((i + 1)); q=${!j}; fi; done
cmd=$1; args=${*:2}; d=$FAKE_DIR
emit() {
  in=$(cat)
  if [ -z "$q" ]; then printf '%s\\n' "$in"; return; fi
  out=$(jq -c "$q" <<<"$in")
  case ${out:0:1} in '[' | '{') printf '%s\\n' "$out" ;; *) jq -r "$q" <<<"$in" ;; esac
}
serve() { [ -f "$1" ] || { echo "mock gh: no fixture for $1" >&2; exit 1; }; emit < "$1"; }
case "$cmd $args" in
  "issue list "*agent-in-progress*) echo '[{"number":7003}]' | emit ;;
  "issue list"*) echo '[]' | emit ;;
  "issue view"*)
    n=${args#view }; n=${n%% *}
    serve "$d/comments-$n.json" ;;
  "pr list "*--head*)
    h=$(sed -n 's/.*--head \\([^ ]*\\).*/\\1/p' <<<"$args")
    jq --arg h "$h" '[.[] | select(.headRefName == $h)] | length' "$d/prs.json" | emit ;;
  "pr list"*) serve "$d/prs.json" ;;
  "pr view"*)
    n=${args#view }; n=${n%% *}
    if [ "${FAIL_READ:-}" = rollup ] && [ "$n" = 8004 ]; then
      echo "__ROLLUP_ERR__" >&2
      exit 1
    fi
    if [ "${FAIL_READ:-}" = conflict ] && [ "$n" = 8002 ] && ! grep -q statusCheckRollup <<<"$args"; then
      echo "gh: refused: pr view $n, mergeable" >&2
      exit 1
    fi
    serve "$d/pr-$n.json" ;;
  "run view"*)
    if [ "${FAIL_READ:-}" = run ]; then echo "gh: refused: run view" >&2; exit 1; fi
    echo '{"status":"completed","jobs":[]}' | emit ;;
  "api graphql"*) echo '{"data":{"repository":{"mergeQueue":{"entries":{"nodes":[]}}}}}' | emit ;;
  "api "*"/issues/"*) serve "$d/api-issue-${args##*/}.json" ;;
  *) echo "mock gh: unexpected call: $cmd $args" >&2; exit 1 ;;
esac
""".replace("__ROLLUP_ERR__", ROLLUP_ERR)


def _y(expr):
    out = subprocess.run(
        ["yq", expr, WF], check=True, capture_output=True, text=True
    ).stdout
    assert out.strip() and out.strip() != "null", expr
    return out


def _issue(n, label):
    return {
        "number": n,
        "created_at": GREEN,
        "state": "open",
        "issue_dependencies_summary": {"blocked_by": 0},
        "labels": [{"name": label}],
    }


def _pr(n, head, mergeable, fork=False):
    return {
        "number": n,
        "headRefName": head,
        "isDraft": False,
        "isCrossRepository": fork,
        "mergeable": mergeable,
        "autoMergeRequest": {},
        "labels": [],
    }


def _run(tmp_path, fail=""):
    fake = tmp_path / "fake"
    fake.mkdir()
    green = [
        {"name": "ci", "status": "COMPLETED", "conclusion": "SUCCESS", "completedAt": GREEN}
    ]
    prs = [
        _pr(8001, "claim/issue-7001", "MERGEABLE"),
        _pr(8002, "claim/issue-7002", "CONFLICTING"),
        _pr(8003, "claim/issue-7003", "MERGEABLE"),
        _pr(8004, "claim/issue-9999", "MERGEABLE", fork=True),
    ]
    (fake / "prs.json").write_text(json.dumps(prs))
    views = {
        8001: {"headRefName": "claim/issue-7001", "mergeStateStatus": "BLOCKED", "statusCheckRollup": green},
        8002: {"headRefName": "claim/issue-7002", "mergeable": "CONFLICTING"},
        8003: {"headRefName": "claim/issue-7003", "mergeStateStatus": "CLEAN", "statusCheckRollup": green},
        8004: {"headRefName": "claim/issue-9999", "mergeStateStatus": "BLOCKED", "statusCheckRollup": green},
    }
    for n, view in views.items():
        (fake / f"pr-{n}.json").write_text(json.dumps(view))
    for n in (7001, 7002, 7003):
        (fake / f"api-issue-{n}.json").write_text(json.dumps(_issue(n, "agent-in-progress")))
        (fake / f"comments-{n}.json").write_text(json.dumps({"comments": []}))
    started = {"body": f"agent run started: {RUN_URL}", "createdAt": GREEN}
    (fake / "comments-7003.json").write_text(json.dumps({"comments": [started]}))
    gh = fake / "gh"
    gh.write_text(FAKE_GH)
    gh.chmod(0o755)
    out = tmp_path / "github-output"
    out.write_text("")
    env = {
        **os.environ,
        "PATH": f"{fake}:{os.environ['PATH']}",
        "FAKE_DIR": str(fake),
        "GITHUB_REPOSITORY": "o/r",
        "GITHUB_OUTPUT": str(out),
        "CHECK_DEFS": _y(f"{STEP} | .env.CHECK_DEFS"),
        "RED_REWORK": _y(f"{STEP} | .env.RED_REWORK"),
        "RUN_LIVE_JQ": _y(".env.RUN_LIVE_JQ"),
        "ISSUE": "",
        "CLOSED": "",
        "FAIL_READ": fail,
    }
    r = subprocess.run(
        ["bash", "--noprofile", "--norc", "-e", "-c", _y(f"{STEP} | .run")],
        env=env,
        capture_output=True,
        text=True,
    )
    return r, out.read_text()


def test_a_healthy_sweep_lists_every_case_and_publishes_refs(tmp_path):
    r, out = _run(tmp_path)
    assert r.returncode == 0, r.stdout + r.stderr
    assert 'claim PRs missing required checks: ["claim/issue-7001","claim/issue-9999"]' in r.stdout
    assert 'claim PRs with a dead agent run: ["claim/issue-7003"]' in r.stdout
    assert "claim PRs red with no rework since: []" in r.stdout
    assert (
        'refs=["claim/issue-7002","claim/issue-7001","claim/issue-9999","claim/issue-7003"]'
        in out
    )


@pytest.mark.parametrize(
    "fail,needle",
    [
        ("rollup", ROLLUP_ERR),
        ("conflict", "gh: refused: pr view 8002, mergeable"),
        ("run", "gh: refused: run view"),
    ],
)
def test_a_failed_read_fails_the_step_before_it_lists_or_publishes(tmp_path, fail, needle):
    r, out = _run(tmp_path, fail)
    assert needle in r.stderr, r.stdout + r.stderr
    assert r.returncode != 0, r.stdout + r.stderr
    assert "claim PRs " not in r.stdout
    assert "refs=" not in out
