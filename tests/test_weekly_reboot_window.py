"""A pending reboot is taken in the Sunday 03:30 window (fleet-ops#11922).

The stock unattended-upgrades setting takes a time of day, not a weekday
(https://documentation.ubuntu.com/server/how-to/software/automatic-updates/),
so the weekly part is the vendor's apt-daily-upgrade.timer moved to Sunday
with its own OnCalendar=.
"""

import os
import re
import subprocess
from pathlib import Path

import ansible_host

ROOT = Path(__file__).resolve().parents[1]
APT = ROOT / "rootfs/etc/apt/apt.conf.d/52fleet-unattended-upgrades"
WINDOW = ROOT / "rootfs/etc/systemd/system/apt-daily-upgrade.timer.d/50-fleet-weekly.conf"


def _lines(path: Path) -> list[str]:
    return [line.strip() for line in path.read_text().splitlines()]


def _calendar() -> str:
    return next(line.split("=", 1)[1] for line in _lines(WINDOW)
                if line.startswith("OnCalendar=") and line != "OnCalendar=")


def _minutes(value: str) -> int:
    hour, minute = (int(part) for part in value.split(":")[:2])
    return hour * 60 + minute


def test_unattended_upgrades_takes_the_reboot_at_the_window() -> None:
    lines = _lines(APT)
    assert 'Unattended-Upgrade::Automatic-Reboot "true";' in lines
    assert 'Unattended-Upgrade::Automatic-Reboot-Time "03:30";' in lines


def test_the_vendor_upgrade_timer_runs_on_sunday_before_the_reboot() -> None:
    lines = _lines(WINDOW)
    assert lines.count("OnCalendar=") == 1, "clear the vendor's daily OnCalendar first"
    assert "OnCalendar=Sun *-*-* 03:00:00" in lines
    assert "RandomizedDelaySec=0" in lines
    assert "Persistent=false" in lines


def test_the_timer_follows_the_host_clock() -> None:
    """The calendar names no timezone, so systemd reads it in the host's local
    time, the clock shutdown(8) reads Automatic-Reboot-Time in. A named zone
    would pin the upgrade to one clock and leave the reboot in another, and
    the two would drift apart on any host not on that zone."""
    elapses = []
    for zone in ("Asia/Kolkata", "UTC"):
        out = subprocess.run(
            ["systemd-analyze", "calendar", "--base-time=2026-11-08 00:00:00 UTC",
             _calendar()],
            check=True, capture_output=True, text=True,
            env={**os.environ, "TZ": zone}).stdout
        elapses.append(next(line for line in out.splitlines() if "Next elapse" in line))
    assert all(re.search(r"03:00:00 (IST|UTC)", line) for line in elapses), elapses


def test_the_reboot_follows_the_upgrade_in_the_same_clock() -> None:
    """The reboot time is half an hour after the upgrade the timer starts, in
    the one clock both are read in."""
    reboot = re.search(r'Automatic-Reboot-Time "(\d\d:\d\d)"', APT.read_text()).group(1)
    start = re.search(r"(\d\d:\d\d:\d\d)", _calendar()).group(1)
    assert _minutes(reboot) - _minutes(start) == 30


def test_the_sunday_calendar_parses() -> None:
    subprocess.run(["systemd-analyze", "calendar", _calendar()], check=True,
                   capture_output=True, text=True)


def test_the_play_installs_the_window_and_restarts_the_timer() -> None:
    play = ansible_host.text()
    assert "apt-daily-upgrade.timer.d/50-fleet-weekly.conf" in play
    assert "Restart apt-daily-upgrade.timer" in play
