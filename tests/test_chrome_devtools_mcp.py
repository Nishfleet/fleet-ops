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

if not shutil.which("yq"):
    pytest.skip("yq missing", allow_module_level=True)

ROOT = pathlib.Path(__file__).resolve().parents[1]
HOST = ROOT / "ansible/host.yml"
PIN_DIR = ROOT / "config/chrome-devtools-mcp"
REQUIRED = ["--headless", "--isolated", "--executablePath", "/usr/bin/google-chrome", "--no-usage-statistics", "--no-performance-crux"]


def _play():
    out = subprocess.run(["yq", "-o=json", ".", str(HOST)], capture_output=True, text=True, check=True).stdout
    return json.loads(out)[0]


PLAY = _play()
VARS = PLAY["vars"]
ARGS = VARS["chrome_devtools_mcp_args"]
TASKS = {t["name"]: t for t in PLAY["tasks"]}


def test_version_is_one_exact_pin_with_a_lockfile():
    manifest = json.loads((PIN_DIR / "package.json").read_text())
    version = manifest["dependencies"]["chrome-devtools-mcp"]
    assert list(manifest["dependencies"]) == ["chrome-devtools-mcp"]
    assert re.fullmatch(r"\d+\.\d+\.\d+", version)
    lock = json.loads((PIN_DIR / "package-lock.json").read_text())
    assert lock["lockfileVersion"] == 3
    assert lock["packages"][""]["dependencies"] == {"chrome-devtools-mcp": version}
    assert lock["packages"]["node_modules/chrome-devtools-mcp"]["version"] == version
    for path, entry in lock["packages"].items():
        if path:
            assert entry["integrity"].startswith("sha512-") and entry["resolved"].startswith("https://registry.npmjs.org/"), path
    assert "chrome_devtools_mcp_version" not in VARS
    pins = [
        p for p in ROOT.rglob("*")
        if p.is_file() and ".git" not in p.parts and "__pycache__" not in p.parts and PIN_DIR not in p.parents and p != pathlib.Path(__file__)
        and re.search(r"chrome-devtools-mcp(@|\s+version)", p.read_text(errors="ignore"))
    ]
    assert pins == [], f"the version string belongs in config/chrome-devtools-mcp only: {pins}"


def test_install_is_an_ansible_core_module_from_the_lockfile():
    for task in PLAY["tasks"]:
        modules = [k for k in task if "." in k]
        assert all(k.startswith("ansible.builtin.") for k in modules), (task["name"], modules)
    install = TASKS["Install the pinned Chrome DevTools MCP server from the lockfile"]
    argv = install["ansible.builtin.command"]["argv"]
    assert argv[1:3] == ["ci", "--ignore-scripts"] and argv[0].endswith("/.local/bin/npm")
    assert install["ansible.builtin.command"]["chdir"] == "{{ chrome_devtools_mcp_dir }}"
    assert "chrome_devtools_pins.changed" in install["when"] and "chrome_devtools_installed" in install["when"]


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
        "Install the pinned Chrome DevTools MCP server from the lockfile",
        "Install the OpenCode managed config",
        "Read the shared MCP config",
        "Install the shared MCP config (Pi reads it through pi-mcp-adapter)",
        "Add the chrome-devtools entry to each agent CLI",
        "Swap Cursor's dead camofox entry for chrome-devtools",
        "Drop Codex's dead camofox entry and its subtables",
        "Add the chrome-devtools entry under Hermes' mcp_servers",
    ):
        assert name in TASKS, name


USER_FILE_TASKS = [
    "Create the Chrome DevTools MCP install directory",
    "Copy the Chrome DevTools MCP package.json and package-lock.json",
    "Look for the installed Chrome DevTools MCP server",
    "Install the pinned Chrome DevTools MCP server from the lockfile",
    "Link the Chrome DevTools MCP server into nish's ~/.local/bin",
    "Create the shared MCP config directory",
    "Read the shared MCP config",
    "Install the shared MCP config (Pi reads it through pi-mcp-adapter)",
    "Read each agent CLI's chrome-devtools entry",
    "Drop a stale chrome-devtools entry",
    "Add the chrome-devtools entry to each agent CLI",
    "Read Cursor's MCP config",
    "Swap Cursor's dead camofox entry for chrome-devtools",
    "Look for Codex's config",
    "Drop Codex's dead camofox entry and its subtables",
    "Read Hermes' config",
    "Add the chrome-devtools entry under Hermes' mcp_servers",
    "Read Hermes' scheduled jobs",
    "Apply config/hermes/digest-*.md to the live digest jobs",
    "Read Hermes' scheduled jobs again",
    "Link the packaged gh into nish's ~/.local/bin",
]


