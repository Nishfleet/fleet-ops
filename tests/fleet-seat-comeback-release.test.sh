#!/usr/bin/env bash
# tests/fleet-seat-comeback-release.test.sh
#
# fleet-ops#2421: the ACTIVE release path for walled seats. A seat whose
# wall clock (bench_until ?? usable_at) has passed is re-probed through the
# real router with a TOOL-USING probe (pi --print): a bash-compute packet whose computed token must appear in the output; an inline-only PONG-ok answer does NOT release (tool-503 stays benched)— on a successful probe
# the seat is UNWALLED (healthy observation written to the ledger); on a
# failed probe it stays walled and the extension re-anchors. Loud check:
# after the sweep, walled seats still holding EXPIRED wall clocks with
# nothing released -> exit 1 + fleet_seat_comeback_release_stalled=1.
#
# This test builds a scratch SEATS_DIR with known fixtures and a stub
# PI_BIN (never touches the real pi / real ledger), then asserts:
#   - selection: only genuinely-expired walled seats are probed; test__
#     fixtures, .spawn-bench pseudo-seats, corpses (except the
#     fleet-ops#3156 no-wall prober-corpse subclass) and future-wall seats
#     are never probed (the two predecessor-killer bugs, fleet-ops#2394).
#   - release: a successful probe unwalls the seat (health_class=healthy,
#     usable_at/bench_until null, count 0) -> released_total increments,
#     last-green written, exit 0.
#   - loud stall: a failed probe with no re-anchor leaves the seat expired
#     -> released_this_run=0 -> exit 1 + stalled=1 + no last-green.
#   - override: a wall-expired seat probed within MIN_INTERVAL_S is
#     re-probed anyway (the stale-wall unstick path, fleet-ops#2421
#     follow-up 2026-08-31 straitly/gpt-5.6-sol — a timeout leaves the
#     extension unable to re-anchor, so the wall stays stale and the
#     min-interval would otherwise block re-probing forever).
#   - future-wall: a seat whose usable_at is still in the future is
#     never probed (the wall-in-future check is the only remaining
#     throttle; it precedes the min-interval check).
#   - overdue-clears (fleet-ops#2520): the FleetSeatComebackOverdue alert
#     keys on the metrics-side fleet_seat_comeback_overdue_total, exported
#     from _read_comeback_overdue against the SAME ledger. A past-wall
#     seat must count overdue BEFORE the sweep; after the sweep the count
#     must be 0 — probed+unwalled on a successful probe, or re-benched
#     into the future on a probe failure (the #2493 timeouts). The count
#     legitimately stays 1 only in the one stuck case: the wall cannot be
#     advanced (read-only ledger, section 3c).
#   - retirement (fleet-ops#2716): a corpse ledger (seat_dead=true,
#     health_class=corpse) whose observed_at has aged past the corpse
#     grace window (default 6h) is PHYSICALLY moved out of the live
#     roster into a dated lanes/seats-corpse-retired-<UTC-ts>/ dir; a
#     fresh corpse (inside grace) or a corpse still carrying a future
#     wall clock is held. This is the terminal step of the seat
#     lifecycle this organ owns (seat-caps.json retiring the slug only
#     stops the rotation, #2708).
#   - comeback-release stuck corpses (fleet-ops#3156): a PROBER-created
#     no-wall corpse (failure_mode comeback_never_released, wall null) is
#     the lived seats_dead stuck case — inside its 6h grace nothing
#     releases or retires it. It now gets ONE second-chance re-probe:
#     on success it is UNWALLED (transitions OUT of corpse), on failure
#     it is explicitly RETIRED immediately (grace bypass). Only that
#     subclass is re-probed; other corpse sources (after_provider_response
#     etc.) and corpses still owed a comeback clock stay held/terminal.
#
# Sandbox: scratch SEATS_DIR/state/prom + stub pi only. No live ledger,
# no live pi, no systemd.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
BIN="$repo_root/bin/fleet-seat-comeback-release"
# fleet-ops#2661: bin/fleet-seat-comeback-release sources seat-lib.sh
# (seat_ledger_path + _record_learned_cap) for the overload-strike +
# provider-wide wall. The bin's `[[ -f "$SEAT_LIB" ]]` guard makes the
# source OPTIONAL — on hosted CI $HOME/.local/lib/pi-packet/seat-lib.sh
# is absent, seat-lib never loads, seat_is_overload_bench returns 1,
# register_overload_strike is never called, and the pong-ok test sees
# `got 0` strikes (PR #2685/#2687 P14 red). Point the bin at the in-repo
# seat-lib explicitly so the contract is "tests provide seat-lib", matching
# every other fleet-ops seat-lib test (pi-scout-seat-rotation,
# keystone-routing, pi-issue-run-*).
export PI_PACKET_SEAT_LIB="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# Metrics-side overdue count (_read_comeback_overdue in
# libexec/fleet-metrics-export.py) over $SEATDIR, evaluated at NOW_EPOCH
# (the sweep's frozen now). This is exactly what feeds
# fleet_seat_comeback_overdue_total, the FleetSeatComebackOverdue alert
# source — asserting 0 here proves the sweep cleared the overdue metric.
overdue_n() {
    python3 - "$repo_root/libexec/fleet-metrics-export.py" "$SEATDIR" "$NOW_EPOCH" <<'PY'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("fme", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.SEAT_LEDGER = Path(sys.argv[2])
m.time.time = lambda: int(sys.argv[3])
cb_n, _ = m._read_comeback_overdue()
print(cb_n)
PY
}

command -v jq >/dev/null 2>&1 || fail "jq missing"
command -v python3 >/dev/null 2>&1 || fail "python3 required (exporter overdue assertion, fleet-ops#2520)"

# Fixed NOW so the test is stable regardless of when it runs.
NOW_ISO="2026-08-30T12:00:00Z"
NOW_EPOCH=$(date -u -d "$NOW_ISO" +%s)

TMPD="$(mktemp -d -t seat-comeback-release.XXXXXX)"
SEATDIR="$TMPD/seats"
mkdir -p "$SEATDIR"
cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT INT TERM

# --- stub pi: SUCCESS stub exits 0 with "OK", FAILURE stub exits 1 -------
cat > "$TMPD/pi-tool-ok" <<'EOF'
#!/usr/bin/env bash
# A healthy tool-using probe: prints the computed token of `echo $((6*7))`.
printf '42\n'
exit 0
EOF
cat > "$TMPD/pi-pong-ok" <<'EOF'
#!/usr/bin/env bash
# A partial-storm seat: answers inline "OK" but no tool result (no token).
printf 'OK\n'
exit  0
EOF
cat > "$TMPD/pi-fail" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat > "$TMPD/pi-timeout" <<'EOF'
#!/usr/bin/env bash
exit 124
EOF
chmod +x "$TMPD/pi-tool-ok" "$TMPD/pi-pong-ok" "$TMPD/pi-fail" "$TMPD/pi-timeout"

# --- synthetic fixtures ---------------------------------------------------
# 1. Walled, wall clock EXPIRED, release-at-expiry class (overload_bench,
#    bench_until past). Probe owed -> released on success.
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" << 'EOF'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":503,"retry_after":null,"health_class":"overload_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:52:47Z","source":"overload_bench","failure_mode":"overload_503","bench_until":"2026-08-30T10:02:47Z","usable_at":"2026-08-30T10:02:47Z","bench_window_s":600,"consecutive_failure_count":5}
EOF

# 2. Walled, wall clock EXPIRED, quota_exhausted (the issue's straitly
#    shape). Probe owed -> released on success.
cat > "$SEATDIR/straitly__gpt-5.6-sol.json" << 'EOF'
{"provider":"straitly","model":"gpt-5.6-sol","http_status":402,"retry_after":null,"health_class":"quota_exhausted","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:00:00.000Z","source":"provider_fetch","failure_mode":"quota_exhausted","usable_at":"2026-08-30T09:30:21.000Z","consecutive_failure_count":23}
EOF

# 3. Walled but wall clock in the FUTURE (held). Must NOT be probed.
cat > "$SEATDIR/opencode__nemotron-3-ultra-free.json" << 'EOF'
{"provider":"opencode","model":"nemotron-3-ultra-free","http_status":429,"retry_after":null,"health_class":"rate_limited","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T08:00:00Z","source":"after_provider_response","failure_mode":"rate_limit","usable_at":"2026-08-30T23:00:00.094Z","consecutive_failure_count":3}
EOF

# 4. test__ fixture (provider == "test"), wall EXPIRED. Must NEVER be
#    probed (the fleet-ops#2394 predecessor-killer).
cat > "$SEATDIR/test__test.json" << 'EOF'
{"provider":"test","model":"test","http_status":429,"retry_after":null,"health_class":"rate_limited","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-29T03:43:09.561Z","source":"after_provider_response","failure_mode":"rate_limit","usable_at":"2026-08-29T03:58:09.561Z","consecutive_failure_count":2}
EOF

# 5. .spawn-bench pseudo-seat, wall EXPIRED. Must NEVER be probed.
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.spawn-bench.json" << 'EOF'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","usable_at":"2026-08-29T16:36:06Z","reason":"no_block:rc=0","written_at":"2026-08-29T16:31:06Z","backoff_s":300}
EOF

# 6. Corpse (seat_dead=true, class corpse), wall EXPIRED. Terminal
#    (fleet-ops#2327/#2415) — never probed, never released.
cat > "$SEATDIR/devin__glm-5-2.json" << 'EOF'
{"provider":"devin","model":"glm-5-2","http_status":503,"retry_after":null,"health_class":"corpse","retryable":true,"seat_dead":true,"poison_ladder":false,"observed_at":"2026-08-29T00:00:00Z","source":"after_provider_response","failure_mode":"transient_http","usable_at":"2026-08-29T01:00:00Z","consecutive_failure_count":150}
EOF

