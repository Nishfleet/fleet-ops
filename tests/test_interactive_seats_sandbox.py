"""The interactive-session sandbox binds the same-uid seat boundary.

fleet-ops#11114: deny rules bind the command text, so a same-uid reader reaches
a seat file with a relative path the rules cannot spell, and the file mode binds
only readers of other uids. The control for interactive sessions is the worker
jail's mount primitive: bubblewrap with an empty tmpfs over the seats directory,
so inside the sandbox every path spelling resolves to a namespace with nothing
in it. docs/managed-settings-defaults.md holds the launch line; this test holds
both halves: the doc must state it, and (where bubblewrap exists) the executed
sandbox must hide the probe seat and the bare shell must reach it.

The probe runs against a synthetic home, so the test never opens a real seat
file and runs unchanged on a host without the seats directory. On a host
without bubblewrap (CI) the executed tests skip and the doc assertions still
hold.
"""

import json
import os
import shlex
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
DOC = ROOT / "docs" / "managed-settings-defaults.md"
CASES = ROOT / "tests" / "evals" / "cases" / "seat_bypass.json"
SEATS_REL = ".config/fleet-ops/seats"  # gitleaks:allow
SEAT_NAME = "claude-seat-a.env"
PROBE = "SEATPROBE"


def doc_text() -> str:
    return DOC.read_text()


def test_doc_states_the_launch_line() -> None:
    text = doc_text()
    assert "bwrap --dev-bind / / --tmpfs" in text
    assert SEATS_REL in text
    assert "--proc /proc" in text
    assert "--unshare-pid" in text


@pytest.fixture(scope="module")
def fake_home() -> Path:
    home = Path(tempfile.mkdtemp(prefix="seat-sandbox-home-"))
    seats = home / SEATS_REL
    seats.mkdir(parents=True)
    (seats / SEAT_NAME).write_text(PROBE + "\n")
    yield home
    shutil.rmtree(home)


def launch_line(home: Path) -> list[str]:
    for line in doc_text().splitlines():
        if line.strip().startswith("bwrap --dev-bind / / --tmpfs"):
            tokens = [token.replace("~/", str(home) + "/") for token in shlex.split(line)]
            for flag in ("--dev-bind", "--tmpfs", "--proc", "--unshare-pid", "--die-with-parent"):
                assert flag in tokens, flag
            return tokens
    pytest.fail("no sandbox launch line under docs/managed-settings-defaults.md")


def run_case(command: str, home: Path, jailed: bool) -> subprocess.CompletedProcess:
    env = dict(os.environ, HOME=str(home))
    command_argv = ["bash", "-c", command]
    argv = launch_line(home) + command_argv if jailed else command_argv
    return subprocess.run(argv, env=env, capture_output=True, text=True)


def reached(result: subprocess.CompletedProcess) -> bool:
    return result.returncode == 0 and PROBE in result.stdout


@pytest.mark.skipif(shutil.which("bwrap") is None, reason="bubblewrap is not installed")
def test_bare_shell_reaches_the_probe_seat(fake_home: Path) -> None:
    for case in json.loads(CASES.read_text()):
        result = run_case(case["command"], fake_home, jailed=False)
        assert reached(result), f"{case['id']}: {result.stdout!r} {result.stderr!r}"


@pytest.mark.skipif(shutil.which("bwrap") is None, reason="bubblewrap is not installed")
def test_sandbox_blocks_every_held_out_bypass(fake_home: Path) -> None:
    for case in json.loads(CASES.read_text()):
        assert case["expected_after"] == "blocked"
        result = run_case(case["command"], fake_home, jailed=True)
        assert not reached(result), f"{case['id']} reached inside the sandbox: {result.stdout!r}"
