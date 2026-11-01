"""The detached worker's launch line carries one timer, the deadline (fleet-ops#10448)."""

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
DOC = ROOT / "docs/detached-worker-unit.md"


@pytest.fixture(scope="module")
def launch_line():
    lines = [line for line in DOC.read_text().splitlines() if "systemd-run" in line and "RuntimeMaxSec" in line]
    assert len(lines) == 1, f"expected one launch line, found {len(lines)}"
    return lines[0].strip()


def test_the_launch_line_bounds_the_run_with_the_deadline(launch_line):
    assert re.search(r"RuntimeMaxSec=\S+", launch_line), (
        "the launch line carries no deadline, the Pi run's only bound:\n" + launch_line
    )


def test_the_launch_line_wraps_no_second_timer_around_the_pi_run(launch_line):
    assert not re.search(r"(?:^|\s)timeout\s", launch_line), (
        "a second timer beside the deadline never fires when the deadline fires "
        "first, and its journal line never appears (fleet-ops#11522):\n" + launch_line
    )
