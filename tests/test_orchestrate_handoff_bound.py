"""Fleet-ops#11167: the orchestrate lane keeps the per-issue concurrency group
that fleet-ops#9700 fixed, and its admission step polls the in-flight hand-off
runs of the same lane: a sixth concurrent hand-off re-checks every 90 seconds
instead of failing, so at most five hand-off jobs run at once near the plans'
measured carry of four to six."""
import pathlib
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/agent-dispatch.yml"
RETURN = "group: orchestrate-${{ github.repository }}-${{ github.event.issue.number || inputs.issue }}"


def _orchestrate():
    return yaml.safe_load(WORKFLOW.read_text())["jobs"]["orchestrate"]


def _wait_step():
    job = _orchestrate()
    return next(s for s in job["steps"] if s.get("id") == "slot")


def _script():
    return _wait_step()["run"]


def test_the_per_issue_group_stays_intact():
    assert f'concurrency:\n      {RETURN}\n      cancel-in-progress: false' in WORKFLOW.read_text()


def test_the_wait_step_runs_after_the_go_check():
    wait = _wait_step()
    assert wait["if"] == "steps.issue.outputs.go == 'true'"
    assert wait["env"]["SLOTS"] == 5


def test_the_poll_counts_only_this_lane_excluding_itself():
    script = _script()
    assert '.name | IN("orchestrate") or endswith(" / orchestrate")' in script
    assert '[ "$id" = "$GITHUB_RUN_ID" ] && continue' in script
    assert "runs?status=in_progress&per_page=100" in script


def test_a_sixth_hand_off_queues_and_rechecks_instead_of_failing():
    script = _script()
    assert [line for line in script.splitlines() if line.strip() == "sleep 90"]
    assert '[ "$in_flight" -ge "$SLOTS" ]' in script


def test_the_poll_fails_closed_on_a_rate_limit_brownout():
    script = _script()
    assert script.count("keeping issue $ISSUE waiting for a slot") == 2
    assert "echo \"::warning::orchestrate: the run list failed" in script
    assert "echo \"::warning::orchestrate: the job read failed on run $id" in script
