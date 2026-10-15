"""The helper and scout subagents reach the Max config dir (~/.claude-max).

Runs fleet-sync.service's own ExecStart lines (read from the unit, never a
copy) against a temp home: the agent installs, the real systemd-tmpfiles
--user --create, and the step 5b link check. Proves both lanes are readable
through ~/.claude-max/agents, that each file's model matches the model-lanes
table, and that a hand-made dir in the link's place fails the sync.
"""
import os
import pathlib
import shlex
import shutil
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
UNIT = ROOT / "systemd/fleet-sync.service"
CLONE = "%h/workspaces/tooling/fleet-ops-deploy-clone"
LANES = {"helper": "sonnet", "scout": "haiku"}  # claude-mods model-lanes/lanes.json


def _exec_lines():
    """ExecStart commands that touch the agents or the user tmpfiles, unescaped as systemd does."""
    out = []
    for line in UNIT.read_text().splitlines():
        if not line.startswith("ExecStart="):
            continue
        cmd = line[len("ExecStart="):].replace("$$", "$")
        if "claude-agents/" in cmd or "claude-max-agents.conf" in cmd or "--user --create" in cmd or ".claude-max/agents" in cmd:
            out.append(cmd)
    return out


def _run(home, cmd):
    # %h is systemd's home specifier; the clone path is swapped first so it points at this checkout.
    cmd = cmd.replace(CLONE, str(ROOT)).replace("%h", str(home))
    env = {"HOME": str(home), "XDG_CONFIG_HOME": str(home / ".config"), "PATH": "/usr/bin:/bin"}
    return subprocess.run(shlex.split(cmd), env=env, capture_output=True, text=True)


def _sync(home):
    return [_run(home, cmd) for cmd in _exec_lines()]


def test_unit_ships_every_agent_file_and_the_link_rule():
    cmds = "\n".join(_exec_lines())
    for name in LANES:
        assert f"config/claude-agents/{name}.md %h/.claude/agents/{name}.md" in cmds
    assert "config/user-tmpfiles.d/claude-max-agents.conf" in cmds
    assert "readlink %h/.claude-max/agents" in cmds
    shipped = {p.stem for p in (ROOT / "config/claude-agents").glob("*.md")}
    assert shipped == set(LANES), "every shipped agent file needs its install line and a lane"


@pytest.mark.skipif(not shutil.which("systemd-tmpfiles"), reason="systemd-tmpfiles missing")
def test_sync_links_max_dir_to_the_lanes(tmp_path):
    home = tmp_path / "home"
    (home / ".claude-max").mkdir(parents=True)
    results = _sync(home)
    assert all(r.returncode == 0 for r in results), [(r.args, r.stderr) for r in results]
    link = home / ".claude-max/agents"
    assert link.is_symlink() and os.readlink(link) == str(home / ".claude/agents")
    for name, model in LANES.items():
        text = (link / f"{name}.md").read_text()
        assert f"\nname: {name}\n" in text and f"\nmodel: {model}\n" in text
    # A second sync changes nothing and still passes (install -C, L on an existing link).
    assert all(r.returncode == 0 for r in _sync(home))


@pytest.mark.skipif(not shutil.which("systemd-tmpfiles"), reason="systemd-tmpfiles missing")
def test_hand_made_dir_in_place_of_the_link_fails_the_sync(tmp_path):
    home = tmp_path / "home"
    (home / ".claude-max/agents").mkdir(parents=True)
    results = _sync(home)
    assert results[-1].returncode != 0
    assert "is not the link" in results[-1].stdout
