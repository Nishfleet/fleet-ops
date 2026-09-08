#!/usr/bin/env bash
# tests/timer-guard.test.sh
#
# Regression drill for the INSTALL-TIME timer-MANIFEST gate (fleet-ops#4472).
# The live check (tests/timer-manifest.test.sh, fleet-ops#1460) catches an
# unmanaged timer only AFTER it is installed. This drill proves the guard
# fires at the creation rail, so a live timer cannot exist without a repo-
# sourced MANIFEST entry — the mechanical prevention of the ten-repeat defect
# #3198/#3317/#3336/#3338/#4128/#4218/#4247/#4327/#4291/#4400.
#
# What this proves, hermetic (no real systemd installs):
#   1. NEGATIVE: installing an unregistered .timer FAILS (exit != 0) and
#      NAMES the missing timer.
#   2. POSITIVE: installing a registered .timer SUCCEEDS (exit 0).
#   3. Template match: an instantiated timer (pi-intake@x.timer -> pi-intake@.timer)
#      SUCCEEDS even though the exact name is absent.
#   4. Dated-reason escape: --unmanaged needs a YYYY-MM-DD prefix; a dated
#      reason permits an unregistered timer (the ONLY escape, no blanket
#      allowlist); an undated reason is refused.
#   5. Fail-closed: a missing manifest makes the guard REFUSE.
#   6. pi-systemd-run (the endorsed install rail) wires the guard: a --unit
#      naming an unregistered .timer is refused with exit 2; a registered one
#      reaches the dry-run systemd-run shape.
#
# Run: bash tests/timer-guard.test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
guard="$repo_root/bin/timer-manifest-guard"
manifest="$repo_root/systemd/timer-manifest.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$guard" ]] || fail "not executable: $guard"
[[ -f "$manifest" ]] || fail "manifest not found: $manifest"
jq '.' "$manifest" >/dev/null || fail "manifest is not valid JSON"
ok "guard executable + manifest valid"

# --- 1. NEGATIVE: unregistered timer refused AND named ----------------------
set +e
out="$("$guard" -- "$repo_root/systemd/nonexistent-does-not-exist.timer" 2>&1)"
rc=$?
set -e
[[ "$rc" != "0" ]] || fail "unregistered timer must fail, rc=$rc: $out"
printf '%s\n' "$out" | grep -q 'REFUSE' || fail "must print REFUSE: $out"
printf '%s\n' "$out" | grep -q 'nonexistent-does-not-exist.timer' || fail "must NAME the missing timer: $out"
ok "NEGATIVE: unregistered timer refused and named"

# --- 2. POSITIVE: registered timer succeeds ---------------------------------
# Use a real manifest entry, resolved from the manifest to stay in sync.
reg=$(jq -r '.timers | keys[]' "$manifest" | head -1)
[[ -n "$reg" ]] || fail "manifest has no entries to test against"
set +e
out="$("$guard" -- "$reg" 2>&1)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "registered timer '$reg' must pass, rc=$rc: $out"
printf '%s\n' "$out" | grep -q "OK $reg" || fail "must print OK for a registered timer: $out"
ok "POSITIVE: registered timer '$reg' accepted"

# --- 3. template match ------------------------------------------------------
# pi-scout@0509-telemetry.timer is NOT in the manifest by exact name, but
# pi-scout@.timer is (template). Its instantiation must pass through the
# template entry.
set +e
out="$("$guard" -- "pi-scout@0509-telemetry.timer" 2>&1)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "template timer pi-scout@0509-telemetry.timer must pass via pi-scout@.timer, rc=$rc: $out"
printf '%s\n' "$out" | grep -q "pi-scout@.timer" || fail "must route through the template: $out"
ok "template timer pi-scout@0509-telemetry.timer accepted via pi-scout@.timer"

# --- 4. dated-reason escape (the ONLY escape, no blanket allowlist) ---------
# A dated reason permits an unregistered timer.
set +e
out="$("$guard" --unmanaged '2026-09-08 one-off drill; adopt or delete by 2026-09-09' -- 'drill-unregistered.timer' 2>&1)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "dated --unmanaged must permit install, rc=$rc: $out"
printf '%s\n' "$out" | grep -q 'drill-unregistered.timer' || fail "dated escape must name the timer: $out"
ok "dated --unmanaged reason permits an unregistered timer"
# An undated reason must be refused — the reason cannot be timeless.
set +e
out="$("$guard" --unmanaged 'no date means forever' -- 'drill-unregistered.timer' 2>&1)"
rc=$?
set -e
[[ "$rc" != "0" ]] || fail "undated --unmanaged must be refused, rc=$rc: $out"
printf '%s\n' "$out" | grep -q 'YYYY-MM-DD' || fail "must demand a YYYY-MM-DD prefix: $out"
ok "undated --unmanaged is refused (no forever-or-orphan allowlist)"

# --- 5. fail closed ---------------------------------------------------------
set +e
out="$("$guard" --manifest "$repo_root/systemd/does-not-exist.json" -- 'any.timer' 2>&1)"
rc=$?
set -e
[[ "$rc" != "0" ]] || fail "missing manifest must fail CLOSED, rc=$rc: $out"
printf '%s\n' "$out" | grep -qi 'closed' || fail "missing manifest must say failing closed: $out"
ok "missing manifest fails closed"

# --- 6. pi-systemd-run wires the guard --------------------------------------
psr="$repo_root/bin/pi-systemd-run"
[[ -x "$psr" ]] || fail "not executable: $psr"
# NEGATIVE via the endorsed rail: unregistered .timer refused with exit 2.
set +e
out="$("$psr" --dry-run --unit drill-unregistered.timer -- sleep 1 2>&1)"
rc=$?
set -e
[[ "$rc" != "0" ]] || fail "pi-systemd-run must refuse unregistered .timer, rc=$rc: $out"
printf '%s\n' "$out" | grep -q 'REFUSE drill-unregistered.timer' || fail "pi-systemd-run must name the missing timer: $out"
printf '%s\n' "$out" | grep -q 'refuse to install unmanaged timer' || fail "pi-systemd-run must print the refuse line: $out"
ok "NEGATIVE: pi-systemd-run refuses unregistered .timer (exit 2, names it)"
# POSITIVE via the endorsed rail: registered .timer reaches the systemd-run
# dry-run shape (proves the guard does not block legitimate timers).
set +e
out="$("$psr" --dry-run --unit "$reg" -- sleep 1 2>&1)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "pi-systemd-run must accept registered .timer, rc=$rc: $out"
printf '%s\n' "$out" | grep -q 'systemd-run' || fail "registered .timer must reach systemd-run: $out"
ok "POSITIVE: pi-systemd-run accepts registered .timer"
# A normal service unit must stay unaffected (no guard trip).
set +e
out="$("$psr" --dry-run --unit drill-service-units-unaffected -- sleep 1 2>&1)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "service unit must be unaffected by the guard, rc=$rc: $out"
printf '%s\n' "$out" | grep -q 'systemd-run' || fail "service unit must reach systemd-run: $out"
ok "normal service --unit unaffected by the guard"

echo "timer-guard drills passed — install-time timer-MANIFEST gate verified (fleet-ops#4472)"
exit 0
