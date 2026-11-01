"""fleet-ops#10275: a hand-off whose deliverable went to another repo is not a dead end.

The hand-off files the product issue and records it as the fleet-ops issue's own
blocked_by dependency, the wait prompts/worker.md step 4 records, keeping
needs-orchestrator on. GitHub owns the state: the dispatch gate skips the issue while
the dependency is open, the summary clears when the product issue closes, and the
cleared summary puts the issue back in the sweep's re-fire queue for its receipt
close. So the cleanup step marks nothing while an open blocker stands, and an issue
with no blocker still gets handoff-ended. This test runs the real `run:` block of
"Clean up and mark a PR-less hand-off" from agent-dispatch.yml against a fake gh, as
test_sweep_requeue.py does; the --jq program the step carries is evaluated by real jq,
so the summary read itself is under test.
"""
import json
import os
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
STEP = "Clean up and mark a PR-less hand-off"
BODY = "no due: line in here\n"
FUTURE_DUE = "due: 2099-01-01 09:00 IST\n"

FAKE_GH = r"""#!/usr/bin/env bash
case "$1 $2" in
  "pr list") jq "${@: -1}" "$FAKE_DIR/prs.json" ;;
  "api graphql") echo 0 ;;
  "api "*) [ -z "$FAIL_DEPS" ] || exit 1; jq -r "${@: -1}" "$FAKE_DIR/issue.json" ;;
  "issue view") cat "$FAKE_DIR/body" ;;
  "label create"|"issue edit"|"issue comment") echo "$*" >> "$FAKE_DIR/writes.log" ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 1 ;;
esac
"""


def _run_block():
    out = subprocess.run(
        ["yq", f'.jobs.orchestrate.steps[] | select(.name == "{STEP}") | .run', str(ROOT / ".github/workflows/agent-dispatch.yml")],
        check=True, capture_output=True, text=True,
    ).stdout
    assert out.strip(), f"step {STEP!r} not found"
    return out


def _setup(tmp_path, blocked=0, body=BODY, prs=(), fail_deps=False):
    home = tmp_path / "home"
    (tmp_path / "runtime").mkdir()
    (tmp_path / "bin").mkdir()
    gh = tmp_path / "bin" / "gh"
    gh.write_text(FAKE_GH)
    gh.chmod(0o755)
    (tmp_path / "prs.json").write_text(json.dumps(list(prs)))
    (tmp_path / "issue.json").write_text(json.dumps({"issue_dependencies_summary": {"blocked_by": blocked}}))
    (tmp_path / "body").write_text(body)
    env = {
        **os.environ,
        "HOME": str(home),
        "XDG_RUNTIME_DIR": str(tmp_path / "runtime"),
        "PATH": f"{tmp_path / 'bin'}:{os.environ['PATH']}",
        "FAKE_DIR": str(tmp_path),
        "REPO": "Nishfleet/fleet-ops",
        "ISSUE": "10275",
        "GO": "true",
        "SESSION_OUTCOME": "success",
        "GH_TOKEN": "x",
        "GITHUB_SERVER_URL": "https://github.test",
        "GITHUB_RUN_ID": "1",
    }
    if fail_deps:
        env["FAIL_DEPS"] = "1"
    return env


def _cleanup(env):
    return subprocess.run(
        ["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", _run_block()],
        env=env, capture_output=True, text=True,
    )


def test_an_open_blocker_marks_nothing(tmp_path):
    env = _setup(tmp_path, blocked=1, body=FUTURE_DUE)
    r = _cleanup(env)
    assert r.returncode == 0, r.stderr
    assert "orchestrate: #10275 has a linked closing PR or an open blocker, or a read failed; nothing to mark" in r.stdout.splitlines()
    assert not (tmp_path / "writes.log").exists(), "an open blocker wins even over a future due:"


def test_no_blocker_still_marks_ended(tmp_path):
    env = _setup(tmp_path)
    r = _cleanup(env)
    assert r.returncode == 0, r.stderr
    writes = (tmp_path / "writes.log").read_text()
    assert "--add-label handoff-ended --remove-label needs-orchestrator" in writes
    assert "orchestrator hand-off ended without a PR:" in writes


def test_dependency_read_failure_marks_nothing(tmp_path):
    env = _setup(tmp_path, fail_deps=True)
    r = _cleanup(env)
    assert r.returncode == 0, r.stderr
    assert "or a read failed; nothing to mark" in r.stdout
    assert not (tmp_path / "writes.log").exists()


def test_pr_on_the_head_skips_before_the_reads(tmp_path):
    env = _setup(tmp_path, blocked=1, prs=[{"number": 1}])
    r = _cleanup(env)
    assert r.returncode == 0, r.stderr
    assert "has a PR on orch/issue-10275; nothing to mark" in r.stdout
    assert not (tmp_path / "writes.log").exists()
