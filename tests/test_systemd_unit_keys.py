"""A unit file with an unknown directive must fail CI: systemd skips it with a warning and exit 0 (fleet-ops#9967)."""

import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
INSTALLED = ROOT / "rootfs/etc/systemd/system"
DASH_PREFIXED_KEY = re.compile(r"^-[A-Za-z]+=")


def unit_files() -> list[Path]:
    found = []
    for pattern in ("systemd/*.service", "systemd/*.timer", "systemd/*.path", "systemd/*.slice"):
        found += sorted(ROOT.glob(pattern))
    found += sorted(INSTALLED.glob("*.slice"))
    found += sorted(INSTALLED.glob("fleet-host-config.*"))
    found += sorted(INSTALLED.glob("fleet-update.*"))
    found += sorted(INSTALLED.glob("tether-*"))
    return [path for path in found if path.is_file()]


@pytest.mark.parametrize("unit", unit_files(), ids=lambda path: str(path.relative_to(ROOT)))
def test_no_directive_starts_with_the_ignore_failure_dash(unit: Path) -> None:
    offenders = [line for line in unit.read_text().splitlines() if DASH_PREFIXED_KEY.match(line)]
    assert offenders == [], (
        f"{unit.relative_to(ROOT)}: {offenders}. The ignore-failure prefix goes after the '=' "
        "as ExecStart=-command, not in front of the key."
    )


@pytest.mark.skipif(shutil.which("systemd-analyze") is None, reason="systemd-analyze is not installed")
def test_systemd_analyze_reports_no_unknown_directive() -> None:
    files = [str(path) for path in unit_files()]
    proc = subprocess.run(
        ["systemd-analyze", "verify", "--man=no", *files],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    unknown = [
        line
        for line in (proc.stdout + proc.stderr).splitlines()
        if "Unknown key" in line or "Unknown section" in line
    ]
    assert unknown == [], "\n".join(unknown)


TETHER = INSTALLED / "tether-agent.service"


def _tether_keys() -> dict[str, list[str]]:
    keys: dict[str, list[str]] = {}
    for line in TETHER.read_text().splitlines():
        if "=" in line and not line.startswith(("#", "[")):
            key, value = line.split("=", 1)
            keys.setdefault(key, []).append(value)
    return keys


def test_tether_restart_is_capped_and_pages() -> None:
    keys = _tether_keys()
    assert keys["Restart"] == ["on-failure"]
    interval = int(keys["StartLimitIntervalSec"][0])
    burst = int(keys["StartLimitBurst"][0])
    restart = int(keys["RestartSec"][0])
    assert interval > 0 and burst > 0, "a zero interval disables the start limit"
    assert burst * restart < interval, "the limit must be reachable inside its interval"
    assert keys["OnFailure"] == ["fleet-unit-failed@%N.service"]


def test_tether_cannot_reach_loopback_or_rewrite_its_code() -> None:
    keys = _tether_keys()
    assert keys["IPAddressDeny"] == ["localhost"]
    assert keys["IPAddressAllow"] == ["127.0.0.53"]
    assert "ReadWritePaths" not in keys
    assert keys["ConditionPathExists"][0].startswith("/opt/tether/")
    assert keys["ExecStart"][0].split()[-1].startswith("/opt/tether/")
    assert not keys["WorkingDirectory"][0].startswith("/opt/")


def test_tether_off_marker_survives_the_host_run() -> None:
    host = (ROOT / "ansible/host.yml").read_text()
    readme = (ROOT / "README.md").read_text()
    assert "path: /etc/fleet-ops/tether-off" in host
    assert 'enabled: "{{ not tether_off.stat.exists }}"' in host
    assert "touch /etc/fleet-ops/tether-off" in readme
