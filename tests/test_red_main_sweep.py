import json
import os
import pathlib
import subprocess
import time

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
DISPATCH = str(ROOT / ".github/workflows/agent-dispatch.yml")
FIND = ".jobs.red-main.steps[0]"
NOW = int(time.time())
DAY = 86400


def _y(expr, wf=DISPATCH):
    out = subprocess.run(["yq", expr, wf], check=True, capture_output=True, text=True).stdout
    assert out.strip() and out.strip() != "null", expr
    return out


def _iso(ts):
    return subprocess.run(["date", "-u", "-d", f"@{ts}", "+%Y-%m-%dT%H:%M:%SZ"], check=True, capture_output=True, text=True).stdout.strip()


def decide(file, run, issues, trig=("push",), present=None):
    payload = json.dumps({"file": file, "run": run, "trig": list(trig), "issues": issues, "present": [file] if present is None else present})
    out = subprocess.run(
        ["jq", "-c", "--argjson", "now", str(NOW), _y(f"{FIND} | .env.RED_MAIN")],
        input=payload, check=True, capture_output=True, text=True,
    ).stdout
    return json.loads(out)


def red(run_id=100, at=NOW - 3600):
    return {"id": run_id, "conclusion": "failure", "url": f"https://example.invalid/runs/{run_id}", "at": _iso(at), "sha": "f" * 40}


def green(run_id=101, at=NOW - 60):
    return {"id": run_id, "conclusion": "success", "url": f"https://example.invalid/runs/{run_id}", "at": _iso(at), "sha": "a" * 40}


def issue(number, file="deploy.yml", state="OPEN", run_id=100, age=2 * DAY, comments=(), closed_ago=None, author="app/github-actions", labels=("agent-ready",)):
    return {
        "number": number, "state": state, "body": f"red-main: {file}\nred-main-run: {run_id}\n\nbody",
        "author": {"login": author}, "labels": [{"name": n} for n in labels], "createdAt": _iso(NOW - age), "closedAt": None if closed_ago is None else _iso(NOW - closed_ago),
        "comments": list(comments),
    }


def comment(run_id, age):
    return {"body": f"red-main-run: {run_id}\n\nStill red", "createdAt": _iso(NOW - age)}


def test_failing_workflow_with_no_issue_creates_one():
    assert decide("deploy.yml", red(), [])["action"] == "create"


def test_issue_for_another_file_does_not_count():
    assert decide("deploy.yml", red(), [issue(5, file="lighthouse.yml")])["action"] == "create"


def test_marker_must_match_the_whole_line():
    assert decide("ci.yml", red(), [issue(5, file="ci.yml.bak")])["action"] == "create"


def test_same_run_already_reported_is_left_alone():
    v = decide("deploy.yml", red(100), [issue(5, run_id=100)])
    assert v == {"action": "none", "issues": [5], "reason": "this run is already reported"}


def test_new_run_inside_a_day_is_not_commented():
    v = decide("deploy.yml", red(200), [issue(5, run_id=100, age=3600)])
    assert v["action"] == "none" and v["reason"] == "reported within a day"


def test_new_run_after_a_day_is_commented_once():
    v = decide("deploy.yml", red(200), [issue(5, run_id=100, age=3 * DAY, comments=[comment(150, 2 * DAY)])])
    assert v == {"action": "comment", "issues": [5], "reason": "new failing run"}


def test_recent_comment_blocks_a_new_comment():
    v = decide("deploy.yml", red(200), [issue(5, run_id=100, age=3 * DAY, comments=[comment(150, 600)])])
    assert v["action"] == "none"


def test_unrelated_recent_comment_does_not_block():
    chatter = {"body": "working on it", "createdAt": _iso(NOW - 60)}
    v = decide("deploy.yml", red(200), [issue(5, run_id=100, age=3 * DAY, comments=[chatter])])
    assert v["action"] == "comment"


def test_duplicates_are_judged_on_the_lowest_number():
    v = decide("deploy.yml", red(200), [issue(9, age=3 * DAY), issue(5, age=3 * DAY)])
    assert v["issues"] == [5]


def test_green_run_closes_every_open_issue():
    v = decide("deploy.yml", green(), [issue(9), issue(5), issue(7, state="CLOSED", closed_ago=DAY)])
    assert v == {"action": "close", "issues": [5, 9], "reason": "green on the default branch again: https://example.invalid/runs/101"}


