"""The Command Code key has one name, COMMAND_CODE_API_KEY, the one the CLI reads.

cmd checks COMMAND_CODE_API_KEY before its own login store, and `cmd login` is
an interactive browser flow that Ansible cannot run and that mints a second
key, so the supported env var is the route (the reviewer of fleet-ops#9767
chose it over a hand-written ~/.commandcode/auth.json). The seat used to name
the key COMMANDCODE_API_KEY, so one play task renames that line and the
LiteLLM quadlet and config read the new name. Nish's zsh and bash startup
files source the seat with allexport, which exports every NAME=VALUE line of
it; the seat holds only that key and a play task asserts it holds nothing but
NAME=VALUE lines. The real Ansible tasks run against a temp home with a fake key.
"""
import json
import pathlib
import re
import shutil
import stat
import subprocess

import pytest

if not shutil.which("yq") or not shutil.which("ansible-playbook") or not shutil.which("zsh"):
    pytest.skip("yq, ansible or zsh missing", allow_module_level=True)

ROOT = pathlib.Path(__file__).resolve().parents[1]
HOST = ROOT / "ansible/host.yml"
FAKE = "user_fake0123456789abcdef"
STAT = "Look for the Command Code seat"
READ = "Read the Command Code seat"
CHECK = "Require the Command Code seat to hold only NAME=VALUE lines (shells source it)"
RENAME = "Rename COMMANDCODE_API_KEY to COMMAND_CODE_API_KEY in the Command Code seat"
LIVE = "Look for the new name in the live LiteLLM config"
RESTART = "Restart the LiteLLM proxy so it reads the renamed seat line"
SHELL = "Export the Command Code seat in nish's zsh and bash startup files"
SEAT_TASKS = [STAT, READ, CHECK, RENAME]
MARK_BEGIN = "# BEGIN fleet-ops: Command Code seat for cmd"
MARK_END = "# END fleet-ops: Command Code seat for cmd"
BASHRC = "# ~/.bashrc: executed by bash(1) for non-login shells.\ncase $- in\n    *i*) ;;\n      *) return;;\nesac\nexport INTERACTIVE_ONLY=1\n"
CLEAN_ENV = {"PATH": "/usr/bin:/bin:/usr/local/bin"}
SHELLS = (["zsh", "-f", "-c"], ["zsh", "-c"], ["sh", "-c"], ["bash", "-c"])
OLD = "COMMANDCODE_API_KEY"
NEW = "COMMAND_CODE_API_KEY"


def _play():
    out = subprocess.run(["yq", "-o=json", ".", str(HOST)], capture_output=True, text=True, check=True).stdout
    return json.loads(out)[0]


PLAY = _play()
TASKS = {t["name"]: t for t in PLAY["tasks"]}


def _run(home, names, extra=(), ok=True):
    tasks = []
    for name in names:
        task = json.loads(json.dumps(TASKS[name]))
        task.pop("become", None)
        task.pop("become_user", None)
        tasks.append(task)
    play = {"hosts": "localhost", "connection": "local", "gather_facts": False, "vars": {**PLAY["vars"], "nish_home": str(home)}, "tasks": tasks}
    book = home / "play.json"
    book.write_text(json.dumps([play]))
    result = subprocess.run(
        ["ansible-playbook", "-i", "localhost,", *extra, str(book)],
        capture_output=True, text=True, cwd=home, env={**CLEAN_ENV, "HOME": str(home), "ANSIBLE_NOCOLOR": "1"},
    )
    out = (result.stdout + result.stderr).replace(FAKE, "<key>")
    assert (result.returncode == 0) == ok, out
    return out


def _seat(home, text, mode=0o600):
    seat = home / ".config" / "fleet-ops" / "seats" / "commandcode.env"
    seat.parent.mkdir(parents=True, exist_ok=True)
    seat.write_text(text)
    seat.chmod(mode)
    return seat


def _mode(path):
    return stat.S_IMODE(path.stat().st_mode)


def _start(home, argv, script):
    return subprocess.run([*argv, script], capture_output=True, text=True, env={**CLEAN_ENV, "HOME": str(home)})


PROBE = '. "$HOME/.zshenv"; printf "[%s]" "${COMMAND_CODE_API_KEY-unset}"'


def test_one_name_everywhere():
    pattern = re.compile(r"\bCOMMANDCODE_API_KEY\b")
    for path in ROOT.rglob("*"):
        if not path.is_file() or ".git" in path.parts or path.suffix in (".png", ".pyc") or path == pathlib.Path(__file__):
            continue
        try:
            text = path.read_text()
        except UnicodeDecodeError:
            continue
        if pattern.search(text):
            assert path == HOST, path
    quadlet = (ROOT / "containers/quadlet/fleet-litellm-proxy.container").read_text()
    assert f"PodmanArgs=--env={NEW}\n" in quadlet
    config = (ROOT / "config/litellm-proxy.yaml").read_text()
    assert config.count(f"os.environ/{NEW}") == 4
    for line in HOST.read_text().splitlines():
        if OLD in line:
            assert "name:" in line or "regexp:" in line, line


