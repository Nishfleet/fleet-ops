"""The shapes three control-flow steps must keep (fleet-ops#9278).

The arm step carried its own path allowlist, which drifted from
config/risky-paths.json, the list hold-risky already reads, so the step must not
classify paths at all. The start-next step toggled agent-ready, and the run the
second label event started displaced the run the first one started, so it
dispatches the issue by number. A close stripped the closed issue's labels and
left an agent-blocked dependent parked with no event left to free it, so it
requeues a dependent that has no open blocker. The review job's session pin is
here too: without it a held PR gets no review to clear it (fleet-ops#9428).
"""
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
AGENT = ROOT / ".github/workflows/agent.yml"
DISPATCH = ROOT / ".github/workflows/agent-dispatch.yml"


def step(path, expr):
    done = subprocess.run(["yq", expr, str(path)], capture_output=True, text=True, timeout=120)
    assert done.returncode == 0 and done.stdout.strip() not in ("", "null"), f"{path.name}: {expr} found no step"
    return done.stdout


def test_the_arm_step_keeps_no_path_list_of_its_own():
    run = step(AGENT, '.jobs.work.steps[] | select(.name == "Arm auto-merge as the App") | .run')
    for gone in ("pulls/$n/files", "safe='^", "policy='^"):
        assert gone not in run, (
            f"the arm step classifies paths again ({gone}): config/risky-paths.json is the one source")
    assert "gh label create needs-coordinator" in run
    assert 'gh pr merge "$REF" -R "$REPO" --auto --squash' in run


def test_the_start_next_step_dispatches_the_issue_it_picked():
    run = step(AGENT, '.jobs.work.steps[] | select(.name == "Start the next ready issue") | .run')
    assert "--remove-label agent-ready" not in run, (
        "the start-next step toggles agent-ready again: the second label event cancels the dispatch "
        "the first one started, so dispatch the issue by number")
    assert 'gh workflow run agent-dispatch.yml -R "$REPO" -f "issue=$n"' in run


def test_a_close_requeues_a_parked_dependent():
    run = step(DISPATCH, ".jobs.close-claim.steps[0].run")
    assert "dependencies/blocking" in run
    assert "--remove-label agent-blocked --add-label agent-ready" in run


def test_the_review_job_names_its_router_session():
    done = subprocess.run(
        ["yq", '-e', '.jobs.review.env.FLEET_TASK_ID | test("^run-")', str(AGENT)],
        capture_output=True, text=True, timeout=120)
    assert done.returncode == 0, (
        "the review job sets no FLEET_TASK_ID, so its litellm call has no session id "
        "and a held PR never gets the review that clears it (fleet-ops#9428)")
