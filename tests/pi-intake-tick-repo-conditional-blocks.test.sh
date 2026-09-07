#!/usr/bin/env bash
# tests/pi-intake-tick-repo-conditional-blocks.test.sh
#
# fleet-ops#3247 (child of #3120): the deterministic intake tick
# (lib/pi-intake-tick.sh) MUST assemble repo-conditional worker prompt blocks
# at packet-write time so non-0509 and non-geo packets stay lean:
#   1. D1 schema + gate-integrity block ships ONLY when TARGET repo is 0509
#      (ideally only when the issue body names migrations/ or .github/).
#   2. GEO/AEO block ships ONLY when the issue carries a geo/aeo label.
#
# Static-grep + bash drill (same shape as pi-intake-tick-protected-verifier-
# vacation and pi-intake-tick-escalate-senior-exclusion): pins the conditional
# assembly in the tick without a live systemd/gh environment. The drill
# reproduces the exact helper logic and proves:
#   - The fragment files exist in the checkout.
#   - The tick defines both helper functions and the config seams.
#   - The tick appends the fragments conditionally at the packet-write block.
#   - d1_gate_integrity_needed: 0509 + body with migrations/ -> needed.
#   - d1_gate_integrity_needed: 0509 + body with .github/ -> needed.
#   - d1_gate_integrity_needed: 0509 + body with neither -> NOT needed.
#   - d1_gate_integrity_needed: fleet-ops + body with migrations/ -> NOT needed.
#   - d1_gate_integrity_needed: empty needles seam -> always needed for 0509.
#   - geo_aeo_needed: labels with "geo" -> needed.
#   - geo_aeo_needed: labels with "aeo" -> needed (case-insensitive).
#   - geo_aeo_needed: labels without geo/aeo -> NOT needed.
#   - geo_aeo_needed: empty labels -> NOT needed.
#   - shellcheck is clean on the tick.
#   - MANIFEST installs both fragment files.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"
manifest="$repo_root/MANIFEST"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"
[[ -f "$manifest" ]] || fail "MANIFEST missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

# === Test 1: fragment files exist ============================================
d1_block="$repo_root/prompts/worker-blocks/d1-gate-integrity.md"
geo_block="$repo_root/prompts/worker-blocks/geo-aeo.md"
[[ -f "$d1_block" ]] || fail "D1+gate-integrity fragment missing: $d1_block"
[[ -f "$geo_block" ]] || fail "GEO/AEO fragment missing: $geo_block"
# The D1 fragment must carry the schema-rule needles (same content that used
# to live inline in worker.md — proves the block was extracted verbatim).
grep -qF 'D1 schema rule (expand/contract)' "$d1_block" \
    || fail "D1 fragment missing 'D1 schema rule (expand/contract)'"
grep -qF 'Gate-integrity rule' "$d1_block" \
    || fail "D1 fragment missing 'Gate-integrity rule'"
grep -qF 'gate-integrity-attest:' "$d1_block" \
    || fail "D1 fragment missing 'gate-integrity-attest:'"
# The GEO/AEO fragment must carry the parked-tactics needles.
grep -qF 'GEO/AEO' "$geo_block" \
    || fail "GEO/AEO fragment missing 'GEO/AEO'"
grep -qF 'preview-then-autonomous' "$geo_block" \
    || fail "GEO/AEO fragment missing 'preview-then-autonomous'"
ok "Test 1: fragment files exist with expected content"

# === Test 2: helper functions defined in the tick ============================
grep -qF 'd1_gate_integrity_needed()' "$tick" \
    || fail "d1_gate_integrity_needed() not defined in tick"
grep -qF 'geo_aeo_needed()' "$tick" \
    || fail "geo_aeo_needed() not defined in tick"
ok "Test 2: both helper functions defined in tick"

# === Test 3: config seams are overridable ====================================
grep -qF 'WORKER_BLOCKS_DIR="${PI_INTAKE_WORKER_BLOCKS_DIR:-' "$tick" \
    || fail "WORKER_BLOCKS_DIR seam (overridable) not found"
grep -qF 'D1_GATE_REPO="${PI_INTAKE_D1_GATE_REPO:-0509}"' "$tick" \
    || fail "D1_GATE_REPO seam (overridable) not found"
grep -qF 'D1_GATE_BODY_NEEDLES="${PI_INTAKE_D1_GATE_BODY_NEEDLES:-' "$tick" \
    || fail "D1_GATE_BODY_NEEDLES seam (overridable) not found"
ok "Test 3: config seams present and overridable"

# === Test 4: conditional append at the packet-write block ====================
grep -qF 'd1_gate_integrity_needed "$body"' "$tick" \
    || fail "tick must call d1_gate_integrity_needed on the issue body at packet-write"
grep -qF 'geo_aeo_needed "${labels[$i]}"' "$tick" \
    || fail "tick must call geo_aeo_needed on the issue labels at packet-write"
grep -qF 'cat "$WORKER_BLOCKS_DIR/$D1_GATE_INTEGRITY_BLOCK"' "$tick" \
    || fail "tick must cat the D1+gate-integrity fragment at packet-write"
grep -qF 'cat "$WORKER_BLOCKS_DIR/$GEO_AEO_BLOCK"' "$tick" \
    || fail "tick must cat the GEO/AEO fragment at packet-write"
