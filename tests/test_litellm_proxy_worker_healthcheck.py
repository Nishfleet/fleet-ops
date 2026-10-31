"""The router parent must not SIGKILL workers for answering a startup import slower than 5 s.

fleet-ops#11372: uvicorn pings each spawned worker with timeout_worker_healthcheck default
5 s, while a litellm worker answers only after re-importing all of litellm on spawn, fast
enough to blow that window (measured 8.1-23.8 s warm in a local venv of the pinned
litellm 1.105.0; 24.6-26.0 s cold / 18-21 s warm in the container per the
fleet-litellm-proxy.container import note). The 2026-10-31 boots lost 1-252 workers at
journal-observed 5.0-5.5 s kill cadence. The fix is the TIMEOUT_WORKER_HEALTHCHECK
environment the litellm CLI forwards to uvicorn.Config (:315-318) as
timeout_worker_healthcheck.
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
QUADLET = ROOT / "containers/quadlet/fleet-litellm-proxy.container"


def values(key: str) -> list[str]:
    return re.findall(rf"^{key}=(.*)$", QUADLET.read_text(), re.M)


def test_120_s_worker_healthcheck_window_present_exactly_once() -> None:
    lines = [line for line in values("Environment") if line.startswith("TIMEOUT_WORKER_HEALTHCHECK=")]
    assert len(lines) == 1
    assert int(lines[0].split("=", maxsplit=1)[1]) >= 120


def test_worker_healthcheck_stays_a_static_value_not_a_host_pass_through() -> None:
    pass_through = [args for args in values("PodmanArgs") if "TIMEOUT_WORKER_HEALTHCHECK" in args]
    assert pass_through == [], "--env=TIMEOUT_WORKER_HEALTHCHECK reads the host name from the unit environment; the window is a fixed container value"


def test_worker_healthcheck_is_not_reduced_to_the_uvicorn_default_by_the_exec_line() -> None:
    exec_lines = values("Exec")
    assert len(exec_lines) == 1
    assert "--timeout-worker-healthcheck" not in exec_lines[0], "two windows now: pin one at the Environment= line only"
