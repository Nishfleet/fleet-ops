"""fleet-hermes-xai-login-check.service pages when Hermes's xai-oauth login is gone.

Runs the unit's own ExecStart (read from the unit file, never a copy) with a
stub hermes: a logged-in status passes; a logged-out status, a missing binary
and empty output fail loud. The three tries are systemd's Restart=, not tested here.
"""
import pathlib
import shlex
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
UNIT = ROOT / "systemd/fleet-hermes-xai-login-check.service"


def _exec_start():
    """The ExecStart command with systemd's line continuations joined and $$ unescaped."""
    text = UNIT.read_text().replace("\\\n", "")
    line = next(ln for ln in text.splitlines() if ln.startswith("ExecStart="))
    return shlex.split(line[len("ExecStart="):].replace("$$", "$"))


def _run(tmp_path, stub_body):
    hermes = tmp_path / "hermes"
    hermes.write_text("#!/bin/sh\n" + stub_body)
    hermes.chmod(0o755)
    env = {"HERMES": str(hermes), "PATH": "/usr/bin:/bin"}
    return subprocess.run(_exec_start(), env=env, capture_output=True, text=True, timeout=30)


def test_logged_in_passes(tmp_path):
    r = _run(tmp_path, 'test "$*" = "auth status xai-oauth" && echo "xai-oauth: logged in"\n')
    assert r.returncode == 0 and "hermes xai login ok" in r.stdout


@pytest.mark.parametrize(
    "body",
    [
        # 2026-09-25 state: relogin_required
        'echo "xai-oauth: logged out (xAI OAuth state is missing access_token. Re-authenticate with \\`hermes model\\`.)"\n',
        'echo "xai-oauth: logged out" >&2; exit 1\n',
        "exit 0\n",  # no output at all
    ],
)
def test_logged_out_fails_loud(tmp_path, body):
    r = _run(tmp_path, body)
    assert r.returncode == 1
    assert "hermes xai login BROKEN" in r.stdout
    assert "hermes auth add xai-oauth --no-browser" in r.stdout


def test_missing_binary_fails_loud(tmp_path):
    env = {"HERMES": str(tmp_path / "nope"), "PATH": "/usr/bin:/bin"}
    r = subprocess.run(_exec_start(), env=env, capture_output=True, text=True, timeout=30)
    assert r.returncode == 1 and "hermes xai login BROKEN" in r.stdout

