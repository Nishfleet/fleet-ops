"""The update's runner version prune: it deletes only what no runner points at.

A runner updates itself in place: it unpacks bin.<version>/ and
externals.<version> beside the pair it runs from, repoints the bin and externals
symlinks, and never removes the pair it moved off. Nothing removed those, so the
tree grew by about 680 MB per runner per update (fleet-ops#10632: 60 stale pairs,
20.3 GB on one host).
"""
import json
import pathlib
import shutil
import subprocess

import pytest

if not shutil.which("yq"):
    pytest.skip("yq missing", allow_module_level=True)

ROOT = pathlib.Path(__file__).resolve().parents[1]
PLAY = json.loads(subprocess.run(["yq", "-o=json", ".", str(ROOT / "ansible/update.yml")], capture_output=True, text=True, check=True).stdout)[0]


def walk(tasks):
    for task in tasks:
        yield task
        for key in ("block", "always", "rescue"):
            if key in task:
                yield from walk(task[key])


TASKS = {task["name"]: task for task in walk(PLAY["tasks"])}
LINKS = TASKS["List the runner version each runner's bin and externals symlink points at"]
TARGETS = TASKS["Read the version directory each of those symlinks points at"]
CANDIDATES = TASKS["List the runner version directories older than a self-update"]
REMOVE = TASKS["Remove the runner version directories no runner points at"]


def test_both_symlinks_are_read_not_only_bin():
    """bin and externals name the same version in two directories.

    Keeping only the bin target deletes the version externals runs from and
    leaves that link broken, so both links are listed and both targets kept.
    """
    assert sorted(LINKS["ansible.builtin.find"]["patterns"]) == ["bin", "externals"]
    assert LINKS["ansible.builtin.find"]["file_type"] == "link"
    assert TARGETS["loop"] == "{{ runner_version_links.files | map(attribute='path') | list }}"
    assert "runner_version_targets.results | map(attribute='stat.lnk_source')" in REMOVE["loop"]


def test_a_version_unpacked_in_the_last_hour_survives():
    """A self-update unpacks the new pair before it moves the symlink.

    In that window the new directory is not a link target yet, so age is the
    only thing that keeps it: without the guard the prune deletes the version
    the update is about to point at.
    """
    assert CANDIDATES["ansible.builtin.find"]["age"] == "1h"
    assert sorted(CANDIDATES["ansible.builtin.find"]["patterns"]) == ["bin.*", "externals.*"]
    assert CANDIDATES["ansible.builtin.find"]["file_type"] == "directory"


def test_the_prune_removes_only_directories():
    assert REMOVE["ansible.builtin.file"] == {"path": "{{ item }}", "state": "absent"}
    assert REMOVE["loop"].startswith("{{ runner_version_dirs.files | map(attribute='path')")
    assert REMOVE["loop"].rstrip().endswith("| list }}")


def test_the_summary_reports_what_was_removed():
    """A prune nobody can read is a prune nobody can check."""
    reports = [task["ansible.builtin.debug"]["msg"] for task in walk(PLAY["tasks"])
               if "runner_version_dirs_removed" in json.dumps(task.get("ansible.builtin.debug", {}))]
    assert len(reports) == 1
    assert "selectattr('changed') | map(attribute='item')" in reports[0]["runner_version_dirs_removed"]
