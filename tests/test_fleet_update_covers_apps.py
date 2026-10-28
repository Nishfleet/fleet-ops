"""The daily update covers Hermes and tincan, restarts what runs old code, and removes a banned Hermes tool before the restart."""
import json
import pathlib
import shutil
import subprocess

import pytest

if not shutil.which("yq"):
    pytest.skip("yq missing", allow_module_level=True)

ROOT = pathlib.Path(__file__).resolve().parents[1]
PLAY = json.loads(subprocess.run(["yq", "-o=json", ".", str(ROOT / "ansible/update.yml")], capture_output=True, text=True, check=True).stdout)[0]
BLOCK = next(t for t in PLAY["tasks"] if "block" in t and "always" in t)
INNER = {t["name"]: t for t in BLOCK["block"]}
NAMES = [t["name"] for t in BLOCK["block"]]
ASSERT = next(t for t in BLOCK["always"] if t["name"] == "Fail loudly if any step or check went wrong")


def test_hermes_updates_on_stable_with_no_prompt():
    task = INNER["Update Hermes on the stable channel"]
    argv = task["ansible.builtin.command"]["argv"]
    assert argv[:2] == ["hermes", "update"]
    assert {"--channel", "stable", "--no-gateway-restart", "--yes"} <= set(argv)
    assert task["become_user"] == "nish"


def test_hermes_services_restart_only_after_a_good_update_that_moved_the_version():
    task = INNER["Restart the Hermes services on the new code"]
    assert "hermes_version_after is changed" in task["when"] and "hermes_update.failed" in task["when"]
    assert task["loop"] == ["hermes-gateway.service", "hermes-serve.service"]


def test_tincan_listeners_restart_only_when_idle_and_the_version_moved():
    assert INNER["Update tincan"]["ansible.builtin.command"]["argv"] == ["tincan", "upgrade"]
    assert INNER["List the tincan listener units"]["when"] == "tincan_version_after is changed"
    idle = INNER["Name the idle listeners"]["ansible.builtin.set_fact"]["tincan_idle"]
    assert "split() | length == 1" in idle
    restart = INNER["Restart the idle tincan listeners on the new build"]
    assert restart["loop"] == "{{ tincan_idle | default([]) }}"
    order = ["Update tincan", "Read the tincan version after its upgrade", "List the tincan listener units",
             "Read each listener's control group", "Read the processes in each listener's control group",
             "Name the idle listeners", "Restart the idle tincan listeners on the new build"]
    assert [NAMES.index(n) for n in order] == sorted(NAMES.index(n) for n in order)


def test_banned_hermes_tools_are_removed_not_left_to_page():
    assert INNER["Remove them, and list them in the report"]["ansible.builtin.file"]["state"] == "absent"
    assert NAMES.index("Find the banned tools Hermes has installed") < NAMES.index("Remove them, and list them in the report")
    assert NAMES.index("Remove them, and list them in the report") < NAMES.index("Restart the Hermes services on the new code")


def test_report_reads_stay_safe_when_a_command_prints_nothing():
    report = next(t for t in BLOCK["always"] if t["name"] == "Report the run")["ansible.builtin.debug"]["msg"]
    for key in ("app_versions_before", "app_versions_after"):
        assert "map('default', '')" in report[key] and "stdout_lines" not in report[key]


def test_every_new_step_is_checked_in_the_final_assert():
    that = " ".join(ASSERT["ansible.builtin.assert"]["that"])
    for var in ("hermes_update", "hermes_restart", "tincan_upgrade", "tincan_listeners", "app_versions_after"):
        assert var in that


def test_every_update_held_back_gets_one_digest_line():
    report = next(t for t in BLOCK["always"] if t["name"] == "Report the run")
    digest = report["ansible.builtin.debug"]["msg"]["checked_not_applied"]
    for hold in ("cua_desk_busy", "tincan_busy", "reboot_flag.stat.exists"):
        assert hold in digest, hold
