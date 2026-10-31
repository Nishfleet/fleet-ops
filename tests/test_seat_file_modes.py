"""The seat files are guarded by their file mode, not by a string rule (fleet-ops#11114).

Claude Code's deny rules match a command's text only, so a reader that hides the path and
builds it after a cd (`cd ~/.config && python3 -c "open('fleet-ops/seats/x').read()"`)
gets past every pattern that names the seats directory. The playbook therefore treats the
mode as the guard: ansible/tasks/secrets.yml keeps `~/.config/fleet-ops/seats` at 0700 and
every `.env` under it at 0600, running as nish so a planted symlink cannot steer a root
chmod (the litellm-keys tasks in the same file follow that rule), and
ansible/tasks/final-checks.yml fails the deploy naming any file or the directory where a
group or other bit is set.
"""
from __future__ import annotations

import re

import pytest
import ansible_host
from jinja2 import Environment

SEATS = "fleet-ops/seats"
DIR_TASK = "Make sure the seats directory exists owner-only"
FIND_TASK = "Find the seat environment files"
CHMOD_TASK = "Make sure every seat environment file is owner-only"
DETECT_FILE_TASK = "Fail when a seat environment file carries a group or other bit"
DETECT_DIR_TASK = "Fail when the seats directory carries a group or other bit"


def blocks() -> dict[str, str]:
    """The play's task blocks, split the way the other ansible tests split it."""
    return {block.split("\n", 1)[0]: block for block in re.split(r"\n    - name: ", ansible_host.text())}


@pytest.fixture(scope="module")
def play_blocks() -> dict[str, str]:
    found = blocks()
    for name in (DIR_TASK, FIND_TASK, CHMOD_TASK, DETECT_FILE_TASK, DETECT_DIR_TASK):
        assert name in found, name
    return found


def test_the_apply_tasks_run_as_nish(play_blocks) -> None:
    for name in (DIR_TASK, FIND_TASK, CHMOD_TASK):
        assert "become_user: nish" in play_blocks[name], name


def test_the_apply_tasks_cover_the_seats(play_blocks) -> None:
    dir_task = play_blocks[DIR_TASK]
    assert "{{ nish_config }}/fleet-ops/seats" in dir_task
    assert re.search(r"state: directory", dir_task)
    assert re.search(r"mode: \"0700\"", dir_task)
    find_task = play_blocks[FIND_TASK]
    assert "{{ nish_config }}/fleet-ops/seats" in find_task
    assert re.search(r"patterns: \"\*\.env\"", find_task)
    assert re.search(r"recurse: true", find_task)
    assert "register: seat_env_files" in find_task
    chmod_task = play_blocks[CHMOD_TASK]
    assert "mode: \"0600\"" in chmod_task
    assert "{{ seat_env_files.files }}" in chmod_task


def test_the_detector_fails_the_deploy_naming_the_file(play_blocks) -> None:
    file_task = play_blocks[DETECT_FILE_TASK]
    assert re.search(r"that: not \(item\.(r|w|x)grp or item\.(r|w|x)oth or item\.(r|w|x)grp", file_task)
    assert "{{ item.path }}" in file_task
    assert "fleet-ops#11114" in file_task
    dir_task = play_blocks[DETECT_DIR_TASK]
    assert "that: not (seat_dir.stat.rgrp" in dir_task
    assert "fleet-ops#11114" in dir_task


@pytest.mark.parametrize("bit", ["rgrp", "roth", "wgrp", "woth", "xgrp", "xoth"])
def test_the_guard_judges_the_modes_for_real(play_blocks, bit: str) -> None:
    match = re.search(r"that: (not \(seat_dir\.stat\..*)\n", play_blocks[DETECT_DIR_TASK])
    assert match, "the directory guard's own expression must be on one line"
    judge = Environment().from_string("{{ " + match.group(1).replace("seat_dir.stat.", "s.") + " }}")
    clean = {"rgrp": False, "roth": False, "wgrp": False, "woth": False, "xgrp": False, "xoth": False}
    assert judge.render(s=clean) == "True", "a file with no group or other bits passes"
    assert judge.render(s={**clean, bit: True}) == "False", f"leaking {bit} fails"
