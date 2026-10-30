"""The detached worker's launch line bounds the Pi run (fleet-ops#10448).

`fix-pr-10422.service` was a one-shot Pi worker that ran its full hour at 14 s of
CPU and wrote no deliverable, so the `ExecStopPost` check failed it and
`SystemUnitFailed` fired. A model call that never returns holds the whole
process, and pi has no per-request timeout to cut it loose, so the launch line
must carry the bound itself. A line that only sets `RuntimeMaxSec` reproduces
that unit.
"""

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
DOC = ROOT / "docs/detached-worker-unit.md"
ISSUE = "10448"


@pytest.fixture(scope="module")
def launch_line():
    lines = [line for line in DOC.read_text().splitlines() if "systemd-run" in line and "RuntimeMaxSec" in line]
    assert len(lines) == 1, f"expected one launch line, found {len(lines)}"
    return lines[0].strip()


@pytest.fixture(scope="module")
def bullets():
    blocks, current = [], []
    for line in DOC.read_text().splitlines():
        if line.startswith("- "):
            if current:
                blocks.append(current)
            current = [line]
        elif current:
            current.append(line)
    if current:
        blocks.append(current)
    return [" ".join(block) for block in blocks]


def test_the_launch_line_wraps_pi_in_a_timeout(launch_line):
    assert re.search(r"-- timeout --verbose \S+ sh -c '.*pi --print", launch_line), (
        "the launch line must bound the Pi call itself:\n" + launch_line
    )


def test_the_timeout_names_the_death_in_the_journal(launch_line):
    assert "timeout --verbose" in launch_line, (
        "without --verbose a timed-out run's journal names no cause, which is what made "
        "fix-pr-10422.service need guesswork (fleet-ops#10448):\n" + launch_line
    )


def test_the_timeout_and_the_deadline_are_separate_placeholders(launch_line):
    deadline = re.search(r"-p RuntimeMaxSec=(\S+)", launch_line).group(1)
    pi_seconds = re.search(r"-- timeout --verbose (\S+) sh -c", launch_line).group(1)
    assert pi_seconds != deadline, (
        "the timeout must be its own placeholder, so a launch can set it below the deadline"
    )


def test_the_doc_says_why_the_timeout_is_there(bullets):
    named = [block for block in bullets if "no per-request timeout" in block]
    assert named, "the launch line carries no reason for the Pi timeout"
    assert any(ISSUE in block for block in named), f"the reason does not name fleet-ops#{ISSUE}"


def test_the_doc_keeps_the_deadline_above_the_timeout(bullets):
    assert any("below" in block and "dead-man" in block for block in bullets), (
        "the doc does not say the timeout sits below RuntimeMaxSec, so a launcher can set them equal"
    )