# 7. Healthy seat. Never probed.
cat > "$SEATDIR/bai__deepseek-v4-flash.json" << 'EOF'
{"provider":"bai","model":"deepseek-v4-flash","http_status":200,"retry_after":null,"health_class":"healthy","retryable":false,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T11:00:00Z","source":"after_provider_response","failure_mode":"none","usable_at":null,"consecutive_failure_count":0}
EOF

STATE="$TMPD/state.json"
PROM="$TMPD/release.prom"

# --- 1. dry-run: selection ------------------------------------------------
out=$(PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" --dry-run 2>&1)
grep -q "would probe commandcode/poolside/laguna-s-2.1-free" <<<"$out" \
  || fail "dry-run: expired overload_bench seat must be selected for probe: $out"
grep -q "would probe straitly/gpt-5.6-sol" <<<"$out" \
  || fail "dry-run: expired quota_exhausted seat must be selected for probe: $out"
grep -qi "test__test" <<<"$out" && fail "dry-run: test__ fixture must never be probed: $out"
grep -qi "spawn-bench" <<<"$out" && fail "dry-run: spawn-bench pseudo-seat must never be probed: $out"
grep -qi "would probe devin/glm-5-2" <<<"$out" && fail "dry-run: corpse must never be probed: $out"
grep -qi "nemotron" <<<"$out" && fail "dry-run: future-wall seat must never be probed: $out"
grep -qi "bai/deepseek" <<<"$out" && fail "dry-run: healthy seat must never be probed: $out"
# fleet-ops#2716: the devin corpse (observed 2026-08-29, ~36h old) IS past
# the 6h corpse grace — dry-run must PREVIEW its retirement but never act.
grep -q "would retire devin/glm-5-2" <<<"$out" \
  || fail "dry-run: aged corpse must be scanned for retirement: $out"
# Dry-run must not touch the ledger, state or prom.
[[ ! -e "$STATE" ]] || fail "dry-run must not write state"
[[ ! -e "$PROM" ]] || fail "dry-run must not write prom"
[[ ! -d "$TMPD/seats-corpse-retired-$NOW_ISO" ]] \
  || fail "dry-run must not create a corpse retirement dir"
[[ -f "$SEATDIR/devin__glm-5-2.json" ]] \
  || fail "dry-run must not move the corpse ledger"
grep -q '"health_class":"overload_bench"' "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" \
  || fail "dry-run must not modify the ledger"
ok "dry-run selects only owed expired-wall seats; test__/spawn-bench/future/healthy never probed, aged corpse previewed for retirement"

# --- 2. live run, probes SUCCEED: both seats released --------------------
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/live-ok.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "successful probes: expected exit 0, got $rc ($(cat "$TMPD/live-ok.err"))"
health=$(jq -r '.health_class' "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json")
[[ "$health" == "healthy" ]] || fail "overload_bench seat must be unwalled (healthy), got $health"
jq -e '.usable_at == null and .bench_until == null and .consecutive_failure_count == 0 and .seat_dead == false and .failure_mode == "none"' \
  "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" >/dev/null \
  || fail "overload_bench seat healthy write must clear the wall and count: $(cat "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json")"
health=$(jq -r '.health_class' "$SEATDIR/straitly__gpt-5.6-sol.json")
[[ "$health" == "healthy" ]] || fail "quota_exhausted seat must be unwalled (healthy), got $health"
# State + prom reflect the release.
released_total=$(jq -r '.released_total' "$STATE")
[[ "$released_total" == "2" ]] || fail "released_total must be 2, got $released_total"
grep -q "^fleet_seat_comeback_release_released_total 2$" "$PROM" \
  || fail "prom released_total must be 2: $(cat "$PROM")"
grep -q "^fleet_seat_comeback_release_stalled 0$" "$PROM" \
  || fail "prom stalled must be 0: $(cat "$PROM")"
grep -qE "^fleet_seat_comeback_release_last_green_seconds [0-9]+$" "$PROM" \
  || fail "prom last-green must be written on a green sweep: $(cat "$PROM")"
# fleet-ops#2716: the devin corpse (observed 2026-08-29T00:00:00Z, ~36h old)
# is past the 6h corpse grace — the live sweep must PHYSICALLY retire it out
# of the live roster: ledger gone from SEATDIR, present in the dated
# seats-corpse-retired-<ts>/ audit dir, retired_total=1 in prom and state.
[[ ! -e "$SEATDIR/devin__glm-5-2.json" ]] \
  || fail "corpse ledger must be retired out of the live roster: $(cat "$SEATDIR/devin__glm-5-2.json")"
retdir="$TMPD/seats-corpse-retired-$NOW_ISO"
[[ -f "$retdir/devin__glm-5-2.json" ]] \
  || fail "retired corpse ledger must land in the dated retirement dir ($retdir): $(ls -la "$TMPD" 2>&1)"
grep -q "^fleet_seat_comeback_release_retired_total 1$" "$PROM" \
  || fail "prom retired_total must be 1: $(cat "$PROM")"
retired_total=$(jq -r '.retired_total' "$STATE")
[[ "$retired_total" == "1" ]] || fail "state retired_total must be 1, got $retired_total"
ok "successful probes release (unwall) both expired seats; corpse retired out of the roster; green prom, exit 0"

# --- 3. re-bench on probe failure (fleet-ops#2493) -----------------------
# The fleet-ops#2493 fix: a probe that fails with no real HTTP response
# (rc=124 timeout, or rc=1 generic failure) leaves the ledger with a
# STALE wall clock in the past. Without re-benching, the next 15-min
# tick finds the same expired wall, re-probes, re-fails, and the loop
# runs forever. Re-bench HERE on probe failure: advance usable_at and
# bench_until to now + REBENCH_BACKOFF_S so the next tick skips the
# seat (wall-in-future check) until the new window passes. The post-
# sweep expired count is 0 (re-benched) so the loud-stall check does
# NOT fire — the release path IS operating, it just couldn't unwall.
# Fresh scratch fixture set: the two expired seats only.
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" << 'EOF'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":503,"retry_after":null,"health_class":"overload_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:52:47Z","source":"overload_bench","failure_mode":"overload_503","bench_until":"2026-08-30T10:02:47Z","usable_at":"2026-08-30T10:02:47Z","bench_window_s":600,"consecutive_failure_count":5}
EOF
cat > "$SEATDIR/straitly__gpt-5.6-sol.json" << 'EOF'
{"provider":"straitly","model":"gpt-5.6-sol","http_status":402,"retry_after":null,"health_class":"quota_exhausted","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:00:00.000Z","source":"provider_fetch","failure_mode":"quota_exhausted","usable_at":"2026-08-30T09:30:21.000Z","consecutive_failure_count":23}
EOF
STATE="$TMPD/state-fail.json"
PROM="$TMPD/release-fail.prom"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-fail" \
    bash "$BIN" >/dev/null 2>"$TMPD/live-fail.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "re-bench path: expected exit 0 (re-benched, not loud), got $rc ($(cat "$TMPD/live-fail.err"))"
grep -q "REBENCHED commandcode/poolside/laguna-s-2.1-free" "$TMPD/live-fail.err" \
  || fail "re-bench: must log REBENCHED for the overload_bench seat: $(cat "$TMPD/live-fail.err")"
grep -q "REBENCHED straitly/gpt-5.6-sol" "$TMPD/live-fail.err" \
  || fail "re-bench: must log REBENCHED for the quota_exhausted seat: $(cat "$TMPD/live-fail.err")"
# The ledger now carries the fresh bench: usable_at and bench_until are
# in the future (now + 900s = 2026-08-30T12:15:00Z) and the source is
# comeback_release_rebench. The prior class is replaced (the wall is
# the truth now, not the prior failure class).
new_usable=$(jq -r '.usable_at' "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json")
new_usable_epoch=$(date -u -d "$new_usable" +%s 2>/dev/null || echo 0)
(( new_usable_epoch > NOW_EPOCH )) || fail "re-bench: usable_at must be in the future, got $new_usable (epoch=$new_usable_epoch, now=$NOW_EPOCH)"
jq -e '.source == "comeback_release_rebench" and .failure_mode == "overload_503" and .health_class == "overload_bench" and .consecutive_failure_count == 6' \
  "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" >/dev/null \
  || fail "re-bench: overload seat must PRESERVE overload_bench/overload_503 across re-bench (fleet-ops#2661), count incremented: $(cat "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json")"
jq -e '.source == "comeback_release_rebench" and .consecutive_failure_count == 24' \
  "$SEATDIR/straitly__gpt-5.6-sol.json" >/dev/null \
  || fail "re-bench: quota seat count must increment: $(cat "$SEATDIR/straitly__gpt-5.6-sol.json")"
# Prom reflects the re-bench (not a stall): stalled=0, walled_expired=0,
# probed_total advanced, last-green written.
grep -q "^fleet_seat_comeback_release_stalled 0$" "$PROM" \
  || fail "re-bench: prom stalled must be 0 (re-benched, not stalled): $(cat "$PROM")"
grep -qE "^fleet_seat_comeback_release_walled_expired 0$" "$PROM" \
  || fail "re-bench: prom walled_expired must be 0 (walls advanced): $(cat "$PROM")"
grep -qE "^fleet_seat_comeback_release_last_green_seconds [0-9]+$" "$PROM" \
  || fail "re-bench: prom last-green must be written (the release path is operating): $(cat "$PROM")"
grep -q "^fleet_seat_comeback_release_probed_total 2$" "$PROM" \
  || fail "re-bench: prom probed_total must be 2: $(cat "$PROM")"
ok "re-bench: probe failure advances the wall to now+REBENCH_BACKOFF_S; no loud stall, next tick skips"

# --- 3b. re-bench: subsequent tick with future wall skips the seat -------
# After re-bench, the wall is in the future. The next 15-min tick should
# skip the seat via the wall-in-future check (the only remaining
# throttle). A second probe attempt must NOT happen (no point — the
# wall is fresh, the next probe is owed only after the new window).
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" << 'EOF'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":503,"retry_after":null,"health_class":"transient_fault","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T12:05:00Z","source":"comeback_release_rebench","failure_mode":"comeback_rebench","usable_at":"2026-08-30T13:00:00Z","bench_until":"2026-08-30T13:00:00Z","bench_window_s":900,"consecutive_failure_count":6}
EOF
STATE="$TMPD/state-rebench-skip.json"
PROM="$TMPD/release-rebench-skip.prom"
out=$(PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" --dry-run 2>&1)
grep -qi "poolside" <<<"$out" \
  && fail "re-bench follow-up: future-wall seat must NOT be re-probed: $out"
released_total=$(jq -r '.released_total' "$STATE" 2>/dev/null || echo 0)
[[ "$released_total" == "0" ]] || fail "re-bench follow-up: released_total must be 0, got $released_total"
ok "re-bench follow-up: future-wall seat is skipped by the wall-in-future check (no probe, no release)"

# --- 3c. loud stall: re-bench itself FAILS (ledger unwritable) -----------
# The loud-stall check still fires when re-bench cannot advance the
# wall (e.g. the ledger directory is read-only). The release path is
# then genuinely stuck: probes fail AND re-bench fails, so the wall
# stays in the past. Simulate by making the ledger dir read-only so
# the re-bench write errors out (mv fails). Note: bash atomic write
# creates a tmp file in the same dir, so a read-only dir blocks BOTH
# the re-bench and any future write.
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" << 'EOF'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":503,"retry_after":null,"health_class":"overload_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:52:47Z","source":"overload_bench","failure_mode":"overload_503","bench_until":"2026-08-30T10:02:47Z","usable_at":"2026-08-30T10:02:47Z","bench_window_s":600,"consecutive_failure_count":5}
EOF
STATE="$TMPD/state-stall.json"
PROM="$TMPD/release-stall.prom"
chmod 0555 "$SEATDIR"  # read+exec only; writes blocked
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-fail" \
    bash "$BIN" >/dev/null 2>"$TMPD/live-stall.err"
