"""The `A new component links a design note` step in ci-lint.yml (#10556), run from the
workflow's own text (read out with yq, never a copy) against throwaway git repos.

A PR that adds a unit, quadlet or Pi extension needs a `design-note:` line; a plain
fix, or an edit to an existing unit, does not.
"""
import pathlib
import subprocess

import pytest

CI = pathlib.Path(__file__).resolve().parent.parent / ".github/workflows/ci-lint.yml"
STEP = "A new component links a design note"


def run_step(tmp_path, files, body, docs=()):
    script = subprocess.run(
        ["yq", "-r", f'.jobs.lint.steps[] | select(.name == "{STEP}") | .run', str(CI)],
        check=True, capture_output=True, text=True,
    ).stdout
    git = lambda *a: subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *a], cwd=tmp_path, check=True, capture_output=True, text=True).stdout.strip()
    git("init", "-q", "-b", "main")
    (tmp_path / "systemd").mkdir()
    (tmp_path / "systemd/old.service").write_text("[Unit]\n")
    git("add", "-A")
    git("commit", "-qm", "base")
    base = git("rev-parse", "HEAD")
    for f in (*files, *docs):
        (tmp_path / f).parent.mkdir(parents=True, exist_ok=True)
        (tmp_path / f).write_text("x\n")
    git("add", "-A")
    git("commit", "-qm", "head")
    return subprocess.run(
        ["bash", "-c", script], cwd=tmp_path, capture_output=True, text=True,
        env={"PATH": "/usr/bin:/bin", "BASE_SHA": base, "HEAD_SHA": git("rev-parse", "HEAD"), "PR_BODY": body},
    ).returncode


@pytest.mark.parametrize("new", ["systemd/x.service", "systemd/x.timer", "containers/quadlet/x.container", "pi-extensions/x/package.json"])
def test_new_component_without_note_fails(tmp_path, new):
    assert run_step(tmp_path, [new], "Closes #1") == 1


def test_new_component_with_repo_note_passes(tmp_path):
    assert run_step(tmp_path, ["systemd/x.service"], "x\ndesign-note: docs/design/x.md\r\n", docs=["docs/design/x.md"]) == 0


def test_note_pointing_nowhere_fails(tmp_path):
    assert run_step(tmp_path, ["systemd/x.service"], "design-note: docs/design/missing.md") == 1


def test_new_component_with_url_note_passes(tmp_path):
    assert run_step(tmp_path, ["systemd/x.service"], "design-note: https://github.com/Nishfleet/fleet-ops/issues/1#c") == 0


def test_plain_fix_and_edit_of_existing_unit_pass(tmp_path):
    assert run_step(tmp_path, ["tests/test_a.py", "systemd/old.service"], "Closes #1") == 0
