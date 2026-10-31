"""Every case in config/stuck-pr-cases.json maps to its recorded class under
the stuck-prs job's own STUCK program, read out of agent-dispatch.yml, never a
copy.

The needle set pins the wiring: the verdict feeds the four lists, each list
starts its agent.yml job, a deleted claim issue is filed not fatal, and the
job's APPROVERS match the coordinator-approval gate's.
"""
import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
WF = ROOT / ".github/workflows/agent-dispatch.yml"
GATE = ROOT / ".github/workflows/agent.yml"
CASES = ROOT / "config/stuck-pr-cases.json"
FIND = '.jobs.stuck-prs.steps[] | select(.id == "find")'
NEEDLES = (
    '--arg who "$APPROVERS" --argjson cut "$(( $(date +%s) - 3600 ))" "$STUCK"',
    'echo "review=$review"',
    'echo "arm=$arm"',
    'echo "rework=$rework"',
    'echo "file=$file"',
    "(HTTP (404|410)",
    "run live, skip",
)
LISTS = {"stuck-review": "review_pr", "stuck-arm": "arm_pr", "stuck-rework": "ref", "stuck-file": "stuck_pr"}


def _yq(expr, wf=WF):
    return subprocess.run(["yq", expr, str(wf)], check=True, capture_output=True, text=True).stdout


def _jq(args, stdin=""):
    return subprocess.run(["jq", *args], check=True, capture_output=True, text=True, input=stdin).stdout


def test_stuck_wiring():
    prog = _yq(f'{FIND} | .env.STUCK')
    who = _yq(f'{FIND} | .env.APPROVERS')
    assert prog and prog != "null", "STUCK missing"
    assert who == _yq(".env.APPROVERS"), "APPROVERS not the coordinator-approval gate"
    run = _yq(f'{FIND} | .run')
    for needle in NEEDLES:
        assert needle in run, f"missing stuck-prs wiring: {needle}"
    for job, slot in LISTS.items():
        assert _yq(f'.jobs."{job}".needs').strip() == "stuck-prs", f"{job} is not wired to stuck-prs"
        assert _yq(f'.jobs."{job}".with.{slot}').strip() != "null", f"{job} is not wired to stuck-prs"
    assert _yq(".jobs.stuck.if", GATE).strip() != "null", "agent.yml has no stuck job"


def test_stuck_case_table():
    prog = _yq(f'{FIND} | .env.STUCK').strip()
    who = _yq(f'{FIND} | .env.APPROVERS').strip()
    lines = _jq(["-c", ".cases[]", str(CASES)]).splitlines()
    assert len(lines) > 0, "config/stuck-pr-cases.json gave no cases"
    for line in lines:
        case = json.loads(line)
        source = _jq(["-c", "--argjson", "c", line, ".base * $c.set | {pr, comments, red}", str(CASES)])
        cut = json.dumps(case.get("cut", 1793318400))
        got = _jq(["-r", "--arg", "who", who, "--argjson", "cut", cut, f"{prog} | .class"], stdin=source)
        want = _jq(["-r", ".want"], stdin=line)
        assert got == want, f"case {case.get('id')}: got {got}, want {want}"
