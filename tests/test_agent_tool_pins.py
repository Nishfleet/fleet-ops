"""The globally installed agent tools are pinned, and the nightly update installs the pins."""

import json
import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
PINS = ROOT / "config" / "agent-tools" / "pins.txt"
RENOVATE = ROOT / ".github" / "renovate.json"
UPDATE = ROOT / "ansible" / "update.yml"


def pin_rows() -> list[list[str]]:
    rows = []
    for line in PINS.read_text().splitlines():
        text = line.split("#")[0].strip()
        if text:
            parts = text.split("|")
            assert len(parts) == 3, f"{PINS.name}: {line!r} is not a manager|tool|version row"
            rows.append(parts)
    return rows


@pytest.mark.parametrize("row", pin_rows(), ids=lambda row: row[0] + ":" + row[1])
def test_pin_row_takes_a_version_whoever_edits_the_file(row: list[str]) -> None:
    manager, tool, version = row
    assert manager in {"npm", "uv"}, f"{manager}: only npm and uv rows are defined"
    assert tool, "the package name is missing"
    assert version and re.fullmatch(r"[0-9][0-9A-Za-z._+-]*", version), (
        f"{tool}: {version!r} is not one exact version"
    )


def test_the_pins_are_unique() -> None:
    rows = pin_rows()
    assert rows, f"{PINS.name}: no pin rows"
    keys = [(row[0], row[1]) for row in rows]
    assert len(keys) == len(set(keys)), "a tool is pinned twice"


def test_the_nightly_update_installs_the_pins_not_latest() -> None:
    text = UPDATE.read_text()
    assert "config/agent-tools/pins.txt" in text, "the nightly update does not read the pin file"
    assert "[npm, update, --global]" not in text, "npm update --global drifts unpinned"
    assert "tool, upgrade, --all" not in text, "uv tool upgrade --all drifts unpinned"


def test_renovate_bumps_the_pins__after_the_release_is_3_days_old() -> None:
    config = json.loads(RENOVATE.read_text())
    pin_managers = [
        manager
        for manager in config.get("customManagers", [])
        if "/^config/agent-tools/pins" in json.dumps(manager.get("managerFilePatterns", []))
    ]
    assert len(pin_managers) == 2, "Renovate does not read config/agent-tools/pins.txt"
    assert {manager.get("datasourceTemplate") for manager in pin_managers} == {"npm", "pypi"}
    rules = config.get("packageRules", [])
    assert any(
        "custom.regex" in rule.get("matchManagers", [])
        and rule.get("minimumReleaseAge") == "3 days"
        for rule in rules
    ), "the pinned tools have no 3-day release-age rule"


def test_the_uv_tasks_install_the_pins() -> None:
    tasks = (ROOT / "ansible" / "tasks" / "mcp-and-agent-clis.yml").read_text()
    assert "agent_tool_pins" in tasks, "the host play installs uv tools without the pins"
