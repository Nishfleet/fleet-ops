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
REVIEW_POOL_9 = "actions.runner.Nishfleet.netcup-agent-9.service.d"
REVIEW_POOL_10 = "actions.runner.Nishfleet.netcup-agent-10.service.d"
REVIEW_POOL_11 = "actions.runner.Nishfleet.netcup-agent-11.service.d"
REVIEW_POOL_12 = "actions.runner.Nishfleet.netcup-agent-12.service.d"
CLONE = "fleet-ops-deploy-clone"
RELOAD = "Reload systemd"
DRAIN = "Wait until those jobs finish"
STOP = "Stop the runner services, so no CI job starts mid-update"
START = "Start the runner services this run stopped"
UP = "Wait for every runner service to be up again"
PICK = "Pick the agent runner this run restarted"
READ_PID = "Read the main pid of a runner this run restarted"
READ_BIND = "Fail unless that runner mounts the deploy clone read-only"
ASSERT = "Fail loudly if any step or check went wrong"
BIND_PATTERN = "fleet-ops-deploy-clone ro(,|$)"
AGENT_PREFIX = "^actions\\.runner\\.Nishfleet\\.netcup-agent-"


def handlers() -> list[dict]:
    return play()["handlers"]


def install_config() -> list[dict]:
    return yaml.safe_load((ROOT / "ansible/tasks/install-config.yml").read_text())


def copy_task() -> dict:
    src = "{{ rootfs }}/etc/systemd/system/" + POOL + "/"
    found = [t for t in play()["tasks"] if isinstance(t, dict) and t.get("ansible.builtin.copy", {}).get("src") == src]
    assert len(found) == 1, [t.get("name") for t in found]
    return found[0]


def in_order(names: list[str], *wanted: str) -> None:
    missing = [name for name in wanted if name not in names]
    assert not missing, missing
    positions = [names.index(name) for name in wanted]
    assert positions == sorted(positions), positions


def clone_pools() -> list[str]:
    return sorted(
        d.name for d in SYSTEM.glob("actions.runner.*.service.d") if any(CLONE in f.read_text() for f in d.glob("*.conf"))
    )


def test_a_sandbox_change_is_installed_and_the_daemon_reloaded() -> None:
    notified = copy_task()["notify"]
    # The apply unit restarts only idle runners, so a change reaches them without cutting a job (fleet-ops#11248).
    assert set(notified if isinstance(notified, list) else [notified]) == {RELOAD, "Start the runner sandbox apply"}


def test_the_sandbox_install_restarts_no_unit() -> None:
    text = yaml.safe_dump(install_config())
    assert "restarted" not in text
    assert "try-restart" not in text


def test_the_deploy_signals_no_agent_runner() -> None:
    signals = yaml.safe_dump(handlers())
    assert "actions.runner." not in signals, "the deploy would restart a runner and cut its running job"
