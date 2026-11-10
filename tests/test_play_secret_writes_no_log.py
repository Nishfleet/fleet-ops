"""Every task that writes a credential file reports nothing to the play log.

fleet-ops#11863: a runner copy task's --diff printed a credential value into
/var/lib/fleet-ops/fleet-host-config.log, which every local user could read.
The play is read as one text with import_tasks files inlined
(tests/ansible_host.py), and the test fails when a task whose destination or
rendered content looks like a credential file (a nish-held .env, or anything
whose literal destination or rendered content mentions a password, token or
secret) lacks no_log. Ansible's own answer for where the bytes land is no_log
on the task:
https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_privacy.html
"""
import re

import ansible_host
import yaml

WRITE_MODULES = (
    "ansible.builtin.copy",
    "ansible.builtin.template",
    "ansible.builtin.lineinfile",
    "ansible.builtin.blockinfile",
)

# Word-match so a rendered `apiKey` that only names the nish-held .env a tool
# reads itself (pi's "!cut" reference) does not look like a value in the task.
SECRET_WORD = re.compile(r"(?i)\b(password|passwd|token|secret)\b")
# A variable whose name names a secret (redis_password, tether_space_token):
# inside Jinja marks the underscore means no \b, so match the name itself.
SECRET_VAR = re.compile(r"(?i)\{\{[^}]*?(password|passwd|token|secret)")


def writes_a_credential_file(task: dict) -> bool:
    module = next((m for m in WRITE_MODULES if m in task), None)
    if module is None:
        return False
    args = task[module]
    if not isinstance(args, dict):
        return False
    content = f"{args.get('content', '')} {args.get('line', '')}"
    if SECRET_WORD.search(content) or SECRET_VAR.search(content):
        return True
    # Vars get stripped: `{{ github_app_token_dir }}` paths hold the token
    # minter's code, not a credential value.
    dest = re.sub(r"\{\{.*?\}\}", "", str(args.get("dest", "")))
    if SECRET_WORD.search(dest):
        return True
    # A copy whose source is a nish-held .env ships a credential file.
    return bool(str(args.get("src", "")).endswith(".env"))


def walk(tasks: object) -> list[dict]:
    found = []
    for task in tasks or []:
        if not isinstance(task, dict):
            continue
        if writes_a_credential_file(task):
            found.append(task)
        for key in ("block", "rescue", "always"):
            found.extend(walk(task.get(key)))
    return found


def test_credential_file_writes_are_no_log() -> None:
    play = yaml.safe_load(ansible_host.text())[0]
    flagged = walk(play.get("tasks"))
    assert len(flagged) > 0, "no task was recognised as writing a credential file;"\
        " the rule has gone blind and protects nothing"
    loose = [
        task.get("name")
        for task in flagged
        if task.get("no_log") is not True
    ]
    assert loose == [], (
        f"tasks writing a credential file without no_log: "
        f"{loose} (Ansible, 'Protecting sensitive data with no_log', fleet-ops#11863)"
    )
