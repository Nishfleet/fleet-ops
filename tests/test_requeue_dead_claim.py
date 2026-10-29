"""The list sweep's requeue path (fleet-ops#9063) for a claim no run ever announced: the real
`run:` block of agent-dispatch.yml's list step against a fake gh.

A worker's Gate labels the issue `agent-in-progress` and posts "agent run started:" one line
apart, so a live worker always has the comment. A run that died between the two lines leaves
the label alone, and the sweep used to skip exactly that case: fleet-ops#10899, 0509#7070 held
the label for 24 days with no branch, no pull request and no comment, and nothing requeued it.
"""
import json
import os
import pathlib
import subprocess
from datetime import datetime, timedelta, timezone

ROOT = pathlib.Path(__file__).resolve().parents[1]
WF = str(ROOT / ".github/workflows/agent-dispatch.yml")
LIST_STEP = '.jobs.list.steps[] | select(.id == "list")'
STEP_ENV = f'{LIST_STEP} | .env'

FAKE_GH = r"""#!/usr/bin/env bash
q=.; for ((i = 1; i <= $#; i++)); do [ "${!i}" = --jq ] && { j=$((i + 1)); q=${!j}; }; done
case "$*" in
  "issue edit"*) echo "$*|token=${GH_TOKEN:-none}" >> "$FAKE_DIR/writes.log" ;;
  "issue list"*"-S no:label"*) echo '[]' | jq -r "$q" ;;
  "issue list"*"-l agent-in-progress"*) echo '[{"number":'"${FAKE_INPROG:-7}"'}]' | jq -r "$q" ;;
  "issue list"*"-l agent-ready"*) echo '[{"number":7}]' | jq -r "$q" ;;
  "pr list"*"--head claim/issue-"*) printf '%s' "$FAKE_CLAIM_PR" | jq -r "$q" ;;
  "pr list"*) echo '[]' | jq -r "$q" ;;
  "issue view"*) jq -r "$q" <<<"$FAKE_COMMENTS" ;;
  "run view"*) jq -r "$q" <<<"$FAKE_RUN" ;;
  "api graphql"*) echo '{"data":{"repository":{"mergeQueue":{"entries":{"nodes":[]}}}}}' | jq -r "$q" ;;
  "api repos/o/r/issues/"*"/events"*) jq -r "$q" <<<"$FAKE_EVENTS" ;;
  "api repos/o/r/issues/"*) jq -r "$q" "$FAKE_DIR/issue.json" ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 99 ;;
esac
"""


def _y(expr):
    return subprocess.run(["yq", expr, WF], check=True, capture_output=True, text=True).stdout


def sweep(tmp_path, *, events, comments=None, run=None, claim_pr="[]", inprog="7"):
    gh = tmp_path / "gh"
    gh.write_text(FAKE_GH)
    gh.chmod(0o755)
    (tmp_path / "issue.json").write_text(json.dumps({
        "number": 7, "state": "OPEN", "labels": [{"name": "agent-in-progress"}],
        "issue_dependencies_summary": {"blocked_by": 0}, "created_at": "2026-10-01T00:00:00Z"}))
    (tmp_path / "out").write_text("")
    env = {**os.environ, "PATH": f"{tmp_path}:{os.environ['PATH']}", "FAKE_DIR": str(tmp_path),
           "GITHUB_REPOSITORY": "o/r", "GH_TOKEN": "x", "ISSUE": "", "CLOSED": "",
           "GITHUB_OUTPUT": str(tmp_path / "out"), "CHECK_DEFS": _y(f"{STEP_ENV}.CHECK_DEFS"), "RUN_LIVE_JQ": _y(".env.RUN_LIVE_JQ"),
           "FAKE_COMMENTS": comments or '{"comments":[]}',
           "FAKE_EVENTS": json.dumps(events), "FAKE_RUN": run or '{"status":"completed","jobs":[]}',
           "FAKE_CLAIM_PR": claim_pr, "FAKE_INPROG": inprog}
    r = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", _y(f"{LIST_STEP} | .run")],
                       env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    log = tmp_path / "writes.log"
    return r.stdout, (log.read_text().splitlines() if log.exists() else []), (tmp_path / "out").read_text()


def labelled(seconds_ago):
    at = datetime.now(timezone.utc) - timedelta(seconds=seconds_ago)
    return [{"event": "labeled", "label": {"name": "agent-in-progress"},
             "created_at": at.strftime("%Y-%m-%dT%H:%M:%SZ")},
            {"event": "labeled", "label": {"name": "agent-ready"}, "created_at": "2026-10-01T00:00:00Z"}]


def run_comment(status="completed"):
    body = f"agent run started: https://github.com/o/r/actions/runs/99"
    return json.dumps({"comments": [{"body": body}]}), json.dumps(
        {"status": status, "jobs": [{"name": "x / work (claim/issue-7)", "status": status}]})


def test_a_claim_no_run_announced_is_requeued(tmp_path):
    log, writes, out = sweep(tmp_path, events=labelled(86400))
    assert "requeued #7: claimed with no live run and no claim PR" in log
    assert "issue edit 7 -R o/r --remove-label agent-in-progress --add-label agent-ready|token=x" in writes
    assert 'stalled_refs=["claim/issue-7-miss-review"]' in out


def test_a_recently_labelled_issue_is_left_alone(tmp_path):
    log, writes, out = sweep(tmp_path, events=labelled(60))
    assert "requeued #7" not in log
    assert writes == []
    assert "stalled_refs=[]" in out


def test_a_live_run_url_is_left_alone(tmp_path):
    comments, run = run_comment("in_progress")
    log, writes, _ = sweep(tmp_path, events=labelled(86400), comments=comments, run=run)
    assert "requeued #7" not in log
    assert writes == []


def test_a_dead_run_url_is_requeued(tmp_path):
    comments, run = run_comment("completed")
    log, writes, _ = sweep(tmp_path, events=labelled(86400), comments=comments, run=run)
    assert "requeued #7: claimed with no live run and no claim PR" in log
    assert "issue edit 7 -R o/r --remove-label agent-in-progress --add-label agent-ready|token=x" in writes


def test_an_open_claim_pr_is_left_alone(tmp_path):
    log, writes, _ = sweep(tmp_path, events=labelled(86400), claim_pr='[{"number":9,"isDraft":false}]')
    assert "requeued #7" not in log
    assert writes == []


def test_no_label_event_at_all_is_skipped(tmp_path):
    log, writes, out = sweep(tmp_path, events=[])
    assert "no agent-in-progress label event, skip" in log
    assert writes == []
    assert "stalled_refs=[]" in out
