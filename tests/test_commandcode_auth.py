"""The Command Code CLI is logged in from the box's seat file, the way pasting the key in /connect would.

cmd reads ~/.commandcode/auth.json (flat JSON, apiKey among other keys, mode
0600; the vendor text says "paste the key in /connect (stored in
~/.commandcode/auth.json)"). That file is read only by cmd, so the key is not
in the environment of any other process. The seat file holds the key as
COMMANDCODE_API_KEY, the name the LiteLLM router reads and this play leaves
alone. The play writes apiKey only when the login has none, so a login made by
`cmd login` is never replaced. The real Ansible tasks run against a temp home
with a fake key.
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
OTHER = "user_made_by_cmd_login"
EMPTY_NOTE = "is not a readable JSON object; treating it as empty"
WARNING = "exists but could not be read"
STAT = "Look for the Command Code seat"
READ = "Read the Command Code seat (an unreadable seat is a warning, not a silent skip)"
DIR = "Create the Command Code login directory"
LOGIN = "Read the Command Code login"
PARSE = "Parse the Command Code login (an unreadable file counts as empty, as it does for cmd)"
STORE = "Store the seat's key as the Command Code login when it has none (a login cmd made is never replaced)"
MODE = "Keep the Command Code login at mode 0600 when it already holds the seat's key"
NAMES = [STAT, READ, DIR, LOGIN, PARSE, STORE, MODE]
HIDDEN = [READ, DIR, LOGIN, STORE, MODE]


def _walk(task, fn):
    fn(task)
    for part in ("block", "rescue", "always"):
        for inner in task.get(part, []):
            _walk(inner, fn)


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


def _book(home, hide):
    tasks = []
    for name in NAMES:
        task = json.loads(json.dumps(TASKS[name]))
        _walk(task, _strip)
        if not hide:
            _walk(task, _unhide)
        tasks.append(task)
    play = {"hosts": "localhost", "connection": "local", "gather_facts": False, "vars": {**PLAY["vars"], "nish_home": str(home)}, "tasks": tasks}
    book = home / "play.json"
    book.write_text(json.dumps([play]))
    return book


def _run(home, hide=False, extra=()):
    result = subprocess.run(
        ["ansible-playbook", "-i", "localhost,", *extra, str(_book(home, hide))],
        capture_output=True, text=True, cwd=home, env={"PATH": "/usr/bin:/bin:/usr/local/bin", "HOME": str(home), "ANSIBLE_NOCOLOR": "1"},
    )
    out = (result.stdout + result.stderr).replace(FAKE, "<key>")
    assert result.returncode == 0, out
    return result.stdout + result.stderr


def _seat(home, text, mode=0o600):
    seat = home / ".config" / "fleet-ops" / "seats" / "commandcode.env"
    seat.parent.mkdir(parents=True, exist_ok=True)
    seat.write_text(text)
    seat.chmod(mode)
    return seat


def _auth(home):
    return home / ".commandcode/auth.json"


def _login(home, content, mode=0o600):
    _auth(home).parent.mkdir(mode=0o700, exist_ok=True)
    _auth(home).write_text(content if isinstance(content, str) else json.dumps(content))
    _auth(home).chmod(mode)


def _mode(path):
    return stat.S_IMODE(path.stat().st_mode)


def test_every_login_task_runs_as_nish_and_hides_the_key():
    for name in [STAT, DIR, LOGIN, STORE, MODE]:
        task = TASKS[name]
        assert task.get("become") is True and task.get("become_user") == "nish", name
        assert "owner" not in json.dumps(task) and "group" not in json.dumps(task), name
        assert all(k.startswith("ansible.builtin.") for k in task if "." in k), name
    slurp = TASKS[READ]["block"][0]
    assert slurp["become"] is True and slurp["become_user"] == "nish"
    assert slurp["no_log"] is True and slurp["diff"] is False
    for name in [DIR, LOGIN, STORE, MODE]:
        assert TASKS[name]["no_log"] is True, name
    names = [t["name"] for t in PLAY["tasks"]]
    assert [n for n in names if n in NAMES] == NAMES
    assert names.index(MODE) < names.index("Fail when an alertmanager credential file is missing")


def test_no_step_hides_a_failure_with_ignore_errors_or_failed_when_false_on_the_seat():
    assert "ignore_errors" not in json.dumps([TASKS[n] for n in NAMES])
    assert "failed_when" not in json.dumps([TASKS[n] for n in (STAT, READ, DIR, STORE, MODE)])
    assert TASKS[READ]["when"] == "commandcode_seat_stat.stat.exists"
    said = TASKS[READ]["rescue"][0]
    assert WARNING in said["ansible.builtin.debug"]["msg"] and said["ansible.builtin.debug"]["msg"].startswith("WARNING")
    assert "commandcode_seat_key" not in json.dumps(said)


def test_parse_is_a_block_with_a_rescue():
    parse = TASKS[PARSE]
    assert parse["when"] == "commandcode_seat_key != ''"
    assert "ansible.builtin.set_fact" in parse["block"][0] and parse["block"][0]["no_log"] is True
    assert parse["block"][1]["ansible.builtin.assert"]["that"] == "commandcode_parsed is mapping"
    assert parse["block"][1]["no_log"] is True
    assert parse["rescue"][0]["ansible.builtin.set_fact"] == {"commandcode_parsed": {}}
    said = parse["rescue"][1]
    assert said.get("no_log") is not True
    assert "commandcode_seat_key" not in json.dumps(said) and "apiKey" not in json.dumps(said)
    assert "treating it as empty" in said["ansible.builtin.debug"]["msg"]


def test_login_writes_the_cli_shape_with_mode_0600(tmp_path):
    _seat(tmp_path, f"OTHER=1\nCOMMANDCODE_API_KEY={FAKE}\n")
    _run(tmp_path)
    assert json.loads(_auth(tmp_path).read_text()) == {"apiKey": FAKE}
    assert _mode(_auth(tmp_path)) == 0o600
    assert _mode(_auth(tmp_path).parent) == 0o700


@pytest.mark.parametrize("line", [f"COMMANDCODE_API_KEY={FAKE}", f"export COMMANDCODE_API_KEY={FAKE}", f'COMMANDCODE_API_KEY="{FAKE}"', f"COMMANDCODE_API_KEY='{FAKE}'"])
def test_seat_line_forms(tmp_path, line):
    _seat(tmp_path, f"# COMMANDCODE_API_KEY=commented\n{line}\n")
    _run(tmp_path)
    assert json.loads(_auth(tmp_path).read_text()) == {"apiKey": FAKE}


def test_second_run_changes_nothing(tmp_path):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    assert EMPTY_NOTE not in _run(tmp_path)
    before = _auth(tmp_path).read_bytes()
    out = _run(tmp_path)
    assert "changed=0" in out and EMPTY_NOTE not in out
    assert _auth(tmp_path).read_bytes() == before


@pytest.mark.parametrize("mode", [0o644, 0o666, 0o640, 0o400])
def test_a_matching_login_with_the_wrong_mode_is_fixed_and_left_otherwise_untouched(tmp_path, mode):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    text = json.dumps({"apiKey": FAKE, "userId": "u", "extra": 1}, indent=2)
    _login(tmp_path, text, mode=mode)
    _run(tmp_path)
    assert _mode(_auth(tmp_path)) == 0o600
    assert _auth(tmp_path).read_text() == text
    assert "changed=0" in _run(tmp_path)


def test_a_login_made_by_cmd_login_is_never_replaced(tmp_path):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    text = json.dumps({"apiKey": OTHER, "userId": "u", "userName": "nish", "keyName": "k", "authenticatedAt": "t"}, indent=2)
    _login(tmp_path, text, mode=0o600)
    out = _run(tmp_path)
    assert _auth(tmp_path).read_text() == text
    assert "changed=0" in out
    assert "changed=0" in _run(tmp_path)


def test_a_rotated_seat_key_does_not_replace_an_existing_login(tmp_path):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    _run(tmp_path)
    _seat(tmp_path, "COMMANDCODE_API_KEY=user_rotated\n")
    _run(tmp_path)
    assert json.loads(_auth(tmp_path).read_text()) == {"apiKey": FAKE}
    _auth(tmp_path).unlink()
    _run(tmp_path)
    assert json.loads(_auth(tmp_path).read_text()) == {"apiKey": "user_rotated"}


@pytest.mark.parametrize("login", [{"extra": 1}, {"apiKey": "", "extra": 1}, {"apiKey": None, "extra": 1}, {"userId": "u", "userName": "nish", "keyName": "k", "authenticatedAt": "t", "extra": 1}])
def test_a_login_without_an_api_key_gets_the_seat_key_and_keeps_other_keys_but_not_stale_identity(tmp_path, login):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    _login(tmp_path, login, mode=0o644)
    _run(tmp_path)
    assert json.loads(_auth(tmp_path).read_text()) == {"apiKey": FAKE, "extra": 1}
    assert _mode(_auth(tmp_path)) == 0o600
    assert "changed=0" in _run(tmp_path)


def test_missing_seat_or_key_skips_cleanly(tmp_path):
    out = _run(tmp_path)
    assert WARNING not in out
    assert not (tmp_path / ".commandcode").exists()
    _seat(tmp_path, "OTHER=1\nCOMMANDCODE_API_KEY=\n")
    out = _run(tmp_path)
    assert WARNING not in out
    assert not (tmp_path / ".commandcode").exists()


def test_an_unreadable_seat_is_a_warning_not_silence_and_writes_nothing(tmp_path):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n", mode=0o000)
    out = _run(tmp_path)
    assert WARNING in out and "WARNING:" in out
    assert FAKE not in out
    assert not (tmp_path / ".commandcode").exists()


def test_key_never_reaches_ansible_output_under_no_log(tmp_path):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    result = subprocess.run(
        ["ansible-playbook", "-i", "localhost,", "-vvv", "--diff", str(_book(tmp_path, hide=True))],
        capture_output=True, text=True, cwd=tmp_path, env={"PATH": "/usr/bin:/bin:/usr/local/bin", "HOME": str(tmp_path), "ANSIBLE_NOCOLOR": "1"},
    )
    assert result.returncode == 0
    assert FAKE not in result.stdout + result.stderr
    assert json.loads(_auth(tmp_path).read_text()) == {"apiKey": FAKE}


def test_a_login_file_that_is_not_an_object_is_replaced(tmp_path):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    _login(tmp_path, "[]")
    out = _run(tmp_path)
    assert EMPTY_NOTE in out
    assert json.loads(_auth(tmp_path).read_text()) == {"apiKey": FAKE}
    again = _run(tmp_path)
    assert "changed=0" in again and EMPTY_NOTE not in again


@pytest.mark.parametrize("broken", ['{"apiKey": "user_ol', "{", "not json", ""])
def test_a_truncated_login_file_is_replaced_and_the_run_still_succeeds(tmp_path, broken):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    _login(tmp_path, broken)
    out = _run(tmp_path)
    assert EMPTY_NOTE in out
    assert FAKE not in out
    assert json.loads(_auth(tmp_path).read_text()) == {"apiKey": FAKE}
    again = _run(tmp_path)
    assert "changed=0" in again and EMPTY_NOTE not in again