stall_rc=$?
set -e
chmod 0755 "$SEATDIR"  # restore for cleanup
[[ "$stall_rc" == "1" ]] || fail "re-bench-fails: expected exit 1 (loud), got $stall_rc ($(cat "$TMPD/live-stall.err"))"
grep -q "LOUD \[COMEBACK-RELEASE-STALLED\]" "$TMPD/live-stall.err" \
  || fail "re-bench-fails: must render the LOUD line: $(cat "$TMPD/live-stall.err")"
grep -q "^fleet_seat_comeback_release_stalled 1$" "$PROM" \
  || fail "re-bench-fails: prom stalled must be 1: $(cat "$PROM")"
# fleet-ops#2806: the same read-only shape leaves usable_at in the past by
# ~2h (> one probe interval) after the sweep — the interval-breach loud
# channel must fire its own LOUD line and gauge (the releaser had a full
# probe cycle and could not move the wall).
grep -q "LOUD \[COMEBACK-RELEASE-INTERVAL-BREACH\]" "$TMPD/live-stall.err" \
  || fail "re-bench-fails: must render the INTERVAL-BREACH LOUD line: $(cat "$TMPD/live-stall.err")"
grep -q "^fleet_seat_comeback_release_interval_breached_total 1$" "$PROM" \
  || fail "re-bench-fails: prom interval_breached_total must be 1: $(cat "$PROM")"
grep -q "fleet_seat_comeback_release_interval_breached{seat=\"commandcode__poolside_laguna-s-2.1-free.json\"} 1" "$PROM" \
  || fail "re-bench-fails: prom interval_breached per-seat series must name the seat: $(cat "$PROM")"
# The overdue metric must STAY 1 here — this is the one honest stuck case
# (wall cannot be advanced), and it is what keeps the alert loud instead
# of the sweep clearing the overdue count while the seat is unreachable.
stuck_overdue=$(overdue_n)
[[ "$stuck_overdue" == "1" ]] \
  || fail "re-bench-fails: overdue count must stay 1 (wall cannot be advanced), got $stuck_overdue"
ok "loud stall still fires when re-bench cannot advance the wall (read-only ledger); overdue stays 1"

# --- 4. override: wall-expired + recent probe -> probe anyway (unstick) --
# The fleet-ops#2421 follow-up (2026-08-31 straitly/gpt-5.6-sol): a probe
# failure (rc=124 timeout) leaves the wall clock stale (extension cannot
# re-anchor without a real HTTP response). The previous min-interval
# skip then blocked re-probing forever, firing LOUD every 15 min. With
# the wall clock already EXPIRED the seat is owed a comeback; the
# min-interval only throttles hammering of future-wall seats. A
# recently-probed seat whose wall is still expired MUST be re-probed so
# the wall can refresh (real response -> extension re-anchors) or the
# seat can be unwalled (probe succeeds).
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" << 'EOF'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":503,"retry_after":null,"health_class":"overload_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:52:47Z","source":"overload_bench","failure_mode":"overload_503","bench_until":"2026-08-30T10:02:47Z","usable_at":"2026-08-30T10:02:47Z","bench_window_s":600,"consecutive_failure_count":5}
EOF
STATE="$TMPD/state-override.json"
PROM="$TMPD/release-override.prom"
# 60s ago: within MIN_INTERVAL (900s). Wall is EXPIRED. Old code skipped;
# fixed code overrides and probes anyway.
jq -nc --argjson lp "{\"commandcode__poolside_laguna-s-2.1-free.json\": $((NOW_EPOCH - 60))}" \
  '{last_probe: $lp, probed_total: 0, released_total: 0}' > "$STATE"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/override.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "override: expected exit 0 (release on success), got $rc ($(cat "$TMPD/override.err"))"
grep -q "override min-interval for commandcode/poolside/laguna-s-2.1-free" "$TMPD/override.err" \
  || fail "override: must log the min-interval override line: $(cat "$TMPD/override.err")"
health=$(jq -r '.health_class' "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json")
[[ "$health" == "healthy" ]] || fail "override: seat must be unwalled (healthy), got $health"
released_total=$(jq -r '.released_total' "$STATE")
[[ "$released_total" == "1" ]] || fail "override: released_total must be 1, got $released_total"
grep -q "^fleet_seat_comeback_release_stalled 0$" "$PROM" \
  || fail "override: prom stalled must be 0: $(cat "$PROM")"
ok "override: wall-expired + recent probe -> probe anyway (unstick), release succeeds, exit 0"

# --- 5. future-wall seat: skipped via the wall-in-future check, regardless
#       of any last_probe history. This is the only remaining throttle; the
#       wall-in-future check precedes the probe and the seat is never owed
#       a comeback while its wall is still held.
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/opencode__nemotron-3-ultra-free.json" << 'EOF'
{"provider":"opencode","model":"nemotron-3-ultra-free","http_status":429,"retry_after":null,"health_class":"rate_limited","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T08:00:00Z","source":"after_provider_response","failure_mode":"rate_limit","usable_at":"2026-08-30T23:00:00.094Z","consecutive_failure_count":3}
EOF
STATE="$TMPD/state-future.json"
PROM="$TMPD/release-future.prom"
# Even with last_probe = 0 (never probed), a future-wall seat must not be
# probed at all — the wall-in-future check is silent and absolute.
jq -nc '{last_probe: {}, probed_total: 0, released_total: 0}' > "$STATE"
out=$(PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" --dry-run 2>&1)
grep -qi "nemotron" <<<"$out" \
  && fail "future-wall seat must never be probed: $out"
released_total=$(jq -r '.released_total' "$STATE")
[[ "$released_total" == "0" ]] || fail "future-wall seat must not increment released_total: $released_total"
ok "future-wall seat: skipped via wall-in-future check, no probe, no release"

# --- 6. overdue metric clears (fleet-ops#2520) -----------------------------
# The FleetSeatComebackOverdue alert keys on fleet_seat_comeback_overdue_total
# (exported from _read_comeback_overdue). A sweep that re-probes + unwalls
# (success) or advances the wall (re-bench on a probe failure with no real
# response, fleet-ops#2493) must leave the ledger with that count at 0 —
# otherwise a fixed sweep still leaves the alert stuck, which is exactly
# the sustained-overdue failure this issue names. Both paths are pinned
# end-to-end against the real exporter function on the SAME scratch ledger
# the sweep just operated on.

# 6a. probe SUCCEEDS: past-wall seat is overdue before, unwalled after.
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/straitly__gpt-5.6-sol.json" << 'EOF'
{"provider":"straitly","model":"gpt-5.6-sol","http_status":402,"retry_after":null,"health_class":"quota_exhausted","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:00:00.000Z","source":"provider_fetch","failure_mode":"quota_exhausted","usable_at":"2026-08-30T09:30:21.000Z","consecutive_failure_count":23}
EOF
STATE="$TMPD/state-overdue-ok.json"
PROM="$TMPD/release-overdue-ok.prom"
before=$(overdue_n)
[[ "$before" == "1" ]] || fail "overdue-clears: past-wall seat must count overdue BEFORE the sweep (got $before)"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/overdue-ok.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "overdue-clears: sweep must exit 0 on success path, got $rc ($(cat "$TMPD/overdue-ok.err"))"
health=$(jq -r '.health_class' "$SEATDIR/straitly__gpt-5.6-sol.json")
[[ "$health" == "healthy" ]] || fail "overdue-clears: seat must be unwalled (healthy), got $health"
after=$(overdue_n)
[[ "$after" == "0" ]] || fail "overdue-clears: _read_comeback_overdue must be 0 AFTER the sweep (unwall), got $after"
ok "overdue metric clears: past-wall seat probed + unwalled -> comeback-overdue count 0"

# 6b. probe FAILS with no real response (rc=124 timeout, the #2493 shape):
#     the wall cannot be re-anchored by the extension, so the sweep must
#     re-bench it into the future. The pre-#2505 bin left the wall in the
#     past after such a failure (next tick re-probes, re-fails, alert
#     sustains) — this assertion is the regression pin for that class.
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/straitly__gpt-5.6-sol.json" << 'EOF'
{"provider":"straitly","model":"gpt-5.6-sol","http_status":402,"retry_after":null,"health_class":"quota_exhausted","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:00:00.000Z","source":"provider_fetch","failure_mode":"quota_exhausted","usable_at":"2026-08-30T09:30:21.000Z","consecutive_failure_count":23}
EOF
STATE="$TMPD/state-overdue-rebench.json"
PROM="$TMPD/release-overdue-rebench.prom"
before=$(overdue_n)
[[ "$before" == "1" ]] || fail "overdue-rebench: past-wall seat must count overdue BEFORE the sweep (got $before)"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    FLEET_SEAT_COMEBACK_TIMEOUT_S=2 \
    PI_BIN="$TMPD/pi-timeout" \
    bash "$BIN" >/dev/null 2>"$TMPD/overdue-rebench.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "overdue-rebench: sweep must exit 0 (re-benched, not loud), got $rc ($(cat "$TMPD/overdue-rebench.err"))"
grep -q "REBENCHED straitly/gpt-5.6-sol" "$TMPD/overdue-rebench.err" \
  || fail "overdue-rebench: must log REBENCHED: $(cat "$TMPD/overdue-rebench.err")"
after=$(overdue_n)
[[ "$after" == "0" ]] || fail "overdue-rebench: _read_comeback_overdue must be 0 AFTER the sweep (wall advanced), got $after"
ok "overdue metric clears: probe failure re-benches the wall into the future -> comeback-overdue count 0 (fleet-ops#2520 regression pin)"

# --- 7. PONG-ok inline answer -> NOT released (fleet-ops#2661) ----------
# A partial 503 storm is PONG-compatible: a 1-token inline "OK" probe
# passes but tool-loading 503s. The tool-using probe must keep such a seat
# benched: an inline-only "OK" answer (no tool result, no computed token) does
# NOT release. This is the regression fixture the issue names: PONG-ok but
# tool-503 -> does NOT release. The probe fails -> re-bench (overload class
# preserved) + a 1st overload strike registered on that provider.
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" << 'EOF'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":503,"retry_after":null,"health_class":"overload_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:52:47Z","source":"overload_bench","failure_mode":"overload_503","bench_until":"2026-08-30T10:02:47Z","usable_at":"2026-08-30T10:02:47Z","bench_window_s":600,"consecutive_failure_count":5}
EOF
STATE="$TMPD/state-pong.json"
PROM="$TMPD/release-pong.prom"
LEARNED="$TMPD/learned-caps-pong.json"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-pong-ok" \
    LEARNED_CAPS_JSON="$LEARNED" \
    bash "$BIN" >/dev/null 2>"$TMPD/pong.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "pong-ok: expected exit 0 (re-benched, not loud), got $rc ($(cat "$TMPD/pong.err"))"
health=$(jq -r '.health_class' "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json")
[[ "$health" == "overload_bench" ]] || fail "pong-ok: seat must STAY benched (overload_bench), got $health"
grep -q "REBENCHED commandcode/poolside/laguna-s-2.1-free" "$TMPD/pong.err" \
  || fail "pong-ok: must log REBENCHED (re-bench on inline-only probe failure): $(cat "$TMPD/pong.err")"
