import json, os, subprocess

import pytest

WF = ".github/workflows/agent-dispatch.yml"
JOB = "wall-rate"


def _yq(prog, path=WF):
    return subprocess.run(["yq", prog, path], capture_output=True, text=True, check=True).stdout.strip()


def _run_block():
    return _yq(f'.jobs.{JOB}.steps[] | select(.name == "Count the wall timeouts in the last 24 hours") | .run')


def _env_var(name):
    val = _yq(f'.jobs.{JOB}.env.{name}')
    assert val and val != "null", f"{JOB} env.{name} missing"
    return val


FAKE_GH = """#!/usr/bin/env bash
q=""; path=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--jq" ]; then q=$a; fi
  case $a in
    repos/*) path=$a ;;
  esac
  prev=$a
done
case $path in
  *"workflows/agent-dispatch.yml/runs"*) f="$FAKE_DIR/runs.json" ;;
  *"actions/runs/"*) n=${path##*/runs/}; n=${n%%/*}; f="$FAKE_DIR/jobs-$n.json" ;;
  *"check-runs/"*) n=$(echo "$path" | sed 's#.*/check-runs/##; s#/.*##'); f="$FAKE_DIR/ann-$n.json" ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 1 ;;
esac
if [ -n "$q" ]; then jq -r "$q" "$f"; else cat "$f"; fi
"""


def _wr(rid, conclusion="failure", started="2026-10-10T10:00:00Z", ended="2026-10-10T10:30:00Z"):
    return {"id": rid, "conclusion": conclusion, "run_started_at": started, "updated_at": ended}


def _bare(tmp_path):
    fake = tmp_path / "fake"
    fake.mkdir()
    gh = fake / "gh"
    gh.write_text(FAKE_GH)
    gh.chmod(0o755)
    env = {**os.environ, "FAKE_DIR": str(fake), "PATH": f"{fake}:{os.environ['PATH']}",
           "GITHUB_REPOSITORY": "Nishfleet/0509",
           "WALL_RATE_MAX": _env_var("WALL_RATE_MAX"), "WALL_MIN_SECS": _env_var("WALL_MIN_SECS"),
           "WALL_MINUTES": _env_var("WALL_MINUTES")}
    return fake, env


def _bash(env, block):
    return subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", block],
                          env=env, capture_output=True, text=True)


def _runs_fixture(fake, runs, timeouts=(), early_failures=(), jobs=None, anns=None):
    (fake / "runs.json").write_text(json.dumps({"workflow_runs": runs}))
    for wr in runs:
        rid = wr["id"]
        steps = [{"name": "Worker", "conclusion": "failure" if rid in timeouts else "success"}]
        run_jobs = (jobs or {}).get(rid, [{"id": 900 + rid, "name": "work", "steps": steps}])
        (fake / f"jobs-{rid}.json").write_text(json.dumps({"jobs": run_jobs}))
        for job in run_jobs:
            if (anns or {}).get(job["id"]) is not None:
                (fake / f"ann-{job['id']}.json").write_text(json.dumps(anns[job["id"]]))
            elif any(s.get("name") == "Worker" and s.get("conclusion") == "failure" for s in job["steps"]):
                (fake / f"ann-{job['id']}.json").write_text(json.dumps(
                    [{"message": "The action 'Worker' has timed out after 55 minutes."}]))
            elif rid in early_failures:
                (fake / f"ann-{job['id']}.json").write_text(json.dumps(
                    [{"message": "The action 'Worker' has failed. tests came back red on main"}]))
            else:
                (fake / f"ann-{job['id']}.json").write_text(json.dumps([]))


def _run(tmp_path, runs, timeouts=(), early_failures=(), repo="Nishfleet/0509", drop_jobs=(), drop_ann=(), jobs=None, anns=None):
    fake, env = _bare(tmp_path)
    _runs_fixture(fake, runs, timeouts, early_failures, jobs, anns)
    for n in drop_jobs:
        (fake / f"jobs-{n}.json").unlink()
    for n in drop_ann:
        (fake / f"ann-{900 + n}.json").unlink()
    return _bash(env, _run_block())


