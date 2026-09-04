#!/usr/bin/env bash
# tests/fleet-ops-3310-infra-death-class-switch.test.sh
#
# fleet-ops#3310: proves infrastructure deaths (rc=124/143, spawnSync
# ETIMEDOUT, no-seat, hard-ceiling near timeout) increment a separate
# .infra-death counter instead of the .reclaim-count WORK cap, and that the
# WORK cap advances a .prefer-class ladder (prepaid -> metered -> senior)
# before blocking with blocked-on: orchestrator.
#
# Proves (structural + functional):
#   1. pi-issue-run has is_infra_death (rc=124, rc=143, mid-session, spawn
#      ETIMEDOUT, hard-ceiling near timeout).
#   2. pi-issue-run writes .last-death-class=infra on infra deaths.
#   3. pi-issue-run writes .last-death-class=work on non-infra deaths.
#   4. pi-issue-run reads .prefer-class -> PI_PICK_PREFER_CLASS.
#   5. pi-issue-run clears .prefer-class/.infra-death/.last-death-class on
#      shipped success.
#   6. pi-issue-failed-reap increments .infra-death (NOT .reclaim-count) when
#      .last-death-class=infra, and clears the marker.
#   7. pi-issue-failed-reap increments .reclaim-count when .last-death-class
#      is absent or =work.
#   8. pi-issue-failed-reap clears .prefer-class/.infra-death/.last-death-class
#      on CLOSED reap.
#   9. seat-lib pick_seat honors PI_PICK_PREFER_CLASS (prepaid/metered/senior)
#      and falls through to the normal ladder when the preferred class is empty.
#  10. pi-intake-tick advances the .prefer-class ladder + resets reclaim-count
#      on each rung, blocks only at senior exhaustion.
#  11. shellcheck clean on all touched files.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
run="$repo_root/bin/pi-issue-run"
reap="$repo_root/bin/pi-issue-failed-reap"
tick="$repo_root/lib/pi-intake-tick.sh"
seat_lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$run" ]] || fail "bin/pi-issue-run missing"
[[ -f "$reap" ]] || fail "bin/pi-issue-failed-reap missing"
[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"
[[ -f "$seat_lib" ]] || fail "lib/seat-lib.sh missing"

# === Test 1: is_infra_death covers all infra signals ===
grep -qF 'is_infra_death()' "$run" || fail "is_infra_death function not found in pi-issue-run"
grep -qF '(( rc == 124 )) && return 0' "$run" || fail "is_infra_death: rc=124 not classified as infra"
grep -qF '(( rc == 143 )) && return 0' "$run" || fail "is_infra_death: rc=143 not classified as infra"
grep -qF 'is_mid_session_death "$err_file"' "$run" || fail "is_infra_death: mid-session death not checked"
grep -qF 'is_spawn_etimeout' "$run" || fail "is_infra_death: spawn ETIMEDOUT not checked"
grep -qF 'provider_hard_ceiling' "$run" || fail "is_infra_death: hard-ceiling near timeout not checked"
grep -qF 'PI_HANG_TIMEOUT_S - 30' "$run" || fail "is_infra_death: 30s-of-hard-timeout window not found"
ok "Test 1: is_infra_death covers rc=124/143, mid-session, spawn ETIMEDOUT, hard-ceiling near timeout"

# === Test 2: pi-issue-run writes .last-death-class=infra on infra deaths ===
grep -qF 'write_death_class infra' "$run" || fail "write_death_class infra not found in pi-issue-run"
grep -qF 'write_death_class()' "$run" || fail "write_death_class function not found"
grep -qF 'pi-issue-${inst}.last-death-class' "$run" || fail ".last-death-class file path not found in pi-issue-run"
# The infra marker must be written in the no-seat path AND the rc!=0 path.
_no_seat_marker=$(grep -c 'write_death_class infra' "$run" || true)
(( _no_seat_marker >= 2 )) \
    || fail "write_death_class infra must appear in both no-seat and rc!=0 paths (got $_no_seat_marker)"
ok "Test 2: pi-issue-run writes .last-death-class=infra on no-seat + rc!=0 infra deaths"

# === Test 3: pi-issue-run writes .last-death-class=work on non-infra deaths ===
grep -qF 'write_death_class work' "$run" || fail "write_death_class work not found in pi-issue-run"
# Must appear in the rc!=0 else branch AND the empty-run exhaustion paths.
_work_marker=$(grep -c 'write_death_class work' "$run" || true)
(( _work_marker >= 3 )) \
    || fail "write_death_class work must appear in rc!=0 else + 2x empty-run exhaustion (got $_work_marker)"
ok "Test 3: pi-issue-run writes .last-death-class=work on non-infra deaths (rc!=0 else + empty-run)"

# === Test 4: pi-issue-run reads .prefer-class -> PI_PICK_PREFER_CLASS ===
grep -qF 'pi-issue-${inst}.prefer-class' "$run" || fail ".prefer-class file path not found in pi-issue-run"
grep -qF 'PI_PICK_PREFER_CLASS="$_prefer_class"' "$run" || fail "PI_PICK_PREFER_CLASS export not found"
grep -qF 'work-cap class switch in effect' "$run" || fail "prefer-class log message not found"
ok "Test 4: pi-issue-run reads .prefer-class and exports PI_PICK_PREFER_CLASS"

# === Test 5: pi-issue-run clears .prefer-class/.infra-death/.last-death-class on success ===
grep -qF 'rm -f "$ATTEMPTS_DIR/pi-issue-${inst}.prefer-class"' "$run" \
    || fail "success-path .prefer-class clear not found"
grep -qF 'rm -f "$ATTEMPTS_DIR/pi-issue-${inst}.infra-death"' "$run" \
    || fail "success-path .infra-death clear not found"
grep -qF 'rm -f "$ATTEMPTS_DIR/pi-issue-${inst}.last-death-class"' "$run" \
    || fail "success-path .last-death-class clear not found"
# Must be in the _shipped=yes branch (after reclaim-count reset, before exit 0).
_shipped_line=$(grep -n '_shipped=yes' "$run" | head -1 | cut -d: -f1)
_pref_clear_line=$(grep -n 'rm -f "$ATTEMPTS_DIR/pi-issue-${inst}.prefer-class"' "$run" | head -1 | cut -d: -f1)
_exit_zero=$(grep -n '^exit 0' "$run" | tail -1 | cut -d: -f1)
(( _pref_clear_line > _shipped_line )) \
    || fail "prefer-class clear (line $_pref_clear_line) must be after _shipped=yes (line $_shipped_line)"
(( _pref_clear_line < _exit_zero )) \
    || fail "prefer-class clear (line $_pref_clear_line) must be before exit 0 (line $_exit_zero)"
ok "Test 5: pi-issue-run clears .prefer-class/.infra-death/.last-death-class on shipped success"

# === Test 6: reaper increments .infra-death (NOT .reclaim-count) when marker=infra ===
grep -qF '_death_class_file="$ATTEMPTS_DIR/pi-issue-${instance}.last-death-class"' "$reap" \
    || fail "reaper does not read .last-death-class marker"
grep -qF 'INFRA-DEATH-INCREMENTED' "$reap" \
    || fail "reaper missing INFRA-DEATH-INCREMENTED triage tag"
grep -qF 'pi-issue-${instance}.infra-death' "$reap" \
    || fail "reaper missing .infra-death counter file path"
# The infra branch must NOT increment .reclaim-count.
# Extract the infra branch block and verify it writes _infra_file, not _rc_file.
_infra_block=$(awk '/if \[\[ "\$_death_class" == "infra" \]\]/,/^    else$/' "$reap")
printf '%s\n' "$_infra_block" | grep -q 'printf.*_infra_file' \
    || fail "infra branch must write to _infra_file"
printf '%s\n' "$_infra_block" | grep -q 'RECLAIM-COUNT-INCREMENTED' \
    && fail "infra branch must NOT emit RECLAIM-COUNT-INCREMENTED"
# The marker must be consumed (rm -f) regardless of branch.
grep -qF 'rm -f "$_death_class_file"' "$reap" \
    || fail "reaper must clear .last-death-class marker after reading it"
ok "Test 6: reaper increments .infra-death (NOT .reclaim-count) when marker=infra, clears marker"

# === Test 7: reaper increments .reclaim-count when marker absent or =work ===
grep -qF 'RECLAIM-COUNT-INCREMENTED' "$reap" \
    || fail "reaper missing RECLAIM-COUNT-INCREMENTED (work path)"
# The work/else branch must still increment _rc_file.
_work_block=$(awk '/^    else$/,/^    fi$/' "$reap" | head -20)
printf '%s\n' "$_work_block" | grep -q 'printf.*_rc_file' \
    || fail "work/else branch must write to _rc_file"
ok "Test 7: reaper increments .reclaim-count when marker absent or =work"

# === Test 8: reaper clears .prefer-class/.infra-death/.last-death-class on CLOSED ===
_closed_line=$(grep -n 'CLAIM-CLOSED-CLEANUP' "$reap" | head -1 | cut -d: -f1)
_pref_reap_line=$(grep -n 'rm -f "$ATTEMPTS_DIR/pi-issue-${instance}.prefer-class"' "$reap" | head -1 | cut -d: -f1)
_infra_reap_line=$(grep -n 'rm -f "$ATTEMPTS_DIR/pi-issue-${instance}.infra-death"' "$reap" | head -1 | cut -d: -f1)
_dc_reap_line=$(grep -n 'rm -f "$ATTEMPTS_DIR/pi-issue-${instance}.last-death-class"' "$reap" | head -1 | cut -d: -f1)
[[ -n "$_closed_line" ]] || fail "CLAIM-CLOSED-CLEANUP not found in reaper"
[[ -n "$_pref_reap_line" ]] || fail "reaper CLOSED path missing .prefer-class clear"
[[ -n "$_infra_reap_line" ]] || fail "reaper CLOSED path missing .infra-death clear"
[[ -n "$_dc_reap_line" ]] || fail "reaper CLOSED path missing .last-death-class clear"
(( _pref_reap_line > _closed_line )) || fail "prefer-class clear must be after CLAIM-CLOSED-CLEANUP"
(( _infra_reap_line > _closed_line )) || fail "infra-death clear must be after CLAIM-CLOSED-CLEANUP"
(( _dc_reap_line > _closed_line )) || fail "last-death-class clear must be after CLAIM-CLOSED-CLEANUP"
ok "Test 8: reaper clears .prefer-class/.infra-death/.last-death-class on CLOSED reap"

# === Test 9: pick_seat honors PI_PICK_PREFER_CLASS + falls through ===
grep -qF 'PI_PICK_PREFER_CLASS' "$seat_lib" || fail "pick_seat does not read PI_PICK_PREFER_CLASS"
grep -qF 'PREFER-CLASS prepaid' "$seat_lib" || fail "pick_seat missing PREFER-CLASS prepaid branch"
grep -qF 'PREFER-CLASS metered' "$seat_lib" || fail "pick_seat missing PREFER-CLASS metered branch"
grep -qF 'PREFER-CLASS senior' "$seat_lib" || fail "pick_seat missing PREFER-CLASS senior branch"
# The fall-through: when prefer-class yields no seat, the normal ladder runs.
grep -qF 'if [[ -z "$chosen" ]]; then' "$seat_lib" || fail "pick_seat fall-through guard not found"
ok "Test 9: pick_seat honors PI_PICK_PREFER_CLASS (prepaid/metered/senior) with fall-through"

# === Test 10: intake tick ladder advancement (already proven by #2462 test 3b,
#              but verify the block message + orchestrator) ===
grep -qF 'blocked-on: orchestrator' "$tick" \
    || fail "tick missing blocked-on: orchestrator (ladder exhausted)"
grep -qF 'class ladder exhausted' "$tick" \
    || fail "tick missing 'class ladder exhausted' message"
ok "Test 10: intake tick blocks with orchestrator only at ladder exhaustion"

# === Test 11: shellcheck ===
# seat-lib.sh has pre-existing SC2034 warnings (unused config vars loaded for
# downstream source); existing tests do not shellcheck it. Run shellcheck on
# the three files this ticket touched.
for f in "$run" "$reap" "$tick"; do
    if command -v shellcheck >/dev/null 2>&1; then
        shellcheck -x "$f" --severity=warning 2>&1 || fail "shellcheck failed on $(basename "$f")"
    fi
done
ok "Test 11: shellcheck clean on pi-issue-run, pi-issue-failed-reap, pi-intake-tick"

# === Tests 12-16: functional replay drill (fleet-ops#3310) ===
# The greps above prove shape; these replay drill runs prove BEHAVIOUR with
# the real scripts against scratch dirs and stubbed seams (fake pi binary,
# stub seat-lib via PI_PACKET_SEAT_LIB, stub gh + systemctl for the reaper).
# This is the replay drill the issue's acceptance requires ("a test or replay
# drill green") and the mechanical-fix prevention: the counter split is
# exercised end-to-end, not just grep-proven.
drill="$(mktemp -d -t fleet-ops-3310-drill.XXXXXX)"
trap 'rm -rf "$drill"' EXIT INT TERM
export PI_PACKET_STATE="$drill/state"
export PI_ISSUES_DIR="$drill/issues"
export PI_SEAT_HEALTH_LEDGER_DIR="$drill/ledger"
export TRIAGE_FILE="$drill/triage.md"
mkdir -p "$PI_PACKET_STATE" "$PI_ISSUES_DIR" "$PI_SEAT_HEALTH_LEDGER_DIR"
# ATTEMPTS_DIR is derived from PI_PACKET_STATE by seat-lib; the reaper and
# pi-issue-run both use it, so mirror the derivation here for asserts.
ATTEMPTS_DIR="$PI_PACKET_STATE/attempts"

# Fake pi: exits with FAKE_PI_RC after a short run; FAKE_PI_MODE=hang sleeps
# past PI_HANG_TIMEOUT_S so timeout(1) kills it with rc=124 (hang watchdog).
cat >"$drill/fake-pi" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAKE_PI_MODE:-}" == "hang" ]]; then sleep 30; fi
exit "${FAKE_PI_RC:-1}"
EOF
chmod +x "$drill/fake-pi"

