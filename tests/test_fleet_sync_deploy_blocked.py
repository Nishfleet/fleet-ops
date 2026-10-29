"""fleet-sync names the cause when the deploy clone is not at origin/main (fleet-ops#9967)."""

import os
import shlex
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UNIT = ROOT / "systemd" / "fleet-sync.service"
CLONE = "workspaces/tooling/fleet-ops-deploy-clone"
GIT_ENV = {
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_SYSTEM": os.devnull,
    "GIT_AUTHOR_NAME": "fleet",
    "GIT_AUTHOR_EMAIL": "fleet@example.invalid",
    "GIT_COMMITTER_NAME": "fleet",
    "GIT_COMMITTER_EMAIL": "fleet@example.invalid",
}


def expand(raw: str, home: Path) -> str:
    return (
        raw.replace("%%", "\x00")
        .replace("$$", "\x01")
        .replace("%h", str(home))
        .replace("\x00", "%")
        .replace("\x01", "$")
    )


def probe(home: Path) -> list[str]:
    return exec_line("DEPLOY-BLOCKED: the deploy clone is not at origin/main", home)


def exec_line(marker: str, home: Path) -> list[str]:
    for raw in UNIT.read_text().splitlines():
        if not raw.startswith("ExecStart="):
            continue
        expanded = expand(raw[len("ExecStart=") :], home)
        if marker in expanded:
            return shlex.split(expanded)
    raise AssertionError(f"no {marker!r} line found in systemd/fleet-sync.service")


def git(cwd: Path, *args: str) -> str:
    env = {**os.environ, **GIT_ENV}
    proc = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True, env=env)
    return proc.stdout.strip()


def clone_at(tmp_path: Path) -> Path:
    clone = tmp_path / CLONE
    clone.mkdir(parents=True)
    git(clone, "init", "-b", "main")
    (clone / "README.md").write_text("main\n")
    git(clone, "add", "README.md")
    git(clone, "commit", "-m", "the only commit on main")
    git(clone, "update-ref", "refs/remotes/origin/main", "HEAD")
    return clone


def run(home: Path) -> tuple[int, str]:
    proc = subprocess.run(probe(home), capture_output=True, text=True, check=False)
    return proc.returncode, proc.stdout + proc.stderr


def test_a_clone_exactly_at_origin_main_passes_silently(tmp_path: Path) -> None:
    clone_at(tmp_path)
    assert run(tmp_path) == (0, "")


def test_a_work_branch_checked_out_in_the_clone_fails_and_names_it(tmp_path: Path) -> None:
    clone = clone_at(tmp_path)
    git(clone, "switch", "-c", "mac-topgrade-config")
    (clone / "topgrade.toml").write_text("[misc]\n")
    git(clone, "add", "topgrade.toml")
    git(clone, "commit", "-m", "Add the Mac topgrade config")
    code, text = run(tmp_path)
    assert code != 0
    assert "DEPLOY-BLOCKED" in text
    assert "branch mac-topgrade-config" in text
    head = git(clone, "rev-parse", "--short", "HEAD")
    assert f"not-on-main: {head} Add the Mac topgrade config" in text
    assert "switch main" in text


def test_a_missing_clone_names_itself_instead_of_exiting_silently(tmp_path: Path) -> None:
    code, text = run(tmp_path)
    assert code != 0
    assert "no deploy clone at" in text
    assert CLONE in text


def test_a_clone_behind_origin_main_fails_without_extra_commits_named(tmp_path: Path) -> None:
    clone = clone_at(tmp_path)
    (clone / "later.txt").write_text("later\n")
    git(clone, "add", "later.txt")
    git(clone, "commit", "-m", "a commit the clone has not taken yet")
    git(clone, "update-ref", "refs/remotes/origin/main", "HEAD")
    git(clone, "reset", "--hard", "HEAD~1")
    code, text = run(tmp_path)
    assert code != 0
    assert "DEPLOY-BLOCKED" in text
    assert "not-on-main:" not in text


