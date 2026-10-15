"""The Command Code CLI is logged in from the box's seat file, the way `cmd login` would.

cmd reads ~/.commandcode/auth.json (flat JSON, apiKey among other keys, mode
0600) when COMMAND_CODE_API_KEY is unset. The seat file holds the key as
COMMANDCODE_API_KEY. The real Ansible tasks run against a temp home with a
fake key.
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
NAMES = [
    "Read the Command Code seat",
    "Create the Command Code login directory",
    "Read the Command Code login",
    "Parse the Command Code login (an unreadable file counts as empty, as it does for cmd)",
    "Store the seat's key as the Command Code login (cmd reads auth.json when COMMAND_CODE_API_KEY is unset)",
]


def _play():
    out = subprocess.run(["yq", "-o=json", ".", str(HOST)], capture_output=True, text=True, check=True).stdout
    return json.loads(out)[0]


PLAY = _play()
TASKS = {t["name"]: t for t in PLAY["tasks"]}


def _run(home):
    tasks = []
    for name in NAMES:
        task = json.loads(json.dumps(TASKS[name]))
        task.pop("become", None)
        task.pop("become_user", None)
        task["no_log"] = False
        tasks.append(task)
    play = {"hosts": "localhost", "connection": "local", "gather_facts": False, "vars": {**PLAY["vars"], "nish_home": str(home)}, "tasks": tasks}
    book = home / "play.json"
    book.write_text(json.dumps([play]))
    result = subprocess.run(
        ["ansible-playbook", "-i", "localhost,", str(book)],
        capture_output=True, text=True, cwd=home, env={"PATH": "/usr/bin:/bin:/usr/local/bin", "HOME": str(home), "ANSIBLE_NOCOLOR": "1"},
    )
    assert result.returncode == 0, result.stdout.replace(FAKE, "<key>") + result.stderr.replace(FAKE, "<key>")
    return result.stdout


def _seat(home, text):
    seat = home / ".config" / "fleet-ops" / "seats" / "commandcode.env"
    seat.parent.mkdir(parents=True, exist_ok=True)
    seat.write_text(text)


def _auth(home):
    return home / ".commandcode/auth.json"


def _mode(path):
    return stat.S_IMODE(path.stat().st_mode)


def test_every_login_task_runs_as_nish_and_hides_the_key():
    for name in NAMES:
        task = TASKS[name]
        if name == NAMES[3]:
            continue
        assert task.get("become") is True and task.get("become_user") == "nish", name
        assert "owner" not in json.dumps(task) and "group" not in json.dumps(task), name
        modules = [k for k in task if "." in k]
        assert all(k.startswith("ansible.builtin.") for k in modules), name
    for name in (NAMES[0], NAMES[2], NAMES[3], NAMES[4]):
        assert TASKS[name]["no_log"] is True, name
    names = [t["name"] for t in PLAY["tasks"]]
    assert [n for n in names if n in NAMES] == NAMES
    assert names.index(NAMES[-1]) < names.index("Fail when an alertmanager credential file is missing")


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
    _run(tmp_path)
    before = _auth(tmp_path).read_bytes()
    out = _run(tmp_path)
    assert "changed=0" in out
    assert _auth(tmp_path).read_bytes() == before


def test_other_keys_survive_and_a_changed_key_drops_the_old_logins_identity(tmp_path):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    _auth(tmp_path).parent.mkdir(mode=0o700)
    _auth(tmp_path).write_text(json.dumps({"apiKey": "user_old", "userId": "u", "userName": "nish", "keyName": "k", "authenticatedAt": "t", "extra": 1}))
    _run(tmp_path)
    assert json.loads(_auth(tmp_path).read_text()) == {"apiKey": FAKE, "extra": 1}
    assert _mode(_auth(tmp_path)) == 0o600
    assert "changed=0" in _run(tmp_path)


def test_matching_login_with_extra_keys_is_left_untouched(tmp_path):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    _auth(tmp_path).parent.mkdir(mode=0o700)
    text = json.dumps({"apiKey": FAKE, "userId": "u"}, indent=2)
    _auth(tmp_path).write_text(text)
    assert "changed=0" in _run(tmp_path)
    assert _auth(tmp_path).read_text() == text


def test_missing_seat_or_key_skips_cleanly(tmp_path):
    _run(tmp_path)
    assert not (tmp_path / ".commandcode").exists()
    _seat(tmp_path, "OTHER=1\nCOMMANDCODE_API_KEY=\n")
    _run(tmp_path)
    assert not (tmp_path / ".commandcode").exists()


def test_key_never_reaches_ansible_output_under_no_log(tmp_path):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    tasks = [json.loads(json.dumps(TASKS[n])) for n in NAMES]
    for task in tasks:
        task.pop("become", None)
        task.pop("become_user", None)
    book = tmp_path / "play.json"
    book.write_text(json.dumps([{"hosts": "localhost", "connection": "local", "gather_facts": False, "vars": {**PLAY["vars"], "nish_home": str(tmp_path)}, "tasks": tasks}]))
    result = subprocess.run(
        ["ansible-playbook", "-i", "localhost,", "-vvv", "--diff", str(book)],
        capture_output=True, text=True, cwd=tmp_path, env={"PATH": "/usr/bin:/bin:/usr/local/bin", "HOME": str(tmp_path), "ANSIBLE_NOCOLOR": "1"},
    )
    assert result.returncode == 0
    assert FAKE not in result.stdout + result.stderr
    assert json.loads(_auth(tmp_path).read_text()) == {"apiKey": FAKE}


def test_a_login_file_that_is_not_an_object_is_replaced(tmp_path):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    _auth(tmp_path).parent.mkdir(mode=0o700)
    _auth(tmp_path).write_text("[]")
    _run(tmp_path)
    assert json.loads(_auth(tmp_path).read_text()) == {"apiKey": FAKE}
    assert "changed=0" in _run(tmp_path)


@pytest.mark.parametrize("broken", ['{"apiKey": "user_ol', "{", "not json", ""])
def test_a_truncated_login_file_is_replaced_and_the_run_still_succeeds(tmp_path, broken):
    _seat(tmp_path, f"COMMANDCODE_API_KEY={FAKE}\n")
    _auth(tmp_path).parent.mkdir(mode=0o700)
    _auth(tmp_path).write_text(broken)
    _run(tmp_path)
    assert json.loads(_auth(tmp_path).read_text()) == {"apiKey": FAKE}
    assert "changed=0" in _run(tmp_path)
