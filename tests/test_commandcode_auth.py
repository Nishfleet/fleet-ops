"""The Command Code CLI is logged in from the box's seat file, the way pasting the key in /connect would.

cmd reads ~/.commandcode/auth.json (flat JSON, apiKey among other keys, mode
0600; the vendor text says "paste the key in /connect (stored in
~/.commandcode/auth.json)"). That file is read only by cmd, so the key is not
in the environment of any other process. The seat file holds the key as
COMMANDCODE_API_KEY, the name the LiteLLM router reads and this play leaves
alone. The play writes the file with copy force: false, so a login that
already exists (one cmd made, or one written from an earlier seat key) is never
replaced, and keeps it at mode 0600 whatever key it holds. A failure to set the
login up is a warning, and a final assert then fails the run after everything
else ran. `cmd login` has no key flag (its help lists only [provider] and -h)
and is an interactive browser flow. The real Ansible tasks run against a temp
home with a fake key.
"""
import functools
import json
import os
import pathlib
import shutil
import stat
import subprocess

import pytest
import ansible_host

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
SEAT_WARNING = "exists but could not be read"
SETUP_WARNING = "could not set up the Command Code login"
STAT = "Look for the Command Code seat"
READ = "Read the Command Code seat (an unreadable seat is a warning, not a silent skip)"
LOGIN = "Log Command Code in from the seat (a login that already exists is never replaced)"
FINAL = "Fail when the Command Code login could not be set up"
NAMES = [STAT, READ, LOGIN, FINAL]
DIR = "Create the Command Code login directory"
WRITE = "Write the seat's key as the Command Code login unless a login file exists"
MODE = "Keep the Command Code login at mode 0600, whatever key it holds"
COMPARE = "Read the Command Code login to compare it with the seat"
DRIFT = "does not contain the seat's key"
ENV = {"PATH": "/usr/bin:/bin:/usr/local/bin", "ANSIBLE_NOCOLOR": "1"}


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
    out = subprocess.run(["yq", "-o=json", "."], input=ansible_host.text(), capture_output=True, text=True, check=True).stdout
    return json.loads(out)[0]


@functools.cache
def _loaded():
    play = _play()
    tasks = {t["name"]: t for t in play["tasks"]}
    login = {t["name"]: t for t in tasks[LOGIN]["block"]}
    return play, tasks, login


def _book(home, hide):
    play, all_tasks, _ = _loaded()
    tasks = []
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
        capture_output=True, text=True, cwd=home, env={**ENV, "HOME": str(home)},
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


def test_every_login_task_runs_as_nish_with_a_stock_module_and_hides_the_key():
    play, tasks, login = _loaded()
    slurp = tasks[READ]["block"][0]
    for task in (tasks[STAT], slurp, login[DIR], login[WRITE], login[MODE], login[COMPARE]):
        assert task.get("become") is True and task.get("become_user") == "nish", task["name"]
        assert "owner" not in json.dumps(task) and "group" not in json.dumps(task), task["name"]
        assert all(k.startswith("ansible.builtin.") for k in task if "." in k), task["name"]
    for task in (slurp, login[WRITE], login[MODE], login[COMPARE]):
        assert task["no_log"] is True, task["name"]
    for task in (slurp, login[WRITE], login[MODE], login[COMPARE]):
        assert task["diff"] is False, task["name"]
    assert login[WRITE]["ansible.builtin.copy"]["force"] is False
    assert login[WRITE]["ansible.builtin.copy"]["mode"] == "0600"
    names = [t["name"] for t in play["tasks"]]
    assert [n for n in names if n in NAMES] == NAMES
    assert names.index(LOGIN) < names.index("Fail when an alertmanager credential file is missing") < names.index(FINAL)
    assert names.index("Apply pending handlers before the credential check") < names.index(STAT)


