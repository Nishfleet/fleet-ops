"""fleet-clone-lag fails loud when the deploy clone is behind origin/main (fleet-ops#10046).

The unit's real ExecStart runs against a temp clone of a temp origin, so the
message and the exit code are the code that ships, not a copy of it.
"""

import os
import re
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UNIT = ROOT / "systemd" / "fleet-clone-lag.service"
TIMER = ROOT / "systemd" / "fleet-clone-lag.timer"
SYNC = ROOT / "systemd" / "fleet-sync.service"
CLONE = "workspaces/tooling/fleet-ops-deploy-clone"
GIT_ENV = {
    "PATH": "/usr/local/bin:/usr/bin:/bin",
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_SYSTEM": os.devnull,
    "GIT_AUTHOR_NAME": "fleet",
    "GIT_AUTHOR_EMAIL": "fleet@example.invalid",
    "GIT_COMMITTER_NAME": "fleet",
    "GIT_COMMITTER_EMAIL": "fleet@example.invalid",
}


def _exec_start():
    text = UNIT.read_text().replace("\\\n", "")
    line = next(ln for ln in text.splitlines() if ln.startswith("ExecStart="))
    match = re.fullmatch(r"/bin/sh -c '(.*)'", line[len("ExecStart="):])
    assert match, line
    return ["/bin/sh", "-c", match.group(1).replace("$$", "$").replace("%%", "%")]


def _git(cwd, *args, env=None):
    full = {**GIT_ENV, **(env or {})}
    return subprocess.run(["git", *args], cwd=str(cwd), env=full, check=True, capture_output=True, text=True).stdout.strip()


