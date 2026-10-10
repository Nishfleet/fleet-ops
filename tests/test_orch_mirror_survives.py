"""fleet-ops#9526: the orchestrate hand-off died with "fatal: not a git
repository" on every run from 2026-10-09.

Cause: the bare mirror under agent-worktrees/.orch-mirror is reused by every
hand-off, its HEAD file is written once, and the 3-day systemd-tmpfiles rule on
agent-worktrees/ deleted that file. The step guarded on `[ ! -d "$mirror" ]`,
so it never rebuilt a directory that git no longer recognised.

Two fixes, two kinds of test. The tmpfiles `x` line keeps the mirror out of the
age-out (tested with the real systemd-tmpfiles and the real conf). The step now
repairs a mirror that lost HEAD (tested by running the real `run:` block).
"""
import os
import pathlib
import re
import shutil
import subprocess
import time

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
STEP = "Fresh worktree on origin/main"
CONF = ROOT / "config/user-tmpfiles.d/agent-worktrees.conf"


def _run_block():
    out = subprocess.run(
        ["yq", f'.jobs.orchestrate.steps[] | select(.name == "{STEP}") | .run', str(ROOT / ".github/workflows/agent-dispatch.yml")],
        check=True, capture_output=True, text=True,
    ).stdout
    assert out.strip(), f"step {STEP!r} not found"
    return out


def _git(*args, cwd):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


def _setup(tmp_path):
    home = tmp_path / "home"
    base = home / "workspaces/agent-worktrees"
    base.mkdir(parents=True)
    seed = tmp_path / "seed.git"
    work = tmp_path / "seed"
    work.mkdir()
    _git("init", "-q", "-b", "main", cwd=work)
    _git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "i", cwd=work)
    _git("clone", "-q", "--bare", str(work), str(seed), cwd=tmp_path)
    env = {
        **os.environ,
        "HOME": str(home),
        "REPO": "Nishfleet/fleet-ops",
        "ISSUE": "9526",
        "GITHUB_OUTPUT": str(tmp_path / "out"),
        # The step fetches https://github.com/<repo>.git; point that at the seed.
        "GIT_CONFIG_COUNT": "1",
        "GIT_CONFIG_KEY_0": f"url.{seed}.insteadOf",
        "GIT_CONFIG_VALUE_0": "https://github.com/Nishfleet/fleet-ops.git",
    }
    return base / ".orch-mirror/fleet-ops.git", base / "orch-fleet-ops-9526", env


def _step(env):
    return subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", _run_block()], env=env, capture_output=True, text=True)


def test_first_run_builds_the_mirror_and_worktree(tmp_path):
    mirror, wt, env = _setup(tmp_path)
    r = _step(env)
    assert r.returncode == 0, r.stderr
    branch = subprocess.run(["git", "-C", str(wt), "rev-parse", "--abbrev-ref", "HEAD"], capture_output=True, text=True).stdout.strip()
    assert branch == "orch/issue-9526"


def test_mirror_that_lost_head_is_repaired(tmp_path):
    mirror, wt, env = _setup(tmp_path)
    assert _step(env).returncode == 0
    # What the tmpfiles age-out did to the live mirrors: HEAD gone, rest intact.
    (mirror / "HEAD").unlink()
    shutil.rmtree(wt)
    r = subprocess.run(["git", "-C", str(mirror), "rev-parse", "--git-dir"], capture_output=True, text=True)
    assert r.returncode != 0, "precondition: a mirror without HEAD is not a repository"
    r = _step(env)
    assert r.returncode == 0, r.stderr
    assert (wt / ".git").exists()
    # The repair keeps the remote that was already configured.
    url = subprocess.run(["git", "-C", str(mirror), "remote", "get-url", "origin"], capture_output=True, text=True).stdout.strip()
    assert url == "https://github.com/Nishfleet/fleet-ops.git"


