"""The Sunday maintenance window updates the tools and restarts (fleet-ops#12046).

unattended-upgrades' Automatic-Reboot-Time is a time of day, not a weekday
(https://ubuntu.com/server/docs/how-to/software/automatic-updates/, shutdown(8)),
so the window's restart is the repo's own fleet-reboot.timer and Automatic-Reboot
stays "false". Ubuntu packages upgrade daily on the vendor's stock
apt-daily-upgrade.timer; a kernel installed on any day takes effect at the
Sunday restart.
"""

import re
import subprocess
from pathlib import Path

import ansible_host

ROOT = Path(__file__).resolve().parents[1]
UPDATE_TIMER = ROOT / "rootfs/etc/systemd/system/fleet-update.timer"
REBOOT_TIMER = ROOT / "rootfs/etc/systemd/system/fleet-reboot.timer"
APT = ROOT / "rootfs/etc/apt/apt.conf.d/52fleet-unattended-upgrades"
OVERRIDE = ROOT / "rootfs/etc/systemd/system/apt-daily-upgrade.timer.d/50-fleet-weekly.conf"


def _lines(path: Path) -> list[str]:
    return [line.strip() for line in path.read_text().splitlines()]


def _calendar(path: Path) -> str:
    return next(line.split("=", 1)[1] for line in _lines(path)
                if line.startswith("OnCalendar=") and line != "OnCalendar=")


def _minutes(value: str) -> int:
    hour, minute = (int(part) for part in re.search(r"(\d\d):(\d\d):", value).groups())
    return hour * 60 + minute


def test_the_tool_update_starts_at_0310_with_no_jitter() -> None:
    lines = _lines(UPDATE_TIMER)
    assert "OnCalendar=Sun *-*-* 03:10:00 Asia/Kolkata" in lines
    # The stock jitter could start the run past 03:25, and a run at the
    # 45-minute cap (fleet-update.service, TimeoutStartSec=) would then
    # overlap the 04:00 restart.
    assert "RandomizedDelaySec=0" in lines
    assert "Persistent=true" in lines


def test_the_update_calendar_parses() -> None:
    subprocess.run(["systemd-analyze", "calendar", _calendar(UPDATE_TIMER)],
                   check=True, capture_output=True, text=True)


def test_the_restart_follows_the_update() -> None:
    """04:00 leaves the update's 45-minute cap after its 03:10 start, plus
    margin, before the restart."""
    subprocess.run(["systemd-analyze", "calendar", _calendar(REBOOT_TIMER)],
                   check=True, capture_output=True, text=True)
    assert _minutes(_calendar(REBOOT_TIMER)) - _minutes(_calendar(UPDATE_TIMER)) >= 50


def test_unattended_upgrades_never_reboots_itself() -> None:
    """Automatic-Reboot-Time is gone with Automatic-Reboot "false": a reboot
    time of day cannot name a weekday, and the restart is fleet-reboot.timer's
    job."""
    lines = _lines(APT)
    assert 'Unattended-Upgrade::Automatic-Reboot "false";' in lines
    assert not [line for line in lines
                if line.startswith("Unattended-Upgrade::Automatic-Reboot-Time")]


def test_the_weekly_upgrade_override_is_retired() -> None:
    """The upgrade runs daily on the vendor's stock timer, so the override file
    and its install task are gone: a run at the override's 03:00 would sit
    inside the window again, and its weekly gap is what made security patches
    wait up to a week."""
    assert not OVERRIDE.exists()
    assert "50-fleet-weekly" not in ansible_host.text()
    assert ("/etc/systemd/system/apt-daily-upgrade.timer.d"
            in ansible_host.play()["vars"]["retired"])


def test_the_play_starts_the_window() -> None:
    play_text = ansible_host.text()
    assert "Enable the daily update" in play_text
    assert "Enable the Sunday restart" in play_text
