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


# fleet-ops#11896: the installer-written gateway unit carries no EnvironmentFile, so the
# deploy of 2026-11-10 that restarted Hermes onto a changed sandbox.conf left it refusing
# to start for ~8 minutes and Prometheus fired HermesGatewayDown. The dashboard login env
# file hermes-serve.service reads itself joined the shared drop-in instead, and the hand
# bridge that restarted the gateway on the box was retired; both locks hold or it breaks
# again.
def test_the_shared_dropin_carries_the_gateway_login() -> None:
    values = _service_values(DROPIN)
    assert values["EnvironmentFile"] == ["-/home/nish/.hermes/secrets.env"]


def test_no_per_unit_gateway_dropin_is_checked_in() -> None:
    assert not (SYSTEM / "hermes-gateway.service.d").exists(), (
        "the gateway's dashboard-login line lives in hermes-.service.d/sandbox.conf; "
        "a per-unit hermes-gateway.service.d in rootfs/ would put the hand bridge "
        "(fleet-ops#11896) back on the play as a checked-in file."
    )
