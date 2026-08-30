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
#   - min-interval: a seat probed within MIN_INTERVAL_S is not re-probed.
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

# --- 3. loud stall: probes FAIL and nothing re-anchors --------------------
# Fresh scratch fixture set: the two expired seats only (run 2 unwalled
# them; the stall math only needs the expired population).
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
[[ "$rc" == "1" ]] || fail "failed probes with no re-anchor: expected exit 1 (loud), got $rc ($(cat "$TMPD/live-fail.err"))"
grep -q "LOUD \[COMEBACK-RELEASE-STALLED\]" "$TMPD/live-fail.err" \
  || fail "stall must render the LOUD line: $(cat "$TMPD/live-fail.err")"
grep -q "^fleet_seat_comeback_release_stalled 1$" "$PROM" \
  || fail "prom stalled must be 1: $(cat "$PROM")"
grep -qE "^fleet_seat_comeback_release_walled_expired 2$" "$PROM" \
  || fail "prom walled_expired must be 2: $(cat "$PROM")"
grep -qE "^fleet_seat_comeback_release_last_green_seconds [0-9]+$" "$PROM" \
  && fail "stalled sweep must NOT write last-green: $(cat "$PROM")"
ok "loud stall: expired walls + zero releases -> exit 1, stalled=1, no last-green"

# --- 4. min-interval: a recently-probed seat is not re-probed -------------
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" << 'EOF'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":503,"retry_after":null,"health_class":"overload_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:52:47Z","source":"overload_bench","failure_mode":"overload_503","bench_until":"2026-08-30T10:02:47Z","usable_at":"2026-08-30T10:02:47Z","bench_window_s":600,"consecutive_failure_count":5}
EOF
STATE="$TMPD/state-interval.json"
PROM="$TMPD/release-interval.prom"
jq -nc --argjson lp "{\"commandcode__poolside_laguna-s-2.1-free.json\": $((NOW_EPOCH - 60))}" \
  '{last_probe: $lp, probed_total: 0, released_total: 0}' > "$STATE"
out=$(PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-ok" \
    bash "$BIN" --dry-run 2>&1)
grep -q "would probe commandcode/poolside" <<<"$out" \
  && fail "seat probed within min interval must be skipped: $out"
grep -q "within min interval" <<<"$out" \
  || fail "skipped seat must log the min-interval skip: $out"
ok "min-interval: a seat probed 60s ago is not re-probed"

echo "ALL OK: active come-back release path (fleet-ops#2421)"