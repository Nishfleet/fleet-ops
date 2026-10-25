"""The daily update fails only when a check really failed: the npm check ignores a long-lived `npm exec`, a running npm is recorded instead of aborting the run, and the router is given time before the smoke call."""
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
ASSERT = next(t for t in BLOCK["always"] if t["name"] == "Fail loudly if any step or check went wrong")["ansible.builtin.assert"]
THAT = " ".join(ASSERT["that"])
FAIL_MSG = ASSERT["fail_msg"]
NPM_CHECK = INNER["Check that no npm install or update runs as nish before its staging dirs go"]
PATTERN = NPM_CHECK["ansible.builtin.command"]["argv"][-1]
WAIT = "Wait for the model router to answer before the smoke call"
SMOKE = "Call pi for real, so a broken extension fails here"


def matches(cmdline):
    return subprocess.run(["grep", "-qE", PATTERN], input=cmdline + "\n", text=True).returncode == 0


def test_a_long_lived_npm_exec_is_not_install_activity():
    for cmdline in ("npm exec @modelcontextprotocol/server-filesystem /srv/notes",
                    "npm exec -y @modelcontextprotocol/server-filesystem -- /srv/notes",
                    "npm run build"):
        assert not matches(cmdline), cmdline


def test_a_real_npm_install_or_update_still_stops_the_removal():
    for cmdline in ("npm install -g @openai/codex", "npm update --global", "npm ci",
                    "/usr/bin/npm i -g tincan",
                    "node /usr/lib/node_modules/npm/bin/npm-cli.js i -g tincan"):
        assert matches(cmdline), cmdline


def test_a_flag_before_the_subcommand_is_still_install_activity():
    for cmdline in ("npm -g install", "npm --global update", "npm -g install @openai/codex",
                    "npm --global update --no-audit", "npm --prefix /srv install"):
        assert matches(cmdline), cmdline


def test_the_other_global_writing_subcommands_are_install_activity():
    for cmdline in ("npm rebuild", "npm prune"):
        assert matches(cmdline), cmdline


def test_a_running_npm_is_recorded_for_the_final_assert_instead_of_aborting_the_run():
    assert "Refuse to remove staging dirs while an npm is running" not in NAMES
    assert "npm_running" in THAT
    removal = INNER["Remove them, because npm reads each as an invalid package name"]
    assert "npm_running" in removal["when"]


def test_the_router_is_waited_for_before_the_smoke_call_for_a_bounded_time():
    wait = INNER[WAIT]
    assert wait["ansible.builtin.uri"]["url"] == "http://127.0.0.1:4000/health/readiness"
    assert wait["until"] == "router_before_smoke.status == 200"
    assert 300 <= wait["retries"] * wait["delay"] <= 900
    assert NAMES.index(WAIT) < NAMES.index(SMOKE)
    assert "router_before_smoke" in THAT


def test_the_smoke_call_still_has_to_answer_ok_and_the_failure_text_separates_never_ran_from_failed():
    assert "(pi_smoke | default({})).stdout | default('') is search('OK')" in THAT
    assert "not run, an earlier step in the block failed" in FAIL_MSG
    assert "no reply, stderr: " in FAIL_MSG
