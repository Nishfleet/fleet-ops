#!/usr/bin/env bash
# tests/heartbeat-watchman-system-scope.test.sh
#
# fleet-ops#1570: claude-telegram-watchdog.service (a SYSTEM-scope oneshot)
# failed at 2026-08-28T12:30Z, but the heartbeat's failed-unit watcher only
# scanned `systemctl --user --state=failed`, so system-scope failures were
# invisible — no triage line, no tier-2 dispatch, no agent repair. The unit
# sat failed until a human noticed and filed this issue.
#
# Root cause of the unit failure itself: the watchdog script exited 1 after a
# SUCCESSFUL bridge restart (log_and_restart took exit 1 on the success path),
# so every green restart landed the oneshot in 'failed'. That script bug was
# fixed live on 2026-08-29 (exit 0 on success). This test pins the STRUCTURAL
# fix that belongs in fleet-ops: the watcher now covers system scope.
#
# This test pins:
#   A. heartbeat_list_failed_units emits --system failed units, prefixed
#      "system:", alongside the --user list. A system-scope failure is no
#      longer invisible.
#   B. heartbeat_repair_unit does NOT reset-failed/start system-scope units.
#      Auto-restarting arbitrary host services is unsafe (it can mask a real
#      fault or start a service that should stay down); system failures are
#      surfaced for tier 2 / the unit-escalation drop-in to diagnose.
#   C. heartbeat_process_failed_units surfaces a still-failed system unit to
#      triage as UNIT-FAILED (the dispatch path for tier 2), never telegrams
#      Nish directly.
#   D. The source carries the system-scope listing and the surface-only
#      guard, so a future refactor cannot silently drop either.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/heartbeat-watchman.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
chmod +x "$lib"

scratch="$(mktemp -d -t heartbeat-wm-sys.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

fake="$scratch/bin"
mkdir -p "$fake"
triage="$scratch/triage.md"
: >"$triage"

# fake journalctl — excerpt per unit
cat >"$fake/journalctl" <<'FAKE'
#!/usr/bin/env bash
echo "journal excerpt for fake unit"
exit 0
FAKE
chmod +x "$fake/journalctl"

# fake systemctl — keeps --user and --system failed lists SEPARATE so the
# test can prove system scope is scanned independently of user scope.
# Files: USER_FAILED (one unit/line) and SYSTEM_FAILED (one unit/line).
cat >"$fake/systemctl" <<'FAKE'
#!/usr/bin/env bash
scope="$1"; shift   # --user | --system
cmd="$1"; shift || true
if [ "$cmd" = "list-units" ]; then
  cmd="$1"; shift || true
fi
case "$scope:$cmd" in
  --user:--state=failed)
    if [[ -s "$USER_FAILED" ]]; then
      while IFS= read -r u; do
        [ -z "$u" ] && continue
        printf '%s loaded failed failed\tfake\n' "$u"
      done <"$USER_FAILED"
    fi
    exit 0
    ;;
  --system:--state=failed)
    if [[ -s "$SYSTEM_FAILED" ]]; then
      while IFS= read -r u; do
        [ -z "$u" ] && continue
        printf '%s loaded failed failed\tfake\n' "$u"
      done <"$SYSTEM_FAILED"
    fi
    exit 0
    ;;
  --user:reset-failed)
    printf 'user reset-failed %s\n' "${1:-}" >>"$SYSTEMCTL_LOG"
    exit 0
    ;;
  --user:start)
    printf 'user start %s\n' "${1:-}" >>"$SYSTEMCTL_LOG"
    exit 0
    ;;
  --system:reset-failed|--system:start)
    # Must never happen for system scope (surface-only). Record it so the
    # test can fail loudly if the guard is dropped.
    printf 'SYSTEM-REPAIR-ATTEMPT %s %s\n' "$cmd" "${1:-}" >>"$SYSTEMCTL_LOG"
    exit 0
    ;;
  *)
    printf 'unexpected systemctl: scope=%s cmd=%s args=%s\n' "$scope" "$cmd" "$*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$fake/systemctl"

export JOURNALCTL="$fake/journalctl"
export SYSTEMCTL="$fake/systemctl"
export SYSTEMCTL_LOG="$scratch/systemctl.log"
export USER_FAILED="$scratch/user-failed.units"
export SYSTEM_FAILED="$scratch/system-failed.units"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export FLEET_SEAT_HEALTH="$scratch/seat.json"
export FLEET_SEAT_HEALTH_MAX_AGE_SEC=5400
export PI_TRANSPORT_CHECK_UNIT="pi-transport-check.service"
# Suppress the dead-man ping path (not under test).
unset HC_URL || true

run_wm() { "$lib" "$@"; }

# ============================================================================
# A. heartbeat_list_failed_units emits system-scope units, prefixed system:
# ============================================================================
: >"$USER_FAILED"; : >"$SYSTEM_FAILED"
printf 'claude-telegram-watchdog.service\n' >"$SYSTEM_FAILED"
out=$(bash -c "source '$lib'; heartbeat_list_failed_units")
printf '%s' "$out" | grep -qx 'system:claude-telegram-watchdog.service' \
  || fail "heartbeat_list_failed_units must emit system-scope unit prefixed system: — got: $out"
ok "list: system-scope failed unit is emitted (system: prefix)"