released_total=$(jq -r '.released_total' "$STATE")
[[ "$released_total" == "0" ]] || fail "pong-ok: inline-only probe must NOT release (released_total must be 0, got $released_total)"
# The first overload strike is registered on that provider (the re-bench preserved the
# overload class;the strike counter is the escalation-to-provider-wall premiso).
strikes=$(jq -r '.overload_strikes.commandcode.count // 0' "$STATE")
[[ "$strikes" == "1" ]] || fail "pong-ok: inline-only probe failure must register 1 overload strike (got $strikes)"
grep -q "OVERLOAD WALL" "$TMPD/pong.err" && fail "pong-ok: 1 strike must NOT arm the wall yet: $(cat "$TMPD/pong.err")"
ok "PONG-ok inline answer -> seat stays benched (1 overload strike, no release)"

# --- 8. >=4 overload strikes within  2h -> exponential provider-wide wall (fleet-ops#2661) --
# A partial storm re-benches seats every bench window; 4 consecutive overload_503
# strikes within the  2h window arm an exponential provider-wide wall via the learned-caps
# mechanism (learned-caps.json providers.<p>.bench_until, the SAME primitive the
# rate_limit/quota classes use) — so the release path cannot keep unwalling walls
# straight back into the storm. A quota_exhausted seat's failures are NOT overload
# strikes (they must not arm the wall).
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" << 'EOF'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":503,"retry_after":null,"health_class":"overload_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:52:47Z","source":"overload_bench","failure_mode":"overload_503","bench_until":"2026-08-30T10:02:47Z","usable_at":"2026-08-30T10:02:47Z","bench_window_s":600,"consecutive_failure_count":5}
EOF
cat > "$SEATDIR/straitly__gpt-5.6-sol.json" << 'EOF'
{"provider":"straitly","model":"gpt-5.6-sol","http_status":402,"retry_after":null,"health_class":"quota_exhausted","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:00:00.000Z","source":"provider_fetch","failure_mode":"quota_exhausted","usable_at":"2026-08-30T09:30:21.000Z","consecutive_failure_count":23}
EOF
STATE="$TMPD/state-wall.json"
PROM="$TMPD/release-wall.prom"
LEARNED="$TMPD/learned-caps-wall.json"
printf '%s\n' '{"providers":{}}' > "$LEARNED"
# 4 sweeps, each 70s apart, a short rebench window (60s, so the wall
# expires between sweeps and every probe re-fails. At the 4th sweep the strike
# count hits 4 within the  2h window -> the exponential provider-wide wall arms.
 
for run in  1 2 3 4; do
  RUN_NOW=$(date -u -d "2026-08-30T12:00:00Z + $((run * 70)) seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$NOW_ISO")
  set +e
  PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
      FLEET_SEAT_COMEBACK_STATE="$STATE" \
      FLEET_SEAT_COMEBACK_PROM="$PROM" \
      FLEET_SEAT_COMEBACK_NOW="$RUN_NOW" \
      FLEET_SEAT_COMEBACK_REBENCH_BACKOFF_S=60 \
      PI_BIN="$TMPD/pi-fail" \
      LEARNED_CAPS_JSON="$LEARNED" \
      bash "$BIN" >/dev/null 2>"$TMPD/wall.err.$run"
  rc=$?
  set -e
  [[ "$rc" == "0" ]] || fail "overload-wall run $run: expected exit 0 (re-benched, not loud), got $rc"
done
# 4 strikes on commandcode within the window (first_at=+70s, last=+280s:
#210s apart <7200s) ->the wall armed. straitly's quota failures are not overload
# strikes -> no wall for it.
strikes=$(jq -r '.overload_strikes.commandcode.count //  0' "$STATE")
[[ "$strikes" == "4" ]] || fail "overload-wall: commandcode must rack 4 overload strikes, got $strikes"
walls_total=$(jq -r '.walls_total // 0' "$STATE")
[[ "$walls_total" == "1" ]] || fail "overload-wall: walls_total must be 1, got $walls_total"
jq -e '.providers.commandcode.bench_until != null and .providers.commandcode.learned_cap == 1' "$LEARNED" >/dev/null \
  || fail "overload-wall: provider-wide wall must land in learned-caps.json for commandcode: $(cat "$LEARNED")"
jq -e '.providers.straitly == null' "$LEARNED" >/dev/null \
  || fail "overload-wall: quota failures must NOT arm a provider wall (straitly should not appear): $(cat "$LEARNED")"
grep -q "OVERLOAD WALL commandcode" "$TMPD/wall.err.4" \
  || fail "overload-wall:the 4th sweep must log OVERLOAD WALL: $(cat "$TMPD/wall.err.4")"
ok "4 overload strikes within  2h -> exponential provider-wide wall via learned-caps.bench_until"

# --- 9. fleet-ops#2638: force probe on overdue usable_at (unstick) -------
# The lived 2026-09-01T09:45Z heartbeat case: a seat had usable_at past but
# bench_until was held by a recent re-bench (the prober's own re-bench
# write). The prober was skipping it because wall_end_of prefers bench_until;
# the re-bench loop held the seat indefinitely. The fix: track usable_at
# SEPARATELY from bench_until; an overdue usable_at forces a real probe
# even when bench_until is held. Same cadence as a normal re-bench cycle
# (a probe every bench window) — but the probe ACTUALLY FIRES instead of
# being silently skipped. A successful probe unwalls; a failed probe
# re-benches again.
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" << 'EOF'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":503,"retry_after":null,"health_class":"overload_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:52:47Z","source":"comeback_release_rebench","failure_mode":"overload_503","bench_until":"2026-08-30T13:00:00Z","usable_at":"2026-08-30T10:00:00Z","bench_window_s":900,"consecutive_failure_count":15}
EOF
STATE="$TMPD/state-force-util.json"
PROM="$TMPD/release-force-util.prom"
out=$(PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" --dry-run 2>&1)
grep -q "force probe commandcode/poolside/laguna-s-2.1-free" <<<"$out" \
  || fail "force-util: must log the force-probe line: $out"
grep -q "usable_at 2026-08-30T10:00:00Z past, bench_until 2026-08-30T13:00:00Z held by re-bench" <<<"$out" \
  || fail "force-util: must name both clocks and the held bench_until: $out"
grep -q "would probe commandcode/poolside/laguna-s-2.1-free" <<<"$out" \
  || fail "force-util: must actually probe (dry-run): $out"
ok "force probe: usable_at past + bench_until held -> prober fires anyway (fleet-ops#2638)"

# --- 9b. force probe succeeds: overdue usable_at seat unwalled ----------
# Live run with the same fixture: the prober should fire and unwall.
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" << 'EOF'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":503,"retry_after":null,"health_class":"overload_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:52:47Z","source":"comeback_release_rebench","failure_mode":"overload_503","bench_until":"2026-08-30T13:00:00Z","usable_at":"2026-08-30T10:00:00Z","bench_window_s":900,"consecutive_failure_count":15}
EOF
STATE="$TMPD/state-force-ok.json"
PROM="$TMPD/release-force-ok.prom"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/force-ok.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "force-util-ok: expected exit 0 (released), got $rc ($(cat "$TMPD/force-ok.err"))"
grep -q "force probe commandcode/poolside/laguna-s-2.1-free" "$TMPD/force-ok.err" \
  || fail "force-util-ok: must log the force-probe line: $(cat "$TMPD/force-ok.err")"
health=$(jq -r '.health_class' "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json")
[[ "$health" == "healthy" ]] || fail "force-util-ok: seat must be unwalled (healthy), got $health"
released_total=$(jq -r '.released_total' "$STATE")
[[ "$released_total" == "1" ]] || fail "force-util-ok: released_total must be 1, got $released_total"
ok "force probe succeeds: overdue usable_at seat unwalled, released_total=1 (fleet-ops#2638)"

# --- 10. fleet-ops#2638: corpse at SEAT_DEAD_CONSECUTIVE_THRESHOLD -------
# The lived mimo-42x-429s and poolside-23x-503s case: probes fail,
# consecutive_failure_count climbs past the threshold, but the prober
# never wrote seat_dead=true — the seat kept re-benching forever. The
# fix: after re-bench, if the count has crossed the threshold, write
# seat_dead=true with cleared wall clocks (fleet-ops#2415 convention).
# seat_usable already holds seat_dead=true terminally (fleet-ops#2327),
# so the next sweep skips the seat entirely. Test pins the boundary: a
# seat at count=24 + a failed probe -> count becomes 25 -> corpse.
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" << 'EOF'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":503,"retry_after":null,"health_class":"overload_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:52:47Z","source":"overload_bench","failure_mode":"overload_503","bench_until":"2026-08-30T10:02:47Z","usable_at":"2026-08-30T10:02:47Z","bench_window_s":600,"consecutive_failure_count":24}
EOF
STATE="$TMPD/state-corpse.json"
PROM="$TMPD/release-corpse.prom"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-fail" \
    bash "$BIN" >/dev/null 2>"$TMPD/corpse.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "corpse: expected exit 0 (corpsed, not loud), got $rc ($(cat "$TMPD/corpse.err"))"
grep -q "REBENCHED commandcode/poolside/laguna-s-2.1-free" "$TMPD/corpse.err" \
  || fail "corpse: must log REBENCHED first (the failed probe re-benches): $(cat "$TMPD/corpse.err")"
grep -q "CORPSED commandcode/poolside/laguna-s-2.1-free" "$TMPD/corpse.err" \
  || fail "corpse: must log CORPSED after the re-bench crosses threshold: $(cat "$TMPD/corpse.err")"
# Ledger: seat_dead=true, health_class=corpse, wall clocks cleared,
# source=comeback_release_corpse, count=25 (one above the start of 24).
jq -e '.seat_dead == true and .health_class == "corpse" and .bench_until == null and .usable_at == null and .source == "comeback_release_corpse" and .failure_mode == "comeback_never_released" and .consecutive_failure_count == 25' \
  "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" >/dev/null \
  || fail "corpse: ledger must be seat_dead=true, wall cleared, count=25: $(cat "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json")"
# fleet-ops#3156: a PROBER-created no-wall corpse (failure_mode
# comeback_never_released, wall null) is NOT terminal-skipped. It gets ONE
# second-chance re-probe: with the healthy probe stub the corpse RE-PROBES
# and, on success, UNWALLS (transitions OUT of corpse). It must not be
# re-corpsed (already a corpse) and must not stay stuck.
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/corpse-followup.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "corpse follow-up: expected exit 0, got $rc"
grep -q "corpse re-probe commandcode/poolside/laguna-s-2.1-free: no wall, second-chance re-probe" "$TMPD/corpse-followup.err" \
  || fail "corpse follow-up: no-wall corpse must be re-probed (fleet-ops#3156): $(cat "$TMPD/corpse-followup.err")"
