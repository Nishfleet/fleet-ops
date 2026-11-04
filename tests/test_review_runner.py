"""The review runner runs as its own user, apart from the worker lane (decisions ledger 2026-11-04).

https://docs.github.com/en/actions/reference/security/secure-use#hardening-for-self-hosted-runners
"""
from configparser import ConfigParser
from pathlib import Path

import ansible_host

ROOT = Path(__file__).resolve().parents[1]
UNIT = ROOT / "rootfs/etc/systemd/system/fleet-reviewer-runner@.service"


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


def test_three_review_runners_each_in_its_own_directory():
    play = ansible_host.play()
    assert play["vars"]["fleet_reviewer_runner_ids"] == [1, 2, 3]
    start = next(t for t in play["tasks"] if t.get("name") == "Start the review runners")
    assert start["ansible.builtin.systemd_service"]["name"] == "fleet-reviewer-runner@{{ item }}.service"
    assert start["loop"] == "{{ fleet_reviewer_runner_ids }}"
    svc = service()
    assert svc["WorkingDirectory"] == "/var/lib/fleet-reviewer/%i"
    assert svc["ExecStart"] == "/var/lib/fleet-reviewer/%i/bin/runsvc.sh"
    assert not (UNIT.parent / "fleet-reviewer-runner.service").exists()


def test_every_review_runner_directory_gets_the_runner_env_and_path():
    copies = {t["ansible.builtin.copy"]["dest"]: t["loop"] for t in ansible_host.play()["tasks"]
              if t.get("ansible.builtin.copy", {}).get("dest", "").startswith("/var/lib/fleet-reviewer/{{ item }}/")}
    assert copies == {"/var/lib/fleet-reviewer/{{ item }}/.env": "{{ fleet_reviewer_runner_ids }}",
                      "/var/lib/fleet-reviewer/{{ item }}/.path": "{{ fleet_reviewer_runner_ids }}"}


def test_the_first_runner_moves_to_directory_1_after_its_plain_unit_stops():
    names = [t.get("name") for t in ansible_host.play()["tasks"]]
    assert names.index("Stop the review runner's plain unit before its directory moves") \
        < names.index("Move the first review runner to directory 1") \
        < names.index("Make the review runner directories")
