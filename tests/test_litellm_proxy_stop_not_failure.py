"""A planned stop of the router must not page, while a crash, an OOM kill or a failed start still must.

fleet-litellm-proxy.container: the stop ends in podman's SIGKILL of a hung uvicorn worker (fleet-ops#10177),
so conmon exits 137. systemd reads these keys, so the test pins them.
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
QUADLET = ROOT / "containers/quadlet/fleet-litellm-proxy.container"


def values(key: str) -> list[str]:
    return re.findall(rf"^{key}=(.*)$", QUADLET.read_text(), re.MULTILINE)


def test_exit_137_from_the_stop_is_a_success() -> None:
    assert values("SuccessExitStatus") == ["137"], "only 137; 125 (podman failed to start) and 139 must stay failures"


def test_an_oom_kill_still_fails_the_unit() -> None:
    assert values("OOMPolicy") == ["stop"], "a 137 from the kernel OOM killer must end as oom-kill, not success"
    assert values("Restart") == ["on-failure"]
