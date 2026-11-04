"""A file this change deletes, that the base play installs, is listed for removal.

`ansible.builtin.copy` never deletes a file it stops installing
(https://docs.ansible.com/ansible/latest/collections/ansible/builtin/copy_module.html),
so dropping a file and its install line leaves the live copy on the box. That
happened in fleet-ops#11687 (prompts/worker.md). The play deletes a live path only
when it is in `retired`, `retired_units` or `retired_user_units`. A rootfs/ file
is installed by a folder copy, so the play never names it. The play is read as
parsed YAML, so a file named only in a comment does not count.

The change is HEAD against its first parent: on a pull request and in the merge
queue, CI checks out a merge commit whose first parent is main.
"""
import json
import pathlib
import subprocess

import ansible_host

ROOT = pathlib.Path(__file__).resolve().parents[1]


def _git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True, text=True).stdout


def test_a_deleted_installed_file_is_retired():
    base = _git("rev-parse", "HEAD^1").strip()
    deleted = _git("diff", "--no-renames", "--name-only", "--diff-filter=D", base, "HEAD").split()
    base_play = json.dumps(ansible_host.play(base))
    v = ansible_host.play()["vars"]
    removed = [*v["retired"], *v["retired_units"], *v["retired_user_units"]]
    removed_names = {pathlib.PurePath(p).name for p in removed}
    missing = []
    for path in deleted:
        name = pathlib.PurePath(path).name
        installed = path.startswith("rootfs/") or name in base_play
        if installed and name not in removed_names:
            missing.append(path)
    assert not missing, (
        "Deleted here, but the base play installs them, so the live copy stays on the box: "
        + ", ".join(missing)
        + ". Fix: add each live path to `retired` (or the unit to `retired_units` or "
        "`retired_user_units`) in ansible/host.yml.")
