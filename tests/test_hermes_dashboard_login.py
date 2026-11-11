"""The gateway's own drop-in loads the dashboard login settings (fleet-ops#11900).

The file it loads is the one hermes-serve.service names, so the test reads the
path from that unit instead of repeating it.
"""

from pathlib import Path

SYSTEM = Path(__file__).resolve().parents[1] / "rootfs/etc/systemd/system"
DROPIN = SYSTEM / "hermes-gateway.service.d/10-dashboard-login.conf"
SERVE = SYSTEM / "hermes-serve.service"


def test_the_gateway_dropin_loads_the_dashboard_login_settings() -> None:
    serve_file = next(
        line.split("=", 1)[1].lstrip("-")
        for line in SERVE.read_text().splitlines()
        if line.startswith("EnvironmentFile=")
    )
    assert DROPIN.is_file()
    assert f"EnvironmentFile=-{serve_file}" in DROPIN.read_text().splitlines()
