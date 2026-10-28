"""The Devin listener's hardening drop-in exists and stays inside user-unit limits."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DROPIN = ROOT / "systemd" / "tincan-listen-devin-vps.service.d" / "80-hardening.conf"

REQUIRED = {
    "PrivateTmp": "yes",
    "ProtectSystem": "strict",
    "ProtectHome": "read-only",
    "ProtectProc": "invisible",
    "ProtectKernelTunables": "yes",
    "ProtectControlGroups": "yes",
    "ProtectHostname": "yes",
    "DevicePolicy": "closed",
    "RestrictRealtime": "yes",
    "RestrictSUIDSGID": "yes",
    "LockPersonality": "yes",
    "SystemCallArchitectures": "native",
    "KeyringMode": "private",
}
FORBIDDEN = {
    "CapabilityBoundingSet",
    "PrivateDevices",
    "PrivateUsers",
    "ProtectClock",
    "ProtectKernelModules",
    "ProtectKernelLogs",
    "User",
    "DynamicUser",
    "RootDirectory",
}
FAMILIES = {"AF_UNIX", "AF_INET", "AF_INET6", "AF_NETLINK"}
SYSCALL_GROUPS = {
    "@clock",
    "@cpu-emulation",
    "@debug",
    "@module",
    "@mount",
    "@obsolete",
    "@privileged",
    "@raw-io",
    "@reboot",
    "@swap",
}
NAMESPACE_TYPES = {"user", "pid", "net", "mnt", "uts", "ipc", "cgroup"}


def parse(path: Path) -> dict[str, dict[str, str]]:
    """Section name to its last value per key; every key in this drop-in is single-valued."""
    sections: dict[str, dict[str, str]] = {}
    current = None
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith(("#", ";")):
            continue
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1]
            sections.setdefault(current, {})
        elif current is not None and "=" in line:
            key, _, value = line.partition("=")
            sections[current][key.strip()] = value.strip()
    return sections


def service() -> dict[str, str]:
    assert DROPIN.is_file(), f"{DROPIN.relative_to(ROOT)} missing"
    sections = parse(DROPIN)
    assert "Service" in sections, f"{DROPIN.name}: no [Service] section"
    return sections["Service"]


def test_write_paths_cover_the_listener() -> None:
    read_write = service().get("ReadWritePaths", "")
    paths = read_write.split()
    assert "/home/nish" in paths, "ReadWritePaths= must keep home writes for git, node and Devin"
    assert "/run/user/1000" in paths, "ReadWritePaths= must keep the runtime dir for the socket"


def test_every_switch_is_set() -> None:
    svc = service()
    for key, expected in REQUIRED.items():
        assert svc.get(key) == expected, f"{DROPIN.name}: {key}={expected} missing"


def test_address_families_and_syscall_and_namespace_deny_lists() -> None:
    svc = service()
    families = set(svc.get("RestrictAddressFamilies", "").split())
    assert FAMILIES <= families, f"{DROPIN.name}: missing socket families {FAMILIES - families}"
    groups = set(svc.get("SystemCallFilter", "").replace("~", " ").split())
    assert SYSCALL_GROUPS <= groups, f"{DROPIN.name}: missing syscall groups {SYSCALL_GROUPS - groups}"
    assert "@resources" not in groups, f"{DROPIN.name}: @resources would SIGSYS bun's setrlimit"
    assert svc.get("SystemCallErrorNumber") == "EPERM", f"{DROPIN.name}: denied syscalls must return EPERM"
    restricted = svc.get("RestrictNamespaces", "")
    assert restricted.startswith("~"), f"{DROPIN.name}: RestrictNamespaces= must be a ~ deny list"
    types = set(restricted.lstrip("~").split())
    assert NAMESPACE_TYPES <= types, f"{DROPIN.name}: missing namespace types {NAMESPACE_TYPES - types}"


def test_no_user_unit_fatal_directives() -> None:
    svc = service()
    present = [key for key in FORBIDDEN if key in svc]
    assert not present, f"{DROPIN.name}: {present} need capabilities the user manager does not have"
