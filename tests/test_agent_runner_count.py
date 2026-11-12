"""The agent lane runs on fleet_runner_ids as fleet-runner; no nish-owned runner unit comes back (fleet-ops#10935)."""
from pathlib import Path

import ansible_host

ROOT = Path(__file__).resolve().parents[1]
PLAY = ansible_host.play()


def test_the_pool_is_netcup_agent_1_to_14() -> None:
    assert PLAY["vars"]["fleet_runner_ids"] == list(range(1, 15))


def test_the_retired_ids_are_the_ones_the_pool_dropped() -> None:
    """The pool was 1 to 30 until the 2026-11-12 cut, so the ids above the pool are
    retired. The list stays derived from the pool (its length plus one, through 30),
    so a later cut keeps its own tail without a second hardcoded count."""
    assert PLAY["vars"]["fleet_runner_ids_retired"] == \
        "{{ range((fleet_runner_ids | length) + 1, 31) | list }}"


def test_nothing_installs_agent_runner_units_any_more() -> None:
    assert not (ROOT / "ansible/templates/actions.runner.Nishfleet.netcup-agent.service.j2").exists()
    assert "agent_runner_ids" not in ansible_host.text()


def test_the_retired_runners_are_stopped_only_while_they_run_no_job() -> None:
    """Stopping the unit kills the job the runner runs, so the stop must not fire on one
    that is busy: rc 0 retires, rc 1 leaves the runner, any other rc fails the task."""
    tasks = PLAY["tasks"]
    find = next(t for t in tasks if t.get("name") == "Find the retired runners that run no job")
    cmd = find["ansible.builtin.shell"]["cmd"]
    assert "pgrep --cgroup \"$cgroup\" -x Runner.Worker" in cmd, find
    assert "test -n \"$cgroup\" || exit 0" in cmd, find
    assert "case $? in 0) exit 1;; 1) exit 0;; *) exit 2;; esac" in cmd, find
    assert find["loop"] == "{{ fleet_runner_ids_retired }}", find
    assert find["failed_when"] == "(fleet_runner_retired.rc | default(2)) not in [0, 1]", find

    off = next(t for t in tasks if t.get("name") == "Retire the runners that run no job")
    assert off["ansible.builtin.systemd_service"]["state"] == "stopped", off
    loop = "fleet_runner_retired.results | selectattr('rc', 'equalto', 0) | map(attribute='item') | list"
    assert off["loop"] == "{{ " + loop + " }}", off
