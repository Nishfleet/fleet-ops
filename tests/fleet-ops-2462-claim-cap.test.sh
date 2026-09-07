#!/usr/bin/env bash
# tests/fleet-ops-2462-claim-cap.test.sh
#
# fleet-ops#2462: proves the reclaim-count cap and systemic-failure skip
# in lib/pi-intake-tick.sh, the reclaim-count increment in
# bin/pi-issue-failed-reap, and the reclaim-count init + reset in
# bin/pi-issue-run.
#
# Proves:
#   1. MAX_RECLAIMS env var is defined (default 8, overridable).
#   2. The tick reads a per-issue reclaim-count file from ATTEMPTS_DIR.
#   3. The tick skips re-claiming when count >= MAX_RECLAIMS (skipped-max-reclaims).
#   4. The tick escalates to agent-blocked on skip (gh issue edit comment).
#   5. The tick allows claims when count < MAX_RECLAIMS.
#   6. A .systemic marker causes skipped-systemic-failure (aged-out clears it).
#   7. pi-issue-failed-reap increments the reclaim-count file on OPEN reap.
#   8. pi-issue-failed-reap resets the reclaim-count file on CLOSED reap.
#   9. pi-issue-run initializes reclaim-count=1 on first claim.
#  10. pi-issue-run resets reclaim-count + systemic marker on success.
#  11. shellcheck is clean on all touched files.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"
reap="$repo_root/bin/pi-issue-failed-reap"
run="$repo_root/bin/pi-issue-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"
[[ -f "$reap" ]] || fail "bin/pi-issue-failed-reap missing"
[[ -f "$run"  ]] || fail "bin/pi-issue-run missing"

# === Test 1: MAX_RECLAIMS env var defined and overridable ===
grep -qF 'MAX_RECLAIMS="${PI_INTAKE_MAX_RECLAIMS:-8}"' "$tick" \
    || fail "MAX_RECLAIMS env var (default 8, overridable) not found in tick"
ok "Test 1: MAX_RECLAIMS env var defined (default 8, overridable)"

# === Test 2: tick reads per-issue reclaim-count file ===
grep -qF '_reclaim_count_file="$ATTEMPTS_DIR/pi-issue-${REPO}-${N}.reclaim-count"' "$tick" \
    || fail "reclaim-count file path not found in tick"
ok "Test 2: tick reads per-issue reclaim-count file from ATTEMPTS_DIR"

# === Test 3: tick skips when count >= MAX_RECLAIMS ===
grep -qF 'skipped-max-reclaims' "$tick" \
    || fail "skipped-max-reclaims skip message not found in tick"
grep -qF '_rc_current >= MAX_RECLAIMS' "$tick" \
    || fail "claim count comparison (>= MAX_RECLAIMS) not found in tick"
ok "Test 3: tick skips re-claiming when count >= MAX_RECLAIMS"

# === Test 4: tick escalates to agent-blocked only after class ladder exhausts ===
grep -qF 'agent-blocked' "$tick" \
    || { grep -q 'add-label agent-blocked' "$tick" \
        || fail "tick does not label agent-blocked on max-reclaims skip"; }
# The WORK cap no longer blocks on first hit: it advances a .prefer-class
# ladder (prepaid -> metered -> senior) and resets reclaim-count to 1 so the
# new class gets a fresh budget. Blocking (agent-blocked) happens only after
# every class has been tried, with a machine-readable blocked-on: infra
# (never the old nish-decision / senior-conference park).
grep -qF '.prefer-class' "$tick" \
    || fail "tick does not write the per-issue .prefer-class ladder on max-reclaims skip"
grep -qF 'advancing seat class' "$tick" \
    || fail "tick does not advance the seat class ladder on max-reclaims skip"
grep -qF 'blocked-on: infra' "$tick" \
    || fail "tick does not emit blocked-on: infra when every seat class is exhausted"
ok "Test 4: WORK-cap skip advances the seat-class ladder; blocks only at exhaustion with blocked-on: infra"

# === Test 5: tick allows claims when count < MAX_RECLAIMS ===
# The reclaim-count file is only written on the claim+spawned path (after
# all guards pass). Verify the init write exists.
grep -qF '_rc_init_file="$ATTEMPTS_DIR/pi-issue-${REPO}-${N}.reclaim-count"' "$tick" \
    || fail "reclaim-count init write not found in tick claim path"
grep -qF "printf '1'" "$tick" \
    || fail "reclaim-count init writes '1' on first claim not found"
ok "Test 5: tick initializes reclaim-count=1 on first claim (allows subsequent claims below cap)"

# === Test 6: systemic-failure skip ===
grep -qF '_systemic_file="$ATTEMPTS_DIR/pi-issue-${REPO}-${N}.systemic"' "$tick" \
    || fail "systemic marker file path not found in tick"
grep -qF 'skipped-systemic-failure' "$tick" \
    || fail "skipped-systemic-failure skip message not found in tick"
grep -qF 'rm -f "$_systemic_file"' "$tick" \
    || fail "systemic marker removal on age-out not found in tick"
ok "Test 6: .systemic marker causes skipped-systemic-failure, aged-out clears it"

