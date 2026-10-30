"""fleet-ops#11166: the hand-off cleanup step must not count an ending the provider owns as a
strike.

On 2026-10-30 the router's 429s killed 14 hand-offs and all 14 walked to needs-nish-decision,
because the sweep counts the "orchestrator hand-off ended without a PR: " comment prefix whatever
killed the run. The cleanup step now posts "orchestrator hand-off ended on infrastructure: "
instead when the session step failed and its logged output names a router error. This runs the
real `run:` block of that step against a fake gh, one case per ending kind.
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

BODY = "Take over issue #9 and land a PR. No due: line in here.\n"


def _block(name, wf=WF):
    out = subprocess.run(
        ["yq", f'.jobs.orchestrate.steps[] | select(.name == "{name}") | .run', str(wf)],
        check=True, capture_output=True, text=True,
    ).stdout
    assert out.strip(), f"step {name!r} not found"
    return out


def run(tmp_path, outcome="success", log=None):
    """The step's real run block, with RUNNER_TEMP holding whatever the session step logged."""
    home = tmp_path / "home"
    home.mkdir()
    (tmp_path / "body").write_text(BODY)
    runner_temp = tmp_path / "runner-temp"
    runner_temp.mkdir()
    if log is not None:
        (runner_temp / "orchestrator.log").write_text(log)
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
        "SESSION_OUTCOME": outcome,
        "RUNNER_TEMP": str(runner_temp),
        "GITHUB_SERVER_URL": "https://example.invalid",
        "GITHUB_RUN_ID": "7",
    }
    done = subprocess.run(
        ["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", _block(STEP)],
        env=env, capture_output=True, text=True,
    )
    assert done.returncode == 0, done.stdout + done.stderr
    writes = tmp_path / "writes.log"
    return writes.read_text().splitlines() if writes.exists() else []


def edits(writes):
    return [line for line in writes if line.startswith("issue edit")]


def comments(writes):
    return [line for line in writes if line.startswith("issue comment")]


@pytest.mark.parametrize(
    "log",
    [
        "litellm.RateLimitError: Rate limit exceeded for model pi/worker-capable. Retrying in 900 seconds (429).\n",
        "litellm.Router: No deployments available for model pi/worker-capable\n",
        "insufficient balance: exhibiting RateLimitError, provider list retry\n",
    ],
    ids=["429", "no-deployments", "rate-limit"]
)
def test_a_session_that_dies_on_a_router_error_is_an_infra_ending(tmp_path, log):
    """A failed session whose log names a router error gets the prefix the sweep never counts."""
    writes = run(tmp_path, outcome="failure", log="session output\n" + log)
    assert edits(writes) == [
        "issue edit 11011 -R Nishfleet/fleet-ops --add-label handoff-ended --remove-label needs-orchestrator"
    ], writes
    assert len(comments(writes)) == 1, writes
    assert "orchestrator hand-off ended on infrastructure: https://example.invalid/Nishfleet/fleet-ops/actions/runs/7" in comments(writes)[0], writes
    assert "ended without a PR" not in comments(writes)[0], writes


@pytest.mark.parametrize(
    "outcome,log",
    [
        ("failure", "npm error code EFAIL\nnpm test failed\n"),
        ("success", "the issue text quotes its own router (429) outage\n"),
        ("failure", None),
        ("skipped", "litellm.RateLimitError: (429)\n"),
    ],
    ids=["clean-failure", "success-quoting-429", "no-log", "never-ran"]
)
def test_a_clean_or_successful_session_is_still_the_works_ending(tmp_path, outcome, log):
    """A clean failure, a session that succeeded but mentioned a 429, a missing log, and a skipped
    session all count as the work's ending, so a broken issue still reaches the owner."""
    writes = run(tmp_path, outcome=outcome, log=log)
    assert edits(writes) == [
        "issue edit 11011 -R Nishfleet/fleet-ops --add-label handoff-ended --remove-label needs-orchestrator"
    ], writes
    assert len(comments(writes)) == 1, writes
    assert "orchestrator hand-off ended without a PR: " in comments(writes)[0], writes
    assert "hand-off ended on infrastructure" not in comments(writes)[0], writes


def test_both_sides_name_one_session_log():
    """The file the session step logs is the file the cleanup step greps: renaming either alone
    would turn every infra ending back into a strike."""
    session = _block("Run the orchestrator session")
    cleanup = _block(STEP)
    assert 'tee "$RUNNER_TEMP/orchestrator.log"' in session, session
    assert 'grep -qiE' in cleanup and "orchestrator.log" in cleanup, cleanup
