"""A router instance's SIGKILL is a failure, never a success.

With --num_workers 2 a planned stop always ended in podman's SIGKILL of a hung worker, so
SuccessExitStatus=137 recorded it as success, and a real kill -9 then neither restarted nor
paged (fleet-ops#10177, #11739). One process per instance exits 0 on a planned stop
(https://docs.litellm.ai/docs/proxy/prod), so 137 must stay a failure.
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
QUADLET = ROOT / "containers/quadlet/fleet-litellm-proxy@.container"


def values(key: str) -> list[str]:
    return re.findall(rf"^{key}=(.*)$", QUADLET.read_text(), re.MULTILINE)


def test_a_sigkill_fails_and_restarts_the_instance() -> None:
    assert values("SuccessExitStatus") == []
    assert values("Restart") == ["on-failure"]
    assert values("OOMPolicy") == ["stop"]


def test_one_uvicorn_process_per_instance() -> None:
    (exec_line,) = values("Exec")
    assert re.search(r"--num_workers 1(\s|$)", exec_line), exec_line
    assert "--port %i" in exec_line, exec_line
