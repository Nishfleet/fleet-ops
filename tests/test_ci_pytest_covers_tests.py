"""Every tests/test_*.py on disk is named in a ci.yml step that runs pytest.

ci.yml runs pytest by an explicit file list, so a test file no step names rots
with no signal. tests/test_fleet_update_covers_apps.py kept asserting a step
#9971 had removed, and nothing on main went red (fleet-ops#10073); #10075 fixed
that instance. This check is the mechanism: a test file added with no pytest
step naming it fails here.

Only a step whose run block invokes pytest is read. A step that runs another
kind of check (an ansible play, a plain python script) is out of scope.
"""

from __future__ import annotations

import glob
import json
import shlex
import subprocess
from fnmatch import fnmatch
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CI = ROOT / ".github" / "workflows" / "ci.yml"
STEP_RUNS = '.jobs[].steps[] | .run // ""'
TEST_FILES = "tests/test_*.py"
EVERYTHING = ("tests", "tests/")


def step_runs() -> list[str]:
    """Every step's run block in ci.yml, read live with yq."""
    done = subprocess.run(
        ["yq", "-o=json", "-I=0", STEP_RUNS, str(CI)],
        check=True,
        capture_output=True,
        text=True,
    )
    return [json.loads(line) for line in done.stdout.splitlines() if line.strip()]


def commands(run: str) -> list[str]:
    """A run block split into shell commands, with continuations joined."""
    found: list[str] = []
    pending = ""
    for line in run.splitlines():
        pending = f"{pending} {line.strip()}" if pending else line.strip()
        if pending.endswith("\\"):
            pending = f"{pending[:-1].rstrip()} "
            continue
        found.append(pending)
        pending = ""
    if pending:
        found.append(pending)
    return found


def pytest_commands(run: str) -> list[list[str]]:
    """The commands in a run block that invoke pytest, as token lists."""
    found: list[list[str]] = []
    for command in commands(run):
        if "pytest" not in command:
            continue
        found.append(shlex.split(command, comments=True))
    return found


def on_disk() -> set[str]:
    return {f"tests/{path.name}" for path in (ROOT / "tests").glob("test_*.py")}


def named_on_a_pytest_step(runs: list[str]) -> set[str]:
    """The test files a ci.yml pytest step names.

    A step that runs the whole tests/ directory names every file, so the answer
    is the whole directory and the scan stops there.
    """
    named: set[str] = set()
    for run in runs:
        for tokens in pytest_commands(run):
            for token in tokens:
                if token in EVERYTHING:
                    return on_disk()
                if fnmatch(token, TEST_FILES):
                    named.update(glob.glob(token, root_dir=ROOT))
    return named


def test_every_test_file_is_named_in_a_ci_pytest_step() -> None:
    runs = step_runs()
    found = [tokens for run in runs for tokens in pytest_commands(run)]
    assert found, "no step in .github/workflows/ci.yml runs pytest"
    uncovered = sorted(on_disk() - named_on_a_pytest_step(runs))
    assert not uncovered, (
        "these test files are on disk but no ci.yml pytest step names them, so nothing runs them: "
        + " ".join(uncovered)
        + " -- add each one to the pytest invocation of a step in .github/workflows/ci.yml"
    )
