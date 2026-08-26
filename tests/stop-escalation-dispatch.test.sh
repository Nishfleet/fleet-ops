#!/usr/bin/env bash
# tests/stop-escalation-dispatch.test.sh
#
# Proves the SENIOR-AUDITOR dispatcher from fleet-ops#34 and #444:
#   - a fully-walled ladder reaches NISH (loud fail-loud escalation)
#   - a healthy seat dispatches the auditor and writes a diagnosis block
#   - a timeout / empty / failed dispatch does NOT consume the 2-dispatch budget
#   - the 2-dispatch cap is enforced
#   - auditor-resolved closeouts skip (do not re-summon)
#   - pi_rc 143/137 is KILL-RETRY (not DISPATCH-NO-BLOCK); 2 consecutive
#     kills on the same hash write KILL-ESCALATION and skip a 3rd seat
#
# Runs entirely offline with stubbed seat-lib.sh and a fake `pi` binary.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
dispatch="$repo_root/bin/stop-escalation-dispatch"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

echo "=== dispatcher: $dispatch ==="
[[ -x "$dispatch" ]] || fail "stop-escalation-dispatch not executable"

scratch="$(mktemp -d -t stop-escalation-test.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
export HOME="$scratch/home"
mkdir -p "$HOME"

AS="$scratch/agent-state"
mkdir -p "$AS"

cat >"$AS/STOP-REASON.json" <<'JSON'
{"reason":"unit-failure","detail":{"unit":"pi-issue@fleet-ops-34.service"}}
JSON

SEAT_LIB_STUB="$scratch/seat-lib-stub.sh"
cat >"$SEAT_LIB_STUB" <<'EOF'
#!/usr/bin/env bash
pick_seat() {
  case "${STOP_ESCALATION_TEST_SEAT_MODE:-healthy}" in
    empty) return 1 ;;
    healthy) printf 'devin\tglm-5-2\n' ;;
    second) printf 'cursor\tsonnet-4\n' ;;
    *) printf 'devin\tglm-5-2\n' ;;
  esac
}
seat_log() { :; }
EOF
chmod +x "$SEAT_LIB_STUB"

PI_STUB="$scratch/pi"
cat >"$PI_STUB" <<'EOF'
#!/usr/bin/env bash
# Fake `pi` for tests; behaviour driven by STOP_ESCALATION_TEST_PI_MODE.
mode="${STOP_ESCALATION_TEST_PI_MODE:-block}"
case "$mode" in
  block)
    # A real-looking auditor block.  Use "printf --" so the leading "---"
    # is not parsed as a printf option in the stub.
    printf -- '---\n## 2026-08-25T12:00:00Z — SENIOR AUDITOR\n**Summoning trip:** test\n**Root cause:** test cause\n**Action:** test action\n'
    exit 0
    ;;
  empty)
    # Exit 0 but write nothing (empty output)
    exit 0
    ;;
  fail)
    echo "pi: simulated provider error" >&2
    exit 1
    ;;
  timeout)
    # Will be killed by the dispatcher's internal timeout
    sleep 60
    exit 0
    ;;
  sigterm)
    # systemd SIGTERM of the auditor (128+15)
    exit 143
    ;;
  sigkill)
    # systemd SIGKILL of the auditor (128+9)
    exit 137
    ;;
  *)
    echo "pi-stub: unknown mode $mode" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$PI_STUB"

export STOP_ESCALATION_AS="$AS"
export STOP_ESCALATION_STOP_REASON="$AS/STOP-REASON.json"
export STOP_ESCALATION_SEEN="$AS/stop-escalation-seen.txt"
export STOP_ESCALATION_KILLS="$AS/stop-escalation-kills.txt"
export STOP_ESCALATION_NISH="$AS/NISH-ESCALATIONS.md"
export STOP_ESCALATION_AUDITOR_LOG="$AS/AUDITOR-LOG.md"
export STOP_ESCALATION_PI_BIN="$PI_STUB"
export PI_PACKET_SEAT_LIB="$SEAT_LIB_STUB"
export STOP_ESCALATION_AUDITOR_TIMEOUT=2
export STOP_ESCALATION_COOLDOWN=0

