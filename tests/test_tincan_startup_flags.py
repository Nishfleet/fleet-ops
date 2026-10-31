"""The headless claude in tincan-listen-claude-vps.service loads only
agent-tincan, no skills and no user settings, from rootfs at checkout time.

Delete a flag, or the MCP file it names, and this fails. --mcp-config must
come before --strict-mcp-config: its value list is variadic and would eat the
prompt. cwd must be a dedicated dir: with WorkingDirectory=/home/nish, the
project settings source is ~/.claude/settings.json (the user file) and
--setting-sources project,local still loads the user Stop hook and plugins.
"""
import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
UNIT = ROOT / "rootfs/etc/systemd/system/tincan-listen-claude-vps.service"
MCP = ROOT / "config/tincan-listener-mcp.json"
FLAGS = (
    "--strict-mcp-config",
    "--disable-slash-commands",
    "--setting-sources project,local",
    "--mcp-config /home/nish/workspaces/tooling/fleet-ops-deploy-clone/config/tincan-listener-mcp.json --strict-mcp-config",
)


def _exec_line():
    lines = [l for l in UNIT.read_text().splitlines() if l.startswith("ExecStart=")]
    assert len(lines) == 1, f"{UNIT}: expected one ExecStart, found {len(lines)}"
    return lines[0]


def test_startup_flags():
    exec_line = _exec_line()
    for needle in FLAGS:
        assert needle in exec_line, f"{UNIT}: ExecStart is missing: {needle}"
    servers = json.loads(MCP.read_text())["mcpServers"]
    assert list(servers) == ["agent-tincan"], f"{MCP}: mcpServers is not only agent-tincan"


def test_working_directory():
    text = UNIT.read_text()
    wd_lines = [l for l in text.splitlines() if l.startswith("WorkingDirectory=")]
    assert len(wd_lines) == 1, f"{UNIT}: expected one WorkingDirectory, found {len(wd_lines)}"
    wd = wd_lines[0][len("WorkingDirectory="):]
    assert wd == "/home/nish/.local/state/tincan-listen-claude-vps", (
        f"{UNIT}: WorkingDirectory is not the dedicated state dir"
    )
    assert wd.strip() not in ("", "/home/nish", "/home/nish/", "~", "%h", "%h/"), (
        f"{UNIT}: WorkingDirectory must not be the home dir"
    )


def test_config_dir_inline():
    lines = [l for l in UNIT.read_text().splitlines() if l.startswith("Environment=CLAUDE_CONFIG_DIR=")]
    assert "Environment=CLAUDE_CONFIG_DIR=/home/nish/.claude-vps" in lines, (
        f"{UNIT}: CLAUDE_CONFIG_DIR is not set inline"
    )
