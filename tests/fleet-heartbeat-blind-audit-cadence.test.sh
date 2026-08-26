#!/usr/bin/env bash
# tests/fleet-heartbeat-blind-audit-cadence.test.sh
#
# fleet-ops#378: audit fires on its calendar regardless of board state;
# cadence-overdue escalates through the heartbeat so a stuck audit screams.
#
# This test runs the REAL canary in lib/blind-audit-cadence.sh (the same
# function tier1 §11 sources). A duplicated predicate would be the same
# class of bug the issue is about — machinery that exists but never runs.
#
#   1. Fresh stamp (< limit)         -> status=ok, NO LOUD.
#   2. Stale stamp (> limit)         -> status=overdue, LOUD.
#   3. Missing stamp in plan         -> status=never-ran, LOUD.
#   4. Missing plan file             -> status=missing-plan, LOUD.
#   5. Unparseable stamp             -> status=unparseable-stamp, LOUD.
#   6. AUDIT_CADENCE_DISABLE=1       -> disabled, NO LOUD.
#   7. AUDIT_CADENCE_MAX_AGE_S       -> tightens the bound.
#   8. tier1 sources the lib; timer stays daily + Persistent.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/blind-audit-cadence.sh"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
timer="$repo_root/systemd/fleet-blind-audit.timer"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing: $lib"
[[ -f "$tier1" ]] || fail "missing: $tier1"
[[ -x "$tier1" ]] || fail "not executable: $tier1"
[[ -f "$timer" ]] || fail "missing: $timer"

# ============================================================================
# Phase A: shape-lock the §11 wiring
# ============================================================================
grep -F -- 'heartbeat_blind_audit_cadence_canary' "$tier1" >/dev/null \
    || fail "tier1 §11 must call heartbeat_blind_audit_cadence_canary"
grep -F -- 'blind-audit-cadence.sh' "$tier1" >/dev/null \
    || fail "tier1 §11 must source lib/blind-audit-cadence.sh"
grep -F -- 'BLIND-AUDIT-CADENCE-OVERDUE' "$lib" >/dev/null \
    || fail "cadence lib must emit BLIND-AUDIT-CADENCE-OVERDUE"
grep -F -- 'last-blind-audit-run:' "$lib" >/dev/null \
    || fail "cadence lib must read last-blind-audit-run:"
grep -F -- 'AUDIT_CADENCE_MAX_AGE_S' "$lib" >/dev/null \
    || fail "cadence lib must honour AUDIT_CADENCE_MAX_AGE_S"
grep -F -- 'AUDIT_CADENCE_DISABLE' "$lib" >/dev/null \
    || fail "cadence lib must honour AUDIT_CADENCE_DISABLE=1"
ok "A: §11 wiring locked (source + call + stamp key + canary tag + env)"

grep -F -- 'OnCalendar=*-*-*' "$timer" >/dev/null \
    || fail "fleet-blind-audit.timer must remain OnCalendar=*-*-* (daily floor)"
grep -F -- 'Persistent=true' "$timer" >/dev/null \
    || fail "fleet-blind-audit.timer must remain Persistent=true"
ok "A: daily floor + Persistent=true still in place"

# ============================================================================
# Phase B: run the real canary against fixture plan files
# ============================================================================
scratch="$(mktemp -d -t blind-cadence.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

triage="$scratch/triage.md"
plan="$scratch/plan.md"
: >"$triage"

# Isolate from a live PLAN_FILE / triage.
export PLAN_FILE="$plan"
export FLEET_HEARTBEAT_TRIAGE="$triage"
unset AUDIT_CADENCE_DISABLE || true
unset AUDIT_CADENCE_MAX_AGE_S || true

# shellcheck source=../lib/blind-audit-cadence.sh
source "$lib"

loud_count() {
    local n
    n="$(grep -c 'BLIND-AUDIT-CADENCE-OVERDUE' "$triage" 2>/dev/null || true)"
    [ -n "$n" ] || n=0
    printf '%s\n' "$n"
}
write_stamp() {
    local stamp="$1" state="${2:-completed, filed=3}"
    printf 'last-heartbeat: 2026-08-26T05:43:00Z (durable-timer)\n' >"$plan"
    printf 'last-blind-audit-run: %s (%s)\n' "$stamp" "$state" >>"$plan"
}

# --- B1: fresh stamp -> ok, NO LOUD --------------------------------------
: >"$triage"
fresh_stamp="$(date -u -d "@$(( $(date +%s) - 6*3600 ))" +%Y-%m-%dT%H:%M:%SZ)"
write_stamp "$fresh_stamp" "completed, filed=3"
heartbeat_blind_audit_cadence_canary
[[ "$audit_canary_status" == "ok" ]] || fail "B1: fresh stamp must report ok, got $audit_canary_status"
[[ "$(loud_count)" == "0" ]] || fail "B1: fresh stamp must NOT emit LOUD, got $(loud_count)"
ok "B1: fresh stamp -> ok, no LOUD"