# ---------------------------------------------------------------------------
# Invariant 1: fully-walled ladder -> LADDER-WALLED in NISH, no AUDITOR dispatch
# ---------------------------------------------------------------------------
export STOP_ESCALATION_TEST_SEAT_MODE=empty
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 1 ]] || fail "empty ladder: expected exit 1, got $rc"
[[ -s "$STOP_ESCALATION_NISH" ]] || fail "empty ladder: NISH-ESCALATIONS should not be empty"
grep -q 'LADDER-WALLED' "$STOP_ESCALATION_NISH" || fail "empty ladder: expected LADDER-WALLED in NISH"
[[ ! -s "$STOP_ESCALATION_SEEN" ]] || fail "empty ladder: must not consume dispatch budget"
ok "fully-walled ladder -> LADDER-WALLED (no NISH on a healthy seat)"

: > "$STOP_ESCALATION_NISH"

# ---------------------------------------------------------------------------
# Invariant 1b: auditor-resolved is a closeout, not a fresh fault.
# Writing reason=auditor-resolved changes the STOP-REASON sha256, so
# PathChanged re-fires. Without this skip the closeout summons another auditor.
# ---------------------------------------------------------------------------
cat >"$STOP_ESCALATION_STOP_REASON" <<'JSON'
{"reason":"auditor-resolved","resolved_from":"unit-failure"}
JSON
export STOP_ESCALATION_TEST_SEAT_MODE=healthy
export STOP_ESCALATION_TEST_PI_MODE=block
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "auditor-resolved: expected exit 0, got $rc"
[[ ! -s "$STOP_ESCALATION_AUDITOR_LOG" ]] || fail "auditor-resolved: must not dispatch (AUDITOR-LOG should stay empty)"
[[ ! -s "$STOP_ESCALATION_SEEN" ]] || fail "auditor-resolved: must not consume dispatch budget"
[[ ! -s "$STOP_ESCALATION_NISH" ]] || fail "auditor-resolved: must not write NISH-ESCALATIONS"
ok "auditor-resolved closeout -> skip (no dispatch, no budget)"

# Restore a real fault for the remaining invariants.
cat >"$STOP_ESCALATION_STOP_REASON" <<'JSON'
{"reason":"unit-failure","detail":{"unit":"pi-issue@fleet-ops-34.service"}}
JSON

# ---------------------------------------------------------------------------
# Invariant 2: healthy seat + real block -> dispatch consumed one budget, no NISH
# ---------------------------------------------------------------------------
export STOP_ESCALATION_TEST_SEAT_MODE=healthy
export STOP_ESCALATION_TEST_PI_MODE=block
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "healthy block: expected exit 0, got $rc"
[[ ! -s "$STOP_ESCALATION_NISH" ]] || fail "healthy block: NISH-ESCALATIONS should be empty"
grep -q 'dispatched auditor' "$STOP_ESCALATION_AUDITOR_LOG" || fail "healthy block: dispatched line missing"
grep -q 'SENIOR AUDITOR' "$STOP_ESCALATION_AUDITOR_LOG" || fail "healthy block: diagnosis block missing"
count=$(awk -v h="$(sha256sum "$STOP_ESCALATION_STOP_REASON" | awk '{print $1}')" '$1==h{print $2}' "$STOP_ESCALATION_SEEN")
[[ "$count" == "1" ]] || fail "healthy block: expected SEEN count=1, got '$count'"
ok "healthy seat + block -> dispatch consumed 1 budget"