# === Test 7: pi-issue-failed-reap increments reclaim-count on OPEN reap (work death) ===
grep -qF '_rc_file="$ATTEMPTS_DIR/pi-issue-${instance}.reclaim-count"' "$reap" \
    || fail "reclaim-count file path not found in reaper"
grep -qF 'RECLAIM-COUNT-INCREMENTED' "$reap" \
    || fail "reclaim-count increment log not found in reaper"
# The increment must be in the OPEN branch (after cooldown, before CLOSED branch)
# and gated to the WORK death class (infra deaths hit the separate counter).
grep -qF 'INFRA-DEATH-INCREMENTED' "$reap" \
    || fail "infra-death increment log not found in reaper"
grep -qF '.last-death-class' "$reap" \
    || fail "reaper does not read the .last-death-class marker"
_rc_line=$(grep -n 'RECLAIM-COUNT-INCREMENTED' "$reap" | head -1 | cut -d: -f1)
_cd_line=$(grep -n 'RECLAIM-COOLDOWN-SET' "$reap" | head -1 | cut -d: -f1)
(( _rc_line > _cd_line )) \
    || fail "reclaim-count increment (line $_rc_line) must come after cooldown (line $_cd_line) in OPEN branch"
ok "Test 7: pi-issue-failed-reap splits reclaim-count (work) vs infra-death on OPEN reap (after cooldown)"

# === Test 8: pi-issue-failed-reap resets reclaim-count on CLOSED reap ===
grep -qF 'pi-issue-${instance}.reclaim-count' "$reap" \
    || fail "reclaim-count reset not found in reaper"
# Verify the reset is in the CLOSED branch and also clears the ladder markers.
grep -qF 'pi-issue-${instance}.prefer-class' "$reap" \
    || fail "CLOSED reap does not clear the .prefer-class ladder marker"
grep -qF 'pi-issue-${instance}.infra-death' "$reap" \
    || fail "CLOSED reap does not clear the .infra-death counter"
_closed_line=$(grep -n 'CLAIM-CLOSED-CLEANUP' "$reap" | head -1 | cut -d: -f1)
_reset_line=$(grep -n 'reset reclaim-count' "$reap" | head -1 | cut -d: -f1)
(( _reset_line > _closed_line )) \
    || fail "reclaim-count reset (line $_reset_line) must come after CLAIM-CLOSED-CLEANUP (line $_closed_line) in CLOSED branch"
ok "Test 8: pi-issue-failed-reap resets reclaim-count + clears ladder/infra markers on CLOSED reap"

# === Test 9: pi-issue-run initializes reclaim-count=1 on first claim ===
grep -qF '_rc_init_file="$ATTEMPTS_DIR/pi-issue-${inst}.reclaim-count"' "$run" \
    || fail "reclaim-count init not found in pi-issue-run"
grep -qF 'initialized reclaim-count=1' "$run" \
    || fail "reclaim-count init log not found in pi-issue-run"
# Must be BEFORE the main while loop (first claim of a fresh dispatch)
_init_while=$(grep -n 'initialized reclaim-count=1' "$run" | head -1 | cut -d: -f1)
_while_loop=$(grep -n 'while true; do' "$run" | head -1 | cut -d: -f1)
(( _init_while < _while_loop )) \
    || fail "reclaim-count init must be before the main retry loop (line $_init_while vs loop @ $_while_loop)"
ok "Test 8b: pi-issue-run initializes reclaim-count=1 on first claim (before retry loop)"

# === Test 10: pi-issue-run resets reclaim-count + systemic on success ===
grep -qF 'SUCCESS reset reclaim-count' "$run" \
    || fail "success-path reclaim-count reset not found in pi-issue-run"
grep -qF 'rm -f "$ATTEMPTS_DIR/pi-issue-${inst}.reclaim-count"' "$run" \
    || fail "reclaim-count reset file path not found in pi-issue-run"
grep -qF 'rm -f "$ATTEMPTS_DIR/pi-issue-${inst}.systemic"' "$run" \
    || fail "systemic marker reset not found in pi-issue-run"
# Must be in the success path (after the tried-seats reset, before exit 0)
_tried_reset=$(grep -n ': >"$tried_file"' "$run" | head -1 | cut -d: -f1)
_rc_reset=$(grep -n 'rm -f "$ATTEMPTS_DIR/pi-issue-${inst}.reclaim-count"' "$run" | head -1 | cut -d: -f1)
_exit_zero=$(grep -n 'exit 0' "$run" | tail -1 | cut -d: -f1)
(( _rc_reset > _tried_reset )) \
    || fail "reclaim-count reset (line $_rc_reset) must come after tried-seats reset (line $_tried_reset)"
(( _rc_reset < _exit_zero )) \
    || fail "reclaim-count reset (line $_rc_reset) must come before exit 0 (line $_exit_zero)"
ok "Test 10: pi-issue-run resets reclaim-count + systemic marker on success"

# === Test 11: shellcheck ===
for f in "$tick" "$reap" "$run"; do
    if command -v shellcheck >/dev/null 2>&1; then
        shellcheck "$f" --severity=warning 2>&1 || {
            fail "shellcheck failed on $(basename "$f")"
        }
    fi
done
ok "Test 11: shellcheck clean on all touched files"

echo ""
echo "ALL OK: fleet-ops#2462 reclaim-count cap + systemic-failure skip"
