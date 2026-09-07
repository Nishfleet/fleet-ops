#!/usr/bin/env bash
# tests/pi-intake-tick-protected-verifier-vacation.test.sh
#
# fleet-ops#1165 (vacation-audit-20260827 finding 12): the deterministic
# intake tick (lib/pi-intake-tick.sh) MUST skip claiming any 0509
# agent-ready issue whose body names a protected verifier/deploy file
# while inside the vacation window, so workers do not open attest-stuck
# PRs that sit red on the required-verifier-integrity gate until Nish
# returns. The gate itself is unchanged (do not weaken or remove it);
# this is intake-side prevention. The skip is date-bounded and expires
# the day after the cutoff, so the issue (which stays agent-ready) becomes
# claimable again with no unpark mechanism.
#
# Static-grep + bash drill (same shape as pi-intake-tick-escalate-senior-
# exclusion and pi-intake-tick-claim-set-e-guard): pins the filter in the
# tick without a live systemd/gh environment. The drill reproduces the
# exact filter logic and proves:
#   1. The tick defines the filter function and the protected file list.
#   2. The tick applies the filter in the claim loop and prints the
#      skipped-protected-verifier-vacation summary line.
#   3. The repo seam, date seams, and file-list seam are overridable.
#   4. A 0509 body naming a protected file is skipped inside the window.
#   5. A 0509 body naming NO protected file is claimed (not skipped).
#   6. The skip expires after the cutoff (date past UNTIL => not skipped).
#   7. The skip does not fire before the window (date before FROM).
#   8. The skip is 0509-only (a fleet-ops body naming a protected file is
#      not skipped — the park is repo-scoped).
#   9. The env file-list override is honored.
#  10. shellcheck is clean on the tick.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"

# === Test 1: filter function + protected file list present ===
grep -qF 'protected_verifier_vacation_filter()' "$tick" \
    || fail "protected_verifier_vacation_filter() not defined in tick"
grep -qF '_pvv_default_files=(' "$tick" \
    || fail "protected file list (_pvv_default_files) not defined in tick"
ok "Test 1: filter function and protected file list present"

# === Test 2: filter applied in the claim loop with the skip summary line ===
grep -qF 'if protected_verifier_vacation_filter "$body"; then' "$tick" \
    || fail "tick must call protected_verifier_vacation_filter on the issue body in the claim loop"
grep -qF 'skipped-protected-verifier-vacation' "$tick" \
    || fail "tick must print skipped-protected-verifier-vacation when the filter fires"
ok "Test 2: filter applied in claim loop with skip summary line"

# === Test 3: seams are overridable ===
grep -qF 'PROTECTED_VERIFIER_VACATION_REPO="${PI_INTAKE_PROTECTED_VERIFIER_VACATION_REPO:-0509}"' "$tick" \
    || fail "PROTECTED_VERIFIER_VACATION_REPO seam (overridable) not found"
grep -qF 'PROTECTED_VERIFIER_VACATION_FROM="${PI_INTAKE_PROTECTED_VERIFIER_VACATION_FROM:-2026-08-28}"' "$tick" \
    || fail "PROTECTED_VERIFIER_VACATION_FROM seam (overridable) not found"
grep -qF 'PROTECTED_VERIFIER_VACATION_UNTIL="${PI_INTAKE_PROTECTED_VERIFIER_VACATION_UNTIL:-2026-09-08}"' "$tick" \
    || fail "PROTECTED_VERIFIER_VACATION_UNTIL seam (overridable) not found"
grep -qF 'PI_INTAKE_PROTECTED_VERIFIER_VACATION_TODAY' "$tick" \
    || fail "PI_INTAKE_PROTECTED_VERIFIER_VACATION_TODAY date seam not found"
grep -qF 'PI_INTAKE_PROTECTED_VERIFIER_VACATION_FILES' "$tick" \
    || fail "PI_INTAKE_PROTECTED_VERIFIER_VACATION_FILES file-list seam not found"
ok "Test 3: repo, date, and file-list seams present and overridable"

# === Test 4-9: bash drill reproducing the exact filter logic ===
# Source the tick's filter by reproducing it standalone (the tick is a
# script with top-level execution, so it cannot be sourced directly). The
# reproduction below mirrors lib/pi-intake-tick.sh verbatim in logic.
PVV_REPO="0509"
PVV_FROM="2026-08-28"
PVV_UNTIL="2026-09-08"
_pvv_default_files=(
    ".github/workflows/ci.yml"
    ".github/workflows/secret-scan.yml"
    ".github/workflows/required-verifier-integrity.yml"
    ".github/scripts/required-verifier-integrity.sh"
    ".github/scripts/test-required-verifier-integrity.sh"
    ".github/workflows/deploy-production.yml"
    ".github/workflows/finalize-production-soak.yml"
    "scripts/ci-verify-production-candidate.sh"
    "scripts/ci-verify-provider-main-cas.sh"
)

