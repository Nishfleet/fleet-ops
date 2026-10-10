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
