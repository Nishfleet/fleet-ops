"""A deleted claim issue does not abort the dispatch sweep (fleet-ops#9553),
and a failed claim-PR re-dispatch costs the pick no hour (fleet-ops#9368).

The sweep runs agent-dispatch.yml's own `redispatch` and `list` scripts, read
out of the workflow with yq, never a copy, against a mock gh whose claim PR
#8002 points at deleted issue #9502: gh api answers 410 and gh issue view
cannot resolve the number, the shape that once stopped every sweep. The sweep
must exit 0, name the issue it skipped, and still pick the red PR (its issue
carries 180 KB of comments, over the 131072-byte argument limit) and both
queued issues. Both 410 shapes are proven: real gh prints the deleted body on
stdout, and BODY_ON_STDOUT=0 drops it, so the stderr-only path is proven on
its own too.

The mock gh lives in a temp dir and is not a repo file.
"""
import json
import os
import pathlib
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
WF = ROOT / ".github/workflows/agent-dispatch.yml"
MOCK_GH = r"""#!/usr/bin/env bash
# Mock gh for the sweep: #7001 and #7002 are queued, #7003 has a red
# claim PR with no run since, and #9502 is deleted.
q=
for ((i = 1; i <= $#; i++)); do if [ "${!i}" = --jq ]; then j=$((i + 1)); q=${!j}; fi; done
cmd=$1; args=${*:2}; d=$FAKE_DIR
emit() { # stdin is the json gh would return; gh prints raw scalars
  in=$(cat)
  if [ -z "$q" ]; then printf '%s\n' "$in"; return; fi
  out=$(jq -c "$q" <<<"$in")
  case ${out:0:1} in '[' | '{') printf '%s\n' "$out" ;; *) jq -r "$q" <<<"$in" ;; esac
}
serve() { [ -f "$1" ] || { echo "mock gh: no fixture for $1" >&2; exit 1; }; emit < "$1"; }
case "$cmd $args" in
  "issue list "*agent-in-progress*) echo '[{"number":11}]' | emit ;;
  "issue list"*) echo '[{"number":7001},{"number":7002}]' | emit ;;
  "issue view 9502"*)
    echo "GraphQL: Could not resolve to an issue or pull request with the number of 9502. (repository.issue)" >&2
    exit 1 ;;
  "issue view"*) jq -n --arg n "${args#view }" '{comments: (if $n | startswith("7003") then [range(0; 3) | {body: ("x" * 60000)}] else [] end)}' | emit ;;
  "pr list "*--head*) echo '0' | emit ;;
  "pr list"*) [ -z "${FAIL_PR_LIST:-}" ] || { echo 'gh: HTTP 502 (pr list)' >&2; exit 1; }; serve "$d/prs.json" ;;
  "pr view"*) n=${args#view }; serve "$d/pr-${n%% *}.json" ;;
  "run view"*) echo '"completed"' | emit ;;
  "api graphql"*) echo '{"data":{"repository":{"mergeQueue":{"entries":{"nodes":[]}}}}}' | emit ;;
  "api "*"/issues/9502")
    # Real gh 2.93.0 (measured 2026-10-12 on this issue): body on
    # stdout, "(HTTP 410)" on stderr, exit 1. BODY_ON_STDOUT=0 drops
    # the body, so the stderr path is proven on its own too.
    echo 'gh: This issue was deleted (HTTP 410)' >&2
    [ "${BODY_ON_STDOUT:-1}" = 0 ] || echo '{"message":"This issue was deleted","documentation_url":"https://docs.github.com/rest","status":"410"}'
    exit 1 ;;
  "api "*"/issues/"*) serve "$d/issue-${args##*/}.json" ;;
  *) echo "mock gh: unexpected call: $cmd $args" >&2; exit 1 ;;
esac
"""
RED = [{"name": "ci", "status": "COMPLETED", "conclusion": "FAILURE",
        "completedAt": "2026-10-09T00:00:00Z", "startedAt": "2026-10-09T00:00:00Z"}]
ISSUES = (
    (7001, "01", [{"name": "agent-ready"}], None),
    (7002, "02", [{"name": "agent-ready"}], None),
    (7003, "03", [{"name": "agent-in-progress"}], "y" * 140000),
)
PRS = [
    {"number": 7001, "headRefName": "claim/issue-7001", "isDraft": False, "isCrossRepository": False,
     "mergeable": "MERGEABLE", "autoMergeRequest": {}, "labels": []},
    {"number": 8001, "headRefName": "claim/issue-7003", "isDraft": False, "isCrossRepository": False,
     "mergeable": "MERGEABLE", "autoMergeRequest": {}, "labels": []},
    {"number": 8002, "headRefName": "claim/issue-9502", "isDraft": False, "isCrossRepository": False,
     "mergeable": "MERGEABLE", "autoMergeRequest": {}, "labels": [{"name": "needs-coordinator"}]},
]


def _yq(expr):
    return subprocess.run(["yq", expr, str(WF)], check=True, capture_output=True, text=True).stdout


