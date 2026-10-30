"""fleet-ops#9420: the arm step's allowlist knows each repo's own code layout.

Every case runs the work job's arm step, read out of agent.yml, against a fake gh,
so the allowlist cannot drift from what the step reads. drive keeps its code in
src/ and its tests in test/, so a drive PR touching either arms the way a 0509 app
PR does, and every other repo keeps the shared list. The controls still hold: a
migration, a workflow, a file at the repo root, an empty file list, the 3000-file
cut, a fleet-ops policy doc, a test helper beside the test files, src/ nested
under another directory, and a repo the case does not name. The last test pins the
review job's FLEET_TASK_ID, whose absence left a held PR with no review to clear it
(fleet-ops#9428). That money, secrets and data inside drive's src/ still hold is
config/risky-paths.json's own business: its drive cases run in the same job.
"""
import os
import pathlib
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
AGENT = ROOT / ".github/workflows/agent.yml"

FAKE_GH = """#!/usr/bin/env bash
case "$*" in
  *"--json state --jq .state"*) echo OPEN ;;
  *"--json body --jq .body"*) echo 'Closes #1' ;;
  *"--json number --jq .number"*) echo 7 ;;
  *"--json changedFiles --jq .changedFiles"*) echo "$CHANGED" ;;
  *"/pulls/7/files"*) printf '%s\\n' "$FILES" ;;
  "label create "*) ;;
  *"pr edit "*) touch "$STATE/labelled" ;;
  *"pr checks "*"--required"*) exit 8 ;;
  *"pr checks "*) ;;
  *"--auto --squash"*) touch "$STATE/armed" ;;
  *"--disable-auto"*) touch "$STATE/disarmed" ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 1 ;;
esac
"""

CASES = [
    ("drive-src-and-test", "Nishfleet/drive", 2, ["src/branch-jobs.js", "test/branch-jobs.test.mjs"], False),
    ("drive-src", "Nishfleet/drive", 1, ["src/branch-jobs.js"], False),
    ("drive-docs-and-test", "Nishfleet/drive", 2, ["docs/runbook.md", "test/deploy-secrets.test.mjs"], False),
    ("drive-nested-test", "Nishfleet/drive", 1, ["test/unit/x.test.mjs"], False),
    ("drive-upper-repo", "NISHFLEET/DRIVE", 1, ["src/a.js"], False),
    ("drive-test-helper", "Nishfleet/drive", 1, ["test/d1-sqlite.mjs"], True),
    ("drive-src-under-other-dir", "Nishfleet/drive", 1, ["lib/src/a.js"], True),
    ("drive-migration", "Nishfleet/drive", 1, ["migrations/drive/0100_x.sql"], True),
    ("drive-workflow", "Nishfleet/drive", 1, [".github/workflows/ci.yml"], True),
    ("drive-root-file", "Nishfleet/drive", 1, ["package.json"], True),
    ("drive-empty-list", "Nishfleet/drive", 0, [], True),
    ("drive-3000-files", "Nishfleet/drive", 3000, ["src/a.js"], True),
    ("0509-app-route", "Nishfleet/0509", 1, ["app/routes/home.tsx"], False),
    ("0509-src", "Nishfleet/0509", 1, ["src/a.ts"], True),
    ("tether-src", "Nishfleet/tether", 1, ["src/a.ts"], True),
    ("fleet-ops-policy-doc", "Nishfleet/fleet-ops", 1, ["docs/quality-bar.md"], True),
]


@pytest.fixture(scope="module")
def arm_step(tmp_path_factory):
    script = tmp_path_factory.mktemp("arm") / "arm.sh"
    done = subprocess.run(
        ["yq", '.jobs.work.steps[] | select(.name == "Arm auto-merge as the App") | .run', str(AGENT)],
        check=True, capture_output=True, text=True, timeout=120)
    assert done.stdout.strip() not in ("", "null"), "agent.yml has no arm step"
    script.write_text(done.stdout)
    return script


@pytest.fixture(scope="module")
def fake_gh(tmp_path_factory):
    bindir = tmp_path_factory.mktemp("bin")
    (bindir / "gh").write_text(FAKE_GH)
    (bindir / "gh").chmod(0o755)
    return bindir


@pytest.mark.parametrize("name,repo,changed,files,held", CASES, ids=[c[0] for c in CASES])
def test_the_arm_step_reads_a_pr_by_its_paths(arm_step, fake_gh, tmp_path, name, repo, changed, files, held):
    state = tmp_path / name
    state.mkdir()
    env = dict(os.environ, PATH=f"{fake_gh}:{os.environ['PATH']}", STATE=str(state), REPO=repo,
               REF="claim/issue-1", CHANGED=str(changed), FILES="\n".join(files), GH_TOKEN="fake")
    done = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", str(arm_step)],
                          env=env, capture_output=True, text=True, timeout=120)
    assert done.returncode == 0, done.stdout + done.stderr
    assert (state / "labelled").exists() == held, done.stdout
    assert (state / "armed").exists() == (not held), done.stdout
    assert (state / "disarmed").exists() is False, done.stdout


def test_the_review_job_names_its_router_session():
    done = subprocess.run(
        ["yq", '-e', '.jobs.review.env.FLEET_TASK_ID | test("^run-")', str(AGENT)],
        capture_output=True, text=True, timeout=120)
    assert done.returncode == 0, (
        "the review job sets no FLEET_TASK_ID, so its litellm call has no session id "
        "and a held PR never gets the review that clears it (fleet-ops#9428)")
