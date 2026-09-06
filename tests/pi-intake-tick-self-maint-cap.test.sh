#!/usr/bin/env bash
# tests/pi-intake-tick-self-maint-cap.test.sh
#
# fleet-ops#3254 (part 1/4): the deterministic intake tick
# (lib/pi-intake-tick.sh) caps SELF-maintenance (fleet-ops) claims at
# SELF_MAINT_CLAIM_PCT of this tick's available slots (floor 1) per tick,
# so a giant fleet-ops agent-ready backlog cannot flood the fleet while
# product (0509) work waits. Product repos are never capped. A
# critical-path (or escalate-senior) issue is exempt from the cap and
# claims even past the budget.
#
# This also retires the gap-audit yield rule (fleet-ops#180): the
# ordering organs that made product yield to fleet-ops gap-audit work
# (pi-intake-priority, fleet-gap-closure-yield/order) are not referenced
# by the live deterministic tick; the cap itself is the self-limiting
# control-plane budget so fleet-ops can no longer outrun product.
#
# Static-grep + shell arithmetic drill (same shape as the umbrella /
# escalate-senior exclusion tests): pins the cap mechanism without a live
# systemd/gh environment.
#
# Proves:
#   1. A SELF_MAINT_CLAIM_PCT knob (default 20) overridable via env.
#   2. A CRITICAL_PATH_LABEL seam (default critical-path) for exemption.
#   3. The cap is computed as floor(slots * pct / 100) with a floor of 1.
#   4. The tick skips non-exempt fleet-ops issues once claims >= cap.
#   5. Exempt (critical-path) issues claim even past the cap.
#   6. The counter increments only on real non-exempt claims.
#   7. Product repos (0509) are not capped.
#   8. shellcheck is clean on the tick.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"

# === Test 1: SELF_MAINT_CLAIM_PCT knob present and overridable ===
grep -qF 'SELF_MAINT_CLAIM_PCT="${PI_INTAKE_SELF_MAINT_CLAIM_PCT:-20}"' "$tick" \
    || fail "SELF_MAINT_CLAIM_PCT knob (default 20) not found in tick"
ok "Test 1: SELF_MAINT_CLAIM_PCT knob present (default 20)"

# === Test 2: CRITICAL_PATH_LABEL seam present and overridable ===
grep -qF 'CRITICAL_PATH_LABEL="${PI_INTAKE_CRITICAL_PATH_LABEL:-critical-path}"' "$tick" \
    || fail "CRITICAL_PATH_LABEL seam not found in tick"
ok "Test 2: CRITICAL_PATH_LABEL seam present (default critical-path)"

# === Test 3: cap = floor(slots * pct / 100) with floor 1 ===
# Reproduce the exact expression the tick uses and prove floor-1 rounding.
cap_for() {
    local slots="$1" pct="$2"
    local c=$(( slots * pct / 100 ))
    (( c < 1 )) && c=1
    printf '%s\n' "$c"
}
grep -qF '_self_maint_cap=$(( slots * SELF_MAINT_CLAIM_PCT / 100 ))' "$tick" \
    || fail "cap expression (slots * SELF_MAINT_CLAIM_PCT / 100) not found in tick"
grep -qF '(( _self_maint_cap < 1 )) && _self_maint_cap=1' "$tick" \
    || fail "floor-1 guard not found in tick"
# slots=20, pct=20 -> 4 (20% of 20)
[[ "$(cap_for 20 20)" == "4" ]] || fail "20% of 20 should be 4, got $(cap_for 20 20)"
# slots=4, pct=20 -> 0, floored to 1
[[ "$(cap_for 4 20)" == "1" ]] || fail "floor-1: 20% of 4 should floor to 1, got $(cap_for 4 20)"
# slots=1, pct=20 -> 0, floored to 1
[[ "$(cap_for 1 20)" == "1" ]] || fail "floor-1: 20% of 1 should floor to 1, got $(cap_for 1 20)"
ok "Test 3: cap = floor(slots*pct/100) with floor 1 (4 / 1 / 1)"

