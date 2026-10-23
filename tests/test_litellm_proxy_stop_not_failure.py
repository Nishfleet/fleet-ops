"""A planned stop of the router must not page, while a crash, an OOM kill or a failed start still must.

fleet-litellm-proxy.container: the stop ends in podman's SIGKILL of a hung uvicorn worker (fleet-ops#10177),
so conmon exits 137. systemd reads these keys, so the test pins them.
"""

import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
QUADLET = ROOT / "containers/quadlet/fleet-litellm-proxy.container"


def values(key: str) -> list[str]:
    return re.findall(rf"^{key}=(.*)$", QUADLET.read_text(), re.M)


def pre_start_scripts() -> list[str]:
    return re.findall(r"^ExecStartPre=/bin/sh -c '(.*)'$", QUADLET.read_text(), re.M)


def test_exit_137_from_the_stop_is_a_success() -> None:
    assert values("SuccessExitStatus") == ["137"], "only 137; 125 (podman failed to start) and 139 must stay failures"


def test_an_oom_kill_still_fails_the_unit_and_pages() -> None:
    assert values("OOMPolicy") == ["stop"], "a 137 from the kernel OOM killer must end as oom-kill, not success"
    assert values("OnFailure") == ["fleet-unit-failed@%N.service"]
    assert values("Restart") == ["on-failure"]


def test_a_sigkilled_pre_start_step_never_exits_137(tmp_path: Path) -> None:
    scripts = pre_start_scripts()
    assert len(scripts) == 2, "dump step and migration step"
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for tool in ("psql", "pg_dump", "pg_restore", "podman"):
        (bin_dir / tool).write_text("#!/bin/sh\nkill -KILL $$\n" if tool != "psql" else "#!/bin/sh\necho 1\n")
        (bin_dir / tool).chmod(0o755)
    for script in scripts:
        script = script.replace("$$", "$").replace("/usr/bin/", f"{bin_dir}/").replace("/bin/mv", "mv")
        script = script.replace("%h", str(tmp_path)).replace("%S", str(tmp_path))
        (tmp_path / "workspaces/agent-state/backups").mkdir(parents=True, exist_ok=True)
        rc = subprocess.run(["/bin/sh", "-c", script], cwd=tmp_path, check=False).returncode
        assert rc == 1, f"a killed step must exit 1, got {rc}: {script[:60]}"
