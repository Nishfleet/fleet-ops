"""The agent lock contract: every agent sees only its own keys (fleet-ops#9977).

systemd silently ignores sandbox settings in a user unit on this box
(kernel.apparmor_restrict_unprivileged_userns=1), so a lock only counts when the
unit is a system unit with User= and a service user. This file resolves each
agent's real settings, the unit plus every drop-in with the symlinked shared
file followed, and fails when a hidden path is still readable or a needed path
is hidden.
"""

import json
import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
INSTALLED = ROOT / "rootfs/etc/systemd/system"
USER_UNITS = ROOT / "systemd"
CONTRACT = json.loads((ROOT / "config/agent-locks.json").read_text())
AGENTS = CONTRACT["agents"]
STALE_USER_UNITS = CONTRACT.get("stale_user_units", {})
AGENT_ENGINE = re.compile(
    r"(\.amp/bin/amp|\.local/bin/(claude|command-code|commandcode|cursor|cursor-agent|devin"
    r"|opencode|pi))$"
)


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
        stripped = [token[1:] if key == "InaccessiblePaths" and token.startswith("-") else token for token in tokens]
        values[key] = [token.replace("%h", "~").replace("/home/nish", "~").replace("%S", "~/.local/state") for token in stripped]
    return values


def covers(path: str, roots: list[str]) -> bool:
    return any(path == root or path.startswith(root.rstrip("/") + "/") for root in roots)


def env(values: dict[str, list[str]], key: str) -> str:
    for pair in values.get("Environment", []):
        name, _, value = pair.partition("=")
        if name == key:
            return value
    return ""


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
def test_a_locked_agent_gets_the_service_users_home_and_path(name: str) -> None:
    # settings() rewrites both %h and /home/nish to ~, so these assertions are
    # about the resolved value, not about which spelling the unit uses.
    values = settings(ROOT / AGENTS[name]["unit"])
    assert env(values, "HOME") == "~", (
        f"{name} sets no HOME, so a CLI that expands ~ writes to /root"
    )
    path = env(values, "PATH").split(":")
    assert path[:1] == ["~/.local/bin"], (
        f"{name} does not start PATH with /home/{CONTRACT['user']}/.local/bin, where node, "
        "npm and every agent CLI live, so an #!/usr/bin/env node shebang fails and the "
        "unit restart-loops"
    )
    assert "/usr/bin" in path and "/bin" in path, f"{name} leaves /usr/bin or /bin off its PATH"


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
def test_a_listener_waits_for_the_user_manager_it_hides(name: str) -> None:
    values = settings(ROOT / AGENTS[name]["unit"])
    hides = [path.lstrip("-") for path in values.get("InaccessiblePaths", [])]
    if not any(covers("/run/user/1000", [path]) for path in hides):
        return
    assert "user@1000.service" in values.get("After", []), (
        f"{name} hides /run/user/1000 but does not order after user@1000.service. "
        "InaccessiblePaths= is applied once at start, so a boot start that wins the race "
        "keeps the user manager socket and the worker App token readable for its whole life."
    )


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
    assert installed - covered == set(), (
        "These listeners are installed by the repo but are not an `agents` entry, so no test "
        "would notice if they could read the other agents' keys"
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


def exec_start_values(unit: Path) -> list[str]:
    text = unit.read_text().replace("\\\n", " ")
    return [line.split("=", 1)[1] for line in text.splitlines() if line.startswith("ExecStart")]


def runs_an_agent(unit: Path) -> bool:
    for value in exec_start_values(unit):
        if "tincan listen" in value:
            return True
        program = value.lstrip("-@+!").split(maxsplit=1)
        if program and AGENT_ENGINE.search(program[0]):
            return True
    return False


def test_every_user_unit_that_runs_an_agent_is_in_the_contract() -> None:
    covered = {entry["unit"] for entry in AGENTS.values()} | set(STALE_USER_UNITS)
    covered |= {gap["unit"] for gap in CONTRACT["gaps"] if gap.get("unit")}
    uncovered = [
        f"systemd/{path.name}"
        for path in sorted(USER_UNITS.glob("*.service"))
        if runs_an_agent(path) and f"systemd/{path.name}" not in covered
    ]
    assert uncovered == [], (
        f"{uncovered} run an agent and are in no contract entry, so deleting that entry would "
        "leave an unlocked agent behind. Add each one as an agent or as a gap."
    )


def test_every_gap_names_a_unit_file_that_still_exists() -> None:
    for gap in CONTRACT["gaps"]:
        unit = gap.get("unit")
        assert isinstance(unit, str) and unit, (
            f"{gap['agent']} names {unit!r} instead of a unit file, so nothing here would notice "
            "when that agent's units are deleted and the gap turns into work nobody can do"
        )
        assert (ROOT / unit).exists(), (
            f"{gap['agent']} names {unit}, which the repo no longer ships. Delete the gap if "
            "the agent is gone, or point it at the new path if the unit moved"
        )


def test_every_gap_names_a_reason_and_a_follow_up() -> None:
    for gap in CONTRACT["gaps"]:
        assert gap.get("reason"), f"{gap['agent']} has no reason"
        assert gap.get("issue"), f"{gap['agent']} has no follow-up issue, so it would be forgotten"


@pytest.mark.parametrize("name", sorted(AGENTS), ids=str)
def test_every_other_relay_identity_is_hidden(name: str) -> None:
    others = [a["relay_identity"] for n, a in AGENTS.items() if n != name and a.get("relay_identity")]
    values = settings(ROOT / AGENTS[name]["unit"])
    missing = [path for path in others if not hidden(values, path)]
    assert missing == [], f"{name} does not hide the relay identities {missing}"


def test_the_probe_expands_the_contracts_tilde_before_systemd_sees_it() -> None:
    """systemd.exec(5) takes InaccessiblePaths= relative to the host's root, so a
    ~ the contract spells out must be expanded before it reaches --property=,
    and the shell body must test the same expanded paths it was given. Without
    the expansion the probe reports every need as MISSING and stops the
    switch-over on a box where the lock holds.
    """
    import yaml

    tasks = yaml.safe_load((ROOT / "ansible/tasks/agent-lock.yml").read_text())
    probe = next(t for t in tasks if t["name"] == "Show one agent cannot read the other agents' keys")
    argv = probe["ansible.builtin.command"]["argv"]
    hidden = [a for a in argv if a.startswith("--property=InaccessiblePaths=")]
    body = argv[argv.index("/bin/sh") + 2]
    assert len(hidden) == 1, "The probe passes no InaccessiblePaths=, so it hides nothing"
    for rendered in (hidden[0], body):
        assert "'^~'" in rendered, (
            "The probe hands systemd a ~ path, which it reads relative to the host's root"
        )
    assert "map('regex_replace', '^', '-')" in hidden[0], (
        "The probe's InaccessiblePaths= has no '-' prefix, so a path that is absent on the box "
        "(dockerd down, a file that agent never had) fails the transient unit with 226/NAMESPACE "
        "before the shell runs, and the whole playbook stops at the import after this file."
    )
