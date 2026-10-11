"""fleet-gh-login-check.service pages when the box's gh login is gone or wrong.

Runs the unit's own ExecStart (read from the unit file, never a copy) with a
stub gh: the right login passes, a missing login, a revoked token and another
account fail loud, and one blip followed by success passes. Also proves the
CI jail step refuses to run outside a GitHub-hosted runner, so a local replay
can never plant over or delete the real login files again.
"""
import os
import pathlib
import shlex
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
UNIT = ROOT / "systemd/fleet-gh-login-check.service"
CI = ROOT / ".github/workflows/ci.yml"


def _exec_start():
    """The ExecStart command with systemd's line continuations joined and $$ unescaped."""
    text = UNIT.read_text().replace("\\\n", "")
    line = next(ln for ln in text.splitlines() if ln.startswith("ExecStart="))
    return shlex.split(line[len("ExecStart="):].replace("$$", "$"))


def _run(tmp_path, stub_body, want="nish3451"):
    gh = tmp_path / "gh"
    gh.write_text("#!/bin/sh\n" + stub_body)
    gh.chmod(0o755)
    env = {"GH": str(gh), "WANT": want, "PAUSE": "0", "PATH": "/usr/bin:/bin", "STATE": str(tmp_path / "n")}
    return subprocess.run(_exec_start(), env=env, capture_output=True, text=True, timeout=30)


def test_right_login_passes(tmp_path):
    r = _run(tmp_path, 'test "$1 $2" = "api user" && echo nish3451\n')
    assert r.returncode == 0 and "gh login ok: nish3451" in r.stdout


@pytest.mark.parametrize(
    "body",
    [
        'echo "To get started with GitHub CLI, please run:  gh auth login" >&2; exit 4\n',  # hosts.yml gone
        'echo "HTTP 401: Bad credentials" >&2; exit 1\n',  # token revoked
        "echo someone-else\n",  # another account is active
    ],
)
def test_missing_revoked_or_wrong_login_fails_loud(tmp_path, body):
    r = _run(tmp_path, body)
    assert r.returncode == 1
    assert "gh login BROKEN" in r.stdout


def test_one_blip_then_ok_passes(tmp_path):
    body = 'n=$(cat "$STATE" 2>/dev/null || echo 0); echo $((n+1)) > "$STATE"; [ "$n" -ge 1 ] || exit 1; echo nish3451\n'
    r = _run(tmp_path, body)
    assert r.returncode == 0, r.stdout


def _jail_step():
    q = '.jobs.ci.steps[] | select(.name | test("^Worker jail hides the gh login")) | .run'
    run = subprocess.run(["yq", q, str(CI)], capture_output=True, text=True, check=True).stdout
    assert "planted" in run
    return run


@pytest.mark.parametrize("runner_env", [None, "self-hosted"])
def test_ci_jail_step_refuses_off_a_hosted_runner(tmp_path, runner_env):
    """Plain bash (no -e), as the 2026-10-11 replay ran it: it must stop before touching $HOME."""
    home = tmp_path / "home"
    for d in (".config/gh", ".claude"):
        (home / d).mkdir(parents=True)
    real = {home / ".config/gh/hosts.yml": "real gh login", home / ".claude.json": "real claude"}
    for p, v in real.items():
        p.write_text(v)
    env = {"HOME": str(home), "PATH": "/usr/bin:/bin"}
    if runner_env:
        env["RUNNER_ENVIRONMENT"] = runner_env
    script = tmp_path / "step.sh"
    script.write_text(_jail_step())
    r = subprocess.run(["bash", str(script)], cwd=ROOT, env=env, capture_output=True, text=True, timeout=60)
    assert r.returncode == 1 and "refusing" in r.stdout
    assert {p: p.read_text() for p in real} == real
    assert sorted(os.listdir(home)) == [".claude", ".claude.json", ".config"]  # nothing planted beside them
