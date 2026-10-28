"""The agent lock contract: every agent sees only its own keys (fleet-ops#9977).

systemd silently ignores sandbox settings in a user unit on this box
(kernel.apparmor_restrict_unprivileged_userns=1), so a lock only counts when the
unit is a system unit with User= and a service user. This file resolves each
agent's real settings, the unit plus every drop-in with the symlinked shared
file followed, and fails when a hidden path is still readable or a needed path
is hidden.
"""

import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
INSTALLED = ROOT / "rootfs/etc/systemd/system"
CONTRACT = json.loads((ROOT / "config/agent-locks.json").read_text())
AGENTS = CONTRACT["agents"]
STALE_USER_UNITS = CONTRACT.get("stale_user_units", {})


def settings(unit: Path) -> dict[str, list[str]]:
    values: dict[str, list[str]] = {}
    files = [unit]
    dropins = unit.with_name(unit.name + ".d")
    if dropins.is_dir():
        files += sorted(dropins.iterdir())
    for path in files:
        for line in path.read_text().splitlines():
            stripped = line.strip()
            if "=" not in stripped or stripped.startswith("#") or stripped.startswith("["):
                continue
            key, _, value = stripped.partition("=")
            values.setdefault(key.strip(), []).extend(value.split())
    for key, tokens in values.items():
        values[key] = [token.replace("%h", "~").replace("/home/nish", "~").replace("%S", "~/.local/state") for token in tokens]
    return values


def covers(path: str, roots: list[str]) -> bool:
    return any(path == root or path.startswith(root.rstrip("/") + "/") for root in roots)


def hidden(values: dict[str, list[str]], path: str) -> bool:
    if covers(path, values.get("InaccessiblePaths", [])):
        return True
    if "tmpfs" in values.get("ProtectHome", []):
        allowed = values.get("BindPaths", []) + values.get("BindReadOnlyPaths", [])
        return not covers(path, allowed)
    return False


@pytest.mark.parametrize("name", sorted(AGENTS), ids=str)
def test_locked_agent_is_a_system_unit_with_a_service_user(name: str) -> None:
    unit = ROOT / AGENTS[name]["unit"]
    assert unit.is_file(), f"{unit.relative_to(ROOT)} is missing"
    assert unit.parent == INSTALLED, (
        f"{unit.relative_to(ROOT)} is not a system unit. A user unit ignores every setting "
        "below on this host, so the lock would not exist."
    )
    values = settings(unit)
    assert values.get("User") == [CONTRACT["user"]], f"{name} does not run as {CONTRACT['user']}"
    assert values.get("NoNewPrivileges") == ["yes"] or values.get("NoNewPrivileges") == ["true"], (
        f"{name} keeps the privilege-escalation path open"
    )
    assert not values.get("SupplementaryGroups"), f"{name} keeps a supplementary group"


@pytest.mark.parametrize("name", sorted(AGENTS), ids=str)
def test_every_path_the_agent_must_not_read_is_hidden(name: str) -> None:
    values = settings(ROOT / AGENTS[name]["unit"])
    readable = [path for path in AGENTS[name]["must_hide"] if not hidden(values, path)]
    assert readable == [], f"{name} can still read {readable}"


@pytest.mark.parametrize("name", sorted(AGENTS), ids=str)
def test_every_path_the_agent_needs_is_still_readable(name: str) -> None:
    values = settings(ROOT / AGENTS[name]["unit"])
    lost = [path for path in AGENTS[name]["needs"] if hidden(values, path)]
    assert lost == [], f"{name} would lose {lost}, so a command it runs for Nish would break"


@pytest.mark.parametrize("name", sorted(AGENTS), ids=str)
def test_the_one_service_key_comes_from_an_environment_file(name: str) -> None:
    key = AGENTS[name].get("service_key")
    if key is None:
        return
    values = settings(ROOT / AGENTS[name]["unit"])
    assert key in values.get("EnvironmentFile", []), (
        f"{name} needs {key}, and systemd must read it as root so the agent gets the value "
        "without the seats directory being readable"
    )


def test_every_listener_unit_on_this_host_is_in_the_contract() -> None:
    installed = {path.name for path in INSTALLED.glob("tincan-listen-*.service")}
    covered = {Path(entry["unit"]).name for entry in AGENTS.values()}
    covered |= {Path(gap["unit"]).name for gap in CONTRACT["gaps"] if gap.get("unit")}
    assert installed - covered == set(), (
        "These listeners are installed by the repo but not in config/agent-locks.json, so no "
        "test would notice if they could read the other agents' keys"
    )


@pytest.mark.parametrize("name", sorted(AGENTS), ids=str)
def test_a_locked_agent_has_no_user_unit_left_behind(name: str) -> None:
    stale = ROOT / "systemd" / f"{name}.service"
    if str(stale.relative_to(ROOT)) in STALE_USER_UNITS:
        return
    assert not stale.exists(), (
        f"{stale.relative_to(ROOT)} is the unlocked form of a locked agent. Enable the system "
        "unit and remove this file, or list it in stale_user_units with its follow-up."
    )


def test_every_gap_names_a_reason_and_a_follow_up() -> None:
    for gap in CONTRACT["gaps"]:
        assert gap.get("reason"), f"{gap['agent']} has no reason"
        assert gap.get("issue"), f"{gap['agent']} has no follow-up issue, so it would be forgotten"
