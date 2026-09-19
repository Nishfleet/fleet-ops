#!/usr/bin/env bash
# tests/fleet-researcher-failed-cycle.test.sh
#
# fleet-ops#6094: while gap-closure last_verdict=FAIL stood,
# evaluate_triggers appended failed-cycle on every tick. Seven consecutive
# cycles (2026-09-11T23:01Z → 2026-09-12T16:55Z) fired on the same FAIL.
# lib/researcher-delta.py, bin/fleet-researcher-dispatch, and
# tests/fleet-researcher.test.sh were deleted by the 2026-09-18 glue sweep
# (81227264f, fa2f27bf9). This file is the class lock so the unbounded
# refire cannot return:
#   1. Replay the stored standing-FAIL packet excerpt.
#   2. Pin Alertmanager-style 24h repeat for failed-cycle and nth-gap-cycle
#      (test-only spec; no production organ).
#   3. The named files stay absent; lib/ and bin/ have no fire path.
#   4. Negative: a scratch copy that appends failed-cycle unconditionally
#      fails the detector.
#
# Hosted by tests/fleet-researcher-oversize.test.sh (already on a listed
# P14 host). Workers cannot add a ci.yml line.
# Offline. python3. No gh, no live proxy, no systemd.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
excerpt="$here/fixtures/fleet-researcher-failed-cycle/20260912T075737Z-packet-excerpt.txt"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$excerpt" ]] || fail "missing standing-FAIL fixture: $excerpt"
command -v python3 >/dev/null || fail "python3 missing"

scratch="$(mktemp -d -t fleet-researcher-failed-cycle.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# ---------- 1. replay the standing-FAIL receipt ----------
python3 - "$excerpt" <<'EOF' || exit 1
import json, sys

text = open(sys.argv[1]).read()
if "Why this run fired: failed-cycle" not in text:
    print("FAIL: fixture missing failed-cycle trigger line")
    sys.exit(1)
# Last non-comment line is the empty deltas body five same-trigger cycles produced.
body = [ln for ln in text.splitlines() if ln.strip() and not ln.lstrip().startswith("#")][-1]
parsed = json.loads(body)
if parsed != {"deltas": []}:
    print(f"FAIL: fixture deltas want {{\"deltas\": []}}, got {parsed!r}")
    sys.exit(1)
print("OK: standing-FAIL excerpt replays failed-cycle + empty deltas")
EOF
ok "1. stored standing-FAIL replays as failed-cycle with empty deltas"

# ---------- 2. 24h repeat spec (issue acceptance, test-only) ----------
python3 - <<'EOF' || exit 1
from datetime import datetime, timezone

REPEAT_S = 24 * 3600

def should_fire_failed_cycle(cycle, last_verdict, last_pair, last_fired_at, now):
    if last_verdict != "FAIL":
        return False
    pair = (cycle, last_verdict)
    if last_pair is None:
        return True
    if pair != last_pair:
        return True
    return (now - last_fired_at) >= REPEAT_S

def should_fire_nth_gap(cycle, last_fired_at, now):
    if cycle % 4 != 1:
        return False
    if last_fired_at is None:
        return True
    return (now - last_fired_at) >= REPEAT_S

t0 = 0
# new-FAIL fires
assert should_fire_failed_cycle(16, "FAIL", None, None, t0) is True
# standing-FAIL at +3h skips
assert should_fire_failed_cycle(16, "FAIL", (16, "FAIL"), t0, t0 + 3 * 3600) is False
# +24h re-fires
assert should_fire_failed_cycle(16, "FAIL", (16, "FAIL"), t0, t0 + REPEAT_S) is True
# DONE→FAIL re-fires (verdict changed; pair is new)
assert should_fire_failed_cycle(16, "FAIL", (16, "DONE"), t0, t0 + 60) is True
# non-FAIL does not fire
assert should_fire_failed_cycle(16, "DONE", None, None, t0) is False

# nth-gap-cycle: cycle%4==1 fires once, then waits 24h; other cycles skip
assert should_fire_nth_gap(1, None, t0) is True
assert should_fire_nth_gap(1, t0, t0 + 3 * 3600) is False
assert should_fire_nth_gap(1, t0, t0 + REPEAT_S) is True
assert should_fire_nth_gap(2, None, t0) is False
assert should_fire_nth_gap(4, None, t0) is False
assert should_fire_nth_gap(5, None, t0) is True

