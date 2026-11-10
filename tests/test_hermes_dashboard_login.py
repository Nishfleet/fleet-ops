"""The dashboard login settings load for both Hermes units, and the deploy checks the gateway.

With dashboard.public_url set (ansible/tasks/services.yml, Hermes web-dashboard.md
"Public URL override") the login gate is mandatory, so every Hermes unit needs
/home/nish/.hermes/secrets.env, the file the serve unit read alone (fleet-ops#11900).
The shared hermes-.service.d/sandbox.conf drop-in loads it for both: for
foo-bar.service systemd reads foo-.service.d/ as well (systemd NEWS, v209).
The load used to be a hand-placed hermes-gateway.service.d drop-in; the play
retires that folder once this drop-in line is live.
"""

from pathlib import Path

import ansible_host

ROOT = Path(__file__).resolve().parents[1]
SYSTEM = ROOT / "rootfs/etc/systemd/system"
DROPIN = SYSTEM / "hermes-.service.d/sandbox.conf"
SERVE = SYSTEM / "hermes-serve.service"
ENV_FILE = "/home/nish/.hermes/secrets.env"
RETIRED_DROPIN_DIR = "/etc/systemd/system/hermes-gateway.service.d"
RESTART_TASK = "Restart Hermes onto the minted login"


def test_the_shared_dropin_loads_serve_s_env_file() -> None:
    serve_lines = [
        line
        for line in SERVE.read_text().splitlines()
        if line.startswith("EnvironmentFile=")
    ]
    assert serve_lines == [f"EnvironmentFile={ENV_FILE}"], (
        f"{SERVE} must stay the unit the dashboard login settings' file is named in; "
        "update the copy here with it"
    )
    lines = DROPIN.read_text().splitlines()
    assert f"EnvironmentFile=-{ENV_FILE}" in lines, (
        f"{DROPIN} must load {ENV_FILE} for both Hermes units (systemd.exec(5), "
        "EnvironmentFile=; fleet-ops#11900): hermes-gateway.service is installer-written "
        "and reads this drop-in, hermes-serve.service reads the unit above, and with "
        "dashboard.public_url set the login gate is mandatory for both"
    )


def test_the_hand_placed_gateway_dropin_folder_is_retired() -> None:
    retired = ansible_host.play()["vars"]["retired"]
    assert RETIRED_DROPIN_DIR in retired, (
        f"{RETIRED_DROPIN_DIR} is the 2026-11-10 hand-placed drop-in folder that carried "
        "the dashboard login settings during fleet-ops#11900's crash loop; the shared "
        f"{DROPIN} line loads the same file for both Hermes units now, so the folder "
        "must go with the play"
    )


def test_the_play_fails_when_the_gateway_is_not_active_30s_after_the_restart() -> None:
    tasks = ansible_host.play()["tasks"]
    names = [t.get("name", "") for t in tasks]
    restart = next(
        (i for i, t in enumerate(tasks) if t.get("name") == RESTART_TASK), -1
    )
    assert restart != -1, f"{RESTART_TASK} must stay the task the check sits after"

    def after(task_name: str) -> int:
        try:
            index = names.index(task_name)
        except ValueError:
            index = -1
        return index

    settle = after("Give hermes-gateway 30 seconds to settle after the restart")
    read = after("Read hermes-gateway's state 30 seconds after the restart")
    gate = after("Fail when hermes-gateway is not active 30 seconds after the restart")
    assert 0 < restart < settle < read < gate, [
        n for n in names if "hermes-gateway" in n
    ]
    wait, assertion = (
        tasks[settle].get("ansible.builtin.wait_for", {}),
        tasks[gate].get("ansible.builtin.assert", {}),
    )
    assert wait.get("timeout") == 30
    assert restart + 1 == settle, (
        "the settle wait must be the first thing after the restart"
    )
    assert "hermes-gateway is" in assertion.get("fail_msg", ""), (
        "the failure must name the symptom"
    )
