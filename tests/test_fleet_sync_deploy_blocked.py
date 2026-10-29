"""fleet-sync names the cause when the deploy clone is not at origin/main (fleet-ops#9967)."""

import os
import shlex
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


def clone_with_hook(tmp_path: Path) -> Path:
    clone = clone_at(tmp_path)
    git(clone, "config", "core.hooksPath", str(HOOK.parent))
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
        ("worktree", "add", "-b", "x", str(tmp_path / "x"), "refs/remotes/origin/main"),
    ):
        code, text = run_git(clone, *args)
        assert code != 0, args
        assert "DEPLOY-BLOCKED" in text, (args, text)
        assert "worktree add" in text, args
    assert git(clone, "symbolic-ref", "HEAD") == "refs/heads/main"
    assert git(clone, "rev-parse", "--abbrev-ref", "HEAD") == "main"


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


def test_the_hook_leaves_a_linked_worktree_alone(tmp_path: Path) -> None:
    clone = clone_with_hook(tmp_path)
    worktree = tmp_path / "side"
    code, text = run_git(clone, "worktree", "add", "--detach", str(worktree), "refs/remotes/origin/main")
    assert code == 0, text
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
    line = exec_line("config core.hooksPath", tmp_path)
    proc = subprocess.run(line, capture_output=True, text=True, check=False)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert git(clone, "config", "core.hooksPath") == str(tmp_path / CLONE / "config" / "git-hooks")

