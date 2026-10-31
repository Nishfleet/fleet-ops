"""fleet-ops#10275: a hand-off whose deliverable went to another repo is not a dead end.

The hand-off never writes to another repo: it files an issue in the product repo and
comments the marker the prompt pins (`orchestrator: deliverable filed in <url>`), with
`gh pr list` empty in fleet-ops and the deliverable present only in the product repo.
The cleanup step then marks nothing, while an issue without a trusted marker, or with
one from a stranger, still gets handoff-ended. This test runs the real `run:`
block of "Clean up and mark a PR-less hand-off" from agent-dispatch.yml against a fake
gh, as test_sweep_requeue.py does; the --jq program the step carries is evaluated by
real jq, so the marker match itself is under test.
"""
import json
import os
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
STEP = "Clean up and mark a PR-less hand-off"
MARKER = (
    "orchestrator: deliverable filed in https://github.com/Nishfleet/rera-report-card/issues/42;"
    " this issue stays open and closes on a receipt when that issue is delivered."
)

FAKE_GH = r"""#!/usr/bin/env bash
case "$1 $2" in
  "pr list") jq "${@: -1}" "$FAKE_DIR/prs.json" ;;
  "issue view")
    [ -z "$FAIL_COMMENTS" ] || exit 1
    jq -r "${@: -1}" "$FAKE_DIR/comments.json" ;;
  "api graphql") echo 0 ;;
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


def _comment(body, association="MEMBER", login="nish3451"):
    return {"body": body, "authorAssociation": association, "author": {"login": login}}


def _setup(tmp_path, comments, prs=(), fail_comments=False):
    home = tmp_path / "home"
    (tmp_path / "runtime").mkdir()
    (tmp_path / "bin").mkdir()
    gh = tmp_path / "bin" / "gh"
    gh.write_text(FAKE_GH)
    gh.chmod(0o755)
    (tmp_path / "prs.json").write_text(json.dumps(list(prs)))
    (tmp_path / "comments.json").write_text(json.dumps({"comments": comments}))
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
    if fail_comments:
        env["FAIL_COMMENTS"] = "1"
    return env


def _cleanup(env):
    return subprocess.run(
        ["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", _run_block()],
        env=env, capture_output=True, text=True,
    )


def test_marker_comment_is_accepted_and_nothing_is_marked(tmp_path):
    env = _setup(tmp_path, [_comment(MARKER)])
    r = _cleanup(env)
    assert r.returncode == 0, r.stderr
    assert (
        "orchestrate: #10275 deliverable filed in another repo: "
        "https://github.com/Nishfleet/rera-report-card/issues/42; nothing to mark"
    ) in r.stdout.splitlines()
    assert not (tmp_path / "writes.log").exists()


def test_last_marker_wins(tmp_path):
    older = _comment(
        "orchestrator: deliverable filed in https://github.com/Nishfleet/old/issues/1; superseded."
    )
    env = _setup(tmp_path, [older, _comment(MARKER)])
    r = _cleanup(env)
    assert r.returncode == 0, r.stderr
    assert "another repo: https://github.com/Nishfleet/rera-report-card/issues/42" in r.stdout
    assert "Nishfleet/old/issues/1" not in r.stdout
    assert not (tmp_path / "writes.log").exists()


def test_no_marker_still_marks_ended(tmp_path):
    env = _setup(tmp_path, [_comment("orchestrator: picked up, PR https://github.test/Nishfleet/fleet-ops/pull/1")])
    r = _cleanup(env)
    assert r.returncode == 0, r.stderr
    writes = (tmp_path / "writes.log").read_text()
    assert "--add-label handoff-ended --remove-label needs-orchestrator" in writes
    assert "orchestrator hand-off ended without a PR:" in writes


def test_marker_from_the_worker_app_is_accepted(tmp_path):
    env = _setup(tmp_path, [_comment(MARKER, association="CONTRIBUTOR", login="nishfleet-worker")])
    r = _cleanup(env)
    assert r.returncode == 0, r.stderr
    assert "deliverable filed in another repo" in r.stdout
    assert not (tmp_path / "writes.log").exists()


def test_marker_from_a_stranger_still_marks_ended(tmp_path):
    env = _setup(tmp_path, [_comment(MARKER, association="NONE", login="stranger")])
    r = _cleanup(env)
    assert r.returncode == 0, r.stderr
    assert "--add-label handoff-ended --remove-label needs-orchestrator" in (tmp_path / "writes.log").read_text()


def test_comment_read_failure_marks_nothing(tmp_path):
    env = _setup(tmp_path, [], fail_comments=True)
    r = _cleanup(env)
    assert r.returncode == 0, r.stderr
    assert "comment read failed; nothing to mark" in r.stdout
    assert not (tmp_path / "writes.log").exists()


def test_pr_on_the_head_still_skips_before_the_marker(tmp_path):
    env = _setup(tmp_path, [_comment(MARKER)], prs=[{"number": 1}])
    r = _cleanup(env)
    assert r.returncode == 0, r.stderr
    assert "has a PR on orch/issue-10275; nothing to mark" in r.stdout
    assert not (tmp_path / "writes.log").exists()