HOOK = ROOT / "config" / "git-hooks" / "reference-transaction"
BRANCH_PROBE = "DEPLOY-BLOCKED: the deploy clone has"


def install_hook(clone: Path) -> None:
    hooks = clone / ".git" / "hooks"
    hooks.mkdir(exist_ok=True)
    shutil.copy2(HOOK, hooks / "reference-transaction")


def clone_with_hook(tmp_path: Path) -> Path:
    clone = clone_at(tmp_path)
    install_hook(clone)
    return clone


def run_git(cwd: Path, *args: str) -> tuple[int, str]:
    proc = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=False, env={**os.environ, **GIT_ENV})
    return proc.returncode, proc.stdout + proc.stderr


def test_the_hook_is_executable_and_shipped_as_a_config_file() -> None:
    assert HOOK.is_file()
    assert os.access(HOOK, os.X_OK), "git ignores a hook it cannot execute"
    assert HOOK.read_text().startswith("#!/bin/sh")


def test_the_hook_rejects_every_ref_update_that_puts_a_branch_in_the_clone(tmp_path: Path) -> None:
    clone = clone_with_hook(tmp_path)
    for args in (
        ("update-ref", "refs/heads/pr-9426", "refs/heads/main"),
        ("checkout", "-b", "zz"),
        ("switch", "--detach", "refs/remotes/origin/main"),
    ):
        code, text = run_git(clone, *args)
        assert code != 0, args
        assert "DEPLOY-BLOCKED" in text, (args, text)
    assert git(clone, "symbolic-ref", "HEAD") == "refs/heads/main"
    assert git(clone, "rev-parse", "--abbrev-ref", "HEAD") == "main"


def test_the_hook_names_the_fix_a_session_needs(tmp_path: Path) -> None:
    clone = clone_with_hook(tmp_path)
    code, text = run_git(clone, "worktree", "add", "-b", "x", str(tmp_path / "x"), "refs/remotes/origin/main")
    assert code != 0
    assert "DEPLOY-BLOCKED" in text
    assert "git worktree add ~/workspaces/agent-worktrees/<name> <ref>" in text


def test_the_hook_blocks_a_fetch_that_creates_a_branch(tmp_path: Path) -> None:
    # The 2026-10-08 shape (fleet-ops#9437): the session fetched the PR head into
    # a local branch, then checked it out here. git 2.43 runs this hook for a
    # fetch from a local path (the test's remote) and not for a fetch over https,
    # which is why fleet-sync.service step 0a is the layer that catches that one.
    remote = tmp_path / "remote"
    remote.mkdir()
    git(remote, "init", "--bare", "-b", "main")
    upstream = tmp_path / "upstream"
    upstream.mkdir()
    git(upstream, "init", "-b", "main")
    (upstream / "pr.txt").write_text("pr\n")
    git(upstream, "add", "pr.txt")
    git(upstream, "commit", "-m", "an unmerged change")
    git(upstream, "push", str(remote), "HEAD:refs/heads/pr-9426")
    clone = clone_with_hook(tmp_path)
    code, text = run_git(clone, "fetch", str(remote), "refs/heads/pr-9426:refs/heads/pr-9426")
    assert code != 0
    assert "DEPLOY-BLOCKED" in text
    assert not (clone / ".git" / "refs" / "heads" / "pr-9426").exists()


def test_the_hook_allows_the_deploy_steps(tmp_path: Path) -> None:
    clone = clone_with_hook(tmp_path)
    assert run_git(clone, "update-ref", "refs/remotes/origin/main", "HEAD")[0] == 0
    code, text = run_git(clone, "merge", "--ff-only", "refs/remotes/origin/main")
    assert code == 0, text
    code, text = run_git(clone, "checkout", "main")
    assert code == 0, text
    assert git(clone, "symbolic-ref", "HEAD") == "refs/heads/main"