# A user-scope unit and a system-scope unit both appear, in their own form.
printf 'pi-issue@fleet-ops-1.service\n' >"$USER_FAILED"
printf 'claude-telegram-watchdog.service\n' >"$SYSTEM_FAILED"
out=$(bash -c "source '$lib'; heartbeat_list_failed_units")
printf '%s' "$out" | grep -qx 'pi-issue@fleet-ops-1.service' \
  || fail "user unit must still appear un-prefixed — got: $out"
printf '%s' "$out" | grep -qx 'system:claude-telegram-watchdog.service' \
  || fail "system unit must appear prefixed — got: $out"
ok "list: user and system scopes both covered"

# Empty system scope -> no system: lines, no crash.
: >"$SYSTEM_FAILED"
out=$(bash -c "source '$lib'; heartbeat_list_failed_units")
! printf '%s' "$out" | grep -q '^system:' \
  || fail "no system: lines when system scope is empty — got: $out"
ok "list: empty system scope emits no system: lines"

# ============================================================================
# B. heartbeat_repair_unit never reset-failed/starts system-scope units
# ============================================================================
: >"$SYSTEMCTL_LOG"
bash -c "source '$lib'; heartbeat_repair_unit 'system:claude-telegram-watchdog.service'"
! grep -q 'SYSTEM-REPAIR-ATTEMPT' "$SYSTEMCTL_LOG" \
  || fail "heartbeat_repair_unit must NOT reset-failed/start system units: $(cat "$SYSTEMCTL_LOG")"
! grep -qE 'user (reset-failed|start) claude-telegram' "$SYSTEMCTL_LOG" \
  || fail "system unit must not be routed to --user repair: $(cat "$SYSTEMCTL_LOG")"
ok "repair: system-scope unit is NOT auto-repaired (surface-only)"

# A user-scope unit IS repaired (regression guard: the new branch must not
# break the existing user-scope floor).
: >"$SYSTEMCTL_LOG"
bash -c "source '$lib'; heartbeat_repair_unit 'pi-issue@fleet-ops-1.service'"
grep -q 'user reset-failed pi-issue@fleet-ops-1.service' "$SYSTEMCTL_LOG" \
  || fail "user unit must still be reset-failed: $(cat "$SYSTEMCTL_LOG")"
grep -q 'user start pi-issue@fleet-ops-1.service' "$SYSTEMCTL_LOG" \
  || fail "user unit must still be started: $(cat "$SYSTEMCTL_LOG")"
ok "repair: user-scope floor unchanged"

# ============================================================================
# C. process-failed surfaces a still-failed system unit to triage (UNIT-FAILED)
#    and never telegrams Nish directly
# ============================================================================
: >"$SYSTEMCTL_LOG"; : >"$triage"
: >"$USER_FAILED"
printf 'claude-telegram-watchdog.service\n' >"$SYSTEM_FAILED"
# No HERMES fake is exported; if the watchman tried to telegram, it would call
# the real hermes and fail loudly. The triage file is the asserted channel.
run_wm process-failed
grep -q 'UNIT-FAILED' "$triage" \
  || fail "system failure must surface to triage as UNIT-FAILED: $(cat "$triage")"
grep -q 'system:claude-telegram-watchdog.service' "$triage" \
  || fail "triage must name the system-scope unit: $(cat "$triage")"
! grep -q 'SYSTEM-REPAIR-ATTEMPT' "$SYSTEMCTL_LOG" \
  || fail "process-failed must not auto-repair system units: $(cat "$SYSTEMCTL_LOG")"
ok "process-failed: system failure -> triage UNIT-FAILED, no auto-repair, no telegram"

# A system failure alongside a repairable user failure: the user unit is
# repaired, the system unit is surfaced. Both scopes handled in one pass.
: >"$SYSTEMCTL_LOG"; : >"$triage"
printf 'pi-issue@fleet-ops-1.service\n' >"$USER_FAILED"
printf 'claude-telegram-watchdog.service\n' >"$SYSTEM_FAILED"
# Assert the user unit was repaired (reset+start called), the system unit was
# NOT repaired, and the system unit appears in triage. (The fake does not
# clear USER_FAILED on start, so the user unit may also appear in triage —
# the invariant under test is the scope routing, not the user clear.)
run_wm process-failed
grep -q 'user reset-failed pi-issue@fleet-ops-1.service' "$SYSTEMCTL_LOG" \
  || fail "user unit must be repaired in the mixed pass: $(cat "$SYSTEMCTL_LOG")"
! grep -q 'SYSTEM-REPAIR-ATTEMPT' "$SYSTEMCTL_LOG" \
  || fail "system unit must not be repaired in the mixed pass: $(cat "$SYSTEMCTL_LOG")"
ok "process-failed: mixed user+system pass repairs user, surfaces system"

# ============================================================================
# D. Source invariants — a future refactor cannot silently drop the coverage
# ============================================================================
grep -q -- '--system list-units --state=failed' "$lib" \
  || fail "source must scan --system scope (fleet-ops#1570)"
grep -q 'system:*' "$lib" \
  || fail "source must prefix system-scope units for surface-only routing"
grep -q 'surface-only' "$lib" \
  || fail "source must document the surface-only guard for system scope"
# The old misleading "no sudo" rationale must be gone — nish has NOPASSWD sudo,
# so capability is not the reason; safety is.
! grep -qi 'no sudo' "$lib" \
  || fail "source must not cite 'no sudo' as the reason (safety, not capability)"
ok "source: system-scope listing + surface-only guard present; rationale corrected"

echo "ALL OK"
