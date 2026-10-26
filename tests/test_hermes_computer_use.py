"""Hermes computer_use needs the Bot Desktop packages and a config opt-in to its own headless screen.

The owner declined Hermes' cua-driver, so no task installs it. Nothing points at a display of the live desktop.
"""
import json
import pathlib
import shutil
import subprocess

import pytest

if not shutil.which("yq"):
    pytest.skip("yq missing", allow_module_level=True)

ROOT = pathlib.Path(__file__).resolve().parents[1]
HOST = ROOT / "ansible/host.yml"
PLAY = json.loads(subprocess.run(["yq", "-o=json", ".", str(HOST)], capture_output=True, text=True, check=True).stdout)[0]
TASKS = {t["name"]: t for t in PLAY["tasks"]}
APT = TASKS["Install the Bot Desktop packages Hermes computer_use needs on a headless host"]
OPT_IN = TASKS["Let Hermes start its own headless Bot Desktop when computer_use needs a display"]


def test_packages_are_the_ones_hermes_reports_missing():
    module = APT["ansible.builtin.apt"]
    assert module["state"] == "present" and module["install_recommends"] is False
    assert set(module["name"]) == {
        "tigervnc-standalone-server", "xfce4-panel", "xfwm4", "xfdesktop4", "xfce4-settings",
        "dbus-x11", "x11-xserver-utils", "x11-utils", "x11-xkb-utils", "xauth", "fonts-dejavu-core",
    }
    assert "become" not in APT


def test_no_task_installs_the_declined_driver():
    assert "computer-use" not in json.dumps(PLAY["tasks"])
    assert "cua-driver" not in json.dumps(PLAY["tasks"])


def test_opt_in_is_one_idempotent_line_and_never_names_a_display():
    module = OPT_IN["ansible.builtin.lineinfile"]
    assert module["line"] == "bot_desktop: {auto_start: true}"
    assert "regexp" not in module
    assert OPT_IN["become"] is True and OPT_IN["become_user"] == "nish"
    assert "mcp_servers" not in OPT_IN["when"]
    assert "bot_desktop:" in OPT_IN["when"]
    assert "DISPLAY" not in json.dumps(OPT_IN)
    assert "hermes_config.content is defined" in OPT_IN["when"]
