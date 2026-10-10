"""scripts/claude-lane-seat.sh: the pick-claude-seat.sh answer, plus `full` when
the chosen seat is at the skip threshold (both seats full). The stub curl is the
same shape as in test_pick_claude_seat.py; the real pick script and jq run.
"""
import json
import os
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/claude-lane-seat.sh"
STUB = """#!/bin/bash
cfg=
while [ $# -gt 0 ]; do [ "$1" = --config ] && cfg=$2; shift; done
tok=$(sed -n 's/^header = "Authorization: Bearer \\(.*\\)"$/\\1/p' "$cfg")
[ -z "$FAIL" ] || exit 22
case "$tok" in
  tok-a) echo "{\\"five_hour\\":{\\"utilization\\":$UTIL_A}}" ;;
  tok-b) echo "{\\"five_hour\\":{\\"utilization\\":$UTIL_B}}" ;;
esac
"""


def _run(tmp_path, epoch, util_a, util_b, fail=False):
    home = tmp_path / "home"
    runner = tmp_path / "runner-config"
    for d, t in ((runner, "tok-a"), (home / ".claude", "tok-b")):
        d.mkdir(parents=True, exist_ok=True)
        (d / ".credentials.json").write_text(json.dumps({"claudeAiOauth": {"accessToken": t}}))
    bindir = tmp_path / "bin"
    bindir.mkdir(exist_ok=True)
    (bindir / "curl").write_text(STUB)
    (bindir / "curl").chmod(0o755)
    env = {
        **os.environ,
        "HOME": str(home),
        "PATH": f"{bindir}:{os.environ['PATH']}",
        "CLAUDE_CONFIG_DIR": str(runner),
        "CLAUDE_SEAT_EPOCH": str(epoch),
        "UTIL_A": util_a,
        "UTIL_B": util_b,
        "FAIL": "1" if fail else "",
    }
    r = subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    return r.stdout.strip()


def test_open_seat_passes_the_pick_through(tmp_path):
    assert _run(tmp_path, 0, "10", "20") == "keep"
    d = tmp_path / "b"
    d.mkdir()
    assert _run(d, 7200, "10", "20") == "default"


def test_full_bucket_seat_moves_to_the_other_one(tmp_path):
    assert _run(tmp_path, 0, "96", "20") == "default"


def test_both_seats_full_is_full(tmp_path):
    assert _run(tmp_path, 0, "95", "99") == "full"
    d = tmp_path / "b"
    d.mkdir()
    assert _run(d, 7200, "99", "100") == "full"


def test_just_under_the_threshold_is_not_full(tmp_path):
    assert _run(tmp_path, 0, "94.9", "99") == "keep"


def test_unreadable_usage_is_not_full(tmp_path):
    assert _run(tmp_path, 0, "99", "99", fail=True) == "keep"


def _run_usage(tmp_path, epoch, util_a, util_b, skip_at="95", fail=False):
    home = tmp_path / "home"
    runner = tmp_path / "runner-config"
    for d, t in ((runner, "tok-a"), (home / ".claude", "tok-b")):
        d.mkdir(parents=True, exist_ok=True)
        (d / ".credentials.json").write_text(json.dumps({"claudeAiOauth": {"accessToken": t}}))
    bindir = tmp_path / "bin"
    bindir.mkdir(exist_ok=True)
    (bindir / "curl").write_text(STUB)
    (bindir / "curl").chmod(0o755)
    env = {
        **os.environ, "HOME": str(home), "PATH": f"{bindir}:{os.environ['PATH']}", "CLAUDE_CONFIG_DIR": str(runner),
        "CLAUDE_SEAT_EPOCH": str(epoch), "UTIL_A": util_a, "UTIL_B": util_b, "FAIL": "1" if fail else "",
        "CLAUDE_SEAT_SKIP_AT": skip_at,
    }
    r = subprocess.run(["bash", str(SCRIPT), "--usage"], env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    return r.stdout.strip()


def test_usage_line_reports_mode_seat_and_five_hour(tmp_path):
    assert _run_usage(tmp_path, 0, "10", "20") == "keep a 10"
    d = tmp_path / "b"
    d.mkdir()
    assert _run_usage(d, 7200, "10", "20") == "default b 20"


def test_lower_threshold_moves_to_the_other_seat_then_is_full(tmp_path):
    # at 80 the bucket seat (85) is skipped for the other (50); both over 80 is full
    assert _run_usage(tmp_path, 0, "85", "50", skip_at="80") == "default b 50"
    d = tmp_path / "b"
    d.mkdir()
    assert _run_usage(d, 0, "85", "90", skip_at="80").split()[0] == "full"


def test_strong_only_threshold_still_takes_a_90_percent_seat(tmp_path):
    assert _run_usage(tmp_path, 0, "90", "92").split()[0] == "keep"


def test_unreadable_usage_reports_n_a(tmp_path):
    assert _run_usage(tmp_path, 0, "1", "1", fail=True).endswith("n/a")