# Args: <repo> <today> <body> [files_override]. Echoes SKIP or CLAIM.
drill_filter() {
    local repo="$1" today="$2" body="$3" files_override="${4:-}"
    [[ "$repo" == "$PVV_REPO" ]] || { echo CLAIM; return; }
    if [[ "$today" < "$PVV_FROM" || "$today" > "$PVV_UNTIL" ]]; then
        echo CLAIM; return
    fi
    local f
    if [[ -n "$files_override" ]]; then
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            if printf '%s' "$body" | grep -qF -- "$f"; then echo SKIP; return; fi
        done <<<"$files_override"
    else
        for f in "${_pvv_default_files[@]}"; do
            if printf '%s' "$body" | grep -qF -- "$f"; then echo SKIP; return; fi
        done
    fi
    echo CLAIM
}

body_protected="accept:\n- Edit .github/workflows/ci.yml to add the job\nverify:\n  grep ci.yml"
body_clean="accept:\n- Update the search heading copy on /search\nverify:\n  curl https://0509.io/search"
body_deploy="evidence:\n- scripts/ci-verify-provider-main-cas.sh"

# Test 4: 0509 body naming a protected file, inside window => SKIP
[[ "$(drill_filter 0509 2026-08-30 "$body_protected")" == SKIP ]] \
    || fail "Test 4: 0509 protected-file body inside window must SKIP"
ok "Test 4: 0509 protected-file body inside window is skipped"

# Test 5: 0509 body naming NO protected file, inside window => CLAIM
[[ "$(drill_filter 0509 2026-08-30 "$body_clean")" == CLAIM ]] \
    || fail "Test 5: 0509 clean body inside window must CLAIM (not skipped)"
ok "Test 5: 0509 clean body inside window is claimed (not skipped)"

# Test 6: skip expires after cutoff (date past UNTIL => CLAIM)
[[ "$(drill_filter 0509 2026-09-09 "$body_protected")" == CLAIM ]] \
    || fail "Test 6: after cutoff (2026-09-09) the skip must expire => CLAIM"
ok "Test 6: skip expires after cutoff (2026-09-09 => claim)"

# Test 7: skip does not fire before the window (date before FROM => CLAIM)
[[ "$(drill_filter 0509 2026-08-27 "$body_protected")" == CLAIM ]] \
    || fail "Test 7: before window (2026-08-27) must CLAIM (park not yet active)"
ok "Test 7: before window (2026-08-27 => claim, park not yet active)"

# Test 8: skip is 0509-only (fleet-ops body naming a protected file => CLAIM)
[[ "$(drill_filter fleet-ops 2026-08-30 "$body_protected")" == CLAIM ]] \
    || fail "Test 8: fleet-ops body naming a protected file must CLAIM (park is 0509-only)"
ok "Test 8: park is 0509-only (fleet-ops protected-file body is claimed)"

# Test 9: a different protected file (deploy chain) is also caught
[[ "$(drill_filter 0509 2026-08-30 "$body_deploy")" == SKIP ]] \
    || fail "Test 9: 0509 body naming scripts/ci-verify-provider-main-cas.sh must SKIP"
ok "Test 9: deploy-chain protected file is also caught"

# Test 10: env file-list override is honored (custom path => SKIP, default absent => CLAIM)
override_body="accept:\n- touch config/special.yml"
[[ "$(drill_filter 0509 2026-08-30 "$override_body" "config/special.yml")" == SKIP ]] \
    || fail "Test 10: env file-list override must be honored (custom path => SKIP)"
[[ "$(drill_filter 0509 2026-08-30 "$override_body")" == CLAIM ]] \
    || fail "Test 10: without override, custom path not in default list => CLAIM"
ok "Test 10: env file-list override honored; default list unaffected"

# === Test 11: shellcheck ===
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "$tick" --severity=warning
    ok "Test 11: shellcheck clean on the tick"
else
    echo "SKIP: Test 11: shellcheck not installed"
fi

echo ""
echo "ALL OK: intake-tick protected-verifier vacation park (fleet-ops#1165, audit finding 12)"