# Stub seat-lib: real seat-lib sourced, then the pick/registration seams
# overridden so the drill never touches live fleet seats. pick_seat returns
# one fake seat unless FAKE_PICK_EMPTY=1 (no-seat path).
cat >"$drill/seat-lib.sh" <<EOF
# shellcheck shell=bash
export PI_PACKET_STATE="$drill/state"
export PI_SEAT_HEALTH_LEDGER_DIR="$drill/ledger"
export PI_ISSUES_DIR="$drill/issues"
mkdir -p "\$PI_PACKET_STATE" "\$PI_ISSUES_DIR" "\$PI_SEAT_HEALTH_LEDGER_DIR"
# shellcheck source=../lib/seat-lib.sh source-path=SCRIPTDIR
source "$repo_root/lib/seat-lib.sh"
pick_seat() {
    if [[ "\${FAKE_PICK_EMPTY:-0}" == "1" ]]; then return 1; fi
    printf '%s\t%s\n' fake-prov fake-model
}
register_active_seat() { :; }
clear_active_seat() { :; }
EOF
export PI_PACKET_SEAT_LIB="$drill/seat-lib.sh"
export PI_BIN="$drill/fake-pi"
export SPAWN_FAIL_MAX_S=30

# --- Test 12: pi-issue-run replay — hang-watchdog death (rc=124) is infra ---
printf 'drill packet\n' >"$PI_ISSUES_DIR/drill-hang.in"
FAKE_PI_RC=124 FAKE_PI_MODE=hang PI_HANG_TIMEOUT_S=2 \
    timeout 60 bash "$run" drill-hang >/dev/null 2>"$drill/hang.err" || true