# ---------------------------------------------------------------------------
# Invariant 3: pi timeout -> TIMEOUT-KILL in AUDITOR-LOG, budget unchanged
# ---------------------------------------------------------------------------
# Use a fresh STOP-REASON so the hash differs and the cooldown doesn't apply.
cat >"$STOP_ESCALATION_STOP_REASON" <<'JSON'
{"reason":"unit-failure","detail":{"unit":"pi-issue@fleet-ops-35.service"}}
JSON

export STOP_ESCALATION_TEST_SEAT_MODE=healthy
export STOP_ESCALATION_TEST_PI_MODE=timeout
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 1 ]] || fail "timeout: expected exit 1, got $rc"
grep -q 'TIMEOUT-KILL' "$STOP_ESCALATION_AUDITOR_LOG" || fail "timeout: expected TIMEOUT-KILL in AUDITOR-LOG"
[[ ! -s "$STOP_ESCALATION_NISH" ]] || fail "timeout: NISH must stay empty on a retryable failure"
# Budget is the count for THIS hash, not the previous one.
count=$(awk -v h="$(sha256sum "$STOP_ESCALATION_STOP_REASON" | awk '{print $1}')" '$1==h{print $2}' "$STOP_ESCALATION_SEEN" 2>/dev/null || true)
[[ -z "$count" ]] || fail "timeout: must not consume dispatch budget (got count=$count)"
ok "pi timeout -> TIMEOUT-KILL, budget not consumed"

# ---------------------------------------------------------------------------
# Invariant 4: pi exit 0 with no block -> DISPATCH-NO-BLOCK, budget unchanged
# ---------------------------------------------------------------------------
cat >"$STOP_ESCALATION_STOP_REASON" <<'JSON'
{"reason":"unit-failure","detail":{"unit":"pi-issue@fleet-ops-36.service"}}
JSON

export STOP_ESCALATION_TEST_PI_MODE=empty
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 1 ]] || fail "empty output: expected exit 1, got $rc"
grep -q 'DISPATCH-NO-BLOCK' "$STOP_ESCALATION_AUDITOR_LOG" || fail "empty output: expected DISPATCH-NO-BLOCK"
[[ ! -s "$STOP_ESCALATION_NISH" ]] || fail "empty output: NISH must stay empty"
count=$(awk -v h="$(sha256sum "$STOP_ESCALATION_STOP_REASON" | awk '{print $1}')" '$1==h{print $2}' "$STOP_ESCALATION_SEEN" 2>/dev/null || true)
[[ -z "$count" ]] || fail "empty output: must not consume dispatch budget (got count=$count)"
ok "empty pi output -> DISPATCH-NO-BLOCK, budget not consumed"

# ---------------------------------------------------------------------------
# Invariant 5: two successful dispatches for same hash -> cap reached on third
# ---------------------------------------------------------------------------
# Reset to a clean state and use a stable STOP-REASON.
: > "$STOP_ESCALATION_SEEN"
: > "$STOP_ESCALATION_AUDITOR_LOG"
: > "$STOP_ESCALATION_NISH"
cat >"$STOP_ESCALATION_STOP_REASON" <<'JSON'
{"reason":"unit-failure","detail":{"unit":"pi-issue@fleet-ops-37.service"}}
JSON

for i in 1 2; do
  export STOP_ESCALATION_TEST_PI_MODE=block
  set +e
  "$dispatch"; rc=$?
  set -e
  [[ $rc -eq 0 ]] || fail "cap-prep run $i: expected exit 0, got $rc"
done

# Switch to a different provider so the stub rotates, and prove it still caps.
export STOP_ESCALATION_TEST_SEAT_MODE=second
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "cap: expected exit 0, got $rc"
grep -q 'CAP-REACHED' "$STOP_ESCALATION_NISH" || fail "cap: expected CAP-REACHED in NISH"
ok "2-dispatch cap -> CAP-REACHED in NISH"

