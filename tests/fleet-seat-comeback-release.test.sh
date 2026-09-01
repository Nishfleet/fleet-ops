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
#     fixtures, .spawn-bench pseudo-seats, corpses and future-wall seats
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
grep -qi "devin/glm-5-2" <<<"$out" && fail "dry-run: corpse must never be probed: $out"
grep -qi "nemotron" <<<"$out" && fail "dry-run: future-wall seat must never be probed: $out"
grep -qi "bai/deepseek" <<<"$out" && fail "dry-run: healthy seat must never be probed: $out"
# Dry-run must not touch the ledger, state or prom.
[[ ! -e "$STATE" ]] || fail "dry-run must not write state"
[[ ! -e "$PROM" ]] || fail "dry-run must not write prom"
grep -q '"health_class":"overload_bench"' "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" \
  || fail "dry-run must not modify the ledger"
ok "dry-run selects only owed expired-wall seats; test__/spawn-bench/corpse/future/healthy never probed"

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
ok "successful probes release (unwall) both expired seats; green prom, exit 0"

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
# Corpse is terminal: a follow-up sweep must skip it (no re-probe, no
# re-corpsed log, no corpse_total advance).
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/corpse-followup.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "corpse follow-up: expected exit 0 (skipped), got $rc"
grep -q "CORPSED" "$TMPD/corpse-followup.err" && fail "corpse follow-up: must NOT re-corpsed (terminal): $(cat "$TMPD/corpse-followup.err")"
grep -qi "poolside" "$TMPD/corpse-followup.err" && fail "corpse follow-up: must not mention poolside at all (terminal skip): $(cat "$TMPD/corpse-followup.err")"
# corpse_total + never-released metric cleared (the corpse is no longer
# stuck — it's terminal).
corpse_total=$(jq -r '.corpse_total // 0' "$STATE")
[[ "$corpse_total" == "1" ]] || fail "corpse: corpse_total must be 1, got $corpse_total"
grep -q "^fleet_seat_comeback_release_corpse_total 1$" "$PROM" \
  || fail "corpse: prom corpse_total must be 1: $(cat "$PROM")"
ok "corpse at threshold: c=24 + failed probe -> c=25 corpse write, terminal skip on next sweep (fleet-ops#2638)"

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

echo "ALL OK: active come-back release path (fleet-ops#2421) + force-probe-on-overdue-usable_at + corpse-at-threshold + never-released metric (fleet-ops#2638)"