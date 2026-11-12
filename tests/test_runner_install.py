"""The play owns each agent runner's install (fleet-ops#11927).

A runner copied by hand can miss ``externals/node20`` or ``externals/node24``;
``runsvc.sh`` then exits 127 before the listener. The stock actions/runner release
is the install path, and the bundled-Node check must run before any task that can
notify a runner restart (fleet-ops#11826). The tests assert the ordering and the
presence of the steps, not their wording: tasks are found by what they do.
"""

import pathlib

import ansible_host

ROOT = pathlib.Path(__file__).resolve().parents[1]
PLAY = ansible_host.play()


def test_the_release_is_downloaded_once_and_unpacked_where_an_install_is_incomplete():
    download = next(t for t in PLAY["tasks"]
                    if "actions-runner-linux-x64" in t.get("ansible.builtin.get_url", {}).get("url", ""))
    unpack = next(t for t in PLAY["tasks"]
                  if "ansible.builtin.unarchive" in t
                  and "/var/lib/fleet-runner/" in t["ansible.builtin.unarchive"]["dest"])
    tasks = PLAY["tasks"]
    assert tasks.index(download) < tasks.index(unpack)
    # The unpack consumes the file the download produced.
    assert unpack["ansible.builtin.unarchive"]["src"] == download["ansible.builtin.get_url"]["dest"]
    # A --check run has no tarball and no incomplete install: neither step may fail it.
    for step in (download, unpack):
        assert "ansible_check_mode" in step["ignore_errors"]


def test_the_node_check_reads_the_same_bundled_binaries_before_and_after_the_install():
    paths = [t["ansible.builtin.stat"]["path"] for t in PLAY["tasks"]
             if "externals" in t.get("ansible.builtin.stat", {}).get("path", "")]
    assert len(paths) == 2
    assert paths[0] == paths[1]


def test_a_missing_bundled_node_fails_before_any_restart_can_be_notified():
    tasks = PLAY["tasks"]
    check = next(i for i, t in enumerate(tasks)
                 if "item.stat.exists" in t.get("ansible.builtin.assert", {}).get("that", ""))
    unit_copy = next(i for i, t in enumerate(tasks)
                     if t.get("ansible.builtin.copy", {}).get("dest")
                     == "/etc/systemd/system/fleet-runner@.service")
    env_copy = next(i for i, t in enumerate(tasks)
                    if t.get("ansible.builtin.copy", {}).get("dest")
                    == "/var/lib/fleet-runner/{{ item }}/.env")
    assert check < unit_copy < env_copy


def test_each_id_gets_the_runsvc_script_the_unit_starts_even_in_check_mode():
    unit = (ROOT / "rootfs/etc/systemd/system/fleet-runner@.service").read_text()
    assert "/var/lib/fleet-runner/%i/runsvc.sh" in unit
    copy_task = next(t for t in PLAY["tasks"]
                     if t.get("ansible.builtin.copy", {}).get("src", "").endswith("bin/runsvc.sh"))
    copy = copy_task["ansible.builtin.copy"]
    assert copy["dest"].endswith("/runsvc.sh")
    assert copy["remote_src"] is True
    # A --check run skips the unpack, so a new id has no bin/runsvc.sh to copy yet:
    # the missing source may not fail the check (the other install steps guard too).
    assert "ansible_check_mode" in copy_task["ignore_errors"]
