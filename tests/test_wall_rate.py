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


def _runs_fixture(fake, runs, timeouts=(), early_failures=()):
    (fake / "runs.json").write_text(json.dumps({"workflow_runs": runs}))
    for rid in timeouts + early_failures:
        (fake / f"jobs-{rid}.json").write_text(json.dumps(
            {"jobs":[{"id": 900 + rid, "name": "work", "steps": [{"name": "Worker", "conclusion": "failure"}]}]}))
        msgs = [{"message": "The action 'Worker' has timed out after 55 minutes."}]
        if rid in early_failures:
            msgs = [{"message": "The action 'Worker' has failed. tests came back red on main"}]
        (fake / f"ann-{900 + rid}.json").write_text(json.dumps(msgs))


def _run(tmp_path, runs, timeouts=(), early_failures=(), repo="Nishfleet/0509"):
    fake = tmp_path / "fake"
    fake.mkdir()
    _runs_fixture(fake, runs, timeouts, early_failures)
    gh = fake / "gh"
    gh.write_text(FAKE_GH)
    gh.chmod(0o755)
    env = {**os.environ, "FAKE_DIR": str(fake), "PATH": f"{fake}:{os.environ['PATH']}",
           "GITHUB_REPOSITORY": repo,
           "WALL_RATE_MAX": _env_var("WALL_RATE_MAX"), "WALL_MIN_SECS": _env_var("WALL_MIN_SECS"),
           "WALL_MINUTES": _env_var("WALL_MINUTES")}
    return subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", _run_block()],
                          env=env, capture_output=True, text=True)


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
    assert "1 of 10 finished agent-dispatch runs" in r.stdout


def test_target_boundary_is_red(tmp_path):
    runs = [_wr(n, "success", _S, _E1_H) for n in range(1, 18)] + \
           [_wr(n, "failure", _S, _E1_H) for n in range(20, 23)]
    r = _run(tmp_path, runs, timeouts=tuple(range(20, 23)))
    assert r.returncode == 1
    assert "3 of 20" in r.stdout + r.stderr


def test_short_run_is_not_a_real_run(tmp_path):
    r = _run(tmp_path, [_wr(1, "failure", _S, "2026-10-10T10:01:00Z")], timeouts=(1,))
    assert r.returncode == 0
    assert "no finished agent-dispatch run" in r.stdout


def test_wall_death_needs_the_annotation_not_the_duration(tmp_path):
    r = _run(tmp_path, [_wr(70, "failure", _S, _E1_H)], early_failures=(70,))
    assert r.returncode == 0, r.stdout + r.stderr
    assert "0 of 1" in r.stdout


def test_cancelled_and_untimely_runs_are_not_counted(tmp_path):
    runs = [_wr(3, "cancelled", _S, _E1_H), _wr(5, "success", _S, _E1_H)]
    r = _run(tmp_path, runs)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "0 of 2" in r.stdout


def test_missing_started_at_falls_back_to_created_at(tmp_path):
    runs = [{"id": 8, "conclusion": "failure", "created_at": _S,
             "updated_at": "2026-10-10T10:50:00Z"}]
    runs += [_wr(n, "success", _S, _E1_H) for n in range(9, 17)]
    fake = None  # fixture built inline
    tmp = tmp_path / "fake"; tmp.mkdir(); fake = tmp
    (fake / "runs.json").write_text(json.dumps({"workflow_runs": runs}))
    (fake / "jobs-8.json").write_text(json.dumps({"jobs": [{"id": 908, "steps": [{"name": "Worker"}]}]}))
    (fake / "ann-908.json").write_text(json.dumps([{"message": "The action 'Worker' has timed out after 55 minutes."}]))
    gh = fake / "gh"; gh.write_text(FAKE_GH); gh.chmod(0o755)
    env = {**os.environ, "FAKE_DIR": str(fake), "PATH": f"{fake}:{os.environ['PATH']}",
           "GITHUB_REPOSITORY": "Nishfleet/0509",
           "WALL_RATE_MAX": _env_var("WALL_RATE_MAX"), "WALL_MIN_SECS": _env_var("WALL_MIN_SECS"),
           "WALL_MINUTES": _env_var("WALL_MINUTES")}
    r = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", _run_block()],
                       env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "1 of 9" in r.stdout


def test_shape_pins_the_daily_read():
    cond = _yq(f".jobs.{JOB}.if")
    assert "FLEET_DISPATCH_PAUSED != 'true'" in cond, f"{JOB} must skip on FLEET_DISPATCH_PAUSED"
    assert "github.event.schedule == '30 2 * * *'" in cond, f"{JOB} not keyed to the 02:30 cron: {cond}"
    src = open(WF).read()
    assert "cron: '30 2 * * *'" in src, f"{JOB}: the daily cron line is missing"
    run = _run_block()
    for needle in ('.name == "Worker"', "has timed out after", "check-runs", "$WALL_RATE_MAX", "run_started_at"):
        assert needle in run, f"{JOB} run block lost: {needle}"


def test_env_guards_ship_with_the_job():
    for name, text in (("WALL_RATE_MAX", "15"), ("WALL_MIN_SECS", "120"), ("WALL_MINUTES", "55")):
        assert _env_var(name) == text
