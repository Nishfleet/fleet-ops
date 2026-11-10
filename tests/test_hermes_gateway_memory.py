"""The gateway's memory caps live in a drop-in, never in a copy of Hermes' unit (fleet-ops#11864).

`hermes gateway install --system` writes hermes-gateway.service with a PATH that
names the tool directories of the version it installed, and `hermes gateway
restart --system` rewrites that PATH on an upgrade. The play re-copies rootfs/ on
every run and copy never deletes, so a checked-in copy would put the old PATH
back and report a change on every play. The caps stay in the shared drop-in,
which systemd also loads for hermes-gateway.service: for foo-bar.service it reads
foo-.service.d/ as well (systemd NEWS, v209, "drop-in unit file extensions in
additional places").
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SYSTEM = ROOT / "rootfs/etc/systemd/system"
DROPIN = SYSTEM / "hermes-.service.d/sandbox.conf"


def _service_values(path: Path) -> dict[str, list[str]]:
    found: dict[str, list[str]] = {}
    for line in path.read_text().splitlines():
        if line.startswith(("#", "[")) or "=" not in line:
            continue
        key, value = line.split("=", 1)
        found.setdefault(key, []).append(value)
    return found


def test_the_shared_dropin_caps_the_gateway() -> None:
    values = _service_values(DROPIN)
    assert values["MemoryHigh"] == ["6G"]
    assert values["MemoryMax"] == ["8G"]


def test_hermes_gateway_unit_stays_the_installers() -> None:
    assert not (SYSTEM / "hermes-gateway.service").exists(), (
        "hermes-gateway.service is written by Hermes' installer, and the play's tree copy "
        "would put its versioned PATH back after an upgrade. Keep the caps in "
        "hermes-.service.d/sandbox.conf instead of checking in a copy of the unit."
    )
