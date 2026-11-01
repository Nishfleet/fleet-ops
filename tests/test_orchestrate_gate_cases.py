"""The orchestrate job starts only parked work, on trusted senders, and the
Gate detector still parks issues that name a workflow file.

`fire` is the orchestrate job's own `if:` filter, checked here against every
case in config/orchestrate-events.json: orchestrate=off, a labeled
needs-orchestrator event from Nish or an allow-listed bot, and a
workflow_dispatch with a parked issue. The Gate detector is taken out of
agent.yml itself, not copied: an issue whose title or body names a workflow
file is parked for the orchestrator, because no worker App can push one. On
fleet-ops the bare file names of its own workflows count too (fleet-ops#9275).

The needle lists pin that the detector still reads all three workflow files
and that dispatch still carries the event filter.
"""
import json
import os
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
CFG = ROOT / "config/orchestrate-events.json"
DISPATCH = ROOT / ".github/workflows/agent-dispatch.yml"
GATE = ROOT / ".github/workflows/agent.yml"

FILTER = """
            def fire:
              ((.orchestrate // "") != "off") and (
                (.event_name == "issues" and .action == "labeled" and .label == "needs-orchestrator" and
                  ((.sender // "") == "nish3451" or
                   (((.sender // "") | endswith("[bot]")) and ((.sender // "") == "nishfleet-worker[bot]" or (.sender // "") == "github-actions[bot]"))))
                or (.event_name == "workflow_dispatch" and .task == "orchestrate" and ((.issue // "") | length) > 0)
              );
            (.orchestrate_cases | map(select(.want != fire)) | if length == 0 then true else error("orchestrate filter mismatch: \\(map(.id)|join(","))") end)
"""


def _jq(*args, stdin=""):
    return subprocess.run(["jq", *args], check=True, capture_output=True, text=True, input=stdin).stdout


GATE_LINE = re.compile(r"^\s*if jq -e --arg p .\.github/workflows/. --argjson fo")


def _gate_detector():
    for line in GATE.read_text().splitlines():
        if GATE_LINE.match(line):
            return line.split("if ", 1)[1].rsplit(" <<<", 1)[0]
    raise AssertionError("Gate detector line not found in agent.yml")


def test_orchestrate_case_table():
    subprocess.run(["jq", "-e", FILTER, str(CFG)], check=True, capture_output=True, text=True)


def test_gate_detector_case_table():
    detector = _gate_detector()
    for line in _jq("-c", ".gate_cases[]", str(CFG)).splitlines():
        case = json.loads(line)
        repo = case.get("repo", "Nishfleet/0509")
        want = bool(case.get("want_park", case.get("want")))
        env = {"CASE": line, "DETECTOR": detector, "PATH": os.environ["PATH"], "fleet_ops": str(repo.endswith("/fleet-ops")).lower()}
        run = subprocess.run(
            ["bash", "-c", 'jq -c \'{title, body}\' <<<"$CASE" | eval "$DETECTOR" >/dev/null'],
            capture_output=True, text=True, env=env,
        )
        assert (run.returncode == 0) == want, (
            f"gate detector mismatch: {case.get('id')} parks={run.returncode == 0} want={want}"
        )

