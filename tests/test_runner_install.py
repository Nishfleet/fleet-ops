"""The play owns each agent runner's install (fleet-ops#11927).

A runner copied by hand can miss ``externals/node20`` or ``externals/node24``;
``runsvc.sh`` then exits 127 before the listener. The stock actions/runner release
is the install path, and the bundled-Node check must run before any task that can
notify a runner restart (fleet-ops#11826). The tests assert the ordering and the
presence of the steps, not their wording: a task is found by the module it runs
and by the data it is wired to, never by the text of an expression.
"""

import pathlib

import ansible_host

ROOT = pathlib.Path(__file__).resolve().parents[1]
PLAY = ansible_host.play()
TASKS = PLAY["tasks"]


def _unpack_index():
    return next(i for i, t in enumerate(TASKS)
                if "ansible.builtin.unarchive" in t
                and "/var/lib/fleet-runner/" in t["ansible.builtin.unarchive"]["dest"])


def _node_stats():
    return [t for t in TASKS
            if "externals" in t.get("ansible.builtin.stat", {}).get("path", "")]


def _stat_after_the_install():
    """The stat that reads the bundled Node once the release is unpacked."""
    later = [t for t in TASKS[_unpack_index() + 1:]
             if "externals" in t.get("ansible.builtin.stat", {}).get("path", "")]
    assert len(later) == 1, "one stat reads the bundled Node after the install"
    return later[0]


def _node_check():
    """The assert that fails when a runner install has no bundled Node."""
    register = _stat_after_the_install()["register"]
    checks = [t for t in TASKS
              if "ansible.builtin.assert" in t
              and isinstance(t.get("loop"), str)
              and register in t["loop"] and ".results" in t["loop"]]
    assert len(checks) == 1, "one assert reads the results of the stat after the install"
    return checks[0]


def _notifies(task, handler):
    notify = task.get("notify", [])
    names = [notify] if isinstance(notify, str) else notify
    return handler in names


def test_the_release_is_downloaded_once_and_unpacked_where_an_install_is_incomplete():
    download = next(t for t in TASKS
                    if "actions-runner-linux-x64" in t.get("ansible.builtin.get_url", {}).get("url", ""))
    unpack = next(t for t in TASKS
                  if "ansible.builtin.unarchive" in t
                  and "/var/lib/fleet-runner/" in t["ansible.builtin.unarchive"]["dest"])
    assert TASKS.index(download) < TASKS.index(unpack)
    # The unpack consumes the file the download produced.
    assert unpack["ansible.builtin.unarchive"]["src"] == download["ansible.builtin.get_url"]["dest"]
    # A --check run has no tarball and no incomplete install: neither step may fail it.
    for step in (download, unpack):
        assert "ansible_check_mode" in step["ignore_errors"]


def test_the_node_check_reads_the_same_bundled_binaries_before_and_after_the_install():
    stats = _node_stats()
    assert len(stats) == 2
    assert stats[0]["ansible.builtin.stat"]["path"] == stats[1]["ansible.builtin.stat"]["path"]


def test_a_missing_bundled_node_fails_before_any_restart_can_be_notified():
    check = TASKS.index(_node_check())
    restarts = [i for i, t in enumerate(TASKS) if _notifies(t, "Restart the agent runners")]
    assert restarts, "the play must notify the agent runner restart somewhere"
    assert check < min(restarts)


def test_each_id_gets_the_runsvc_script_the_unit_starts_even_in_check_mode():
    unit = (ROOT / "rootfs/etc/systemd/system/fleet-runner@.service").read_text()
    exec_start = next(line.split("=", 1)[1] for line in unit.splitlines()
                      if line.startswith("ExecStart="))
    copy_task = next(t for t in TASKS
                     if t.get("ansible.builtin.copy", {}).get("src", "").endswith("bin/runsvc.sh"))
    copy = copy_task["ansible.builtin.copy"]
    # The unit starts the script the copy writes, for every id.
    assert copy["dest"].replace("{{ item }}", "%i") == exec_start
    assert copy["remote_src"] is True
    # A --check run skips the unpack, so a new id has no bin/runsvc.sh to copy yet:
    # the missing source may not fail the check (the other install steps guard too).
    assert "ansible_check_mode" in copy_task["ignore_errors"]


def test_the_guard_names_the_missing_node_without_reading_the_stat_result():
    # A stat of a missing file has no `path` key, so the message may not read one:
    # the guard would fail with an error about the message instead of the reason.
    message = _node_check()["ansible.builtin.assert"]["fail_msg"]
    assert "stat.path" not in message
    assert "item.item.0" in message and "item.item.1" in message
