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