def test_tasks_run_as_nish_with_stock_modules_and_hide_the_key():
    for name in [STAT, READ, RENAME, LIVE, SHELL]:
        task = TASKS[name]
        assert task["become"] is True and task["become_user"] == "nish", name
        assert "owner" not in json.dumps(task) and "group" not in json.dumps(task) and "mode" not in json.dumps(task), name
    for name in [READ, CHECK, RENAME]:
        assert TASKS[name]["no_log"] is True, name
    for name in [READ, RENAME]:
        assert TASKS[name]["diff"] is False, name
    assert [k for k in TASKS[RENAME] if "." in k] == ["ansible.builtin.replace"]
    assert [k for k in TASKS[SHELL] if "." in k] == ["ansible.builtin.blockinfile"]
    assert "ignore_errors" not in json.dumps([TASKS[n] for n in SEAT_TASKS + [LIVE, RESTART, SHELL]])
    names = [t["name"] for t in PLAY["tasks"]]
    order = [STAT, READ, CHECK, RENAME, LIVE, RESTART, SHELL]
    assert [n for n in names if n in order] == order
    assert names.index(SHELL) < names.index("Fail when an alertmanager credential file is missing")
    assert names.index("Apply pending handlers before the credential check") < names.index(STAT)


def test_proxy_restart_only_after_a_real_rename_and_only_once_the_live_config_has_the_new_name():
    restart = TASKS[RESTART]
    assert restart["when"] == "commandcode_seat_renamed is changed and litellm_live_new_name.rc == 0"
    assert "try-restart" in restart["ansible.builtin.command"] and "fleet-litellm-proxy.service" in restart["ansible.builtin.command"]
    live = TASKS[LIVE]["ansible.builtin.command"]["argv"]
    assert live[:2] == ["/usr/bin/grep", "-qF"] and live[2] == f"os.environ/{NEW}"
    assert TASKS[LIVE]["failed_when"] is False and TASKS[LIVE]["changed_when"] is False


@pytest.mark.parametrize("prefix", ["", "export "])
def test_seat_line_is_renamed_once_idempotently_keeping_mode(tmp_path, prefix):
    seat = _seat(tmp_path, f"# {OLD}=commented\nOTHER=1\n{prefix}{OLD}={FAKE}\n", mode=0o640)
    owner = seat.stat().st_uid
    _run(tmp_path, SEAT_TASKS)
    assert seat.read_text() == f"# {OLD}=commented\nOTHER=1\n{prefix}{NEW}={FAKE}\n"
    assert _mode(seat) == 0o640 and seat.stat().st_uid == owner
    out = _run(tmp_path, SEAT_TASKS)
    assert "changed=0" in out
    assert seat.read_text().count(NEW) == 1


def test_missing_seat_or_already_renamed_seat_is_a_clean_skip(tmp_path):
    out = _run(tmp_path, SEAT_TASKS)
    assert "skipped=3" in out and not (tmp_path / ".config").exists()
    seat = _seat(tmp_path, f"{NEW}={FAKE}\n")
    assert "changed=0" in _run(tmp_path, SEAT_TASKS)
    assert seat.read_text() == f"{NEW}={FAKE}\n"


@pytest.mark.parametrize("line", ["curl x | sh", "A=$(id)", "A=`id`", "A=a;id", "A=a b", "A=a&b", "export A=b c", "A='a;b'", "1A=b", "A =b"])
def test_a_seat_with_anything_but_name_value_lines_fails_before_any_change(tmp_path, line):
    seat = _seat(tmp_path, f"{OLD}={FAKE}\n{line}\n")
    out = _run(tmp_path, SEAT_TASKS, ok=False)
    assert "NAME=VALUE" in out
    assert seat.read_text() == f"{OLD}={FAKE}\n{line}\n"


@pytest.mark.parametrize("text", [f"{OLD}={FAKE}\n", f"# note\n\n{OLD}={FAKE}", f'{OLD}="{FAKE}"\n', f"{OLD}='{FAKE}'\nexport OTHER=a.b:c/d+e=@%,-x\n"])
def test_a_seat_of_name_value_lines_passes_and_sourcing_it_is_safe(tmp_path, text):
    _seat(tmp_path, text)
    _run(tmp_path, SEAT_TASKS)
    seat_text = (tmp_path / ".config/fleet-ops/seats/commandcode.env").read_text()
    for line in seat_text.splitlines():
        assert re.fullmatch(PLAY["vars"]["commandcode_seat_line_re"], line), "a seat line is not NAME=VALUE"
    names = set(re.findall(r"^(?:export +)?([A-Za-z_][A-Za-z0-9_]*)=", seat_text, re.M))
    for argv in SHELLS:
        got = _start(tmp_path, argv, f'set -a; . "$HOME/.config/fleet-ops/seats/commandcode.env"; set +a; env | cut -d= -f1 | sort')
        assert got.stderr == "", argv
        assert names <= set(got.stdout.split()), argv


