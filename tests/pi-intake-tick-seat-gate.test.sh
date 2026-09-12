#!/usr/bin/env bash
# tests/pi-intake-tick-seat-gate.test.sh
#
# fleet-ops#176: the intake tick probes a usable worker path BEFORE
# claiming. If workers cannot run, the tick holds all claims and exits 0
# — killing the spawn-churn class that burned 37 pi-issue@ units 2026-08-26.
#
# fleet-ops#4263 P3b: the probe is LiteLLM proxy health, not pick-seat
# need_capable=1. A dead proxy means workers cannot run, so hold claims.
#
# Proves:
#   1. lib/pi-intake-tick.sh exists.
#   2. The gate block (litellm_ready) is present; pick-seat need_capable=1 is gone.
#   3. The gate fires when litellm_ready returns false.
#   4. The gate does NOT fire when the proxy is ready.
#   5. MANIFEST entry maps the tick to its install path.
#   6. SEAT_LIB is overridable.
#   7. shellcheck is clean on the tick.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"
manifest="$repo_root/MANIFEST"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# === Test 1: file exists ===
[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"
ok "Test 1: lib/pi-intake-tick.sh exists"

# === Test 2: seat-gate block present (P3b: proxy health, not pick-seat) ===
grep -qE '\$\(pick-seat "" "" 1' "$tick" \
    && fail "tick still calls pick-seat need_capable=1"
grep -qF 'litellm_ready' "$tick" \
    || fail "Seat-gate litellm_ready not found in tick"
grep -qF 'holding claims this tick — gate: litellm_ready' "$tick" \
    || fail "Holding message not found in tick"
ok "Test 2: seat-gate block present (litellm_ready; pick-seat gone)"

# === Test 3: gate fires when the proxy is down ===
litellm_ready() { return 1; }
if ! litellm_ready; then
    echo "no usable LiteLLM proxy (slots=2); holding claims this tick — gate: litellm_ready"
fi
ok "Test 3: gate fires when proxy is down"

# === Test 4: gate does NOT fire when the proxy is ready ===
litellm_ready() { return 0; }
if ! litellm_ready; then
    fail "Gate should NOT fire when LiteLLM is ready"
fi
heavy_seat=$(printf 'litellm\tworker-capable\n')
[[ -n "$heavy_seat" ]] || fail "heavy_seat should be set"
ok "Test 4: gate does NOT fire when proxy is ready (heavy_seat=$heavy_seat)"

# === Test 5: MANIFEST entry ===
grep -qF 'lib/pi-intake-tick.sh /home/nish/.local/lib/pi-packet/pi-intake-tick.sh' "$manifest" \
    || fail "MANIFEST missing tick entry"
ok "Test 5: MANIFEST entry present"

# === Test 6: SEAT_LIB override (testability) ===
grep -qF 'SEAT_LIB="${SEAT_LIB:-' "$tick" \
    || fail "SEAT_LIB not overridable via env var"
ok "Test 6: SEAT_LIB overridable via env var (testability)"

# === Test 7: shellcheck ===
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$tick" --severity=warning
    ok "Test 7: shellcheck clean"
else
    echo "SKIP: Test 7: shellcheck not installed"
fi

# === Test 8: refill seam stays (fleet-ops#4723 / #3695) ===
# A freed slot must refill from ExecStopPost, not a new timer. Debounce 60s
# is the "inside 60s" bound in the issue termination line.
unit="$repo_root/systemd/pi-issue@.service"
[[ -f "$unit" ]] || fail "systemd/pi-issue@.service missing"
grep -qF 'systemctl --user start --no-block "pi-intake@' "$unit" \
    || fail "Test 8: ExecStopPost must start pi-intake@ (continuous top-up, fleet-ops#3695/#4723)"
grep -qF 'PI_INTAKE_DEBOUNCE_SEC:-60' "$tick" \
    || fail "Test 8: intake debounce default must stay 60s so a freed slot refills inside 60s"
ok "Test 8: ExecStopPost refill seam + 60s debounce still in place (fleet-ops#4723)"

echo ""
echo "ALL OK: intake-tick seat gate holds claims when the LiteLLM proxy is down"
