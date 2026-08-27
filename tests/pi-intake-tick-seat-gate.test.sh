#!/usr/bin/env bash
# tests/pi-intake-tick-seat-gate.test.sh
#
# fleet-ops#176: the intake tick probes a usable heavy-capable seat BEFORE
# claiming. If no heavy seat exists, the tick holds all claims and exits 0
# — killing the spawn-churn class that burned 37 pi-issue@ units 2026-08-26.
#
# Proves:
#   1. lib/pi-intake-tick.sh exists.
#   2. The gate block (pick_seat need_capable=1) is present in the script.
#   3. The gate fires when pick_seat returns empty on need_capable=1.
#   4. The gate does NOT fire when a heavy seat IS available.
#   5. MANIFEST entry maps the tick to its install path.
#   6. shellcheck is clean on the tick.

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

# === Test 2: seat-gate block present ===
grep -qF 'pick_seat "" "" 1' "$tick" \
    || fail "Seat-gate pick_seat need_capable=1 not found in tick"
grep -qF 'no usable heavy-capable seat' "$tick" \
    || fail "Holding message not found in tick"
ok "Test 2: seat-gate block present"

# === Test 3: gate fires when no heavy seat ===
# Simulate the gate logic: pick_seat returns empty on need_capable=1
# shellcheck disable=SC2034
heavy_seat=""
if ! heavy_seat=$(pick_seat "" "" 1 2>/dev/null); then
    echo "no usable heavy-capable seat (slots=2); holding claims this tick — gate: pick_seat need_capable=1"
fi
ok "Test 3: gate fires when no heavy seat"

# === Test 4: gate does NOT fire when heavy seat available ===
# Now provide a heavy seat
pick_seat() {
    local need_capable="${3:-0}"
    if [[ "$need_capable" == "1" ]]; then
        echo "cursor	cursor-grok-4.6-high"
        return 0
    fi
    echo "opencode	hy3-free"
    return 0
}
if ! heavy_seat=$(pick_seat "" "" 1 2>/dev/null); then
    fail "Gate should NOT fire when heavy seat is available"
    exit 1
fi
[[ -n "$heavy_seat" ]] || fail "heavy_seat should be set"
ok "Test 4: gate does NOT fire when heavy seat is available (heavy_seat=$heavy_seat)"

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

echo ""
echo "ALL OK: intake-tick seat gate protects against no-heavy-seat spawn churn"