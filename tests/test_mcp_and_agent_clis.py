"""The play's MCP and agent-CLI tasks, and the guard that the browser wiring stays out.

The drive entry, the Codex cleanup and the Hermes cron store are edited in
nish's home, so every static assertion here is about the shape of those tasks
and the real tasks run twice against temp copies: the second run changes
nothing, and other entries and keys survive.

The browser tool has no owner (fleet-ops#10208): the chrome-devtools mod left
the nish-mods marketplace, so the pin, the seven per-agent server writes and
the Claude worker lane's allowed-tool entry were the same glue the audit
removed. The second half of this file is the detector for that removal: the
files stay deleted, no task writes a browser server into any agent config, the
play retires what the host still holds, and no file outside ALLOWED_TO_NAME
names the removed wiring again.
"""
import json
import pathlib
import re
import shutil
import subprocess
import tomllib

import pytest
import ansible_host

if not shutil.which("yq"):
    pytest.skip("yq missing", allow_module_level=True)

ROOT = pathlib.Path(__file__).resolve().parents[1]
HOST = ROOT / "ansible/host.yml"
DRIVE_PIN = ROOT / "config/drive-mcp.json"

REMOVED_FILES = (
    "config/chrome-devtools-mcp/package.json",
    "config/chrome-devtools-mcp/package-lock.json",
    "config/worker-mcp.json",
    "rootfs/etc/claude-code/managed-settings.d/60-chrome-devtools.json",
    "rootfs/etc/tmpfiles.d/chrome-devtools-profiles.conf",
)
REMOVED_HOST_PATHS = (
    "{{ nish_home }}/.local/bin/chrome-devtools-mcp",
    "{{ nish_home }}/.local/share/chrome-devtools-mcp",
    "/etc/tmpfiles.d/chrome-devtools-profiles.conf",
)
WIRING_TOKENS = (
    "chrome_devtools_mcp",
    "chrome-devtools-mcp",
    "chrome-devtools@nish-mods",
    "mcp__chrome-devtools",
    "puppeteer_dev_chrome_profile",
)
ALLOWED_TO_NAME = (
    "tests/test_mcp_and_agent_clis.py",
    "tests/test_claude_lanes.py",
    "docs/browser-tool.md",
    ".github/gitleaks-private-detail.toml",
    "ansible/host.yml",
)


def shutil_which(name):
    import shutil

    return shutil.which(name)


def _play():
    out = subprocess.run(["yq", "-o=json", "."], input=ansible_host.text(), capture_output=True, text=True, check=True).stdout
    return json.loads(out)[0]


PLAY = _play()
VARS = PLAY["vars"]
TASKS = {t["name"]: t for t in PLAY["tasks"]}


def test_no_runtime_fetch():
    text = ansible_host.text()
    assert "@latest" not in text and "npx" not in text


def test_every_task_is_an_ansible_core_module():
    for task in PLAY["tasks"]:
        modules = [k for k in task if "." in k]
        assert all(k.startswith("ansible.builtin.") for k in modules), (task["name"], modules)


def test_every_task_the_play_still_runs_is_listed():
    for name in (
        "Read Claude Code's drive entry",
        "Drop a stale drive entry",
        "Pin the Drive filesystem server in Claude Code's user config",
        "Drop Codex's dead camofox entry and its subtables",
        "Create Codex's rules directory",
        "Install the Codex execpolicy floor",
        "Read Hermes' config",
        "Install the Bot Desktop packages Hermes computer_use needs on a headless host",
        "Let Hermes start its own headless Bot Desktop when computer_use needs a display",
        "Read Hermes' scheduled jobs",
        "Delete the retired jobs from Hermes' cron store",
        "Apply config/hermes/digest-*.md to the live digest jobs",
        "Read Hermes' scheduled jobs again",
        "Link the packaged gh into nish's ~/.local/bin",
    ):
        assert name in TASKS, name


