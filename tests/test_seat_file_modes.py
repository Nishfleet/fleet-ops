"""The seat files are guarded for the other uids by their mode and owner (fleet-ops#11114).

Claude Code's deny rules match a command's text only, so a reader that hides the path and
builds it after a cd (`cd ~/.config && python3 -c "open('fleet-ops/seats/x').read()"`)
gets past every pattern that names the seats directory. A file mode binds the other uids
(runner users, jailed engines outside the hides, other local accounts), never a process
already reading as nish, whose hole is the sandbox the issue's follow-up tracks. The
playbook therefore keeps `~/.config/fleet-ops/seats` at 0700 and every `.env` under it at
0600 owned by nish, running as nish so a planted symlink cannot steer a root chmod (the
litellm-keys tasks in the same file follow that rule), and ansible/tasks/final-checks.yml
fails the deploy naming any file or the directory whose mode or owner drifts. The threat
model is stated once in docs/managed-settings-defaults.md.
"""
from __future__ import annotations

import re

import pytest
import ansible_host
from jinja2 import Environment

DIR_TASK = "Make sure the seats directory exists owner-only"
FIND_TASK = "Find the seat environment files"
CHMOD_TASK = "Make sure every seat environment file is owner-only"
DETECT_FILE_TASK = "Fail when a seat environment file carries a group or other bit"
DETECT_DIR_TASK = "Fail when the seats directory is missing, not nish's, or carries a group or other bit"
FULL_GROUP_OR_OTHER = "item.rgrp or item.roth or item.wgrp or item.woth or item.xgrp or item.xoth"
CLEAN_EXISTENCE = "s.exists and"


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
    assert re.search(r"file_type: file", find_task)
    assert re.search(r"recurse: true", find_task)
    assert "register: seat_env_files" in find_task
    chmod_task = play_blocks[CHMOD_TASK]
    assert "mode: \"0600\"" in chmod_task
    assert "{{ seat_env_files.files }}" in chmod_task


def test_the_detector_judges_mode_and_owner_naming_the_file(play_blocks) -> None:
    file_task = play_blocks[DETECT_FILE_TASK]
    assert f"that: not ({FULL_GROUP_OR_OTHER}) and item.pw_name == 'nish'" in file_task
    assert "{{ item.path }}" in file_task
    assert "fleet-ops#11114" in file_task
    dir_task = play_blocks[DETECT_DIR_TASK]
    full_dir = FULL_GROUP_OR_OTHER.replace("item.", "seat_dir.stat.")
    assert f"seat_dir.stat.exists and seat_dir.stat.pw_name == 'nish' and not ({full_dir})" in dir_task
    assert "fleet-ops#11114" in dir_task



@pytest.mark.parametrize("bit", ["rgrp", "roth", "wgrp", "woth", "xgrp", "xoth"])
def test_the_guards_judge_the_modes_for_real(play_blocks, bit: str) -> None:
    clean = {"exists": True, "pw_name": "nish", "rgrp": False, "roth": False, "wgrp": False,
             "woth": False, "xgrp": False, "xoth": False}
    for task, needle in ((DETECT_DIR_TASK, "seat_dir.stat"), (DETECT_FILE_TASK, "item")):
        match = re.search(rf"that: (not \(|)({needle}\..*)\n", play_blocks[task])
        assert match, f"{task}'s own expression must be on one line"
        full = (match.group(1) + match.group(2)).replace(needle + ".", "s.")
        judge = Environment().from_string("{{ " + full + " }}")
        assert judge.render(s=clean) == "True", f"{task}: a file with no group or other bits passes"
        assert judge.render(s={**clean, bit: True}) == "False", f"{task}: leaking {bit} fails"
        wrong_owner = dict(clean, pw_name="root")
        assert judge.render(s=wrong_owner) == "False", f"{task}: a root-owned seat file fails"
        if CLEAN_EXISTENCE in full:
            assert judge.render(s={"exists": False}) == "False", f"{task}: a missing seat file fails"