def test_green_run_leaves_an_issue_a_worker_has_claimed():
    v = decide("deploy.yml", green(), [issue(5, labels=("agent-in-progress",)), issue(9)])
    assert v == {"action": "close", "issues": [9], "reason": "green on the default branch again: https://example.invalid/runs/101"}


def test_green_run_with_only_a_claimed_issue_does_nothing():
    assert decide("deploy.yml", green(), [issue(5, labels=("agent-in-progress",))])["action"] == "none"


def test_green_with_nothing_open_does_nothing():
    assert decide("deploy.yml", green(), [issue(7, state="CLOSED", closed_ago=DAY)])["action"] == "none"


def test_red_run_older_than_the_close_is_not_refiled():
    v = decide("deploy.yml", red(at=NOW - 2 * DAY), [issue(7, state="CLOSED", closed_ago=DAY)])
    assert v["action"] == "none"


def test_red_run_after_the_close_is_filed_again():
    v = decide("deploy.yml", red(at=NOW - 600), [issue(7, state="CLOSED", closed_ago=DAY)])
    assert v["action"] == "create"


def test_flapping_workflow_is_not_filed_again_within_a_day():
    flapped = issue(7, state="CLOSED", age=7200, closed_ago=3600)
    v = decide("deploy.yml", red(at=NOW - 600), [flapped])
    assert v == {"action": "none", "issues": [], "reason": "an issue was filed for it within a day"}


def test_flapping_workflow_is_filed_again_after_a_day():
    old = issue(7, state="CLOSED", age=DAY + 7200, closed_ago=DAY)
    assert decide("deploy.yml", red(at=NOW - 600), [old])["action"] == "create"


def test_no_finished_run_does_nothing():
    assert decide("deploy.yml", None, [])["action"] == "none"


def test_no_finished_run_and_no_default_branch_trigger_closes_its_open_issue():
    v = decide("hand.yml", None, [issue(5, file="hand.yml")], trig=("workflow_dispatch",))
    assert v == {"action": "close", "issues": [5], "reason": "not triggered by push, schedule or workflow_run, so it cannot be green there on its own"}


def test_no_finished_run_and_no_default_branch_trigger_leaves_a_claimed_issue_alone():
    v = decide("hand.yml", None, [issue(5, file="hand.yml", labels=("agent-in-progress",))], trig=("workflow_dispatch",))
    assert v == {"action": "none", "issues": [], "reason": "no trigger that runs on the default branch"}


def test_a_green_run_of_a_workflow_that_cannot_run_on_the_default_branch_closes_its_issue():
    v = decide("hand.yml", green(), [issue(5, file="hand.yml")], trig=("workflow_dispatch",))
    assert v == {"action": "close", "issues": [5], "reason": "green on the default branch again: https://example.invalid/runs/101"}


def test_a_red_run_from_before_the_trigger_change_does_not_keep_the_issue_open():
    assert decide("hand.yml", red(), [], trig=("workflow_dispatch",))["action"] == "none"
    v = decide("hand.yml", red(200), [issue(5, file="hand.yml", run_id=100, age=3 * DAY)], trig=("workflow_dispatch",))
    assert v == {"action": "close", "issues": [5], "reason": "not triggered by push, schedule or workflow_run, so it cannot be green there on its own"}


def test_workflow_call_is_not_a_default_branch_trigger():
    assert decide("hand.yml", None, [issue(5, file="hand.yml")], trig=("workflow_call", "workflow_dispatch"))["action"] == "close"
    assert decide("deploy.yml", red(), [], trig=("push", "workflow_dispatch"))["action"] == "create"


def test_workflow_gone_from_the_default_branch_closes_its_open_issues():
    v = decide("grader-calibration.yml", red(), [issue(5, file="grader-calibration.yml")], present=["deploy.yml"])
    assert v == {"action": "close", "issues": [5], "reason": "gone from the default branch, so it cannot run there again"}


def test_workflow_gone_from_the_default_branch_files_nothing():
    assert decide("grader-calibration.yml", red(), [], present=["deploy.yml"])["action"] == "none"


