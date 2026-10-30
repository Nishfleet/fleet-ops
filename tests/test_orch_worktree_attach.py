"""fleet-ops#9376: the hand-off worktree step must leave the worktree attached
to the issue branch, and must not resume a stale branch tip.

On 2026-10-28 the #9376 hand-off resumed a branch that only the mirror held,
because origin's had gone. `worktree add <path> refs/heads/…` detaches, so the
session's commit landed on detached HEAD; the branch push then sent the stale
tip; `gh pr create` said "No commits between main and orch/issue-9376"; and the
force push answered "Everything up-to-date" against that same stale tip. This
test runs the real `run:` block of the "Fresh worktree on origin/main" step
from agent-dispatch.yml against a local bare remote as origin. Only
`systemctl` is a stub on PATH, because CI has no user systemd.
"""
import os
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
STEP = "Fresh worktree on origin/main"
ISSUE = "9376"


def _run_block():
    out = subprocess.run(
        ["yq", f'.jobs.orchestrate.steps[] | select(.name == "{STEP}") | .run',
         str(ROOT / ".github/workflows/agent-dispatch.yml")],
        check=True, capture_output=True, text=True,
    ).stdout
    assert out.strip(), f"step {STEP!r} not found"
    return out


def _git(*args, cwd):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True)


def _rev(repo, ref):
    return subprocess.run(
        ["git", "-C", str(repo), "rev-parse", ref], check=True, capture_output=True, text=True
    ).stdout.strip()


def _commit_detached(mirror, sha, msg):
    wt = mirror.parent / "tmp-commit-wt"
    _git("worktree", "add", "-q", "-d", str(wt), sha, cwd=mirror)
    _git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", msg, cwd=wt)
    tip = _rev(wt, "HEAD")
    _git("worktree", "remove", "--force", str(wt), cwd=mirror)
    return tip


def _setup(tmp_path, *, mirror_branch="stale", remote_branch=False):
    home = tmp_path / "home"
    runtime = tmp_path / "runtime"
    runtime.mkdir()
    base = home / "workspaces/agent-worktrees"
    mirror = base / ".orch-mirror/fleet-ops.git"
    wt = base / f"orch-fleet-ops-{ISSUE}"
    seed = tmp_path / "seed"
    seed.mkdir()
    _git("init", "-q", "-b", "main", cwd=seed)
    _git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "a", cwd=seed)
    old_main = _rev(seed, "main")
    mirror.parent.mkdir(parents=True)
    _git("clone", "-q", "--bare", str(seed), str(mirror), cwd=tmp_path)
    if remote_branch:
        _git("push", "-q", "origin", f"{old_main}:refs/heads/orch/issue-{ISSUE}", cwd=mirror)
        pushed = old_main
    else:
        pushed = None
    work = None
    if mirror_branch == "work":
        work = _commit_detached(mirror, old_main, "session commit")
        _git("branch", "-f", f"orch/issue-{ISSUE}", work, cwd=mirror)
    elif mirror_branch == "stale":
        _git("branch", "-f", f"orch/issue-{ISSUE}", old_main, cwd=mirror)
    _git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "b", cwd=seed)
    new_main = _rev(seed, "main")

    stub_dir = tmp_path / "bin"
    stub_dir.mkdir()
    stub = stub_dir / "systemctl"
    stub.write_text("#!/bin/sh\ncase \"$*\" in *list-units*) : ;; esac\nexit 0\n")
    stub.chmod(0o755)
    output = tmp_path / "github-output"
    output.write_text("")
    env = {
        **os.environ,
        "HOME": str(home),
        "XDG_RUNTIME_DIR": str(runtime),
        "PATH": f"{stub_dir}:{os.environ['PATH']}",
        "REPO": "Nishfleet/fleet-ops",
        "ISSUE": ISSUE,
        "GITHUB_OUTPUT": str(output),
    }
    return wt, env, old_main, new_main, mirror, pushed


def _worktree_step(env):
    return subprocess.run(
        ["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", _run_block()],
        env=env, capture_output=True, text=True,
    )


def test_stale_branch_without_remote_branch_is_attached_to_branch_and_pinned_to_main(tmp_path):
    wt, env, old_main, new_main, mirror, pushed = _setup(tmp_path)
    r = _worktree_step(env)
    assert r.returncode == 0, r.stderr
    assert _rev(wt, "HEAD") == new_main
    attached = subprocess.run(
        ["git", "-C", str(wt), "symbolic-ref", "HEAD"], capture_output=True, text=True
    )
    assert attached.stdout.strip() == f"refs/heads/orch/issue-{ISSUE}", attached.stderr
    assert _rev(mirror, f"refs/heads/orch/issue-{ISSUE}") == new_main


def test_unpushed_commits_on_mirror_branch_keep_the_tip_attached(tmp_path):
    wt, env, old_main, new_main, mirror, pushed = _setup(tmp_path, mirror_branch="work")
    r = _worktree_step(env)
    assert r.returncode == 0, r.stderr
    assert "branch holds unpushed commits" in r.stdout
    assert _rev(wt, "HEAD") == _rev(mirror, f"refs/heads/orch/issue-{ISSUE}")
    attached = subprocess.run(
        ["git", "-C", str(wt), "symbolic-ref", "HEAD"], capture_output=True, text=True
    )
    assert attached.stdout.strip() == f"refs/heads/orch/issue-{ISSUE}", attached.stderr


def test_remote_branch_start_is_kept(tmp_path):
    wt, env, old_main, new_main, mirror, remote_tip = _setup(tmp_path, remote_branch=True)
    r = _worktree_step(env)
    assert r.returncode == 0, r.stderr
    assert "branch holds unpushed commits" not in r.stdout
    assert _rev(wt, "HEAD") == remote_tip


def test_remote_branch_start_with_unpushed_commits_saves_them(tmp_path):
    wt, env, old_main, new_main, mirror, remote_tip = _setup(tmp_path, mirror_branch="work", remote_branch=True)
    work = _rev(mirror, f"refs/heads/orch/issue-{ISSUE}")
    r = _worktree_step(env)
    assert r.returncode == 0, r.stderr
    assert "unpushed commits, kept on" in r.stdout
    assert _rev(wt, "HEAD") == remote_tip
    assert _rev(mirror, f"refs/heads/orch/issue-{ISSUE}-unpushed") == work
