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
  api) case $2 in */labels/*) [ -e "$FAKE_DIR/labels-exist" ]; exit ;; esac
       [ -e "$FAKE_DIR/api-fails" ] && exit 1; jq -r "$q" "$FAKE_DIR/issues.json" ;;
  label) echo "$*" >> "$FAKE_DIR/labels" ;;
  issue) [ -e "$FAKE_DIR/edit-fails" ] && exit 1; echo "$*" >> "$FAKE_DIR/calls" ;;
esac
"""

OLD = "2026-01-01T00:00:00Z"
YOUNG = (datetime.now(timezone.utc) - timedelta(seconds=60)).strftime("%Y-%m-%dT%H:%M:%SZ")


def issue(n, assoc="MEMBER", login="nish3451", created=OLD, labels=(), **extra):
    return {"number": n, "author_association": assoc, "user": {"login": login}, "created_at": created,
            "labels": [{"name": x} for x in labels], **extra}


ISSUES = [
    issue(1),
    issue(8, "COLLABORATOR", "helper"),
    issue(9, "MEMBER", "nishfleet-worker[bot]"),
    issue(2, labels=["agent-ready"]),
    issue(3, pull_request={}),
    issue(4, "CONTRIBUTOR", "nishfleet-worker[bot]"),
    issue(5, "NONE", "driveby"),
    issue(6, "CONTRIBUTOR", "dependabot[bot]"),
    issue(7, created=YOUNG),
]


def job(expr):
    return subprocess.run(["yq", "-o=json", f".jobs.label-unlabelled{expr}", WF],
                          check=True, capture_output=True, text=True).stdout


def sweep_step():
    return json.loads(job('.steps[] | select(.run | contains("gh issue edit"))'))


def run(tmp_path, repo, issues=ISSUES, api_fails=False, edit_fails=False, labels_exist=False):
    step = sweep_step()["run"]
    tmp_path.mkdir(parents=True, exist_ok=True)
    (tmp_path / "bin").mkdir()
    gh = tmp_path / "bin/gh"
    gh.write_text(FAKE_GH)
    gh.chmod(0o755)
    (tmp_path / "issues.json").write_text(json.dumps(issues))
    (tmp_path / "calls").touch()
    if labels_exist:
        (tmp_path / "labels-exist").touch()
    if api_fails:
        (tmp_path / "api-fails").touch()
    if edit_fails:
        (tmp_path / "edit-fails").touch()
    env = {**os.environ, "PATH": f"{tmp_path/'bin'}:{os.environ['PATH']}",
           "FAKE_DIR": str(tmp_path), "REPO": repo, "GH_TOKEN": "x"}
    done = subprocess.run(["bash", "-c", step], env=env, capture_output=True, text=True)
    (tmp_path / "labels").touch()
    return done, (tmp_path / "calls").read_text().splitlines()


def edits(calls):
    return {c.split()[2]: c.split()[-1] for c in calls if c.startswith("issue edit")}


def test_fleet_ops_owner_gets_needs_orchestrator_others_needs_triage(tmp_path):
    done, calls = run(tmp_path, "Nishfleet/fleet-ops")
    assert done.returncode == 0
    assert edits(calls) == {"1": "needs-orchestrator", "8": "needs-triage"}


def test_product_repo_issues_get_needs_triage_only(tmp_path):
    done, calls = run(tmp_path, "Nishfleet/0509")
    assert done.returncode == 0
    assert edits(calls) == {"1": "needs-triage", "8": "needs-triage"}


def test_bot_filed_issues_are_never_labelled(tmp_path):
    bots = [issue(n, a, "nishfleet-worker[bot]") for n, a in ((1, "MEMBER"), (2, "CONTRIBUTOR"), (3, "OWNER"))]
    for repo in ("Nishfleet/fleet-ops", "Nishfleet/0509"):
        done, calls = run(tmp_path / repo.split("/")[1], repo, bots)
        assert done.returncode == 0 and calls == []


def test_labels_are_created_only_when_missing_and_never_forced(tmp_path):
    done, _ = run(tmp_path / "a", "Nishfleet/fleet-ops")
    made = (tmp_path / "a/labels").read_text().splitlines()
    assert len(made) == 2 and not any("--force" in m or "--description" in m for m in made)
    done, _ = run(tmp_path / "b", "Nishfleet/fleet-ops", labels_exist=True)
    assert (tmp_path / "b/labels").read_text() == ""


def test_per_run_cap_is_5(tmp_path):
    done, calls = run(tmp_path, "Nishfleet/fleet-ops", [issue(n) for n in range(1, 31)])
    assert done.returncode == 0
    assert len(edits(calls)) == 5


def test_empty_list_edits_nothing_and_stays_green(tmp_path):
    done, calls = run(tmp_path, "Nishfleet/fleet-ops", [])
    assert done.returncode == 0 and calls == []


def test_failed_read_fails_loud(tmp_path):
    done, calls = run(tmp_path, "Nishfleet/fleet-ops", api_fails=True)
    assert done.returncode != 0 and calls == []


def test_failed_edit_fails_loud(tmp_path):
    done, calls = run(tmp_path, "Nishfleet/fleet-ops", edit_fails=True)
    assert done.returncode != 0 and calls == []


def test_edit_credential_is_the_app_token_on_the_app_runner():
    assert sweep_step()["env"]["GH_TOKEN"] == "${{ steps.app-token.outputs.token }}"
    assert "GH_TOKEN" not in sweep_step()["run"]
    assert json.loads(job(".runs-on")) == ["self-hosted", "agent"]
    assert json.loads(job('.steps[] | select(.id == "app-token") | .with.permission-issues')) == "write"
    assert json.loads(job('.steps[] | select(.id == "app-token") | .uses')).endswith("/.github/actions/app-token@main")


def test_label_create_failure_is_not_hidden():
    assert "|| true" not in sweep_step()["run"]


def test_triggers_are_sweep_only_and_opened_stays_out():
    cond = json.loads(job(".if"))
    assert "schedule" in cond and "workflow_dispatch" in cond
    assert "github.event_name" in cond and "github.event.action" not in cond
    on = subprocess.run(["yq", "-o=json", ".on.issues.types", WF], check=True,
                        capture_output=True, text=True).stdout
    assert "opened" not in json.loads(on)


def test_no_workflow_keeps_a_private_copy_of_the_key_steps():
    for wf in ("agent.yml", "agent-dispatch.yml"):
        text = (ROOT / ".github/workflows" / wf).read_text()
        assert "create-github-app-token" not in text and "private-key.pem" not in text
