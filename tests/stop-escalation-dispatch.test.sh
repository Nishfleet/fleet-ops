#!/usr/bin/env bash
# tests/stop-escalation-dispatch.test.sh
#
# Proves the SENIOR-AUDITOR dispatcher from fleet-ops#34 and #95:
#   - a fully-walled ladder reaches NISH (loud fail-loud escalation)
#   - a healthy seat dispatches the auditor and writes a diagnosis block
#   - a timeout / empty / failed dispatch does NOT consume the 2-dispatch budget
#   - the 2-dispatch cap is enforced
#   - a transient ladder blip (rate_limited / transient_fault, dead=false,
#     not poison) is re-picked once after a bounded delay; dispatch on
#     recovery writes NO NISH line
#   - dead=true or poison_ladder=true fails loud immediately (no wait)
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

LEDGER="$scratch/ledgers"
mkdir -p "$LEDGER"
export PI_SEAT_HEALTH_LEDGER_DIR="$LEDGER"

write_ledger() {
  # $1=stem $2=health_class $3=seat_dead $4=poison_ladder $5=retry_after-or-empty
  local stem="$1" hc="$2" dead="$3" poison="$4" retry="${5:-}"
  local retry_json="null"
  [[ -n "$retry" ]] && retry_json="$retry"
  cat >"$LEDGER/${stem}.json" <<JSON
{"health_class":"$hc","seat_dead":$dead,"poison_ladder":$poison,"retry_after":$retry_json,"observed_at":"2026-08-26T00:00:00Z"}
JSON
}