# ---------------------------------------------------------------------------
# Invariant 6 (fleet-ops#444): pi_rc=143 is KILL-RETRY, not DISPATCH-NO-BLOCK
# ---------------------------------------------------------------------------
: > "$STOP_ESCALATION_SEEN"
: > "$STOP_ESCALATION_KILLS"
: > "$STOP_ESCALATION_AUDITOR_LOG"
: > "$STOP_ESCALATION_NISH"
cat >"$STOP_ESCALATION_STOP_REASON" <<'JSON'
{"reason":"unit-failure","detail":{"unit":"pi-issue@fleet-ops-444.service"}}
JSON
hash444=$(sha256sum "$STOP_ESCALATION_STOP_REASON" | awk '{print $1}')
export STOP_ESCALATION_TEST_SEAT_MODE=healthy
export STOP_ESCALATION_TEST_PI_MODE=sigterm
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 1 ]] || fail "sigterm: expected exit 1 on first kill, got $rc"
grep -q "KILL-RETRY hash=$hash444" "$STOP_ESCALATION_AUDITOR_LOG" \
  || fail "sigterm: expected KILL-RETRY in AUDITOR-LOG"
if grep "hash=$hash444" "$STOP_ESCALATION_AUDITOR_LOG" | grep -q 'DISPATCH-NO-BLOCK'; then
  fail "sigterm: must NOT log DISPATCH-NO-BLOCK for pi_rc=143"
fi
grep -q "pi_rc=143" "$STOP_ESCALATION_AUDITOR_LOG" || fail "sigterm: KILL-RETRY must record pi_rc=143"
grep -q "signal=SIGTERM" "$STOP_ESCALATION_AUDITOR_LOG" || fail "sigterm: KILL-RETRY must record signal=SIGTERM"
[[ ! -s "$STOP_ESCALATION_NISH" ]] || fail "sigterm: first kill must not escalate to NISH"
count=$(awk -v h="$hash444" '$1==h{print $2}' "$STOP_ESCALATION_SEEN" 2>/dev/null || true)
[[ -z "$count" ]] || fail "sigterm: must not consume dispatch budget (got count=$count)"
ok "pi_rc=143 -> KILL-RETRY, not DISPATCH-NO-BLOCK"

# ---------------------------------------------------------------------------
# Invariant 7 (fleet-ops#444): two consecutive 143 kills on the same hash
# produce KILL-ESCALATION and no 3rd dispatch attempt
# ---------------------------------------------------------------------------
# Second kill on the same STOP-REASON hash.
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "2x-sigterm: expected exit 0 after KILL-ESCALATION, got $rc"
grep -q "KILL-ESCALATION hash=$hash444" "$STOP_ESCALATION_AUDITOR_LOG" \
  || fail "2x-sigterm: expected KILL-ESCALATION in AUDITOR-LOG"
grep -q "KILL-ESCALATION hash=$hash444" "$STOP_ESCALATION_NISH" \
  || fail "2x-sigterm: expected KILL-ESCALATION in NISH-ESCALATIONS"
dispatch_count=$(grep -c "DISPATCH hash=$hash444" "$STOP_ESCALATION_AUDITOR_LOG" || true)
[[ "$dispatch_count" == "2" ]] || fail "2x-sigterm: expected 2 DISPATCH lines, got $dispatch_count"

# Third trip must skip: no extra DISPATCH, exit 0, no 3rd seat.
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "3rd-sigterm: expected exit 0 skip, got $rc"
dispatch_count=$(grep -c "DISPATCH hash=$hash444" "$STOP_ESCALATION_AUDITOR_LOG" || true)
[[ "$dispatch_count" == "2" ]] || fail "3rd-sigterm: must not dispatch a 3rd time (got $dispatch_count DISPATCH lines)"
ok "2x pi_rc=143 -> KILL-ESCALATION, no 3rd dispatch"