def _write(path, payload):
    path.write_text(json.dumps(payload))


@pytest.fixture(scope="module")
def rig(tmp_path_factory):
    t = tmp_path_factory.mktemp("sweep-deleted-issue")
    (t / "bin").mkdir()
    data = t / "data"
    data.mkdir()
    for step in ("redispatch", "list"):
        run = _yq(f'.jobs.list.steps[] | select(.id == "{step}") | .run')
        assert run.strip() and run.strip() != "null", f"the {step} script is missing from agent-dispatch.yml"
        (t / f"{step}.sh").write_text(run)
    defs = _yq('.jobs.list.steps[] | select(.id == "redispatch") | .env.CHECK_DEFS')
    prog = _yq('.jobs.list.steps[] | select(.id == "redispatch") | .env.RED_REWORK')
    assert defs.strip() and defs.strip() != "null", "CHECK_DEFS is missing"
    assert prog.strip() and prog.strip() != "null", "RED_REWORK is missing"
    gh = t / "bin" / "gh"
    gh.write_text(MOCK_GH)
    gh.chmod(0o755)
    for number, day, labels, body in ISSUES:
        _write(data / f"issue-{number}.json", {
            "number": number, "created_at": f"2026-10-{day}T00:00:00Z", "state": "open",
            "body": body, "issue_dependencies_summary": {"blocked_by": 0}, "labels": labels,
        })
    _write(data / "prs.json", PRS)
    for number, rollup in ((7001, []), (8001, RED), (8002, RED)):
        pr = next(p for p in PRS if p["number"] == number)
        _write(data / f"pr-{number}.json", {
            "headRefName": pr["headRefName"], "mergeStateStatus": "CLEAN", "statusCheckRollup": rollup,
        })
    return t, defs, prog


def _run(t, script, out, **extra):
    env = {**os.environ, "PATH": f"{t / 'bin'}:{os.environ['PATH']}", "FAKE_DIR": str(t / "data"),
           "GITHUB_OUTPUT": str(out), "GITHUB_REPOSITORY": "o/r", "GH_TOKEN": "x"}
    env.update(extra)
    return subprocess.run(["bash", "-eo", "pipefail", str(t / script)],
                          capture_output=True, text=True, env=env)


def _value(out, key):
    return "\n".join(line[len(key) + 1:] for line in out.read_text().splitlines() if line.startswith(f"{key}="))


def test_a_deleted_issue_does_not_abort_the_sweep(rig):
    t, defs, prog = rig
    out = t / "out"
    for body in ("1", "0"):
        out.write_text("")
        redispatch = _run(t, "redispatch.sh", out, BODY_ON_STDOUT=body, CHECK_DEFS=defs, RED_REWORK=prog)
        assert redispatch.returncode == 0, (
            f"the claim-PR re-dispatch exited {redispatch.returncode} on a deleted issue "
            f"(BODY_ON_STDOUT={body}): {redispatch.stdout}{redispatch.stderr}")
        prs = _value(out, "prs")
        out.write_text("")
        sweep = _run(t, "list.sh", out, BODY_ON_STDOUT=body, ISSUE="", CLOSED="", PRS=prs)
        log = redispatch.stdout + redispatch.stderr + sweep.stdout + sweep.stderr
        assert sweep.returncode == 0, f"the sweep exited {sweep.returncode} on a deleted issue (BODY_ON_STDOUT={body}): {log}"
        assert _value(out, "refs") == '["claim/issue-7001","claim/issue-7002","claim/issue-7003"]', (
            f"refs on a deleted issue (BODY_ON_STDOUT={body}): {_value(out, 'refs')}")
        assert "#9502: issue gone" in log, f"the skipped issue was not reported (BODY_ON_STDOUT={body}): {log}"


def test_a_failed_redispatch_costs_the_pick_no_hour(rig):
    t, defs, prog = rig
    out = t / "out"
    out.write_text("")
    redispatch = _run(t, "redispatch.sh", out, FAIL_PR_LIST="1", CHECK_DEFS=defs, RED_REWORK=prog)
    assert redispatch.returncode != 0 and not out.read_text(), (
        f"the re-dispatch did not fail clean on a pr list fault (rc={redispatch.returncode}, "
        f"outputs: {out.read_text()})")
    sweep = _run(t, "list.sh", out, ISSUE="", CLOSED="", PRS="", REDISPATCH="failure")
    log = redispatch.stdout + redispatch.stderr + sweep.stdout + sweep.stderr
    assert sweep.returncode == 0, f"the sweep exited {sweep.returncode} after a failed re-dispatch: {log}"
    assert "claim-PR re-dispatch failed; this run appends no claim PRs" in log, (
        f"the pick did not warn about the failed re-dispatch: {log}")
    assert _value(out, "refs") == '["claim/issue-7001","claim/issue-7002"]', (
        f"refs after a failed re-dispatch: {_value(out, 'refs')}")
