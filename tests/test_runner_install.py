"""The play owns each agent runner's install and registration (fleet-ops#11927).

A runner copied by hand can miss ``externals/node20`` or ``externals/node24``;
``runsvc.sh`` then exits 127 before the listener. The stock actions/runner release
and the vendor's ``config.sh`` are the install path, and the bundled-Node check
must run before any task that can notify a runner restart (fleet-ops#11826).
"""

import pathlib

import ansible_host

ROOT = pathlib.Path(__file__).resolve().parents[1]
PLAY = ansible_host.play()


def _task(name):
    return next(task for task in PLAY["tasks"] if task.get("name") == name)


def test_the_pinned_actions_runner_release_is_downloaded_and_unpacked_per_id():
    download = _task("Download the pinned actions runner for the agent pool")["ansible.builtin.get_url"]
    assert download["url"] == (
        "https://github.com/actions/runner/releases/download/"
        "v{{ fleet_runner_version }}/actions-runner-linux-x64-{{ fleet_runner_version }}.tar.gz"
    )
    assert download["checksum"] == "sha256:{{ fleet_runner_sha256 }}"

    unpack = _task("Unpack the pinned actions runner where an install is incomplete")
    assert unpack["ansible.builtin.unarchive"]["src"] == "{{ fleet_runner_tarball }}"
    assert unpack["ansible.builtin.unarchive"]["dest"] == "/var/lib/fleet-runner/{{ item }}/"
    assert unpack["ansible.builtin.unarchive"]["remote_src"] is True
    assert unpack["loop"] == "{{ fleet_runner_install_repairs }}"


def test_the_repair_uses_the_same_two_node_binaries_the_check_reads():
    for name in ("Read each runner's bundled Node before the install",
                 "Read each runner's bundled Node after the install"):
        stat = _task(name)["ansible.builtin.stat"]
        assert stat["path"] == "/var/lib/fleet-runner/{{ item.0 }}/externals/{{ item.1 }}/bin/node"
    assert _task("Read each runner's bundled Node before the install")["loop"] == (
        "{{ fleet_runner_ids | product(['node20', 'node24']) | list }}"
    )


def test_a_missing_bundled_node_fails_before_install_config_can_restart_a_runner():
    tasks = PLAY["tasks"]
    check = next(i for i, task in enumerate(tasks)
                 if task.get("name") == "Fail before any restart when a runner install has no bundled Node")
    unit_copy = next(i for i, task in enumerate(tasks)
                     if task.get("ansible.builtin.copy", {}).get("dest")
                     == "/etc/systemd/system/fleet-runner@.service")
    env_copy = next(i for i, task in enumerate(tasks)
                    if task.get("ansible.builtin.copy", {}).get("dest")
                    == "/var/lib/fleet-runner/{{ item }}/.env")
    assert check < unit_copy < env_copy
    assert tasks[check]["ansible.builtin.assert"]["that"] == "item.stat.exists"


def test_every_id_gets_the_root_runsvc_script_the_agent_unit_starts():
    unit = (ROOT / "rootfs/etc/systemd/system/fleet-runner@.service").read_text()
    assert "ExecStart=/var/lib/fleet-runner/%i/runsvc.sh" in unit
    copy = _task("Lay down the runner script the agent unit starts")["ansible.builtin.copy"]
    assert copy["src"] == "/var/lib/fleet-runner/{{ item }}/bin/runsvc.sh"
    assert copy["dest"] == "/var/lib/fleet-runner/{{ item }}/runsvc.sh"
    assert copy["remote_src"] is True
    assert copy["mode"] == "0755"
    assert copy["force"] is False


def test_a_new_id_is_registered_with_the_vendor_config_script_and_no_token_in_argv():
    mint = _task("Mint a registration token for the runner ids with no registration")
    assert mint["no_log"] is True
    assert "orgs/Nishfleet/actions/runners/registration-token" in mint["ansible.builtin.command"]["argv"]

    register = _task("Register each runner id that has no registration")
    assert register["no_log"] is True
    command = register["ansible.builtin.command"]
    assert command["argv"][0] == "/bin/sh"
    assert command["argv"][-1] == (
        "exec ./config.sh --unattended --replace --url https://github.com/Nishfleet "
        '--token "$RUNNER_REGISTRATION_TOKEN" --name "netcup-agent-$RUNNER_ID" '
        "--runnergroup agent --labels agent --work _work"
    )
    assert register["environment"]["RUNNER_REGISTRATION_TOKEN"] == "{{ fleet_runner_registration_token.stdout }}"
    assert "$RUNNER_REGISTRATION_TOKEN" in command["argv"][-1]
