"""Host-play tasks that outlive the dockerd eval: the root podman socket mask, the alert gates."""

import ansible_host

MASK_TASK = "Mask the unused root podman API socket"


def _mask() -> dict:
    found = [t for t in ansible_host.play()["tasks"] if t.get("name") == MASK_TASK]
    assert len(found) == 1, "one task must mask the unused root podman API socket"
    return found[0]["ansible.builtin.systemd_service"]


def test_the_unused_root_podman_api_socket_is_masked() -> None:
    assert _mask() == {"name": "podman.socket", "state": "stopped", "masked": True}


def test_no_other_play_task_touches_the_root_podman_api_socket() -> None:
    others = [t.get("name") for t in ansible_host.play()["tasks"] if t.get("name") != MASK_TASK and "podman.socket" in str(t)]
    assert not others, others


def test_the_host_playbook_keeps_the_tasks_this_change_must_not_drop() -> None:
    host = ansible_host.text()
    assert host.count("alertmanager_credentials is defined and (") == 4
