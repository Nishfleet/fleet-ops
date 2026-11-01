"""fleet-ops#10275, as tightened by fleet-ops#11530: a hand-off whose deliverable went
to another repo is not a dead end, and its ending is not invisible either.

The hand-off files the product issue and records it as the fleet-ops issue's own
blocked_by dependency, the wait prompts/worker.md step 4 records, keeping
needs-orchestrator on. GitHub owns the state: the dispatch gate skips the issue while
a blocker is open, the summary reads open blockers only (fleet-ops#10289), so the
summary clears when the product issue closes, and the cleared summary puts the issue
back in the sweep's re-fire queue for its receipt close. So the cleanup step marks
nothing while an open cross-repo blocker stands — but it still posts the hand-off
ending, naming the run and the blocker, so recording a dependency dodges the mark
nowhere and a run that dies after recording the dependency leaves its ending. A
same-repo blocker, a closed blocker and no blocker all reach the mark below, and a
read failure marks nothing. This test runs the real `run:` block of "Clean up and
mark a PR-less hand-off" from agent-dispatch.yml against a fake gh, as
test_sweep_requeue.py does; the --jq program the step carries is evaluated by real
jq with $ENV.REPO set, so the blocker list read itself is under test.
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
  "api "*) [ -z "$FAIL_DEPS" ] || exit 1; jq -r "${@: -1}" "$FAKE_DIR/blockers.json" ;;
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


def dep(repo, num, state="open"):
    """One blocked_by entry, the shape the list endpoint returns."""
    return {"number": num, "state": state, "html_url": f"https://github.com/{repo}/issues/{num}"}


def _setup(tmp_path, blockers=(), body=BODY, prs=(), fail_deps=False):
    home = tmp_path / "home"
    (tmp_path / "runtime").mkdir()
    (tmp_path / "bin").mkdir()
    gh = tmp_path / "bin" / "gh"
    gh.write_text(FAKE_GH)
    gh.chmod(0o755)
    (tmp_path / "prs.json").write_text(json.dumps(list(prs)))
    (tmp_path / "blockers.json").write_text(json.dumps(list(blockers)))
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


def _edits(tmp_path):
    return [line for line in (tmp_path / "writes.log").read_text().splitlines() if line.startswith("issue edit")]


def _comments(tmp_path):
    return [line for line in (tmp_path / "writes.log").read_text().splitlines() if line.startswith("issue comment")]


def test_an_open_cross_repo_blocker_posts_the_ending_but_marks_nothing(tmp_path):
    """The deliverable is open in another repo, so no mark goes on — and the ending
    still lands on the issue with the run URL and the blocker named, over a future
    due: too, because the wait is the product issue, not the calendar."""
    env = _setup(tmp_path, blockers=[dep("nish3451/agent-fleet", 999)], body=FUTURE_DUE)
    r = _cleanup(env)
    assert r.returncode == 0, r.stderr
    comments = _comments(tmp_path)
    assert len(comments) == 1
    assert "orchestrator hand-off ended without a PR: https://github.test/Nishfleet/fleet-ops/actions/runs/1" in comments[0], comments
    assert "https://github.com/nish3451/agent-fleet/issues/999" in comments[0], comments
    assert "on hold until the due date" not in comments[0], comments
    assert not _edits(tmp_path), "the deliverable waits in another repo; handoff-ended says it was here"
    assert not [line for line in (tmp_path / "writes.log").read_text().splitlines() if line.startswith("label create")]


def test_a_same_repo_blocker_is_still_marked_ended(tmp_path):
    """The skip is cross-repo only: a dependency a hand-off recorded against an issue
    in its own repo dodges nothing, its run still carries the dead-end mark and the
    sweep escalates on it."""
    env = _setup(tmp_path, blockers=[dep("Nishfleet/fleet-ops", 42)])
    r = _cleanup(env)
    assert r.returncode == 0, r.stderr
    assert _edits(tmp_path) == [
        "issue edit 10275 -R Nishfleet/fleet-ops --add-label handoff-ended --remove-label needs-orchestrator"
    ]
    assert "orchestrator hand-off ended without a PR:" in _comments(tmp_path)[0]


def test_a_closed_blocker_is_still_marked_ended(tmp_path):
    """A closed blocker's record is the takeover branch's input, not a block on this
    run: only an open one stops the mark, whatever repo the blocker sat in."""
    env = _setup(tmp_path, blockers=[dep("nish3451/agent-fleet", 999, state="closed")])
    r = _cleanup(env)
    assert r.returncode == 0, r.stderr
    assert _edits(tmp_path) == [
        "issue edit 10275 -R Nishfleet/fleet-ops --add-label handoff-ended --remove-label needs-orchestrator"
    ]


def test_no_blocker_still_marks_ended(tmp_path):
    env = _setup(tmp_path)
    r = _cleanup(env)
    assert r.returncode == 0, r.stderr
    assert _edits(tmp_path) == [
        "issue edit 10275 -R Nishfleet/fleet-ops --add-label handoff-ended --remove-label needs-orchestrator"
    ]
    assert "orchestrator hand-off ended without a PR:" in _comments(tmp_path)[0]


def test_dependency_read_failure_marks_nothing(tmp_path):
    env = _setup(tmp_path, fail_deps=True)
    r = _cleanup(env)
    assert r.returncode == 0, r.stderr
    assert "the blocker list read failed; nothing to mark" in r.stdout
    assert not (tmp_path / "writes.log").exists()


def test_pr_on_the_head_skips_before_the_reads(tmp_path):
    env = _setup(tmp_path, prs=[{"number": 1}])
    r = _cleanup(env)
    assert r.returncode == 0, r.stderr
    assert not (tmp_path / "writes.log").exists()