USER_FILE_TASKS = [
    "Read Claude Code's drive entry",
    "Drop a stale drive entry",
    "Pin the Drive filesystem server in Claude Code's user config",
    "Look for Codex's config",
    "Drop Codex's dead camofox entry and its subtables",
    "Create Codex's rules directory",
    "Install the Codex execpolicy floor",
    "Read Hermes' config",
    "Let Hermes start its own headless Bot Desktop when computer_use needs a display",
    "Read Hermes' scheduled jobs",
    "Delete the retired jobs from Hermes' cron store",
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
                "Create Codex's rules directory",
                "Install the Codex execpolicy floor",
                "Check whether Hermes has its cua-driver",
                "Install Hermes' pinned cua-driver",
                "Let Hermes start its own headless Bot Desktop when computer_use needs a display",
                "Look for the agent state directories",
                "Look for a plaintext git credential file in nish's home",
                "Fail the run when a plaintext git credential file is in the way",
                "Copy runner 1 to the pilot user once",
                "Point the pilot runner links at the copy",
                "Copy the review runners to the review user once",
                "Point the review runner links at the copy",
                "Point the review runner PATH at the bound tool directories",
            ), task["name"]
    for name in ("Look for the agent state directories", "Keep the agent state directories private"):
        task = TASKS[name]
        assert task.get("become") is True and task.get("become_user") == "nish", name
        for module in task.values():
            if isinstance(module, dict):
                assert module.get("follow") is not True, name
                assert "owner" not in module and "group" not in module, name


def test_mcp_tasks_run_after_the_handler_flush_and_before_the_credential_assert():
    names = [t["name"] for t in PLAY["tasks"]]
    flush = names.index("Apply pending handlers before the credential check")
    assert_at = names.index("Fail when an alertmanager credential file is missing")
    assert [n for n in names if n in USER_FILE_TASKS] == USER_FILE_TASKS
    assert flush < min(names.index(n) for n in USER_FILE_TASKS)
    assert max(names.index(n) for n in USER_FILE_TASKS) < assert_at


def test_agent_cli_tasks_are_bounded():
    for name in ("Read Claude Code's drive entry", "Drop a stale drive entry", "Pin the Drive filesystem server in Claude Code's user config"):
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
        task.pop("notify", None)
        for key in ("owner", "group"):
            for module in task.values():
                if isinstance(module, dict):
                    module.pop(key, None)
        tasks.append(task)
    vars_text = json.dumps(VARS)
    for old, new in subs.items():
        vars_text = vars_text.replace(old, new)
    play = {"hosts": "localhost", "connection": "local", "gather_facts": False, "vars": {**json.loads(vars_text), "nish_home": str(tmp_path)}, "tasks": tasks}
    book = tmp_path / "play.json"
    book.write_text(json.dumps([play]))
    result = subprocess.run(
        ["ansible-playbook", "-i", "localhost,", str(book)],
        capture_output=True, text=True, cwd=tmp_path, env={"PATH": "/usr/bin:/bin:/usr/local/bin", "HOME": str(tmp_path), "ANSIBLE_NOCOLOR": "1"},
    )
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout


def test_the_drive_entry_is_one_exact_pin_and_nothing_else():
    entry = json.loads(DRIVE_PIN.read_text())["mcpServers"]["drive"]
    assert entry["type"] == "stdio" and entry["command"] == "npx" and entry["env"] == {}
    assert entry["args"][0] == "-y"
    assert re.fullmatch(r"@modelcontextprotocol/server-filesystem@\d+\.\d+\.\d+", entry["args"][1])
    assert entry["args"][2] == "~/Drive"
    text = HOST.read_text()
    assert "config/drive-mcp.json" in text and "server-filesystem" not in text and "npx" not in text


