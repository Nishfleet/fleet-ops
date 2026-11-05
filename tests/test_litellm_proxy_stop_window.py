"""The router's restart stop is bounded by podman's own SIGKILL, inside systemd's stop timeout."""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
QUADLET = ROOT / "containers/quadlet/fleet-litellm-proxy@.container"


def test_the_stop_window_is_bounded_by_podman_inside_systemd() -> None:
    """A restart's stop is `podman rm -f`, which waits the container's own --stop-timeout and then SIGKILLs.

    That value is fixed when the container is created, so a unit edit changes the bound only for the next
    container: the 2026-10-23 17:08 IST stop of a container made under --stop-timeout=110 waited out systemd's
    new TimeoutStopSec=60 (Stopping timed out 17:09:55, SIGKILL 17:10:55). The pair must stay ordered so
    podman's SIGKILL, which removes the container cleanly, always fires before systemd's.
    """
    text = QUADLET.read_text()
    stop = [int(x) for x in re.findall(r"^PodmanArgs=--stop-timeout=(\d+)$", text, re.MULTILINE)]
    unit = [int(x) for x in re.findall(r"^TimeoutStopSec=(\d+)$", text, re.MULTILINE)]
    assert len(stop) == 1 and len(unit) == 1, (stop, unit)
    assert stop[0] >= 300, "the drain must cover the p99.9 call (298 s, fleet-ops#11739)"
    assert stop[0] + 10 <= unit[0], "systemd's timeout must leave room after podman's SIGKILL"