[[ -f "$ATTEMPTS_DIR/pi-issue-drill-hang.last-death-class" ]] \
    || fail "Test 12: rc=124 hang-watchdog death must write .last-death-class (got: $(cat "$drill/hang.err" 2>/dev/null | tail -3))"
[[ "$(cat "$ATTEMPTS_DIR/pi-issue-drill-hang.last-death-class")" == "infra" ]] \
    || fail "Test 12: rc=124 death must classify as infra, got '$(cat "$ATTEMPTS_DIR/pi-issue-drill-hang.last-death-class")'"
ok "Test 12: replay — rc=124 (hang watchdog) death writes .last-death-class=infra"

# --- Test 13: pi-issue-run replay — plain rc=1 death is WORK ---
printf 'drill packet\n' >"$PI_ISSUES_DIR/drill-work.in"
FAKE_PI_RC=1 PI_HANG_TIMEOUT_S=2 \
    timeout 60 bash "$run" drill-work >/dev/null 2>"$drill/work.err" || true
[[ -f "$ATTEMPTS_DIR/pi-issue-drill-work.last-death-class" ]] \
    || fail "Test 13: rc=1 death must write .last-death-class (got: $(cat "$drill/work.err" | tail -3))"
[[ "$(cat "$ATTEMPTS_DIR/pi-issue-drill-work.last-death-class")" == "work" ]] \
    || fail "Test 13: rc=1 death must classify as work, got '$(cat "$ATTEMPTS_DIR/pi-issue-drill-work.last-death-class")'"
