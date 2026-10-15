"""The Command Code CLI gets its key from COMMAND_CODE_API_KEY, loaded from the box's seat file.

cmd checks COMMAND_CODE_API_KEY before ~/.commandcode/auth.json. The seat file
holds the key as COMMANDCODE_API_KEY, the name the LiteLLM router reads, so
host.yml adds a second line with the CLI's name and a block in nish's zsh and
bash startup files exports only that one variable. The real Ansible tasks run
against a temp home with a fake key.
"""
import json
import os
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
SEAT_NAME = "Give the Command Code seat the COMMAND_CODE_API_KEY name that cmd reads"
SHELL_NAME = "Export COMMAND_CODE_API_KEY from the seat in nish's zsh and bash startup files"
DROP_NAME = "Drop the COMMAND_CODE_API_KEY line when the seat no longer has COMMANDCODE_API_KEY"
NAMES = ["Read the Command Code seat", SEAT_NAME, DROP_NAME, SHELL_NAME]
MARK_BEGIN = "# BEGIN fleet-ops: COMMAND_CODE_API_KEY for cmd, read from the seat"
MARK_END = "# END fleet-ops: COMMAND_CODE_API_KEY for cmd, read from the seat"
BASHRC = "# ~/.bashrc: executed by bash(1) for non-login shells.\ncase $- in\n    *i*) ;;\n      *) return;;\nesac\nexport INTERACTIVE_ONLY=1\n"
CLEAN_ENV = {"PATH": "/usr/bin:/bin:/usr/local/bin"}


def _strip(task):
    task.pop("become", None)
    task.pop("become_user", None)


def _unhide(task):
    task["no_log"] = False


def _play():
    out = subprocess.run(["yq", "-o=json", ".", str(HOST)], capture_output=True, text=True, check=True).stdout
    return json.loads(out)[0]


PLAY = _play()
TASKS = {t["name"]: t for t in PLAY["tasks"]}


def _book(home, hide=True, names=NAMES):
    tasks = []
    for name in names:
        task = json.loads(json.dumps(TASKS[name]))
        _strip(task)
        if not hide:
            _unhide(task)
        tasks.append(task)
    play = {"hosts": "localhost", "connection": "local", "gather_facts": False, "vars": {**PLAY["vars"], "nish_home": str(home)}, "tasks": tasks}
    book = home / "play.json"
    book.write_text(json.dumps([play]))
    return book


def _run(home, extra=()):
    result = subprocess.run(
        ["ansible-playbook", "-i", "localhost,", *extra, str(_book(home))],
        capture_output=True, text=True, cwd=home, env={**CLEAN_ENV, "HOME": str(home), "ANSIBLE_NOCOLOR": "1"},
    )
    assert result.returncode == 0, result.stdout.replace(FAKE, "<key>") + result.stderr.replace(FAKE, "<key>")
    return result.stdout + result.stderr


def _seat_path(home):
    return home / ".config" / "fleet-ops" / "seats" / "commandcode.env"


def _seat(home, text, mode=0o600):
    seat = _seat_path(home)
    seat.parent.mkdir(parents=True, exist_ok=True)
    seat.write_text(text)
    seat.chmod(mode)
    return seat


def _mode(path):
    return stat.S_IMODE(path.stat().st_mode)


def _block(home, name=".zshenv"):
    text = (home / name).read_text()
    assert text.count(MARK_BEGIN) == 1 and text.count(MARK_END) == 1
    return text.split(MARK_BEGIN + "\n")[1].split(MARK_END)[0]


def _start(home, argv, script):
    return subprocess.run(
        [*argv, script], capture_output=True, text=True, env={**CLEAN_ENV, "HOME": str(home)},
    )


def test_tasks_run_as_nish_with_stock_modules_and_hide_the_key():
    for name in NAMES:
        task = TASKS[name]
        assert task.get("become") is True and task.get("become_user") == "nish", name
        assert "owner" not in json.dumps(task) and "group" not in json.dumps(task), name
        assert [k for k in task if "." in k][0].startswith("ansible.builtin."), name
    assert all(TASKS[n]["no_log"] is True for n in NAMES[:3])
    assert "ignore_errors" not in json.dumps([TASKS[n] for n in NAMES])
    names = [t["name"] for t in PLAY["tasks"]]
    assert [n for n in names if n in NAMES] == NAMES
    assert names.index(NAMES[-1]) < names.index("Fail when an alertmanager credential file is missing")
    assert ".commandcode" not in HOST.read_text()


