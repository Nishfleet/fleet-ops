"""Every case in config/sweep-rework-cases.json maps to its recorded verdict
under the sweep's own RED_REWORK program, read out of agent-dispatch.yml with
the CHECK_DEFS it shares with the missing-checks case, never a copy.

The needle set pins the wiring: the program's verdict feeds the sweep's pick
list, and a live newest run is still skipped.
"""
import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
WF = ROOT / ".github/workflows/agent-dispatch.yml"
CASES = ROOT / "config/sweep-rework-cases.json"
REDISPATCH = '.jobs.list.steps[] | select(.id == "redispatch")'
NEEDLES = ('"$CHECK_DEFS $RED_REWORK"', '--argjson d "$red"', "$o[], $d[]", "run live, skip")


def _yq(expr):
    run = subprocess.run(["yq", f"{REDISPATCH} | {expr}", str(WF)], check=True, capture_output=True, text=True)
    return run.stdout


def _jq(args, stdin=""):
    return subprocess.run(["jq", *args], check=True, capture_output=True, text=True, input=stdin).stdout


def test_sweep_wiring():
    defs = _yq(".env.CHECK_DEFS")
    prog = _yq(".env.RED_REWORK")
    assert defs and defs != "null"
    assert prog and prog != "null"
    run = _yq(".run")
    for needle in NEEDLES:
        assert needle in run, f"missing sweep wiring: {needle}"


def test_red_rework_case_table():
    defs = _yq(".env.CHECK_DEFS")
    prog = _yq(".env.RED_REWORK")
    for line in _jq(["-c", ".cases[]", str(CASES)]).splitlines():
        case = json.loads(line)
        source = _jq(["-c", "--argjson", "c", line, ".base * $c.set | {pr, issue, comments}", str(CASES)])
        got = _jq(["-r", f"{defs} {prog} | .reason"], stdin=source)
        want = _jq(["-r", ".want"], stdin=line)
        assert got == want, f"case {case.get('id')}: got {got}, want {want}"