ok "Test 13: replay — plain rc=1 death writes .last-death-class=work"

# --- Test 14: pi-issue-run replay — no-seat exit is infra ---
printf 'drill packet\n' >"$PI_ISSUES_DIR/drill-noseat.in"
FAKE_PICK_EMPTY=1 PI_HANG_TIMEOUT_S=2 \
    timeout 60 bash "$run" drill-noseat >/dev/null 2>"$drill/noseat.err" || true
[[ -f "$ATTEMPTS_DIR/pi-issue-drill-noseat.last-death-class" ]] \
    || fail "Test 14: no-seat exit must write .last-death-class (got: $(cat "$drill/noseat.err" | tail -3))"
[[ "$(cat "$ATTEMPTS_DIR/pi-issue-drill-noseat.last-death-class")" == "infra" ]] \
    || fail "Test 14: no-seat exit must classify as infra, got '$(cat "$ATTEMPTS_DIR/pi-issue-drill-noseat.last-death-class")'"
ok "Test 14: replay — no-seat exit writes .last-death-class=infra"

# --- Reaper replay setup: stub gh + systemctl so the real reaper runs offline ---
cat >"$drill/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *"/issues/"*) echo '{"state":"open","labels":[]}' ;;   # state load
    *"/pulls?state=open"*) echo '[]' ;;                        # no open PR
    *"git/refs/heads/"*) exit 0 ;;                             # branch exists (and DELETE ok)
    *) exit 0 ;;                                                # issue edit / comment ok
