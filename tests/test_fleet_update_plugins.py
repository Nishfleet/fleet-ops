"""The daily update never asks for an update Claude Code refuses for our own plugin policy.

`claude plugin list --json` reports `enabled`, its merge of the user and managed
settings (docs/claude-plugin-drop-ins.md). 85-no-playwright.json switches
playwright@claude-plugins-official off, Claude Code refuses its update with exit 1,
and the run's assert then went red on 30 Oct (fleet-ops#10161). The step updates
only the plugins that report as enabled, and every other failure still reds it.
"""
import json
import os
import pathlib
import shutil
import subprocess

import pytest

if not shutil.which("yq") or not shutil.which("jq"):
    pytest.skip("yq or jq missing", allow_module_level=True)

ROOT = pathlib.Path(__file__).resolve().parents[1]
PLAY = json.loads(subprocess.run(["yq", "-o=json", ".", str(ROOT / "ansible/update.yml")], capture_output=True, text=True, check=True).stdout)[0]
OFF_ID = "playwright@claude-plugins-official"
ON_ID = "inbox@inbox"
BROKEN_ID = "broken@nish-mods"

STUB = """#!/bin/bash
if [ "$1 $2" = "plugin list" ]; then
  if [ -n "${FAKE_LIST_FAIL}" ]; then
    echo "no plugin registry" >&2
    exit 1
  fi
  printf '%s' "${FAKE_PLUGINS}"
  exit 0
fi
case "$3" in
  playwright@claude-plugins-official)
    echo 'Plugin "playwright@claude-plugins-official" is blocked by your organization'"'"'s policy and was not updated' >&2
    exit 1 ;;
  broken@nish-mods)
    echo "network unreachable" >&2
    exit 2 ;;
  *)
    echo "updated $3"
    exit 0 ;;
esac
"""


def walk(tasks):
    for task in tasks:
        yield task
        for key in ("block", "always", "rescue"):
            if key in task:
                yield from walk(task[key])


TASKS = {task["name"]: task for task in walk(PLAY["tasks"]) if "name" in task}
SHELL = TASKS["Update every installed Claude Code plugin"]["ansible.builtin.shell"]


def entry(plugin_id, enabled=True):
    return {
        "id": plugin_id,
        "version": "0.2.14",
        "scope": "user",
        "enabled": enabled,
        "installPath": str(pathlib.Path.home() / ".claude/plugins/cache" / plugin_id.split("@")[1] / plugin_id.split("@")[0] / "0.2.14"),
        "installedAt": "2026-10-08T06:01:47.528Z",
        "lastUpdated": "2026-10-29T23:10:17.848Z",
        "projectEnabled": False,
    }


def _run(monkeypatch, tmp_path, plugins, list_fails=False):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    stub = bin_dir / "claude"
    stub.write_text(STUB)
    stub.chmod(0o755)
    monkeypatch.setenv("PATH", f"{bin_dir}:{os.environ['PATH']}")
    monkeypatch.setenv("FAKE_PLUGINS", json.dumps(plugins))
    monkeypatch.setenv("FAKE_LIST_FAIL", "1" if list_fails else "")
    return subprocess.run([SHELL["executable"], "-c", SHELL["cmd"]], capture_output=True, text=True)


def test_a_plugin_the_settings_report_as_off_is_never_asked_for(monkeypatch, tmp_path):
    done = _run(monkeypatch, tmp_path, [entry(OFF_ID, False), entry(ON_ID)])
    assert done.returncode == 0, done.stderr
    assert f"updated {ON_ID}" in done.stdout
    assert OFF_ID not in done.stdout + done.stderr


def test_a_plugin_with_no_marketplace_is_never_asked_for(monkeypatch, tmp_path):
    session = entry("session-only@m")
    del session["installedAt"], session["enabled"]
    done = _run(monkeypatch, tmp_path, [session, entry(ON_ID)])
    assert done.returncode == 0, done.stderr
    assert f"updated {ON_ID}" in done.stdout
    assert "session-only@m" not in done.stdout + done.stderr


@pytest.mark.parametrize("shape", ["missing", "null"])
def test_a_row_with_no_boolean_enabled_flag_fails_the_run(monkeypatch, tmp_path, shape):
    blind = entry(ON_ID)
    if shape == "missing":
        del blind["enabled"]
    else:
        blind["enabled"] = None
    done = _run(monkeypatch, tmp_path, [blind])
    assert done.returncode != 0
    assert "no enabled flag" in done.stderr


def test_a_refusal_for_a_plugin_it_did_ask_for_still_fails_the_run(monkeypatch, tmp_path):
    done = _run(monkeypatch, tmp_path, [entry(OFF_ID), entry(ON_ID)])
    assert done.returncode != 0
    assert "blocked by your organization'" in done.stderr


def test_any_other_plugin_error_still_fails_the_run(monkeypatch, tmp_path):
    done = _run(monkeypatch, tmp_path, [entry(BROKEN_ID), entry(ON_ID)])
    assert done.returncode != 0
    assert "network unreachable" in done.stderr


def test_a_plugin_list_that_cannot_be_read_still_fails_the_run(monkeypatch, tmp_path):
    done = _run(monkeypatch, tmp_path, [], list_fails=True)
    assert done.returncode != 0


def test_a_box_whose_plugins_are_all_off_is_not_an_error(monkeypatch, tmp_path):
    done = _run(monkeypatch, tmp_path, [entry(OFF_ID, False)])
    assert done.returncode == 0, done.stderr