# The live streak was seven fires inside 18h. A 24h repeat allows the first
# fire only; the other six would not dispatch.
streak = [
    datetime(2026, 9, 11, 23, 1, tzinfo=timezone.utc),
    datetime(2026, 9, 12, 1, 57, tzinfo=timezone.utc),
    datetime(2026, 9, 12, 4, 57, tzinfo=timezone.utc),
    datetime(2026, 9, 12, 7, 57, tzinfo=timezone.utc),
    datetime(2026, 9, 12, 10, 57, tzinfo=timezone.utc),
    datetime(2026, 9, 12, 13, 56, tzinfo=timezone.utc),
    datetime(2026, 9, 12, 16, 55, tzinfo=timezone.utc),
]
if len(streak) != 7:
    print(f"FAIL: streak want 7, got {len(streak)}"); raise SystemExit(1)
span = (streak[-1] - streak[0]).total_seconds()
if span >= REPEAT_S:
    print(f"FAIL: streak span {span}s is not inside 24h"); raise SystemExit(1)
fires = 0
last_pair = None
last_fired = None
for ts in streak:
    now = int(ts.timestamp())
    if should_fire_failed_cycle(16, "FAIL", last_pair, last_fired, now):
        fires += 1
        last_pair = (16, "FAIL")
        last_fired = now
if fires != 1:
    print(f"FAIL: 24h repeat would fire {fires} times on the 7-run streak, want 1")
    raise SystemExit(1)
print("OK: 24h spec: new-FAIL fires; +3h skips; +24h re-fires; DONE→FAIL re-fires; streak 7→1")
EOF
ok "2. 24h repeat spec matches the issue acceptance and collapses the 7-run streak to 1"

# ---------- 3. named files stay absent; lib/ and bin/ have no fire path ----------
[[ ! -f "$repo_root/lib/researcher-delta.py" ]] \
  || fail "lib/researcher-delta.py must stay absent (deleted 81227264f)"
[[ ! -f "$repo_root/bin/fleet-researcher-dispatch" ]] \
  || fail "bin/fleet-researcher-dispatch must stay absent (deleted fa2f27bf9)"
[[ ! -f "$repo_root/tests/fleet-researcher.test.sh" ]] \
  || fail "tests/fleet-researcher.test.sh must stay absent (deleted with the glue sweep)"
[[ ! -f "$repo_root/bin/fleet-researcher-run" ]] \
  || fail "bin/fleet-researcher-run must stay absent (deleted with the glue sweep)"
shopt -s nullglob
researcher_units=("$repo_root"/systemd/*researcher*)
shopt -u nullglob
((${#researcher_units[@]} == 0)) \
  || fail "systemd researcher unit(s) must stay absent: ${researcher_units[*]}"
ok "3a. researcher-delta, dispatch, researcher.test.sh, researcher-run, systemd units stay absent"

hits="$(grep -RInE 'failed-cycle|evaluate_triggers|last_failed_cycle|nth-gap-cycle' \
  "$repo_root/lib" "$repo_root/bin" 2>/dev/null || true)"
[[ -z "$hits" ]] || fail "lib/ or bin/ still contains a failed-cycle fire path:
$hits"
ok "3b. lib/ and bin/ have no failed-cycle / evaluate_triggers / nth-gap-cycle fire path"

# ---------- 4. negative: an unconditional append fails the detector ----------
mkdir -p "$scratch/lib"
cat >"$scratch/lib/researcher-delta.py" <<'PY'
def evaluate_triggers(state):
    if state.get("last_verdict") == "FAIL":
        return ["failed-cycle"]
    return []
PY
if grep -RInE 'failed-cycle|evaluate_triggers' "$scratch/lib" >/dev/null; then
    ok "4. negative check: unconditional failed-cycle append correctly fails the detector"
else
    fail "4. detector did NOT catch an injected evaluate_triggers failed-cycle append"
fi

echo
echo "ALL OK: fleet-researcher-failed-cycle checks passed"
exit 0