# ---------------------------------------------------------------------------
# Invariant 8 (fleet-ops#444): pi_rc=137 is also KILL-RETRY, not DISPATCH-NO-BLOCK
# ---------------------------------------------------------------------------
: > "$STOP_ESCALATION_SEEN"
: > "$STOP_ESCALATION_KILLS"
: > "$STOP_ESCALATION_AUDITOR_LOG"
: > "$STOP_ESCALATION_NISH"
cat >"$STOP_ESCALATION_STOP_REASON" <<'JSON'
{"reason":"unit-failure","detail":{"unit":"pi-issue@fleet-ops-444-sigkill.service"}}
JSON
hash137=$(sha256sum "$STOP_ESCALATION_STOP_REASON" | awk '{print $1}')
export STOP_ESCALATION_TEST_SEAT_MODE=healthy
export STOP_ESCALATION_TEST_PI_MODE=sigkill
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 1 ]] || fail "sigkill: expected exit 1 on first kill, got $rc"
grep -q "KILL-RETRY hash=$hash137" "$STOP_ESCALATION_AUDITOR_LOG" \
  || fail "sigkill: expected KILL-RETRY in AUDITOR-LOG"
if grep "hash=$hash137" "$STOP_ESCALATION_AUDITOR_LOG" | grep -q 'DISPATCH-NO-BLOCK'; then
  fail "sigkill: must NOT log DISPATCH-NO-BLOCK for pi_rc=137"
fi
grep -q "pi_rc=137" "$STOP_ESCALATION_AUDITOR_LOG" || fail "sigkill: KILL-RETRY must record pi_rc=137"
grep -q "signal=SIGKILL" "$STOP_ESCALATION_AUDITOR_LOG" || fail "sigkill: KILL-RETRY must record signal=SIGKILL"
ok "pi_rc=137 -> KILL-RETRY, not DISPATCH-NO-BLOCK"

# ---------------------------------------------------------------------------
# Invariant 9 (fleet-ops#444): two consecutive TIMEOUT-KILL (124) on the
# same hash also cap (KILL-ESCALATION). First 124 still logs TIMEOUT-KILL
# and exits 1 (invariant 3 unchanged).
# ---------------------------------------------------------------------------
: > "$STOP_ESCALATION_SEEN"
: > "$STOP_ESCALATION_KILLS"
: > "$STOP_ESCALATION_AUDITOR_LOG"
: > "$STOP_ESCALATION_NISH"
cat >"$STOP_ESCALATION_STOP_REASON" <<'JSON'
{"reason":"unit-failure","detail":{"unit":"pi-issue@fleet-ops-444-timeout.service"}}
JSON
hash124=$(sha256sum "$STOP_ESCALATION_STOP_REASON" | awk '{print $1}')
export STOP_ESCALATION_TEST_SEAT_MODE=healthy
export STOP_ESCALATION_TEST_PI_MODE=timeout
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 1 ]] || fail "1x-timeout: expected exit 1, got $rc"
grep -q 'TIMEOUT-KILL' "$STOP_ESCALATION_AUDITOR_LOG" || fail "1x-timeout: expected TIMEOUT-KILL"
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "2x-timeout: expected exit 0 after KILL-ESCALATION, got $rc"
grep -q "KILL-ESCALATION hash=$hash124" "$STOP_ESCALATION_AUDITOR_LOG" \
  || fail "2x-timeout: expected KILL-ESCALATION in AUDITOR-LOG"
grep -q "KILL-ESCALATION hash=$hash124" "$STOP_ESCALATION_NISH" \
  || fail "2x-timeout: expected KILL-ESCALATION in NISH-ESCALATIONS"
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "3rd-timeout: expected exit 0 skip, got $rc"
dispatch_count=$(grep -c "DISPATCH hash=$hash124" "$STOP_ESCALATION_AUDITOR_LOG" || true)
[[ "$dispatch_count" == "2" ]] || fail "3rd-timeout: must not dispatch a 3rd time (got $dispatch_count DISPATCH lines)"
ok "2x pi_rc=124 -> KILL-ESCALATION, no 3rd dispatch"

ok "stop-escalation-dispatch: lane faults rotate, timeout/no-block fail loud, cap enforced, kill-retry capped"
