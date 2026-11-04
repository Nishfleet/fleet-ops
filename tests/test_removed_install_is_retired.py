"""A file this change deletes, that the base play installs, has its live path in `retired`.

`ansible.builtin.copy` never deletes a file it stops installing
(https://docs.ansible.com/ansible/latest/collections/ansible/builtin/copy_module.html),
so dropping a file and its install line leaves the live copy on the box. That
happened in fleet-ops#11687 (prompts/worker.md). The play deletes a live path only
when it, or a folder above it, is in `retired`
(https://docs.ansible.com/ansible/latest/collections/ansible/builtin/file_module.html,
`state: absent` deletes a folder with its contents). The test keys on the full live
path, not the file name: four drop-ins share the name 90-podman-newuidmap.conf.
rootfs/X is installed at /X (ansible/host.yml header). Any other file is installed
by a copy or template task whose rendered `src` is that file. The play is read as
parsed YAML, so a file named only in a comment does not count.

The change is HEAD against its first parent: on a pull request and in the merge
queue, CI checks out a merge commit whose first parent is main.
"""
import pathlib
import posixpath
import re
import subprocess

import ansible_host

ROOT = pathlib.Path(__file__).resolve().parents[1]
PATHS = {"playbook_dir": "ansible", "repo_root": ".", "rootfs": "rootfs"}


def _git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True, text=True).stdout


def _render(s: str, v: dict, item=None) -> str:
    def sub(m: re.Match) -> str:
        name, _, key = m.group(1).partition(".")
        if name == "item":
            value = item.get(key) if key else item
        else:
            value = PATHS.get(name, v.get(name))
        return value if isinstance(value, str) else m.group(0)

    for _ in range(5):
        s = re.sub(r"\{\{ ([\w.]+)(?: \| default\(omit\))? \}\}", sub, s)
    return s.rstrip("/")


def _copies(node):
    if isinstance(node, dict):
        for mod in ("ansible.builtin.copy", "ansible.builtin.template"):
            if isinstance(node.get(mod), dict) and "src" in node[mod]:
                loop = node.get("loop")
                for item in loop if isinstance(loop, list) else [None]:
                    yield node[mod]["src"], node[mod].get("dest", ""), item
        for child in node.values():
            yield from _copies(child)
    elif isinstance(node, list):
        for child in node:
            yield from _copies(child)


def _live_paths(rev: str) -> dict:
    """Repo path -> every live path the play at `rev` installs that file at."""
    p = ansible_host.play(rev)
    live = {f: {f[len("rootfs"):]} for f in _git("ls-tree", "-r", "--name-only", rev, "rootfs/").split()}
    for src, dest, item in _copies(p["tasks"]):
        live.setdefault(posixpath.normpath(_render(src, p["vars"], item)), set()).add(_render(dest, p["vars"], item))
    return live


def test_a_deleted_installed_file_is_retired():
    base = _git("rev-parse", "HEAD^1").strip()
    deleted = _git("diff", "--no-renames", "--name-only", "--diff-filter=D", base, "HEAD").split()
    installed = _live_paths(base)
    v = ansible_host.play()["vars"]
    retired = {_render(p, v) for p in v["retired"]}
    missing = []
    for path in deleted:
        for live in sorted(installed.get(path, ())):
            if not {live, *map(str, pathlib.PurePosixPath(live).parents)} & retired:
                missing.append(f"{path} (live at {live})")
    assert not missing, (
        "Deleted here, but the base play installs them, so the live copy stays on the box: "
        + ", ".join(missing)
        + ". Fix: add each live path to `retired` in ansible/host.yml.")