def test_workflow_gone_from_the_default_branch_leaves_a_claimed_issue():
    v = decide("grader-calibration.yml", red(), [issue(5, file="grader-calibration.yml", labels=("agent-in-progress",))], present=["deploy.yml"])
    assert v["action"] == "none"


def test_a_green_run_for_a_gone_workflow_still_closes_it():
    v = decide("grader-calibration.yml", green(), [issue(5, file="grader-calibration.yml")], present=[])
    assert v["action"] == "close"


def test_an_empty_present_list_treats_every_file_as_gone():
    assert decide("deploy.yml", red(), [], present=[])["action"] == "none"


def test_a_gone_workflow_is_closed_even_when_it_cannot_run_on_its_own():
    v = decide("hand.yml", None, [issue(5, file="hand.yml")], trig=("workflow_dispatch",), present=[])
    assert v == {"action": "close", "issues": [5], "reason": "gone from the default branch, so it cannot run there again"}


FAKE_GH = r"""#!/usr/bin/env bash
d=$FAKE_DIR
args=("$@")
jqx=
for ((i = 0; i < ${#args[@]}; i++)); do [ "${args[i]}" = --jq ] && jqx=${args[i + 1]}; done
case "$1" in
  api)
    url=
    for a in "${args[@]:1}"; do case $a in -*) ;; repos/*) url=$a; break ;; esac; done
    case $url in
      repos/o/r) f=$d/repo.json ;;
      repos/o/r/git/trees/*) f=$d/tree.json ;;
      repos/o/r/actions/workflows\?*) f=$d/workflows.json ;;
      repos/o/r/actions/workflows/*status=success*) f=$d/green-$(basename "${url%%/runs*}").json ;;
      repos/o/r/actions/workflows/*/runs\?*) f=$d/runs-$(basename "${url%%/runs*}").json ;;
      repos/o/r/actions/runs/*/jobs*) f=$d/jobs-$(echo "$url" | sed 's|.*/runs/\([0-9]*\)/jobs.*|\1|').json ;;
      repos/o/r/contents/*) f=$d/on-$(basename "${url%%\?*}"); [ -f "$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; } ;;
      *) echo "fake gh: unexpected api: $url" >&2; exit 1 ;;
    esac
    [ -f "$f" ] || { echo "fake gh: no fixture $f" >&2; exit 1; }
    [ -n "$jqx" ] || { cat "$f"; exit 0; }
    jq -r "$jqx" "$f" ;;
  issue)
    case "$2" in
      list) cat "$d/issues.json" ;;
      view) jq -r "$jqx" "$d/view.json" ;;
      *) printf '%s' "$*" | tr '\n' '~' >> "$d/writes.log"; echo >> "$d/writes.log" ;;
    esac ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 1 ;;
esac
"""


def _setup(tmp_path, files, issues, repo="o/r", gone=()):
    fake = tmp_path / "fake"
    fake.mkdir()
    (fake / "repo.json").write_text(json.dumps({"default_branch": "main"}))
    workflows = []
    tree = []
    for wid, spec in files.items():
        path, state, runs, jobs, green_sha = spec[:5]
        workflows.append({"id": wid, "path": path, "state": state})
        if path.rsplit("/", 1)[-1] not in gone:
            tree.append({"path": path})
            (fake / f"on-{path.rsplit('/', 1)[-1]}").write_text(spec[5] if len(spec) > 5 else "on:\n  push:\n  workflow_dispatch:\n")
        (fake / f"runs-{wid}.json").write_text(json.dumps({"workflow_runs": runs}))
        (fake / f"green-{wid}.json").write_text(json.dumps({"workflow_runs": [{"head_sha": green_sha}] if green_sha else []}))
        for r in runs:
            (fake / f"jobs-{r['id']}.json").write_text(json.dumps({"jobs": jobs}))
    (fake / "workflows.json").write_text(json.dumps({"workflows": workflows}))
    (fake / "tree.json").write_text(json.dumps({"tree": tree}))
    (fake / "issues.json").write_text(json.dumps(issues))
    gh = fake / "gh"
    gh.write_text(FAKE_GH)
    gh.chmod(0o755)
    return fake


def _api_run(rid, conclusion, at=NOW - 3600, repo="o/r", event="push"):
    return {"id": rid, "conclusion": conclusion, "html_url": f"https://example.invalid/runs/{rid}", "run_started_at": _iso(at),
            "head_sha": "c" * 40, "head_repository": {"full_name": repo}, "event": event}


