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

The Claude engine's login is a Team seat token (fleet-ops#11958): the step masks it before
use, hands it to `claude -p` alone, and a dead seat hands the run to the other seat once.
HOME points at a fake fleet-claude home holding both seat files, one name per file, each
its own CLAUDE_CODE_OAUTH_TOKEN line.
https://code.claude.com/docs/en/cli-reference
https://code.claude.com/docs/en/authentication#generate-a-long-lived-token
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
SEAT_A = "oat-seat-a-01890"
SEAT_B = "oat-seat-b-77210"


def worker_step():
    return next(s for s in WF["jobs"]["work"]["steps"] if s.get("name") == "Worker")["run"]


def git(*args, cwd=None):
    return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *args],
                          cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


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
    # fleet-claude's home (ansible/tasks/runners.yml), pointed at by HOME: the two seat
    # files live only there, one name each, each its own CLAUDE_CODE_OAUTH_TOKEN line.
    seats = tmp_path / "home" / ".config" / "fleet-ops" / "seats"
    seats.mkdir(parents=True)
    (seats / "claude-seat-a.env").write_text(f"CLAUDE_CODE_OAUTH_TOKEN={SEAT_A}\n")
    (seats / "claude-seat-b.env").write_text(f"CLAUDE_CODE_OAUTH_TOKEN={SEAT_B}\n")
    return tmp_path


def run_worker(work, engine, verdict=None, run_id=1000, stubs=None):
    for name in ("claude", "pi"):
        stub = work / "bin" / name
        if stubs and name in stubs:
            stub.write_text(f"#!/bin/sh\n{stubs[name]}\n")
        elif verdict is None:
            shutil.copy("/bin/true", stub)  # the no-op the agent runner answered with
        else:
            stub.write_text(f"#!/bin/sh\ncat > /dev/null\n{verdict}\n")
        stub.chmod(0o755)
    env = {**os.environ, "PATH": f"{work / 'bin'}:{os.environ['PATH']}",
           "RUNNER_TEMP": str(work), "GITHUB_ENV": str(work / "github_env"),
           "REPO": "o/r", "ISSUE": "7", "ISSUE_TEXT": "the task", "ENGINE": engine,
           # The work job's job-level env (agent.yml): the base the clone starts from, so
           # the claude arm can tell a commit the worker made from an untouched tree.
           "BASE": git("rev-parse", "agent/issue-7", cwd=work / "src"),
           # The claude arm reads its seat from fleet-claude's own home and picks the seat
           # by run id parity.
           "HOME": str(work / "home"), "GITHUB_RUN_ID": str(run_id)}
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


def test_the_claude_stub_sees_the_seat_token_and_the_pi_stub_does_not(work):
    seen = "cat > /dev/null\nprintf '%s\\n' \"${CLAUDE_CODE_OAUTH_TOKEN-}\" > \"$RUNNER_TEMP/seen\"\necho verdict"
    proc = run_worker(work, "claude", stubs={"claude": seen})
    assert proc.returncode == 0, proc.stderr
    assert (work / "seen").read_text().splitlines() == [SEAT_A]  # even run id starts on seat A
    proc = run_worker(work, "pi", stubs={"pi": seen})
    assert proc.returncode == 0, proc.stderr
    assert (work / "seen").read_text().splitlines() == [""]  # pi never gets CLAUDE_CODE_OAUTH_TOKEN


def test_the_token_reaches_the_step_output_only_inside_a_mask_line(work):
    proc = run_worker(work, "claude", "printf 'changed the gate\\n'")
    assert proc.returncode == 0, proc.stderr
    lines = proc.stdout.splitlines()
    mask_lines = [l for l in lines if SEAT_A in l]
    assert mask_lines and all("::add-mask::" in l for l in mask_lines)  # only exposure is the mask line
    assert sum(l.count(SEAT_A) for l in lines) == 1  # exactly once in the step's output
    assert SEAT_A not in proc.stderr
    assert SEAT_A not in (work / "github_env").read_text()  # never exported into a later step


def test_even_run_id_takes_seat_a_and_odd_takes_seat_b(work):
    used = "cat > /dev/null\nprintf '%s\\n' \"${CLAUDE_CODE_OAUTH_TOKEN-}\" >> \"$RUNNER_TEMP/seats-used\"\necho verdict"
    assert run_worker(work, "claude", stubs={"claude": used}, run_id=1000).returncode == 0
    assert (work / "seats-used").read_text().splitlines() == [SEAT_A]
    assert run_worker(work, "claude", stubs={"claude": used}, run_id=1001).returncode == 0
    assert (work / "seats-used").read_text().splitlines() == [SEAT_A, SEAT_B]  # no retry on the even run


def test_a_seat_that_exits_nonzero_with_no_commit_hands_the_run_to_the_other(work):
    handoff = ("cat > /dev/null\n"
               "printf '%s\\n' \"${CLAUDE_CODE_OAUTH_TOKEN-}\" >> \"$RUNNER_TEMP/seats-used\"\n"
               "if [ -f \"$RUNNER_TEMP/retry\" ]; then echo 'recovered verdict'; exit 0; fi\n"
               "touch \"$RUNNER_TEMP/retry\"\necho dying\nexit 1")
    proc = run_worker(work, "claude", stubs={"claude": handoff})
    assert proc.returncode == 0, proc.stderr
    assert "recovered verdict" in proc.stdout  # the run finished on the other seat
    assert (work / "seats-used").read_text().splitlines() == [SEAT_A, SEAT_B]  # moved once, then stopped


def test_a_seat_that_fails_after_a_commit_ends_the_run(work):
    committed = ("cat > /dev/null\n"
                 "printf '%s\\n' \"${CLAUDE_CODE_OAUTH_TOKEN-}\" >> \"$RUNNER_TEMP/seats-used\"\n"
                 "git -c user.name=w -c user.email=w@w commit -q --allow-empty -m w\n"
                 "echo dying\nexit 1")
    proc = run_worker(work, "claude", stubs={"claude": committed})
    assert proc.returncode != 0
    assert (work / "seats-used").read_text().splitlines() == [SEAT_A]  # the worker keeps its commit, no hand-off
    assert "the other seat" not in proc.stdout
