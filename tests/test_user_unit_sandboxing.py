"""A user unit gets no mount sandbox on this host, so this repo sets no such key.

systemd 255 builds an unprivileged user namespace for a user unit that names one of
these keys, AppArmor's unprivileged_userns profile refuses every namespace the
process tries to make after that one, and systemd continues without the sandbox at
debug level (fleet-ops#10880, docs/user-unit-sandboxing.md). A key that does not
apply reads as a protection that does not exist, so the test fails on one. Delete
this test when the host allows an unprivileged mount namespace again.

PrivateUsers= is not on the list: it is the user namespace systemd builds, the one
step AppArmor allows. ProtectHostname= is not on the list either: its UTS half is
lost, but its seccomp half holds.

systemd/ is the user tree: fleet-sync.service links every unit in it into
~/.config/systemd/user. System units live in rootfs/etc/systemd/system/, where the
sandbox keys do apply, and the test checks that no system unit lands in systemd/.
"""

from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
GUARDED = {
    "BindPaths",
    "BindReadOnlyPaths",
    "DynamicUser",
    "ExtensionDirectories",
    "ExtensionImages",
    "InaccessiblePaths",
    "MountAPIVFS",
    "PrivateDevices",
    "PrivateIPC",
    "PrivateMounts",
    "PrivateNetwork",
    "PrivateTmp",
    "ProcSubset",
    "ProtectControlGroups",
    "ProtectHome",
    "ProtectKernelLogs",
    "ProtectKernelModules",
    "ProtectKernelTunables",
    "ProtectProc",
    "ProtectSystem",
    "ReadOnlyPaths",
    "ReadWritePaths",
    "RootDirectory",
    "RootImage",
    "TemporaryFileSystem",
}
OFF = {"", "0", "false", "no", "off"}
SYSTEM_TARGETS = ("basic.", "graphical.", "multi-user.", "sysinit.")


def user_unit_files() -> list[Path]:
    files = [
        path
        for root in (ROOT / "systemd", ROOT / "rootfs/etc/systemd/user")
        for pattern in ("*.service", "*.conf")
        for path in root.rglob(pattern)
    ]
    return sorted(path for path in files if path.is_file())


def settings(path: Path) -> list[tuple[str, str]]:
    pairs = []
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith(("#", ";")):
            continue
        key, separator, value = line.partition("=")
        if separator:
            pairs.append((key.strip(), value.strip()))
    return pairs


def guarded(path: Path) -> list[str]:
    return [f"{key}={value}" for key, value in settings(path) if key in GUARDED and value.lower() not in OFF]


def test_finds_user_unit_files() -> None:
    assert user_unit_files(), "no unit under systemd/ or rootfs/etc/systemd/user/ to check"


def test_catches_a_guarded_key(tmp_path: Path) -> None:
    unit = tmp_path / "probe.service"
    unit.write_text("[Service]\nProtectSystem=strict\nPrivateTmp=yes\n")
    assert guarded(unit) == ["ProtectSystem=strict", "PrivateTmp=yes"]


def test_ignores_a_key_set_off(tmp_path: Path) -> None:
    unit = tmp_path / "probe.service"
    unit.write_text("[Service]\nProtectSystem=no\nPrivateTmp=false\n")
    assert guarded(unit) == []


@pytest.mark.parametrize("path", user_unit_files(), ids=lambda path: str(path.relative_to(ROOT)))
def test_no_guarded_key(path: Path) -> None:
    found = guarded(path)
    assert not found, (
        f"{path.relative_to(ROOT)}: {', '.join(found)} do not apply in a user unit on this host "
        "(docs/user-unit-sandboxing.md): a mount key is dropped silently, and a non-trivial "
        "rearrangement or DynamicUser= refuses the unit at start. Use a system unit with User=, or a bwrap jail"
    )


def test_no_system_unit_lands_in_the_user_tree() -> None:
    misplaced = [
        path.relative_to(ROOT)
        for path in sorted((ROOT / "systemd").glob("*.service"))
        for key, value in settings(path)
        if key in ("WantedBy", "RequiredBy") and value.startswith(SYSTEM_TARGETS)
    ]
    assert not misplaced, (
        f"{', '.join(str(path) for path in misplaced)} install to a system target, but systemd/ is the "
        "user tree that fleet-sync.service links into ~/.config/systemd/user; a system unit belongs in "
        "rootfs/etc/systemd/system/, where the sandbox keys do apply"
    )


def test_the_poll_watcher_ships_as_a_system_unit_with_its_sandbox() -> None:
    unit = ROOT / "rootfs/etc/systemd/system/beacon-hermes-poll.service"
    assert unit.is_file(), "beacon-hermes-poll.service parses Telegram text and needs a sandbox that holds"
    assert not (ROOT / "systemd/beacon-hermes-poll.service").exists(), (
        "the user unit it replaced is gone, so a copy under systemd/ would be linked a second time"
    )
    pairs = dict(settings(unit))
    assert pairs.get("User") == "nish"
    assert pairs.get("WantedBy") == "multi-user.target"
    assert {"ProtectSystem=strict", "ProtectHome=read-only", "PrivateTmp=yes"} <= set(guarded(unit)), (
        f"{unit.relative_to(ROOT)}: the system manager applies these, so the file must set them"
    )
    assert "/home/nish/.beacon" in pairs.get("ReadWritePaths", ""), "the watcher writes its log and cursor there"


def test_fleet_sync_drops_the_retired_user_link_before_the_link_guard() -> None:
    lines = (ROOT / "systemd/fleet-sync.service").read_text().splitlines()
    link = "%h/.config/systemd/user/beacon-hermes-poll.service"
    stop = [i for i, line in enumerate(lines) if line.startswith("ExecStart=") and line.endswith("--user stop beacon-hermes-poll.service")]
    rm = [i for i, line in enumerate(lines) if line.startswith("ExecStart=") and "rm -f " in line and link in line]
    guard = [i for i, line in enumerate(lines) if line.startswith("ExecStart=") and "-xtype l" in line]
    assert stop and rm and guard, "fleet-sync.service must stop the unit, delete the link and keep its LINK-GUARD"
    assert max(stop + rm) < guard[0], (
        "the link is deleted after LINK-GUARD (step 9) runs, which fails the deploy on the dangling link "
        "the deleted file leaves behind"
    )
    assert "default.target.wants/beacon-hermes-poll.service" in lines[rm[0]], (
        "the wants link is named outright: systemd expands no glob in ExecStart, so `*.wants` reaches rm "
        "literally, leaves a dangling link, and LINK-GUARD fails the next deploy"
    )
    assert not [line for line in lines if "--user link" in line and "beacon-hermes-poll" in line], (
        "a link line would put the user unit back"
    )