FAILED_JOBS = [{"name": "build", "conclusion": "success", "steps": []},
               {"name": "deploy", "conclusion": "failure", "steps": [
                   {"name": "Set up job", "conclusion": "success"}, {"name": "Publish to R2", "conclusion": "failure"}]}]


def _sweep(tmp_path, files, issues, drop=(), gone=()):
    fake = _setup(tmp_path, files, issues, gone=gone)
    for name in drop:
        (fake / name).unlink()
    home = tmp_path / "home"
    home.mkdir()
    env = {
        **os.environ, "HOME": str(home), "PATH": f"{fake}:{os.environ['PATH']}", "FAKE_DIR": str(fake),
        "GITHUB_REPOSITORY": "o/r", "GH_TOKEN": "x", "RUNNER_TEMP": str(tmp_path), "RED_MAIN": _y(f"{FIND} | .env.RED_MAIN"),
    }
    r = subprocess.run(
        ["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", _y(f"{FIND} | .run")],
        env=env, capture_output=True, text=True,
    )
    log = fake / "writes.log"
    return r, (log.read_text().splitlines() if log.exists() else [])


def deploy(conclusion="failure", rid=10, **kw):
    return {1: (".github/workflows/deploy.yml", "active", [_api_run(rid, conclusion, **kw)], FAILED_JOBS, "g" * 40)}


def test_sweep_files_the_red_workflow_with_step_and_last_green(tmp_path):
    files = {**deploy(), 2: (".github/workflows/ci.yml", "active", [_api_run(20, "success")], [], None)}
    r, log = _sweep(tmp_path, files, [])
    assert r.returncode == 0, r.stdout + r.stderr
    assert log == [
        "issue create -R o/r --label agent-ready --title Main is red: deploy.yml --body red-main: deploy.yml~red-main-run: 10~~"
        "The latest run of deploy.yml on the default branch failed: https://example.invalid/runs/10~"
        "First failing step: deploy / Publish to R2~Last green sha: " + "g" * 40 + "~~"
        "Fix the root cause in a PR. This issue closes itself when the workflow is green on the default branch; "
        "do not file another issue for it."
    ]


def test_sweep_includes_ci_and_skips_disabled_dynamic_and_dispatcher(tmp_path):
    bad = [_api_run(10, "failure")]
    files = {
        1: (".github/workflows/ci.yml", "active", bad, FAILED_JOBS, None),
        2: (".github/workflows/old.yml", "disabled_manually", bad, FAILED_JOBS, None),
        3: ("dynamic/dependabot/dependabot-updates", "active", bad, FAILED_JOBS, None),
        4: (".github/workflows/agent-dispatch.yml", "active", bad, FAILED_JOBS, None),
    }
    r, log = _sweep(tmp_path, files, [])
    assert r.returncode == 0, r.stdout + r.stderr
    assert len(log) == 1 and "--title Main is red: ci.yml " in log[0] and "Last green sha: none" in log[0]


def test_sweep_ignores_cancelled_and_skipped_runs(tmp_path):
    runs = [_api_run(12, "cancelled"), _api_run(11, "skipped"), _api_run(10, "success")]
    files = {1: (".github/workflows/lighthouse.yml", "active", runs, [], None)}
    r, log = _sweep(tmp_path, files, [issue(5, file="lighthouse.yml")])
    assert r.returncode == 0, r.stdout + r.stderr
    assert log == ["issue close 5 -R o/r -r completed -c lighthouse.yml is green on the default branch again: https://example.invalid/runs/10"]


def test_sweep_closes_every_duplicate_when_green(tmp_path):
    r, log = _sweep(tmp_path, deploy("success"), [issue(9), issue(5)])
    assert r.returncode == 0, r.stdout + r.stderr
    assert [l.split(" -R")[0] for l in log] == ["issue close 5", "issue close 9"]


def test_sweep_ignores_a_fork_run_on_a_branch_named_main(tmp_path):
    files = {1: (".github/workflows/deploy.yml", "active", [_api_run(10, "failure", repo="fork/r"), _api_run(9, "success")], FAILED_JOBS, None)}
    r, log = _sweep(tmp_path, files, [issue(5)])
    assert r.returncode == 0, r.stdout + r.stderr
    assert len(log) == 1 and log[0].startswith("issue close 5 ")