def test_the_hook_allows_a_real_deploy_fast_forward(tmp_path: Path) -> None:
    # The deploy step is a fast-forward of main, and git sends it as two lines:
    # refs/heads/main and a reflog-only HEAD line with the same new commit. A
    # guard that refuses the second one stops every deploy (fleet-ops#9437).
    clone = clone_with_hook(tmp_path)
    (clone / "later.txt").write_text("later\n")
    git(clone, "add", "later.txt")
    git(clone, "commit", "-m", "a commit main has not taken yet")
    ahead = git(clone, "rev-parse", "HEAD")
    git(clone, "update-ref", "refs/remotes/origin/main", ahead)
    git(clone, "reset", "--hard", "HEAD~1")
    code, text = run_git(clone, "merge", "--ff-only", "refs/remotes/origin/main")
    assert code == 0, text
    assert "Fast-forward" in text
    assert git(clone, "rev-parse", "HEAD") == ahead


def test_the_hook_allows_removing_a_stray_branch(tmp_path: Path) -> None:
    # A stray branch is the 2026-10-08 leftover, and deleting one cannot put the
    # clone on it, so the guard must not need a bypass to clean it up.
    clone = clone_at(tmp_path)
    git(clone, "branch", "pr-9426")
    install_hook(clone)
    code, text = run_git(clone, "branch", "-D", "pr-9426")
    assert code == 0, text
    assert git(clone, "branch", "--list", "pr-9426") == ""


def test_the_hook_leaves_a_linked_worktree_alone(tmp_path: Path) -> None:
    # The worktree is made before the hook is installed: `git worktree add` runs
    # its HEAD transaction from the main worktree, and whether the hook can tell
    # that HEAD is the new worktree's is a git version detail. What the guard
    # promises is that a ref update made in a linked worktree is skipped, so the
    # test moves that worktree's HEAD, which the clone's own guard refuses.
    clone = clone_at(tmp_path)
    (clone / "later.txt").write_text("later\n")
    git(clone, "add", "later.txt")
    git(clone, "commit", "-m", "a second commit on main")
    worktree = tmp_path / "side"
    git(clone, "worktree", "add", "--detach", str(worktree), "HEAD~1")
    git(clone, "config", "core.hooksPath", str(HOOK.parent))
    code, text = run_git(worktree, "update-ref", "HEAD", "refs/heads/main")
    assert code == 0, text
    assert git(worktree, "rev-parse", "HEAD") == git(clone, "rev-parse", "refs/heads/main")
    assert git(clone, "symbolic-ref", "HEAD") == "refs/heads/main"


def test_a_clone_on_a_branch_fails_at_step_0a_before_the_fetch(tmp_path: Path) -> None:
    clone = clone_at(tmp_path)
    git(clone, "switch", "-c", "pr-9426")
    proc = subprocess.run(exec_line(BRANCH_PROBE, tmp_path), capture_output=True, text=True, check=False)
    assert proc.returncode != 0
    text = proc.stdout + proc.stderr
    assert "DEPLOY-BLOCKED" in text
    assert "branch pr-9426" in text
    assert "switch main" in text


def test_a_clone_on_main_passes_step_0a(tmp_path: Path) -> None:
    clone_at(tmp_path)
    proc = subprocess.run(exec_line(BRANCH_PROBE, tmp_path), capture_output=True, text=True, check=False)
    assert proc.returncode == 0, proc.stdout + proc.stderr


def test_fleet_sync_installs_the_hook_on_every_sync(tmp_path: Path) -> None:
    clone = clone_at(tmp_path)
    source = clone / "config" / "git-hooks" / "reference-transaction"
    source.parent.mkdir(parents=True)
    source.write_bytes(HOOK.read_bytes())
    line = exec_line("install -m 0755", tmp_path)
    proc = subprocess.run(line, capture_output=True, text=True, check=False)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    installed = clone / ".git" / "hooks" / "reference-transaction"
    assert installed.is_file()
    assert os.access(installed, os.X_OK), "git ignores a hook it cannot execute"
    assert installed.read_bytes() == HOOK.read_bytes()

