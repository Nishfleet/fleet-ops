"""pi's retry wait must outlast a router restart, or a call refused mid-restart fails the run (fleet-ops#11739)."""

import re
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
READINESS_S = 75


def pi_wait_s(retries: int, base_ms: int = 2000, cap_ms: int = 60000) -> float:
    return sum(min(base_ms * 2 ** (n - 1), cap_ms) for n in range(1, retries + 1)) / 1000


def test_pi_retries_outlast_the_drain_and_the_start() -> None:
    play = yaml.safe_load((ROOT / "ansible/host.yml").read_text())[0]
    retries = play["vars"]["pi_router_retry"]["maxRetries"]
    quadlet = (ROOT / "containers/quadlet/fleet-litellm-proxy.container").read_text()
    stop = int(re.search(r"^PodmanArgs=--stop-timeout=(\d+)$", quadlet, re.MULTILINE).group(1))
    assert pi_wait_s(retries) >= stop + READINESS_S, (pi_wait_s(retries), stop)


def test_pi_default_retries_fail_a_restart() -> None:
    assert pi_wait_s(3) < 300 + READINESS_S


def test_both_router_callers_get_the_retry() -> None:
    runners = (ROOT / "ansible/tasks/runners.yml").read_text()
    assert runners.count("'retry': pi_router_retry") == 2
