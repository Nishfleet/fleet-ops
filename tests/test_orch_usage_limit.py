"""fleet-ops#10732: a hand-off that hits the Claude usage limit did no work, so the run
does not fail and the issue is not marked orchestrator-tried.

On 2026-10-27/28, 61 of 72 failed orchestrate sessions were this limit (job 122939721613),
each one a red run and a spent try. These tests run the real `run:` blocks of the session
and cleanup steps from agent-dispatch.yml. Only `claude` and `gh` are fakes: the fake
claude prints the result line that job logged and exits 1.
"""
import json
import os
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/agent-dispatch.yml"
LIMIT = {"type": "result", "subtype": "success", "is_error": True, "num_turns": 1, "terminal_reason": "api_error",
         "api_error_status": 429, "api_error_origin": "first_party", "api_error": "usage_limit_reached",
         "result": "You've hit your 5-hour limit · resets 11pm (Asia/Kolkata)"}
MAX_TURNS = {"type": "result", "subtype": "error_max_turns", "is_error": True, "num_turns": 81, "terminal_reason": "max_turns"}


def _block(step):
    out = subprocess.run(["yq", f'.jobs.orchestrate.steps[] | select(.name == "{step}") | .run', str(WORKFLOW)],
                         check=True, capture_output=True, text=True).stdout
    assert out.strip() and out.strip() != "null", f"step {step!r} not found"
    return out


def _bash(script, env):
    return subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", script], env=env, capture_output=True, text=True)


def _session(tmp_path, result, code):
    home = tmp_path / "home"
    (home / ".local/bin").mkdir(parents=True)
    fake = home / ".local/bin/claude"
    (tmp_path / "result.json").write_text(json.dumps(result) + "\n")
    fake.write_text(f"#!/bin/sh\ncat > /dev/null\ncat {tmp_path / 'result.json'}\nexit {code}\n")
    fake.chmod(0o755)
    wt = tmp_path / "wt"
    (wt / "prompts").mkdir(parents=True)
    (wt / "prompts/orchestrator-handoff.md").write_text("---\n")
    out = tmp_path / "out"
    out.write_text("")
    env = {**os.environ, "HOME": str(home), "WORKTREE": str(wt), "RUNNER_TEMP": str(tmp_path), "GITHUB_OUTPUT": str(out),
           "REPO_NAME": "o/r", "ISSUE_N": "5", "ORCH_RUNNER": "claude", "MODEL": "", "TURNS": "80", "HOOKS": "", "SEAT": ""}
    return _bash(_block("Run the orchestrator session"), env), out.read_text()


def test_usage_limit_passes_and_sets_limited(tmp_path):
    r, out = _session(tmp_path, LIMIT, 1)
    assert r.returncode == 0, r.stderr
    assert "limited=true" in out.splitlines()
    assert "::warning::orchestrate: Claude usage limit reached" in r.stdout


def test_other_failure_still_fails(tmp_path):
    r, out = _session(tmp_path, MAX_TURNS, 1)
    assert r.returncode == 1
    assert "limited" not in out


def test_success_passes_without_limited(tmp_path):
    r, out = _session(tmp_path, {"type": "result", "subtype": "success", "is_error": False}, 0)
    assert r.returncode == 0, r.stderr
    assert "limited" not in out


def _cleanup(tmp_path, limited):
    stub = tmp_path / "bin"
    stub.mkdir()
    log = tmp_path / "gh.log"
    (stub / "gh").write_text(f'#!/bin/sh\necho "$*" >> {log}\ncase "$*" in *"pr list"*) echo 0 ;; esac\n')
    (stub / "gh").chmod(0o755)
    env = {**os.environ, "PATH": f"{stub}:{os.environ['PATH']}", "HOME": str(tmp_path / "home"),
           "XDG_RUNTIME_DIR": str(tmp_path / "no-runtime"), "REPO": "o/r", "ISSUE": "5", "GO": "true", "LIMITED": limited,
           "GITHUB_SERVER_URL": "https://github.com", "GITHUB_RUN_ID": "1"}
    r = _bash(_block("Clean up and mark a PR-less hand-off"), env)
    return r, log.read_text() if log.exists() else ""


def test_limited_run_is_not_marked_tried(tmp_path):
    r, calls = _cleanup(tmp_path, "true")
    assert r.returncode == 0, r.stderr
    assert "orchestrator-tried" not in calls
    assert "hit the Claude usage limit" in r.stdout


def test_unlimited_run_without_pr_is_still_marked_tried(tmp_path):
    r, calls = _cleanup(tmp_path, "")
    assert r.returncode == 0, r.stderr
    assert "--add-label orchestrator-tried" in calls
