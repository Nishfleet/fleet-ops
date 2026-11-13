"""The Worker step fails loudly when its engine prints nothing or dies (fleet-ops#11946).

Run 43258852407: the agent runner's `claude` was a coreutils `true` stub, so the step's
`claude -p` printed nothing, exited 0 in under a minute, and the lane read the dead run as
"the worker changed nothing" — a silent engine taken for a verdict. A worker that really
has nothing to change still prints its verdict (claude -p and pi --print both print their
result), so the step pipes both engines through `tee` and fails on an empty capture. That
pipe is held honest by the step's own first line, `set -euo pipefail`: with pipefail the
pipeline takes the engine's non-zero status, so an engine that prints and then crashes
fails the step too, under the `-e` the script sets for itself. The step runs here as
written in agent.yml, under `bash -e`, the default shell Actions uses for a `run:` step
that sets no `shell:` key, with real git against a repo bundle and stub engines on PATH;
the silent stub is /bin/true, the same no-op the box had.

The Claude login (fleet-ops#11958, owner 2026-11-13): the claude arm reads its seat token
from the seats folder in fleet-runner's home, which the step reaches as $HOME (the runner
unit pins HOME=/var/lib/fleet-runner, rootfs/etc/systemd/system/fleet-runner@.service),
alternates the seats by run id parity, masks each value with ::add-mask:: before any
engine runs, and passes it to `claude -p` for that one command only, so the pi arm never
sees it; a first seat that exits non-zero with no commit hands the run to the other seat
once. Here the seats folder is a stub home with two stub token files, so no real seat
value is ever read.
https://code.claude.com/docs/en/cli-reference
https://code.claude.com/docs/en/authentication
https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands#masking-a-value-in-a-log
https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idstepsshell
"""
import os
import shutil
import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
WF = yaml.safe_load((ROOT / ".github/workflows/agent.yml").read_text())


def worker_step():
    return next(s for s in WF["jobs"]["work"]["steps"] if s.get("name") == "Worker")["run"]


def git(*args, cwd=None):
    return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *args],
                          cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


SEAT_A = "stub-seat-a-token"
SEAT_B = "stub-seat-b-token"


@pytest.fixture
def work(tmp_path):
    src = tmp_path / "src"
    git("init", "-q", "-b", "agent/issue-7", str(src))
    (src / "file").write_text("base\n")
    git("add", "file", cwd=src)
    git("commit", "-qm", "base", cwd=src)
    git("bundle", "create", str(tmp_path / "repo.bundle"), "agent/issue-7", cwd=src)
    (tmp_path / "bin").mkdir()
    (tmp_path / "github_env").touch()
    # The seats folder as the play installs it into fleet-runner's home
    # (ansible/tasks/runners.yml), with stub token files of the same shape:
    # one CLAUDE_CODE_OAUTH_TOKEN=<value> line per seat, never a real value.
    seats = tmp_path / "home" / ".config" / "fleet-ops" / "seats"
    seats.mkdir(parents=True)
    (seats / "claude-seat-a.env").write_text(f"CLAUDE_CODE_OAUTH_TOKEN={SEAT_A}\n")
    (seats / "claude-seat-b.env").write_text(f"CLAUDE_CODE_OAUTH_TOKEN={SEAT_B}\n")
    return tmp_path


# Records the CLAUDE_CODE_OAUTH_TOKEN it was started with, one line per invocation.
RECORDING_STUB = """#!/bin/sh
cat > /dev/null
printf '%s\\n' "${CLAUDE_CODE_OAUTH_TOKEN-}" >> "$STUB_LOG"
printf 'changed the gate\\n'
"""

# The same, but the first invocation dies after printing, like a seat at its limit.
FAILS_FIRST_STUB = """#!/bin/sh
cat > /dev/null
printf '%s\\n' "${CLAUDE_CODE_OAUTH_TOKEN-}" >> "$STUB_LOG"
[ "$(wc -l < "$STUB_LOG")" -gt 1 ] || { printf 'seat limit\\n'; exit 1; }
printf 'changed the gate\\n'
"""


