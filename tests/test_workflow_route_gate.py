"""The workflow-file route gate in agent.yml and the worker's push-refusal route.

Runs the gate's real jq condition (read out of agent.yml, never copied) against
issue bodies: the directory path on any repo, a relative path fragment on a
repo that is not fleet-ops, a bare file name on fleet-ops's own list, and
prose that must not route. Asserts the worker prompt routes the App's push
refusal to the orchestrator with the exact routed comment (fleet-ops#9294).
"""
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AGENT = ROOT / ".github/workflows/agent.yml"
WORKER = ROOT / "prompts/worker.md"

REFUSAL = "refusing to allow a GitHub App to create or update workflow"
ROUTED = "routed: push refused for .github/workflows/**; handed to the orchestrator"


def gate_program():
    text = AGENT.read_text()
    match = re.search(r"--argjson fo \"\$fleet_ops\" '([^']+)'", text)
    assert match, "workflow-file gate condition not found in agent.yml"
    return match.group(1)


def routes(issue, fleet_ops):
    out = subprocess.run(
        [
            "jq", "-e", "--arg", "p", ".github/workflows/",
            "--argjson", "fo", "true" if fleet_ops else "false",
            gate_program(),
        ],
        input=issue, text=True, capture_output=True,
    )
    return out.returncode == 0


def test_directory_path_routes_on_any_repo():
    issue = '{"title": "Deploy reruns the suite", "body": "delete the steps in .github/workflows/deploy-production.yml"}'
    assert routes(issue, fleet_ops=False)
    assert routes(issue, fleet_ops=True)


def test_relative_path_fragment_routes_off_fleet_ops():
    issue = '{"title": "Deploy reruns the suite", "body": "**Evidence:** workflows/deploy-production.yml:41-42 runs npm test"}'
    assert routes(issue, fleet_ops=False)


def test_relative_yaml_routes_off_fleet_ops():
    issue = '{"title": "Tune the nightly", "body": "the schedule in workflows/nightly.yaml is wrong"}'
    assert routes(issue, fleet_ops=False)


def test_bare_listed_name_routes_on_fleet_ops():
    issue = '{"title": "fix agent.yml", "body": "the gate drops comments"}'
    assert routes(issue, fleet_ops=True)


def test_prose_yaml_without_a_path_does_not_route():
    issue = '{"title": "Fix config", "body": "see docs/notes.md and pnpm-lock.yaml"}'
    assert not routes(issue, fleet_ops=False)


def test_worker_prompt_routes_the_push_refusal():
    step5a = re.search(r"^5a\..*?(?=^5b\.)", WORKER.read_text(), re.S | re.M).group(0)
    assert REFUSAL in step5a
    assert ROUTED in step5a
    assert "--add-label needs-orchestrator --remove-label agent-ready,agent-in-progress" in step5a
