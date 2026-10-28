"""label-unlabelled: the job in agent-dispatch.yml (fleet-ops#10218).

Runs the job's real `run:` block, read out with yq, against a fake gh on PATH.
The fake gh executes the `--jq` string it is passed, so the job's own filter
decides what gets labelled. Covers: trust is the stock author association plus
the worker bot login (other bots, strangers, labelled issues, PRs and issues
inside the 10-minute grace stay unlabelled); product-repo owner issues get
needs-triage (admit's input), the rest needs-orchestrator; 20 edits a run; a
failed read fails the job; and the sweep is the only trigger (`opened` stays
out of on.issues.types, so no issue event fans a sweep out).
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
  api) [ -e "$FAKE_DIR/api-fails" ] && exit 1; jq -r "$q" "$FAKE_DIR/issues.json" ;;
  label) ;;
  issue) echo "$*" >> "$FAKE_DIR/calls" ;;
esac
"""

OLD = "2026-01-01T00:00:00Z"
YOUNG = (datetime.now(timezone.utc) - timedelta(seconds=60)).strftime("%Y-%m-%dT%H:%M:%SZ")


def issue(n, assoc="MEMBER", login="nish3451", created=OLD, labels=(), **extra):
    return {"number": n, "author_association": assoc, "user": {"login": login}, "created_at": created,
            "labels": [{"name": x} for x in labels], **extra}


ISSUES = [
    issue(1),
    issue(2, labels=["agent-ready"]),
    issue(3, pull_request={}),
    issue(4, "CONTRIBUTOR", "nishfleet-worker[bot]"),
    issue(5, "NONE", "driveby"),
    issue(6, "CONTRIBUTOR", "dependabot[bot]"),
    issue(7, created=YOUNG),
]


def run(tmp_path, repo, issues=ISSUES, api_fails=False):
    step = subprocess.run(["yq", ".jobs.label-unlabelled.steps[0].run", WF],
                          check=True, capture_output=True, text=True).stdout
    (tmp_path / "bin").mkdir()
    gh = tmp_path / "bin/gh"
    gh.write_text(FAKE_GH)
    gh.chmod(0o755)
    (tmp_path / "issues.json").write_text(json.dumps(issues))
    (tmp_path / "calls").touch()
    if api_fails:
        (tmp_path / "api-fails").touch()
    env = {**os.environ, "PATH": f"{tmp_path/'bin'}:{os.environ['PATH']}",
           "FAKE_DIR": str(tmp_path), "REPO": repo}
    done = subprocess.run(["bash", "-c", step], env=env, capture_output=True, text=True)
    return done, (tmp_path / "calls").read_text().splitlines()


def edits(calls):
    return {c.split()[2]: c.split()[-1] for c in calls if c.startswith("issue edit")}


def test_fleet_ops_labels_trusted_issues_needs_orchestrator(tmp_path):
    done, calls = run(tmp_path, "Nishfleet/fleet-ops")
    assert done.returncode == 0
    assert edits(calls) == {"1": "needs-orchestrator", "4": "needs-orchestrator"}


def test_product_repo_owner_issue_gets_needs_triage_bot_issue_needs_orchestrator(tmp_path):
    done, calls = run(tmp_path, "Nishfleet/0509")
    assert done.returncode == 0
    assert edits(calls) == {"1": "needs-triage", "4": "needs-orchestrator"}


def test_per_run_cap_is_20(tmp_path):
    done, calls = run(tmp_path, "Nishfleet/fleet-ops", [issue(n) for n in range(1, 31)])
    assert done.returncode == 0
    assert len(edits(calls)) == 20


def test_empty_list_edits_nothing_and_stays_green(tmp_path):
    done, calls = run(tmp_path, "Nishfleet/fleet-ops", [])
    assert done.returncode == 0 and calls == []


def test_failed_read_fails_loud(tmp_path):
    done, calls = run(tmp_path, "Nishfleet/fleet-ops", api_fails=True)
    assert done.returncode != 0 and calls == []


def test_triggers_are_sweep_only_and_opened_stays_out():
    cond = subprocess.run(["yq", ".jobs.label-unlabelled.if", WF], check=True,
                          capture_output=True, text=True).stdout
    assert "schedule" in cond and "workflow_dispatch" in cond
    on = subprocess.run(["yq", "-o=json", ".on.issues.types", WF], check=True,
                        capture_output=True, text=True).stdout
    assert "opened" not in json.loads(on)
