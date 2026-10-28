from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/actions/app-token/action.yml"
PILOT = ROOT / "rootfs/etc/systemd/system/actions.runner.Nishfleet.netcup-agent-1.service.d/30-pilot-user.conf"
KEY = "nishfleet-worker.private-key.pem"


def test_the_key_read_takes_the_systemd_credential_first():
    lines = [l.strip() for l in WORKFLOW.read_text().splitlines() if l.strip().startswith("keyfile=")]
    assert lines, "app-token action no longer reads the worker App key"
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


def test_app_token_fails_loud_with_no_permission():
    assert 'needs at least one permission-* input"; exit 1' in WORKFLOW.read_text()


def test_no_workflow_keeps_its_own_key_or_mint_step():
    for f in (ROOT / ".github/workflows").glob("*.yml"):
        if f.name == "ci.yml":  # holds the guard's test fixtures, not a key read
            continue
        text = f.read_text()
        assert KEY not in text and "create-github-app-token" not in text, f"{f.name} bypasses the app-token action"


def _steps():
    return yaml.safe_load(WORKFLOW.read_text())["runs"]["steps"]


def test_every_inner_step_runs_under_failure_and_cancelled():
    # A caller with `if: failure() || cancelled()` skips inner steps that default to success().
    for step in _steps():
        assert str(step.get("if")).replace(" ", "") == "always()", f"inner step without if: always(): {step}"


def test_app_token_fails_loud_on_an_empty_token():
    last = _steps()[-1]
    assert "steps.mint.outputs.token" in last["env"]["TOKEN"]
    assert '[ -n "$TOKEN" ] ||' in last["run"] and "exit 1" in last["run"]
