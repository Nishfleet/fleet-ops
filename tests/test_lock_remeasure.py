"""fleet-lock-remeasure.service fails when the Hermes lock stops matching the host (fleet-ops#10269).

Runs the unit's own ExecStart (read from the unit file, never a copy) against a
fake home, a fake /proc and a stub systemctl: a host the table accounts for
passes, and a new credential file or directory, a hidden path an open fd points
into, and a hidden path named in an environment value each fail with the path.
"""
import json
import os
import pathlib
import shlex
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
UNIT = ROOT / "systemd/fleet-lock-remeasure.service"
PID = "4242"


def _exec_start():
    """The ExecStart command with systemd's line continuations joined and $$ unescaped."""
    text = UNIT.read_text().replace("\\\n", "")
    line = next(ln for ln in text.splitlines() if ln.startswith("ExecStart="))
    return shlex.split(line[len("ExecStart="):].replace("$$", "$"))


@pytest.fixture
def host(tmp_path):
    home = tmp_path / "home"
    for rel in (".hermes", ".ssh", ".config/gh", ".config/cloudflare", ".config/tincan", ".local/share/devin", ".npm"):
        (home / rel).mkdir(parents=True)
    (home / ".config/tincan/hermes.json").write_text("{}")
    (home / ".gitconfig").write_text("")
    locks = tmp_path / "locks.json"
    locks.write_text(json.dumps({
        "agents": {"hermes-gateway": {
            "needs": ["~/.hermes", "~/.config/gh", "~/.config/tincan"],
            "must_hide": ["~/.ssh", "~/.config/cloudflare", "~/.local/share/devin"],
        }},
        "reviewed_open": {"~/.gitconfig": "no secret", "~/.npm": "cache", "~/.config/tincan/hermes.json": "own relay identity"},
    }))
    proc = tmp_path / "proc"
    (proc / PID / "fd").mkdir(parents=True)
    (proc / PID / "environ").write_bytes(b"HOME=/x\0LANG=C\0")
    (proc / PID / "fd/3").symlink_to(home / ".hermes")
    cgroup = tmp_path / "cgroup.procs"
    cgroup.write_text(PID + "\n")
    systemctl = tmp_path / "systemctl"
    systemctl.write_text('#!/bin/sh\necho \'Environment=HOME=/x "A=b"\'\n')
    systemctl.chmod(0o755)
    env = {"HOME": str(home), "PATH": os.environ["PATH"], "LOCKS": str(locks), "UNIT": "hermes-gateway",
           "PROC": str(proc), "CGROUP": str(cgroup), "SYSTEMCTL": str(systemctl)}
    return home, proc, systemctl, env


def _run(env):
    return subprocess.run(_exec_start(), env=env, capture_output=True, text=True, timeout=30)


def test_a_host_the_table_accounts_for_passes(host):
    r = _run(host[3])
    assert r.returncode == 0, r.stdout
    assert "lock remeasure ok: 3 hidden paths, 1 gateway processes, nothing unlisted" in r.stdout


@pytest.mark.parametrize("rel", [".config/tincan/new-token.json", ".config/newtool", ".netrc", ".local/share/newtool"])
def test_a_new_credential_store_fails_with_its_path(host, rel):
    home, _, _, env = host
    path = home / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("t")
    r = _run(env)
    assert r.returncode == 1
    assert "LOCK-REMEASURE" in r.stdout and f"  {path}" in r.stdout


def test_a_hidden_path_an_open_fd_points_into_fails(host):
    home, proc, _, env = host
    (proc / PID / "fd/4").symlink_to(home / ".ssh/id_ed25519")
    r = _run(env)
    assert r.returncode == 1
    assert f"{home}/.ssh: {home}/.ssh/id_ed25519" in r.stdout


def test_a_hidden_path_in_the_environment_fails_but_a_longer_name_does_not(host):
    home, proc, systemctl, env = host
    (proc / PID / "environ").write_bytes(f"X={home}/.ssh-old\0".encode())
    assert _run(env).returncode == 0
    (proc / PID / "environ").write_bytes(f"X={home}/.ssh\0".encode())
    assert _run(env).returncode == 1


def test_no_gateway_process_is_a_failure_not_a_pass(host):
    env = dict(host[3], CGROUP=str(host[0] / "absent"))
    r = _run(env)
    assert r.returncode == 1 and "read set was not measured" in r.stdout


@pytest.mark.skipif(os.geteuid() == 0, reason="root reads a mode-000 file")
def test_an_unreadable_gateway_process_is_a_failure_not_a_pass(host):
    _, proc, _, env = host
    (proc / PID / "environ").chmod(0)
    r = _run(env)
    assert r.returncode == 1 and "read set was not measured" in r.stdout
