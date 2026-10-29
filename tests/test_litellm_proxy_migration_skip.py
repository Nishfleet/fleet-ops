"""The router's migration pre-start runs once per (image digest, applied-migration count), not on every start.

fleet-litellm-proxy.container: ExecStartPre= step 2 is a sh -c line that skips the image's migration job when
a marker for the same digest and the same count exists, and writes the marker only after the job succeeds.
The line runs here under sh with psql and podman replaced by stubs.
"""

import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
QUADLET = ROOT / "containers/quadlet/fleet-litellm-proxy.container"


def migration_line() -> str:
    lines = re.findall(r"^ExecStartPre=/bin/sh -c '(.*skip_server_startup.*)'$", QUADLET.read_text(), re.M)
    assert len(lines) == 1, lines
    return lines[0]


def run(tmp: Path, count: int, podman_rc: int = 0) -> tuple[int, int]:
    """Run the line once. Returns (exit code, number of times the migration job ran)."""
    state, calls = tmp / "state", tmp / "calls"
    psql, podman = tmp / "psql", tmp / "podman"
    psql.write_text(f"#!/bin/sh\necho {count}\n")
    podman.write_text(f"#!/bin/sh\necho run >> {calls}\nexit {podman_rc}\n")
    psql.chmod(0o755)
    podman.chmod(0o755)
    # systemd turns $$ into $ and expands %S; the stubs stand in for the two absolute paths.
    line = migration_line().replace("$$", "$").replace("%S", str(state))
    line = line.replace("/usr/bin/psql", str(psql)).replace("/usr/bin/podman", str(podman))
    rc = subprocess.run(["/bin/sh", "-c", line], capture_output=True).returncode
    return rc, calls.read_text().count("run") if calls.exists() else 0


def test_first_start_migrates_and_a_repeat_with_nothing_changed_skips(tmp_path: Path) -> None:
    assert run(tmp_path, 195) == (0, 1)
    assert run(tmp_path, 195) == (0, 1), "second start with the same digest and count must not run the job again"
    assert run(tmp_path, 195) == (0, 1)


def test_a_different_migration_count_runs_the_job_again(tmp_path: Path) -> None:
    assert run(tmp_path, 152) == (0, 1)
    assert run(tmp_path, 195) == (0, 2), "a restored or older schema has another count, so it must migrate"


def test_a_failed_job_fails_the_start_and_leaves_no_marker(tmp_path: Path) -> None:
    rc, runs = run(tmp_path, 195, podman_rc=1)
    assert rc != 0 and runs == 1
    rc, runs = run(tmp_path, 195, podman_rc=1)
    assert rc != 0 and runs == 2, "no marker after a failure, so the next start tries again"
    assert run(tmp_path, 195) == (0, 3)


def test_the_marker_is_keyed_on_the_image_digest() -> None:
    line = migration_line()
    digest = re.search(r"@sha256:([0-9a-f]{64})", line)
    assert digest and "litellm-migrated-$${i##*@sha256:}-$$n" in line


def test_the_stop_window_is_bounded_by_podman_inside_systemd() -> None:
    """A restart's stop is `podman rm -f`, which waits the container's own --stop-timeout and then SIGKILLs.

    That value is fixed when the container is created, so a unit edit changes the bound only for the next
    container: the 2026-10-23 17:08 IST stop of a container made under --stop-timeout=110 waited out systemd's
    new TimeoutStopSec=60 (Stopping timed out 17:09:55, SIGKILL 17:10:55). The pair must stay ordered so
    podman's SIGKILL, which removes the container cleanly, always fires before systemd's.
    """
    text = QUADLET.read_text()
    stop = [int(x) for x in re.findall(r"^PodmanArgs=--stop-timeout=(\d+)$", text, re.M)]
    unit = [int(x) for x in re.findall(r"^TimeoutStopSec=(\d+)$", text, re.M)]
    assert len(stop) == 1 and len(unit) == 1, (stop, unit)
    assert stop[0] <= 45, "a restart must not stall longer than 45 s"
    assert stop[0] + 10 <= unit[0], "systemd's timeout must leave room after podman's SIGKILL"
