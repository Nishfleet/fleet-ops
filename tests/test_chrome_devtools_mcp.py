"""Chrome DevTools MCP is pinned once and wired the same way into every agent.

The version and the argument list live in ansible/host.yml vars. Every static
config fragment must carry the same argument list, nothing may run the package
through npx or @latest, and the real Ansible tasks that edit user files run
twice against temp copies: the second run changes nothing, and other entries
and keys survive.
"""
import json
import pathlib
import re
import shutil
import subprocess
import tomllib

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
HOST = ROOT / "ansible/host.yml"
REQUIRED = ["--headless", "--isolated", "--executablePath", "/usr/bin/google-chrome", "--no-usage-statistics"]


def _play():
    out = subprocess.run(["yq", "-o=json", ".", str(HOST)], capture_output=True, text=True, check=True).stdout
    return json.loads(out)[0]


PLAY = _play()
VARS = PLAY["vars"]
ARGS = VARS["chrome_devtools_mcp_args"]
TASKS = {t["name"]: t for t in PLAY["tasks"]}


def test_version_is_one_exact_pin():
    assert re.fullmatch(r"\d+\.\d+\.\d+", VARS["chrome_devtools_mcp_version"])
    pins = [
        p for p in ROOT.rglob("*")
        if p.is_file() and ".git" not in p.parts and "__pycache__" not in p.parts and p not in (HOST, pathlib.Path(__file__))
        and re.search(r"chrome-devtools-mcp(@|\s+version)", p.read_text(errors="ignore"))
    ]
    assert pins == [], f"the version string belongs in ansible/host.yml only: {pins}"
    install = TASKS["Install the pinned Chrome DevTools MCP server"]["community.general.npm"]
    assert install["version"] == "{{ chrome_devtools_mcp_version }}"


def test_no_runtime_fetch():
    text = HOST.read_text()
    assert "@latest" not in text and "npx" not in text


def test_args_run_headless_in_a_throwaway_profile_on_system_chrome():
    assert ARGS[: len(REQUIRED)] == REQUIRED
    assert VARS["chrome_devtools_mcp_bin"].endswith("/.local/bin/chrome-devtools-mcp")


def test_claude_drop_in_enables_the_plugin():
    drop_in = json.loads((ROOT / "rootfs/etc/claude-code/managed-settings.d/60-chrome-devtools.json").read_text())
    assert drop_in == {"enabledPlugins": {"chrome-devtools@nish-mods": True}}


def test_every_install_step_is_in_the_play():
    for name in (
        "Install the pinned Chrome DevTools MCP server",
        "Install the OpenCode managed config",
        "Install the shared MCP config (Pi reads it through pi-mcp-adapter)",
        "Add the chrome-devtools entry to each agent CLI",
        "Swap Cursor's dead camofox entry for chrome-devtools",
        "Drop Codex's dead camofox entry",
        "Add the chrome-devtools entry under Hermes' mcp_servers",
    ):
        assert name in TASKS, name


def _run_tasks(tmp_path, names, subs=None):
    subs = subs or {}
    tasks = []
    for name in names:
        text = json.dumps(TASKS[name])
        for old, new in subs.items():
            text = text.replace(old, new)
        task = json.loads(text)
        for key in ("owner", "group"):
            for module in task.values():
                if isinstance(module, dict):
                    module.pop(key, None)
        tasks.append(task)
    play = {"hosts": "localhost", "connection": "local", "gather_facts": False, "vars": {**VARS, "nish_home": str(tmp_path)}, "tasks": tasks}
    book = tmp_path / "play.json"
    book.write_text(json.dumps([play]))
    result = subprocess.run(
        ["ansible-playbook", "-i", "localhost,", str(book)],
        capture_output=True, text=True, cwd=tmp_path, env={"PATH": "/usr/bin:/bin:/usr/local/bin", "HOME": str(tmp_path), "ANSIBLE_NOCOLOR": "1"},
    )
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout


@pytest.mark.skipif(not shutil.which("ansible-playbook") or not shutil.which("yq"), reason="ansible or yq missing")
def test_generated_configs_carry_the_pinned_command(tmp_path):
    names = [
        "Create the OpenCode managed config directory",
        "Install the OpenCode managed config",
        "Create the shared MCP config directory",
        "Install the shared MCP config (Pi reads it through pi-mcp-adapter)",
    ]
    subs = {"/etc/opencode": str(tmp_path / "etc/opencode")}
    (tmp_path / "etc").mkdir()
    _run_tasks(tmp_path, names, subs)
    bin_path = f"{tmp_path}/.local/bin/chrome-devtools-mcp"
    entry = json.loads((tmp_path / "etc/opencode/opencode.json").read_text())["mcp"]["chrome-devtools"]
    assert entry == {"type": "local", "command": [bin_path, *ARGS], "enabled": True}
    shared = json.loads((tmp_path / ".config/mcp/mcp.json").read_text())["mcpServers"]["chrome-devtools"]
    assert shared == {"command": bin_path, "args": ARGS, "lifecycle": "lazy", "idleTimeout": 5}
    assert "changed=0" in _run_tasks(tmp_path, names, subs)


@pytest.mark.skipif(not shutil.which("ansible-playbook") or not shutil.which("yq"), reason="ansible or yq missing")
def test_cursor_swap_keeps_other_servers_and_is_idempotent(tmp_path):
    cfg = tmp_path / ".cursor/mcp.json"
    cfg.parent.mkdir()
    cfg.write_text(json.dumps({"mcpServers": {
        "camofox-browser": {"command": "/opt/gone/camofox-browser-mcp-shared", "args": ["cursor"]},
        "drive": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/srv/Drive"]},
    }}))
    names = ["Read Cursor's MCP config", "Swap Cursor's dead camofox entry for chrome-devtools"]
    _run_tasks(tmp_path, names)
    servers = json.loads(cfg.read_text())["mcpServers"]
    assert set(servers) == {"drive", "chrome-devtools"}
    assert servers["drive"]["command"] == "npx"
    assert servers["chrome-devtools"] == {"command": f"{tmp_path}/.local/bin/chrome-devtools-mcp", "args": ARGS}
    assert "changed=0" in _run_tasks(tmp_path, names)


@pytest.mark.skipif(not shutil.which("ansible-playbook") or not shutil.which("yq"), reason="ansible or yq missing")
def test_codex_drops_only_the_camofox_table(tmp_path):
    cfg = tmp_path / ".codex/config.toml"
    cfg.parent.mkdir()
    before = (
        'model = "gpt"\n\n[plugins."sites@openai-bundled"]\nenabled = true\n\n'
        '[mcp_servers.camofox-browser]\ncommand = "/opt/gone/camofox-browser-mcp-shared"\nargs = ["codex"]\n\n'
        '[mcp_servers.other]\ncommand = "other"\n'
    )
    cfg.write_text(before)
    _run_tasks(tmp_path, ["Drop Codex's dead camofox entry"])
    after = tomllib.loads(cfg.read_text())
    assert after["mcp_servers"] == {"other": {"command": "other"}}
    assert after["plugins"]["sites@openai-bundled"]["enabled"] is True
    assert "changed=0" in _run_tasks(tmp_path, ["Drop Codex's dead camofox entry"])


@pytest.mark.skipif(not shutil.which("ansible-playbook") or not shutil.which("yq"), reason="ansible or yq missing")
def test_hermes_line_lands_under_mcp_servers_once(tmp_path):
    cfg = tmp_path / ".hermes/config.yaml"
    cfg.parent.mkdir()
    cfg.write_text("browser:\n  inactivity_timeout: 120\nmcp_servers:\n  agent-tincan:\n    command: /x/tincan\n    enabled: true\ncron:\n  model: m\n")
    names = ["Look for Hermes' chrome-devtools entry", "Add the chrome-devtools entry under Hermes' mcp_servers"]
    _run_tasks(tmp_path, names)
    text = cfg.read_text()
    assert text.count("chrome-devtools:") == 1
    assert text.index("mcp_servers:") < text.index("chrome-devtools:") < text.index("cron:")
    assert "agent-tincan:" in text
    _run_tasks(tmp_path, names)
    assert cfg.read_text() == text
    if shutil.which("yq"):
        servers = json.loads(subprocess.run(["yq", "-o=json", ".mcp_servers", str(cfg)], capture_output=True, text=True, check=True).stdout)
        assert servers["chrome-devtools"] == {"command": f"{tmp_path}/.local/bin/chrome-devtools-mcp", "args": ARGS, "enabled": True}