# === Test 4: tick skips non-exempt fleet-ops when claims >= cap ===
grep -qF 'skipped-self-maintenance-cap' "$tick" \
    || fail "skip message skipped-self-maintenance-cap not found in tick"
grep -qF '_self_maint_claims >= _self_maint_cap' "$tick" \
    || fail "cap comparison (_self_maint_claims >= _self_maint_cap) not found in tick"
ok "Test 4: non-exempt fleet-ops skip when claims >= cap"

# === Test 5: critical-path exemption (claims even past the cap) ===
# Reproduce the jq exemption filter the tick runs: a critical-path label
# present in the labels array marks the issue exempt.
exempt() {
    local labels_json="$1"
    printf '%s' "$labels_json" | jq -e --arg cp "critical-path" \
        '[.[]?.name // empty] | index($cp) != null' >/dev/null 2>&1
}
grep -qF 'index($cp) != null' "$tick" \
    || fail "critical-path exemption filter (index(\$cp) != null) not found in tick"
exempt '[{"name":"critical-path"},{"name":"agent-ready"}]' \
    || fail "critical-path issue must be exempt"
if exempt '[{"name":"agent-ready"},{"name":"fix"}]'; then
    fail "non-critical-path issue must NOT be exempt"
fi
ok "Test 5: critical-path exemption filter (exempt true when critical-path, false otherwise)"

# === Test 6: counter increments only on real non-exempt claims ===
grep -qF '_self_maint_claims=$(( _self_maint_claims + 1 ))' "$tick" \
    || fail "claim counter increment not found in tick"
grep -qF '_self_maint_claims=0' "$tick" \
    || fail "claim counter init (0) not found in tick"
ok "Test 6: claim counter init and increment present"

# === Test 7: product repos (0509) are not capped ===
# The cap is gated on the repo being self-maintenance / fleet-ops; product
# repos fall through with _self_maint_cap=0 (no cap).
grep -qF 'product_first_is_self_maintenance "$REPO" || [[ "$REPO" == "fleet-ops" ]]' "$tick" \
    || fail "self-maintenance repo gate not found in tick (product repos should be uncapped)"
ok "Test 7: cap gated to self-maintenance/fleet-ops repo (product repos uncapped)"

# === Test 8: shellcheck ===
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$tick" --severity=warning
    ok "Test 8: shellcheck clean"
else
    echo "SKIP: Test 8: shellcheck not installed"
fi

echo ""
# === Test 9: critical-path issues are claimed FIRST (0509#1691, fleet-ops#3710) ===
# Step 3 used a plain ascending-number order, so a critical-path issue filed
# late (0509#1691, deploy-blocking, 19:47Z) was "skipped-capacity" behind
# 18 older ready issues four ticks in a row. The tick must share the model
# orderer's rule (lib/intake-priority.sh rule 2): critical first, then the
# tail; lowest number first inside each tier. All three arrays use ONE
# expression so numbers/titles/labels stay aligned.
_order_line=$(grep -E '^_claim_order=' "$tick" || true)
[[ -n "$_order_line" ]] || fail "Test 9: _claim_order= seam not found in tick (Step 3 must sort critical-path first)"
_claim_order=""
eval "$_order_line"
[[ -n "$_claim_order" ]] || fail "Test 9: _claim_order= seam is empty"
_fixture='[{"number":1576,"title":"tail-old","labels":[]},
           {"number":1691,"title":"crit-new","labels":[{"name":"critical-path"},{"name":"priority"}]},
           {"number":1283,"title":"tail-priority-only","labels":[{"name":"priority"}]},
           {"number":1702,"title":"crit-newest","labels":[{"name":"critical-path"}]}]'
_got=$(jq -r --arg cp "critical-path" "$_claim_order | .[].number" <<<"$_fixture" | paste -sd,)
[[ "$_got" == "1691,1702,1283,1576" ]] \
    || fail "Test 9: claim order must be critical-path first then ascending, want 1691,1702,1283,1576 got $_got"
