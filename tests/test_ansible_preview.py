"""Preview before apply, step 2 (fleet-ops#10931): for each ansible-pull play, list the task names
the diff adds and removes, and the handlers every changed task notifies.

`ansible --check --diff` cannot run on a runner: running the play needs root, nftables needs
CAP_NET_ADMIN, and NoNewPrivileges blocks sudo. So this reads the play as data instead:
ansible/host.yml (fleet-host-config.service) and ansible/update.yml (fleet-update.service), the two
plays the box applies, with each import_tasks file put back in its place, read at main's copy and at
the PR's tree. Nothing runs, nothing on the box is touched, and each rootfs/ file still gets step 1's
listing (tests/test_rootfs_preview.py), which shows the file against its live path.

The listing goes to the step summary as well as stdout, because the `unit` job runs `pytest -q`,
which hides printed output when a test passes.

The assertions are the preview's own integrity: a play file that changed must read differently at
main's copy and at the PR's tree, so a base that is not main's copy fails here instead of printing
nothing; and every `notify:` in the PR's play resolves to a handler in that play, because a notify
whose handler is gone leaves the change on the box without the restart that was meant to follow it.
"""
import os
import pathlib
import subprocess

import pytest

import ansible_host

ROOT = pathlib.Path(__file__).resolve().parents[1]


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


def _plays(rev: str) -> list[str]:
    """The play files the named tree holds; a play the diff adds or removes shows up on one side
    of the diff only, so the preview reads its section from the side that has it."""
    return [line for line in _git("ls-tree", "--name-only", "-r", rev, "--", "ansible").splitlines()
            if line.endswith(".yml") and line.count("/") == 1]


def _play(rev: str, rel: str) -> dict:
    """The play at rev; a play the diff removes is absent there, so every entry of it counts."""
    try:
        return ansible_host.play(rev, rel)
    except subprocess.CalledProcessError:
        return {}


def _to_list(value) -> list:
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


def _blocks(entry: dict) -> list:
    return [entry[key] for key in ("block", "rescue", "always") if isinstance(entry.get(key), list)]


def _flatten(node, rows: dict, label: str):
    for item in node:
        if not isinstance(item, dict):
            continue
        if blocks := _blocks(item):
            for one in blocks:
                _flatten(one, rows, label)
            continue
        rows[item.get("name") or f"<unnamed {label}>"] = item


def _entries(play: dict) -> dict:
    """name -> task entry, flattened out of blocks."""
    rows: dict = {}
    _flatten(_to_list(play.get("tasks")), rows, "task")
    return rows


def _handlers(play: dict) -> dict:
    """name -> handler entry, for resolving what a `notify:` names."""
    rows: dict = {}
    _flatten(_to_list(play.get("handlers")), rows, "handler")
    return rows


def _topics(handler: dict) -> list:
    return _to_list(handler.get("listen"))


def _notifies(entry: dict) -> list:
    return _to_list(entry.get("notify"))


def _fires(notify: str, handlers: dict) -> list[str]:
    """The handler names ansible runs for this notify: the handler it names, plus every handler
    listening on that name."""
    return sorted(name for name, entry in handlers.items()
                  if notify == name or notify in _topics(entry))


def _changes(before: dict, after: dict) -> list[tuple[str, str, dict]]:
    out = []
    for name in sorted(set(before) | set(after)):
        if name not in before:
            out.append(("+", name, after[name]))
        elif name not in after:
            out.append(("-", name, before[name]))
        elif before[name] != after[name]:
            out.append(("~", name, after[name]))
    return out


def _sections(base: str) -> list[str]:
    """The listing for every play whose text the diff changes between main's copy and the PR's
    tree, with the raw diff of each file under ansible/ that the diff touches."""
    plays = sorted(set(_plays("HEAD")) | set(_plays(base)))
    changed = sorted(row.split("\t")[1] for row in _git("diff", "--name-status", "--no-renames",
                                                        f"{base}..HEAD", "--", "ansible").splitlines())
    if not changed and not any(ansible_host.text(base, rel) != ansible_host.text("", rel)
                               for rel in plays):
        return []
    lines = ["files under ansible/:"]
    for rel in changed:
        lines.append(f"  {_git('diff', '--no-color', f'{base}..HEAD', '--', rel).rstrip()}")
    for rel in plays:
        before_text, after_text = ansible_host.text(base, rel), ansible_host.text("", rel)
        if not (before_text and after_text):
            # an added or removed play's file diff is already listed above
            continue
        if before_text == after_text:
            continue
        lines.append(f"{rel}: the play the PR puts on the box")
        before, after = _play(base, rel), _play("", rel)
        for mark, name, entry in _changes(_entries(before), _entries(after)):
            handlers = _handlers(after if mark in "+~" else before)
            word = {"+": "notifies", "-": "notified", "~": "notifies"}[mark]
            lines.append(f"  {mark} {name}")
            if _notifies(entry):
                fired = [who for notify in _notifies(entry) for who in _fires(notify, handlers)] or ["nothing"]
                lines.append(f"      {word}: {', '.join(fired)}")
    return lines


def test_a_play_change_is_listed_with_its_task_names_and_the_handlers_they_notify():
    base = _base()
    lines = [f"ansible preview against main's copy ({base[:12]}):"]
    lines += _sections(base)
    if len(lines) == 1:
        lines.append("  no play change")
    print("\n".join(lines))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write("```\n" + "\n".join(lines) + "\n```\n")


def test_every_notify_names_a_handler_that_exists():
    for rel in _plays("HEAD"):
        play = ansible_host.play("", rel)
        handlers = _handlers(play)
        for name, entry in sorted(_entries(play).items()):
            for notify in _notifies(entry):
                assert _fires(notify, handlers), (
                    f"{rel}: {name} notifies {notify!r}, which no handler in the play names or "
                    "listens on")