# --- B2: stale stamp (40h, limit 30h) -> overdue + LOUD -------------------
: >"$triage"
stale_stamp="$(date -u -d "@$(( $(date +%s) - 40*3600 ))" +%Y-%m-%dT%H:%M:%SZ)"
write_stamp "$stale_stamp" "completed, filed=2"
heartbeat_blind_audit_cadence_canary
[[ "$audit_canary_status" == "overdue" ]] || fail "B2: stale stamp must report overdue, got $audit_canary_status"
[[ "$(loud_count)" -ge 1 ]] || fail "B2: stale stamp must emit LOUD, got $(loud_count)"
grep -q "stamp='$stale_stamp'" "$triage" \
    || fail "B2: LOUD line must include the stale stamp '$stale_stamp'"
ok "B2: stale stamp (40h, limit 30h) -> overdue + LOUD (stamp echoed)"

# --- B3: missing stamp (blank plan body) -> never-ran + LOUD -------------
: >"$triage"
printf 'last-heartbeat: 2026-08-26T05:43:00Z (durable-timer)\n' >"$plan"
heartbeat_blind_audit_cadence_canary
[[ "$audit_canary_status" == "never-ran" ]] || fail "B3: blank plan must report never-ran, got $audit_canary_status"
[[ "$(loud_count)" -ge 1 ]] || fail "B3: blank plan must emit LOUD, got $(loud_count)"
ok "B3: blank plan body -> never-ran + LOUD"

# --- B4: missing plan file -> missing-plan + LOUD -----------------------
: >"$triage"
rm -f "$plan"
heartbeat_blind_audit_cadence_canary
[[ "$audit_canary_status" == "missing-plan" ]] || fail "B4: missing plan must report missing-plan, got $audit_canary_status"
[[ "$(loud_count)" -ge 1 ]] || fail "B4: missing plan must emit LOUD, got $(loud_count)"
ok "B4: missing plan file -> missing-plan + LOUD"

# --- B5: unparseable stamp -> unparseable-stamp + LOUD ------------------
: >"$triage"
write_stamp "not-an-iso-timestamp" "completed, filed=0"
heartbeat_blind_audit_cadence_canary
[[ "$audit_canary_status" == "unparseable-stamp" ]] || fail "B5: garbage stamp must report unparseable-stamp, got $audit_canary_status"
[[ "$(loud_count)" -ge 1 ]] || fail "B5: garbage stamp must emit LOUD, got $(loud_count)"
ok "B5: garbage stamp -> unparseable-stamp + LOUD"

# --- B6: AUDIT_CADENCE_DISABLE=1 -> disabled, NO LOUD -------------------
: >"$triage"
stale_stamp="$(date -u -d "@$(( $(date +%s) - 50*3600 ))" +%Y-%m-%dT%H:%M:%SZ)"
write_stamp "$stale_stamp" "completed, filed=1"
AUDIT_CADENCE_DISABLE=1
heartbeat_blind_audit_cadence_canary
[[ "$audit_canary_status" == "disabled" ]] || fail "B6: escape hatch must report disabled, got $audit_canary_status"
[[ "$(loud_count)" == "0" ]] || fail "B6: escape hatch must silence LOUD, got $(loud_count)"
unset AUDIT_CADENCE_DISABLE
ok "B6: AUDIT_CADENCE_DISABLE=1 -> disabled (no LOUD, even when stale)"

# --- B7: AUDIT_CADENCE_MAX_AGE_S tightens the bound ----------------------
: >"$triage"
six_h_old="$(date -u -d "@$(( $(date +%s) - 6*3600 ))" +%Y-%m-%dT%H:%M:%SZ)"
write_stamp "$six_h_old" "completed, filed=0"
heartbeat_blind_audit_cadence_canary
[[ "$audit_canary_status" == "ok" ]] || fail "B7: 6h stamp at default 30h limit must be ok, got $audit_canary_status"
AUDIT_CADENCE_MAX_AGE_S=3600
heartbeat_blind_audit_cadence_canary
[[ "$audit_canary_status" == "overdue" ]] || fail "B7: 6h stamp at 1h limit must be overdue, got $audit_canary_status"
[[ "$(loud_count)" -ge 1 ]] || fail "B7: tightened limit must emit LOUD when overdue, got $(loud_count)"
unset AUDIT_CADENCE_MAX_AGE_S
ok "B7: AUDIT_CADENCE_MAX_AGE_S respected (6h stamp: ok@30h, overdue@1h)"

# ============================================================================
# Phase C: §10 dispatch + §11 stamp stay independent
# ============================================================================
grep -F -- 'last-blind-audit-dispatch:' "$tier1" >/dev/null \
    || fail "tier1 §10 must still stamp last-blind-audit-dispatch: after §11 lands"
ok "C: §10 dispatch + §11 stamp coexisting"

echo "all phases passed"
