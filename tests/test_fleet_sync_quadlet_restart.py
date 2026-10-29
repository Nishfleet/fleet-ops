"""fleet-sync restarts Grafana when a quadlet edit lands in the deploy clone (fleet-ops#10820)."""

import shlex
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UNIT = ROOT / "systemd" / "fleet-sync.service"
HOME = Path.home()
CLONE = "workspaces/tooling/fleet-ops-deploy-clone"
QUADLET = "containers/quadlet/fleet-grafana.container"
MARKER = ".config/fleet-ops/grafana-quadlet.container"
DAEMON_RELOAD = "/usr/bin/systemctl --user daemon-reload"
MERGE = f"/usr/bin/git -C {HOME}/{CLONE} merge --ff-only refs/remotes/origin/main"
QUADLET_BYTES = b"Image=grafana/grafana:13.2.3@sha256:b28bae15\nSecret=grafana-postgres-password,type=mount\n"


def expand(raw: str, home: Path) -> str:
    return (
        raw.replace("%%", "\x00")
        .replace("$$", "\x01")
        .replace("%h", str(home))
        .replace("\x00", "%")
        .replace("\x01", "$")
    )


def steps(home: Path) -> list[str]:
    return [expand(raw[len("ExecStart=") :], home) for raw in UNIT.read_text().splitlines() if raw.startswith("ExecStart=")]


def is_quadlet_step(step: str) -> bool:
    return "cmp -s" in step and "grafana-quadlet.container" in step


def quadlet_step(home: Path, systemctl: str) -> list[str]:
    for raw in UNIT.read_text().splitlines():
        if not raw.startswith("ExecStart="):
            continue
        expanded = expand(raw[len("ExecStart=") :], home)
        if is_quadlet_step(expanded):
            return shlex.split(expanded.replace("/usr/bin/systemctl", systemctl))
    raise AssertionError("no quadlet restart step found in systemd/fleet-sync.service")


def home_at(tmp_path: Path, quadlet: bytes) -> Path:
    home = tmp_path / "home"
    (home / CLONE / QUADLET).parent.mkdir(parents=True)
    (home / CLONE / QUADLET).write_bytes(quadlet)
    return home


def stub(tmp_path: Path, exit_code: int = 0) -> tuple[Path, Path]:
    binary = tmp_path / "bin" / "systemctl"
    binary.parent.mkdir(parents=True, exist_ok=True)
    binary.write_text(f'#!/bin/sh\nprintf "%s\\n" "$*" >> "$STUB_LOG"\nexit {exit_code}\n')
    binary.chmod(0o755)
    log = tmp_path / "systemctl.log"
    log.write_text("")
    return binary, log


def run(home: Path, binary: Path, log: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        quadlet_step(home, str(binary)),
        capture_output=True,
        text=True,
        check=False,
        env={"PATH": "/usr/bin:/bin", "STUB_LOG": str(log)},
    )


def systemctl_argv(script: list[str]) -> list[str]:
    argv = ["/usr/bin/systemctl"]
    for token in script[script.index("/usr/bin/systemctl") + 1 :]:
        if token in {"&&", "||", ";"} or token.endswith(";"):
            break
        argv.append(token)
    return argv


def shell_script(step: str) -> list[str]:
    argv = shlex.split(step)
    return shlex.split(argv[argv.index("-c") + 1])


def test_a_changed_quadlet_restarts_grafana_and_records_the_bytes_it_started_from(tmp_path: Path) -> None:
    binary, log = stub(tmp_path)
    home = home_at(tmp_path, QUADLET_BYTES)
    proc = run(home, binary, log)
    assert proc.returncode == 0, proc.stderr
    assert log.read_text() == "--user try-restart fleet-grafana.service\n"
    marker = home / MARKER
    assert marker.read_bytes() == QUADLET_BYTES
    assert marker.stat().st_mode & 0o777 == 0o600


def test_a_failed_restart_records_nothing_so_the_next_sync_retries(tmp_path: Path) -> None:
    binary, log = stub(tmp_path, exit_code=1)
    home = home_at(tmp_path, QUADLET_BYTES)
    proc = run(home, binary, log)
    assert proc.returncode != 0, "a failed try-restart must fail the step, not be swallowed"
    assert log.read_text() == "--user try-restart fleet-grafana.service\n"
    assert not (home / MARKER).exists(), "a marker written before the restart would hide the failure from every later sync"


def test_a_quadlet_absent_from_the_clone_restarts_nothing(tmp_path: Path) -> None:
    binary, log = stub(tmp_path)
    home = tmp_path / "home"
    (home / CLONE / QUADLET).parent.mkdir(parents=True)
    proc = run(home, binary, log)
    assert proc.returncode != 0, "a clone with no quadlet is a fault, not a no-op"
    assert log.read_text() == ""
    assert not (home / MARKER).exists()


def test_an_unchanged_quadlet_restarts_nothing(tmp_path: Path) -> None:
    binary, log = stub(tmp_path)
    home = home_at(tmp_path, QUADLET_BYTES)
    (home / MARKER).parent.mkdir(parents=True)
    (home / MARKER).write_bytes(QUADLET_BYTES)
    proc = run(home, binary, log)
    assert proc.returncode == 0, proc.stderr
    assert log.read_text() == ""


def test_the_step_never_starts_a_grafana_stopped_on_purpose() -> None:
    step = next(s for s in steps(HOME) if is_quadlet_step(s))
    assert systemctl_argv(shell_script(step)) == ["/usr/bin/systemctl", "--user", "try-restart", "fleet-grafana.service"]
    assert "restart fleet-grafana.service" not in step.replace("try-restart fleet-grafana.service", "")


def test_the_step_runs_after_the_merge_and_the_daemon_reload_that_carry_the_edit() -> None:
    found = steps(HOME)
    merge_at = found.index(MERGE)
    reload_at = found.index(DAEMON_RELOAD)
    step_at = next(i for i, s in enumerate(found) if is_quadlet_step(s))
    assert merge_at < reload_at < step_at, "the restart must apply the unit the merge landed and daemon-reload regenerated"


def test_the_marker_never_sits_inside_the_deploy_clone() -> None:
    step = next(s for s in steps(HOME) if is_quadlet_step(s))
    assert MARKER in step
    assert f"{CLONE}/{MARKER}" not in step, "a marker inside the clone is reset by the git merge above it"


def test_the_compare_and_the_marker_both_read_the_clone_copy() -> None:
    step = next(s for s in steps(HOME) if is_quadlet_step(s))
    clone_quadlet = f"{CLONE}/{QUADLET}"
    assert step.count(clone_quadlet) == 3, "the test -f guard, the compare and the marker write must all read the clone copy"
    assert "containers/quadlet" not in step.replace(clone_quadlet, ""), "no glob and no second quadlet"
