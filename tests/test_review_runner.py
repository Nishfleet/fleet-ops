"""The review runner runs as its own user, apart from the worker lane (decisions ledger 2026-11-04).

https://docs.github.com/en/actions/reference/security/secure-use#hardening-for-self-hosted-runners
"""
from configparser import ConfigParser
from pathlib import Path

import ansible_host

ROOT = Path(__file__).resolve().parents[1]
UNIT = ROOT / "rootfs/etc/systemd/system/fleet-reviewer-runner.service"


def user_tasks():
    return [t["ansible.builtin.user"] for t in ansible_host.play()["tasks"]
            if t.get("ansible.builtin.user", {}).get("name") == "fleet-reviewer"]


def service():
    unit = ConfigParser(strict=False, interpolation=None)
    unit.optionxform = str
    unit.read_string(UNIT.read_text())
    return unit["Service"]


def test_the_play_creates_fleet_reviewer_and_never_removes_it():
    assert [t.get("state", "present") for t in user_tasks()] == ["present"]


def test_the_runner_runs_as_fleet_reviewer_away_from_the_worker_and_nish_homes():
    svc = service()
    assert (svc["User"], svc["Group"]) == ("fleet-reviewer", "fleet-reviewer")
    assert svc["ProtectHome"] == "yes"
    assert svc["InaccessiblePaths"] == "-/var/lib/fleet-runner"
    assert "LoadCredential" not in svc