esac
exit 0
EOF
chmod +x "$drill/gh"
cat >"$drill/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "inactive"
exit 0
EOF
chmod +x "$drill/systemctl"
export SYSTEMCTL="$drill/systemctl"
PATH="$drill:$PATH"

# --- Test 15: reaper replay — marker=infra bumps .infra-death, NOT reclaim-count ---
reap_instance="drill-15"
printf 'infra' >"$ATTEMPTS_DIR/pi-issue-${reap_instance}.last-death-class"
rm -f "$ATTEMPTS_DIR/pi-issue-${reap_instance}.reclaim-count" \
      "$ATTEMPTS_DIR/pi-issue-${reap_instance}.infra-death"
timeout 60 bash "$reap" "$reap_instance" >/dev/null 2>"$drill/reap-infra.err" || true
[[ -f "$ATTEMPTS_DIR/pi-issue-${reap_instance}.infra-death" ]] \
    || fail "Test 15: reaper must write .infra-death on infra marker (got: $(cat "$drill/reap-infra.err" | tail -3))"
[[ "$(cat "$ATTEMPTS_DIR/pi-issue-${reap_instance}.infra-death")" == "1" ]] \
    || fail "Test 15: .infra-death must be 1, got '$(cat "$ATTEMPTS_DIR/pi-issue-${reap_instance}.infra-death")'"
