"""Hermes computer_use needs the Bot Desktop packages, its pinned cua-driver and a config opt-in to its own headless screen.

The tasks must use only stock modules, run the Hermes install as nish against the real HERMES_HOME only when the
status check says the driver is missing, and never point anything at a display of the live desktop.
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
CHECK = TASKS["Check whether Hermes has its cua-driver"]
INSTALL = TASKS["Install Hermes' pinned cua-driver"]
OPT_IN = TASKS["Let Hermes start its own headless Bot Desktop when computer_use needs a display"]


def test_packages_are_the_ones_hermes_reports_missing():
    module = APT["ansible.builtin.apt"]
    assert module["state"] == "present" and module["install_recommends"] is False
    assert set(module["name"]) == {
        "tigervnc-standalone-server", "xfce4-panel", "xfwm4", "xfdesktop4", "xfce4-settings", "xfce4-terminal",
        "dbus-x11", "x11-xserver-utils", "x11-utils", "x11-xkb-utils", "xauth", "fonts-dejavu-core",
    }
    assert "become" not in APT


def test_driver_install_runs_as_nish_on_the_real_home_only_when_status_fails():
    for task in (CHECK, INSTALL):
        assert task["become"] is True and task["become_user"] == "nish"
        assert "HERMES_HOME': nish_home ~ '/.hermes'" in task["environment"]
        assert task["ansible.builtin.command"]["argv"][0].endswith("/.local/bin/hermes")
    assert CHECK["ansible.builtin.command"]["argv"][1:] == ["computer-use", "status"]
    assert CHECK["changed_when"] is False
    assert INSTALL["ansible.builtin.command"]["argv"][1:] == ["computer-use", "install"]
    assert INSTALL["when"] == "(hermes_cua_driver.rc | default(0)) == 1"
    assert CHECK["check_mode"] is False and CHECK["timeout"] <= 120 and INSTALL["timeout"] <= 600
    assert INSTALL["failed_when"] is False


def test_opt_in_is_one_idempotent_line_and_never_names_a_display():
    module = OPT_IN["ansible.builtin.lineinfile"]
    assert module["line"] == "bot_desktop: {auto_start: true}"
    assert "regexp" not in module
    assert OPT_IN["become"] is True and OPT_IN["become_user"] == "nish"
    assert "mcp_servers" not in OPT_IN["when"]
    assert "bot_desktop:" in OPT_IN["when"]
    assert "DISPLAY" not in HOST.read_text()


def test_order_is_packages_then_check_then_install():
    names = [t["name"] for t in PLAY["tasks"]]
    assert names.index(APT["name"]) < names.index(CHECK["name"]) < names.index(INSTALL["name"])
