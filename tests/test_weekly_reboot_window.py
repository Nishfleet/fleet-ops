"""A pending reboot is taken in the Sunday 03:30 IST window (fleet-ops#11922).

The stock unattended-upgrades setting takes a time of day, not a weekday
(https://documentation.ubuntu.com/server/how-to/software/automatic-updates/),
so the weekly part is the vendor's apt-daily-upgrade.timer moved to Sunday
with its own OnCalendar=.
"""

import subprocess
from pathlib import Path

import ansible_host

ROOT = Path(__file__).resolve().parents[1]
APT = ROOT / "rootfs/etc/apt/apt.conf.d/52fleet-unattended-upgrades"
WINDOW = ROOT / "rootfs/etc/systemd/system/apt-daily-upgrade.timer.d/50-fleet-weekly.conf"


def _lines(path: Path) -> list[str]:
    return [line.strip() for line in path.read_text().splitlines()]


def test_unattended_upgrades_takes_the_reboot_at_the_window() -> None:
    lines = _lines(APT)
    assert 'Unattended-Upgrade::Automatic-Reboot "true";' in lines
    assert 'Unattended-Upgrade::Automatic-Reboot-Time "03:30";' in lines


def test_the_vendor_upgrade_timer_runs_on_sunday_before_the_reboot() -> None:
    lines = _lines(WINDOW)
    assert lines.count("OnCalendar=") == 1, "clear the vendor's daily OnCalendar first"
    assert "OnCalendar=Sun *-*-* 03:00:00 Asia/Kolkata" in lines
    assert "RandomizedDelaySec=0" in lines
    assert "Persistent=false" in lines


def test_the_sunday_calendar_parses() -> None:
    calendar = next(line.split("=", 1)[1] for line in _lines(WINDOW)
                    if line.startswith("OnCalendar=") and line != "OnCalendar=")
    subprocess.run(["systemd-analyze", "calendar", calendar], check=True,
                   capture_output=True, text=True)


def test_the_play_installs_the_window_and_restarts_the_timer() -> None:
    play = ansible_host.text()
    assert "apt-daily-upgrade.timer.d/50-fleet-weekly.conf" in play
    assert "Restart apt-daily-upgrade.timer" in play