def test_block_is_in_both_files_once_idempotent_and_keeps_existing_modes(tmp_path):
    (tmp_path / ".bashrc").write_text(BASHRC)
    (tmp_path / ".bashrc").chmod(0o600)
    _run(tmp_path, [SHELL])
    zsh_text = (tmp_path / ".zshenv").read_text()
    bash_text = (tmp_path / ".bashrc").read_text()
    assert zsh_text.count(MARK_BEGIN) == 1 and zsh_text.count(MARK_END) == 1
    assert bash_text.count(MARK_BEGIN) == 1 and bash_text.endswith(BASHRC)
    assert bash_text.index(MARK_END) < bash_text.index("case $-")
    assert "changed=0" in _run(tmp_path, [SHELL])
    assert (tmp_path / ".zshenv").read_text() == zsh_text and (tmp_path / ".bashrc").read_text() == bash_text
    assert _mode(tmp_path / ".bashrc") == 0o600


def test_block_is_the_stock_env_file_load_and_prints_nothing():
    block = PLAY["vars"]["commandcode_shell_block"].strip().splitlines()
    assert [x.strip() for x in block] == [
        'if [ -r "$HOME/.config/fleet-ops/seats/commandcode.env" ]; then',
        "set -a",
        '. "$HOME/.config/fleet-ops/seats/commandcode.env"',
        "set +a",
        "fi",
    ]


@pytest.mark.parametrize("form", ["{k}", '"{k}"', "'{k}'", "export {k}"])
def test_sourcing_the_block_yields_the_value_adds_only_the_seat_names_and_prints_nothing(tmp_path, form):
    value = form.format(k=FAKE)
    line = f"export {OLD}={FAKE}" if form.startswith("export") else f"{OLD}={value}"
    _seat(tmp_path, f"# {OLD}=commented\n{line}\n")
    _run(tmp_path, SEAT_TASKS + [SHELL])
    env_names = "env | cut -d= -f1 | sort"
    bare = tmp_path / "bare"
    bare.mkdir()
    for argv in SHELLS:
        before = _start(bare, argv, env_names).stdout.split()
        got = _start(tmp_path, argv, f'. "$HOME/.zshenv"; printf %s "${NEW}"; echo; {env_names}')
        assert got.stderr == "", argv
        lines = got.stdout.splitlines()
        assert lines[0] == FAKE, argv
        assert set(lines[1:]) - set(before) == {NEW}, argv
        quiet = _start(tmp_path, argv, '. "$HOME/.zshenv"')
        assert quiet.stdout == "" and quiet.stderr == "" and quiet.returncode == 0, argv


def test_startup_files_load_the_key_in_the_shells_agents_use(tmp_path):
    (tmp_path / ".bashrc").write_text(BASHRC)
    _seat(tmp_path, f"{NEW}={FAKE}\n")
    _run(tmp_path, [SHELL])
    probe = f'printf %s "${NEW}"'
    zsh = _start(tmp_path, ["zsh", "-c"], probe)
    assert zsh.stdout == FAKE and zsh.stderr == ""
    bash = _start(tmp_path, ["bash", "-c"], f'. "$HOME/.bashrc"; {probe}; printf " %s" "$INTERACTIVE_ONLY"')
    assert bash.stdout == FAKE + " " and bash.stderr == ""
    exported = _start(tmp_path, ["bash", "-c"], f'. "$HOME/.bashrc"; env | grep -c "^{NEW}="')
    assert exported.stdout.strip() == "1"


def test_a_rotated_seat_is_live_in_the_next_shell(tmp_path):
    seat = _seat(tmp_path, f"{NEW}={FAKE}\n")
    _run(tmp_path, [SHELL])
    assert _start(tmp_path, ["sh", "-c"], PROBE).stdout == f"[{FAKE}]"
    seat.write_text(f"{NEW}=user_rotated\n")
    assert _start(tmp_path, ["sh", "-c"], PROBE).stdout == "[user_rotated]"


def test_absent_or_unreadable_seat_exports_nothing_and_does_not_error(tmp_path):
    _run(tmp_path, [SHELL])
    for argv in SHELLS:
        got = _start(tmp_path, argv, PROBE)
        assert got.stdout == "[unset]" and got.stderr == "" and got.returncode == 0, argv
    for text, shown in (("OTHER=1\n", "[unset]"), (f"{NEW}=\n", "[]")):
        _seat(tmp_path, text)
        got = _start(tmp_path, ["sh", "-c"], PROBE)
        assert got.stdout == shown and got.stderr == "" and got.returncode == 0, text
    _seat(tmp_path, f"{NEW}={FAKE}\n", mode=0o000)
    got = _start(tmp_path, ["sh", "-c"], "set -e; " + PROBE)
    assert got.stdout == "[unset]" and got.stderr == "" and got.returncode == 0


def test_the_play_never_shows_the_key(tmp_path):
    _seat(tmp_path, f"{OLD}={FAKE}\n")
    out = _run(tmp_path, SEAT_TASKS + [LIVE, SHELL], extra=("-vvv", "--diff"))
    assert FAKE not in out and "<key>" not in out
    assert FAKE not in (tmp_path / ".zshenv").read_text()
