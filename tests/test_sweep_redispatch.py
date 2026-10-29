"""The claim-PR re-dispatch is its own step in agent-dispatch.yml's list job (fleet-ops#9368).

It reads PRs, issues and runs, and any one read fault used to abort the sweep before the pick, so an
hourly sweep produced no refs at all. It now runs as a continue-on-error step that feeds the pick
through a step output; this pins the split, the order and the wiring.
"""
import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
WF = str(ROOT / ".github/workflows/agent-dispatch.yml")


def _steps():
    out = subprocess.run(["yq", "-o=json", ".jobs.list.steps", WF], check=True,
                         capture_output=True, text=True).stdout
    return json.loads(out)


def test_redispatch_is_a_continue_on_error_step_before_the_pick():
    ids = [s.get("id") for s in _steps()]
    assert ids.index("redispatch") < ids.index("list")
    step = _steps()[ids.index("redispatch")]
    assert step["continue-on-error"] is True
    assert "if" not in step
    assert "prs=${prs:-[]}" in step["run"]


def test_the_pick_reads_the_claim_prs_as_a_step_output():
    steps = {s.get("id"): s for s in _steps()}
    assert steps["list"]["env"]["PRS"] == "${{ steps.redispatch.outputs.prs }}"
    assert '--argjson prs "${PRS:-[]}"' in steps["list"]["run"]
    assert "refs=${refs:-[]}" in steps["list"]["run"]
    assert "merge-queue read failed" in steps["redispatch"]["run"]
    assert "merge-queue read failed" not in steps["list"]["run"]