clear_ledgers() { rm -f "$LEDGER"/*.json; }

PICK_COUNT_FILE="$scratch/pick-count"
: >"$PICK_COUNT_FILE"

SEAT_LIB_STUB="$scratch/seat-lib-stub.sh"
cat >"$SEAT_LIB_STUB" <<EOF
#!/usr/bin/env bash
pick_seat() {
  local n=0
  if [ -f "$PICK_COUNT_FILE" ]; then
    n=\$(cat "$PICK_COUNT_FILE" 2>/dev/null || echo 0)
  fi
  n=\$((n + 1))
  printf '%s\\n' "\$n" > "$PICK_COUNT_FILE"
  case "\${STOP_ESCALATION_TEST_SEAT_MODE:-healthy}" in
    empty) return 1 ;;
    blip)
      if [ "\$n" -eq 1 ]; then return 1; fi
      printf 'devin\\tglm-5-2\\n'
      ;;
    transient_persist) return 1 ;;
    dead) return 1 ;;
    poison) return 1 ;;
    healthy) printf 'devin\\tglm-5-2\\n' ;;
    second) printf 'cursor\\tsonnet-4\\n' ;;
    *) printf 'devin\\tglm-5-2\\n' ;;
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
export STOP_ESCALATION_NISH="$AS/NISH-ESCALATIONS.md"
export STOP_ESCALATION_AUDITOR_LOG="$AS/AUDITOR-LOG.md"
export STOP_ESCALATION_PI_BIN="$PI_STUB"
export PI_PACKET_SEAT_LIB="$SEAT_LIB_STUB"
export STOP_ESCALATION_AUDITOR_TIMEOUT=2
export STOP_ESCALATION_COOLDOWN=0
export STOP_ESCALATION_DRY_RUN=0
# Fast re-pick in tests. Production default is 30s, clamped to [5,60] when
# the delay comes from an untrusted ledger retry_after.
export STOP_ESCALATION_TRANSIENT_DELAY=1

# ---------------------------------------------------------------------------
# Invariant 1: fully-walled ladder -> LADDER-WALLED in NISH, no AUDITOR dispatch
# ---------------------------------------------------------------------------
export STOP_ESCALATION_TEST_SEAT_MODE=empty
start=$(date +%s)
set +e
"$dispatch"; rc=$?
set -e
elapsed=$(( $(date +%s) - start ))
[[ $rc -eq 1 ]] || fail "empty ladder: expected exit 1, got $rc"
[[ -s "$STOP_ESCALATION_NISH" ]] || fail "empty ladder: NISH-ESCALATIONS should not be empty"
grep -q 'LADDER-WALLED' "$STOP_ESCALATION_NISH" || fail "empty ladder: expected LADDER-WALLED in NISH"
[[ ! -s "$STOP_ESCALATION_SEEN" ]] || fail "empty ladder: must not consume dispatch budget"
[[ "$elapsed" -lt 4 ]] || fail "empty ladder with no transient evidence must not wait, took ${elapsed}s"
ok "fully-walled ladder -> LADDER-WALLED (no NISH on a healthy seat)"

: > "$STOP_ESCALATION_NISH"

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
# fleet-ops#95: transient ladder blip is re-picked once; hard-down is immediate
# ---------------------------------------------------------------------------
reset_dispatch_state() {
  : > "$STOP_ESCALATION_SEEN"
  : > "$STOP_ESCALATION_AUDITOR_LOG"
  : > "$STOP_ESCALATION_NISH"
  : > "$PICK_COUNT_FILE"
  rm -rf "$AS/stop-escalation-tried"
  clear_ledgers
}

# A: rate_limited ledger, pick_seat empty then healthy -> dispatch, no NISH
reset_dispatch_state
cat >"$STOP_ESCALATION_STOP_REASON" <<'JSON'
{"reason":"unit-failure","detail":{"unit":"pi-issue@fleet-ops-95a.service"}}
JSON
write_ledger "devin__glm-5-2" "rate_limited" "false" "false" "1"
export STOP_ESCALATION_TEST_SEAT_MODE=blip
export STOP_ESCALATION_TEST_PI_MODE=block
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "A: clearing blip must exit 0, got $rc"
[[ ! -s "$STOP_ESCALATION_NISH" ]] || fail "A: clearing blip must NOT write a NISH line; got $(cat "$STOP_ESCALATION_NISH")"
grep -q 'dispatched auditor' "$STOP_ESCALATION_AUDITOR_LOG" || fail "A: must dispatch on recovery"
count=$(awk -v h="$(sha256sum "$STOP_ESCALATION_STOP_REASON" | awk '{print $1}')" '$1==h{print $2}' "$STOP_ESCALATION_SEEN")
[[ "$count" == "1" ]] || fail "A: budget must be 1 after dispatch, got '$count'"
ok "A: transient blip clears within re-pick -> dispatched, no NISH line, budget=1"

# B: dead=true -> fail loud immediately, LADDER-WALLED, no dispatch
reset_dispatch_state
cat >"$STOP_ESCALATION_STOP_REASON" <<'JSON'
{"reason":"unit-failure","detail":{"unit":"pi-issue@fleet-ops-95b.service"}}
JSON
write_ledger "devin__glm-5-2" "dead" "true" "false" ""
export STOP_ESCALATION_TEST_SEAT_MODE=dead
start=$(date +%s)
set +e
"$dispatch"; rc=$?
set -e
elapsed=$(( $(date +%s) - start ))
[[ $rc -eq 1 ]] || fail "B: dead=true must exit 1, got $rc"
[[ "$elapsed" -lt 4 ]] || fail "B: dead=true must fail immediately (no re-pick wait), took ${elapsed}s"
grep -q 'LADDER-WALLED' "$STOP_ESCALATION_NISH" || fail "B: dead=true must write LADDER-WALLED; got $(cat "$STOP_ESCALATION_NISH")"
grep -q 'dispatched auditor' "$STOP_ESCALATION_AUDITOR_LOG" && fail "B: dead=true must NOT dispatch"
ok "B: dead=true -> fail loud immediately, LADDER-WALLED, exit 1, no dispatch"

# C: poison_ladder=true -> fail loud immediately, no wait
reset_dispatch_state
cat >"$STOP_ESCALATION_STOP_REASON" <<'JSON'
{"reason":"unit-failure","detail":{"unit":"pi-issue@fleet-ops-95c.service"}}
JSON
write_ledger "devin__glm-5-2" "poison_ladder" "false" "true" ""
export STOP_ESCALATION_TEST_SEAT_MODE=poison
start=$(date +%s)
set +e
"$dispatch"; rc=$?
set -e
elapsed=$(( $(date +%s) - start ))
[[ $rc -eq 1 ]] || fail "C: poison_ladder must exit 1, got $rc"
[[ "$elapsed" -lt 4 ]] || fail "C: poison_ladder must fail immediately, took ${elapsed}s"
grep -q 'LADDER-WALLED' "$STOP_ESCALATION_NISH" || fail "C: poison_ladder must write LADDER-WALLED"
grep -q 'dispatched auditor' "$STOP_ESCALATION_AUDITOR_LOG" && fail "C: poison_ladder must NOT dispatch"
ok "C: poison_ladder=true -> fail loud immediately, LADDER-WALLED, exit 1"

# D: rate_limited that does not clear -> LADDER-WALLED after one re-pick, no dispatch
reset_dispatch_state
cat >"$STOP_ESCALATION_STOP_REASON" <<'JSON'
{"reason":"unit-failure","detail":{"unit":"pi-issue@fleet-ops-95d.service"}}
JSON
write_ledger "devin__glm-5-2" "rate_limited" "false" "false" "1"
export STOP_ESCALATION_TEST_SEAT_MODE=transient_persist
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 1 ]] || fail "D: persistent unhealth must exit 1, got $rc"
grep -q 'LADDER-WALLED' "$STOP_ESCALATION_NISH" || fail "D: persistent unhealth must write LADDER-WALLED"
grep -q 'dispatched auditor' "$STOP_ESCALATION_AUDITOR_LOG" && fail "D: persistent unhealth must NOT dispatch"
ok "D: transient blip that does not clear -> LADDER-WALLED, exit 1, no dispatch"

ok "stop-escalation-dispatch: lane faults rotate, blips re-pick, timeout/no-block fail loud, cap enforced"
