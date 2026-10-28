"""review/pr_rot.py, the PR rot rules (fleet-ops#10573), run as agent.yml runs it against a fake gh.

Round 1 is sent back to the orchestrator, round 2 is handed to its owner, a conflicting strong/ branch is
reworked on its own branch, and a PR with no commit for 7 days is closed and its work re-filed.
"""
import importlib.util
import json
import os
import pathlib
import subprocess
from datetime import datetime, timedelta, timezone

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
PROG = ROOT / "review/pr_rot.py"
SHA = "a" * 40
OLD = ["b" * 40, "c" * 40]
FAKE_GH = r"""#!/usr/bin/env bash
f=$FAKE_DIR
case "$*" in
  "api repos/o/r/pulls/5") cat "$f/pr.json" ;;
  "api repos/o/r/commits/"*) echo "$HEAD_DATE" ;;
  "pr view 5 -R o/r --json closingIssuesReferences") cat "$f/closing.json" ;;
  "api repos/o/r/issues/77") cat "$f/issue.json" ;;
  "api --paginate --slurp repos/o/r/issues/"*"/comments?per_page=100") n=${4#repos/o/r/issues/}; n=${n%%/*}; echo "[$(cat "$f/comments-$n.json")]" ;;
  "run view"*) cat "$f/run.json" ;;
  "issue list"*) echo '[]' ;;
  "issue create"*) echo "$*" >> "$f/writes.log"; echo https://github.com/o/r/issues/99 ;;
  "issue edit"*|"issue comment"*|"pr close"*) echo "$*" >> "$f/writes.log" ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 1 ;;
esac
"""


def bot(body):
    return {"user": {"login": "github-actions[bot]"}, "body": body}


def blocked(sha):
    return bot(f"reviewer: {sha} blocked. Fix the items below.")


