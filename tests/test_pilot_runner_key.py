import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = sorted((ROOT / ".github/workflows").glob("*.yml"))
PILOT = ROOT / "rootfs/etc/systemd/system/actions.runner.Nishfleet.netcup-agent-1.service.d/30-pilot-user.conf"
KEY = "nishfleet-worker.private-key.pem"


def keys(path: Path) -> dict[str, list[str]]:
    found: dict[str, list[str]] = {}
    for line in path.read_text().splitlines():
        if line.startswith(("#", "[")) or "=" not in line:
            continue
        key, value = line.split("=", 1)
        found.setdefault(key, []).append(value)
    return found


def test_every_key_read_takes_the_systemd_credential_first(tmp_path):
    assigns = [line.strip() for workflow in WORKFLOWS for line in workflow.read_text().splitlines() if line.strip().startswith("keyfile=")]
    assert assigns, "no workflow reads the worker App key"
    credential = tmp_path / "credential"
    home = tmp_path / "home"
    credential.mkdir()
    home.mkdir()
    bare = {name: value for name, value in os.environ.items() if name != "CREDENTIALS_DIRECTORY"}
    for assign in assigns:
        shell = f'{assign}\nprintf %s "$keyfile"'
        got = subprocess.run(["bash", "-c", shell], env={**bare, "CREDENTIALS_DIRECTORY": str(credential), "HOME": str(home)}, capture_output=True, text=True, check=True).stdout
        assert got == str(credential / KEY), f"a runner whose uid has no key under HOME (the fleet-runner pilot) fails this step: {assign}"
        got = subprocess.run(["bash", "-c", shell], env={**bare, "HOME": str(home)}, capture_output=True, text=True, check=True).stdout
        assert got == str(home / ".config/fleet-worker" / KEY), assign


def test_the_pilot_runner_gets_the_key_as_a_credential():
    pilot = keys(PILOT)
    assert pilot["User"] == ["fleet-runner"]
    assert pilot["LoadCredential"] == [f"{KEY}:/home/nish/.config/fleet-worker/{KEY}"], (
        "the pilot runs as fleet-runner, which has no copy of the key, so arm and the App-token steps fail on it"
    )