grep -q "UNWALLED commandcode/poolside/laguna-s-2.1-free" "$TMPD/corpse-followup.err" \
  || fail "corpse follow-up: healthy re-probe must unwall the corpse: $(cat "$TMPD/corpse-followup.err")"
# The seat transitioned OUT of corpse: healthy, seat_dead false, streak 0.
jq -e '.seat_dead == false and .health_class == "healthy" and .failure_mode == "none" and .consecutive_failure_count == 0' \
  "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" >/dev/null \
  || fail "corpse follow-up: seat must transition OUT of corpse (healthy, seat_dead=false): $(cat "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json")"
# corpse_total stays 1 (the first pass wrote the corpse; the #3156
# transition-out is not a second corpse write).
corpse_total=$(jq -r '.corpse_total // 0' "$STATE")
[[ "$corpse_total" == "1" ]] || fail "corpse: corpse_total must stay 1, got $corpse_total"
grep -q "^fleet_seat_comeback_release_corpse_total 1$" "$PROM" \
  || fail "corpse: prom corpse_total must be 1: $(cat "$PROM")"
ok "corpse at threshold: c=24 + failed probe -> c=25 corpse write; second-chance re-probe unwalls it OUT of corpse (fleet-ops#2638/#3156)"

# --- 11. fleet-ops#2638: corpse does NOT fire below threshold ------------
# Pin the boundary: a seat at count=23 + failed probe -> count becomes 24
# (< 25) -> re-bench only, NO corpse. Mirrors fleet-ops#2594's corpse-
# boundary contract: only at or above threshold does seat_dead=true land.
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" << 'EOF'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":503,"retry_after":null,"health_class":"overload_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:52:47Z","source":"overload_bench","failure_mode":"overload_503","bench_until":"2026-08-30T10:02:47Z","usable_at":"2026-08-30T10:02:47Z","bench_window_s":600,"consecutive_failure_count":23}
EOF
STATE="$TMPD/state-no-corpse.json"
PROM="$TMPD/release-no-corpse.prom"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-fail" \
    bash "$BIN" >/dev/null 2>"$TMPD/no-corpse.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "no-corpse: expected exit 0 (re-benched, not loud), got $rc ($(cat "$TMPD/no-corpse.err"))"
grep -q "REBENCHED" "$TMPD/no-corpse.err" \
  || fail "no-corpse: must log REBENCHED: $(cat "$TMPD/no-corpse.err")"
grep -q "CORPSED" "$TMPD/no-corpse.err" \
  && fail "no-corpse: must NOT log CORPSED (below threshold): $(cat "$TMPD/no-corpse.err")"
health=$(jq -r '.health_class' "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json")
[[ "$health" == "overload_bench" ]] || fail "no-corpse: seat must STAY overload_bench (not corpse), got $health"
dead=$(jq -r '.seat_dead' "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json")
[[ "$dead" == "false" ]] || fail "no-corpse: seat_dead must stay false (below threshold), got $dead"
count=$(jq -r '.consecutive_failure_count' "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json")
[[ "$count" == "24" ]] || fail "no-corpse: count must be 24 (one above 23), got $count"
ok "no corpse below threshold: c=23 + failed probe -> c=24 re-bench only, NO corpse (fleet-ops#2638)"