def run(tmp_path, *, ref="claim/issue-77", issue=True, labels=(), pr_comments=(), issue_comments=(), age=timedelta(hours=2),
        fork=False, live=False, flags=(), reason="required checks failed (ci)"):
    f = tmp_path / "fake"
    f.mkdir()
    pr = {"number": 5, "state": "open", "title": "Make it faster", "body": "Speeds up the sweep.", "html_url": "https://github.com/o/r/pull/5",
          "head": {"sha": SHA, "ref": ref, "repo": {"full_name": "x/r" if fork else "o/r"}}}
    (f / "pr.json").write_text(json.dumps(pr))
    refs = [{"number": 77, "repository": {"name": "r", "owner": {"login": "o"}}}] if issue else []
    (f / "closing.json").write_text(json.dumps({"closingIssuesReferences": refs}))
    (f / "issue.json").write_text(json.dumps({"number": 77, "state": "open", "labels": [{"name": x} for x in labels]}))
    started = [{"body": "agent run started: https://github.com/o/r/actions/runs/42"}] if live else []
    (f / "comments-5.json").write_text(json.dumps(list(pr_comments)))
    (f / "comments-77.json").write_text(json.dumps(started + list(issue_comments)))
    (f / "run.json").write_text(json.dumps({"status": "in_progress", "jobs": [{"name": f"work / work ({ref})", "status": "in_progress"}]}))
    gh = f / "gh"
    gh.write_text(FAKE_GH)
    gh.chmod(0o755)
    head_date = (datetime.now(timezone.utc) - age).strftime("%Y-%m-%dT%H:%M:%SZ")
    env = {**os.environ, "PATH": f"{f}:{os.environ['PATH']}", "FAKE_DIR": str(f), "HEAD_DATE": head_date,
           "REPO": "o/r", "PR": "5", "SHA": SHA, "REASON": reason, "URL": ""}
    r = subprocess.run(["python3", "-I", str(PROG), *flags], env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    log = f / "writes.log"
    return r.stdout, (log.read_text() if log.exists() else "")


def test_round_one_is_sent_back_to_the_orchestrator(tmp_path):
    out, writes = run(tmp_path, labels=("agent-in-progress",))
    assert "issue edit 77 -R o/r --add-label needs-orchestrator --remove-label orchestrator-tried" in writes
    assert f"rework: PR #5 at {SHA[:7]}: required checks failed (ci). Round 1 of 2" in writes
    assert "strong-only" not in writes


def test_a_block_right_after_review_sends_round_one_back(tmp_path):
    out, writes = run(tmp_path, pr_comments=[blocked(SHA)], flags=("--blocked",), reason="")
    assert f"rework: PR #5 at {SHA[:7]}: the review blocked {SHA[:7]}. https://github.com/o/r/pull/5 Round 1 of 2" in writes


def test_round_two_is_handed_to_its_owner(tmp_path):
    out, writes = run(tmp_path, labels=("needs-orchestrator",), pr_comments=[blocked(OLD[0]), blocked(SHA)], flags=("--blocked",), reason="")
    assert "issue edit 77 -R o/r --add-label needs-orchestrator,strong-only" in writes
    assert "rounds: PR #5 has had 2 review or CI rounds, the limit is 2" in writes
    assert "rework:" not in writes


def test_a_ci_round_after_a_rework_counts_as_round_two(tmp_path):
    out, writes = run(tmp_path, issue_comments=[{"body": f"rework: PR #5 at {OLD[0][:7]}: it conflicts with main."}])
    assert "--add-label needs-orchestrator,strong-only" in writes


def test_the_owner_hand_off_is_said_once(tmp_path):
    out, writes = run(tmp_path, pr_comments=[blocked(OLD[0]), blocked(OLD[1])], issue_comments=[{"body": "rounds: PR #5 has had 2 review or CI rounds"}])
    assert writes == ""
    assert "already handed to its owner" in out


def test_a_conflicting_strong_branch_is_reworked_on_its_own_branch(tmp_path):
    out, writes = run(tmp_path, ref="strong/issue-77", reason="it conflicts with main")
    assert f"rework: PR #5 at {SHA[:7]}: it conflicts with main." in writes
    assert "continues `strong/issue-77`, merges main (never a rebase)" in writes


def test_a_seven_day_pr_is_closed_and_its_issue_made_agent_ready(tmp_path):
    out, writes = run(tmp_path, ref="strong/issue-77", labels=("needs-orchestrator",), age=timedelta(days=7, minutes=1))
    assert "issue edit 77 -R o/r --add-label agent-ready" in writes
    assert "--remove-label needs-orchestrator,orchestrator-tried,agent-in-progress" in writes
    assert "Reuse branch `strong/issue-77`: https://github.com/o/r/tree/strong/issue-77" in writes
    assert "pr close 5 -R o/r --comment stale: no new commit for 7 days" in writes
    assert "--delete-branch" not in writes


def test_a_seven_day_pr_with_no_issue_is_re_filed_from_its_title_and_body(tmp_path):
    out, writes = run(tmp_path, ref="hand-named", issue=False, age=timedelta(days=8))
    assert "issue create -R o/r --title Make it faster --body Re-filed from PR #5" in writes
    assert "Speeds up the sweep." in writes and "--label agent-ready" in writes
    assert "pr close 5 -R o/r" in writes and "#99 carries the work again" in writes


def test_a_six_day_pr_is_not_stale(tmp_path):
    out, writes = run(tmp_path, age=timedelta(days=6, hours=23))
    assert "pr close" not in writes and "rework:" in writes


def test_a_pr_with_no_issue_is_filed_as_a_stuck_pr(tmp_path):
    out, writes = run(tmp_path, ref="hand-named", issue=False)
    assert "issue create -R o/r --title Stuck PR #5: required checks failed (ci)" in writes
    assert "--add-label needs-orchestrator" in writes


@pytest.mark.parametrize("case,kw", [
    ("parked", {"labels": ("needs-nish-decision",)}),
    ("queued", {"labels": ("needs-orchestrator",)}),
    ("same head sent back", {"issue_comments": [{"body": f"rework: PR #5 at {SHA[:7]}: x"}]}),
    ("live run", {"live": True}),
    ("fork", {"fork": True}),
    ("no block on this head", {"pr_comments": [blocked(OLD[0])], "flags": ("--blocked",)}),
    ("blocked but no issue", {"issue": False, "pr_comments": [blocked(SHA)], "flags": ("--blocked",)}),
])
def test_nothing_is_written_when_the_rule_does_not_apply(tmp_path, case, kw):
    out, writes = run(tmp_path, **kw)
    assert writes == "", case


def test_run_live_matches_the_sweep_liveness_cases():
    spec = importlib.util.spec_from_file_location("pr_rot", PROG)
    rot = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rot)
    for c in json.loads((ROOT / "config/sweep-liveness-events.json").read_text())["cases"]:
        run_ = {"status": c["run_status"], "jobs": [{"name": n, "status": st} for n, st in c["jobs"]]}
        assert rot.run_live(run_, c["ref"]) is c["want"], c["name"]