_S = "2026-10-10T10:00:00Z"
_E1_H = "2026-10-10T11:00:00Z"


def test_over_target_goes_red_with_numbers(tmp_path):
    runs = [
        _wr(1, "success", _S, _E1_H),
        _wr(2, "failure", _S, "2026-10-10T10:59:58Z"),
        _wr(3, "failure", _S, _E1_H),
        _wr(4, "failure", _S, "2026-10-10T10:01:00Z"),
    ]
    r = _run(tmp_path, runs, timeouts=(2,))
    assert r.returncode == 1, r.stdout + r.stderr
    out = r.stdout + r.stderr
    assert "1 of 3" in out
    assert "::error::" in out and "target: below 15%" in out


def test_under_target_is_green(tmp_path):
    runs = [_wr(n, "success", _S, _E1_H) for n in range(1, 10)] + [_wr(11, "failure", _S, _E1_H)]
    r = _run(tmp_path, runs, timeouts=(11,))
    assert r.returncode == 0, r.stdout + r.stderr
    assert "::error::" not in r.stdout
    assert "1 of 10 worker jobs" in r.stdout


def test_target_boundary_is_red(tmp_path):
    runs = [_wr(n, "success", _S, _E1_H) for n in range(1, 18)] + \
           [_wr(n, "failure", _S, _E1_H) for n in range(20, 23)]
    r = _run(tmp_path, runs, timeouts=tuple(range(20, 23)))
    assert r.returncode == 1
    assert "3 of 20" in r.stdout + r.stderr


def test_no_worker_step_run_is_not_in_the_denominator(tmp_path):
    runs = [_wr(1, "failure", _S, _E1_H), _wr(2, "success", _S, _E1_H)]
    r = _run(tmp_path, runs, jobs={1: [{"id": 901, "name": "work", "steps": [{"name": "Checkout"}]}],
                                   2: [{"id": 902, "name": "work", "steps": [{"name": "Checkout"}]}]})
    assert r.returncode == 0, r.stdout + r.stderr
    assert "no worker job in a finished agent-dispatch run" in r.stdout


def test_failed_runs_read_fails_loud(tmp_path):
    _, env = _bare(tmp_path)
    r = _bash(env, _run_block())
    assert r.returncode == 1, r.stdout + r.stderr
    out = r.stdout + r.stderr
    assert "::error::" in out and "runs-list read failed" in out
    assert "nothing to report" not in out


def test_jobs_read_failure_is_loud(tmp_path):
    r = _run(tmp_path, [_wr(1, "success", _S, _E1_H)], drop_jobs=(1,))
    assert r.returncode != 0 and "::error::" in r.stdout and "jobs read" in r.stdout


def test_annotations_read_failure_is_loud(tmp_path):
    r = _run(tmp_path, [_wr(1, "failure", _S, _E1_H)], timeouts=(1,), drop_ann=(1,))
    assert r.returncode != 0 and "::error::" in r.stdout and "annotations read" in r.stdout


def test_cancelled_wall_death_is_counted(tmp_path):
    runs = [_wr(9, "cancelled", _S, _E1_H)] + [_wr(n, "success", _S, _E1_H) for n in range(10, 17)]
    r = _run(tmp_path, runs, timeouts=(9,))
    assert r.returncode == 0, r.stdout + r.stderr
    assert "1 of 8" in r.stdout


def test_short_run_is_not_a_real_run(tmp_path):
    r = _run(tmp_path, [_wr(1, "failure", _S, "2026-10-10T10:01:00Z")], timeouts=(1,))
    assert r.returncode == 0
    assert "no worker job in a finished agent-dispatch run" in r.stdout