def run_worker(work, engine, verdict=None, stub_text=None, run_id="41846745347"):
    for name in ("claude", "pi"):
        stub = work / "bin" / name
        if stub_text is not None:
            stub.write_text(stub_text)
        elif verdict is None:
            shutil.copy("/bin/true", stub)  # the no-op the agent runner answered with
        else:
            stub.write_text(f"#!/bin/sh\ncat > /dev/null\n{verdict}\n")
        stub.chmod(0o755)
    stub_log = work / "stub.log"
    stub_log.unlink(missing_ok=True)
    env = {**os.environ, "PATH": f"{work / 'bin'}:{os.environ['PATH']}",
           "RUNNER_TEMP": str(work), "GITHUB_ENV": str(work / "github_env"),
           "REPO": "o/r", "ISSUE": "7", "ISSUE_TEXT": "the task", "ENGINE": engine,
           # HOME is fleet-runner's home on the box (fleet-runner@.service pins it);
           # here it is the stub home the work fixture fills with the seat files.
           "HOME": str(work / "home"), "GITHUB_RUN_ID": run_id, "STUB_LOG": str(stub_log)}
    # Actions runs a `run:` step that sets no `shell:` key as `bash -e {0}`; match it:
    # https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idstepsshell
    return subprocess.run(["bash", "-e", "-c", worker_step()], env=env, capture_output=True, text=True, check=False)


@pytest.mark.parametrize("engine", ["claude", "pi"])
def test_an_engine_that_prints_nothing_fails_the_step(work, engine):
    proc = run_worker(work, engine)
    assert proc.returncode != 0
    assert f"::error::the {engine} engine printed nothing" in proc.stdout


@pytest.mark.parametrize("engine", ["claude", "pi"])
def test_an_engine_that_prints_a_verdict_passes_the_step(work, engine):
    proc = run_worker(work, engine, "printf 'changed the gate\\n'")
    assert proc.returncode == 0, proc.stderr
    assert "changed the gate" in proc.stdout


@pytest.mark.parametrize("engine", ["claude", "pi"])
def test_an_engine_that_prints_then_exits_nonzero_fails_the_step(work, engine):
    proc = run_worker(work, engine, "printf 'partial verdict\\n'\nexit 1")
    assert proc.returncode != 0
    assert "partial verdict" in proc.stdout  # tee still passed the output through
    assert "::error::" not in proc.stdout  # it died on the engine's status, not the empty check


def test_the_claude_engine_pulls_one_seat_and_the_pi_arm_never_sees_a_token(work):
    """One seat per run (fleet-ops#11958): the claude arm reads the seat the run id
    parity picks, masks its value before the engine runs, and keeps it to that one
    command; the pi arm reads no seat and prints no mask. A first seat that exits
    non-zero with no commit hands the run to the other seat once, masked too."""
    pi = run_worker(work, "pi", stub_text=RECORDING_STUB)
    assert pi.returncode == 0, pi.stderr
    assert (work / "stub.log").read_text() == "\n"  # the stub saw no CLAUDE_CODE_OAUTH_TOKEN at all
    assert "::add-mask::" not in pi.stdout  # the pi arm masks nothing and reads no seat

    even = run_worker(work, "claude", stub_text=RECORDING_STUB, run_id="41846745348")
    assert even.returncode == 0, even.stderr
    assert (work / "stub.log").read_text() == f"{SEAT_A}\n"  # even run id starts on seat A
    assert even.stdout.count("::add-mask::") == 1 and f"::add-mask::{SEAT_A}" in even.stdout
    assert even.stdout.count(SEAT_A) == 1  # the value shows only inside its mask line

    odd = run_worker(work, "claude", stub_text=RECORDING_STUB, run_id="41846745349")
    assert odd.returncode == 0, odd.stderr
    assert (work / "stub.log").read_text() == f"{SEAT_B}\n"  # odd run id starts on seat B
    assert odd.stdout.count("::add-mask::") == 1 and f"::add-mask::{SEAT_B}" in odd.stdout
    assert odd.stdout.count(SEAT_B) == 1

    retry = run_worker(work, "claude", stub_text=FAILS_FIRST_STUB, run_id="41846745348")
    assert retry.returncode == 0, retry.stderr
    assert (work / "stub.log").read_text() == f"{SEAT_A}\n{SEAT_B}\n"  # one hand-over, to the other seat
    assert retry.stdout.count("::add-mask::") == 2  # both seat values were masked
    assert "changed the gate" in retry.stdout  # the run finished on seat B
