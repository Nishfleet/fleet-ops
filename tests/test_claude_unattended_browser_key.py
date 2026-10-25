"""The unattended Claude units take the browser MCP key from the one place that names it, or from nothing at all (fleet-ops#10222)."""

from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
REMOTE_CONTROL = ROOT / "rootfs/etc/systemd/system/claude-remote-control.service"
LISTENERS = (
    ROOT / "systemd/tincan-listen-claude-vps.service",
    ROOT / "rootfs/etc/systemd/system/tincan-listen-claude-vps.service",
)
BROWSER_KEY_FILE = "-/home/nish/.config/claude/browser-use.env"


def _keys(path: Path) -> dict[str, list[str]]:
    keys: dict[str, list[str]] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if "=" in line and not line.startswith(("#", "[")):
            key, value = line.split("=", 1)
            keys.setdefault(key.strip(), []).append(value.strip())
    return keys


def test_remote_control_browser_key_comes_from_its_own_single_name_file() -> None:
    keys = _keys(REMOTE_CONTROL)
    assert BROWSER_KEY_FILE in keys.get("EnvironmentFile", []), (
        "the unit must load the browser key file (optional, exactly as written)"
    )


@pytest.mark.parametrize("name", ["oauth.env", "CLAUDE_CODE_OAUTH_TOKEN", "EXA_API_KEY", "BROWSER_USE_API_KEY"])
def test_remote_control_names_no_credential_outside_that_file(name: str) -> None:
    offenders = [
        f"{key}={value}"
        for key, values in _keys(REMOTE_CONTROL).items()
        for value in values
        if name in key or name in value
    ]
    assert offenders == [], (
        f"{REMOTE_CONTROL.relative_to(ROOT)}: {name} must reach the unit only through {BROWSER_KEY_FILE}, found in {offenders}"
    )


@pytest.mark.parametrize("unit", LISTENERS, ids=lambda path: str(path.relative_to(ROOT)))
def test_the_listener_units_take_no_credential_file_at_all(unit: Path) -> None:
    assert "EnvironmentFile" not in _keys(unit), (
        f"{unit.relative_to(ROOT)}: the listener stays keyless (no keys except Jev, Nish 2026-10-22); "
        "the browser MCP entry is dropped from the config it reads, not fed a key"
    )
    assert "BROWSER_USE" not in unit.read_text(), unit.relative_to(ROOT)


def test_the_runbook_records_where_the_browser_key_lives() -> None:
    runbook = (ROOT / "docs/RUNBOOK.md").read_text()
    assert "browser-use.env" in runbook
    assert 'has("browser-use")' in runbook, "the check for the listener's cleaned config is written down"
