#!/usr/bin/env bash
# tests/seat-empty-run-park-persists.test.sh
#
# fleet-ops#3666: the failure-ceiling park (SEAT_PARK_WALL_S, 24 h) must
# PERSIST across the 24 h boundary, not be overwritten by a short flat
# cooldown. The live symptom (2026-09-05): ollama/deepseek-v4-flash:0731
# no-op'ed 24x/2h; the empty-run handler logged "unusable until +24h
# (backoff=86400s, count=9/10/11)" but the live seat row showed
# bench_backoff_s=1800 with ledger_health_class=healthy — the 86400 s bench
# was written then lost, and the dead seat re-entered the no-op loop every
# ~30 min.
#
# Root cause: the empty-run count-merge window (EMPTY_RUN_COUNT_WINDOW_S)
# was shorter than the park wall. A parked seat is held out of rotation by
# its marker's usable_at for the full 24 h, so "no new empty run for 6 h"
# (the pre-#3666 window) is NOT a recovery signal for a parked seat — it is
# just the park holding. The global seat-health probe clobbers the ledger to
# health_class=healthy/count=0 during the park (a 200 HTTP observation on a
# no-op'ing seat). Once the marker aged past the count window, the count-merge
# fell through to the clobbered ledger, the count reset to 1, and the next
# no-op at the 24 h boundary dropped the bench back to the 900 s base — the
# 24 h park was overwritten by a 30 min flat cooldown.
#
# The fix (fleet-ops#3666): EMPTY_RUN_COUNT_WINDOW_S defaults to the PARK
# WALL (SEAT_PARK_WALL_S, 24 h) so the marker-carried count survives the
# full park. A no-op at the 24 h boundary merges the marker count (not the
# clobbered ledger), re-parks immediately, and the seat stays out of
# rotation.
#
# This test proves, end to end against the live wrapper:
#   (a) a seat parked at the failure ceiling (count=ceiling) writes a 24 h
#       park to BOTH the ledger and the marker.
#   (b) after the ledger is clobbered to healthy/count=0 (the global probe)
#       and the marker is aged to just under the 24 h park boundary, a new
#       empty-run MERGES the marker count (not the clobbered ledger), so the
#       count climbs (ceiling -> ceiling+1) and the park RE-PARKS at 24 h —
#       the bench does NOT drop to the 900 s base. This is the #3666 fix.
#   (c) seat_usable holds the re-parked seat UNUSABLE across the boundary.
#   (d) a marker aged PAST the 24 h park wall DOES reset the count (the real
#       recovery signal — a full park wall with no no-op — is honoured), so
#       the wider window does not wall a recovered seat forever.
#
# Runs entirely offline: scratch ledger, scratch state, no network, no
# systemd. Mirrors the harness of tests/seat-empty-run-clobber-park.test.sh.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
seat_lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch="$(mktemp -d -t seat-empty-run-park-persists.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
STATE_DIR="$scratch/state"
mkdir -p "$STATE_DIR/attempts" "$STATE_DIR/active-seats"
LEDGER="$scratch/ledger"
mkdir -p "$LEDGER"
export PI_PACKET_STATE="$STATE_DIR"
export PI_SEAT_HEALTH_LEDGER_DIR="$LEDGER"
export PI_SEAT_HEALTH_SIDECAR="$scratch/pi-seat-health.json"
export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export XDG_RUNTIME_DIR="$scratch/xdg"
export PI_SEAT_LIB_CHECK_SYSTEMD=0
# Test isolation: pin the failure ceiling low so the park fires in a few
# iterations. Production default is 20 (fleet-ops#3531).
export SEAT_FAILURE_CEILING=3
export SEAT_PARK_WALL_S=86400
export EMPTY_RUN_MARKER_FRESH_S=1800
# Leave EMPTY_RUN_COUNT_WINDOW_S at its DEFAULT (now SEAT_PARK_WALL_S = 24 h,
# fleet-ops#3666) so this test exercises the production window, NOT a pinned
# override.
# Disable the corpse reclassification (fleet-ops#2594) so the parked seat is
# not also written seat_dead=true — this test proves the parking behaviour
# in isolation.
export SEAT_DEAD_CONSECUTIVE_THRESHOLD=999999
mkdir -p "$XDG_RUNTIME_DIR"