def test_sweep_ignores_runs_started_by_an_issue_comment(tmp_path):
    files = {1: (".github/workflows/deploy.yml", "active", [_api_run(10, "failure", event="issue_comment")], FAILED_JOBS, None)}
    r, log = _sweep(tmp_path, files, [])
    assert r.returncode == 0, r.stdout + r.stderr
    assert log == []


def test_sweep_counts_a_startup_failure_as_red(tmp_path):
    r, log = _sweep(tmp_path, deploy("startup_failure"), [])
    assert r.returncode == 0, r.stdout + r.stderr
    assert len(log) == 1 and log[0].startswith("issue create ")


def test_sweep_files_at_most_three_new_issues_a_day(tmp_path):
    files = {i: (f".github/workflows/w{i}.yml", "active", [_api_run(10 * i, "failure")], FAILED_JOBS, None) for i in range(1, 6)}
    r, log = _sweep(tmp_path, files, [])
    assert r.returncode == 0, r.stdout + r.stderr
    assert [l.split("--title Main is red: ")[1].split(" --body")[0] for l in log] == ["w1.yml", "w2.yml", "w3.yml"]


def test_sweep_counts_issues_filed_earlier_today_against_the_cap(tmp_path):
    files = {i: (f".github/workflows/w{i}.yml", "active", [_api_run(10 * i, "failure")], FAILED_JOBS, None) for i in range(1, 4)}
    earlier = [issue(n, file=f"other{n}.yml", age=3600) for n in (50, 51)]
    r, log = _sweep(tmp_path, files, earlier)
    assert r.returncode == 0, r.stdout + r.stderr
    assert len(log) == 1


def test_sweep_ignores_an_issue_by_anyone_but_the_sweep(tmp_path):
    r, log = _sweep(tmp_path, deploy(), [issue(5, author="stranger")])
    assert r.returncode == 0, r.stdout + r.stderr
    assert len(log) == 1 and log[0].startswith("issue create ")


def test_strangers_issues_do_not_use_up_the_daily_cap(tmp_path):
    files = {i: (f".github/workflows/w{i}.yml", "active", [_api_run(10 * i, "failure")], FAILED_JOBS, None) for i in range(1, 4)}
    strays = [issue(n, file=f"other{n}.yml", age=3600, author="stranger") for n in (50, 51, 52)]
    r, log = _sweep(tmp_path, files, strays)
    assert r.returncode == 0, r.stdout + r.stderr
    assert len(log) == 3


def test_sweep_passes_a_long_issue_list_without_the_argument_limit(tmp_path):
    big = issue(5, run_id=10, comments=[{"body": "x" * 70000, "createdAt": _iso(NOW - 60)} for _ in range(2)])
    r, log = _sweep(tmp_path, deploy(), [big])
    assert r.returncode == 0, r.stdout + r.stderr
    assert "Argument list too long" not in r.stdout + r.stderr
    assert "this run is already reported" in r.stdout


def test_sweep_matches_the_open_issue_instead_of_filing_another(tmp_path):
    r, log = _sweep(tmp_path, deploy(), [issue(5, run_id=10)])
    assert r.returncode == 0, r.stdout + r.stderr
    assert log == []
    assert "deploy.yml: none, this run is already reported" in r.stdout


def test_sweep_closes_a_hand_only_workflow_whose_newest_run_is_an_old_red_push(tmp_path):
    files = {1: (".github/workflows/hand.yml", "active", [_api_run(10, "failure")], FAILED_JOBS, None, "on:\n  workflow_dispatch:\n")}
    r, log = _sweep(tmp_path, files, [issue(5, file="hand.yml", age=3 * DAY)])
    assert r.returncode == 0, r.stdout + r.stderr
    assert log == ["issue close 5 -R o/r -r completed -c hand.yml is not triggered by push, schedule or workflow_run, so it cannot be green there on its own"]
    assert "hand.yml: close, not triggered by push, schedule or workflow_run" in r.stdout


