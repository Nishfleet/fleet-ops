"""fleet-ops#9377: the hand-off cleanup step must keep a worktree that a running
unit uses as its WorkingDirectory.

On 2026-10-07 the step removed orch-drive-642 under the detached
orch-drive-642-build unit (status=200/CHDIR, uncommitted edits lost). This test
runs the real `run:` block of the step from agent-dispatch.yml against a real
git mirror and worktree. Only `systemctl` is a stub on PATH, because CI has no
user systemd; the drill on the VPS uses a real transient unit.
"""
import os
import pathlib
import subprocess

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
STEP = "Clean up and mark a PR-less hand-off"


def _run_block():
    wf = yaml.safe_load((ROOT / ".github/workflows/agent-dispatch.yml").read_text())
    for job in wf["jobs"].values():
        for step in job.get("steps", []):
            if step.get("name") == STEP:
                return step["run"]
    raise AssertionError(f"step {STEP!r} not found")


def _git(*args, cwd):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


def _setup(tmp_path, unit_wd, **extra):
    home = tmp_path / "home"
    base = home / "workspaces/agent-worktrees"
    mirror = base / ".orch-mirror/fleet-ops.git"
    wt = base / "orch-fleet-ops-9377"
    seed = tmp_path / "seed"
    seed.mkdir()
    _git("init", "-q", "-b", "main", cwd=seed)
    _git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "i", cwd=seed)
    mirror.parent.mkdir(parents=True)
    _git("clone", "-q", "--bare", str(seed), str(mirror), cwd=tmp_path)
    _git("worktree", "add", "-q", "-b", "orch/issue-9377", str(wt), "main", cwd=mirror)
    (wt / "uncommitted.txt").write_text("work in progress\n")
    stub_dir = tmp_path / "bin"
    stub_dir.mkdir()
    stub = stub_dir / "systemctl"
    stub.write_text(
        "#!/bin/sh\n"
        'case "$*" in\n'
        '  *list-units*) [ -z "$LIST_FAILS" ] || exit 1; [ -n "$UNIT_WD" ] && echo "orch-fleet-ops-9377-build.service loaded active running x"; exit 0 ;;\n'
        '  *"show -p WorkingDirectory"*) [ -z "$SHOW_FAILS" ] || exit 1; echo "$UNIT_WD" ;;\n'
        "esac\n"
    )
    stub.chmod(0o755)
    env = {
        **os.environ,
        "HOME": str(home),
        "PATH": f"{stub_dir}:{os.environ['PATH']}",
        "REPO": "Nishfleet/fleet-ops",
        "ISSUE": "9377",
        "GO": "false",
        "UNIT_WD": str(unit_wd(wt)) if unit_wd else "",
        **extra,
    }
    return wt, env


def _cleanup(env):
    return subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", _run_block()], env=env, capture_output=True, text=True)


def test_running_unit_keeps_worktree_and_uncommitted_file(tmp_path):
    wt, env = _setup(tmp_path, lambda w: w)
    r = _cleanup(env)
    assert r.returncode == 0, r.stderr
    assert (wt / "uncommitted.txt").read_text() == "work in progress\n"


def test_idle_worktree_is_removed(tmp_path):
    wt, env = _setup(tmp_path, None)
    r = _cleanup(env)
    assert r.returncode == 0, r.stderr
    assert not wt.exists()


def test_unit_in_another_directory_does_not_keep_worktree(tmp_path):
    wt, env = _setup(tmp_path, lambda w: w.parent / "orch-other-1")
    r = _cleanup(env)
    assert r.returncode == 0, r.stderr
    assert not wt.exists()


def test_failed_unit_listing_keeps_worktree(tmp_path):
    wt, env = _setup(tmp_path, None, LIST_FAILS="1")
    r = _cleanup(env)
    assert r.returncode == 0, r.stderr
    assert (wt / "uncommitted.txt").exists()


def test_failed_property_lookup_keeps_worktree(tmp_path):
    wt, env = _setup(tmp_path, lambda w: w.parent / "orch-other-1", SHOW_FAILS="1")
    r = _cleanup(env)
    assert r.returncode == 0, r.stderr
    assert (wt / "uncommitted.txt").exists()
