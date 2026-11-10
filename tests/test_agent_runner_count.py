"""The agent lane runs on fleet_runner_ids as fleet-runner; no nish-owned runner unit comes back (fleet-ops#10935)."""

from pathlib import Path

import ansible_host

ROOT = Path(__file__).resolve().parents[1]
PLAY = ansible_host.play()


def test_the_pool_is_netcup_agent_1_to_30():
    assert PLAY["vars"]["fleet_runner_ids"] == list(range(1, 31))


def test_nothing_installs_agent_runner_units_any_more():
    assert not (ROOT / "ansible/templates/actions.runner.Nishfleet.netcup-agent.service.j2").exists()
    assert "agent_runner_ids" not in ansible_host.text()

