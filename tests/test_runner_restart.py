"""A changed runner unit, .env or .path restarts its runners through an Ansible handler.

A runner reads those files only at start (fleet-ops#11715 left 15 runners on the old unit).
Ansible's handlers are the stock way to restart a service when a task changed its config:
https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_handlers.html
"""
import ansible_host

POOLS = {
    "Restart the agent runners": ("fleet-runner@{{ item }}.service", "{{ fleet_runner_ids }}"),
    "Restart the review runners": ("fleet-reviewer-runner@{{ item }}.service", "{{ fleet_reviewer_runner_ids }}"),
}


def _play():
    return ansible_host.play()


def _notifies(task):
    n = task.get("notify", [])
    return [n] if isinstance(n, str) else n


def test_each_pool_has_a_handler_that_restarts_every_runner():
    handlers = {h["name"]: h for h in _play()["handlers"]}
    for name, (unit, loop) in POOLS.items():
        assert handlers[name]["ansible.builtin.systemd_service"] == {"name": unit, "state": "restarted"}
        assert handlers[name]["loop"] == loop


def test_systemd_reloads_before_a_runner_restarts():
    names = [h["name"] for h in _play()["handlers"]]
    assert all(names.index("Reload systemd") < names.index(n) for n in POOLS)


def test_the_unit_env_and_path_tasks_notify_their_pool():
    tasks = _play()["tasks"]
    for name, unit_file, home in (("Restart the agent runners", "fleet-runner@.service", "/var/lib/fleet-runner/"),
                                  ("Restart the review runners", "fleet-reviewer-runner@.service", "/var/lib/fleet-reviewer/")):
        notifying = [t for t in tasks if name in _notifies(t)]
        dests = sorted(t["ansible.builtin.copy"]["dest"] for t in notifying)
        assert dests == sorted([f"/etc/systemd/system/{unit_file}", f"{home}{{{{ item }}}}/.env",
                                f"{home}{{{{ item }}}}/.path"])


def test_the_runner_units_are_copied_before_the_unit_tree():
    dests = [t.get("ansible.builtin.copy", {}).get("dest") for t in _play()["tasks"]]
    tree = dests.index("/etc/systemd/system/")
    assert dests.index("/etc/systemd/system/fleet-runner@.service") < tree
    assert dests.index("/etc/systemd/system/fleet-reviewer-runner@.service") < tree


def test_no_task_restarts_a_runner_outside_the_handlers():
    for t in _play()["tasks"]:
        svc = t.get("ansible.builtin.systemd_service", {})
        assert not (svc.get("state") == "restarted" and "runner" in str(svc.get("name"))), t["name"]
        assert "Runner.Worker" not in str(t.get("ansible.builtin.shell", "")), t["name"]