def test_failures_are_warnings_then_one_final_assert_never_ignore_errors_or_failed_when():
    play, tasks, login = _loaded()
    text = json.dumps([tasks[n] for n in NAMES])
    assert "ignore_errors" not in text and "failed_when" not in text
    assert tasks[READ]["when"] == "commandcode_seat_stat.stat.exists"
    said = tasks[READ]["rescue"][0]["ansible.builtin.debug"]["msg"]
    assert SEAT_WARNING in said and said.startswith("WARNING")
    outer = tasks[LOGIN]["rescue"][0]
    assert SETUP_WARNING in outer["ansible.builtin.debug"]["msg"]
    assert "commandcode_seat_key" not in json.dumps(outer)
    for rescue in (tasks[READ]["rescue"], tasks[LOGIN]["rescue"]):
        assert any("commandcode_problems" in json.dumps(x) for x in rescue)
    assert tasks[FINAL]["ansible.builtin.assert"]["that"] == "commandcode_problems | default([]) | length == 0"
    assert tasks[LOGIN]["when"] == "commandcode_seat_key != ''"


def test_login_writes_the_cli_shape_with_mode_0600(tmp_path):
    _seat(tmp_path, f"OTHER=1\nCOMMANDCODE_API_KEY={FAKE}\n")
    _run(tmp_path)
    assert json.loads(_auth(tmp_path).read_text()) == {"apiKey": FAKE}
    assert _mode(_auth(tmp_path)) == 0o600
    assert _mode(_auth(tmp_path).parent) == 0o700


@pytest.mark.parametrize("line", [f"COMMANDCODE_API_KEY={FAKE}", f"export COMMANDCODE_API_KEY={FAKE}", f'COMMANDCODE_API_KEY="{FAKE}"', f"COMMANDCODE_API_KEY='{FAKE}'", f"COMMANDCODE_API_KEY={FAKE}  ", f"COMMANDCODE_API_KEY={FAKE}\r"])
def test_seat_line_forms(tmp_path, line):
    _seat(tmp_path, f"# COMMANDCODE_API_KEY=commented\n{line}\n")
    _run(tmp_path)
    assert json.loads(_auth(tmp_path).read_text()) == {"apiKey": FAKE}


@pytest.mark.parametrize("value", ["abc def", "abc'def", 'abc"def', "abc def ghi", "a b"])
def test_a_seat_value_that_the_pattern_would_cut_short_is_not_written(tmp_path, value):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={value}\n")
    _run(tmp_path)
    assert not _auth(tmp_path).exists()


def test_second_run_changes_nothing(tmp_path):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    _run(tmp_path)
    before = _auth(tmp_path).read_bytes()
    out = _run(tmp_path)
    assert "changed=0" in out
    assert _auth(tmp_path).read_bytes() == before


@pytest.mark.parametrize("content", [{"apiKey": FAKE, "userId": "u", "extra": 1}, {"apiKey": OTHER, "userName": "nish"}, {"extra": 1}, {"apiKey": ""}])
@pytest.mark.parametrize("mode", [0o644, 0o666, 0o640, 0o400, 0o200])
def test_an_existing_login_is_never_replaced_and_gets_mode_0600_whatever_it_holds(tmp_path, content, mode):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    text = json.dumps(content, indent=2)
    _login(tmp_path, text, mode=mode)
    out = _run(tmp_path)
    assert _mode(_auth(tmp_path)) == 0o600
    assert _auth(tmp_path).read_text() == text
    assert FAKE not in out and OTHER not in out
    assert "changed=0" in _run(tmp_path)


@pytest.mark.parametrize("broken", ['{"apiKey": "user_ol', "{", "not json", "", "[]", "null"])
def test_a_login_that_is_not_valid_json_is_left_alone_and_does_not_fail_the_run(tmp_path, broken):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    _login(tmp_path, broken, mode=0o644)
    out = _run(tmp_path)
    assert FAKE not in out and "WARNING" not in out
    assert _auth(tmp_path).read_text() == broken
    assert _mode(_auth(tmp_path)) == 0o600


def test_a_rotated_seat_key_does_not_replace_an_existing_login(tmp_path):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    _run(tmp_path)
    _seat(tmp_path, "COMMANDCODE_API_KEY=user_rotated\n")
    _run(tmp_path)
    assert json.loads(_auth(tmp_path).read_text()) == {"apiKey": FAKE}
    _auth(tmp_path).unlink()
    _run(tmp_path)
    assert json.loads(_auth(tmp_path).read_text()) == {"apiKey": "user_rotated"}


