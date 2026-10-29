"""A runner reads its sandbox at unit start, so the deploy restarts the pool when it changes."""

from fnmatch import fnmatch
from pathlib import Path

from ansible_host import play

ROOT = Path(__file__).resolve().parents[1]
SYSTEM = ROOT / "rootfs/etc/systemd/system"
POOL = "actions.runner.Nishfleet.netcup-agent-.service.d"
CLONE = "fleet-ops-deploy-clone"
RELOAD = "Reload systemd"
FIRST = "Restart one agent runner"


def unit_glob(pool: str = POOL) -> str:
    """`...-agent-.service.d` -> `...-agent-*.service`."""
    return pool.removesuffix(".service.d") + "*.service"


def handlers() -> list[dict]:
    return play()["handlers"]


def handler(name: str) -> dict:
    found = [h for h in handlers() if h["name"] == name]
    assert len(found) == 1, name
    return found[0]


def copy_task(pool: str = POOL) -> dict:
    src = "{{ rootfs }}/etc/systemd/system/" + pool + "/"
    found = [t for t in play()["tasks"] if isinstance(t, dict) and t.get("ansible.builtin.copy", {}).get("src") == src]
    assert len(found) == 1, [t.get("name") for t in found]
    return found[0]


def clone_pools() -> list[str]:
    return sorted(
        d.name for d in SYSTEM.glob("actions.runner.*.service.d") if any(CLONE in f.read_text() for f in d.glob("*.conf"))
    )


def test_the_agent_pool_is_the_only_pool_that_binds_the_deploy_clone() -> None:
    assert clone_pools() == [POOL], "a pool that binds the deploy clone needs its own restart, and its own canary runner"


def test_the_restart_glob_covers_the_pool_and_not_the_deploy_host() -> None:
    assert fnmatch("actions.runner.Nishfleet.netcup-agent-17.service", unit_glob())
    assert not fnmatch("actions.runner.Nishfleet.netcup-fleet-ci-1.service", unit_glob())


def test_a_sandbox_change_restarts_its_pool() -> None:
    notify = copy_task()["notify"]
    assert notify.index(RELOAD) < notify.index(FIRST)
    assert handler(FIRST)["ansible.builtin.systemd_service"] == {
        "name": "actions.runner.Nishfleet.netcup-agent-1.service",
        "state": "restarted",
    }


def test_the_first_runner_is_read_back_before_the_rest_restart() -> None:
    names = [h["name"] for h in handlers()]
    order = names.index(RELOAD), names.index(FIRST)
    assert order[0] < order[1]
    rest = names.index("Restart the rest of the agent runners")
    read = names.index("Fail unless that runner mounts the deploy clone read-only")
    main_pid = names.index("Read the main pid of that runner")
    assert order[1] < main_pid < read < rest
    assert handler("Read the main pid of that runner")["ansible.builtin.command"]["argv"][-1] == (
        "actions.runner.Nishfleet.netcup-agent-1.service"
    )
    assert handler("Fail unless that runner mounts the deploy clone read-only")["ansible.builtin.command"]["argv"][-1] == (
        "/proc/{{ agent_runner_pid.stdout | trim }}/mountinfo"
    )
    argv = handler("Restart the rest of the agent runners")["ansible.builtin.command"]["argv"]
    assert argv[:2] == ["/usr/bin/systemctl", "try-restart"] and argv[-1] == unit_glob()
