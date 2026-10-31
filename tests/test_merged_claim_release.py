"""fleet-ops#9118: the list job releases agent-in-progress from an issue whose claim PR merged without
closing it, comments the receipt naming that PR, and never closes the issue. A run started after the
merge is a new claim and is left alone. Runs the real `run:` block against a fake gh."""
import json
import os
import pathlib
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
WF = str(ROOT / ".github/workflows/agent-dispatch.yml")
LIST_STEP = '.jobs.list.steps[] | select(.id == "list")'

FAKE_GH = r"""#!/usr/bin/env bash
q=.; for ((i = 1; i <= $#; i++)); do [ "${!i}" = --jq ] && { j=$((i + 1)); q=${!j}; }; done
case "$*" in
  "issue edit"*|"issue comment"*|"issue close"*) echo "$*" >> "$FAKE_DIR/writes.log" ;;
  "issue list"*"-l agent-in-progress"*) echo '[{"number":7}]' | jq -r "$q" ;;
  "issue list"*) echo '[]' | jq -r "$q" ;;
  "issue view"*) jq -r "$q" "$FAKE_DIR/issue.json" ;;
  "pr list"*"--state merged"*) jq -r "$q" "$FAKE_DIR/merged.json" ;;
  "pr list"*) echo '[]' | jq -r "$q" ;;
  "api graphql"*) echo '{"data":{"repository":{"mergeQueue":{"entries":{"nodes":[]}}}}}' | jq -r "$q" ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 99 ;;
esac
"""


def _y(expr):
    return subprocess.run(["yq", f"{LIST_STEP} | {expr}", WF], check=True, capture_output=True, text=True).stdout


def sweep(tmp_path, merged, started):
    gh = tmp_path / "gh"
    gh.write_text(FAKE_GH)
    gh.chmod(0o755)
    (tmp_path / "merged.json").write_text(json.dumps(merged))
    comments = [{"body": "agent run started: https://x/actions/runs/1", "createdAt": started}] if started else []
    (tmp_path / "issue.json").write_text(json.dumps({"comments": comments}))
    (tmp_path / "out").write_text("")
    env = {**os.environ, "PATH": f"{tmp_path}:{os.environ['PATH']}", "FAKE_DIR": str(tmp_path),
           "GITHUB_REPOSITORY": "Nishfleet/fleet-ops", "GH_TOKEN": "x", "CLOSED": "", "ISSUE": "",
           "GITHUB_OUTPUT": str(tmp_path / "out"), "CHECK_DEFS": _y(".env.CHECK_DEFS"),
           "RUN_LIVE_JQ": _y(".env.RUN_LIVE_JQ"), "RED_REWORK": _y(".env.RED_REWORK")}
    r = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", _y(".run")],
                       env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    log = tmp_path / "writes.log"
    return log.read_text().splitlines() if log.exists() else []


MERGED = [{"number": 6243, "mergedAt": "2026-10-30T10:00:00Z"}]


@pytest.mark.parametrize("started", ["2026-10-30T09:00:00Z", None])
def test_merged_claim_pr_releases_the_label_with_a_receipt(tmp_path, started):
    writes = sweep(tmp_path, MERGED, started)
    assert any(w.startswith("issue comment 7 ") and "claim PR #6243 merged" in w for w in writes)
    assert "issue edit 7 -R Nishfleet/fleet-ops --remove-label agent-in-progress" in writes
    assert not [w for w in writes if w.startswith("issue close")]


def test_a_run_started_after_the_merge_keeps_its_label(tmp_path):
    assert sweep(tmp_path, MERGED, "2026-10-30T11:00:00Z") == []


def test_no_merged_claim_pr_changes_nothing(tmp_path):
    assert sweep(tmp_path, [], "2026-10-30T09:00:00Z") == []