def test_the_play_writes_the_drive_entry_with_claudes_own_mcp_command():
    assert "drive_mcp_words: \"{{ [drive_mcp_entry.command] + (drive_mcp_entry.args | map('replace', '~', nish_home) | list) }}\"" in HOST.read_text()
    read = TASKS["Read Claude Code's drive entry"]
    assert read["ansible.builtin.command"]["argv"] == ["{{ nish_home }}/.local/bin/claude", "mcp", "get", "drive"]
    assert read["changed_when"] is False and read["failed_when"] is False
    drop = TASKS["Drop a stale drive entry"]
    assert drop["ansible.builtin.command"]["argv"] == ["{{ nish_home }}/.local/bin/claude", "mcp", "remove", "drive", "--scope", "user"]
    assert "drive_entry.rc == 0" in drop["when"]
    add = TASKS["Pin the Drive filesystem server in Claude Code's user config"]
    assert add["ansible.builtin.command"]["argv"] == "{{ [nish_home ~ '/.local/bin/claude', 'mcp', 'add', '--scope', 'user', 'drive', '--'] + drive_mcp_words }}"
    assert "drive_entry.rc != 0" in add["when"]
    for task in (read, drop, add):
        assert task["timeout"] <= 120, task["name"]


@pytest.mark.skipif(not shutil_which("ansible-playbook") or not shutil_which("yq"), reason="ansible or yq missing")
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


@pytest.mark.skipif(not shutil_which("ansible-playbook"), reason="ansible missing")
def test_codex_drops_the_camofox_subtables_too(tmp_path):
    cfg = tmp_path / ".codex/config.toml"
    cfg.parent.mkdir()
    cfg.write_text(
        '[mcp_servers.camofox-browser]\ncommand = "gone"\n\n[mcp_servers.camofox-browser.env]\nA = "b"\n\n'
        '[mcp_servers.camofox-browser-keep]\ncommand = "keep"\n\n[mcp_servers.other.env]\nC = "d"\n'
    )
    _run_tasks(tmp_path, ["Look for Codex's config", "Drop Codex's dead camofox entry and its subtables"])
    assert tomllib.loads(cfg.read_text())["mcp_servers"] == {"camofox-browser-keep": {"command": "keep"}, "other": {"env": {"C": "d"}}}


@pytest.mark.skipif(not shutil_which("ansible-playbook"), reason="ansible missing")
def test_codex_without_a_config_is_not_an_error(tmp_path):
    _run_tasks(tmp_path, ["Look for Codex's config", "Drop Codex's dead camofox entry and its subtables"])
    assert not (tmp_path / ".codex").exists()


def test_pi_lane_passes_no_flag_that_hides_the_shared_configs():
    text = (ROOT / ".github/workflows/agent.yml").read_text()
    for line in re.findall(r"pi --print --no-context-files.*", text):
        assert not re.search(r"--(config|no-mcp|no-extensions)\b|\s-ne\b", line), line


@pytest.mark.skipif(not shutil_which("ansible-playbook") or not shutil_which("yq"), reason="ansible or yq missing")
def test_pilot_runner_copy_fills_an_empty_destination_and_never_clobbers_a_live_copy(tmp_path):
    src = tmp_path / ".local/share/agent-runner/1"
    (src / "bin.2.338.0").mkdir(parents=True)
    (src / "bin.2.338.0/Runner.Listener").write_text("listener")
    (src / "externals.2.338.0").mkdir()
    (src / "runsvc.sh").write_text("run")
    (src / "bin").symlink_to(src / "bin.2.338.0")
    (src / "externals").symlink_to(src / "externals.2.338.0")
    dest = tmp_path / "var/lib/fleet-runner/1"
    dest.mkdir(parents=True)
    names = ["Copy runner 1 to the pilot user once", "Read the pilot runner links", "Point the pilot runner links at the copy"]
    subs = {"/var/lib/fleet-runner": str(tmp_path / "var/lib/fleet-runner")}
    _run_tasks(tmp_path, names, subs)
    assert (dest / "runsvc.sh").read_text() == "run"
    assert (dest / "bin").readlink().as_posix() == "bin.2.338.0"
    assert (dest / "externals").readlink().as_posix() == "externals.2.338.0"
    assert (dest / "bin/Runner.Listener").read_text() == "listener"
    (dest / "runsvc.sh").write_text("live state")
    (src / "runsvc.sh").write_text("changed upstream")
    assert "changed=0" in _run_tasks(tmp_path, names, subs)
    assert (dest / "runsvc.sh").read_text() == "live state"


