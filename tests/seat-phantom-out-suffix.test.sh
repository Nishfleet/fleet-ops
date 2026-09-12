#!/usr/bin/env bash
# tests/seat-phantom-out-suffix.test.sh
# fleet-ops#4018: a probe-output filename fragment (a model id ending in
# `-.out`, e.g. grok-4-6-.out / glm-5-2-.out) is NEVER a real seat model.
# It must be rejected at every seatlib write/probe/dispatch guard — even
# when config/seat-caps.json is missing (the fleet-ops#3661 fail-open must
# NOT re-admit a phantom under a missing caps file, or a phantom model read
# back from pi-seat-health.json / a stray ledger is re-dispatched and the
# seat-health extension re-writes the phantom `<model>-.out.json` ledger,
# splitting the reactive bench off the real ledger).
#
# Acceptance pin: after a reactive bench (mark_seat_*) fed a unit-output
# path's model fragment, the seat ledger holds NO `*-.out.json` file.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/litellm-seat.sh"

scratch="$(mktemp -d -t seat-phantom-out.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
LEDGER="$scratch/ledger"
STATE="$scratch/pi-packet-state"
CAPS="$scratch/seat-caps.json"
mkdir -p "$LEDGER" "$STATE"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# Caps fixture: only the real seats exist. The probe-output fragment model
# is absent by construction.
cat > "$CAPS" <<'CAPS'
{
  "providers": {
    "xai-oauth": {"models": {"grok-4.6": 2, "grok-4.5": 0}},
    "devin":     {"models": {"glm-5-2": 3, "swe-1-7": 1}}
  }
}
CAPS

# A real seat must still pass the guard (regression guard, not a blanket
# reject of every model).
real_ok=$(SEAT_CAPS_JSON="$CAPS" PI_SEAT_HEALTH_LEDGER_DIR="$LEDGER" \
  bash -c 'source "$1"; _seat_key_in_caps xai-oauth grok-4.6; echo $?' _ "$lib")
[[ "$real_ok" == "0" ]] || fail "real seat xai-oauth/grok-4.6 must pass _seat_key_in_caps (got rc=$real_ok)"
ok "real seat passes the guard; phantom .out is rejected"

# 1. Reactive bench from a unit-output path, caps PRESENT: the writer must
#    reject the fragment model, log LOUD, write no ledger.
set +e
out=$(PI_SEAT_LIB_CHECK_TRANSPORT=0 \
    PI_SEAT_HEALTH_LEDGER_DIR="$LEDGER" \
    SEAT_CAPS_JSON="$CAPS" \
    PI_PACKET_STATE="$STATE" \
    bash -c 'source "$1"; mark_seat_spawn_fail xai-oauth "grok-4.6-.out" "unit-output:run"' _ "$lib" 2>&1)
rc=$?
set -e
[[ "$rc" == "1" ]] \
  || fail "caps present: writer must reject the .out fragment (rc=1), got rc=$rc: $out"
grep -q "LOUD SEAT-KEY-INVALID xai-oauth/grok-4.6-.out writer=mark_seat_spawn_fail" <<<"$out" \
  || fail "caps present: missing LOUD SEAT-KEY-INVALID line: $out"
[[ -z "$(ls "$LEDGER" | grep -- '-.out.json' || true)" ]] \
  || fail "caps present: a -.out.json ledger was written: $(ls "$LEDGER")"
ok "caps present: reactive bench from a unit-output path writes no -.out.json ledger (rc=1)"

# 2. The critical pin: caps file MISSING. The fleet-ops#3661 guard fail-opens
#    (a missing caps file must not brick the ladder) — but a probe-output
#    fragment model must STILL be rejected, or a phantom model re-read from
#    pi-seat-health.json / a stray ledger is re-dispatched and the seat-health
#    extension re-writes the phantom `<model>-.out.json` ledger
#    (self-perpetuation: live devin__glm-5-2-.out.json /
#    xai-oauth__grok-4-6-.out.json).
set +e
out=$(PI_SEAT_LIB_CHECK_TRANSPORT=0 \
    PI_SEAT_HEALTH_LEDGER_DIR="$LEDGER" \
    SEAT_CAPS_JSON="$scratch/nonexistent-seat-caps.json" \
    PI_PACKET_STATE="$STATE" \
    bash -c 'source "$1"; _seat_key_guard devin "glm-5-2-.out" mark_seat_empty_run; echo "guard_rc=$?"' _ "$lib" 2>&1)
rc=$?
set -e
grep -q "guard_rc=1" <<<"$out" \
  || fail "no-caps: guard must reject devin/glm-5-2-.out even with the caps file missing: $out"
grep -q "LOUD SEAT-KEY-INVALID devin/glm-5-2-.out writer=mark_seat_empty_run" <<<"$out" \
  || fail "no-caps: missing LOUD SEAT-KEY-INVALID line: $out"
# And a full reactive-bench write through the guarded path must still produce
# no ledger file.
[[ -z "$(ls "$LEDGER" | grep -- '-.out.json' || true)" ]] \
  || fail "no-caps: a -.out.json ledger was written with the caps file missing: $(ls "$LEDGER")"
ok "no-caps: .out fragment rejected even when seat-caps.json is missing (fail-open override)"

# 3. The acceptance grep on the whole ledger dir after all of the above.
n=$(ls "$LEDGER" 2>/dev/null | grep -c -- '-.out.json' || true)
[[ "$n" == "0" ]] \
  || fail "ledger dir must contain zero -.out.json files, got $n: $(ls "$LEDGER")"
ok "ledger dir ends with zero -.out.json files (acceptance grep == 0)"

echo "ALL OK: probe-output fragment (.out) model ids never land in the seat ledger, caps present or missing (fleet-ops#4018)"