def test_wall_death_needs_the_annotation_not_the_duration(tmp_path):
    r = _run(tmp_path, [_wr(70, "failure", _S, _E1_H)], early_failures=(70,))
    assert r.returncode == 0, r.stdout + r.stderr
    assert "0 of 1" in r.stdout


def test_job_level_timeout_text_counts_too(tmp_path):
    runs = [_wr(n, "success", _S, _E1_H) for n in range(3, 12)] + [_wr(12, "failure", _S, "2026-10-10T10:56:00Z")]
    r = _run(tmp_path, runs, jobs={12: [{"id": 912, "steps": [{"name": "Worker"}]}]},
             anns={912: [{"message": "The job running on runner host has exceeded the maximum execution time of 55 minutes."}]})
    assert r.returncode == 0, r.stdout + r.stderr
    assert "1 of 10" in r.stdout


def test_cancelled_and_untimely_runs_are_not_counted(tmp_path):
    runs = [_wr(3, "cancelled", _S, _E1_H), _wr(5, "success", _S, _E1_H)]
    r = _run(tmp_path, runs)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "0 of 2" in r.stdout, r.stdout + r.stderr


def test_missing_started_at_falls_back_to_created_at(tmp_path):
    runs = [{"id": 8, "conclusion": "failure", "created_at": _S,
             "updated_at": "2026-10-10T10:50:00Z"}]
    runs += [_wr(n, "success", _S, _E1_H) for n in range(9, 17)]
    r = _run(tmp_path, runs, timeouts=(8,))
    assert r.returncode == 0, r.stdout + r.stderr
    assert "1 of 9" in r.stdout


def test_shape_pins_the_daily_read():
    cond = _yq(f".jobs.{JOB}.if")
    assert "FLEET_DISPATCH_PAUSED != 'true'" in cond, f"{JOB} must skip on FLEET_DISPATCH_PAUSED"
    assert "github.event.schedule == '30 2 * * *'" in cond, f"{JOB} not on the daily cron: {cond}"
    assert "30 2 * * *" in _yq(".on.schedule[].cron"), "the daily cron entry is missing from the schedule"
    run = _run_block()
    for needle in ('.name == "Worker"', "has timed out after", "check-runs", "$WALL_RATE_MAX", "run_started_at", "runs-list read"):
        assert needle in run, f"{JOB} run block lost: {needle}"


def test_daily_fire_has_its_own_concurrency_group():
    group = _yq(".concurrency.group")
    assert "github.event.schedule == '30 2 * * *'" in group and "'wall-rate'" in group, \
        "the 02:30 fire needs a concurrency group of its own, or a pending sweep run cancels it (blocker on #11180)"


def test_task_wall_rate_runs_outside_the_schedule():
    cond = _yq(f".jobs.{JOB}.if")
    assert "inputs.task == 'wall-rate'" in cond, \
        "an enrolled repo must reach wall-rate with gh workflow run -f task=wall-rate, which workflow_call stubs can reach too"


def test_every_worker_job_counts_not_just_the_first(tmp_path):
    runs = [_wr(1, "failure", _S, _E1_H)] + [_wr(n, "success", _S, _E1_H) for n in range(2, 4)]
    jobs = {1: [{"id": 905, "name": "work", "steps": [{"name": "Worker", "conclusion": "failure"}]},
                {"id": 906, "name": "work", "steps": [{"name": "Worker", "conclusion": "failure"}]}]}
    anns = {905: [{"message": "The action 'Worker' has timed out after 55 minutes."}],
            906: [{"message": "The action 'Worker' has timed out after 55 minutes."}]}
    r = _run(tmp_path, runs, jobs=jobs, anns=anns)
    assert r.returncode == 1, r.stdout + r.stderr
    assert "2 of 4" in r.stdout + r.stderr


def test_env_guards_ship_with_the_job():
    for name, text in (("WALL_RATE_MAX", "15"), ("WALL_MIN_SECS", "120"), ("WALL_MINUTES", "55")):
        assert _env_var(name) == text
