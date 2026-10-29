"""A runner that runs as its own service user cannot be signalled by nish, and only root
could restart it, so an installed sandbox drop-in waited for the nightly update to drain
the pool: the review runners kept a jail that named /run/user/1000 without hiding it, and
every review job failed the probe (fleet-ops#11016). The polkit rule grants nish start
and restart on exactly those units, and the first test fails a PR that switches another
runner's user without adding it to the grant.
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SYSTEM = ROOT / "rootfs/etc/systemd/system"
RULE = ROOT / "rootfs/etc/polkit-1/rules.d/50-fleet-runner-restart.rules"


def rule() -> str:
    return RULE.read_text()


def granted_units() -> list[str]:
    array = re.search(r"var fleetRestartableUnits = \[(.*?)\];", rule(), re.S)
    assert array is not None
    return re.findall(r'"([^"]+)"', array.group(1))


def granted_verbs() -> list[str]:
    return re.findall(r'action\.lookup\("verb"\) == "([a-z]+)"', rule())


def units_that_run_as_another_user() -> list[str]:
    units = []
    for drop_in in SYSTEM.glob("actions.runner.*.service.d"):
        users = [
            line.split("=", 1)[1].strip()
            for conf in drop_in.glob("*.conf")
            for line in conf.read_text().splitlines()
            if line.startswith("User=")
        ]
        if users and users[-1] != "nish":
            units.append(drop_in.name.removesuffix(".service.d") + ".service")
    return sorted(units)


def test_the_grant_names_every_runner_that_runs_as_another_user() -> None:
    assert sorted(granted_units()) == units_that_run_as_another_user()


def test_the_grant_is_start_and_restart_for_nish_only() -> None:
    assert sorted(granted_verbs()) == ["restart", "start"]
    assert 'subject.user == "nish"' in rule()
    assert 'action.id == "org.freedesktop.systemd1.manage-units"' in rule()


def test_the_grant_covers_the_review_runners() -> None:
    units = granted_units()
    assert "actions.runner.Nishfleet.netcup-agent-9.service" in units
    assert "actions.runner.Nishfleet.netcup-agent-10.service" in units