def test_every_task_that_touches_nishs_home_runs_as_nish_not_root():
    for name in USER_FILE_TASKS:
        task = TASKS[name]
        assert task.get("become") is True and task.get("become_user") == "nish", name
        for module in task.values():
            if isinstance(module, dict):
                assert module.get("follow") is not True, name
                assert "owner" not in module and "group" not in module, name
    for task in PLAY["tasks"]:
        if "nish_home" in json.dumps(task) and task["name"] not in USER_FILE_TASKS:
            assert task["name"] in (
                "Create the OpenCode managed config directory",
                "Install the OpenCode managed config",
                "Create Codex's rules directory",
                "Install the Codex execpolicy floor",
                "Check whether Hermes has its cua-driver",
                "Install Hermes' pinned cua-driver",
                "Let Hermes start its own headless Bot Desktop when computer_use needs a display",
            ), task["name"]


def test_chrome_tasks_run_after_the_handler_flush_and_before_the_credential_assert():
    names = [t["name"] for t in PLAY["tasks"]]
    flush = names.index("Apply pending handlers before the credential check")
    assert_at = names.index("Fail when an alertmanager credential file is missing")
    assert [n for n in names if n in USER_FILE_TASKS] == USER_FILE_TASKS
    assert flush < min(names.index(n) for n in USER_FILE_TASKS)
    assert max(names.index(n) for n in USER_FILE_TASKS) < assert_at


def test_agent_cli_tasks_are_bounded():
    for name in ("Read each agent CLI's chrome-devtools entry", "Drop a stale chrome-devtools entry", "Add the chrome-devtools entry to each agent CLI"):
        assert TASKS[name]["timeout"] <= 120, name


def test_fleet_sync_fast_forwards_claude_mods_and_fails_loud():
    lines = [l for l in (ROOT / "systemd/fleet-sync.service").read_text().splitlines() if "claude-mods" in l and l.startswith("ExecStart")]
    assert [l.split(" ", 1)[0] for l in lines] == ["ExecStart=/usr/bin/git"] * 2
    assert " fetch --no-tags origin refs/heads/main:refs/remotes/origin/main" in lines[0]
    assert lines[1].endswith(" merge --ff-only refs/remotes/origin/main")
    assert not any(" pull" in l for l in lines)


def _run_tasks(tmp_path, names, subs=None):
    subs = subs or {}
    tasks = []
    for name in names:
        text = json.dumps(TASKS[name])
        for old, new in subs.items():
            text = text.replace(old, new)
        task = json.loads(text)
        task.pop("become", None)
        task.pop("become_user", None)
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
        "Read the shared MCP config",
        "Install the shared MCP config (Pi reads it through pi-mcp-adapter)",
    ]
    subs = {"/etc/opencode": str(tmp_path / "etc/opencode")}
    (tmp_path / "etc").mkdir()
    (tmp_path / ".config/mcp").mkdir(parents=True)
    (tmp_path / ".config/mcp/mcp.json").write_text(json.dumps({"mcpServers": {"kept": {"url": "https://example.invalid/mcp"}}, "settings": {"x": 1}}))
    _run_tasks(tmp_path, names, subs)
    bin_path = f"{tmp_path}/.local/bin/chrome-devtools-mcp"
    entry = json.loads((tmp_path / "etc/opencode/opencode.json").read_text())["mcp"]["chrome-devtools"]
    assert entry == {"type": "local", "command": [bin_path, *ARGS], "enabled": True}
    whole = json.loads((tmp_path / ".config/mcp/mcp.json").read_text())
    assert whole["mcpServers"]["chrome-devtools"] == {"command": bin_path, "args": ARGS, "lifecycle": "lazy", "idleTimeout": 5}
    assert whole["mcpServers"]["kept"] == {"url": "https://example.invalid/mcp"} and whole["settings"] == {"x": 1}
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
    names = ["Look for Codex's config", "Drop Codex's dead camofox entry and its subtables"]
    _run_tasks(tmp_path, names)
    after = tomllib.loads(cfg.read_text())
    assert after["mcp_servers"] == {"other": {"command": "other"}}
    assert after["plugins"]["sites@openai-bundled"]["enabled"] is True
    assert "changed=0" in _run_tasks(tmp_path, names)


