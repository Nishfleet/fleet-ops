"""The docker group stays empty and Tether stays on its Podman quadlet.

fleet-ops#12062: membership in the docker group is root access — any member
mounts the host filesystem into a container it starts — so the play may never
add an account to the group, and the unit that runs Tether must stay the
fleet-tether Podman quadlet, never a Docker-run unit again.

The play is read as parsed YAML with tasks/tether.yml put back in its place
(ansible_host.text), so a word in a comment does not count. gpasswd -d (drop
one member, what the play itself runs) and deluser are removals and pass.
Unit files are checked on Exec lines only: quadlet Image= lines legitimately
name docker.io, and comments name Docker freely.
"""
import re
from pathlib import Path

import ansible_host

ROOT = Path(__file__).resolve().parents[1]

ARGV_MODULES = (
    "ansible.builtin.command",
    "ansible.builtin.shell",
    "ansible.builtin.raw",
    "ansible.builtin.script",
)

# argv/cmd shapes that put an account INTO a group. -M replaces the member
# list, so it adds too.
ADD_PATTERNS = (
    re.compile(r"\bgpasswd\s+-[aM]\b"),
    re.compile(r"\busermod\s+[^;\n]*\s-(aG|Ga|G)\b"),
    re.compile(r"\badduser\s+\S+\s+docker\b"),
    re.compile(r"\buseradd\s+[^;\n]*\s-G\b"),
)


def tasks(items):
    for t in items or []:
        if isinstance(t, dict):
            yield t
            for key in ("block", "rescue", "always", "tasks", "handlers", "pre_tasks", "post_tasks"):
                yield from tasks(t.get(key))


def argv_string(task: dict) -> str:
    for mod in ARGV_MODULES:
        value = task.get(mod)
        if value is None:
            continue
        if isinstance(value, str):
            return value
        return " ".join(str(a) for a in (value.get("argv") or [value.get("cmd") or value.get("executable", "")]))
    return ""


def test_the_play_adds_no_account_to_the_docker_group() -> None:
    bad = []
    for task in tasks(ansible_host.play()["tasks"]):
        label = f"{task.get('name', '<unnamed task>')}"
        user = task.get("ansible.builtin.user")
        if isinstance(user, dict):
            # A list item, or any string (fail closed on a `{{ ... }}` that
            # renders from docker-named data).
            groups = user.get("groups")
            if (isinstance(groups, list) and "docker" in groups) or (
                isinstance(groups, str) and "docker" in groups
            ) or user.get("group") == "docker":
                bad.append(f"{label}: ansible.builtin.user puts an account in the docker group")
        cmd = argv_string(task)
        if any(p.search(cmd) for p in ADD_PATTERNS):
            bad.append(f"{label}: {cmd}")
    assert not bad, (
        "The play adds an account to the docker group, which is root access "
        "(fleet-ops#12062): " + "; ".join(bad)
    )


def unit_files() -> list[Path]:
    paths = [
        *(ROOT / "rootfs/etc/systemd").rglob("*"),
        *(ROOT / "systemd").rglob("*"),
        *(ROOT / "containers/quadlet").glob("*"),
        *(ROOT / "ansible/templates").glob("*.j2"),
    ]
    return sorted(p for p in paths if p.is_file())


def test_no_unit_runs_tether_through_docker() -> None:
    bad = []
    for path in unit_files():
        for raw in path.read_text(errors="replace").splitlines():
            if re.match(r"^\s*Exec\w+\s*=", raw) and "docker" in raw:
                bad.append(f"{path.relative_to(ROOT)}: {raw.strip()}")
    assert not bad, (
        "A unit file runs something through Docker again (fleet-ops#12062): " + "; ".join(bad)
    )


def test_the_retired_tether_unit_stays_gone() -> None:
    left = [
        str(p.relative_to(ROOT))
        for p in (ROOT / "rootfs/etc/systemd").rglob("tether-agent*")
    ]
    assert not left, f"the retired tether-agent unit is back under rootfs/: {left}"
    in_tasks = [
        task.get("name", "<unnamed task>")
        for task in tasks(ansible_host.play()["tasks"])
        if "tether-agent" in str(task)
    ]
    assert not in_tasks, (
        "the play installs the retired tether-agent unit again (fleet-ops#12062): " + "; ".join(in_tasks)
    )


def test_the_tether_quadlet_is_what_the_play_installs() -> None:
    template = ROOT / "ansible/templates/fleet-tether.container.j2"
    assert template.is_file(), "ansible/templates/fleet-tether.container.j2 must exist"
    quadlet = [
        task.get("name", "<unnamed task>")
        for task in tasks(ansible_host.play()["tasks"])
        if isinstance(task.get("ansible.builtin.template"), dict)
        and "fleet-tether.container" in str(task["ansible.builtin.template"])
    ]
    assert quadlet, "the play must render fleet-tether.container into /etc/containers/systemd/"
