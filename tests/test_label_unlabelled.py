"""label-unlabelled: the job in agent-dispatch.yml (fleet-ops#10218).

Runs the job's real `run:` block, read out with yq, against a fake gh on
PATH. The fake gh executes the `--jq` string it is passed, so the job's own
filter decides what gets labelled, never a copy. Covers: only open,
unlabelled issues from a trusted author get the owner label (needs-
orchestrator in fleet-ops, needs-triage in a product repo); the fleet's own
[bot] automations file as CONTRIBUTOR and count, while strangers
(author_association NONE), human contributors, labelled issues, PRs and
issues inside the 10-minute grace stay unlabelled; and the job triggers on
the sweep only - `opened` stays out of on.issues.types, so no issue event
can fan a full sweep out per opened issue.
"""
import json
import os
import pathlib
import subprocess
from datetime import datetime, timedelta, timezone

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
WF = str(ROOT / ".github/workflows/agent-dispatch.yml")

FAKE_GH = r"""#!/usr/bin/env bash
q=; args=("$@")
for ((i = 0; i < $#; i++)); do
  [ "${args[$i]}" = --jq ] && q=${args[$((i + 1))]}
done
case $1 in
  api) jq -r "$q" "$FAKE_DIR/issues.json" ;;
  label) echo "label $*" >> "$FAKE_DIR/calls" ;;
  issue) echo "$*" >> "$FAKE_DIR/calls" ;;
esac
"""

OLD = "2026-01-01T00:00:00Z"
YOUNG = (datetime.now(timezone.utc) - timedelta(seconds=60)).strftime("%Y-%m-%dT%H:%M:%SZ")

ISSUES = [
    {"number": 1, "author_association": "MEMBER", "user": {"login": "nish3451"}, "created_at": OLD, "labels": []},
    {"number": 2, "author_association": "MEMBER", "user": {"login": "nish3451"}, "created_at": OLD, "labels": [{"name": "agent-ready"}]},
    {"number": 3, "author_association": "MEMBER", "user": {"login": "nish3451"}, "created_at": OLD, "labels": [], "pull_request": {}},
    {"number": 4, "author_association": "CONTRIBUTOR", "user": {"login": "nishfleet-worker[bot]"}, "created_at": OLD, "labels": []},
    {"number": 5, "author_association": "NONE", "user": {"login": "driveby"}, "created_at": OLD, "labels": []},
    {"number": 6, "author_association": "CONTRIBUTOR", "user": {"login": "human-outsider"}, "created_at": OLD, "labels": []},
    {"number": 7, "author_association": "MEMBER", "user": {"login": "nish3451"}, "created_at": YOUNG, "labels": []},
]


def run(tmp_path, repo):
    step = subprocess.run(["yq", ".jobs.label-unlabelled.steps[0].run", WF],
                          check=True, capture_output=True, text=True).stdout
    (tmp_path / "bin").mkdir()
    gh = tmp_path / "bin/gh"
    gh.write_text(FAKE_GH)
    gh.chmod(0o755)
    (tmp_path / "issues.json").write_text(json.dumps(ISSUES))
    env = {**os.environ, "PATH": f"{tmp_path/'bin'}:{os.environ['PATH']}",
           "FAKE_DIR": str(tmp_path), "REPO": repo}
    subprocess.run(["bash", "-c", step], check=True, env=env, capture_output=True)
    return (tmp_path / "calls").read_text().splitlines()


@pytest.mark.parametrize("repo,label", [("Nishfleet/fleet-ops", "needs-orchestrator"),
                                        ("Nishfleet/0509", "needs-triage")])
def test_only_trusted_unlabelled_issues_get_owner_label(tmp_path, repo, label):
    calls = run(tmp_path, repo)
    edits = [c for c in calls if c.startswith("issue edit")]
    assert [c.split()[2] for c in edits] == ["1", "4"]
    assert all(f"--add-label {label}" in c for c in edits)


def test_triggers_are_sweep_only_and_opened_stays_out():
    cond = subprocess.run(["yq", ".jobs.label-unlabelled.if", WF], check=True,
                          capture_output=True, text=True).stdout
    assert "schedule" in cond and "workflow_dispatch" in cond
    assert "opened" not in cond
    on = subprocess.run(["yq", "-o=json", ".on.issues.types", WF], check=True,
                        capture_output=True, text=True).stdout
    assert "opened" not in json.loads(on)
