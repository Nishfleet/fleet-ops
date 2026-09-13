#!/usr/bin/env bash
# tests/fleet-blindspot-count.test.sh
#
# fleet-ops#4460: pin the contract of libexec/fleet-blindspot-count.py —
# the two counts the weekly review opens with ("Caught by hand this week")
# and that measure.sh reports. The observable properties we prove:
#
#   1. With a decisions-ledger containing a dated caught-by-hand entry in
#      the window, caught_by_hand_7d counts it; out-of-window and
#      non-catch entries do not.
#   2. With trailing fable-check run outputs carrying `new-measure:` header
#      lines, new_measures_7d counts them; older-than-window outputs are
#      excluded.
#   3. A new-measure:<what> record in fable-state.json (current run) is
#      counted.
#   4. The metric invariant holds: new_measures_7d >= caught_by_hand_7d
#      when every caught item got a measure line, and the balance line is
#      "red" when a caught-by-hand item is NOT covered (blind spot).
#   5. Missing sources are not fabricated: an absent ledger/fable-state
#      yields 0, not a guess, and the script still exits 0.
#
# Environment seams (FLEET_LEDGER, FLEET_FABLE_STATE, FLEET_FABLE_OUT_DIR,
# FLEET_BLIND_NOW, FLEET_WINDOW_DAYS) keep this fully hermetic: no live
# ledger, no live fable-state, no network, no real fleet.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
py="$repo_root/libexec/fleet-blindspot-count.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$py" ]] || fail "not found: $py"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

scratch="$(mktemp -d -t fleet-blindspot-test.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

mkdir -p "$scratch/out"
NOW="2026-09-08T12:00:00Z"   # fixed reference "now"
WINDOW=7

# ---- fixtures -------------------------------------------------------------
# Ledger: two dated decision lines. "caught by hand this week" is in the
# window and tagged; "capacity is measured" is in-window but NOT a manual
# catch; "2026-08-01" is a catch but out of window.
cat >"$scratch/ledger.md" <<'LED'
# Decisions Ledger (fixture)
## Ledger
- 2026-09-07 | blind spot | caught by hand this week: judge missed the 19 red deploys | fleet-ops#4460
- 2026-09-08 | capacity | capacity is measured, never declared | fleet-ops #217
- 2026-08-01 | old catch | caught by hand this week: stale | fleet-ops#1
LED

# Fable-check run outputs, append-only by day. Today's has one new-measure,
# yesterday's has two (one of which names another caught-by-hand item), a
# 9-day-old file is out of window and excluded.
mkdir -p "$scratch/out"
cat >"$scratch/out/fable-check-2026-09-08.md" <<'F1'
# fable-check 2026-09-08T00-15-00Z
header: product: ... new-measure: caught-discarded-issues
F1
cat >"$scratch/out/fable-check-2026-09-07.md" <<'F2'
# fable-check 2026-09-07T00-15-00Z
header: new-measure: 19-red-deploys
header: new-measure: idle-pool
caught by hand: a note in this run
F2
cat >"$scratch/out/fable-check-2026-08-30.md" <<'F3'
# fable-check 2026-08-30T00-15-00Z
new-measure: stale-out-of-window
F3

export FLEET_LEDGER="$scratch/ledger.md"
export FLEET_FABLE_STATE="$scratch/fable-state.json"
export FLEET_FABLE_OUT_DIR="$scratch/out"
export FLEET_BLIND_NOW="$NOW"
export FLEET_WINDOW_DAYS="$WINDOW"

# fable-state.json carries a new-measure record for the current run.
cat >"$scratch/fable-state.json" <<'FJ'
{"runs": 15, "new_measures": [{"what": "starving-pool", "at": "2026-09-08T10:00:00Z"}]}
FJ

# ---- 1. caught_by_hand_7d counts in-window ledger catches only -----------
out=$(python3 "$py" 2>/dev/null) || fail "script exited non-zero on the happy path"
echo "$out" | grep -q '^new_measures_7d=4' \
  || fail "new_measures_7d must be 4 (today 1 + yesterday 2 + fable-state 1); got: $out"
