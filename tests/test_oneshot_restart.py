"""The nightly oneshots retry themselves with systemd's Restart=, and stop retrying.

Restart=on-failure is allowed for Type=oneshot
(https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html#Restart=).
A unit in auto-restart is `activating`, not `failed`, so SystemUnitFailed only sees a run
that keeps failing once the start limit ends the retries
(https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html#StartLimitIntervalSec=interval).
The play no longer re-runs failed oneshots itself (fleet-ops#10935 glue audit).
"""
import configparser
import re
from pathlib import Path

import ansible_host

ROOT = Path(__file__).resolve().parent.parent
ONESHOTS = ["fleet-update.service", "restic-r2-backup.service"]
SECONDS = {"s": 1, "min": 60, "h": 3600}


def _seconds(value: str) -> int:
    m = re.fullmatch(r"(\d+)(s|min|h)", value)
    assert m, value
    return int(m.group(1)) * SECONDS[m.group(2)]


def _unit(text: str) -> configparser.ConfigParser:
    cp = configparser.ConfigParser(strict=False, interpolation=None)
    cp.optionxform = str
    cp.read_string(text)
    return cp


def assert_retries_then_fails(text: str) -> None:
    unit = _unit(text)
    assert unit["Service"].get("Type") == "oneshot"
    assert unit["Service"].get("Restart") == "on-failure"
    wait = _seconds(unit["Service"]["RestartSec"])
    # upstream: https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html#TimeoutStartSec=
    # - Type=oneshot has no start timeout by default, so a run without one has no bound.
    assert "TimeoutStartSec" in unit["Service"], "cap each run with TimeoutStartSec"
    run = _seconds(unit["Service"]["TimeoutStartSec"])
    burst = int(unit["Unit"]["StartLimitBurst"])
    window = _seconds(unit["Unit"]["StartLimitIntervalSec"])
    assert burst > 1
    # upstream: https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html#StartLimitIntervalSec=
    # - the refused start comes burst * (run + wait) after the first one; a shorter window
    # resets the count first, so a slow failure retries forever and never reaches failed.
    assert window > burst * (run + wait), "StartLimitIntervalSec must exceed burst * (TimeoutStartSec + RestartSec)"


def test_each_nightly_oneshot_retries_then_fails() -> None:
    for name in ONESHOTS:
        assert_retries_then_fails((ROOT / "rootfs/etc/systemd/system" / name).read_text())


def test_the_play_does_not_restart_failed_oneshots() -> None:
    host = ansible_host.text()
    assert "systemctl is-failed" not in host
    assert "systemctl start --no-block" not in host