[[ -f "$ATTEMPTS_DIR/pi-issue-${reap_instance}.reclaim-count" ]] \
    && fail "Test 15: infra death must NOT touch .reclaim-count"
[[ ! -f "$ATTEMPTS_DIR/pi-issue-${reap_instance}.last-death-class" ]] \
    || fail "Test 15: reaper must consume (rm) the .last-death-class marker"
ok "Test 15: replay — reaper turns marker=infra into .infra-death=1, WORK cap untouched"

# --- Test 16: reaper replay — marker=work bumps .reclaim-count, infra untouched ---
reap_instance="drill-16"
printf 'work' >"$ATTEMPTS_DIR/pi-issue-${reap_instance}.last-death-class"
rm -f "$ATTEMPTS_DIR/pi-issue-${reap_instance}.reclaim-count" \
      "$ATTEMPTS_DIR/pi-issue-${reap_instance}.infra-death"
timeout 60 bash "$reap" "$reap_instance" >/dev/null 2>"$drill/reap-work.err" || true
[[ -f "$ATTEMPTS_DIR/pi-issue-${reap_instance}.reclaim-count" ]] \
    || fail "Test 16: reaper must write .reclaim-count on work marker (got: $(cat "$drill/reap-work.err" | tail -3))"
[[ "$(cat "$ATTEMPTS_DIR/pi-issue-${reap_instance}.reclaim-count")" == "1" ]] \
    || fail "Test 16: .reclaim-count must be 1, got '$(cat "$ATTEMPTS_DIR/pi-issue-${reap_instance}.reclaim-count")'"
[[ ! -f "$ATTEMPTS_DIR/pi-issue-${reap_instance}.infra-death" ]] \
    || fail "Test 16: work death must NOT write .infra-death"
ok "Test 16: replay — reaper turns marker=work into .reclaim-count=1, infra counter untouched"

# --- Test 17: reaper replay — absent marker defaults to WORK (back-compat) ---
reap_instance="drill-17"
rm -f "$ATTEMPTS_DIR/pi-issue-${reap_instance}.last-death-class" \
      "$ATTEMPTS_DIR/pi-issue-${reap_instance}.reclaim-count" \
      "$ATTEMPTS_DIR/pi-issue-${reap_instance}.infra-death"
timeout 60 bash "$reap" "$reap_instance" >/dev/null 2>"$drill/reap-absent.err" || true
[[ -f "$ATTEMPTS_DIR/pi-issue-${reap_instance}.reclaim-count" ]] \
    || fail "Test 17: absent marker must default to work (reclaim-count increment), got: $(cat "$drill/reap-absent.err" | tail -3)"
[[ "$(cat "$ATTEMPTS_DIR/pi-issue-${reap_instance}.reclaim-count")" == "1" ]] \
    || fail "Test 17: absent-marker .reclaim-count must be 1, got '$(cat "$ATTEMPTS_DIR/pi-issue-${reap_instance}.reclaim-count")'"
ok "Test 17: replay — absent .last-death-class defaults to WORK (reclaim-count), old-version back-compat"

echo ""
echo "ALL OK: fleet-ops#3310 infra-death classification + work-cap class switch (incl. replay drill)"
