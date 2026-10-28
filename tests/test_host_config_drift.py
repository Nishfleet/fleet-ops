import json
import pathlib
import shutil
import subprocess

import pytest
import yaml

if not shutil.which("ansible-playbook"):
    pytest.skip("ansible missing", allow_module_level=True)

ROOT = pathlib.Path(__file__).resolve().parents[1]
PLAY = yaml.safe_load((ROOT / "ansible/host.yml").read_text())[0]
TASK_FILES = ["install-config.yml", "retired-and-drift.yml"]
TASKS = {
    t["name"]: t
    for f in TASK_FILES
    for t in yaml.safe_load((ROOT / "ansible/tasks" / f).read_text())
}
NAMES = [
    "List the files rootfs/ ships, with checksums",
    "List the same files on the box, with checksums",
    "Read the commit this run applies",
    "List the files this deploy changes in rootfs/",
    "Work out which shipped files were edited by hand",
    "Fail on a hand-edited file",
    "Record the commit this run applied",
]
UNIT = "etc/systemd/system/fleet-a.service"


def _git(repo, *args):
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@example.invalid", *args], check=True, capture_output=True)


def _commit(repo, message):
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "-m", message)


def _run(tmp_path):
    tasks = []
    for name in NAMES:
        task = json.loads(json.dumps(TASKS[name]))
        for key in ("owner", "group"):
            task.get("ansible.builtin.copy", {}).pop(key, None)
        tasks.append(task)
    variables = {
        **PLAY["vars"],
        "rootfs": str(tmp_path / "repo/rootfs"),
        "host_root": str(tmp_path / "box"),
        "applied_sha_file": str(tmp_path / "applied-sha"),
    }
    play = {"hosts": "localhost", "connection": "local", "gather_facts": False, "vars": variables, "tasks": tasks}
    book = tmp_path / "play.json"
    book.write_text(json.dumps([play]))
    return subprocess.run(
        ["ansible-playbook", "-i", "localhost,", str(book)],
        capture_output=True, text=True, cwd=tmp_path, env={"PATH": "/usr/bin:/bin:/usr/local/bin", "HOME": str(tmp_path), "ANSIBLE_NOCOLOR": "1"},
    )


@pytest.fixture
def fixture(tmp_path):
    repo = tmp_path / "repo"
    (repo / "rootfs" / UNIT).parent.mkdir(parents=True)
    (repo / "rootfs" / UNIT).write_text("[Service]\nUMask=0077\n")
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    _commit(repo, "first")
    live = tmp_path / "box" / UNIT
    live.parent.mkdir(parents=True)
    shutil.copy(repo / "rootfs" / UNIT, live)
    assert _run(tmp_path).returncode == 0
    return tmp_path


def test_first_run_has_no_baseline_and_records_the_commit(fixture):
    head = subprocess.run(["git", "-C", str(fixture / "repo"), "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout
    assert (fixture / "applied-sha").read_text() == head


def test_untouched_box_passes(fixture):
    result = _run(fixture)
    assert result.returncode == 0, result.stdout


def test_hand_edit_of_a_managed_file_fails_and_names_it(fixture):
    (fixture / "box" / UNIT).write_text("[Service]\nUMask=0022\n")
    result = _run(fixture)
    assert result.returncode != 0
    assert f"/{UNIT}" in result.stdout and "Hand-edited" in result.stdout


def test_file_changed_by_this_deploy_passes(fixture):
    (fixture / "repo/rootfs" / UNIT).write_text("[Service]\nUMask=0027\n")
    _commit(fixture / "repo", "second")
    result = _run(fixture)
    assert result.returncode == 0, result.stdout