@pytest.mark.parametrize("line", [f"COMMANDCODE_API_KEY={FAKE}", f"export COMMANDCODE_API_KEY={FAKE}", f'COMMANDCODE_API_KEY="{FAKE}"', f"COMMANDCODE_API_KEY='{FAKE}'"])
def test_seat_gets_the_cli_name_once_with_the_same_value(tmp_path, line):
    seat = _seat(tmp_path, f"OTHER=1\n# COMMANDCODE_API_KEY=commented\n{line}\n")
    _run(tmp_path)
    lines = seat.read_text().splitlines()
    assert lines.count(f"COMMAND_CODE_API_KEY={FAKE}") == 1
    assert sum(1 for x in lines if x.removeprefix("export ").startswith("COMMAND_CODE_API_KEY=")) == 1
    assert line in lines and "OTHER=1" in lines


def test_seat_update_is_idempotent_and_keeps_mode(tmp_path):
    seat = _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n", mode=0o640)
    owner = seat.stat().st_uid
    _run(tmp_path)
    first = seat.read_bytes()
    out = _run(tmp_path)
    assert seat.read_bytes() == first
    assert first.count(b"COMMAND_CODE_API_KEY=") == 1
    assert _mode(seat) == 0o640 and seat.stat().st_uid == owner
    seat_step = out.split(f"TASK [{SEAT_NAME}]")[1].split("TASK [")[0]
    assert "ok: [localhost]" in seat_step


def test_a_stale_cli_name_value_is_replaced_not_duplicated(tmp_path):
    seat = _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\nCOMMAND_CODE_API_KEY=user_old\n")
    _run(tmp_path)
    assert seat.read_text().count("COMMAND_CODE_API_KEY=") == 1
    assert "user_old" not in seat.read_text()
    assert f"\nCOMMAND_CODE_API_KEY={FAKE}\n" in seat.read_text()


def test_missing_seat_or_source_var_skips_cleanly(tmp_path):
    _run(tmp_path)
    assert not _seat_path(tmp_path).exists()
    seat = _seat(tmp_path, "OTHER=1\nCOMMANDCODE_API_KEY=\n")
    _run(tmp_path)
    assert seat.read_text() == "OTHER=1\nCOMMANDCODE_API_KEY=\n"


def test_revoking_the_source_var_drops_the_derived_line(tmp_path):
    seat = _seat(tmp_path, f"OTHER=1\nCOMMANDCODE_API_KEY={FAKE}\n")
    _run(tmp_path)
    assert f"COMMAND_CODE_API_KEY={FAKE}" in seat.read_text()
    seat.write_text(f"OTHER=1\nCOMMANDCODE_API_KEY=\nCOMMAND_CODE_API_KEY={FAKE}\n")
    _run(tmp_path)
    assert seat.read_text() == "OTHER=1\nCOMMANDCODE_API_KEY=\n"
    seat.write_text(f"OTHER=1\nCOMMAND_CODE_API_KEY={FAKE}\n")
    out = _run(tmp_path)
    assert seat.read_text() == "OTHER=1\n" and FAKE not in out
    assert "changed=0" in _run(tmp_path)


def test_key_never_reaches_ansible_output(tmp_path):
    seat = _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    out = _run(tmp_path, extra=("-vvv", "--diff"))
    assert FAKE not in out
    assert f"COMMAND_CODE_API_KEY={FAKE}" in seat.read_text()


def test_startup_block_is_in_both_files_once_and_idempotent(tmp_path):
    (tmp_path / ".bashrc").write_text(BASHRC)
    (tmp_path / ".bashrc").chmod(0o600)
    _run(tmp_path)
    zsh_text = (tmp_path / ".zshenv").read_text()
    bash_text = (tmp_path / ".bashrc").read_text()
    assert zsh_text.count(MARK_BEGIN) == 1 and bash_text.count(MARK_BEGIN) == 1
    assert bash_text.index(MARK_END) < bash_text.index("case $-")
    assert bash_text.endswith(BASHRC)
    out = _run(tmp_path)
    assert (tmp_path / ".zshenv").read_text() == zsh_text and (tmp_path / ".bashrc").read_text() == bash_text
    assert "changed=0" in out
    assert _mode(tmp_path / ".bashrc") == 0o600


