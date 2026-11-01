"""Every nish-owned agent runner is retired; the lane runs on fleet_runner_ids as fleet-runner (fleet-ops#10935)."""

from pathlib import Path

import yaml
import ansible_host

ROOT = Path(__file__).resolve().parents[1]
PLAY = ansible_host.play()


def tasks():
    return {t["name"]: t for t in PLAY["tasks"] if "name" in t}


def test_every_nish_runner_but_the_vault_ones_directory_is_retired():
    expr = PLAY["vars"]["agent_runner_retired_ids"]
    assert expr == "{{ range(1, 37) | reject('equalto', 23) | list }}"


def test_the_pool_is_netcup_agent_1_to_15():
    assert PLAY["vars"]["fleet_runner_ids"] == list(range(1, 16))


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


def test_retired_directories_go_after_their_units():
    names = list(tasks())
    rm = tasks()["Remove the retired runner directories"]
    assert names.index("Remove the retired agent runner units") < names.index("Remove the retired runner directories")
    assert names.index("Copy each runner registration to fleet-runner once") < names.index("Remove the retired runner directories")
    assert rm["loop"] == "{{ agent_runner_retired_ids }}"