echo "$out" | grep -q '^caught_by_hand_7d=2' \
  || fail "caught_by_hand_7d must be 2 (ledger 1 in-window catch + 1 catch-note in output); got: $out"
echo "$out" | grep -q '^blindspot_balance=ok$' \
  || fail "with all catches covered, balance must be ok; got: $out"
ok "1. counts in-window ledger catches + trailing-7d fable runs + fable-state"

# ---- 2. out-of-window fable output excluded ------------------------------
# Shrink the window to 1 day: only today's file + fable-state count.
out=$(FLEET_WINDOW_DAYS=1 python3 "$py" 2>/dev/null) || fail "script failed with 1-day window"
echo "$out" | grep -q '^new_measures_7d=2' \
  || fail "1-day window: new_measures_7d must be 2 (today 1 + fable-state 1); got: $out"
echo "$out" | grep -q '^caught_by_hand_7d=0' \
  || fail "1-day window: caught_by_hand_7d must be 0 (09-07 ledger catch is out of the 1-day window); got: $out"
ok "2. out-of-window fable-check outputs are excluded"

# ---- 3. red balance when a caught-by-hand item has NO measure line --------
# A caught-by-hand ledger entry in the window with no matching new-measure.
cat >"$scratch/ledger2.md" <<'LED'
- 2026-09-08 | blind spot | caught by hand this week: the $400 idle pool, not yet a measure line | fleet-ops#4460
LED
mkdir -p "$scratch/out2"
cat >"$scratch/out2/fable-check-2026-09-08.md" <<'F1'
# fable-check 2026-09-08T00-15-00Z
header: no new-measure here
F1
: >"$scratch/empty-state.json"
out=$(FLEET_LEDGER="$scratch/ledger2.md" FLEET_FABLE_STATE="$scratch/empty-state.json" \
      FLEET_FABLE_OUT_DIR="$scratch/out2" python3 "$py" 2>/dev/null) \
  || fail "script failed on the red-balance path"
echo "$out" | grep -q '^blindspot_balance=red' \
  || fail "a caught-by-hand item with no measure line must be red; got: $out"
ok "3. caught-by-hand with no measure line reports blindspot_balance=red"

# ---- 4. missing sources are not fabricated ---------------------------------
out=$(FLEET_LEDGER="$scratch/missing-ledger.md" FLEET_FABLE_STATE="$scratch/missing-state.json" \
      FLEET_FABLE_OUT_DIR="$scratch/missing-out" python3 "$py" 2>/dev/null) \
  || fail "script must exit 0 on missing sources"
echo "$out" | grep -q '^new_measures_7d=0$' || fail "missing fable-state must yield 0, got: $out"
echo "$out" | grep -q '^caught_by_hand_7d=0$' || fail "missing ledger must yield 0, got: $out"
echo "$out" | grep -q '^blindspot_balance=ok$' || fail "0/0 must be ok, got: $out"
ok "4. missing sources yield 0 (never a guess), exit 0"

# ---- 5. CI host lock (fleet-ops#449). Workers cannot edit .github/workflows.
#       This file must be listed in ci.yml OR invoked from a test that is.
ci_yml="$repo_root/.github/workflows/ci.yml"
listed=0
hosted=0
grep -Fq 'bash tests/fleet-blindspot-count.test.sh' "$ci_yml" && listed=1
grep -Fq 'bash "$here/fleet-blindspot-count.test.sh"' "$repo_root/tests/seat""-lib.test.sh" && hosted=1
if [[ "$listed" -eq 0 && "$hosted" -eq 0 ]]; then
  fail "fleet-blindspot-count.test.sh has no CI host (fleet-ops#449): list it in ci.yml or invoke it from seat.lib.test.sh"
fi
ok "5. CI host exists (ci.yml listed=$listed seatlib hosted=$hosted)"

echo
echo "ALL OK"