def test_startup_block_exports_only_the_one_variable_and_never_prints_the_key():
    block = PLAY["vars"]["commandcode_shell_block"]
    assert block.count(" export ") == 1 and " export COMMAND_CODE_API_KEY=" in block
    assert "echo" not in block and "printf" not in block and "set -x" not in block
    assert "sed" not in block and "tail" not in block and "tr " not in block
    assert "COMMANDCODE_API_KEY" not in block


@pytest.mark.parametrize("quoted", ["{k}", '"{k}"', "'{k}'", "{k}\n#", "export COMMAND_CODE_API_KEY={k}"])
def test_sourcing_the_block_yields_the_value_and_prints_nothing(tmp_path, quoted):
    _seat(tmp_path, f"OTHER=secret_other\nCOMMANDCODE_API_KEY={FAKE}\n")
    _run(tmp_path)
    seat = _seat_path(tmp_path)
    line = quoted.format(k=FAKE)
    line = line if line.startswith("export ") else "COMMAND_CODE_API_KEY=" + line
    seat.write_text(f"OTHER=secret_other\nCOMMANDCODE_API_KEY={FAKE}\n{line}")
    env_dump = "env | cut -d= -f1 | sort"
    for argv in (["zsh", "-f", "-c"], ["sh", "-c"], ["bash", "-c"]):
        before = _start(tmp_path, argv, env_dump).stdout.split()
        got = _start(tmp_path, argv, f'. "$HOME/.zshenv"; printf %s "$COMMAND_CODE_API_KEY"; echo; {env_dump}')
        assert got.stderr == "", argv
        lines = got.stdout.splitlines()
        assert lines[0] == FAKE, argv
        added = set(lines[1:]) - set(before)
        assert added == {"COMMAND_CODE_API_KEY"}, (argv, added)
        quiet = _start(tmp_path, argv, '. "$HOME/.zshenv"')
        assert quiet.stdout == "" and quiet.stderr == "", argv


def test_startup_files_load_the_key_in_the_shells_agents_use(tmp_path):
    (tmp_path / ".bashrc").write_text(BASHRC)
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    _run(tmp_path)
    probe = 'printf %s "$COMMAND_CODE_API_KEY"'
    zsh = _start(tmp_path, ["zsh", "-c"], probe)
    assert zsh.stdout == FAKE and zsh.stderr == ""
    bash = _start(tmp_path, ["bash", "-c"], f'. "$HOME/.bashrc"; {probe}; printf " %s" "$INTERACTIVE_ONLY"')
    assert bash.stdout == FAKE + " " and bash.stderr == ""
    exported = _start(tmp_path, ["bash", "-c"], f". \"$HOME/.bashrc\"; env | grep -c '^COMMAND_CODE_API_KEY='")
    assert exported.stdout.strip() == "1"


def test_absent_seat_or_key_exports_nothing_and_does_not_error(tmp_path):
    _run(tmp_path)
    for argv in (["zsh", "-f", "-c"], ["sh", "-c"], ["bash", "-c"], ["zsh", "-c"]):
        got = _start(tmp_path, argv, '. "$HOME/.zshenv" 2>&1; printf "[%s]" "${COMMAND_CODE_API_KEY-unset}"')
        assert got.stdout == "[unset]" and got.returncode == 0, argv
    _seat(tmp_path, f"OTHER=1\nCOMMANDCODE_API_KEY={FAKE}\n")
    got = _start(tmp_path, ["sh", "-c"], '. "$HOME/.zshenv"; printf "[%s]" "${COMMAND_CODE_API_KEY-unset}"')
    assert got.stdout == "[unset]" and got.stderr == ""
    _seat(tmp_path, "COMMAND_CODE_API_KEY=\n")
    got = _start(tmp_path, ["sh", "-c"], '. "$HOME/.zshenv"; printf "[%s]" "${COMMAND_CODE_API_KEY-unset}"')
    assert got.stdout == "[unset]"
    _seat(tmp_path, f"COMMAND_CODE_API_KEY={FAKE}\n", mode=0o000)
    if os.geteuid() != 0:
        got = _start(tmp_path, ["sh", "-c"], '. "$HOME/.zshenv"; printf "[%s]" "${COMMAND_CODE_API_KEY-unset}"')
        assert got.stdout == "[unset]" and got.stderr == ""
