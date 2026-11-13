"""The Claude engine's runners run as their own user, and its seat tokens stay in that home (fleet-ops#11958).

The pool is built like the review pool: its own user fleet-claude, its own home, two runners,
and the two seat files copied there and nowhere a shared-pool job can read. `claude` comes from
the system package; no task installs anything into fleet-claude's home, and no PATH entry names
a folder under it.
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


def test_no_task_installs_claude_into_fleet_claudes_home():
    # A home install would be job-writable: a job could replace `claude` for every later job.
    for task in fleet_claude_tasks():
        assert "claude-code" not in json.dumps(task)


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


def test_the_job_path_names_no_folder_under_the_pool_home():
    # The runner prepends the .path file's entries to every job's PATH, so none may name a
    # folder under fleet-claude's home: a job could replace what is found there.
    task = next(t for t in ansible_host.play()["tasks"]
                if t.get("ansible.builtin.copy", {}).get("dest") == "/var/lib/fleet-claude/{{ item }}/.path")
    for entry in task["ansible.builtin.copy"]["content"].strip().split(":"):
        assert entry.startswith("/")  # absolute, never relative, never empty
        assert not entry.startswith(("/var/lib/fleet-claude", "/home", "/tmp"))
        assert "_work" not in entry


def test_the_unit_is_installed_with_the_box_config():
    install = unit_install()["ansible.builtin.copy"]
    assert install["dest"] == "/etc/systemd/system/fleet-claude-runner@.service"
    assert install["src"].endswith("fleet-claude-runner@.service")
    assert unit_install()["notify"] == ["Reload systemd", "Restart the Claude runners"]
