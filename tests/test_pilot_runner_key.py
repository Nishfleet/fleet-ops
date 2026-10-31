from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = sorted((ROOT / ".github/workflows").glob("*.yml"))
PILOT = ROOT / "rootfs/etc/systemd/system/actions.runner.Nishfleet.netcup-agent-1.service.d/30-pilot-user.conf"
KEY = "nishfleet-worker.private-key.pem"
REVIEWER_KEY = "nishfleet-reviewer.private-key.pem"
# The worker key falls back to the fleet-worker copy under HOME because the pilot runner's uid has none;
# the reviewer key has no copy outside the credential store of the two review runners (fleet-ops#9521), so its
# read fails closed when the credential is missing instead of falling back to a path.
KEYFILE_LINES = {
    f'keyfile="${{CREDENTIALS_DIRECTORY:-$HOME/.config/fleet-worker}}/{KEY}"',
    f'keyfile="${{CREDENTIALS_DIRECTORY:-}}/{REVIEWER_KEY}"',
}


def test_every_key_read_takes_the_systemd_credential_first():
    lines = [l.strip().split(";")[0] for w in WORKFLOWS for l in w.read_text().splitlines() if l.strip().startswith("keyfile=")]
    assert lines, "no workflow reads an App key"
    for line in lines:
        assert line in KEYFILE_LINES, (
            "a runner whose uid has no key under HOME (the fleet-runner pilot) fails this step: " + line
        )


def test_the_pilot_runner_gets_the_key_as_a_credential():
    text = PILOT.read_text()
    assert "User=fleet-runner" in text
    line = next((l for l in text.splitlines() if l.startswith(f"LoadCredential={KEY}:")), "")
    assert line.endswith(f"/.config/fleet-worker/{KEY}"), (
        "the pilot runs as fleet-runner, which has no copy of the key, so arm and the App-token steps fail on it"
    )
