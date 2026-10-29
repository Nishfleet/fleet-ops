"""fleet-ops#11014: a hand-off that ends with no PR on an issue whose `due:` line is still in
the future must park it on-hold, not orchestrator-tried.

orchestrator-tried is the label the parked hand-off sweep re-fires and later-sweep skips, so a
future-dated issue could never reach its date: three tries, then needs-nish-decision, then a
person clears the label. This runs the real `run:` block of agent-dispatch.yml's no-PR step
against a fake gh, one case per branch.
"""
import os
import pathlib
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
WF = ROOT / ".github/workflows/agent-dispatch.yml"
STEP = "Clean up and mark a PR-less hand-off"

FAKE_GH = r"""#!/usr/bin/env bash
case "$1 $2" in
  "pr list") echo 0 ;;
  "api graphql") echo 0 ;;
  "issue view") cat "$FAKE_DIR/body" ;;
  "label create"|"issue edit"|"issue comment") echo "$*" >> "$FAKE_DIR/writes.log" ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 1 ;;
esac
"""

FUTURE = "due: 2099-01-01 09:00 IST\n\nThe read is the first full 48h after a trial that ends.\n"


def _run_block():
    out = subprocess.run(
        ["yq", f'.jobs.orchestrate.steps[] | select(.name == "{STEP}") | .run', str(WF)],
        check=True, capture_output=True, text=True,
    ).stdout
    assert out.strip(), f"step {STEP!r} not found"
    return out


def run(tmp_path, body):
    """The step's real run block. HOME holds no mirror and no worktree, so the cleanup is a no-op."""
    home = tmp_path / "home"
    home.mkdir()
    (tmp_path / "body").write_text(body)
    gh = tmp_path / "gh"
    gh.write_text(FAKE_GH)
    gh.chmod(0o755)
    env = {
        **os.environ,
        "PATH": f"{tmp_path}{os.pathsep}{os.environ['PATH']}",
        "FAKE_DIR": str(tmp_path),
        "HOME": str(home),
        "XDG_RUNTIME_DIR": str(tmp_path / "no-user-runtime-dir"),
        "REPO": "Nishfleet/fleet-ops",
        "ISSUE": "11011",
        "GO": "true",
        "GITHUB_SERVER_URL": "https://example.invalid",
        "GITHUB_RUN_ID": "7",
    }
    done = subprocess.run(
        ["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", _run_block()],
        env=env, capture_output=True, text=True,
    )
    assert done.returncode == 0, done.stdout + done.stderr
    log = tmp_path / "writes.log"
    return done.stdout, log.read_text().splitlines() if log.exists() else []


def edits(writes):
    return [line for line in writes if line.startswith("issue edit")]


@pytest.mark.parametrize("body", [FUTURE, "prose first\n\ndue: 2099-01-01 09:00 IST\n"], ids=["first-line", "mid-body"])
def test_a_future_due_parks_on_hold_and_never_marks_it_tried(tmp_path, body):
    out, writes = run(tmp_path, body)
    assert edits(writes) == [
        "issue edit 11011 -R Nishfleet/fleet-ops --add-label on-hold --remove-label needs-orchestrator"
    ], writes
    assert not [line for line in writes if "orchestrator-tried" in line], writes
    assert not [line for line in writes if "ended without a PR" in line], (
        "the sweep counts that comment prefix as a strike"
    )
    assert "marked on-hold (no PR)" in out


@pytest.mark.parametrize(
    "body",
    [
        "due: 2020-01-01 09:00 IST\n",
        "no due line at all\n",
        "due: 2099-13-01 09:00 IST\n",
        "due: 2099-01-01 09:00 PST\n",
        "due: 2099-01-01 9:00 IST\n",
        "",
    ],
    ids=["past", "none", "month-13", "not-IST", "one-digit-hour", "empty"],
)
def test_a_past_missing_or_unreadable_due_marks_it_tried_as_today(tmp_path, body):
    _, writes = run(tmp_path, body)
    assert edits(writes) == [
        "issue edit 11011 -R Nishfleet/fleet-ops --add-label orchestrator-tried --remove-label needs-orchestrator"
    ], writes
    assert not [line for line in writes if "on-hold" in line], writes