def test_sweep_comments_once_for_a_new_run_after_a_day(tmp_path):
    r, log = _sweep(tmp_path, deploy(rid=11), [issue(5, run_id=10, age=3 * DAY)])
    assert r.returncode == 0, r.stdout + r.stderr
    assert log == [
        "issue comment 5 -R o/r --body red-main-run: 11~~Still red: https://example.invalid/runs/11~"
        "First failing step: deploy / Publish to R2~Last green sha: " + "g" * 40
    ]


def test_sweep_closes_the_issue_of_a_workflow_whose_file_is_gone(tmp_path):
    files = {**deploy("success"), 2: (".github/workflows/grader-calibration.yml", "active", [_api_run(20, "failure")], FAILED_JOBS, None)}
    r, log = _sweep(tmp_path, files, [issue(5, file="grader-calibration.yml")], gone=("grader-calibration.yml",))
    assert r.returncode == 0, r.stdout + r.stderr
    assert log == ["issue close 5 -R o/r -r completed -c grader-calibration.yml is gone from the default branch, so it cannot run there again"]


def test_sweep_files_nothing_for_a_workflow_whose_file_is_gone(tmp_path):
    files = {**deploy(), 2: (".github/workflows/grader-calibration.yml", "active", [_api_run(20, "failure")], FAILED_JOBS, None)}
    r, log = _sweep(tmp_path, files, [], gone=("grader-calibration.yml",))
    assert r.returncode == 0, r.stdout + r.stderr
    assert len(log) == 1 and "--title Main is red: deploy.yml " in log[0]


def test_sweep_skips_one_unreadable_workflow_and_fails_the_job(tmp_path):
    files = {
        1: (".github/workflows/a.yml", "active", [_api_run(10, "failure")], FAILED_JOBS, None),
        2: (".github/workflows/b.yml", "active", [_api_run(20, "failure")], FAILED_JOBS, None),
    }
    r, log = _sweep(tmp_path, files, [], drop=["runs-1.json"])
    assert r.returncode != 0
    assert "::warning::a.yml: runs unreadable, skipped" in r.stdout
    assert len(log) == 1 and "--title Main is red: b.yml " in log[0]


def test_sweep_fails_when_the_workflow_list_is_unreadable(tmp_path):
    r, log = _sweep(tmp_path, deploy(), [], drop=["workflows.json"])
    assert r.returncode != 0
    assert log == []


def test_sweep_skips_a_present_workflow_whose_file_cannot_be_read(tmp_path):
    files = {1: (".github/workflows/hand.yml", "active", [_api_run(10, "failure")], FAILED_JOBS, None, "on:\n  workflow_dispatch:\n")}
    r, log = _sweep(tmp_path, files, [issue(5, file="hand.yml")], drop=["on-hand.yml"])
    assert r.returncode == 1, r.stdout + r.stderr
    assert "::warning::hand.yml: file unreadable, skipped" in r.stdout
    assert "::error::1 of 1 workflows errored and were skipped" in r.stdout
    assert log == []


def test_sweep_files_nothing_for_a_red_run_of_a_workflow_that_cannot_run_on_the_default_branch(tmp_path):
    files = {1: (".github/workflows/hand.yml", "active", [_api_run(10, "failure")], FAILED_JOBS, None, "on:\n  workflow_dispatch:\n")}
    r, log = _sweep(tmp_path, files, [])
    assert r.returncode == 0, r.stdout + r.stderr
    assert log == []
    assert "hand.yml: none, no trigger that runs on the default branch" in r.stdout


def test_sweep_skips_a_workflow_that_cannot_run_on_the_default_branch(tmp_path):
    files = {1: (".github/workflows/hand.yml", "active", [], FAILED_JOBS, None, "on:\n  workflow_dispatch:\n")}
    r, log = _sweep(tmp_path, files, [])
    assert r.returncode == 0, r.stdout + r.stderr
    assert log == []
    assert "hand.yml: none, no trigger that runs on the default branch" in r.stdout


def test_sweep_closes_an_issue_for_a_workflow_that_cannot_run_on_the_default_branch(tmp_path):
    files = {1: (".github/workflows/hand.yml", "active", [], FAILED_JOBS, None, "on:\n  workflow_dispatch:\n")}
    r, log = _sweep(tmp_path, files, [issue(5, file="hand.yml")])
    assert r.returncode == 0, r.stdout + r.stderr
    assert log == ["issue close 5 -R o/r -r completed -c hand.yml is not triggered by push, schedule or workflow_run, so it cannot be green there on its own"]


