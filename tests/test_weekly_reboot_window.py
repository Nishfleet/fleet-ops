"""The Sunday maintenance window: Ubuntu upgrade 03:00, tool update 03:10,
restart 04:00 (fleet-ops#12045).

The vendor's `Automatic-Reboot` only fires in a week where an upgrade marked
`reboot-required`, and its time is a time of day passed to `shutdown(8)`, not a
weekday (https://documentation.ubuntu.com/server/how-to/software/automatic-updates/).
So the weekly restart is stock `systemd.timer(5)` over `systemctl reboot`, and
the vendor's own reboot is off: one owner for the instant.
"""

import os
import re
import subprocess
from pathlib import Path

import ansible_host

ROOT = Path(__file__).resolve().parents[1]
APT = ROOT / "rootfs/etc/apt/apt.conf.d/52fleet-unattended-upgrades"
UPGRADE_TIMER = ROOT / "rootfs/etc/systemd/system/apt-daily-upgrade.timer.d/50-fleet-weekly.conf"
UPDATE_TIMER = ROOT / "rootfs/etc/systemd/system/fleet-update.timer"
REBOOT_TIMER = ROOT / "rootfs/etc/systemd/system/fleet-reboot.timer"
REBOOT_UNIT = ROOT / "rootfs/etc/systemd/system/fleet-reboot.service"
SERVICES = ROOT / "ansible/tasks/services.yml"


def _lines(path: Path) -> list[str]:
    return [line.strip() for line in path.read_text().splitlines()]


def _calendar(path: Path) -> str:
    return next(line.split("=", 1)[1] for line in _lines(path)
                if line.startswith("OnCalendar=") and line != "OnCalendar=")


def _minutes(value: str) -> int:
    hour, minute = (int(part) for part in value.split(":")[:2])
    return hour * 60 + minute


def _start(path: Path) -> int:
    return _minutes(re.search(r"(\d\d:\d\d):\d\d", _calendar(path)).group(1))


def test_the_vendor_upgrade_timer_runs_on_sunday_before_the_reboot() -> None:
    lines = _lines(UPGRADE_TIMER)
    assert lines.count("OnCalendar=") == 1, "clear the vendor's daily OnCalendar first"
    assert "OnCalendar=Sun *-*-* 03:00:00" in lines
    assert "RandomizedDelaySec=0" in lines
    assert "Persistent=false" in lines


def test_the_vendor_reboot_is_off_so_one_owner_restarts() -> None:
    text = APT.read_text()
    assert 'Unattended-Upgrade::Automatic-Reboot "false";' in text
    assert "Automatic-Reboot-Time" not in text


def test_the_window_runs_upgrade_then_tools_then_restart() -> None:
    upgrade, tools, reboot = _start(UPGRADE_TIMER), _start(UPDATE_TIMER), _start(REBOOT_TIMER)
    assert upgrade < tools < reboot, (upgrade, tools, reboot)


def test_the_tool_run_and_the_restart_are_sunday_only() -> None:
    assert _calendar(UPDATE_TIMER).startswith("Sun ")
    assert _calendar(REBOOT_TIMER).startswith("Sun ")
    for timer in (UPDATE_TIMER, REBOOT_TIMER):
        assert "Persistent=false" in _lines(timer), timer.name


def test_the_restart_is_a_stock_oneshot() -> None:
    lines = _lines(REBOOT_UNIT)
    assert "Type=oneshot" in lines
    assert "ExecStart=/usr/bin/systemctl --no-block reboot" in lines


def test_the_timer_follows_the_host_clock() -> None:
    """The upgrade calendar names no timezone, so systemd reads it in the host's
    local time. A named zone would pin it to one clock and leave the reboot in
    another, and the two would drift apart on any host not on that zone."""
    elapses = []
    for zone in ("Asia/Kolkata", "UTC"):
        out = subprocess.run(
            ["systemd-analyze", "calendar", "--base-time=2026-11-08 00:00:00 UTC",
             _calendar(UPGRADE_TIMER)],
            check=True, capture_output=True, text=True,
            env={**os.environ, "TZ": zone}).stdout
        elapses.append(next(line for line in out.splitlines() if "Next elapse" in line))
    assert all(re.search(r"03:00:00 (IST|UTC)", line) for line in elapses), elapses


def test_the_sunday_calendars_parse() -> None:
    for path in (UPGRADE_TIMER, UPDATE_TIMER, REBOOT_TIMER):
        subprocess.run(["systemd-analyze", "calendar", _calendar(path)], check=True,
                       capture_output=True, text=True)


def test_the_play_installs_the_window_and_restarts_the_timer() -> None:
    play = ansible_host.text()
    assert "apt-daily-upgrade.timer.d/50-fleet-weekly.conf" in play
    assert "Restart apt-daily-upgrade.timer" in play


def test_the_play_enables_the_restart_timer() -> None:
    text = SERVICES.read_text()
    assert "name: fleet-reboot.timer" in text
    assert "name: fleet-update.timer" in text


def test_the_update_play_owns_the_tools_without_an_updater() -> None:
    play = (ROOT / "ansible/update.yml").read_text()
    for command in ("[rustup, update]", "[bun, upgrade]", "[rclone, selfupdate]",
                    "[gh, extension, upgrade, --all]"):
        assert command in play, command
