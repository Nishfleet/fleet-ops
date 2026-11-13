"""The Claude engine's runners run as their own user, and its seat tokens stay in that home (fleet-ops#11958).

The lane's two one-year Team seat tokens are the Claude engine's login, so the pool that
runs it is built the way the review runner pool is built: its own user fleet-claude with
its own home, two runners, and the two seat files copied into that home — never into the
shared agent runners' home, which every cheap-engine job can read and whose run logs are
public. fleet-claude gets the packaged claude and its seats and nothing else: no router
key, no git credential, no App key. The unit's PATH names no job-writable folder, so
nothing a job writes is ever searched before the system directories.
https://docs.github.com/en/actions/reference/security/secure-use#hardening-for-self-hosted-runners
https://code.claude.com/docs/en/authentication#generate-a-long-lived-token
"""
import json
from configparser import ConfigParser
from pathlib import Path

import ansible_host
import yaml

ROOT = Path(__file__).resolve().parents[1]
UNIT = ROOT / "rootfs/etc/systemd/system/fleet-claude-runner@.service"
SEATS = ["claude-seat-a", "claude-seat-b"]


def seat_copy_tasks():
    return [t for t in ansible_host.play()["tasks"]
            if t.get("ansible.builtin.copy") and t.get("loop") == SEATS]


def service():
    unit = ConfigParser(strict=False, interpolation=None)
    unit.optionxform = str
    unit.read_string(UNIT.read_text())
    return unit["Service"]


def unit_path():
    line = next(l for l in UNIT.read_text().splitlines() if l.startswith("Environment=PATH="))
    return line.removeprefix("Environment=PATH=").strip()


def fleet_claude_tasks():
    return [t for t in ansible_host.play()["tasks"] if t and "/var/lib/fleet-claude" in json.dumps(t)]


def unit_install():
    tasks = yaml.safe_load(ansible_host.text(play_file="ansible/tasks/install-config.yml"))
    return next(t for t in tasks if t and t.get("name") == "Install the Claude runner unit")


def test_the_play_creates_fleet_claude_and_never_removes_it():
    users = [t["ansible.builtin.user"] for t in ansible_host.play()["tasks"]
             if t.get("ansible.builtin.user", {}).get("name") == "fleet-claude"]
    assert users and all(t.get("state", "present") == "present" for t in users)


def test_both_seat_files_land_in_fleet_claudes_home_only():
    (task,) = seat_copy_tasks()  # one loop over both seat names, the way the play loops
    copy = task["ansible.builtin.copy"]
    assert copy["src"] == "{{ nish_home }}/.config/fleet-ops/seats/{{ item }}.env"  # same source folder as the other seat files
    assert copy["dest"] == "/var/lib/fleet-claude/.config/fleet-ops/seats/{{ item }}.env"
    assert copy["remote_src"] is True
    assert copy["mode"] == "0600"
    assert copy["owner"] == copy["group"] == "fleet-claude"
    assert task.get("no_log") is True  # the router keys are copied the same way
    assert task.get("diff") is False


def test_no_task_puts_a_claude_seat_in_the_shared_worker_home():
    for task in ansible_host.play()["tasks"]:
        blob = json.dumps(task)
        if "claude-seat" in blob:
            assert "/var/lib/fleet-runner" not in blob


def test_fleet_claude_gets_no_router_key_no_credential_helper():
    for task in fleet_claude_tasks():
        blob = json.dumps(task)
        assert "litellm" not in blob
        assert "credential" not in blob.lower()
        assert "APP_PRIVATE_KEY" not in blob


def test_two_claude_runners_start_from_the_pinned_install():
    play = ansible_host.play()
    assert play["vars"]["fleet_claude_runner_ids"] == [1, 2]
    start = next(t for t in play["tasks"] if t.get("name") == "Start the Claude runners")
    assert start["ansible.builtin.systemd_service"]["name"] == "fleet-claude-runner@{{ item }}.service"
    assert start["loop"] == "{{ fleet_claude_runner_ids }}"
    unpack = next(t for t in play["tasks"] if t.get("name") == "Unpack the actions runner for fleet-claude")
    assert unpack["loop"] == "{{ fleet_claude_runner_ids }}"
    # The review pool's pinned download above is reused, not a second pin:
    assert "fleet_reviewer_runner_version" in json.dumps(unpack)
    install = next(t for t in play["tasks"] if t.get("name") == "Install the packaged claude for fleet-claude")
    assert "fleet_claude_code_version" in json.dumps(install)


def test_the_claude_runners_run_as_fleet_claude_away_from_the_worker_home():
    unit = ConfigParser(strict=False, interpolation=None)
    unit.optionxform = str
    unit.read_string(UNIT.read_text())
    svc = service()
    assert (svc["User"], svc["Group"]) == ("fleet-claude", "fleet-claude")
    assert svc["WorkingDirectory"] == "/var/lib/fleet-claude/%i"
    assert svc["ExecStart"] == "/var/lib/fleet-claude/%i/bin/runsvc.sh"
    assert unit["Unit"]["ConditionPathExists"] == "/var/lib/fleet-claude/%i/.runner"
    assert svc["ProtectHome"] == "yes"
    assert svc["InaccessiblePaths"] == "-/var/lib/fleet-runner"


def test_the_unit_path_names_no_job_writable_folder():
    for entry in unit_path().split(":"):
        assert entry.startswith("/")  # absolute, never relative, never empty
        assert not entry.startswith(("/var/lib/fleet-claude", "/home", "/tmp"))
        assert "_work" not in entry


def test_the_unit_is_installed_with_the_box_config():
    install = unit_install()["ansible.builtin.copy"]
    assert install["dest"] == "/etc/systemd/system/fleet-claude-runner@.service"
    assert install["src"].endswith("fleet-claude-runner@.service")
    assert unit_install()["notify"] == ["Reload systemd", "Restart the Claude runners"]
