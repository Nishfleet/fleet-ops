import json
import os
import pathlib
import shutil
import subprocess

import pytest

if not shutil.which("yq") or not shutil.which("ansible-playbook"):
    pytest.skip("yq or ansible missing", allow_module_level=True)

ROOT = pathlib.Path(__file__).resolve().parents[1]


def _yq(path):
    return json.loads(subprocess.run(["yq", "-o=json", ".", str(path)], capture_output=True, text=True, check=True).stdout)


def _load_tasks():
    tasks = {}
    for path in sorted((ROOT / "ansible" / "tasks").glob("*.yml")):
        for task in _yq(path):
            tasks[task["name"]] = task
    return tasks


PLAY = _yq(ROOT / "ansible/host.yml")[0]
TASKS = _load_tasks()
NAMES = [
    "List the files rootfs/ ships, with checksums",
    "List the same files on the box, with checksums",
    "Read the checksum of the file each shipped symlink points at",
    "Read the commit this run applies",
    "List the files this deploy changes in rootfs/",
    "Work out which shipped files were edited by hand",
    "Fail on a hand-edited file",
    "Record the commit this run applied",
]
UNIT = "etc/systemd/system/fleet-a.service"
# A shipped symlink whose target sits outside rootfs/etc, the way
# fleet-unit-failed@.service does: copy follows it, so the box holds a regular
# file at the link's own path with the target's bytes.
LINK = "etc/systemd/system/fleet-unit-failed@.service"
TARGET = "systemd/fleet-unit-failed@.service"
# A shipped symlink whose target sits inside rootfs/etc, the way the
# 90-podman-newuidmap.conf drop-ins do.
INSIDE_LINK = "etc/systemd/user/fleet-litellm-proxy.service.d/90-podman-newuidmap.conf"
INSIDE_TARGET = "etc/systemd/user/fleet-grafana.service.d/90-podman-newuidmap.conf"


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


def _ship(repo, link, target):
    (repo / link).parent.mkdir(parents=True, exist_ok=True)
    (repo / link).symlink_to(pathlib.PurePosixPath(os.path.relpath(target, pathlib.PurePosixPath(link).parent.as_posix())))


@pytest.fixture
def fixture(tmp_path):
    repo = tmp_path / "repo"
    (repo / "rootfs" / UNIT).parent.mkdir(parents=True)
    (repo / "rootfs" / UNIT).write_text("[Service]\nUMask=0077\n")
    (repo / "rootfs" / INSIDE_TARGET).parent.mkdir(parents=True)
    (repo / "rootfs" / INSIDE_TARGET).write_text("PrivateUsers=1\n")
    _ship(repo, "rootfs/" + LINK, TARGET)
    _ship(repo, "rootfs/" + INSIDE_LINK, "rootfs/" + INSIDE_TARGET)
    (repo / TARGET).parent.mkdir(parents=True)
    (repo / TARGET).write_text("[Unit]\nDescription=fleet\n")
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    _commit(repo, "first")
    shutil.copytree(repo / "rootfs" / "etc", tmp_path / "box" / "etc", symlinks=False)
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


def test_hand_edit_at_a_shipped_symlinks_path_fails_and_names_it(fixture):
    (fixture / "box" / LINK).write_text("[Unit]\nDescription=edited\n")
    result = _run(fixture)
    assert result.returncode != 0
    assert f"/{LINK}" in result.stdout and "Hand-edited" in result.stdout


def test_change_to_a_symlink_target_outside_rootfs_is_reported(fixture):
    (fixture / "repo" / TARGET).write_text("[Unit]\nDescription=changed\n")
    _commit(fixture / "repo", "second")
    result = _run(fixture)
    assert result.returncode != 0
    assert f"/{LINK}" in result.stdout and "Hand-edited" in result.stdout


def test_change_to_a_symlink_target_inside_rootfs_is_excused(fixture):
    (fixture / "repo/rootfs" / INSIDE_TARGET).write_text("PrivateUsers=0\n")
    _commit(fixture / "repo", "second")
    result = _run(fixture)
    assert result.returncode == 0, result.stdout


def test_a_file_the_live_walk_cannot_read_is_not_reported(fixture):
    (fixture / "box" / UNIT).chmod(0)
    result = _run(fixture)
    assert result.returncode == 0, result.stdout