cat >"$PI_MODELS_JSON" <<'JSON'
{
  "providers": {
    "ollama": {
      "models": [
        { "id": "deepseek-v4-flash:0731", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 }
      ]
    }
  }
}
JSON

cat >"$SEAT_CAPS_JSON" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["ollama"],
  "providers": {
    "ollama": { "cap": 6, "class": "free", "quota_bench_default_s": 900, "overload_bench_default_s": 600, "models": { "deepseek-v4-flash:0731": 3 } }
  }
}
JSON

# shellcheck disable=SC1091
source "$seat_lib"

ledger_file() {
    local p="$1" m="$2"
    printf '%s/%s__%s.json' "$LEDGER" \
        "${p//[^A-Za-z0-9._-]/_}" "${m//[^A-Za-z0-9._-]/_}"
}

marker_file() {
    local p="$1" m="$2"
    printf '%s/%s__%s.spawn-bench.json' "$LEDGER" \
        "${p//[^A-Za-z0-9._-]/_}" "${m//[^A-Za-z0-9._-]/_}"
}

# Simulate seat-health.ts writing a healthy observation to the ledger (the
# global-probe clobber that zeroes consecutive_failure_count during a park).
clobber_with_healthy() {
    local p="$1" m="$2" lf="$3"
    local now_utc
    now_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local tmp="$lf.clobber.$$.$RANDOM.tmp"
    jq -nc \
        --arg provider "$p" --arg model "$m" --arg obs "$now_utc" \
        '{provider:$provider, model:$model, http_status:200,
          health_class:"healthy", retryable:false, seat_dead:false,
          poison_ladder:false, observed_at:$obs,
          source:"after_provider_response", failure_mode:"none",
          usable_at:null, consecutive_failure_count:0}' \
        > "$tmp" 2>/dev/null
    mv "$tmp" "$lf" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

count_of() { jq -r '.consecutive_failure_count // 0' "$1" 2>/dev/null || echo 0; }
usable_of() { jq -r '.usable_at // ""' "$1" 2>/dev/null || true; }
wall_s_of_marker() {
    local u now_s u_s
    u=$(usable_of "$1")
    [[ -n "$u" ]] || { echo 0; return; }
    now_s=$(date -u +%s)
    u_s=$(date -u -d "$u" +%s 2>/dev/null || echo 0)
    echo $((u_s - now_s))
}

# Age the marker's written_at to <age_s> seconds ago.
age_marker() {
    local mf="$1" age_s="$2"
    local aged_iso
    aged_iso=$(date -u -d "@$(($(date -u +%s) - age_s))" +%Y-%m-%dT%H:%M:%SZ)
    local tmp
    tmp=$(mktemp)
    jq --arg w "$aged_iso" '.written_at = $w' "$mf" >"$tmp" 2>/dev/null && mv "$tmp" "$mf"
}

p="ollama"; m="deepseek-v4-flash:0731"
lf=$(ledger_file "$p" "$m")
mf=$(marker_file "$p" "$m")

# --- (a) park at the failure ceiling writes a 24 h wall to both stores ----
rm -f "$lf" "$mf"
for i in 1 2 3; do
    mark_seat_empty_run "$p" "$m" "t3666:noop:${i}" >/dev/null 2>&1 \
        || fail "mark_seat_empty_run #${i} failed"
    clobber_with_healthy "$p" "$m" "$lf"
done
park_count=$(count_of "$mf")
[[ "$park_count" == "3" ]] \
    || fail "(a) marker count after 3 no-ops = $park_count, want 3 (SEAT_FAILURE_CEILING=3)"
park_wall=$(wall_s_of_marker "$mf")
(( park_wall >= SEAT_PARK_WALL_S - 120 && park_wall <= SEAT_PARK_WALL_S + 120 )) \
    || fail "(a) park wall = ${park_wall}s, want ~${SEAT_PARK_WALL_S}s — the failure-ceiling park must fire at count=3"
# The ledger was clobbered to healthy/count=0 by the last clobber; the
# marker is the durable count authority.
ledger_hc=$(jq -r '.health_class // ""' "$lf" 2>/dev/null || true)
ledger_cnt=$(jq -r '.consecutive_failure_count // 0' "$lf" 2>/dev/null || echo 0)
[[ "$ledger_hc" == "healthy" && "$ledger_cnt" == "0" ]] \
    || fail "(a) ledger after clobber = hc=$ledger_hc count=$ledger_cnt, want healthy/0 (the global-probe clobber)"
