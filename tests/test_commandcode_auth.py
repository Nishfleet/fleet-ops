"""The Command Code CLI gets its key from COMMAND_CODE_API_KEY, loaded from the box's seat file.

cmd checks COMMAND_CODE_API_KEY before its own login store, and `cmd login` is
an interactive browser flow that Ansible cannot run and that mints a second
key, so the supported env var is the route (the reviewer of fleet-ops#9767
chose it over a hand-written ~/.commandcode/auth.json). The seat file holds the
key as COMMANDCODE_API_KEY, the name the LiteLLM router reads and this play
leaves alone. A marked block in nish's zsh and bash startup files reads that
line from the seat on every shell start and exports only COMMAND_CODE_API_KEY,
so a rotated seat is live in the next shell and no second copy of the key
exists. The real Ansible task runs against a temp home with a fake key.
"""
import json
import pathlib
import shutil
import stat
import subprocess

import pytest

if not shutil.which("yq") or not shutil.which("ansible-playbook"):
    pytest.skip("yq or ansible missing", allow_module_level=True)

ROOT = pathlib.Path(__file__).resolve().parents[1]
HOST = ROOT / "ansible/host.yml"
FAKE = "user_fake0123456789abcdef"
NAME = "Export COMMAND_CODE_API_KEY from the seat in nish's zsh and bash startup files"
MARK_BEGIN = "# BEGIN fleet-ops: COMMAND_CODE_API_KEY for cmd, from COMMANDCODE_API_KEY in the seat"
MARK_END = "# END fleet-ops: COMMAND_CODE_API_KEY for cmd, from COMMANDCODE_API_KEY in the seat"
BASHRC = "# ~/.bashrc: executed by bash(1) for non-login shells.\ncase $- in\n    *i*) ;;\n      *) return;;\nesac\nexport INTERACTIVE_ONLY=1\n"
CLEAN_ENV = {"PATH": "/usr/bin:/bin:/usr/local/bin"}
SHELLS = (["zsh", "-f", "-c"], ["zsh", "-c"], ["sh", "-c"], ["bash", "-c"])


def _play():
    out = subprocess.run(["yq", "-o=json", ".", str(HOST)], capture_output=True, text=True, check=True).stdout
    return json.loads(out)[0]


PLAY = _play()
TASKS = {t["name"]: t for t in PLAY["tasks"]}


def _run(home, extra=()):
    task = json.loads(json.dumps(TASKS[NAME]))
    task.pop("become", None)
    task.pop("become_user", None)
    play = {"hosts": "localhost", "connection": "local", "gather_facts": False, "vars": {**PLAY["vars"], "nish_home": str(home)}, "tasks": [task]}
    book = home / "play.json"
    book.write_text(json.dumps([play]))
    result = subprocess.run(
        ["ansible-playbook", "-i", "localhost,", *extra, str(book)],
        capture_output=True, text=True, cwd=home, env={**CLEAN_ENV, "HOME": str(home), "ANSIBLE_NOCOLOR": "1"},
    )
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout + result.stderr


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


def test_task_runs_as_nish_with_a_stock_module_and_touches_no_seat_or_login_file():
    task = TASKS[NAME]
    assert task["become"] is True and task["become_user"] == "nish"
    assert "owner" not in json.dumps(task) and "group" not in json.dumps(task) and "mode" not in json.dumps(task)
    assert [k for k in task if "." in k] == ["ansible.builtin.blockinfile"]
    assert "ignore_errors" not in json.dumps(task)
    names = [t["name"] for t in PLAY["tasks"]]
    assert names.index(NAME) < names.index("Fail when an alertmanager credential file is missing")
    text = HOST.read_text()
    assert ".commandcode" not in text and "commandcode.env\"\n        state" not in text
    assert "seats" not in json.dumps([t for t in PLAY["tasks"] if t["name"] != NAME])


def test_block_is_in_both_files_once_idempotent_and_keeps_existing_modes(tmp_path):
    (tmp_path / ".bashrc").write_text(BASHRC)
    (tmp_path / ".bashrc").chmod(0o600)
    _run(tmp_path)
    zsh_text = (tmp_path / ".zshenv").read_text()
    bash_text = (tmp_path / ".bashrc").read_text()
    assert zsh_text.count(MARK_BEGIN) == 1 and zsh_text.count(MARK_END) == 1
    assert bash_text.count(MARK_BEGIN) == 1 and bash_text.endswith(BASHRC)
    assert bash_text.index(MARK_END) < bash_text.index("case $-")
    out = _run(tmp_path)
    assert "changed=0" in out
    assert (tmp_path / ".zshenv").read_text() == zsh_text and (tmp_path / ".bashrc").read_text() == bash_text
    assert _mode(tmp_path / ".bashrc") == 0o600


