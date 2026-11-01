"""fleet-sync merges config/pi-packages.json into pi's live settings' packages key (fleet-ops#9302)."""

import json
import shlex
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UNIT = ROOT / "systemd" / "fleet-sync.service"
REPO_FILE = ROOT / "config" / "pi-packages.json"
HOME = Path.home()
CLONE = "workspaces/tooling/fleet-ops-deploy-clone"
SETTINGS = ".pi/agent/settings.json"
TEMP = ".pi/agent/.settings.json.sync"
MERGE_TAIL = "merge --ff-only refs/remotes/origin/main"

LIVE = """{
  "defaultProvider": "openrouter",
  "packages": [
    "npm:old-package@1.0.0"
  ],
  "lastChangelogVersion": "1.0.3",
  "thinkingBudgets": {
    "high": 16384
  }
}"""
REPO = {"packages": ["git:github.com/stnly/pi-grok@a5817666500fbbc9c41534346f82b5183a7b89b0", "npm:pi-mcp-adapter@5.3.0"]}


def expand(raw: str, home: Path) -> str:
    return (
        raw.replace("%%", "\x00")
        .replace("$$", "\x01")
        .replace("%h", str(home))
        .replace("\x00", "%")
        .replace("\x01", "$")
    )


def steps(home: Path) -> list[str]:
    return [expand(raw[len("ExecStart=") :], home) for raw in UNIT.read_text().splitlines() if raw.startswith("ExecStart=")]


def pi_packages_step_at(home: Path) -> int:
    found = [i for i, step in enumerate(steps(home)) if "pi-packages.json" in step]
    assert len(found) == 1, "the tests must pin one packages merge step"
    return found[0]


def pi_packages_step(home: Path) -> list[str]:
    return shlex.split(steps(home)[pi_packages_step_at(home)])


def merge_step_at(home: Path) -> int:
    return next(i for i, s in enumerate(steps(home)) if s.endswith(MERGE_TAIL) and CLONE in s)


def run(home: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        pi_packages_step(home),
        capture_output=True,
        text=True,
        check=False,
        env={"PATH": "/usr/bin:/bin"},
    )


def home_at(tmp_path: Path, live: str | None, repo: dict | None) -> Path:
    home = tmp_path / "home"
    settings = home / SETTINGS
    settings.parent.mkdir(parents=True)
    if live is not None:
        settings.write_text(live)
    if repo is not None:
        (home / CLONE / "config").mkdir(parents=True)
        (home / CLONE / "config" / "pi-packages.json").write_text(json.dumps(repo))
    return home


def test_a_repo_package_change_updates_the_live_list_and_keeps_pis_own_keys(tmp_path: Path) -> None:
    home = home_at(tmp_path, LIVE, REPO)
    proc = run(home)
    assert proc.returncode == 0, proc.stderr
    merged = json.loads((home / SETTINGS).read_text())
    assert merged["packages"] == REPO["packages"]
    assert merged["defaultProvider"] == "openrouter"
    assert merged["lastChangelogVersion"] == "1.0.3"
    assert merged["thinkingBudgets"] == {"high": 16384}
    assert not (home / TEMP).exists(), "the temp file must not survive a move"


def test_a_second_merge_changes_nothing_and_cleans_up(tmp_path: Path) -> None:
    home = home_at(tmp_path, LIVE, REPO)
    first = run(home)
    assert first.returncode == 0, first.stderr
    before = (home / SETTINGS).read_bytes()
    second = run(home)
    assert second.returncode == 0, second.stderr
    assert (home / SETTINGS).read_bytes() == before
    assert not (home / TEMP).exists()


def test_an_unparsable_live_file_fails_loud_and_is_left_alone(tmp_path: Path) -> None:
    home = home_at(tmp_path, "{not json", REPO)
    proc = run(home)
    assert proc.returncode != 0, "bad JSON must fail the step, not be overwritten"
    assert (home / SETTINGS).read_text() == "{not json"
    assert not (home / TEMP).exists()


def test_a_missing_live_file_fails_loud(tmp_path: Path) -> None:
    home = home_at(tmp_path, None, REPO)
    proc = run(home)
    assert proc.returncode != 0
    assert not (home / SETTINGS).exists()
    assert not (home / TEMP).exists()


def test_a_missing_repo_file_fails_loud(tmp_path: Path) -> None:
    home = home_at(tmp_path, LIVE, None)
    proc = run(home)
    assert proc.returncode != 0
    assert (home / SETTINGS).read_text() == LIVE
    assert not (home / TEMP).exists()


def test_the_step_reads_the_clone_copy_after_the_merge_that_carries_it() -> None:
    step_at = pi_packages_step_at(HOME)
    assert merge_step_at(HOME) < step_at, "the merge must read the copy the clone merge landed"


def test_a_live_file_without_a_packages_key_gains_it(tmp_path: Path) -> None:
    live = '{\n  "defaultProvider": "openrouter",\n  "lastChangelogVersion": "1.0.3"\n}'
    home = home_at(tmp_path, live, REPO)
    proc = run(home)
    assert proc.returncode == 0, proc.stderr
    merged = json.loads((home / SETTINGS).read_text())
    assert merged["packages"] == REPO["packages"]
    assert merged["defaultProvider"] == "openrouter"
    assert merged["lastChangelogVersion"] == "1.0.3"


def test_the_merge_target_is_the_home_the_step_runs_for(tmp_path: Path) -> None:
    home = home_at(tmp_path, None, None)
    assert str(home) in " ".join(pi_packages_step(home))


def test_the_repo_file_carries_only_the_packages_list() -> None:
    parsed = json.loads(REPO_FILE.read_text())
    assert set(parsed) == {"packages"}, "a second key would leak into pi's live settings through the object merge"
    assert all(isinstance(p, str) for p in parsed["packages"])