def _commit(tmp_path, msg, line=None):
    work = tmp_path / "seed"
    if line is not None:
        # A big file with one changed line: the next fetch sends a thin delta
        # against a blob the mirror is expected to hold.
        (work / "big.txt").write_text("".join(f"line {i}\n" for i in range(5000)) + f"{line}\n")
        _git("add", "big.txt", cwd=work)
    _git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", msg, cwd=work)
    _git("push", "-q", str(tmp_path / "seed.git"), "main", cwd=tmp_path / "seed")


def test_mirror_with_a_damaged_object_store_is_rebuilt(tmp_path):
    mirror, wt, env = _setup(tmp_path)
    _commit(tmp_path, "base", line="a")
    assert _step(env).returncode == 0
    # The age-out also removed old objects: commits and trees survive, a blob
    # does not, and the next fetch sends a delta against it.
    blob = subprocess.run(["git", "-C", str(tmp_path / "seed"), "rev-parse", "HEAD:big.txt"], check=True, capture_output=True, text=True).stdout.strip()
    (mirror / "objects" / blob[:2] / blob[2:]).unlink()
    _commit(tmp_path, "next", line="b")
    shutil.rmtree(wt)
    # A hand-off that died before its push leaves its commits on a local branch.
    _git("branch", "orch/issue-localonly", "refs/remotes/origin/main", cwd=mirror)
    r = _step(env)
    assert r.returncode == 0, r.stderr
    assert "setting it aside" in r.stdout + r.stderr
    # The damaged mirror is moved, not deleted, so the local-only branch can be salvaged.
    aside = list(mirror.parent.parent.glob("orch-damaged-fleet-ops-*.git"))
    assert len(aside) == 1
    branches = subprocess.run(["git", "--git-dir", str(aside[0]), "branch", "--list", "orch/issue-localonly"], capture_output=True, text=True).stdout
    assert "orch/issue-localonly" in branches
    assert (wt / ".git").exists()
    tip = subprocess.run(["git", "-C", str(wt), "log", "-1", "--format=%s"], capture_output=True, text=True).stdout.strip()
    assert tip == "next"


def test_failed_fetch_on_an_intact_mirror_is_not_rebuilt(tmp_path):
    mirror, wt, env = _setup(tmp_path)
    assert _step(env).returncode == 0
    shutil.rmtree(wt)
    keep = mirror / "keep-me"
    keep.write_text("x\n")
    # Same mirror, but origin is unreachable: a network or credential failure.
    env = {**env, "GIT_CONFIG_VALUE_0": "https://github.com/Nishfleet/fleet-ops.git", "GIT_CONFIG_KEY_0": "url./nonexistent/seed.git.insteadOf"}
    r = _step(env)
    assert r.returncode != 0
    assert keep.exists(), "an intact mirror must survive a failed fetch"


def test_tmpfiles_age_out_keeps_the_mirror(tmp_path):
    if not shutil.which("systemd-tmpfiles"):
        pytest.skip("systemd-tmpfiles not installed")
    home = tmp_path / "home"
    head = home / "workspaces/agent-worktrees/.orch-mirror/fleet-ops.git/HEAD"
    stale = home / "workspaces/agent-worktrees/orch-fleet-ops-1/file"
    head.parent.mkdir(parents=True)
    stale.parent.mkdir(parents=True)
    head.write_text("ref: refs/heads/main\n")
    stale.write_text("x\n")
    time.sleep(1.5)
    # The real conf, with the home expanded and the 3-day age shortened to 1s.
    conf = tmp_path / "t.conf"
    text = CONF.read_text().replace("%h", str(home))
    conf.write_text(re.sub(r"bcmBCM:3d", "bcmBCM:1s", text))
    r = subprocess.run(["systemd-tmpfiles", "--clean", str(conf)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert head.exists(), "the age-out deleted the mirror's HEAD"
    assert not stale.exists(), "precondition: the age-out still removes stale worktrees"