def test_sweep_skips_a_workflow_whose_file_it_cannot_read(tmp_path):
    files = {1: (".github/workflows/hand.yml", "active", [], FAILED_JOBS, None)}
    r, log = _sweep(tmp_path, files, [issue(5)], drop=["on-hand.yml"])
    assert r.returncode == 1, r.stdout + r.stderr
    assert log == []
    assert "::warning::hand.yml: file unreadable, skipped" in r.stdout
    assert "::error::1 of 1 workflows errored and were skipped" in r.stdout


def _on_shape(tmp_path, name, on, closes):
    files = {1: (f".github/workflows/{name}", "active", [], FAILED_JOBS, None, on)}
    r, log = _sweep(tmp_path, files, [issue(5, file=name)])
    assert r.returncode == 0, r.stdout + r.stderr
    assert log == (["issue close 5 -R o/r -r completed -c "
                    f"{name} is not triggered by push, schedule or workflow_run, so it cannot be green there on its own"] if closes else [])
    assert f"{name}: " + ("close, not triggered by push, schedule or workflow_run, so it cannot be green there on its own" if closes else "none, no finished run on the default branch") in r.stdout


def test_a_comment_before_the_first_key_does_not_hide_a_dispatch_only_trigger(tmp_path):
    _on_shape(tmp_path, "commented.yml", "on: # push and schedule come later\n  workflow_dispatch:\n", True)


def test_a_flow_list_of_triggers_is_read(tmp_path):
    _on_shape(tmp_path, "flow.yml", "on: [schedule, workflow_dispatch]\n", False)


def test_a_quoted_on_key_is_read(tmp_path):
    _on_shape(tmp_path, "quoted.yml", '"on":\n  push:\n', False)


def test_a_bare_scalar_on_is_read(tmp_path):
    _on_shape(tmp_path, "scalar.yml", "on: push\n", False)


def test_an_on_block_with_no_trigger_name_is_unreadable_not_a_close(tmp_path):
    files = {1: (".github/workflows/empty.yml", "active", [], FAILED_JOBS, None, "on:\n")}
    r, log = _sweep(tmp_path, files, [issue(5, file="empty.yml")])
    assert r.returncode == 1, r.stdout + r.stderr
    assert "::warning::empty.yml: on: block unreadable, skipped" in r.stdout
    assert "::error::1 of 1 workflows errored and were skipped" in r.stdout
    assert log == []


def test_sweep_fails_when_the_on_block_of_a_workflow_is_not_yaml(tmp_path):
    files = {1: (".github/workflows/hand.yml", "active", [], FAILED_JOBS, None, "on: [push,\n")}
    r, log = _sweep(tmp_path, files, [issue(5, file="hand.yml")])
    assert r.returncode == 1, r.stdout + r.stderr
    assert "::warning::hand.yml: on: block unreadable, skipped" in r.stdout
    assert "::error::1 of 1 workflows errored and were skipped" in r.stdout
    assert log == []


def test_sweep_closes_a_gone_workflow_with_no_run_without_reading_a_file(tmp_path):
    files = {1: (".github/workflows/grader-calibration.yml", "active", [], FAILED_JOBS, None)}
    r, log = _sweep(tmp_path, files, [issue(5, file="grader-calibration.yml")], gone=("grader-calibration.yml",))
    assert r.returncode == 0, r.stdout + r.stderr
    assert log == ["issue close 5 -R o/r -r completed -c grader-calibration.yml is gone from the default branch, so it cannot run there again"]


def test_red_main_job_is_gated_and_needs_no_new_token():
    cond = " ".join(_y(".jobs.red-main.if").split())
    assert cond.startswith("vars.FLEET_DISPATCH_PAUSED != 'true' && ")
    assert "github.repository != 'Nishfleet/fleet-ops'" in cond
    assert "vars.RED_MAIN != 'off'" in cond
    assert "TinyStudio" not in cond
    assert _y(".jobs.red-main.steps[0].env.GH_TOKEN").strip() == "${{ github.token }}"
    assert _y(".jobs.red-main.permissions").strip() == "{issues: write, contents: read, actions: read}"
