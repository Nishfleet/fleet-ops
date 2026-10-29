"""fleet-ops#10218, #10456: unlabelled issues get needs-triage from the sweep, 5 a run, in every repo
that runs it. Admit never takes them without a trusted labeller.

The sweep moved out of the list job's shell into control-plane/src/sweep.ts, so the
behaviour itself is tested there, by test/sweep.test.ts (run by tests/test_control_plane_sweep.py). This file
pins what is left in the workflow: the list job runs that one file, no copy of the sweep's jq
programs remains, and the file imports nothing but node builtins.
"""
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
WF = str(ROOT / ".github/workflows/agent-dispatch.yml")
LIST_STEP = '.jobs.list.steps[] | select(.id == "list")'
SWEEP = ROOT / "control-plane/src/sweep.ts"
SUITE = ROOT / "control-plane/test/sweep.test.ts"


def _y(expr):
    return subprocess.run(["yq", f"{LIST_STEP} | {expr}", WF], check=True, capture_output=True, text=True).stdout


def test_the_list_job_runs_the_sweep_file():
    assert _y(".run").strip() == "node control-plane/src/sweep.ts"
    env = _y(".env | keys | join(\",\") | split(\",\") | sort | join(\",\")").strip()
    assert env == "CLOSED,GH_TOKEN,ISSUE", env
    assert _y(".timeout-minutes").strip() == "20"


def test_no_copy_of_the_sweep_is_left_in_the_workflow():
    text = pathlib.Path(WF).read_text()
    for gone in ("CHECK_DEFS", "RED_REWORK", "RUN_LIVE_JQ: |"):
        assert gone not in text, f"{gone} is still in agent-dispatch.yml"
    body = _y(".run")
    assert len(body.strip().splitlines()) == 1, "the list step carries shell again"


def test_the_sweep_imports_nothing_but_node_builtins():
    imports = re.findall(r'^import .* from "([^"]+)";$', SWEEP.read_text(), re.M)
    assert imports, "sweep.ts has no imports; the pin below would pass vacuously"
    assert [i for i in imports if not i.startswith("node:")] == []


def test_the_moved_behaviour_is_tested_where_it_lives():
    text = SUITE.read_text()
    assert 'describe("sweep triage"' in text
    assert "-S no:label -L 5" in text
    assert "needs-triage" in text
