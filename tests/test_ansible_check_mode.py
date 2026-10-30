"""The check_mode: false tasks of the apply play run for real on the plan run.

Their only safety is module choice: --check skips modules without check-mode
support, so a forced task must mean "read the box and report". Until these
tests, that rule was prose. An allow-list holds every forced site in the play
(black and the one own playbook): so any added forced task with another module
fails here before it can run for real on the plan run's host.
"""

import pathlib
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
FILES = ["ansible/host.yml", "ansible/tasks/secrets.yml", "ansible/tasks/alerting.yml",
         "ansible/tasks/install-config.yml", "ansible/tasks/mcp-and-agent-clis.yml",
         "ansible/tasks/tether.yml", "ansible/tasks/retired-and-drift.yml"]

# The plan's promise: a --check run reads the box and never changes it. A
# forced task stays inside these read-only modules: stat and find walk the
# filesystem, set_fact derives from earlier results, and command reads one
# binary's own census output (promtool/amtool/nft checks, git reads, gh auth
# token, claude mcp get, grep). Modules that would change state and on which
# --check cannot even predict (systemd, copy, git apply) are never forced.
_READ_ONLY_MODULES = frozenset({"stat", "find", "set_fact", "command"})

_ANSIBle_META = (
    "name", "check_mode", "become", "become_user", "become_flags", "when", "changed_when",
    "failed_when", "register", "loop", "loop_control", "vars", "environment", "no_log",
    "ignore_errors", "args", "tags", "notify", "delegate_to", "delegate_facts", "timeout",
    "run_once", "listen", "with_fileglob", "with_items", "with_flattened",
)


def _task_tasks(node):
    """Every forced task, nested blocks and rescue arms included."""
    if not isinstance(node, (list, dict)):
        return
    if isinstance(node, dict):
        if "check_mode" in node:
            yield node
        for key in ("block", "rescue", "always"):
            yield from _task_tasks(node.get(key))
        return
    for entry in node:
        yield from _task_tasks(entry)


def test_every_forced_task_is_a_read_only_probe():
    findings = []
    for rel in FILES:
        for doc in yaml.safe_load((ROOT / rel).read_text()) or []:
            if not isinstance(doc, dict):
                continue
            for task in _task_tasks(doc.get("tasks")):
                module_keys = [k for k in task if k not in _ANSIBle_META]
                lend = [k for k in module_keys if k not in ("block", "rescue", "always")]
                if len(lend) != 1:
                    findings.append(f"{rel}: {task.get('name', '')!r}: task keys are {sorted(task)}")
                    continue
                module = lend[0].rsplit(".", 1)[-1]
                if module not in _READ_ONLY_MODULES:
                    findings.append(
                        f"{rel}: forced task {task.get('name', '')!r} runs module {module!r}, "
                        "not a read-only probe; a --check plan run would execute it for real")
                if module == "command" and ("changed_when" not in task or "failed_when" not in task):
                    findings.append(
                        f"{rel}: forced command task {task.get('name', '')!r} must set "
                        "changed_when and failed_when so the plan run reads and moves on")
    assert not findings, "\n".join(findings)
