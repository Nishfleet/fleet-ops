"""promtool and amtool hold the deployed alert configs (fleet-ops#11032).

The dead-man Watchdog, SystemUnitFailed and HermesGatewayDown rules and the
Alertmanager routing the host installs from rootfs/etc/prometheus must parse and
route as deployed. promtool check config also loads the rule file named by
rule_files, and neither check opens url_file or bot_token_file (verified with both
paths missing), so a runner without the box's credential files passes. The route
tests prove the matchers: Watchdog reaches the dead-man, severity=nish reaches
Telegram, a plain warning reaches neither.
"""

import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
PROMETHEUS = ROOT / "rootfs/etc/prometheus"
ALERTMANAGER = ROOT / "rootfs/etc/alertmanager/alertmanager.yml"
PROMTOOL = shutil.which("promtool")
AMTOOL = shutil.which("amtool")


def _run(argv, want=None):
    done = subprocess.run(argv, capture_output=True, text=True, timeout=120)
    assert done.returncode == 0, f"{' '.join(argv)} failed:\n{done.stdout}\n{done.stderr}"
    if want is not None:
        assert want in done.stdout.splitlines(), f"{argv[-1]} routed to {done.stdout!r}, want {want}"


@pytest.fixture(scope="module", autouse=True)
def _binaries_on_path():
    assert PROMTOOL, "promtool must be on PATH to check the deployed Prometheus configs"
    assert AMTOOL, "amtool must be on PATH to check the deployed Alertmanager config"


def test_prometheus_config_and_rules_parse():
    _run([PROMTOOL, "check", "config", str(PROMETHEUS / "prometheus.yml")])
    _run([PROMTOOL, "check", "rules", str(PROMETHEUS / "fleet_rules.yml")])


def test_alertmanager_config_parses():
    _run([AMTOOL, "check-config", str(ALERTMANAGER)])


@pytest.mark.parametrize(
    ("labels", "receiver"),
    [
        ({"alertname": "Watchdog", "severity": "none"}, "deadman"),
        ({"alertname": "HermesGatewayDown", "severity": "nish"}, "telegram"),
        ({"alertname": "SystemUnitFailed", "severity": "warning"}, "none"),
    ],
)
def test_routes_reach_their_receiver(labels, receiver):
    argv = [AMTOOL, "config", "routes", "test", f"--config.file={ALERTMANAGER}", f"--verify.receivers={receiver}"]
    argv += [f"{key}={value}" for key, value in labels.items()]
    _run(argv, want=receiver)


def test_prometheus_rule_tests():
    tests = sorted((ROOT / "config/prometheus-tests").glob("*.test.yml"))
    assert tests, "config/prometheus-tests holds no *.test.yml, so the rule tests are gone"
    _run([PROMTOOL, "test", "rules", *[str(path) for path in tests]])