@pytest.mark.skipif(not shutil_which("ansible-playbook") or not shutil_which("yq"), reason="ansible or yq missing")
def test_pilot_runner_env_gets_its_own_home_and_loses_nish_paths(tmp_path):
    dest = tmp_path / "var/lib/fleet-runner/1"
    dest.mkdir(parents=True)
    env = dest / ".env"
    env.write_text("HOME=/home/nish\nXDG_RUNTIME_DIR=/run/user/1000\nLANG=C.UTF-8\nCLAUDE_CONFIG_DIR=/home/nish/.claude-a\n")
    names = ["Give the pilot runner its own HOME in the runner environment", "Drop nish's runtime paths from the pilot runner environment"]
    subs = {"/var/lib/fleet-runner": str(tmp_path / "var/lib/fleet-runner")}
    _run_tasks(tmp_path, names, subs)
    assert env.read_text() == f"HOME={tmp_path}/var/lib/fleet-runner\nLANG=C.UTF-8\n"
    assert "changed=0" in _run_tasks(tmp_path, names, subs)


def test_the_removed_wiring_files_stay_deleted():
    for rel in REMOVED_FILES:
        assert not (ROOT / rel).exists(), rel
    assert not (ROOT / "config/chrome-devtools-mcp").exists()


def test_no_task_writes_a_browser_server_into_any_agent_config():
    tasks = json.dumps(PLAY["tasks"])
    for token in WIRING_TOKENS:
        assert token not in tasks, token


def test_the_play_names_the_browser_wiring_only_in_its_retired_list():
    hits = [line for line in HOST.read_text().splitlines() if "chrome-devtools" in line]
    assert hits
    assert all(line.lstrip().startswith(("-", "#")) for line in hits), hits


def test_the_play_retires_the_binary_the_install_tree_and_the_tmpfiles_lines():
    retired = VARS["retired"]
    for path in REMOVED_HOST_PATHS:
        assert path in retired, path
    names = [path for path in retired if "chrome-devtools" in path]
    assert names.index("{{ nish_home }}/.local/bin/chrome-devtools-mcp") < names.index("{{ nish_home }}/.local/share/chrome-devtools-mcp")


def test_the_claude_worker_lane_serves_no_browser_server():
    lane = re.search(r"claude -p --continue.*?try\.out", (ROOT / ".github/workflows/agent.yml").read_text(), re.S).group(0)
    flat = " ".join(lane.replace("\\\n", " ").split())
    assert "--mcp-config" not in flat
    assert "--strict-mcp-config --disable-slash-commands --setting-sources project,local" in flat
    assert "mcp__" not in flat


def test_the_decision_is_written_down_in_one_place():
    doc = (ROOT / "docs/browser-tool.md").read_text()
    assert "#10208" in doc
    assert "owner: none" in doc.lower()
    assert (ROOT / "README.md").read_text().count("docs/browser-tool.md") == 1


def test_no_file_outside_the_allowlist_names_the_removed_wiring():
    found = {}
    for path in sorted(ROOT.rglob("*")):
        if not path.is_file() or ".git" in path.parts or "__pycache__" in path.parts or ".pytest_cache" in path.parts:
            continue
        rel = path.relative_to(ROOT).as_posix()
        if rel in ALLOWED_TO_NAME:
            continue
        try:
            text = path.read_text(errors="ignore")
        except OSError:
            continue
        hits = [token for token in WIRING_TOKENS if token in text]
        if hits:
            found[rel] = hits
    assert found == {}, found
