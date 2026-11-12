"""A changed runner unit, .env or .path restarts its runners through an Ansible handler.

A runner reads those files only at start (fleet-ops#11715 left 15 runners on the old unit).
Ansible's handlers are the stock way to restart a service when a task changed its config:
https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_handlers.html

The agent restart touches only the runners whose .env or .path changed, because a restart
cancels the job the runner runs (fleet-ops#11932: the pool-to-30 deploy wrote runners 16
to 30 their first .env and .path, restarted all 30, and the 5 agent.yml runs that were
running failed). The review pool is small and idle between reviews, so it stays restart-all.
"""
import ansible_host

POOLS = {
    # The agent pool is not in here: a change restarts only the runners whose file
    # changed (tests below), not every runner (fleet-ops#11932).
    "Restart the review runners": ("fleet-reviewer-runner@{{ item }}.service", "{{ fleet_reviewer_runner_ids }}"),
}

AGENT = "Restart the agent runners"


def _play():
    return ansible_host.play()


def _notifies(task):
    n = task.get("notify", [])
    return [n] if isinstance(n, str) else n


# The Ansible filters the agent handler's loop uses. The tests run without
# ansible-core, so the shims follow the vendor docs exactly (`ternary` and `unique`,
# https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_filters.html).
def _ternary(value, true_value, false_value, none_value=None):
    if value is None:
        return none_value
    return true_value if value else false_value


def _unique(values):
    out = []
    for v in values:
        if v not in out:
            out.append(v)
    return out


def _render_agent_loop(unit, env_results, path_results):
    """The agent handler's loop, evaluated as Ansible would evaluate it.

    The register names come from the tasks that notify the handler, so the render
    checks the wiring too: a task that stops registering, or registers under a name
    the loop does not use, makes the render fail instead of the test pass.
    """
    import jinja2
    from jinja2.nativetypes import NativeEnvironment

    play = _play()
    loop = {h["name"]: h for h in play["handlers"]}[AGENT]["loop"]
    register = {t["ansible.builtin.copy"]["dest"]: t["register"]
                for t in play["tasks"] if AGENT in _notifies(t) and "ansible.builtin.copy" in t}
    env = NativeEnvironment(undefined=jinja2.StrictUndefined)
    env.filters.update(ternary=_ternary, unique=_unique)
    return env.from_string(loop).render({
        "fleet_runner_ids": play["vars"]["fleet_runner_ids"],
        register["/etc/systemd/system/fleet-runner@.service"]: unit,
        register["/var/lib/fleet-runner/{{ item }}/.env"]: {"changed": False, "results": env_results},
        register["/var/lib/fleet-runner/{{ item }}/.path"]: {"changed": False, "results": path_results},
    })


def test_each_pool_has_a_handler_that_restarts_every_runner():
    handlers = {h["name"]: h for h in _play()["handlers"]}
    for name, (unit, loop) in POOLS.items():
        assert handlers[name]["ansible.builtin.systemd_service"] == {"name": unit, "state": "restarted"}
        assert handlers[name]["loop"] == loop


def test_the_agent_handler_restarts_its_runners_after_the_reload():
    handlers = {h["name"]: h for h in _play()["handlers"]}
    names = [h["name"] for h in _play()["handlers"]]
    assert handlers[AGENT]["ansible.builtin.systemd_service"] == {"name": "fleet-runner@{{ item }}.service", "state": "restarted"}
    assert names.index("Reload systemd") < names.index(AGENT)


def test_the_agent_handler_restarts_only_the_changed_runners():
    # The loop is evaluated the way Ansible would, against register data: the proof the
    # handler restarts only the runners whose file changed (fleet-ops#11932: the
    # pool-to-30 deploy restarted all 30, and the 5 agent.yml runs that were running
    # failed).
    ids = _play()["vars"]["fleet_runner_ids"]
    unchanged = [{"item": i, "changed": False} for i in ids]
    runner_16_env_changed = [{"item": i, "changed": i == 16} for i in ids]
    runners_7_and_30_path_changed = [{"item": i, "changed": i in (7, 30)} for i in ids]
    assert _render_agent_loop({"changed": False}, runner_16_env_changed, unchanged) == [16]
    assert _render_agent_loop({"changed": False}, unchanged, runners_7_and_30_path_changed) == [7, 30]
    assert _render_agent_loop({"changed": False}, unchanged, unchanged) == []
    # The unit is one file every runner reads at start: a unit change restarts the pool.
    assert _render_agent_loop({"changed": True}, runner_16_env_changed, unchanged) == ids


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
