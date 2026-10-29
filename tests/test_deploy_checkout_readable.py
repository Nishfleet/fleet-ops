import shlex
from pathlib import Path

import yaml
import ansible_host

ROOT = Path(__file__).resolve().parents[1]
PLAY = ansible_host.play()
UNIT = ROOT / "rootfs/etc/systemd/system/fleet-host-config.service"


def _task() -> dict:
    found = [t for t in PLAY["tasks"] if "ansible.builtin.file" in t and "playbook_dir" in str(t["ansible.builtin.file"].get("path"))]
    assert len(found) == 1, "one task must set the mode of the checkout ansible-pull runs from"
    return found[0]["ansible.builtin.file"]


def test_checkout_is_the_playbook_clone_owned_by_root() -> None:
    task = _task()
    assert task["path"] == "{{ (playbook_dir ~ '/..') | realpath }}"
    assert (task["owner"], task["group"]) == ("root", "root")


def test_checkout_is_readable_by_all_and_writable_by_root_only() -> None:
    task = _task()
    assert task["recurse"] is True
    assert task["mode"] == "u=rwX,go=rX"


def test_checkout_is_the_directory_the_unit_pulls_into() -> None:
    line = next(ln for ln in UNIT.read_text().splitlines() if ln.startswith("ExecStart="))
    argv = shlex.split(line[len("ExecStart="):])
    assert argv[argv.index("--directory") + 1] == "/var/lib/fleet-ops/repo"
    assert "--clean" in argv