def test_a_login_directory_that_cannot_be_made_is_a_warning_then_the_run_fails_after_the_rest(tmp_path):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    (tmp_path / ".commandcode").write_text("a regular file where the directory should be")
    out = _run(tmp_path, ok=False)
    assert SETUP_WARNING in out and "WARNING:" in out
    assert "Command Code login: the login could not be set up at step: Create the Command Code login directory" in out
    assert FAKE not in out
    assert (tmp_path / ".commandcode").read_text() == "a regular file where the directory should be"


def test_missing_seat_or_key_skips_cleanly(tmp_path):
    out = _run(tmp_path)
    assert "WARNING" not in out
    assert not (tmp_path / ".commandcode").exists()
    _seat(tmp_path, "OTHER=1\nCOMMANDCODE_API_KEY=\n")
    out = _run(tmp_path)
    assert "WARNING" not in out
    assert not (tmp_path / ".commandcode").exists()


@pytest.mark.skipif(os.geteuid() == 0, reason="root reads a mode 000 file")
def test_an_unreadable_seat_is_a_warning_then_the_run_fails_and_writes_nothing(tmp_path):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n", mode=0o000)
    out = _run(tmp_path, ok=False)
    assert SEAT_WARNING in out and "WARNING:" in out and "Command Code login: the seat exists but could not be read" in out
    assert FAKE not in out
    assert not (tmp_path / ".commandcode").exists()


def test_the_key_never_reaches_ansible_output_on_any_path_under_no_log(tmp_path_factory):
    cases = []
    happy = tmp_path_factory.mktemp("happy")
    _seat(happy, f"COMMANDCODE_API_KEY={FAKE}\n")
    cases.append((happy, True))
    if os.geteuid() != 0:
        unreadable = tmp_path_factory.mktemp("unreadable")
        _seat(unreadable, f"COMMANDCODE_API_KEY={FAKE}\n", mode=0o000)
        cases.append((unreadable, False))
    blocked = tmp_path_factory.mktemp("blocked")
    _seat(blocked, f"COMMANDCODE_API_KEY={FAKE}\n")
    (blocked / ".commandcode").write_text("x")
    cases.append((blocked, False))
    existing = tmp_path_factory.mktemp("existing")
    _seat(existing, f"COMMANDCODE_API_KEY={FAKE}\n")
    _login(existing, {"apiKey": FAKE})
    cases.append((existing, True))
    for home, ok in cases:
        result = subprocess.run(
            ["ansible-playbook", "-i", "localhost,", "-vvv", "--diff", str(_book(home, hide=True))],
            capture_output=True, text=True, cwd=home, env={**ENV, "HOME": str(home)},
        )
        assert (result.returncode == 0) == ok, (result.stdout + result.stderr).replace(FAKE, "<key>")
        assert FAKE not in result.stdout + result.stderr, home.name
    assert json.loads(_auth(happy).read_text()) == {"apiKey": FAKE}


def test_a_check_mode_run_with_no_login_yet_stays_clean(tmp_path):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    out = _run(tmp_path, extra=("--check",))
    assert "WARNING" not in out and "failed=0" in out
    assert not _auth(tmp_path).exists()
    assert "when" in _loaded()[2][MODE] and _loaded()[2][MODE]["when"] == "not ansible_check_mode"


def test_a_login_that_does_not_hold_the_seat_key_is_noted_and_a_matching_one_is_silent(tmp_path):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    _login(tmp_path, {"apiKey": OTHER, "userName": "nish"})
    out = _run(tmp_path)
    assert DRIFT in out and "NOTE:" in out
    assert OTHER not in out and FAKE not in out
    assert json.loads(_auth(tmp_path).read_text()) == {"apiKey": OTHER, "userName": "nish"}
    assert DRIFT not in _run(tmp_path, extra=("--check",))
    _auth(tmp_path).write_text(json.dumps({"apiKey": FAKE, "userId": "u"}))
    assert DRIFT not in _run(tmp_path)


def test_a_fresh_login_is_not_reported_as_drift(tmp_path):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    assert DRIFT not in _run(tmp_path)
