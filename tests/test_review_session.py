"""The review job names its router session, so a held PR gets the review that
clears it (fleet-ops#9428)."""
import pathlib
import subprocess

AGENT = pathlib.Path(__file__).resolve().parents[1] / ".github/workflows/agent.yml"


def test_the_review_job_names_its_router_session():
    done = subprocess.run(
        ["yq", '-e', '.jobs.review.env.FLEET_TASK_ID | test("^run-")', str(AGENT)],
        capture_output=True, text=True, timeout=120)
    assert done.returncode == 0, (
        "the review job sets no FLEET_TASK_ID, so its litellm call has no session id "
        "and a held PR never gets the review that clears it (fleet-ops#9428)")
