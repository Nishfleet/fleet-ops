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
CONF = ROOT / "config/user-tmpfiles.d/agent-worktrees.conf"


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