@pytest.mark.skipif(not shutil.which("ansible-playbook"), reason="ansible missing")
def test_codex_drops_the_camofox_subtables_too(tmp_path):
    cfg = tmp_path / ".codex/config.toml"
    cfg.parent.mkdir()
    cfg.write_text(
        '[mcp_servers.camofox-browser]\ncommand = "gone"\n\n[mcp_servers.camofox-browser.env]\nA = "b"\n\n'
        '[mcp_servers.camofox-browser-keep]\ncommand = "keep"\n\n[mcp_servers.other.env]\nC = "d"\n'
    )
    _run_tasks(tmp_path, ["Look for Codex's config", "Drop Codex's dead camofox entry and its subtables"])
    assert tomllib.loads(cfg.read_text())["mcp_servers"] == {"camofox-browser-keep": {"command": "keep"}, "other": {"env": {"C": "d"}}}


@pytest.mark.skipif(not shutil.which("ansible-playbook"), reason="ansible missing")
def test_codex_without_a_config_is_not_an_error(tmp_path):
    _run_tasks(tmp_path, ["Look for Codex's config", "Drop Codex's dead camofox entry and its subtables"])
    assert not (tmp_path / ".codex").exists()


@pytest.mark.skipif(not shutil.which("ansible-playbook") or not shutil.which("yq"), reason="ansible or yq missing")
def test_hermes_line_lands_under_mcp_servers_once(tmp_path):
    cfg = tmp_path / ".hermes/config.yaml"
    cfg.parent.mkdir()
    cfg.write_text("browser:\n  inactivity_timeout: 120\nmcp_servers:\n  agent-tincan:\n    command: /x/tincan\n    enabled: true\ncron:\n  model: m\n")
    names = ["Read Hermes' config", "Add the chrome-devtools entry under Hermes' mcp_servers"]
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


def test_claude_worker_lane_loads_the_browser_server_and_nothing_else():
    shipped = json.loads((ROOT / "config/worker-mcp.json").read_text())
    assert shipped == {"mcpServers": {"chrome-devtools": {"type": "stdio", "command": pathlib.Path(VARS["chrome_devtools_mcp_bin"]).name, "args": ARGS}}}
    lane = re.search(r"claude -p --continue.*?try\.out", (ROOT / ".github/workflows/agent.yml").read_text(), re.S).group(0)
    flat = " ".join(lane.replace("\\\n", " ").split())
    assert '--mcp-config "$HOME/workspaces/tooling/fleet-ops-deploy-clone/config/worker-mcp.json" --strict-mcp-config' in flat


def test_other_worker_lanes_pass_no_flag_that_hides_the_shared_configs():
    text = (ROOT / ".github/workflows/agent.yml").read_text()
    for lane in (r"devin -p --prompt-file.*", r"opencode run --dir.*", r"pi --print --no-context-files.*"):
        for line in re.findall(lane, text):
            assert not re.search(r"--(config|no-mcp|no-extensions)\b|\s-ne\b", line), line


@pytest.mark.skipif(not shutil.which("ansible-playbook") or not shutil.which("yq"), reason="ansible or yq missing")
def test_hermes_without_an_mcp_servers_key_is_left_alone(tmp_path):
    cfg = tmp_path / ".hermes/config.yaml"
    cfg.parent.mkdir()
    cfg.write_text("browser:\n  inactivity_timeout: 120\n")
    names = ["Read Hermes' config", "Add the chrome-devtools entry under Hermes' mcp_servers"]
    _run_tasks(tmp_path, names)
    assert cfg.read_text() == "browser:\n  inactivity_timeout: 120\n"
    cfg.write_text("mcp_servers: {}\ncron:\n  model: m\n")
    _run_tasks(tmp_path, names)
    assert cfg.read_text() == "mcp_servers: {}\ncron:\n  model: m\n"
    cfg.unlink()
    _run_tasks(tmp_path, names)
    assert not cfg.exists()


