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
https://code.claude.com/docs/en/cli-reference
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


@pytest.fixture
def work(tmp_path):
    src = tmp_path / "src"
    git("init", "-q", "-b", "agent/issue-7", str(src))
    (src / "file").write_text("base\n")
    git("add", "file", cwd=src)
    git("commit", "-qm", "base", cwd=src)
    # the bundle as the claim job now builds it: the default branch rides along
    git("update-ref", "refs/remotes/origin/main", "HEAD", cwd=src)
    git("bundle", "create", str(tmp_path / "repo.bundle"), "agent/issue-7", "refs/remotes/origin/main", cwd=src)
    (tmp_path / "bin").mkdir()
    (tmp_path / "github_env").touch()
    return tmp_path


def run_worker(work, engine, verdict=None):
    for name in ("claude", "pi"):
        stub = work / "bin" / name
        if verdict is None:
            shutil.copy("/bin/true", stub)  # the no-op the agent runner answered with
        else:
            stub.write_text(f"#!/bin/sh\ncat > /dev/null\n{verdict}\n")
        stub.chmod(0o755)
    env = {**os.environ, "PATH": f"{work / 'bin'}:{os.environ['PATH']}",
           "RUNNER_TEMP": str(work), "GITHUB_ENV": str(work / "github_env"),
           "REPO": "o/r", "ISSUE": "7", "ISSUE_TEXT": "the task", "ENGINE": engine,
           "DEFAULT_BRANCH": "main"}
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