ok "(a) seat parked at count=3: marker wall=${park_wall}s (~24h), marker count=3, ledger clobbered healthy/0 — the marker carries the park"

# --- (b) a no-op at the 24 h boundary RE-PARKS from the marker count -----
# This is the #3666 fix. The marker is aged to just under the 24 h park wall
# (still inside EMPTY_RUN_COUNT_WINDOW_S = 24 h), and the ledger was
# clobbered to healthy/count=0 by the global probe during the park. A new
# empty-run at the boundary MUST merge the marker count (3), not the
# clobbered ledger (0), so the count climbs to 4 and the park RE-PARKS at
# 24 h — it must NOT drop to the 900 s base.
age_marker "$mf" $((SEAT_PARK_WALL_S - 600))   # 23h50m ago — still inside the 24h window
clobber_with_healthy "$p" "$m" "$lf"            # global probe clobbers ledger during the park
mark_seat_empty_run "$p" "$m" "t3666:boundary-noop" >/dev/null 2>&1 \
    || fail "mark_seat_empty_run (boundary) failed"
boundary_count=$(count_of "$mf")
[[ "$boundary_count" == "4" ]] \
    || fail "(b) marker count at the 24h boundary = $boundary_count, want 4 — the marker count (3) must carry forward across the park boundary, NOT reset to 1 from the clobbered ledger (fleet-ops#3666)"
boundary_wall=$(wall_s_of_marker "$mf")
(( boundary_wall >= SEAT_PARK_WALL_S - 120 && boundary_wall <= SEAT_PARK_WALL_S + 120 )) \
    || fail "(b) boundary park wall = ${boundary_wall}s, want ~${SEAT_PARK_WALL_S}s — the park must RE-PARK at 24h from the marker-carried count; before #3666 the count reset to 1 and the bench dropped to the 900s base (the 'overwritten by a 30m flat cooldown' symptom)"
ok "(b) no-op at the 24h boundary: count 3 -> 4 (marker carries, NOT the clobbered ledger), park RE-PARKS at ${boundary_wall}s — the 24h park PERSISTS (fleet-ops#3666)"

# --- (c) seat_usable holds the re-parked seat UNUSABLE across the boundary
if seat_usable "$p" "$m"; then
    fail "(c) seat_usable returned usable on the re-parked seat — the park wall must hold it out of rotation across the 24h boundary"
fi
ok "(c) re-parked seat is HELD UNUSABLE by seat_usable — the dead seat does not re-enter the no-op loop at the park boundary"

# --- (d) a marker aged PAST the 24 h park wall DOES reset (recovery) -----
# A seat that goes a full park wall (24 h) without no-op'ing has recovered.
# The next empty-run must start a fresh count, not carry the stale high count
# forward. This is the fail-open contract: the wider window does not wall a
# recovered seat forever.
rm -f "$lf" "$mf"
mark_seat_empty_run "$p" "$m" "t3666:recovery-seed" >/dev/null 2>&1 \
    || fail "mark_seat_empty_run (recovery seed) failed"
clobber_with_healthy "$p" "$m" "$lf"
[[ "$(count_of "$mf")" == "1" ]] \
    || fail "(d) seed count = $(count_of "$mf"), want 1"
# Age the marker past the 24 h park wall (the count window) + margin.
age_marker "$mf" $((SEAT_PARK_WALL_S + 600))
clobber_with_healthy "$p" "$m" "$lf"
mark_seat_empty_run "$p" "$m" "t3666:after-recovery" >/dev/null 2>&1 \
    || fail "mark_seat_empty_run (after recovery) failed"
fresh_count=$(count_of "$mf")
[[ "$fresh_count" == "1" ]] \
    || fail "(d) after a > 24h gap, merged count = $fresh_count, want 1 — a full park wall with no no-op is the real recovery signal; the count must reset"
ok "(d) a > 24h gap resets the empty-run count (recovered seat is NOT walled forever) — the park-wall window honours fail-open"

ok "fleet-ops#3666: the failure-ceiling park (24h) PERSISTS across the park boundary — a no-op at 24h re-parks from the marker-carried count (not the clobbered ledger), so the dead seat stays out of rotation instead of re-entering the no-op loop every ~30min"