def test_block_exports_only_the_one_variable_and_never_prints():
    block = PLAY["vars"]["commandcode_shell_block"]
    assert block.count(" export ") == 1 and " export COMMAND_CODE_API_KEY=" in block
    for word in ("echo", "printf", "set -x", "sed", "tail", "eval", "source", "curl"):
        assert word not in block
    assert not any(line.startswith(". ") or " . " in line for line in block.splitlines())


@pytest.mark.parametrize("form", ["{k}", '"{k}"', "'{k}'", "export {k}"])
def test_sourcing_the_block_yields_the_value_and_adds_only_that_variable(tmp_path, form):
    value = form.format(k=FAKE)
    line = ("export COMMANDCODE_API_KEY=" + FAKE) if form.startswith("export") else "COMMANDCODE_API_KEY=" + value
    _seat(tmp_path, f"# COMMANDCODE_API_KEY=commented\nOTHER=secret_other\n{line}")
    _run(tmp_path)
    env_names = "env | cut -d= -f1 | sort"
    for argv in SHELLS:
        bare = tmp_path / "bare"
        bare.mkdir(exist_ok=True)
        before = _start(bare, argv, env_names).stdout.split()
        got = _start(tmp_path, argv, f'. "$HOME/.zshenv"; printf %s "$COMMAND_CODE_API_KEY"; echo; {env_names}')
        assert got.stderr == "", argv
        lines = got.stdout.splitlines()
        assert lines[0] == FAKE, argv
        assert set(lines[1:]) - set(before) == {"COMMAND_CODE_API_KEY"}, argv
        quiet = _start(tmp_path, argv, '. "$HOME/.zshenv"')
        assert quiet.stdout == "" and quiet.stderr == "", argv


def test_a_rotated_seat_is_live_in_the_next_shell(tmp_path):
    seat = _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    _run(tmp_path)
    assert _start(tmp_path, ["sh", "-c"], PROBE).stdout == f"[{FAKE}]"
    seat.write_text("COMMANDCODE_API_KEY=user_rotated\n")
    assert _start(tmp_path, ["sh", "-c"], PROBE).stdout == "[user_rotated]"
    seat.write_text("COMMANDCODE_API_KEY=\n")
    assert _start(tmp_path, ["sh", "-c"], PROBE).stdout == "[unset]"


def test_the_last_line_wins_and_a_trailing_line_without_newline_is_read(tmp_path):
    _seat(tmp_path, "COMMANDCODE_API_KEY=user_first\nCOMMANDCODE_API_KEY=user_second")
    _run(tmp_path)
    for argv in SHELLS:
        assert _start(tmp_path, argv, PROBE).stdout == "[user_second]", argv


def test_startup_files_load_the_key_in_the_shells_agents_use(tmp_path):
    (tmp_path / ".bashrc").write_text(BASHRC)
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    _run(tmp_path)
    probe = 'printf %s "$COMMAND_CODE_API_KEY"'
    zsh = _start(tmp_path, ["zsh", "-c"], probe)
    assert zsh.stdout == FAKE and zsh.stderr == ""
    bash = _start(tmp_path, ["bash", "-c"], f'. "$HOME/.bashrc"; {probe}; printf " %s" "$INTERACTIVE_ONLY"')
    assert bash.stdout == FAKE + " " and bash.stderr == ""
    exported = _start(tmp_path, ["bash", "-c"], ". \"$HOME/.bashrc\"; env | grep -c '^COMMAND_CODE_API_KEY='")
    assert exported.stdout.strip() == "1"


def test_absent_seat_or_key_exports_nothing_and_does_not_error(tmp_path):
    _run(tmp_path)
    for argv in SHELLS:
        got = _start(tmp_path, argv, PROBE + " 2>&1")
        assert got.stdout == "[unset]" and got.stderr == "" and got.returncode == 0, argv
    for text in ("OTHER=1\n", "COMMANDCODE_API_KEY=\n", f"COMMAND_CODE_API_KEY={FAKE}\n", "COMMANDCODE_API_KEY=''\n"):
        _seat(tmp_path, text)
        got = _start(tmp_path, ["sh", "-c"], PROBE)
        assert got.stdout == "[unset]" and got.stderr == "", text
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n", mode=0o000)
    got = _start(tmp_path, ["sh", "-c"], PROBE)
    assert got.stdout == "[unset]" and got.stderr == ""


@pytest.mark.parametrize("value", ["a$(touch pwned)b", "a`touch pwned`b", "a;touch pwned;b", "a$HOMEb&c|d", "a b"])
def test_shell_metacharacters_in_the_value_are_data_not_code(tmp_path, value):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={value}\n")
    _run(tmp_path)
    for argv in SHELLS:
        got = _start(tmp_path, argv, '. "$HOME/.zshenv"; printf %s "$COMMAND_CODE_API_KEY"')
        assert got.stdout == value and got.stderr == "", argv
    assert not (tmp_path / "pwned").exists()


def test_the_play_never_shows_the_key(tmp_path):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    out = _run(tmp_path, extra=("-vvv", "--diff"))
    assert FAKE not in out
    assert FAKE not in (tmp_path / ".zshenv").read_text()