def _land(seed, min_ago, text):
    (seed / "prompts" / "worker.md").write_text(text)
    _git(seed, "add", "-A")
    stamp = "@%d +0000" % (time.time() - min_ago * 60)
    _git(seed, "commit", "-q", "-m", text, env={"GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp})
    _git(seed, "push", "-q", "origin", "main")
    return _git(seed, "rev-parse", "HEAD")


def _repo(tmp_path, landed_min_ago=(45,)):
    origin = tmp_path / "origin.git"
    origin.mkdir()
    _git(origin, "init", "-q", "--bare", "-b", "main")
    seed = tmp_path / "seed"
    seed.mkdir()
    _git(seed, "init", "-q", "-b", "main")
    (seed / "prompts").mkdir()
    (seed / "prompts" / "worker.md").write_text("the prompts the box already runs\n")
    _git(seed, "add", "-A")
    _git(seed, "commit", "-q", "-m", "what the box already runs")
    deployed = _git(seed, "rev-parse", "HEAD")
    _git(seed, "remote", "add", "origin", str(origin))
    _git(seed, "push", "-q", "origin", "main")
    clone = tmp_path / "home" / CLONE
    clone.parent.mkdir(parents=True)
    _git(tmp_path, "clone", "-q", str(origin), str(clone))
    landed = [_land(seed, minutes, "a merge that landed on main %d min ago\n" % minutes) for minutes in landed_min_ago]
    return clone, deployed, landed


def _run(clone, lag_min):
    env = {**GIT_ENV, "CLONE": str(clone), "LAG_MIN": str(lag_min)}
    return subprocess.run(_exec_start(), env=env, capture_output=True, text=True, timeout=60)


def _reported_age(stdout):
    match = re.search(r"unshipped for (\d+) min", stdout) or re.search(r"landed (\d+) min ago", stdout)
    assert match, stdout
    return int(match.group(1))


def test_quiet_when_the_clone_is_at_origin_main(tmp_path):
    clone, _, landed = _repo(tmp_path)
    _git(clone, "fetch", "-q", "origin")
    _git(clone, "merge", "-q", "--ff-only", "refs/remotes/origin/main")
    done = _run(clone, 30)
    assert done.returncode == 0, done.stdout + done.stderr
    assert "deploy clone is at origin/main (%s)" % landed[-1][:7] in done.stdout


def test_fires_when_the_oldest_unshipped_commit_is_past_the_window(tmp_path):
    clone, deployed, landed = _repo(tmp_path, (45,))
    done = _run(clone, 30)
    assert done.returncode == 1, done.stdout + done.stderr
    assert 45 <= _reported_age(done.stdout) <= 47
    assert "CLONE-LAG: origin/main %s has been unshipped" % landed[-1][:7] in done.stdout
    assert "the deploy clone head is %s, behind by 1 commit(s)" % deployed[:7] in done.stdout
    assert "fix: systemctl --user start fleet-sync.service" in done.stdout


def test_fires_when_only_the_oldest_of_several_unshipped_commits_is_old(tmp_path):
    clone, deployed, landed = _repo(tmp_path, (45, 20, 2))
    done = _run(clone, 30)
    assert done.returncode == 1, done.stdout + done.stderr
    assert 45 <= _reported_age(done.stdout) <= 47
    assert landed[0][:7] in done.stdout
    assert "the deploy clone head is %s, behind by 3 commit(s)" % deployed[:7] in done.stdout


def test_quiet_while_the_oldest_unshipped_commit_is_inside_the_window(tmp_path):
    clone, _, landed = _repo(tmp_path, (12, 2))
    done = _run(clone, 30)
    assert done.returncode == 0, done.stdout + done.stderr
    assert "deploy pending: oldest unshipped commit %s landed 12 min ago" % landed[0][:7] in done.stdout


def test_fires_when_a_work_branch_is_checked_out_in_the_clone(tmp_path):
    clone, _, landed = _repo(tmp_path)
    _git(clone, "checkout", "-q", "-b", "work")
    (clone / "untracked-by-main.md").write_text("a session's work\n")
    _git(clone, "add", "-A")
    _git(clone, "commit", "-q", "-m", "a work branch in the deploy clone")
    done = _run(clone, 30)
    assert done.returncode == 1, done.stdout + done.stderr
    assert "not an ancestor of origin/main" in done.stdout
    assert "origin/main %s" % landed[-1][:7] in done.stdout
    assert "git -C %s checkout main" % clone in done.stdout
    assert "fix: systemctl --user start fleet-sync.service" not in done.stdout


def test_fires_when_the_clone_is_missing(tmp_path):
    done = _run(tmp_path / "gone", 30)
    assert done.returncode == 1, done.stdout + done.stderr
    assert "CLONE-LAG: no deploy clone at" in done.stdout


def test_fires_when_origin_main_cannot_be_fetched(tmp_path):
    clone, _, _ = _repo(tmp_path)
    _git(clone, "remote", "set-url", "origin", str(tmp_path / "no-such-origin.git"))
    done = _run(clone, 30)
    assert done.returncode == 1, done.stdout + done.stderr
    assert "CLONE-LAG: cannot fetch origin main into %s" % clone in done.stdout


def test_the_fetch_leaves_the_clone_alone(tmp_path):
    clone, deployed, _ = _repo(tmp_path)
    fetch_head = clone / ".git" / "FETCH_HEAD"
    before = fetch_head.read_text() if fetch_head.exists() else None
    done = _run(clone, 30)
    assert done.returncode == 1, done.stdout + done.stderr
    assert _git(clone, "rev-parse", "refs/remotes/origin/main") == deployed
    assert (fetch_head.read_text() if fetch_head.exists() else None) == before


def test_unit_wiring_and_defaults_match_the_test():
    text = UNIT.read_text()
    assert "Environment=CLONE=%h/" + CLONE in text
    assert "Environment=LAG_MIN=35" in text
    assert "OnFailure=fleet-unit-failed@%N.service" in text
    assert "--no-write-fetch-head" in text
    assert "+refs/heads/main:refs/fleet-clone-lag/main" in text
    assert "Restart=on-failure" in text
    assert "RestartMode=direct" in text
    assert "StartLimitIntervalSec=30min" in text
    timer = TIMER.read_text()
    assert "OnUnitActiveSec=5min" in timer
    assert "OnBootSec=" in timer
    assert "WantedBy=timers.target" in timer
    sync = SYNC.read_text()
    assert re.search(r"^ExecStart=/usr/bin/systemctl --user link \S*fleet-clone-lag\.service \S*fleet-clone-lag\.timer$", sync, re.M)
    assert "ExecStart=/usr/bin/systemctl --user enable --now fleet-clone-lag.timer" in sync
