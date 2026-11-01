"""Fleet-ops#11167: the orchestrate job runs on its own `handoff` runner label, so
the runners that hold the label are the cap and an extra hand-off queues at GitHub
with no API call. The per-issue concurrency group that fleet-ops#9700 fixed stays."""
import pathlib
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/orchestrate.yml"
GROUP = "group: orchestrate-${{ github.repository }}-${{ github.event.issue.number || inputs.issue }}"


def _orchestrate():
    return yaml.safe_load(WORKFLOW.read_text())["jobs"]["orchestrate"]


def test_the_per_issue_group_stays_intact():
    assert f"concurrency:\n      {GROUP}\n      cancel-in-progress: false" in WORKFLOW.read_text()


def test_every_runner_choice_carries_the_handoff_label():
    runs_on = _orchestrate()["runs-on"]
    assert runs_on.count('"handoff"') == 2
    assert "fleet-ops" in runs_on and '"agent"' in runs_on


def test_no_poller_waits_for_a_slot():
    assert all(s.get("id") != "slot" for s in _orchestrate()["steps"])
    assert "Wait for a free hand-off slot" not in WORKFLOW.read_text()