# labels may arrive as bare strings (older gh shapes) — same order.
_got2=$(jq -r --arg cp "critical-path" "$_claim_order | .[].number" \
    <<<'[{"number":9,"labels":["priority"]},{"number":10,"labels":["critical-path"]},{"number":8,"labels":[]}]' | paste -sd,)
[[ "$_got2" == "10,8,9" ]] || fail "Test 9: bare-string labels must order the same, want 10,8,9 got $_got2"
for arr in numbers titles labels; do
    grep -qE "^mapfile -t $arr +< <\(jq -[rc]+ --arg cp \"\\\$CRITICAL_PATH_LABEL\" \"\\\$_claim_order \| " "$tick" \
        || fail "Test 9: Step 3 array '$arr' must be built from \$_claim_order (arrays must stay aligned)"
done
ok "Test 9: Step 3 claims critical-path first, then the ascending tail (1691,1702,1283,1576)"

echo "ALL OK: intake-tick self-maintenance claim cap (fleet-ops#3254)"

# === Test 10: usable seat-slot gate (fleet-ops#3732) ===
# The tick must bound claims by the slots pick_seat would actually fill.
# Replay the tick's own gate block (extracted verbatim, not re-typed) with a
# stubbed pick_seat: 0 usable slots -> holds with the gate line and never
# reaches the claim step; 1 usable slot with capacity slots=2 -> claims at most 1.
grep -qF 'PICK_SEAT_COUNT_SLOTS=1 pick_seat "" "" 0 "" light' "$tick" \
    || fail "Test 10: usable-slot count seam (PICK_SEAT_COUNT_SLOTS=1 pick_seat) missing from tick"
grep -qF 'gate: no usable seat slot' "$tick" \
    || fail "Test 10: 'gate: no usable seat slot' hold line missing from tick"
_gate_block=$(awk '/Usable seat-slot gate \(fleet-ops#3732\)/{on=1} on{print} on && /^fi$/{n++; if(n==2) exit}' "$tick")
[[ -n "$_gate_block" ]] || fail "Test 10: could not extract the #3732 gate block from the tick"
_out0=$( pick_seat() { echo 0; }; slots=2; eval "$_gate_block"; echo "CLAIM-STEP-REACHED slots=$slots" ) || true
grep -qF 'holding claims this tick — gate: no usable seat slot' <<<"$_out0" \
    || fail "Test 10: 0 usable slots must hold with the gate line, got: $_out0"
if grep -qF 'CLAIM-STEP-REACHED' <<<"$_out0"; then fail "Test 10: 0 usable slots must exit before the claim step"; fi
_out1=$( pick_seat() { echo 1; }; slots=2; eval "$_gate_block"; echo "CLAIM-STEP-REACHED slots=$slots" ) || true
grep -qF 'CLAIM-STEP-REACHED slots=1' <<<"$_out1" \
    || fail "Test 10: 1 usable slot with capacity 2 must claim at most 1, got: $_out1"
_out3=$( pick_seat() { echo 3; }; slots=2; eval "$_gate_block"; echo "CLAIM-STEP-REACHED slots=$slots" ) || true
grep -qF 'CLAIM-STEP-REACHED slots=2' <<<"$_out3" \
    || fail "Test 10: 3 usable slots with capacity 2 must keep slots=2, got: $_out3"
_outx=$( pick_seat() { echo "garbage"; }; slots=2; eval "$_gate_block"; echo "CLAIM-STEP-REACHED slots=$slots" ) || true
grep -qF 'gate: no usable seat slot' <<<"$_outx" \
    || fail "Test 10: a non-numeric count must fail closed (hold), got: $_outx"
ok "Test 10: usable seat-slot gate holds at 0, bounds claims to min(slots, usable), fails closed on garbage (fleet-ops#3732)"