# --- 12. fleet-ops#2638: never-released metric over a scratch ledger ----
# The metric-exporter's _read_never_released identifies seats the prober
# has been failing on (consecutive_failure_count in [10, 25)) that are
# NOT corpses yet. Pin the shape against the real exporter function on
# the SAME scratch ledger the bin operates on — same pattern as test 6
# (fleet-ops#2520) which pins the comeback-overdue count clear path.
# A scratch ledger with three seats verifies the boundaries:
#   - count=5  (below 10): NOT never-released (fresh single failure).
#   - count=15 (in [10,25)): IS never-released (the lived poolside case).
#   - count=24 (in [10,25)): IS never-released (the lived mimo case).
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" << 'EOF'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":503,"retry_after":null,"health_class":"overload_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:52:47Z","source":"overload_bench","failure_mode":"overload_503","bench_until":"2026-08-30T10:02:47Z","usable_at":"2026-08-30T10:02:47Z","consecutive_failure_count":15}
EOF
cat > "$SEATDIR/opencode__mimo-v2.5-free.json" << 'EOF'
{"provider":"opencode","model":"mimo-v-2.5-free","http_status":429,"retry_after":null,"health_class":"rate_limited","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:00:00Z","source":"provider_fetch","failure_mode":"rate_limit","usable_at":"2026-08-30T09:30:21.000Z","consecutive_failure_count":24}
EOF
cat > "$SEATDIR/cline__z-ai_glm-5.3-flash.json" << 'EOF'
{"provider":"cline","model":"z-ai/glm-5.3-flash","http_status":200,"retry_after":null,"health_class":"healthy","retryable":false,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T11:00:00Z","source":"after_provider_response","failure_mode":"none","consecutive_failure_count":0}
EOF
# never_released_n() over $SEATDIR (mirrors tests 6's overdue_n()).
never_released_n() {
    python3 - "$repo_root/libexec/fleet-metrics-export.py" "$SEATDIR" <<'PY'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("fme", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.SEAT_LEDGER = Path(sys.argv[2])
nr_n, _ = m._read_never_released()
print(nr_n)
PY
}
nr=$(never_released_n)
[[ "$nr" == "2" ]] \
  || fail "never-released: must count 2 stuck seats (poolside c=15, mimo c=24; healthy glm excluded), got $nr"
ok "never-released metric: 2 stuck seats counted (poolside+mimo), healthy seat excluded (fleet-ops#2638)"

# --- 13. corpse-ledger retirement (fleet-ops#2716) ------------------------
# The terminal step of the seat lifecycle this organ owns: a corpse
# (seat_dead=true, health_class=corpse) ledger must not sit in the live
# roster forever — seat-caps.json retiring the slug (cap 0 +
# intentional_cap_zero=corpse, fleet-ops#2708) stops the rotation but the
# ledger file keeps counting as roster membership in the census
# (daily-digest 'Total seen', opus-heartbeat-gather seat_table n). The
# corpse is physically moved into lanes/seats-corpse-retired-<UTC-ts>/
# once its observed_at ages past CORPSE_GRACE_S (default 6h). A fresh
# corpse (inside grace) and a corpse that still carries a future wall
# clock are held.
#
# Fixed NOW for this section (independent of the sweep sections above) so
# the dated retirement dir is a clean scratch name.
NOW2_ISO="2026-08-30T13:00:00Z"
RETSEAT="$TMPD/seats13"
RETDIR="$TMPD/seats-corpse-retired-$NOW2_ISO"

# 13a. grace hold: a fresh corpse (1h old, inside the 6h grace window)
#      must NOT be retired — the recovery window is still open.
rm -rf "$RETSEAT"; mkdir -p "$RETSEAT"; rm -rf "$RETDIR"
cat > "$RETSEAT/devin__glm-5-2.json" << 'EOF'
{"provider":"devin","model":"glm-5-2","http_status":503,"retry_after":null,"health_class":"corpse","retryable":true,"seat_dead":true,"poison_ladder":false,"observed_at":"2026-08-30T12:00:00Z","source":"after_provider_response","failure_mode":"transient_http","usable_at":null,"consecutive_failure_count":150}
EOF
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$RETSEAT" \
    FLEET_SEAT_COMEBACK_STATE="$TMPD/state13a.json" \
    FLEET_SEAT_COMEBACK_PROM="$TMPD/prom13a.prom" \
    FLEET_SEAT_COMEBACK_NOW="$NOW2_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/ret13a.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "13a: grace-hold sweep must exit 0, got $rc ($(cat "$TMPD/ret13a.err"))"
[[ -f "$RETSEAT/devin__glm-5-2.json" ]] \
  || fail "13a: fresh corpse (age 1h < grace 6h) must NOT be retired: $(cat "$TMPD/ret13a.err")"
[[ ! -d "$RETDIR" ]] || fail "13a: no retirement dir may be created while the corpse is inside grace: $(ls -la "$TMPD" 2>&1)"
grep -q "RETIRED" "$TMPD/ret13a.err" \
  && fail "13a: fresh corpse must not be retired: $(cat "$TMPD/ret13a.err")"
ok "13a: fresh corpse inside the 6h grace window is held (recovery window still open)"

# 13b. grace override + retirement: the same 1h-old corpse with
#      FLEET_SEAT_COMEBACK_CORPSE_GRACE_S=3600 is past grace -> retired.
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$RETSEAT" \
    FLEET_SEAT_COMEBACK_STATE="$TMPD/state13b.json" \
    FLEET_SEAT_COMEBACK_PROM="$TMPD/prom13b.prom" \
    FLEET_SEAT_COMEBACK_NOW="$NOW2_ISO" \
    FLEET_SEAT_COMEBACK_CORPSE_GRACE_S=3600 \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/ret13b.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "13b: retirement sweep must exit 0, got $rc ($(cat "$TMPD/ret13b.err"))"
[[ ! -e "$RETSEAT/devin__glm-5-2.json" ]] \
  || fail "13b: corpse past grace must be moved out of the live roster: $(ls "$RETSEAT")"
[[ -f "$RETDIR/devin__glm-5-2.json" ]] \
  || fail "13b: corpse ledger must land in seats-corpse-retired-<ts>/: $(ls -la "$TMPD" 2>&1)"
grep -q "^fleet_seat_comeback_release_retired_total 1$" "$TMPD/prom13b.prom" \
  || fail "13b: prom retired_total must be 1: $(cat "$TMPD/prom13b.prom")"
# Idempotence: a second sweep with the ledger already empty must not
# re-retire (no file to move) and must keep retired_total=1.
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$RETSEAT" \
    FLEET_SEAT_COMEBACK_STATE="$TMPD/state13b.json" \
    FLEET_SEAT_COMEBACK_PROM="$TMPD/prom13b.prom" \
    FLEET_SEAT_COMEBACK_NOW="$NOW2_ISO" \
    FLEET_SEAT_COMEBACK_CORPSE_GRACE_S=3600 \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/ret13b2.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "13b idem: re-run on an empty ledger must exit 0, got $rc ($(cat "$TMPD/ret13b2.err"))"
grep -q "^fleet_seat_comeback_release_retired_total 1$" "$TMPD/prom13b.prom" \
  || fail "13b idem: retired_total must stay 1 across re-runs: $(cat "$TMPD/prom13b.prom")"
retired_total=$(jq -r '.retired_total' "$TMPD/state13b.json")
[[ "$retired_total" == "1" ]] || fail "13b idem: state retired_total must stay 1, got $retired_total"
ok "13b: corpse past grace (env override 3600s) retired out of the roster; re-run idempotent"

# 13c. defensive hold: an OLD corpse that still carries a FUTURE wall clock
#      is held (a clock means a comeback is still owed — fleet-ops#2394 shape).
rm -rf "$RETSEAT"; mkdir -p "$RETSEAT"; rm -rf "$RETDIR"
cat > "$RETSEAT/opencode__mimo-v2.5-free.json" << 'EOF'
{"provider":"opencode","model":"mimo-v2.5-free","http_status":429,"retry_after":null,"health_class":"corpse","retryable":true,"seat_dead":true,"poison_ladder":false,"observed_at":"2026-08-29T01:00:00Z","source":"after_provider_response","failure_mode":"rate_limit","usable_at":null,"bench_until":"2026-08-30T14:00:00Z","consecutive_failure_count":150}
EOF
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$RETSEAT" \
    FLEET_SEAT_COMEBACK_STATE="$TMPD/state13c.json" \
    FLEET_SEAT_COMEBACK_PROM="$TMPD/prom13c.prom" \
    FLEET_SEAT_COMEBACK_NOW="$NOW2_ISO" \
    FLEET_SEAT_COMEBACK_CORPSE_GRACE_S=3600 \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/ret13c.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "13c: future-clock-corpse sweep must exit 0, got $rc ($(cat "$TMPD/ret13c.err"))"
[[ -f "$RETSEAT/opencode__mimo-v2.5-free.json" ]] \
  || fail "13c: corpse with a future wall clock must NOT be retired: $(cat "$TMPD/ret13c.err")"
[[ ! -d "$RETDIR" ]] || fail "13c: no retirement dir may be created for a held corpse: $(ls -la "$TMPD" 2>&1)"
grep -q "RETIRED" "$TMPD/ret13c.err" \
  && fail "13c: future-clock corpse must not be retired: $(cat "$TMPD/ret13c.err")"
ok "13c: old corpse still carrying a future wall clock is held (comeback still owed)"

# 13d. clean sweep: a roster with no corpses retires nothing (retired_total
#      stays 0), creates no retirement dir, exit 0.
rm -rf "$RETSEAT"; mkdir -p "$RETSEAT"; rm -rf "$RETDIR"
cat > "$RETSEAT/bai__deepseek-v4-flash.json" << 'EOF'
{"provider":"bai","model":"deepseek-v4-flash","http_status":200,"retry_after":null,"health_class":"healthy","retryable":false,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T12:30:00Z","source":"after_provider_response","failure_mode":"none","usable_at":null,"consecutive_failure_count":0}
EOF
cat > "$RETSEAT/opencode__nemotron-3-ultra-free.json" << 'EOF'
{"provider":"opencode","model":"nemotron-3-ultra-free","http_status":429,"retry_after":null,"health_class":"rate_limited","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T08:00:00Z","source":"provider_fetch","failure_mode":"rate_limit","usable_at":"2026-08-30T23:00:00Z","consecutive_failure_count":3}
EOF
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$RETSEAT" \
    FLEET_SEAT_COMEBACK_STATE="$TMPD/state13d.json" \
    FLEET_SEAT_COMEBACK_PROM="$TMPD/prom13d.prom" \
    FLEET_SEAT_COMEBACK_NOW="$NOW2_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/ret13d.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "13d: clean sweep must exit 0, got $rc ($(cat "$TMPD/ret13d.err"))"
[[ ! -d "$RETDIR" ]] || fail "13d: clean roster must create no retirement dir: $(ls -la "$TMPD" 2>&1)"
grep -q "^fleet_seat_comeback_release_retired_total 0$" "$TMPD/prom13d.prom" \
  || fail "13d: prom retired_total must be 0 on a clean roster: $(cat "$TMPD/prom13d.prom")"
ok "13d: clean roster (healthy + rate_limited) retires nothing, creates no dir (fleet-ops#2716)"

# --- 14. fleet-ops#2806: corpse on the merged own-failure streak -------
# The lived nemotron/mimo shape: the seat-health extension re-anchors the
# wall into the future on each release-probe failure (skip re-bench), and
# its own consecutive_failure_count only increments on real responses at
# its own cadence (15->17 across 8h of 15-min probes) — so the pre-#2806
# corpse path, gated on the LEDGER count after a probe, never fired in a
# useful window. The organ now keeps its own per-seat failure streak in
# the state file (own_failures), seeded from the ledger count at first
# sighting and advanced on EVERY probe failure, and corpses on the MERGED
# streak (max of ledger count and own streak). Here the ledger count is a
# low 5 (the extension never counted most failures) while the own streak
# sits at 24 — one more failed probe crosses the threshold -> corpse.
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" << 'EOF'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":503,"retry_after":null,"health_class":"overload_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:52:47Z","source":"overload_bench","failure_mode":"overload_503","bench_until":"2026-08-30T10:02:47Z","usable_at":"2026-08-30T10:02:47Z","bench_window_s":600,"consecutive_failure_count":5}
EOF
STATE="$TMPD/state-own-streak.json"
PROM="$TMPD/release-own-streak.prom"
# Own streak pre-seeded at 24 (extension count sat at 5 — the gap the
# merged-streak fix closes). One failed probe -> 25 -> corpse.
jq -nc '{"last_probe":{}, "probed_total": 0, "released_total": 0, "own_failures": {"commandcode__poolside_laguna-s-2.1-free.json": 24}}' > "$STATE"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-fail" \
    bash "$BIN" >/dev/null 2>"$TMPD/own-streak.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "own-streak corpse: expected exit 0 (corpsed, not loud), got $rc ($(cat "$TMPD/own-streak.err"))"
grep -q "REBENCHED commandcode/poolside/laguna-s-2.1-free" "$TMPD/own-streak.err" \
  || fail "own-streak corpse: must log REBENCHED (failed probe re-benches): $(cat "$TMPD/own-streak.err")"
grep -q "CORPSED commandcode/poolside/laguna-s-2.1-free" "$TMPD/own-streak.err" \
  || fail "own-streak corpse: must log CORPSED on the merged streak: $(cat "$TMPD/own-streak.err")"
# Corpse write carries the MERGED streak count (25 = own 24 + this failure):
# seat_dead=true, class corpse, wall clocks cleared, source comeback_release_corpse.
jq -e '.seat_dead == true and .health_class == "corpse" and .bench_until == null and .usable_at == null and .source == "comeback_release_corpse" and .consecutive_failure_count == 25' \
  "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" >/dev/null \
  || fail "own-streak corpse: ledger must be seat_dead=true, wall cleared, count=25: $(cat "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json")"
# fleet-ops#3156: the prober-created no-wall corpse gets ONE second-chance
# re-probe — with the healthy stub it transitions OUT of corpse (unwalled).
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/own-streak-followup.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "own-streak corpse follow-up: expected exit 0, got $rc"
grep -q "UNWALLED commandcode/poolside/laguna-s-2.1-free" "$TMPD/own-streak-followup.err" \
  || fail "own-streak corpse follow-up: no-wall corpse must be re-probed and unwalled (fleet-ops#3156): $(cat "$TMPD/own-streak-followup.err")"
jq -e '.seat_dead == false and .health_class == "healthy"' \
  "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" >/dev/null \
  || fail "own-streak corpse follow-up: seat must transition OUT of corpse: $(cat "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json")"
corpse_total=$(jq -r '.corpse_total // 0' "$STATE")
[[ "$corpse_total" == "1" ]] || fail "own-streak corpse: corpse_total must be 1, got $corpse_total"
ok "corpse on merged own-failure streak: own=24 + failed probe -> 25 corpse; #3156 re-probe unwalls it out of corpse (fleet-ops#2806/#3156)"

# --- 15. fleet-ops#2806: no interval-breach false positive in-cadence ----
# A seat whose usable_at passed less than one probe interval ago (500s <
# 900s) is mid-cycle: the sweep probes it (the wall is past), the probe
# fails, and the re-bench advances the wall into the future. The breach
# gauge must stay 0 (the releaser IS operating — a past-by-<interval wall
# at sweep start is its normal job), exit 0, no LOUD line.
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" << EOF
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":503,"retry_after":null,"health_class":"overload_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:52:47Z","source":"overload_bench","failure_mode":"overload_503","bench_until":"$(date -u -d '2026-08-30T12:00:00Z - 500 seconds' +%Y-%m-%dT%H:%M:%SZ)","usable_at":"$(date -u -d '2026-08-30T12:00:00Z - 500 seconds' +%Y-%m-%dT%H:%M:%SZ)","bench_window_s":600,"consecutive_failure_count":5}
EOF
STATE="$TMPD/state-in-cadence.json"
PROM="$TMPD/release-in-cadence.prom"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-fail" \
    bash "$BIN" >/dev/null 2>"$TMPD/in-cadence.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "in-cadence: expected exit 0 (re-benched, not loud), got $rc ($(cat "$TMPD/in-cadence.err"))"
grep -q "REBENCHED commandcode/poolside/laguna-s-2.1-free" "$TMPD/in-cadence.err" \
  || fail "in-cadence: must log REBENCHED (failed probe re-benches the mid-cycle wall): $(cat "$TMPD/in-cadence.err")"
grep -q "INTERVAL-BREACH" "$TMPD/in-cadence.err" \
  && fail "in-cadence: past-by-<interval wall must NOT breach: $(cat "$TMPD/in-cadence.err")"
grep -q "^fleet_seat_comeback_release_interval_breached_total 0$" "$PROM" \
  || fail "in-cadence: prom interval_breached_total must be 0: $(cat "$PROM")"
grep -q "^fleet_seat_comeback_release_stalled 0$" "$PROM" \
  || fail "in-cadence: prom stalled must be 0 (re-benched): $(cat "$PROM")"
new_usable=$(jq -r '.usable_at' "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json")
new_usable_epoch=$(date -u -d "$new_usable" +%s 2>/dev/null || echo 0)
(( new_usable_epoch > NOW_EPOCH )) || fail "in-cadence: wall must be advanced into the future, got $new_usable"
ok "in-cadence: past-by-<interval wall probed + re-benched, breach gauge 0, exit 0 (fleet-ops#2806)"

# --- 16. fleet-ops#2806: own-failure streak resets on a healthy interlude --
# The streak must NOT persist across a recovery: a seat that is observed
# healthy (real worker passed it, or the extension re-wrote it healthy)
# breaks the consecutive-failure streak even though the release organ did
# not probe it this sweep. Without the reset, a seat that recovered and
# then re-walled would carry its old streak forward and corpse too fast.
# State holds own_failures=24; the ledger is HEALTHY -> sweep clears the
# streak (state own_failures=0) and takes no other action, exit 0.
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" << 'EOF'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":200,"health_class":"healthy","retryable":false,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T11:55:00Z","source":"after_provider_response","failure_mode":"none","usable_at":null,"consecutive_failure_count":0}
EOF
STATE="$TMPD/state-streak-reset.json"
PROM="$TMPD/release-streak-reset.prom"
jq -nc '{"last_probe":{}, "probed_total": 0, "released_total": 0, "own_failures": {"commandcode__poolside_laguna-s-2.1-free.json": 24}}' > "$STATE"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/streak-reset.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "streak-reset: expected exit 0, got $rc ($(cat "$TMPD/streak-reset.err"))"
grep -qi "poolside" "$TMPD/streak-reset.err" \
  && fail "streak-reset: healthy seat must not be probed or mentioned: $(cat "$TMPD/streak-reset.err")"
own_failures=$(jq -r '.own_failures["commandcode__poolside_laguna-s-2.1-free.json"] // 0' "$STATE")
[[ "$own_failures" == "0" ]] \
  || fail "streak-reset: own_failures must reset to 0 on a healthy observation, got $own_failures: $(cat "$STATE")"
grep -q "^fleet_seat_comeback_release_interval_breached_total 0$" "$PROM" \
  || fail "streak-reset: prom interval_breached_total must be 0: $(cat "$PROM")"
ok "own-failure streak resets on a healthy interlude; no probe, no breach (fleet-ops#2806)"

# --- 17. fleet-ops#3156: no-wall corpse comeback-release paths ------------
# The lived seats_dead stuck case (opencode/mimo-v2.5-free c=25,
# straitly/deepseek-v4-pro c=43): the prober corpsed the seat
# (failure_mode=comeback_never_released, wall clocks null) but inside its
# 6h grace NOTHING releases or retires it — the corpse sits as seats_dead
# for the full grace window with no probe ever fired. The fix: a
# no-wall prober corpse gets ONE second-chance re-probe — success unwalls
# it (transition OUT of corpse, covered by the follow-up asserts above),
# failure RETIRES it immediately (grace bypass). Other corpse sources
# inside grace stay held (recovery window still open, no re-probe).

# 17a. failed second-chance re-probe -> explicit immediate retirement.
#      A fresh prober no-wall corpse (age 1h < 6h grace) with a FAILING
#      probe must be retired at once (no 6h wait), retired_total=1.
rm -rf "$TMPD/seats17" "$TMPD/seats-corpse-retired-$NOW_ISO"
mkdir -p "$TMPD/seats17"
cat > "$TMPD/seats17/opencode__mimo-v2.5-free.json" << 'EOF'
{"provider":"opencode","model":"mimo-v2.5-free","http_status":null,"retry_after":null,"health_class":"corpse","retryable":false,"seat_dead":true,"poison_ladder":false,"observed_at":"2026-08-30T11:00:00Z","source":"comeback_release_corpse","failure_mode":"comeback_never_released","usable_at":null,"bench_until":null,"consecutive_failure_count":25,"corpse_threshold":25}
EOF
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$TMPD/seats17" \
    FLEET_SEAT_COMEBACK_STATE="$TMPD/state17a.json" \
    FLEET_SEAT_COMEBACK_PROM="$TMPD/prom17a.prom" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-fail" \
    bash "$BIN" >/dev/null 2>"$TMPD/ret17a.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "17a: failed re-probe retirement sweep must exit 0, got $rc ($(cat "$TMPD/ret17a.err"))"
grep -q "corpse re-probe opencode/mimo-v2.5-free: no wall, second-chance re-probe" "$TMPD/ret17a.err" \
  || fail "17a: no-wall corpse must be re-probed (fleet-ops#3156): $(cat "$TMPD/ret17a.err")"
grep -q "explicitly retired opencode/mimo-v2.5-free after failed no-wall corpse re-probe" "$TMPD/ret17a.err" \
  || fail "17a: failed re-probe must explicitly retire the corpse: $(cat "$TMPD/ret17a.err")"
[[ ! -e "$TMPD/seats17/opencode__mimo-v2.5-free.json" ]] \
  || fail "17a: corpse must leave the live roster on failed re-probe: $(ls "$TMPD/seats17")"
[[ -f "$TMPD/seats-corpse-retired-$NOW_ISO/opencode__mimo-v2.5-free.json" ]] \
  || fail "17a: retired corpse must land in the dated retirement dir: $(ls -la "$TMPD/seats-corpse-retired-$NOW_ISO" 2>&1)"
grep -q "^fleet_seat_comeback_release_retired_total 1$" "$TMPD/prom17a.prom" \
  || fail "17a: prom retired_total must be 1 (grace bypass): $(cat "$TMPD/prom17a.prom")"
ok "17a: failed second-chance re-probe retires the no-wall corpse immediately (grace bypass, fleet-ops#3156)"

# 17b. guard: a no-wall corpse from ANOTHER source (after_provider_response,
#      transient_http — the test-13a shape) inside grace is NOT re-probed
#      even with a healthy probe stub; it is held (recovery window open).
rm -rf "$TMPD/seats17"
mkdir -p "$TMPD/seats17"
cat > "$TMPD/seats17/devin__glm-5-2.json" << 'EOF'
{"provider":"devin","model":"glm-5-2","http_status":503,"retry_after":null,"health_class":"corpse","retryable":true,"seat_dead":true,"poison_ladder":false,"observed_at":"2026-08-30T11:00:00Z","source":"after_provider_response","failure_mode":"transient_http","usable_at":null,"consecutive_failure_count":150}
EOF
rm -rf "$TMPD/seats-corpse-retired-$NOW_ISO"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$TMPD/seats17" \
    FLEET_SEAT_COMEBACK_STATE="$TMPD/state17b.json" \
    FLEET_SEAT_COMEBACK_PROM="$TMPD/prom17b.prom" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/ret17b.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "17b: guard-hold sweep must exit 0, got $rc ($(cat "$TMPD/ret17b.err"))"
[[ -f "$TMPD/seats17/devin__glm-5-2.json" ]] \
  || fail "17b: non-prober no-wall corpse must be held, not retired: $(cat "$TMPD/ret17b.err")"
grep -q "re-probe" "$TMPD/ret17b.err" \
  && fail "17b: non-prober corpse must NOT be re-probed: $(cat "$TMPD/ret17b.err")"
grep -qi "devin/glm-5-2" "$TMPD/ret17b.err" \
  && fail "17b: non-prober corpse must not be mentioned at all (held silently): $(cat "$TMPD/ret17b.err")"
ok "17b: non-prober no-wall corpse inside grace is held, never re-probed (source guard, fleet-ops#3156)"

# 17c. non-dead seat with NO wall clock (bench_until and usable_at null) is
#      no longer silently skipped (the removed pre-#3156 defensive hold):
#      it is re-probed and, on success, unwalled. Proves the non-dead
#      no-wall class cannot sit stuck forever either.
rm -rf "$TMPD/seats17"
mkdir -p "$TMPD/seats17"
cat > "$TMPD/seats17/straitly__deepseek-v4-pro.json" << 'EOF'
{"provider":"straitly","model":"deepseek-v4-pro","http_status":null,"retry_after":null,"health_class":"rate_limited","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T11:55:00Z","source":"provider_fetch","failure_mode":"rate_limit","usable_at":null,"bench_until":null,"consecutive_failure_count":3}
EOF
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$TMPD/seats17" \
    FLEET_SEAT_COMEBACK_STATE="$TMPD/state17c.json" \
    FLEET_SEAT_COMEBACK_PROM="$TMPD/prom17c.prom" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/ret17c.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "17c: no-wall non-dead sweep must exit 0, got $rc ($(cat "$TMPD/ret17c.err"))"
grep -q "UNWALLED straitly/deepseek-v4-pro" "$TMPD/ret17c.err" \
  || fail "17c: no-wall non-dead seat must be re-probed and unwalled (fleet-ops#3156): $(cat "$TMPD/ret17c.err")"
jq -e '.seat_dead == false and .health_class == "healthy"' \
  "$TMPD/seats17/straitly__deepseek-v4-pro.json" >/dev/null \
  || fail "17c: seat must land healthy after the no-wall re-probe: $(cat "$TMPD/seats17/straitly__deepseek-v4-pro.json")"
grep -q "^fleet_seat_comeback_release_released_total 1$" "$TMPD/prom17c.prom" \
  || fail "17c: prom released_total must be 1: $(cat "$TMPD/prom17c.prom")"
ok "17c: non-dead no-wall seat re-probed and released, not silently stuck (fleet-ops#3156)"

# --- 18. fleet-ops#3176: PQE 1h==1h deadlock — comeback-release must NOT ---
#      re-anchor a quota_exhausted seat whose observed_at is still inside the
#      PROVIDER_QUOTA_WINDOW_S (3600s) window. The live straitly/gpt-5.6-sol
#      + deepseek-v4-pro + qwen3.8-max burn: a 402 with no Retry-After got
#      daily_quota_s=3600 (== the PQE window), comeback-release probed at the
#      1h mark, the fresh 402 re-anchored observed_at=now, and the 1h window
#      never emptied so FleetProviderQuotaExhausted fired forever. The fix:
#      (a) seat-health.ts now defaults quota_exhausted to
#      free_balance_exhausted_s=86400 (strictly longer than 3600s); (b)
#      comeback-release skips probing a quota_exhausted seat whose observed_at
#      is inside the window; (c) comeback-release does NOT corpse a 402 by
#      count (quota_exhausted is time-based, not count-based). This test pins
#      all three on a scratch ledger with the exporter's PQE helper.
# -------------------------------------------------------------------------
# PQE count over $SEATDIR evaluated at a FIXED now (the exporter's
# _read_provider_quota_exhausted uses time.time(); pin it so the test is
# stable regardless of when it runs). Mirrors the overdue_n() helper.
pqe_n() {
    local seatdir="$1" now_epoch="$2"
    python3 - "$repo_root/libexec/fleet-metrics-export.py" "$seatdir" "$now_epoch" <<'PY'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("fme", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.SEAT_LEDGER = Path(sys.argv[2])
m.time.time = lambda: int(sys.argv[3])
n, _ = m._read_provider_quota_exhausted()
print(n)
PY
}

# 18a. Two 402s inside the 1h PQE window, expired usable_at. Comeback tick
#      must SKIP them (PQE gate), leave the ledger UNTOUCHED (observed_at not
#      re-anchored), and NOT probe. PQE total stays 1 (in window) right after
#      the tick — the point is the tick did not re-anchor, so observed_at can
#      still age out.
rm -rf "$TMPD/seats18"
mkdir -p "$TMPD/seats18"
# observed_at 5 min ago (inside 1h window), usable_at 5 min ago (expired wall
# — would normally be probed). count=24 so a count-based corpse would fire at
# 25 if the probe ran and failed (the 3176 guard must prevent both).
cat > "$TMPD/seats18/straitly__gpt-5.6-sol.json" << 'EOF'
{"provider":"straitly","model":"gpt-5.6-sol","http_status":402,"retry_after":null,"health_class":"quota_exhausted","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T11:55:00Z","source":"provider_fetch","failure_mode":"quota_exhausted","usable_at":"2026-08-30T11:55:00Z","consecutive_failure_count":24}
EOF
cat > "$TMPD/seats18/straitly__deepseek_deepseek-v4-pro.json" << 'EOF'
{"provider":"straitly","model":"deepseek/deepseek-v4-pro","http_status":402,"retry_after":null,"health_class":"quota_exhausted","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T11:55:00Z","source":"provider_fetch","failure_mode":"quota_exhausted","usable_at":"2026-08-30T11:55:00Z","consecutive_failure_count":23}
EOF
# Pin the pre-tick PQE total: 2 straitly seats inside the window -> 1 provider.
pre_pqe=$(pqe_n "$TMPD/seats18" "$NOW_EPOCH")
[[ "$pre_pqe" == "1" ]] \
  || fail "18a: pre-tick PQE total must be 1 (2 straitly seats in window), got $pre_pqe"
# Snapshot observed_at BEFORE the tick to prove it is not re-anchored.
obs_before=$(jq -r '.observed_at' "$TMPD/seats18/straitly__gpt-5.6-sol.json")
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$TMPD/seats18" \
    FLEET_SEAT_COMEBACK_STATE="$TMPD/state18a.json" \
    FLEET_SEAT_COMEBACK_PROM="$TMPD/prom18a.prom" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-fail" \
    bash "$BIN" >/dev/null 2>"$TMPD/ret18a.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "18a: PQE-window skip sweep must exit 0, got $rc ($(cat "$TMPD/ret18a.err"))"
# The skip log must name both seats and the PQE window hold.
grep -q "skip probe straitly/gpt-5.6-sol: quota_exhausted observed_at still inside the 3600s PQE window" "$TMPD/ret18a.err" \
  || fail "18a: must log PQE-window skip for gpt-5.6-sol: $(cat "$TMPD/ret18a.err")"
grep -q "skip probe straitly/deepseek/deepseek-v4-pro: quota_exhausted observed_at still inside the 3600s PQE window" "$TMPD/ret18a.err" \
  || fail "18a: must log PQE-window skip for deepseek-v4-pro: $(cat "$TMPD/ret18a.err")"
# No probe, no re-bench, no corpse.
grep -qi "REBENCHED" "$TMPD/ret18a.err" && fail "18a: must NOT re-bench a PQE-window-held seat: $(cat "$TMPD/ret18a.err")"
grep -qi "CORPSED" "$TMPD/ret18a.err" && fail "18a: must NOT corpse a PQE-window-held seat: $(cat "$TMPD/ret18a.err")"
# Ledger UNTOUCHED — observed_at not re-anchored (the deadlock root cause).
obs_after=$(jq -r '.observed_at' "$TMPD/seats18/straitly__gpt-5.6-sol.json")
[[ "$obs_after" == "$obs_before" ]] \
  || fail "18a: observed_at must NOT be re-anchored by the skip (was $obs_before, now $obs_after)"
# count unchanged (no probe, no re-bench increment).
count_after=$(jq -r '.consecutive_failure_count' "$TMPD/seats18/straitly__gpt-5.6-sol.json")
[[ "$count_after" == "24" ]] \
  || fail "18a: count must stay 24 (no probe), got $count_after"
# PQE total right after the tick is still 1 (observed_at unchanged, still in
# window) — the tick did NOT make it worse. The win is observed_at can age out.
post_pqe=$(pqe_n "$TMPD/seats18" "$NOW_EPOCH")
[[ "$post_pqe" == "1" ]] \
  || fail "18a: post-tick PQE total must stay 1 (no re-anchor), got $post_pqe"
ok "18a: PQE-window-held 402s are skipped (no probe, no re-bench, no corpse, observed_at not re-anchored) — the 1h window can age out (fleet-ops#3176)"

# 18b. Advance past the PQE window (now+2h). observed_at is now 2h05m old
#      (outside 3600s). PQE total must be 0 — observed_at aged out because the
#      18a tick did not re-anchor it. This is the closure: without the fix the
#      tick would have re-anchored and PQE would still be 1 here.
NOW_PLUS_2H_ISO="2026-08-30T14:00:00Z"
NOW_PLUS_2H_EPOCH=$(date -u -d "$NOW_PLUS_2H_ISO" +%s)
aged_pqe=$(pqe_n "$TMPD/seats18" "$NOW_PLUS_2H_EPOCH")
[[ "$aged_pqe" == "0" ]] \
  || fail "18b: PQE total must be 0 after observed_at ages out (no re-anchor), got $aged_pqe"
ok "18b: PQE total drops to 0 once observed_at ages out — the 1h==1h deadlock is broken (fleet-ops#3176)"

# 18c. After the window ages out, the next comeback tick DOES probe (the gate
#      releases). A failed probe re-benches but does NOT corpse a 402 by count
#      (quota_exhausted is time-based, not count-based — the live
#      straitly/gpt-5.6-sol was CORPSED at count=38 by the prober's count-based
#      corpse path even though its observed_at was only ~1h old). Pin both: the
#      probe fires, re-benches, count climbs to 25, but seat_dead stays false.
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$TMPD/seats18" \
    FLEET_SEAT_COMEBACK_STATE="$TMPD/state18c.json" \
    FLEET_SEAT_COMEBACK_PROM="$TMPD/prom18c.prom" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_PLUS_2H_ISO" \
    PI_BIN="$TMPD/pi-fail" \
    bash "$BIN" >/dev/null 2>"$TMPD/ret18c.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "18c: post-window probe sweep must exit 0, got $rc ($(cat "$TMPD/ret18c.err"))"
# The PQE-window skip must NOT fire now (observed_at is outside the window).
grep -q "skip probe straitly/gpt-5.6-sol: quota_exhausted observed_at still inside" "$TMPD/ret18c.err" \
  && fail "18c: must NOT skip a seat whose observed_at is outside the PQE window: $(cat "$TMPD/ret18c.err")"
# The probe fired and re-benched (the wall was expired, the gate released).
grep -q "REBENCHED straitly/gpt-5.6-sol" "$TMPD/ret18c.err" \
  || fail "18c: must re-bench gpt-5.6-sol after the probe fails (gate released): $(cat "$TMPD/ret18c.err")"
# CRITICAL: the 402 must NOT be corpseed by count even though count crosses 25.
grep -q "skip corpse straitly/gpt-5.6-sol: quota_exhausted is time-based" "$TMPD/ret18c.err" \
  || fail "18c: must log skip-corpse for quota_exhausted (time-based, not count-based): $(cat "$TMPD/ret18c.err")"
grep -q "CORPSED straitly/gpt-5.6-sol" "$TMPD/ret18c.err" \
  && fail "18c: must NOT corpse a 402 by count (quota_exhausted is time-based): $(cat "$TMPD/ret18c.err")"
dead=$(jq -r '.seat_dead' "$TMPD/seats18/straitly__gpt-5.6-sol.json")
[[ "$dead" == "false" ]] \
  || fail "18c: seat_dead must stay false for a 402 corpseed-by-count guard, got $dead"
# rebench_seat clobbers quota_exhausted to transient_fault (it only preserves
# overload_bench); the corpse guard uses the PRE-rebench class to decide. The
# ledger post-rebench carries transient_fault (the prober's re-bench class),
# NOT corpse — the time-based corpse fires in seat-health.ts on a real 402
# response at observed_at age >= 24h, not here.
hc=$(jq -r '.health_class' "$TMPD/seats18/straitly__gpt-5.6-sol.json")
[[ "$hc" == "transient_fault" ]] \
  || fail "18c: health_class must be transient_fault (re-bench clobber, not corpse), got $hc"
# count climbed to 25 (the re-bench incremented it) but no corpse.
count=$(jq -r '.consecutive_failure_count' "$TMPD/seats18/straitly__gpt-5.6-sol.json")
[[ "$count" == "25" ]] \
  || fail "18c: count must climb to 25 (re-bench increment), got $count"
ok "18c: post-window probe fires + re-benches, but 402 NOT corpseed by count (time-based, not count-based) — fleet-ops#3176"

# 18d. seat-health.ts backoff pin: a no-Retry-After 402 must default to
#      free_balance_exhausted_s=86400 (strictly longer than the 3600s PQE
#      window), not daily_quota_s=3600. A provider Retry-After still wins.
#      This is the out-of-repo extension; skip if not installed (mirrors the
#      seat-health-quarantine / seat-health-seat-dead CI safety pattern).
EXT_PATH="${FLEET_SEAT_HEALTH_TS:-$HOME/.pi/agent/extensions/seat-health.ts}"
if [[ -f "$EXT_PATH" ]] && command -v node >/dev/null 2>&1; then
    node_major=$(node -e 'console.log(Number.parseInt(process.versions.node.split(".")[0], 10))')
    node_minor=$(node -e 'console.log(Number.parseInt(process.versions.node.split(".")[1], 10))')
    if [[ "$node_major" -ge 22 ]] || { [[ "$node_major" -eq 22 ]] && [[ "$node_minor" -ge 6 ]]; }; then
        backoff_out=$(node --experimental-strip-types --no-warnings=ExperimentalWarning \
            --input-type=module -e "
import { computeUsableAt } from ${EXT_PATH@Q};
const now = Date.now();
const u = computeUsableAt('quota_exhausted', null, now, 0);
const s = u === null ? null : Math.round((Date.parse(u) - now) / 1000);
console.log('BACKOFF:' + s);
" 2>&1 | tail -1)
        [[ "$backoff_out" == BACKOFF:* ]] || fail "18d: node did not emit BACKOFF line (got $backoff_out)"
        backoff="${backoff_out#BACKOFF:}"
        [[ "$backoff" == "86400" ]] \
          || fail "18d: quota_exhausted no-Retry-After backoff must be 86400 (free_balance_exhausted_s, strictly > 3600s PQE window), got $backoff"
        # A provider Retry-After of 3600 still wins (max(base, retry)).
        retry_out=$(node --experimental-strip-types --no-warnings=ExperimentalWarning \
            --input-type=module -e "
import { computeUsableAt } from ${EXT_PATH@Q};
const now = Date.now();
const u = computeUsableAt('quota_exhausted', 3600, now, 0);
const s = u === null ? null : Math.round((Date.parse(u) - now) / 1000);
console.log('RETRY:' + s);
" 2>&1 | tail -1)
        [[ "$retry_out" == RETRY:* ]] || fail "18d: node did not emit RETRY line (got $retry_out)"
        retry="${retry_out#RETRY:}"
        [[ "$retry" == "3600" ]] \
          || fail "18d: quota_exhausted Retry-After=3600 must be honoured (3600), got $retry"
        ok "18d: seat-health.ts quota_exhausted default backoff=86400 (strictly > 3600s PQE window); provider Retry-After=3600 still wins (fleet-ops#3176)"
    else
        ok "18d: SKIP seat-health.ts backoff pin (node < 22.6 for --experimental-strip-types) (fleet-ops#3176)"
    fi
else
    ok "18d: SKIP seat-health.ts backoff pin (extension not installed at $EXT_PATH) (fleet-ops#3176)"
fi

echo "ALL OK: active come-back release path (fleet-ops#2421) + force-probe-on-overdue-usable_at + corpse-at-threshold + never-released metric (fleet-ops#2638) + own-streak corpse + interval-breach loud check (fleet-ops#2806) + no-wall corpse second-chance re-probe / explicit retire (fleet-ops#3156) + PQE 1h==1h deadlock fix (fleet-ops#3176)"