def test_orphaned_chrome_profiles_age_out():
    conf = (ROOT / "rootfs/etc/tmpfiles.d/chrome-devtools-profiles.conf").read_text().split()
    assert conf[:2] == ["e", "/tmp/puppeteer_dev_chrome_profile-*"] and conf[-1].endswith("d")


NEED_ANSIBLE = pytest.mark.skipif(not shutil.which("ansible-playbook"), reason="ansible missing")
INSTALL = [
    "Create the Chrome DevTools MCP install directory",
    "Copy the Chrome DevTools MCP package.json and package-lock.json",
    "Look for the installed Chrome DevTools MCP server",
    "Install the pinned Chrome DevTools MCP server from the lockfile",
    "Link the Chrome DevTools MCP server into nish's ~/.local/bin",
]


def _stub(path, body):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(0o755)


@NEED_ANSIBLE
def test_lockfile_install_runs_npm_ci_once_and_again_only_when_the_lock_changes(tmp_path):
    log = tmp_path / "npm.log"
    _stub(tmp_path / ".local/bin/npm", f'echo "$PWD $*" >> {log}\nmkdir -p node_modules/.bin\nprintf "#!/bin/sh\\n" > node_modules/.bin/chrome-devtools-mcp\nchmod +x node_modules/.bin/chrome-devtools-mcp\n')
    subs = {"{{ playbook_dir }}/../config": str(ROOT / "config")}
    _run_tasks(tmp_path, INSTALL, subs)
    install_dir = tmp_path / ".local/share/chrome-devtools-mcp"
    assert log.read_text().splitlines() == [f"{install_dir} ci --ignore-scripts --no-audit --no-fund"]
    assert (install_dir / "package-lock.json").read_text() == (PIN_DIR / "package-lock.json").read_text()
    assert (tmp_path / ".local/bin/chrome-devtools-mcp").resolve() == (install_dir / "node_modules/.bin/chrome-devtools-mcp").resolve()
    assert "changed=0" in _run_tasks(tmp_path, INSTALL, subs)
    assert len(log.read_text().splitlines()) == 1
    (install_dir / "package-lock.json").write_text("{}")
    _run_tasks(tmp_path, INSTALL, subs)
    assert len(log.read_text().splitlines()) == 2
    shutil.rmtree(install_dir / "node_modules")
    _run_tasks(tmp_path, INSTALL, subs)
    assert len(log.read_text().splitlines()) == 3


AGENT_CLI = [
    "Read each agent CLI's chrome-devtools entry",
    "Drop a stale chrome-devtools entry",
    "Add the chrome-devtools entry to each agent CLI",
]


def _fake_cli(tmp_path, name, style):
    state = tmp_path / f"{name}.state"
    calls = tmp_path / f"{name}.calls"
    show = {
        "line": 'echo "Command: $(cat %s)"' % state,
        "lines": 'echo "Args:"; for a in $(cat %s); do echo "  - $a"; done' % state,
    }[style]
    _stub(
        tmp_path / f".local/bin/{name}",
        f'echo "$1 $2" >> {calls}\n'
        f'case "$2" in\n'
        f'  get) test -s {state} || exit 1; {show};;\n'
        f'  remove) : > {state};;\n'
        f'  add) shift 6; echo "$@" > {state};;\n'
        f'esac\n',
    )
    return state, calls


@NEED_ANSIBLE
@pytest.mark.parametrize("style", ["line", "lines"])
def test_devin_and_cmd_entries_converge_in_any_output_format_and_missing_cli_is_skipped(tmp_path, style):
    state, calls = _fake_cli(tmp_path, "devin", style)
    _run_tasks(tmp_path, AGENT_CLI)
    want = " ".join([f"{tmp_path}/.local/bin/chrome-devtools-mcp", *ARGS])
    assert state.read_text().strip() == want
    assert calls.read_text().split("\n")[:-1] == ["mcp get", "mcp add"]
    assert "changed=0" in _run_tasks(tmp_path, AGENT_CLI)
    assert calls.read_text().split("\n")[:-1] == ["mcp get", "mcp add", "mcp get"]
    state.write_text(want.replace("--headless", "--headed") + "\n")
    _run_tasks(tmp_path, AGENT_CLI)
    assert state.read_text().strip() == want
    assert calls.read_text().split("\n")[:-1][3:] == ["mcp get", "mcp remove", "mcp add"]
    assert not (tmp_path / ".local/bin/cmd").exists()
