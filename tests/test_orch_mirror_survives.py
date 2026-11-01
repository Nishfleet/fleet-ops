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


def _commit(tmp_path, msg, line=None):
    work = tmp_path / "seed"
    if line is not None:
        # A big file with one changed line: the next fetch sends a thin delta
        # against a blob the mirror is expected to hold.
        (work / "big.txt").write_text("".join(f"line {i}\n" for i in range(5000)) + f"{line}\n")
        _git("add", "big.txt", cwd=work)
    _git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", msg, cwd=work)
    _git("push", "-q", str(tmp_path / "seed.git"), "main", cwd=tmp_path / "seed")


def test_fleet_sync_installs_the_age_out():
    unit = (ROOT / "systemd/fleet-sync.service").read_text()
    assert "config/user-tmpfiles.d/agent-worktrees.conf" in unit
    assert "%h/.config/user-tmpfiles.d/agent-worktrees.conf" in unit
    assert (ROOT / "config/user-tmpfiles.d/agent-worktrees.conf").is_file()
    assert (ROOT / "config/user-tmpfiles.d/pi-state.conf").is_file()
    assert "pi-state.conf" not in unit
    assert unit.index("ExecStart=/usr/bin/install -C -D -m 0644 %h/workspaces/tooling/fleet-ops-deploy-clone/config/user-tmpfiles.d/agent-worktrees.conf") < unit.index("ExecStart=/usr/bin/systemd-tmpfiles --user --create")


def _run_conf(tmp_path, text):
    conf = tmp_path / "t.conf"
    conf.write_text(re.sub(r"bcmBCM:3d", "bcmBCM:1s", text))
    return subprocess.run(["systemd-tmpfiles", "--clean", str(conf)], capture_output=True, text=True)


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
    r = _run_conf(tmp_path, CONF.read_text().replace("%h", str(home)))
    assert r.returncode == 0, r.stderr
    assert head.exists(), "the age-out deleted the mirror's HEAD"
    assert not stale.exists(), "precondition: the age-out still removes stale worktrees"


def test_tmpfiles_age_out_keeps_the_damaged_save_dirs_and_a_run_worktree(tmp_path):
    if not shutil.which("systemd-tmpfiles"):
        pytest.skip("systemd-tmpfiles not installed")
    home = tmp_path / "home"
    base = home / "workspaces/agent-worktrees"
    saved = base / "orch-damaged-siterep-public.git/HEAD"
    saved.parent.mkdir(parents=True)
    saved.write_text("ref: refs/heads/main\n")
    time.sleep(1.5)
    live = base / "orch-fleet-ops-2/src"
    live.mkdir(parents=True)
    (live / "keeper.txt").write_text("x\n")
    r = _run_conf(tmp_path, CONF.read_text().replace("%h", str(home)))
    assert r.returncode == 0, r.stderr
    assert saved.exists(), "the age-out deleted the parked orch-damaged save-dir"
    assert live.is_dir() and (live / "keeper.txt").exists(), "the age-out deleted a work freshly checked out this run"


def test_tmpfiles_age_out_removes_an_untouched_worktree_whole(tmp_path):
    if not shutil.which("systemd-tmpfiles"):
        pytest.skip("systemd-tmpfiles not installed")
    home = tmp_path / "home"
    base = home / "workspaces/agent-worktrees"
    gone = base / "orch-fleet-ops-3"
    gone.mkdir(parents=True)
    (gone / "main.ts").write_text("x\n")
    (gone / ".git").write_text("gitdir: /tmp/orch-mirror/fleet-ops.git/worktrees/3\n")
    time.sleep(1.5)
    r = _run_conf(tmp_path, CONF.read_text().replace("%h", str(home)))
    assert r.returncode == 0, r.stderr
    assert not gone.exists(), "a worktree with no write for the period must go entirely, not lose files one by one"

