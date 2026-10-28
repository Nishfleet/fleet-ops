from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = sorted((ROOT / ".github/workflows").glob("*.yml"))
PILOT = ROOT / "rootfs/etc/systemd/system/actions.runner.Nishfleet.netcup-agent-1.service.d/30-pilot-user.conf"
PILOT_TASKS = ROOT / "ansible/tasks/pilot-and-retired-runners.yml"
PILOT_HOME = "/var/lib/fleet-runner"
KEY = "nishfleet-worker.private-key.pem"


def _pilot_tasks() -> dict:
    return {task["name"]: task for task in yaml.safe_load(PILOT_TASKS.read_text())}


def _unit_home() -> str:
    line = next(l for l in PILOT.read_text().splitlines() if l.startswith("Environment=HOME="))
    return line.split("=", 2)[2]


def test_every_key_read_takes_the_systemd_credential_first():
    lines = [l.strip() for w in WORKFLOWS for l in w.read_text().splitlines() if l.strip().startswith("keyfile=")]
    assert lines, "no workflow reads the worker App key"
    for line in lines:
        assert line == f'keyfile="${{CREDENTIALS_DIRECTORY:-$HOME/.config/fleet-worker}}/{KEY}"', (
            "a runner whose uid has no key under HOME (the fleet-runner pilot) fails this step: " + line
        )


def test_the_pilot_runner_gets_the_key_as_a_credential():
    text = PILOT.read_text()
    assert "User=fleet-runner" in text
    line = next((l for l in text.splitlines() if l.startswith(f"LoadCredential={KEY}:")), "")
    assert line.endswith(f"/.config/fleet-worker/{KEY}"), (
        "the pilot runs as fleet-runner, which has no copy of the key, so arm and the App-token steps fail on it"
    )


def test_the_pilot_home_is_the_directory_the_tasks_prepare_for_that_uid():
    """The job's HOME comes from the unit drop-in and the copied .env, and both name the pilot's own home."""
    home = _unit_home()
    assert home == PILOT_HOME
    tasks = _pilot_tasks()
    assert tasks["Give the pilot runner its own HOME in the runner environment"]["ansible.builtin.lineinfile"]["line"] == f"HOME={home}"


def test_the_review_refuses_to_run_without_its_reviewer_prompt():
    """A review that finds no rules still answers, so agent.yml stops a runner whose HOME has no reviewer prompt before any model call (fleet-ops#10517)."""
    text = (ROOT / ".github/workflows/agent.yml").read_text()
    for f in ("$HOME/AGENTS.md", "fleet-ops-deploy-clone/prompts/risky-review.md"):
        assert f in text, f"the review must name {f} in its readability check"
    assert '[ -r "$f" ] || retry' in text, "the review must stop with retry when a reviewer prompt is missing or unreadable"
    assert "system_prompt=$(cat" not in text, "the buggy guard captured the prompt in a subshell whose exit 1 only ended the subshell"
    assert '--append-system-prompt "$(cat "$HOME/AGENTS.md"' in text, "claude must still be fed the reviewer prompt inline"
