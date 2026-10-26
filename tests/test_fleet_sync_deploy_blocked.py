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
    for raw in UNIT.read_text().splitlines():
        if not raw.startswith("ExecStart="):
            continue
        expanded = expand(raw[len("ExecStart=") :], home)
        if "DEPLOY-BLOCKED: the deploy clone is not at origin/main" in expanded:
            return shlex.split(expanded)
    raise AssertionError("no clone-state probe found in systemd/fleet-sync.service")


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
