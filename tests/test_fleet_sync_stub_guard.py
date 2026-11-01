"""fleet-sync's STUB-GUARD fails the unit when a launch path is a copy of /bin/true (fleet-ops#10525)."""

import shlex
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UNIT = ROOT / "systemd" / "fleet-sync.service"


def guard(home: Path) -> list[str]:
    for raw in UNIT.read_text().splitlines():
        if raw.startswith("ExecStart=") and "STUB-GUARD" in raw:
            text = raw[len("ExecStart=") :].replace("%h", str(home)).replace("$$", "$")
            return shlex.split(text)
    raise AssertionError("no STUB-GUARD ExecStart line")


def run(home: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(guard(home), capture_output=True, text=True, check=False)


def test_a_launch_path_that_is_a_copy_of_bin_true_fails_loud(tmp_path: Path) -> None:
    (tmp_path / ".local/bin").mkdir(parents=True)
    stub = tmp_path / ".local/bin/claude"
    shutil.copy("/bin/true", stub)
    proc = run(tmp_path)
    assert proc.returncode != 0
    assert str(stub) in proc.stdout


def test_a_symlink_to_a_stub_fails_loud(tmp_path: Path) -> None:
    (tmp_path / ".local/bin").mkdir(parents=True)
    real = tmp_path / "true-copy"
    shutil.copy("/bin/true", real)
    (tmp_path / ".local/bin/pi").symlink_to(real)
    assert run(tmp_path).returncode != 0


def test_real_programs_and_missing_paths_pass(tmp_path: Path) -> None:
    (tmp_path / ".local/bin").mkdir(parents=True)
    real = tmp_path / ".local/bin/claude"
    real.write_text("#!/bin/sh\necho 2.1.312\n")
    real.chmod(0o755)
    proc = run(tmp_path)
    assert (proc.returncode, proc.stdout) == (0, "")
