"""The shapes three control-flow steps must keep (fleet-ops#9278).

The arm step carried its own path allowlist, which drifted from
config/risky-paths.json, the list hold-risky already reads, so the step must not
classify paths at all: the fake gh fails on a changed-files or changedFiles read.
The start-next step toggled agent-ready, and the run the second label event
started displaced the run the first one started, so it dispatches the issue by
number. A close stripped the closed issue's labels and left an agent-blocked
dependent parked with no event left to free it, so it requeues a dependent that
has no open blocker and no other recorded reason. The review job's session pin is
here too: without it a held PR gets no review to clear it (fleet-ops#9428).
"""
import os
import pathlib
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
AGENT = ROOT / ".github/workflows/agent.yml"
DISPATCH = ROOT / ".github/workflows/agent-dispatch.yml"

ARM = '.jobs.work.steps[] | select(.name == "Arm auto-merge as the App") | .run'

FAKE_GH = """#!/usr/bin/env bash
case "$*" in
  *"--json state --jq .state"*) echo OPEN ;;
  *"--json body --jq .body"*) echo 'Closes #1' ;;
  *"--json number --jq .number"*) echo 7 ;;
  "label create "*) ;;
  *"pr checks "*"--required"*) [ -z "$RED" ] || { echo "$RED"; exit 1; } ; exit 8 ;;
  *"pr checks "*) exit 8 ;;
  *"--auto --squash"*) touch "$STATE/armed" ;;
  *"--disable-auto"*) touch "$STATE/disarmed" ;;
  *changedFiles*|*"/files"*) echo "fake gh: the arm step read the diff again: $*" >&2; exit 1 ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 1 ;;
esac
"""


def step(path, expr):
    done = subprocess.run(["yq", expr, str(path)], capture_output=True, text=True, timeout=120)
    assert done.returncode == 0 and done.stdout.strip() not in ("", "null"), f"{path.name}: {expr} found no step"
    return done.stdout


@pytest.fixture(scope="module")
def arm(tmp_path_factory):
    script = tmp_path_factory.mktemp("arm") / "arm.sh"
    script.write_text(step(AGENT, ARM))
    bindir = tmp_path_factory.mktemp("bin")
    (bindir / "gh").write_text(FAKE_GH)
    (bindir / "gh").chmod(0o755)

    def run(tmp_path, red=""):
        state = tmp_path / "state"
        state.mkdir()
        env = dict(os.environ, PATH=f"{bindir}:{os.environ['PATH']}", STATE=str(state),
                   REPO="Nishfleet/drive", REF="claim/issue-1", GH_TOKEN="fake", RED=red)
        done = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", str(script)],
                              env=env, capture_output=True, text=True, timeout=120)
        return done, state

    return run


def test_the_arm_step_arms_with_pending_or_green_checks_only(arm, tmp_path):
    done, state = arm(tmp_path)
    assert done.returncode == 0, done.stdout + done.stderr
    assert (state / "armed").exists(), done.stdout
    assert not (state / "disarmed").exists(), done.stdout


def test_a_red_required_check_disarms_and_fails_the_step(arm, tmp_path):
    done, state = arm(tmp_path, red="ci")
    assert done.returncode == 1, done.stdout + done.stderr
    assert (state / "disarmed").exists(), done.stdout
    assert not (state / "armed").exists(), done.stdout
    assert "not armed" in done.stdout + done.stderr


def test_the_arm_step_keeps_no_path_list_of_its_own():
    run = step(AGENT, ARM)
    for gone in ("pulls/$n/files", "safe='^", "policy='^"):
        assert gone not in run, (
            f"the arm step classifies paths again ({gone}): config/risky-paths.json is the one source")


def test_the_start_next_step_dispatches_the_issue_it_picked():
    run = step(AGENT, '.jobs.work.steps[] | select(.name == "Start the next ready issue") | .run')
    assert "--remove-label agent-ready" not in run, (
        "the start-next step toggles agent-ready again: the second label event cancels the dispatch "
        "the first one started, so dispatch the issue by number")
    assert 'gh workflow run agent-dispatch.yml -R "$REPO" -f "issue=$n"' in run


def test_a_close_requeues_a_parked_dependent_only_when_nothing_else_blocks_it():
    run = step(DISPATCH, ".jobs.close-claim.steps[0].run")
    assert "dependencies/blocking" in run
    assert 'IN("needs-split","needs-orchestrator","needs-nish-decision","needs-coordinator","handoff-ended","epic")' in run, (
        "a park label that records a decision must keep the dependent parked")
    assert "(proposal|blocked-on):" in run, "a worker's own park note must keep the dependent parked"
    assert "--remove-label agent-blocked --add-label agent-ready" in run


def test_the_review_job_names_its_router_session():
    done = subprocess.run(
        ["yq", '-e', '.jobs.review.env.FLEET_TASK_ID | test("^run-")', str(AGENT)],
        capture_output=True, text=True, timeout=120)
    assert done.returncode == 0, (
        "the review job sets no FLEET_TASK_ID, so its litellm call has no session id "
        "and a held PR never gets the review that clears it (fleet-ops#9428)")
