"""A runner sandbox drop-in is read once, at unit start, so the deploy must restart the pool.

Measured 2026-10-29 (fleet-ops#10866): the read-only deploy-clone bind had been installed
since 13:13 while every agent runner started at 04:34, so a job in the runner's own
namespace could still write the clone. The restart the drop-in's comment already
prescribes was nobody's task, so a sandbox change reached no running runner.
"""

from fnmatch import fnmatch
from pathlib import Path

from ansible_host import play

ROOT = Path(__file__).resolve().parents[1]
SYSTEM = ROOT / "rootfs/etc/systemd/system"
CLONE = "fleet-ops-deploy-clone"
RELOAD = "Reload systemd"


def pool_dir() -> Path:
    return next(SYSTEM.glob("actions.runner.*.service.d"))


def clone_pools() -> list[str]:
    """Every runner pool whose drop-ins name the deploy clone."""
    return sorted(
        d.name for d in SYSTEM.glob("actions.runner.*.service.d") if any(CLONE in f.read_text() for f in d.glob("*.conf"))
    )


def unit_glob(pool: str) -> str:
    """`actions.runner.x-y-.service.d` -> `actions.runner.x-y-*.service`."""
    assert pool.endswith(".service.d"), pool
    return pool.removesuffix(".service.d") + "*.service"


def copy_task(pool: str) -> dict:
    src = "{{ rootfs }}/etc/systemd/system/" + pool + "/"
    found = [t for t in play()["tasks"] if isinstance(t, dict) and t.get("ansible.builtin.copy", {}).get("src") == src]
    assert len(found) == 1, [t.get("name") for t in found]
    return found[0]


def restart_handler(pool: str) -> list[list[str]]:
    """The argv of every handler a change to this pool notifies that restarts its units."""
    handlers = {h["name"]: h for h in play()["handlers"]}
    out = []
    for name in copy_task(pool)["notify"]:
        argv = handlers[name].get("ansible.builtin.command", {}).get("argv")
        if argv and unit_glob(pool) in argv:
            out.append(argv)
    return out


def test_the_deploy_clone_bind_is_on_the_agent_pool() -> None:
    assert clone_pools() == ["actions.runner.Nishfleet.netcup-agent-.service.d"], (
        "a pool that binds the deploy clone needs its own restart task, because the deploy job runs on fleet-ci"
    )


def test_the_restart_glob_covers_the_units_it_names() -> None:
    assert fnmatch("actions.runner.Nishfleet.netcup-agent-17.service", unit_glob(pool_dir().name))


def test_a_sandbox_change_restarts_the_pool_it_changes() -> None:
    for pool in clone_pools():
        assert RELOAD in copy_task(pool)["notify"], pool
        argv = restart_handler(pool)
        assert len(argv) == 1, pool
        assert argv[0][:2] == ["/usr/bin/systemctl", "try-restart"], argv


def test_the_drop_in_says_where_its_restart_comes_from() -> None:
    lockdown = pool_dir() / "20-lockdown.conf"
    assert "ansible/tasks/install-config.yml" in lockdown.read_text(), lockdown
