"""Every Hermes cron prompt step sets the shell variables it reads.

fleet-ops#9575: scorecard-weekly computed S7, E and T on one ``W:`` line and
read them in later steps, but every Hermes terminal call is a fresh
``subprocess.Popen`` shell, so those variables were empty in every later
step and the scorecard reported a week of zeros.

The gate runs each step's command under ``bash -u``, where reading a variable
the same command never set aborts the shell, and fails the test when it does.
Steps carry a plain-language label and often a trailing explanation, so the
command is cut out with bash as the oracle: the longest prefix bash can parse,
starting either at the top of the line or after a label, is what runs.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
PROMPT_DIR = ROOT / "config" / "hermes"
BASH = shutil.which("bash") or "/bin/bash"

SAFE_COMMANDS = (
    "awk",
    "basename",
    "comm",
    "cut",
    "date",
    "dirname",
    "env",
    "expr",
    "grep",
    "head",
    "jq",
    "join",
    "sed",
    "seq",
    "sort",
    "tail",
    "tr",
    "uniq",
    "wc",
)

STEP_LINE = re.compile(r"^(?:W:|\d+[a-z]? )")
LABEL_END = re.compile(r": ")
CUT_AFTER = re.compile(r"[;|&.]")


def prompts() -> list[Path]:
    return sorted(PROMPT_DIR.glob("*.md"))


def step_lines(text: str) -> list[tuple[int, str]]:
    return [(n, line) for n, line in enumerate(text.splitlines(), 1) if STEP_LINE.match(line)]


@pytest.fixture(scope="session")
def stub_path(tmp_path_factory) -> str:
    """A PATH holding only read-only coreutils, so a step cannot touch anything.

    Every command a step could use for real work (gh, hermes, psql, sqlite3,
    systemctl, cf, curl) is absent, which fails the call and leaves the
    variable expansion intact.
    """
    directory = tmp_path_factory.mktemp("prompt-stubs")
    for name in SAFE_COMMANDS:
        real = shutil.which(name)
        if real:
            (directory / name).symlink_to(real)
    return str(directory)


def _parses(script: str) -> bool:
    return subprocess.run([BASH, "-n", "-c", script], capture_output=True).returncode == 0


def _longest_parsable_prefix(text: str) -> str:
    ends = [m.end() for m in CUT_AFTER.finditer(text)]
    ends.append(len(text))
    for end in sorted(ends, reverse=True):
        candidate = text[:end]
        if _parses(candidate):
            return candidate
    return ""


def command_of(line: str) -> str:
    """The shell command a step line runs, without its label or trailing prose.

    A step line opens with a label (``W:`` or ``3b SOME WORDS:``) and closes
    with a plain-language explanation, and neither is shell. The label is cut
    at its first colon, and the explanation is cut by the same parsable-prefix
    rule, so what is left is the command and only the command.
    """
    start = 0
    if STEP_LINE.match(line):
        label = LABEL_END.search(line)
        if label:
            start = label.end()
    return _longest_parsable_prefix(line[start:])


def unbound_variables(script: str, stub_path: str) -> list[str]:
    env = dict(os.environ)
    env["PATH"] = stub_path
    env["HOME"] = str(Path.home())
    result = subprocess.run(
        [BASH, "-u", "-c", script],
        capture_output=True,
        env=env,
        stdin=subprocess.DEVNULL,
        timeout=120,
    )
    stderr = result.stderr.decode(errors="replace")
    return [ln for ln in stderr.splitlines() if "unbound variable" in ln]


@pytest.mark.parametrize("prompt", [p.name for p in prompts()], ids=lambda name: name)
def test_every_step_sets_the_variables_it_reads(prompt: str, stub_path: str) -> None:
    text = (PROMPT_DIR / prompt).read_text()
    steps = step_lines(text)
    assert steps, f"{prompt} has no numbered step to check"
    for number, line in steps:
        command = command_of(line)
        if not command:
            assert "$" not in line, (
                f"{prompt}:{number} reads a variable but carries no command the gate can read:\n{line}"
            )
            continue
        unbound = unbound_variables(command, stub_path)
        assert not unbound, f"{prompt}:{number} reads a variable it never sets: {unbound}\n{line}"


def test_the_gate_catches_a_variable_read_in_a_later_step(stub_path: str) -> None:
    broken = (
        "W: S7=$(date -u -d '7 days ago' +%F); echo \"$S7\"",
        "1 REAL USERS (0509 production): gh pr list --search \"merged:>=$S7\" --json number",
    )
    assert command_of(broken[0]) == 'S7=$(date -u -d \'7 days ago\' +%F); echo "$S7"'
    command = command_of(broken[1])
    assert command == 'gh pr list --search "merged:>=$S7" --json number'
    assert unbound_variables(command, stub_path), "a variable set on another line must be caught"


def test_a_step_that_computes_its_own_dates_is_clean(stub_path: str) -> None:
    line = "3 MERGE SPREAD: S7=$(date -u -d '7 days ago' +%F); T=$(date -u +%F); echo \"$S7..$T\""
    command = command_of(line)
    assert command == 'S7=$(date -u -d \'7 days ago\' +%F); T=$(date -u +%F); echo "$S7..$T"'
    assert unbound_variables(command, stub_path) == []


def test_prose_after_the_command_is_dropped() -> None:
    line = "2 SHIPPED CHANGES: echo \"done\" 2>/dev/null. It is Nish's own note each Monday."
    command = command_of(line)
    assert command.startswith('echo "done"')
    assert "Nish" not in command


def test_a_bare_command_line_is_kept_whole() -> None:
    line = "W=$(printf '%s' \"$R\" | jq -c 'select(type==\"object\")'); test -n \"$W\" || W=null"
    assert command_of(line) == line
