"""label-unlabelled: the job in agent-dispatch.yml (fleet-ops#10218).

Runs the job's real `run:` block against a fake gh on PATH: only open,
unlabelled issues (not PRs, not labelled ones) get the owner label, and the
label differs for fleet-ops and for a product repo.
"""
import json
import os
import pathlib
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
WF = str(ROOT / ".github/workflows/agent-dispatch.yml")

FAKE_GH = r"""#!/usr/bin/env bash
case $1 in
  api) jq -r '.[] | select((has("pull_request") | not) and (.labels | length == 0)) | .number' "$FAKE_DIR/issues.json" ;;
  label) echo "label $*" >> "$FAKE_DIR/calls" ;;
  issue) echo "$*" >> "$FAKE_DIR/calls" ;;
esac
"""

ISSUES = [
    {"number": 1, "labels": []},
    {"number": 2, "labels": [{"name": "agent-ready"}]},
    {"number": 3, "labels": [], "pull_request": {}},
    {"number": 4, "labels": []},
]


def run(tmp_path, repo):
    step = subprocess.run(
        ["yq", ".jobs.label-unlabelled.steps[0].run", WF],
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
def test_only_unlabelled_issues_get_owner_label(tmp_path, repo, label):
    calls = run(tmp_path, repo)
    edits = [c for c in calls if c.startswith("issue edit")]
    assert [c.split()[2] for c in edits] == ["1", "4"]
    assert all(f"--add-label {label}" in c for c in edits)


def test_triggers_cover_sweep_and_new_issue():
    cond = subprocess.run(["yq", ".jobs.label-unlabelled.if", WF], check=True,
                          capture_output=True, text=True).stdout
    assert "'opened'" in cond and "'schedule'" in cond
    on = subprocess.run(["yq", "-o=json", ".on.issues.types", WF], check=True,
                        capture_output=True, text=True).stdout
    assert "opened" in json.loads(on)
