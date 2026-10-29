"""Agent runners are sized to the box: 1-30 stay, 31-36 are retired (fleet-ops#10480; 30 since 2026-10-28)."""

from pathlib import Path

import yaml
import ansible_host

ROOT = Path(__file__).resolve().parents[1]
PLAY = ansible_host.play()


def tasks():
    return {t["name"]: t for t in PLAY["tasks"] if "name" in t}


def test_retired_ids_are_31_to_36():
    expr = PLAY["vars"]["agent_runner_retired_ids"]
    assert expr == "{{ range(31, 37) | list }}"


def test_retired_units_are_stopped_then_removed():
    names = list(tasks())
    stop = tasks()["Stop and disable the retired agent runners"]
    rm = tasks()["Remove the retired agent runner units"]
    assert names.index("Stop and disable the retired agent runners") < names.index("Remove the retired agent runner units")
    assert stop["ansible.builtin.systemd_service"]["state"] == "stopped"
    assert stop["ansible.builtin.systemd_service"]["enabled"] is False
    assert rm["ansible.builtin.file"]["state"] == "absent"
    assert rm["notify"] == "Reload systemd"


def test_nothing_installs_agent_runner_units_any_more():
    assert not (ROOT / "ansible/templates/actions.runner.Nishfleet.netcup-agent.service.j2").exists()
    assert "agent_runner_ids" not in ansible_host.text()


def test_a_retired_runners_directory_goes_only_once_its_registration_does():
    """The directory holds the only credentials that can deregister the runner.

    Deleting it first strands an offline runner at GitHub with nothing left on
    the box to remove it with, and that needs an org-owner token the host does
    not carry (fleet-ops#10632). `config.sh remove` deletes .runner and
    .credentials, so their absence is the local proof.
    """
    names = list(tasks())
    read = tasks()["Read which retired runner directories still hold a registration"]
    rm = tasks()["Remove the directory of a retired runner whose registration is gone"]
    assert names.index("Remove the retired agent runner units") < names.index("Read which retired runner directories still hold a registration")
    assert names.index("Read which retired runner directories still hold a registration") < names.index(
        "Remove the directory of a retired runner whose registration is gone"
    )
    assert sorted(read["ansible.builtin.find"]["patterns"]) == [".credentials", ".runner"]
    assert read["ansible.builtin.find"]["hidden"] is True
    assert rm["loop"] == "{{ agent_runner_retired_ids }}"
    assert rm["when"] == "item | string not in (retired_runner_registrations.files | map(attribute='path') | map('dirname') | map('basename') | list)"
