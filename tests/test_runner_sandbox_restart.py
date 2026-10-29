"""A runner reads its sandbox at unit start, so the deploy restarts the pool when it changes."""

from fnmatch import fnmatch
from pathlib import Path

from ansible_host import play

ROOT = Path(__file__).resolve().parents[1]
SYSTEM = ROOT / "rootfs/etc/systemd/system"
POOL = "actions.runner.Nishfleet.netcup-agent-.service.d"
CLONE = "fleet-ops-deploy-clone"
RELOAD = "Reload systemd"
TOPIC = "Restart the agent runners"
CANARY = "Restart one agent runner"
READ_PID = "Read the main pid of that runner"
READ_CLONE = "Fail unless that runner mounts the deploy clone read-only"
POOL_RESTART = "Restart the rest of the agent runners"
CHAIN = [CANARY, READ_PID, READ_CLONE, POOL_RESTART]
PILOT = "Leave the pilot runner stopped while it carries the agent label"


def handlers() -> list[dict]:
    return play()["handlers"]


def handler(name: str) -> dict:
    found = [h for h in handlers() if h["name"] == name]
    assert len(found) == 1, name
    return found[0]


def task(name: str) -> dict:
    found = [t for t in play()["tasks"] if isinstance(t, dict) and t.get("name") == name]
    assert len(found) == 1, name
    return found[0]


def copy_task() -> dict:
    src = "{{ rootfs }}/etc/systemd/system/" + POOL + "/"
    found = [t for t in play()["tasks"] if isinstance(t, dict) and t.get("ansible.builtin.copy", {}).get("src") == src]
    assert len(found) == 1, [t.get("name") for t in found]
    return found[0]


def canary() -> str:
    return handler(CANARY)["ansible.builtin.systemd_service"]["name"]


def pool_patterns() -> list[str]:
    argv = handler(POOL_RESTART)["ansible.builtin.command"]["argv"]
    assert argv[:2] == ["/usr/bin/systemctl", "try-restart"], argv
    return argv[2:]


def matched(unit: str) -> bool:
    return any(fnmatch(unit, pattern) for pattern in pool_patterns())


def clone_pools() -> list[str]:
    return sorted(
        d.name for d in SYSTEM.glob("actions.runner.*.service.d") if any(CLONE in f.read_text() for f in d.glob("*.conf"))
    )


def test_the_agent_pool_is_the_only_pool_that_binds_the_deploy_clone() -> None:
    assert clone_pools() == [POOL], "a pool that binds the deploy clone needs its own restart, and its own canary runner"


def test_a_sandbox_change_notifies_the_restart_after_the_reload() -> None:
    notify = copy_task()["notify"]
    assert notify.index(RELOAD) < notify.index(TOPIC)


def test_every_handler_in_the_chain_listens_to_the_notified_topic() -> None:
    for name in CHAIN:
        assert handler(name).get("listen") == TOPIC, f"nothing notifies {name}, so it never runs"


def test_the_canary_is_a_runner_the_deploy_leaves_running() -> None:
    service = handler(CANARY)["ansible.builtin.systemd_service"]
    assert service["state"] == "restarted"
    stopped = task(PILOT)["ansible.builtin.systemd_service"]["name"]
    assert service["name"] != stopped, "restarted starts a stopped unit, and the pilot takes jobs it cannot run"


def test_the_canary_is_read_back_before_the_rest_restart() -> None:
    names = [h["name"] for h in handlers()]
    assert names.index(RELOAD) < names.index(CANARY)
    assert names.index(CANARY) < names.index(READ_PID) < names.index(READ_CLONE) < names.index(POOL_RESTART)
    assert handler(READ_PID)["ansible.builtin.command"]["argv"][-1] == canary()
    assert handler(READ_CLONE)["ansible.builtin.command"]["argv"][-1] == "/proc/{{ agent_runner_pid.stdout | trim }}/mountinfo"


def test_the_pool_restart_covers_every_runner_the_canary_and_the_pilot_do_not() -> None:
    assert matched("actions.runner.Nishfleet.netcup-agent-3.service")
    assert matched("actions.runner.Nishfleet.netcup-agent-9.service")
    assert matched("actions.runner.Nishfleet.netcup-agent-10.service")
    assert matched("actions.runner.Nishfleet.netcup-agent-30.service")


def test_the_pool_restart_names_no_runner_already_restarted_and_no_other_pool() -> None:
    assert not matched(canary()), "the pool restart would restart the canary a second time"
    assert not matched(task(PILOT)["ansible.builtin.systemd_service"]["name"]), "the pool restart would start the pilot"
    assert not matched("actions.runner.Nishfleet.netcup-fleet-ci-1.service"), "the deploy job runs on fleet-ci"
