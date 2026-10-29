"""GitHub "blocked by" in the coordinator path (fleet-ops#10489): the orchestrate job's own
`run:` block of agent-dispatch.yml against a fake gh.

The orchestrate issue step skips a blocked issue. The list job's half of #10489, re-labelling each
unblocked needs-orchestrator dependent when its blocker closes, moved into
pi-extensions/issue-desk/src/sweep.ts (fleet-ops#10456) and is tested there by test/sweep.test.ts.
"""
import json
import os
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
WF = str(ROOT / ".github/workflows/agent-dispatch.yml")
ISSUE_STEP = '.jobs.orchestrate.steps[] | select(.id == "issue")'

FAKE_GH = r"""#!/usr/bin/env bash
q=.; for ((i = 1; i <= $#; i++)); do [ "${!i}" = --jq ] && { j=$((i + 1)); q=${!j}; }; done
case "$*" in
  "issue edit"*) echo "$*|token=${GH_TOKEN:-none}" >> "$FAKE_DIR/writes.log" ;;
  "issue view"*) jq -r "$q" "$FAKE_DIR/issue.json" ;;
  *"/dependencies/blocking"*) jq -r "$q" "$FAKE_DIR/blocking.json" ;;
  *"/parent"*) exit 1 ;;
  *git/ref/heads/*) exit 1 ;;
  "issue comment"*) ;;
  *issues/comments*) echo '[]' | jq -c "$q" ;;
  "api repos/o/r/issues/"*) n=${2##*/}; jq -r "$q" "$FAKE_DIR/issue-$n.json" 2>/dev/null || jq -r "$q" "$FAKE_DIR/issue.json" ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 99 ;;
esac
"""


def _y(expr):
    return subprocess.run(["yq", expr, WF], check=True, capture_output=True, text=True).stdout


def _fake(tmp_path):
    gh = tmp_path / "gh"
    gh.write_text(FAKE_GH)
    gh.chmod(0o755)
    return {**os.environ, "PATH": f"{tmp_path}:{os.environ['PATH']}", "FAKE_DIR": str(tmp_path)}


def orchestrate(tmp_path, blocked_by):
    (tmp_path / "issue.json").write_text(json.dumps({
        "state": "OPEN", "labels": [{"name": "needs-orchestrator"}],
        "issue_dependencies_summary": {"blocked_by": blocked_by}}))
    (tmp_path / "out").write_text("")
    env = {**_fake(tmp_path), "REPO": "o/r", "ISSUE": "5", "GH_TOKEN": "x", "GITHUB_SERVER_URL": "https://github.com",
           "GITHUB_RUN_ID": "1", "GITHUB_OUTPUT": str(tmp_path / "out"), "DAILY_MAX": "5"}
    r = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", _y(f"{ISSUE_STEP} | .run")],
                       env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    return r.stdout, (tmp_path / "out").read_text()


def test_blocked_issue_is_skipped_and_says_so(tmp_path):
    log, out = orchestrate(tmp_path, blocked_by=1)
    assert "blocked" in log and "go=true" not in out


def test_unblocked_issue_still_goes(tmp_path):
    _, out = orchestrate(tmp_path, blocked_by=0)
    assert "go=true" in out
