"""Preview before apply, step 1 (fleet-ops#10991): list each changed rootfs file with its live
path and its diff against main's copy.

rootfs/ mirrors /: the file at rootfs/etc/X is installed at /etc/X (ansible/host.yml), so the live
path is the mirrored path. fleet-host-config.service applies that tree as root on every push to
main, and a root `ansible --check` cannot run on a runner, because nftables needs CAP_NET_ADMIN
and NoNewPrivileges blocks sudo. This reads git and the repo instead: no root, and nothing on the
box.

The listing goes to the step summary as well as stdout, because the `unit` job runs `pytest -q`:
`-q` hides printed output when the test passes, so without the summary a clean PR would show no
preview at all.

The one assertion is the preview's own integrity: the diff against main's copy must be a real
diff, so a base that is not main's copy fails here instead of printing nothing. Step 2 (which
task installs each file, and which handler runs after it) is a later issue.
"""
import os
import pathlib
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
ROOTFS = "rootfs"


def _git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True, text=True).stdout


def _base():
    """main's copy: the first parent of the checked-out commit, which is the PR's base. On a
    merge-group entry it is the previous queue entry, so the preview there covers that entry."""
    try:
        return _git("rev-parse", "HEAD^1").strip()
    except subprocess.CalledProcessError as e:
        pytest.fail(f"git rev-parse HEAD^1 failed with {e.stderr.strip()}: the unit job's checkout "
                    "needs fetch-depth: 2 so this preview can read main's copy")


def _changed():
    """(status, repo path) for every file the diff touches under rootfs/."""
    rows = []
    for line in _git("diff", "--name-status", "--no-renames", f"{_base()}..HEAD", "--", ROOTFS).splitlines():
        status, rel = line.split("\t", 1)
        rows.append((status, rel))
    return rows


def test_a_changed_rootfs_file_is_listed_with_its_live_path_and_the_diff_against_main():
    base = _base()
    lines = [f"rootfs preview against main's copy ({base[:12]}):"]
    for status, rel in _changed():
        live = "/" + rel[len(ROOTFS) + 1:]
        lines.append(f"  {rel} -> {live}  [{status}]")
        diff = _git("diff", "--no-color", f"{base}..HEAD", "--", rel).splitlines()
        lines += [f"    {line}" for line in diff]
        assert any(line[:1] in "+-" and not line.startswith(("+++", "---")) for line in diff), (
            f"{rel} is {status}, but its diff against main is empty: the preview is not reading "
            "main's copy")
    if len(lines) == 1:
        lines.append("  no rootfs file changed")
    print("\n".join(lines))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write("```\n" + "\n".join(lines) + "\n```\n")