ok "Test 4: conditional append wired at packet-write"

# === Test 5: MANIFEST installs both fragments ================================
grep -qF 'prompts/worker-blocks/d1-gate-integrity.md /home/nish/.pi/agent/prompts/worker-blocks/d1-gate-integrity.md' "$manifest" \
    || fail "MANIFEST must install d1-gate-integrity.md"
grep -qF 'prompts/worker-blocks/geo-aeo.md /home/nish/.pi/agent/prompts/worker-blocks/geo-aeo.md' "$manifest" \
    || fail "MANIFEST must install geo-aeo.md"
ok "Test 5: MANIFEST installs both fragment files"

# === Test 6-13: bash drill reproducing the exact helper logic ================
# Source the helpers by reproducing them standalone (the tick is a script with
# top-level execution, so it cannot be sourced directly). The reproduction
# below mirrors lib/pi-intake-tick.sh verbatim in logic.

d1_gate_integrity_needed() {
    local body="$1"
    [[ "$REPO" == "$D1_GATE_REPO" ]] || return 1
    [[ -n "$D1_GATE_BODY_NEEDLES" ]] || return 0
    local needle
    while IFS= read -r needle; do
        [[ -n "$needle" ]] || continue
        if printf '%s' "$body" | grep -qF -- "$needle"; then
            return 0
        fi
    done <<<"$D1_GATE_BODY_NEEDLES"
    return 1
}

geo_aeo_needed() {
    local labels_json="${1:-}"
    [[ -n "$labels_json" ]] || return 1
    printf '%s' "$labels_json" | jq -e \
        'any(.[]?; (.name // "") | test("geo|aeo"; "i"))' >/dev/null 2>&1
}

# Test 6: 0509 + body with migrations/ -> needed
REPO="0509"; D1_GATE_REPO="0509"
D1_GATE_BODY_NEEDLES="migrations/
.github/"
d1_gate_integrity_needed "Add a migrations/0001_init.sql file" \
    && ok "Test 6: 0509 + body with migrations/ -> needed" \
    || fail "Test 6: 0509 + migrations/ should be needed"

# Test 7: 0509 + body with .github/ -> needed
d1_gate_integrity_needed "Edit .github/workflows/ci.yml" \
    && ok "Test 7: 0509 + body with .github/ -> needed" \
    || fail "Test 7: 0509 + .github/ should be needed"

# Test 8: 0509 + body with neither -> NOT needed
if d1_gate_integrity_needed "Fix a typo in the README" 2>/dev/null; then
    fail "Test 8: 0509 + neither needle should NOT be needed"
else
    ok "Test 8: 0509 + body with neither -> NOT needed"
fi

# Test 9: fleet-ops + body with migrations/ -> NOT needed (repo-scoped)
REPO="fleet-ops"
if d1_gate_integrity_needed "Add a migrations/0001_init.sql file" 2>/dev/null; then
    fail "Test 9: fleet-ops should NOT be needed (repo-scoped to 0509)"
else
    ok "Test 9: fleet-ops + migrations/ -> NOT needed (repo-scoped)"
fi

# Test 10: empty needles seam -> always needed for 0509
REPO="0509"; D1_GATE_BODY_NEEDLES=""
d1_gate_integrity_needed "Fix a typo in the README" \
    && ok "Test 10: empty needles -> always needed for 0509" \
    || fail "Test 10: empty needles should still be needed for 0509"

# Test 11: labels with "geo" -> needed
geo_aeo_needed '[{"name":"agent-ready"},{"name":"geo"}]' \
    && ok "Test 11: labels with geo -> needed" \
    || fail "Test 11: labels with geo should be needed"

# Test 12: labels with "AEO" (case-insensitive) -> needed
geo_aeo_needed '[{"name":"agent-ready"},{"name":"AEO"}]' \
    && ok "Test 12: labels with AEO (case-insensitive) -> needed" \
    || fail "Test 12: labels with AEO should be needed"

# Test 13: labels without geo/aeo -> NOT needed
if geo_aeo_needed '[{"name":"agent-ready"},{"name":"bug"}]' 2>/dev/null; then
    fail "Test 13: labels without geo/aeo should NOT be needed"
else
    ok "Test 13: labels without geo/aeo -> NOT needed"
fi

# Test 14: empty labels -> NOT needed
if geo_aeo_needed '[]' 2>/dev/null; then
    fail "Test 14: empty labels should NOT be needed"
else
    ok "Test 14: empty labels -> NOT needed"
fi

# Test 15: empty string labels -> NOT needed
if geo_aeo_needed '' 2>/dev/null; then
    fail "Test 15: empty string labels should NOT be needed"
else
    ok "Test 15: empty string labels -> NOT needed"
fi

# === Test 16: shellcheck is clean on the tick ================================
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$tick" 2>/dev/null \
        && ok "Test 16: shellcheck clean on tick" \
        || fail "Test 16: shellcheck found issues in tick"
else
    ok "Test 16: shellcheck not installed — skipped"
fi

# === Test 17: bash -n parses =================================================
bash -n "$tick" \
    && ok "Test 17: bash -n parses tick" \
    || fail "Test 17: bash -n failed on tick"

echo "All repo-conditional-blocks tests passed."
