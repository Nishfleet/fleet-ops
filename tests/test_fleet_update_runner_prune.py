"""The update's runner version prune: it deletes only what no runner points at.

A runner updates itself in place: it unpacks bin.<version>/ and
externals.<version> beside the pair it runs from, repoints the bin and externals
symlinks, and never removes the pair it moved off. Nothing removed those, so the
tree grew by about 680 MB per runner per update (fleet-ops#10632: 60 stale pairs,
20.3 GB on one host).
"""
import ast
import json
import pathlib
import shutil
import subprocess

import jinja2
import pytest

if not shutil.which("yq"):
    pytest.skip("yq missing", allow_module_level=True)

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = subprocess.run(
    ["yq", "-o=json", ".", str(ROOT / "ansible/update.yml")], capture_output=True, text=True, check=True
)
PLAY = json.loads(OUT.stdout)[0]


def walk(tasks):
    for task in tasks:
        yield task
        for key in ("block", "always", "rescue"):
            if key in task:
                yield from walk(task[key])


TASKS = {task["name"]: task for task in walk(PLAY["tasks"])}
LINKS = TASKS["List the runner version each runner's bin and externals symlink points at"]
TARGETS = TASKS["Read the version directory each of those symlinks points at"]
CANDIDATES = TASKS["List the runner version directories older than a self-update"]
REMOVE = TASKS["Remove the runner version directories no runner points at"]


def test_both_symlinks_are_read_not_only_bin():
    """bin and externals name the same version in two directories.

    Keeping only the bin target deletes the version externals runs from and
    leaves that link broken, so both links are listed and both targets kept.
    """
    assert sorted(LINKS["ansible.builtin.find"]["patterns"]) == ["bin", "externals"]
    assert LINKS["ansible.builtin.find"]["file_type"] == "link"
    assert TARGETS["loop"] == "{{ runner_version_links.files | map(attribute='path') | list }}"
    assert "runner_version_targets.results | map(attribute='stat.lnk_source')" in REMOVE["loop"]


def test_a_version_unpacked_in_the_last_hour_survives():
    """A runner stopped mid-self-update may have unpacked without repointing.

    The stop above the prune is what makes it safe, and the hour is the second
    belt for that runner: its fresh directory is not a link target yet, so age
    is the only thing that keeps it. An archive's mtime can make a directory
    look older than it is, so the belt is loose, not a window.
    """
    assert CANDIDATES["ansible.builtin.find"]["age"] == "1h"
    assert sorted(CANDIDATES["ansible.builtin.find"]["patterns"]) == ["bin.*", "externals.*"]
    assert CANDIDATES["ansible.builtin.find"]["file_type"] == "directory"


def test_both_finds_walk_the_root_resolved_the_same_way_stat_reports():
    """stat reports a link's target as a realpath.

    If the candidates were walked under an unresolved root, a symlinked path
    component would leave no candidate matching the keep set, and the prune
    would delete the version every runner runs from.
    """
    for task in (LINKS, CANDIDATES):
        assert task["ansible.builtin.find"]["paths"] == ["{{ agent_runner_root | realpath }}"]


def test_the_prune_removes_only_directories():
    assert REMOVE["ansible.builtin.file"] == {"path": "{{ item }}", "state": "absent"}
    assert REMOVE["loop"].startswith("{{ runner_version_dirs.files | map(attribute='path')")
    assert REMOVE["loop"].rstrip().endswith("| list }}")


def test_the_summary_reports_what_was_removed():
    """A prune nobody can read is a prune nobody can check."""
    reports = [task["ansible.builtin.debug"]["msg"] for task in walk(PLAY["tasks"])
               if "runner_version_dirs_removed" in json.dumps(task.get("ansible.builtin.debug", {}))]
    assert len(reports) == 1
    assert "selectattr('changed') | map(attribute='item')" in reports[0]["runner_version_dirs_removed"]
    assert "selectattr('failed', 'defined') | selectattr('failed') | map(attribute='item')" in reports[0]["runner_version_dirs_failed"]
    assert reports[0]["runner_version_prune_ran"].endswith("results | default([]) | length > 0 }}")
    assert "runner_version_prune.skipped" not in reports[0]["runner_version_prune_ran"]


def _render(expression, keep, candidates):
    """Evaluate the task's own expression against a runner tree, as the play would."""
    template = expression if expression.lstrip().startswith("{{") else "{{ " + expression + " }}"
    env = jinja2.Environment()
    return env.from_string(template).render(
        runner_version_dirs={"files": [{"path": path} for path in candidates]},
        runner_version_targets={"results": [{"stat": {"lnk_source": path}} for path in keep]},
    )


def test_the_expression_deletes_only_what_no_runner_points_at():
    """The rule is the expression, so the expression is what the test runs.

    Two links, one stale pair and one fresh pair, as on the host: the fresh pair
    is absent from the candidates because the age guard already removed it.
    """
    stale = ["/r/13/bin.2.337.0", "/r/13/externals.2.337.0"]
    live = ["/r/13/bin.2.338.0", "/r/13/externals.2.338.0"]
    rendered = _render(REMOVE["loop"], live, stale + live)
    assert sorted(ast.literal_eval(rendered)) == stale


def test_an_empty_keep_set_removes_nothing():
    """A link the play cannot read must not turn the prune into a wipe.

    An empty keep set makes every directory a candidate, so the guard is what
    stops the task from deleting the version each runner is running from.
    """
    candidates = ["/r/13/bin.2.338.0", "/r/13/externals.2.338.0"]
    assert _render(REMOVE["when"], [], candidates).strip() == "False"
    assert _render(REMOVE["when"], candidates, candidates).strip() == "True"


def test_a_skipped_link_read_reads_as_an_empty_keep_set():
    """The stat loop skips when no link was found.

    A skipped register carries no results key, so the guard must read that as
    an empty keep set, not as an expression error.
    """
    template = "{{ " + REMOVE["when"] + " }}"
    rendered = jinja2.Environment().from_string(template).render(runner_version_targets={})
    assert rendered.strip() == "False"
