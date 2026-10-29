"""A sandbox drop-in reaches a runner at its next start, never by cutting a running job.

The deploy installs the drop-in and reloads systemd. It restarts no runner: a
restart waits TimeoutStopSec (5 min) for a job and then kills it, and the pool
restart that shipped with fleet-ops#10892 cut three hand-offs mid-session on its
own merge, 2026-10-29 11:57Z (fleet-ops#10898). A runner reads the drop-in at its
next start, which the nightly update performs after it drains the runners, and
that run reads the read-only clone bind back on a runner it restarted, so the
guard still gets its live proof (fleet-ops#10866).
"""

from pathlib import Path

import yaml

from ansible_host import play

ROOT = Path(__file__).resolve().parents[1]
SYSTEM = ROOT / "rootfs/etc/systemd/system"
POOL = "actions.runner.Nishfleet.netcup-agent-.service.d"
CLONE = "fleet-ops-deploy-clone"
RELOAD = "Reload systemd"
DRAIN = "Wait until those jobs finish"
STOP = "Stop the runner services, so no CI job starts mid-update"
START = "Start the runner services this run stopped"
READ_PID = "Read the main pid of a runner this run restarted"
READ_BIND = "Fail unless that runner mounts the deploy clone read-only"
ASSERT = "Fail loudly if any step or check went wrong"
BIND_PATTERN = "fleet-ops-deploy-clone ro(,|$)"


def handlers() -> list[dict]:
    return play()["handlers"]


def copy_task() -> dict:
    src = "{{ rootfs }}/etc/systemd/system/" + POOL + "/"
    found = [t for t in play()["tasks"] if isinstance(t, dict) and t.get("ansible.builtin.copy", {}).get("src") == src]
    assert len(found) == 1, [t.get("name") for t in found]
    return found[0]


def update() -> dict:
    playbook = yaml.safe_load((ROOT / "ansible/update.yml").read_text())
    return next(t for t in playbook[0]["tasks"] if isinstance(t, dict) and "always" in t)


def always() -> dict:
    return {t["name"]: t for t in update()["always"]}


def in_order(names: list[str], *wanted: str) -> None:
    positions = [names.index(name) for name in wanted]
    assert positions == sorted(positions), positions


def clone_pools() -> list[str]:
    return sorted(
        d.name for d in SYSTEM.glob("actions.runner.*.service.d") if any(CLONE in f.read_text() for f in d.glob("*.conf"))
    )


def test_the_agent_pool_is_the_only_pool_that_binds_the_deploy_clone() -> None:
    assert clone_pools() == [POOL], "a second pool that binds the deploy clone needs the read-back in ansible/update.yml"


def test_a_sandbox_change_is_installed_and_the_daemon_reloaded() -> None:
    assert copy_task()["notify"] == RELOAD


def test_the_deploy_signals_no_agent_runner() -> None:
    signals = yaml.safe_dump(handlers())
    assert "actions.runner." not in signals, "the deploy would restart a runner and cut its running job"


def test_the_nightly_update_drains_before_it_stops_the_runners() -> None:
    block = update()
    in_order([t["name"] for t in block["block"]], DRAIN, STOP)
    assert START in always()


def test_the_nightly_update_reads_the_clone_bind_back_on_a_runner_it_restarted() -> None:
    tasks = always()
    in_order(list(tasks), START, READ_PID, READ_BIND)
    assert tasks[READ_PID]["ansible.builtin.command"]["argv"][-1].startswith("{{ (runners_stopped")
    assert tasks[READ_BIND]["ansible.builtin.command"]["argv"][2:] == [BIND_PATTERN, "/proc/{{ agent_runner_pid.stdout | trim }}/mountinfo"]
    for name in (READ_PID, READ_BIND):
        assert "runners_stopped" in tasks[name]["when"], "the read would fail a run that restarted no runner"
    assert any("agent_runner_clone_bind" in check for check in tasks[ASSERT]["ansible.builtin.assert"]["that"])
