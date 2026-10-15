"""The Command Code CLI is logged in from the box's seat file, the way pasting the key in /connect would.

cmd reads ~/.commandcode/auth.json (flat JSON, apiKey among other keys, mode
0600; the vendor text says "paste the key in /connect (stored in
~/.commandcode/auth.json)"). That file is read only by cmd, so the key is not
in the environment of any other process. The seat file holds the key as
COMMANDCODE_API_KEY, the name the LiteLLM router reads and this play leaves
alone. The play writes apiKey only when the login has none, never replaces a
login that cmd made, and leaves a login it cannot read or parse alone with a
warning; a final assert then fails the run (everything else has run by then),
so a broken login is not silent. `cmd login` has no key flag (its help lists
only [provider] and -h) and is an interactive browser flow, and the identity
keys dropped when the key is absent are the ones the CLI's own
storeCommandAuthCredentials writes (userId, userName, keyName, authenticatedAt).
The real Ansible tasks run against a temp home with a fake key.
"""
import functools
import json
import os
import pathlib
import shutil
import stat
import subprocess

import pytest

TOOLS = bool(shutil.which("yq") and shutil.which("ansible-playbook"))


@pytest.fixture(autouse=True)
def _tools():
    if not TOOLS:
        if os.environ.get("CI"):
            pytest.fail("yq and ansible-playbook are required in CI; these tests must not be skipped")
        pytest.skip("yq or ansible missing")

ROOT = pathlib.Path(__file__).resolve().parents[1]
HOST = ROOT / "ansible/host.yml"
FAKE = "user_fake0123456789abcdef"
OTHER = "user_made_by_cmd_login"
LEFT_ALONE = "leaving its content alone"
SEAT_WARNING = "exists but could not be read"
SETUP_WARNING = "could not set up the Command Code login"
STAT = "Look for the Command Code seat"
READ = "Read the Command Code seat (an unreadable seat is a warning, not a silent skip)"
LOGIN = "Log Command Code in from the seat (a problem is a warning here and fails the run after everything else ran)"
FINAL = "Fail when the Command Code login could not be set up"
NAMES = [STAT, READ, LOGIN, FINAL]
STORE = "Store the seat's key as the Command Code login when it has none (a login cmd made is never replaced)"
MODE = "Keep an existing Command Code login at mode 0600, whatever key it holds"
PARSE = "Parse the Command Code login (one that cannot be read or parsed is left alone)"
DIR = "Create the Command Code login directory"


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


@functools.cache
def _loaded():
    play = _play()
    tasks = {t["name"]: t for t in play["tasks"]}
    login = {t["name"]: t for t in tasks[LOGIN]["block"]}
    parse = login[PARSE]
    inner = {t["name"]: t for t in parse["block"]}
    return play, tasks, login, parse, inner


def _book(home, hide):
    tasks = []
    play, all_tasks, *_ = _loaded()
    for name in NAMES:
        task = json.loads(json.dumps(all_tasks[name]))
        _walk(task, _strip)
        if not hide:
            _walk(task, _unhide)
        tasks.append(task)
    doc = {"hosts": "localhost", "connection": "local", "gather_facts": False, "vars": {**play["vars"], "nish_home": str(home)}, "tasks": tasks}
    book = home / "play.json"
    book.write_text(json.dumps([doc]))
    return book


def _run(home, hide=False, extra=(), ok=True):
    result = subprocess.run(
        ["ansible-playbook", "-i", "localhost,", *extra, str(_book(home, hide))],
        capture_output=True, text=True, cwd=home, env={"PATH": "/usr/bin:/bin:/usr/local/bin", "HOME": str(home), "ANSIBLE_NOCOLOR": "1"},
    )
    out = (result.stdout + result.stderr).replace(FAKE, "<key>")
    assert (result.returncode == 0) == ok, out
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
    play, tasks, login, parse, inner = _loaded()
    slurp = tasks[READ]["block"][0]
    read_login = inner["Read the Command Code login"]
    for task in (tasks[STAT], login[DIR], slurp, read_login, login[STORE], login[MODE]):
        assert task.get("become") is True and task.get("become_user") == "nish", task["name"]
        assert "owner" not in json.dumps(task) and "group" not in json.dumps(task), task["name"]
        assert all(k.startswith("ansible.builtin.") for k in task if "." in k), task["name"]
    for task in (slurp, read_login, *[inner[n] for n in inner if n.startswith(("Decode", "Require"))], login[STORE], login[MODE]):
        assert task["no_log"] is True, task["name"]
    for task in (slurp, read_login, login[STORE]):
        assert task["diff"] is False, task["name"]
    names = [t["name"] for t in play["tasks"]]
    assert [n for n in names if n in NAMES] == NAMES
    assert names.index(LOGIN) < names.index("Fail when an alertmanager credential file is missing") < names.index(FINAL)
    assert names.index("Apply pending handlers before the credential check") < names.index(STAT)


def test_failures_are_warnings_then_one_final_assert_never_ignore_errors_or_failed_when():
    play, tasks, login, parse, inner = _loaded()
    text = json.dumps([tasks[n] for n in NAMES])
    assert "ignore_errors" not in text and "failed_when" not in text
    assert tasks[READ]["when"] == "commandcode_seat_stat.stat.exists"
    said = tasks[READ]["rescue"][0]["ansible.builtin.debug"]["msg"]
    assert SEAT_WARNING in said and said.startswith("WARNING")
    outer = tasks[LOGIN]["rescue"][0]
    assert SETUP_WARNING in outer["ansible.builtin.debug"]["msg"]
    assert "commandcode_seat_key" not in json.dumps(outer)
    for rescue in (tasks[READ]["rescue"], parse["rescue"], tasks[LOGIN]["rescue"]):
        assert any("commandcode_problems" in json.dumps(x) for x in rescue)
    assert tasks[FINAL]["ansible.builtin.assert"]["that"] == "commandcode_problems | default([]) | length == 0"


