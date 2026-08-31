#!/usr/bin/env bash
# tests/fleet-seat-comeback-release.test.sh
#
# fleet-ops#2421: the ACTIVE release path for walled seats. A seat whose
# wall clock (bench_until ?? usable_at) has passed is re-probed through the
# real router (pi --print "Reply with exactly: OK"); on a successful probe
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
#
# Sandbox: scratch SEATS_DIR/state/prom + stub pi only. No live ledger,
# no live pi, no systemd.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
BIN="$repo_root/bin/fleet-seat-comeback-release"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

command -v jq >/dev/null 2>&1 || fail "jq missing"

# Fixed NOW so the test is stable regardless of when it runs.
NOW_ISO="2026-08-30T12:00:00Z"
NOW_EPOCH=$(date -u -d "$NOW_ISO" +%s)

TMPD="$(mktemp -d -t seat-comeback-release.XXXXXX)"
SEATDIR="$TMPD/seats"
mkdir -p "$SEATDIR"
cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT INT TERM

# --- stub pi: SUCCESS stub exits 0 with "OK", FAILURE stub exits 1 -------
cat > "$TMPD/pi-ok" <<'EOF'
#!/usr/bin/env bash
printf 'OK\n'
exit 0
EOF
cat > "$TMPD/pi-fail" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TMPD/pi-ok" "$TMPD/pi-fail"

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
    PI_BIN="$TMPD/pi-ok" \
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
    PI_BIN="$TMPD/pi-ok" \
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
jq -e '.source == "comeback_release_rebench" and .failure_mode == "comeback_rebench" and .health_class == "transient_fault" and .consecutive_failure_count == 6' \
  "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" >/dev/null \
  || fail "re-bench: ledger must carry source=comeback_release_rebench, count incremented: $(cat "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json")"
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
    PI_BIN="$TMPD/pi-ok" \
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
ok "loud stall still fires when re-bench cannot advance the wall (read-only ledger)"

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
    PI_BIN="$TMPD/pi-ok" \
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
    PI_BIN="$TMPD/pi-ok" \
    bash "$BIN" --dry-run 2>&1)
grep -qi "nemotron" <<<"$out" \
  && fail "future-wall seat must never be probed: $out"
released_total=$(jq -r '.released_total' "$STATE")
[[ "$released_total" == "0" ]] || fail "future-wall seat must not increment released_total: $released_total"
ok "future-wall seat: skipped via wall-in-future check, no probe, no release"

echo "ALL OK: active come-back release path (fleet-ops#2421)"