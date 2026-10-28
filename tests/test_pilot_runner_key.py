from pathlib import Path

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
    for f in map(ROOT.joinpath, (".github/workflows/agent.yml", ".github/workflows/agent-dispatch.yml")):
        text = f.read_text()
        assert KEY not in text and "create-github-app-token" not in text, f"{f.name} bypasses the app-token action"