def test_parse_is_a_block_with_a_rescue_that_leaves_the_login_alone():
    play, tasks, login, parse, inner = _loaded()
    assert parse["when"] == "commandcode_auth_stat.stat.exists"
    assert inner["Require the Command Code login to be a JSON object"]["ansible.builtin.assert"]["that"] == "commandcode_parsed is mapping"
    assert parse["rescue"][0]["ansible.builtin.set_fact"] == {"commandcode_parsed": None}
    said = parse["rescue"][1]
    assert said.get("no_log") is not True
    assert "commandcode_seat_key" not in json.dumps(said) and "apiKey" not in json.dumps(said)
    assert LEFT_ALONE in said["ansible.builtin.debug"]["msg"]
    assert login[STORE]["when"] == "commandcode_parsed is mapping and commandcode_parsed.apiKey | default('', true) == ''"


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
    assert LEFT_ALONE not in _run(tmp_path)
    before = _auth(tmp_path).read_bytes()
    out = _run(tmp_path)
    assert "changed=0" in out and LEFT_ALONE not in out
    assert _auth(tmp_path).read_bytes() == before


@pytest.mark.parametrize("key", [FAKE, OTHER])
@pytest.mark.parametrize("mode", [0o644, 0o666, 0o640, 0o400])
def test_an_existing_login_gets_mode_0600_whatever_key_it_holds_and_its_content_is_untouched(tmp_path, key, mode):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    text = json.dumps({"apiKey": key, "userId": "u", "extra": 1}, indent=2)
    _login(tmp_path, text, mode=mode)
    _run(tmp_path)
    assert _mode(_auth(tmp_path)) == 0o600
    assert _auth(tmp_path).read_text() == text
    assert "changed=0" in _run(tmp_path)


def test_a_login_made_by_cmd_login_is_never_replaced(tmp_path):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    text = json.dumps({"apiKey": OTHER, "userId": "u", "userName": "nish", "keyName": "k", "authenticatedAt": "t"}, indent=2)
    _login(tmp_path, text)
    out = _run(tmp_path)
    assert _auth(tmp_path).read_text() == text
    assert "changed=0" in out


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


@pytest.mark.parametrize("broken", ['{"apiKey": "user_ol', "{", "not json", "", "[]", "null", '"text"', "3"])
def test_a_login_that_cannot_be_parsed_is_left_alone_with_a_warning(tmp_path, broken):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    _login(tmp_path, broken, mode=0o644)
    out = _run(tmp_path, ok=False)
    assert LEFT_ALONE in out and "WARNING:" in out and "Command Code login: the login file is not a readable JSON object" in out
    assert FAKE not in out
    assert _auth(tmp_path).read_text() == broken
    assert _mode(_auth(tmp_path)) == 0o600
    again = _run(tmp_path, ok=False)
    assert LEFT_ALONE in again and _auth(tmp_path).read_text() == broken


def test_a_login_the_user_cannot_read_is_left_alone_with_a_warning_not_replaced(tmp_path):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    _login(tmp_path, {"apiKey": OTHER}, mode=0o000)
    out = _run(tmp_path, ok=False)
    assert LEFT_ALONE in out and "WARNING:" in out and "Command Code login:" in out
    assert OTHER not in out and FAKE not in out
    assert _mode(_auth(tmp_path)) == 0o600
    assert json.loads(_auth(tmp_path).read_text()) == {"apiKey": OTHER}


def test_a_login_directory_that_cannot_be_made_is_a_warning_and_the_run_succeeds(tmp_path):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    (tmp_path / ".commandcode").write_text("a regular file where the directory should be")
    out = _run(tmp_path, ok=False)
    assert SETUP_WARNING in out and "WARNING:" in out and "Command Code login: the login could not be set up at step: Create the Command Code login directory" in out
    assert FAKE not in out
    assert (tmp_path / ".commandcode").read_text() == "a regular file where the directory should be"


def test_missing_seat_or_key_skips_cleanly(tmp_path):
    out = _run(tmp_path)
    assert SEAT_WARNING not in out and "WARNING" not in out
    assert not (tmp_path / ".commandcode").exists()
    _seat(tmp_path, "OTHER=1\nCOMMANDCODE_API_KEY=\n")
    out = _run(tmp_path)
    assert "WARNING" not in out
    assert not (tmp_path / ".commandcode").exists()


def test_an_unreadable_seat_is_a_warning_not_silence_and_writes_nothing(tmp_path):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n", mode=0o000)
    out = _run(tmp_path, ok=False)
    assert SEAT_WARNING in out and "WARNING:" in out and "Command Code login: the seat exists but could not be read" in out
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


def test_a_key_that_differs_from_the_seat_is_noted_not_failed_and_a_matching_one_is_silent(tmp_path):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    _login(tmp_path, {"apiKey": OTHER})
    out = _run(tmp_path)
    assert "NOTE:" in out and "differs from the seat" in out
    assert OTHER not in out and FAKE not in out
    assert json.loads(_auth(tmp_path).read_text()) == {"apiKey": OTHER}
    _login(tmp_path, {"apiKey": FAKE})
    assert "differs from the seat" not in _run(tmp_path)
