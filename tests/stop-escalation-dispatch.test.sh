#!/usr/bin/env bash
# tests/stop-escalation-dispatch.test.sh
#
# Proves the SENIOR-AUDITOR dispatcher from fleet-ops#34 and #444:
#   - a fully-walled ladder reaches NISH as MONEY-BOUNDARY (fleet-ops#1534:
#     writer class-gate tags walled ladders with a sanctioned boundary class
#     so nish-boundary-notify can match and page; the old LADDER-WALLED token
#     was not in CLASSES and never paged)
#   - a healthy seat dispatches the auditor and writes a diagnosis block
#   - a timeout / empty / failed dispatch does NOT consume the 2-dispatch budget
#   - the 2-dispatch cap is enforced
#   - auditor-resolved closeouts skip (do not re-summon)
#   - pi_rc 143/137 is KILL-RETRY (not DISPATCH-NO-BLOCK); 2 consecutive
#     kills on the same hash write KILL-ESCALATION to AUDITOR-LOG only
#     (fleet-ops#1534: writer class-gate routes non-boundary escalations to
#     the auditor path, not NISH — they fold into the daily digest)
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
{"reason":"max_auto_continues","detail":{"unit":"pi-issue@fleet-ops-34.service"}}
JSON

SEAT_LIB_STUB="$scratch/seat-lib-stub.sh"
# The stub mirrors the real seat-lib contract the fix relies on:
#   - pick_seat honours need_capable (arg 3) and the tried-file exclusion (arg 4)
#   - pick_seat skips seats recorded in $STOP_ESCALATION_TEST_BENCH_FILE
#     (stands in for seat_usable reading the per-seat ledger a real
#     mark_seat_spawn_fail writes)
#   - mark_seat_spawn_fail appends to the bench file so the next pick rotates
# Only ollama is treated as not-capable, so the existing healthy/second modes
# (devin / cursor) keep returning a seat and the legacy invariants are
# unchanged.
cat >"$SEAT_LIB_STUB" <<'EOF'
#!/usr/bin/env bash
# $'\t' gives a real tab; a double-quoted "\t" is a literal backslash-t and
# would not split in `read` / `cut`, breaking provider/model parsing.
pick_seat() {
  local fail_p="$1" fail_m="$2" need_capable="${3:-0}" tried_file="${4:-}"
  local mode="${STOP_ESCALATION_TEST_SEAT_MODE:-healthy}"
  local TAB=$'\t'
  local -a cands=()
  case "$mode" in
    empty)  return 1 ;;
    healthy) cands=("devin${TAB}glm-5-2") ;;
    second)  cands=("cursor${TAB}sonnet-4") ;;
    rotate)  cands=("devin${TAB}glm-5-2" "cursor${TAB}sonnet-4") ;;
    flash)   cands=("ollama${TAB}deepseek-v4-flash") ;;
    *) cands=("devin${TAB}glm-5-2") ;;
  esac
  local s p m
  for s in "${cands[@]}"; do
    IFS="$TAB" read -r p m <<<"$s"
    # need_capable: ollama/flash is the tools=0 dead-seat class (fleet-ops#1354)
    if [ "$need_capable" = "1" ] && [ "$p" = "ollama" ]; then continue; fi
    # benched seats (stands in for seat_usable reading the ledger)
    if [ -n "${STOP_ESCALATION_TEST_BENCH_FILE:-}" ] && [ -f "$STOP_ESCALATION_TEST_BENCH_FILE" ] \
       && grep -qxF "$p/$m" "$STOP_ESCALATION_TEST_BENCH_FILE" 2>/dev/null; then continue; fi
    # tried seats (the dispatcher records each pick in the tried file)
    if [ -n "$tried_file" ] && [ -f "$tried_file" ] \
       && grep -qxF "$p/$m" "$tried_file" 2>/dev/null; then continue; fi
    # fleet-ops#2661: escalate-lane provider-wedge skip (mirror of the
    # real seat-lib pick_seat when FLEET_ESCALATION_WEDGE_CHECK=1):a
    # provider listed in $STOP_ESCALATION_TEST_WEDGE_FILE is overload-wedged
    # and ALL its seats are excluded from this pick.
    if [ "${FLEET_ESCALATION_WEDGE_CHECK:-0}" = "1" ] && [ -n "${STOP_ESCALATION_TEST_WEDGE_FILE:-}" ] && [ -f "$STOP_ESCALATION_TEST_WEDGE_FILE" ] \
       && grep -qxF "$p" "$STOP_ESCALATION_TEST_WEDGE_FILE" 2>/dev/null; then continue; fi
    printf '%s%s%s\n' "$p" "$TAB" "$m"
    return 0
  done
  return 1
}
mark_seat_spawn_fail() {
  local p="$1" m="$2"
  [ -n "${STOP_ESCALATION_TEST_BENCH_FILE:-}" ] || return 0
  printf '%s/%s\n' "$p" "$m" >> "$STOP_ESCALATION_TEST_BENCH_FILE"
}
# Mirror the real seat-lib detectors (fleet-ops#623): "insufficient funds" is
# NOT a quota_cap match in production either, so a 402 falls through to
# mark_seat_spawn_fail — that is the live tight-loop path this fix targets.
is_credentials_error() { return 1; }
mark_seat_credentials_bad() { return 1; }
is_quota_cap_error() {
  local out="$1" err="$2"
  local combined="$out"$'\n'"$err"
  [[ -n "$combined" ]] || return 1
  # Mirror of the real lib/seat-lib.sh matcher (fleet-ops#3816 added the
  # xkiro free-model daily-token-quota patterns; the live 47-count
  # spawn_fail park on xkiro/deepseek-v4-flash was a stub that predated
  # them, so a regression here re-opens the misclassification).
  grep -qiE 'weekly[[:space:]]+(clinepass[[:space:]]+)?limit|daily[[:space:]]+limit|quota[[:space:]]+(exhausted|exceeded|reached)|usage[[:space:]]+balance[[:space:]]+exhausted|budget_exceeded|credit[[:space:]]+balance[[:space:]]+depleted|free-model[[:space:]]+token[[:space:]]+quota|resource_exhausted|INFERENCE_CAP_ERROR|usage[[:space:]]+limit|plan[[:space:]]+limit|out[[:space:]]+of[[:space:]]+credits|message[[:space:]]+rate[[:space:]]+limit|rate[[:space:]]+limit[[:space:]]+(exceeded|reached)|cap[[:space:]]+(exceeded|reached)|exceeded[[:space:]]+your' <<<"$combined" || return 1
  grep -qiE 'resets?[[:space:]]+(in|at|after)|retry[[:space:]_-]?after|reset[[:space:]]+window' <<<"$combined" && return 0
  grep -qiE 'weekly[[:space:]]+(clinepass[[:space:]]+)?limit|daily[[:space:]]+limit|INFERENCE_CAP_ERROR|FreeUsageLimitError|usage[[:space:]]+balance[[:space:]]+exhausted|budget_exceeded|credit[[:space:]]+balance[[:space:]]+depleted|usage[[:space:]]+limit[[:space:]]+for[[:space:]]+the[[:space:]]+current[[:space:]]+free[[:space:]]+model|free-model[[:space:]]+token[[:space:]]+quota|resource_exhausted' <<<"$combined" && return 0
  return 1
}
is_overload_error() {
  local out="$1" err="$2"
  local combined="$out"$'\n'"$err"
  grep -qiE 'upstream[[:space:]]+(model[[:space:]]+)?provider[[:space:]]+is[[:space:]]+temporarily[[:space:]]+unavailable' <<<"$combined" || return 1
  return 0
}
mark_seat_quota_bench() {
  local p="$1" m="$2"
  [ -n "${STOP_ESCALATION_TEST_BENCH_FILE:-}" ] || return 0
  printf '%s/%s\n' "$p" "$m" >> "$STOP_ESCALATION_TEST_BENCH_FILE"
}
mark_seat_overload_bench() {
  local p="$1" m="$2"
  [ -n "${STOP_ESCALATION_TEST_BENCH_FILE:-}" ] || return 0
  printf '%s/%s\n' "$p" "$m" >> "$STOP_ESCALATION_TEST_BENCH_FILE"
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
  http402)
    # The live tight-loop cause (fleet-ops#623): straitly billing wall.
    echo "HTTP 402: Insufficient funds for request. Check the billing page." >&2
    exit 1
    ;;
  quota)
    # A hard quota/cap wall with an advertised reset window.
    echo "quota exhausted, resets in 1h" >&2
    exit 1
    ;;
  xkiro_quota)
    # fleet-ops#3780: the live xkiro free-tier daily wall. pi surfaces it
    # as rc=1 with the 429 body on stderr; the real is_quota_cap_error
    # classifies it (free-model token quota + rate_limit_exceeded), so the
    # dispatcher must bench via the quota path, not the spawn_fail fallback
    # that accumulated the 47-count park.
    printf '429: {"message":"You'"'"'ve reached today'"'"'s free-model token quota. Your plan'"'"'s paid allowance is separate — switch to a paid model to keep going, or wait for the daily reset.","type":"rate_limit_error","code":"rate_limit_exceeded"}\n' >&2
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
export STOP_ESCALATION_WALLED="$AS/stop-escalation-walled.txt"
export STOP_ESCALATION_NISH="$AS/NISH-ESCALATIONS.md"
export STOP_ESCALATION_AUDITOR_LOG="$AS/AUDITOR-LOG.md"
export STOP_ESCALATION_PI_BIN="$PI_STUB"
export PI_PACKET_SEAT_LIB="$SEAT_LIB_STUB"
export STOP_ESCALATION_AUDITOR_TIMEOUT=2
export STOP_ESCALATION_COOLDOWN=0
# Walled cooldown disabled so re-fire invariants are not silently skipped.
export STOP_ESCALATION_WALLED_CD=0
# Stands in for the per-seat ledger a real mark_seat_spawn_fail writes.
# Cleared per-invariant that needs a fresh bench set.
export STOP_ESCALATION_TEST_BENCH_FILE="$scratch/benched.txt"
: > "$STOP_ESCALATION_TEST_BENCH_FILE"

# ---------------------------------------------------------------------------
# Invariant 1: fully-walled ladder -> MONEY-BOUNDARY in NISH (fleet-ops#1534),
# no AUDITOR dispatch. The writer class-gate tags walled ladders with the
# sanctioned MONEY-BOUNDARY class so nish-boundary-notify can match and page.
# fleet-ops#623: a walled ladder is a Nish escalation, NOT a unit failure —
# the dispatcher exits 0 so the unit is active-and-quiet (no alarm blindness).
# ---------------------------------------------------------------------------
export STOP_ESCALATION_TEST_SEAT_MODE=empty
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "empty ladder: expected exit 0 (quiet walled escalation), got $rc"
# 2026-08-28 storm fix: a non-payment wall (unit-failure) must be LOUD in the
# auditor LOG but must NOT page Nish (35-text storm). NISH stays empty here.
[[ ! -s "$STOP_ESCALATION_NISH" ]] || fail "empty ladder (unit-failure): must NOT write NISH — not a money page"
grep -q 'LADDER-WALLED' "$STOP_ESCALATION_AUDITOR_LOG" || fail "empty ladder: LADDER-WALLED must land in auditor LOG (fail-loud, not silent)"
[[ ! -s "$STOP_ESCALATION_SEEN" ]] || fail "empty ladder: must not consume dispatch budget"
ok "fully-walled ladder (unit-failure) -> auditor LOG, NISH untouched, exit 0"
: > "$STOP_ESCALATION_AUDITOR_LOG"  # reset for later scenarios (state bleed)

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
{"reason":"max_auto_continues","detail":{"unit":"pi-issue@fleet-ops-34.service"}}
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
{"reason":"max_auto_continues","detail":{"unit":"pi-issue@fleet-ops-35.service"}}
JSON

export STOP_ESCALATION_TEST_SEAT_MODE=healthy
export STOP_ESCALATION_TEST_PI_MODE=timeout
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "timeout: expected exit 0, got $rc"
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
{"reason":"max_auto_continues","detail":{"unit":"pi-issue@fleet-ops-36.service"}}
JSON

export STOP_ESCALATION_TEST_PI_MODE=empty
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "empty output: expected exit 0, got $rc"
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
: > "$STOP_ESCALATION_TEST_BENCH_FILE"
cat >"$STOP_ESCALATION_STOP_REASON" <<'JSON'
{"reason":"max_auto_continues","detail":{"unit":"pi-issue@fleet-ops-37.service"}}
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
# fleet-ops#1534: CAP-REACHED is an auditor-path outcome, not a Nish-reserved
# decision. The writer class-gate routes it to AUDITOR-LOG only — it must NOT
# appear in NISH (it would pollute the file nish-boundary-notify scans).
grep -q 'CAP-REACHED' "$STOP_ESCALATION_AUDITOR_LOG" || fail "cap: expected CAP-REACHED in AUDITOR-LOG (fleet-ops#1534 writer class-gate)"
[[ ! -s "$STOP_ESCALATION_NISH" ]] || fail "cap: CAP-REACHED must NOT write NISH (fleet-ops#1534 — auditor path only, folds into digest)"
ok "2-dispatch cap -> CAP-REACHED in AUDITOR-LOG only (not NISH)"

# ---------------------------------------------------------------------------
# Invariant 6 (fleet-ops#444): pi_rc=143 is KILL-RETRY, not DISPATCH-NO-BLOCK
# ---------------------------------------------------------------------------
: > "$STOP_ESCALATION_SEEN"
: > "$STOP_ESCALATION_KILLS"
: > "$STOP_ESCALATION_AUDITOR_LOG"
: > "$STOP_ESCALATION_NISH"
: > "$STOP_ESCALATION_TEST_BENCH_FILE"
cat >"$STOP_ESCALATION_STOP_REASON" <<'JSON'
{"reason":"max_auto_continues","detail":{"unit":"pi-issue@fleet-ops-444.service"}}
JSON
hash444=$(sha256sum "$STOP_ESCALATION_STOP_REASON" | awk '{print $1}')
export STOP_ESCALATION_TEST_SEAT_MODE=healthy
export STOP_ESCALATION_TEST_PI_MODE=sigterm
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "sigterm: expected exit 0 on first kill, got $rc"
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
# fleet-ops#1534: KILL-ESCALATION is an auditor-path outcome, not a Nish-reserved
# decision. The writer class-gate routes it to AUDITOR-LOG only — it must NOT
# appear in NISH (it would pollute the file nish-boundary-notify scans).
[[ ! -s "$STOP_ESCALATION_NISH" ]] || fail "2x-sigterm: KILL-ESCALATION must NOT write NISH (fleet-ops#1534 — auditor path only)"
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
: > "$STOP_ESCALATION_TEST_BENCH_FILE"
cat >"$STOP_ESCALATION_STOP_REASON" <<'JSON'
{"reason":"max_auto_continues","detail":{"unit":"pi-issue@fleet-ops-444-sigkill.service"}}
JSON
hash137=$(sha256sum "$STOP_ESCALATION_STOP_REASON" | awk '{print $1}')
export STOP_ESCALATION_TEST_SEAT_MODE=healthy
export STOP_ESCALATION_TEST_PI_MODE=sigkill
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "sigkill: expected exit 0 on first kill, got $rc"
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
: > "$STOP_ESCALATION_TEST_BENCH_FILE"
cat >"$STOP_ESCALATION_STOP_REASON" <<'JSON'
{"reason":"max_auto_continues","detail":{"unit":"pi-issue@fleet-ops-444-timeout.service"}}
JSON
hash124=$(sha256sum "$STOP_ESCALATION_STOP_REASON" | awk '{print $1}')
export STOP_ESCALATION_TEST_SEAT_MODE=healthy
export STOP_ESCALATION_TEST_PI_MODE=timeout
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "1x-timeout: expected exit 0, got $rc"
grep -q 'TIMEOUT-KILL' "$STOP_ESCALATION_AUDITOR_LOG" || fail "1x-timeout: expected TIMEOUT-KILL"
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "2x-timeout: expected exit 0 after KILL-ESCALATION, got $rc"
grep -q "KILL-ESCALATION hash=$hash124" "$STOP_ESCALATION_AUDITOR_LOG" \
  || fail "2x-timeout: expected KILL-ESCALATION in AUDITOR-LOG"
# fleet-ops#1534: KILL-ESCALATION is auditor-path only — must NOT write NISH.
[[ ! -s "$STOP_ESCALATION_NISH" ]] || fail "2x-timeout: KILL-ESCALATION must NOT write NISH (fleet-ops#1534 — auditor path only)"
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "3rd-timeout: expected exit 0 skip, got $rc"
dispatch_count=$(grep -c "DISPATCH hash=$hash124" "$STOP_ESCALATION_AUDITOR_LOG" || true)
[[ "$dispatch_count" == "2" ]] || fail "3rd-timeout: must not dispatch a 3rd time (got $dispatch_count DISPATCH lines)"
ok "2x pi_rc=124 -> KILL-ESCALATION, no 3rd dispatch"

# ---------------------------------------------------------------------------
# Invariant 10 (fleet-ops#1354): a stub seat returning rc=0/empty must
# BENCH the seat and ROTATE on the next fire, never re-pick the same dead
# seat.  Two capable seats, both return empty.  Without the fix the tried
# file is wiped each fire and the same first seat is re-picked forever
# (unbounded loop).  With the fix each no-block benches the seat, so the
# next fire rotates to the other seat, then the ladder is walled.
# ---------------------------------------------------------------------------
: > "$STOP_ESCALATION_SEEN"
: > "$STOP_ESCALATION_KILLS"
: > "$STOP_ESCALATION_AUDITOR_LOG"
: > "$STOP_ESCALATION_NISH"
: > "$STOP_ESCALATION_TEST_BENCH_FILE"
cat >"$STOP_ESCALATION_STOP_REASON" <<'JSON'
{"reason":"max_auto_continues","detail":{"unit":"pi-issue@fleet-ops-1354.service"}}
JSON
hash1354=$(sha256sum "$STOP_ESCALATION_STOP_REASON" | awk '{print $1}')
export STOP_ESCALATION_TEST_SEAT_MODE=rotate
export STOP_ESCALATION_TEST_PI_MODE=empty

# Fire 1: picks the first capable seat (devin), rc=0/empty -> bench it, exit 1.
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "1354 fire 1: expected exit 0, got $rc"
grep -q "DISPATCH-NO-BLOCK hash=$hash1354 provider=devin" "$STOP_ESCALATION_AUDITOR_LOG" \
  || fail "1354 fire 1: expected DISPATCH-NO-BLOCK on devin"
grep -qxF "devin/glm-5-2" "$STOP_ESCALATION_TEST_BENCH_FILE" \
  || fail "1354 fire 1: devin must be benched (mark_seat_spawn_fail called)"

# Fire 2: devin is benched -> rotates to cursor, rc=0/empty -> bench it, exit 1.
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "1354 fire 2: expected exit 0, got $rc"
grep -q "DISPATCH-NO-BLOCK hash=$hash1354 provider=cursor" "$STOP_ESCALATION_AUDITOR_LOG" \
  || fail "1354 fire 2: expected DISPATCH-NO-BLOCK on cursor (rotation)"
grep -qxF "cursor/sonnet-4" "$STOP_ESCALATION_TEST_BENCH_FILE" \
  || fail "1354 fire 2: cursor must be benched"

# Fire 3: both capable seats benched -> ladder walled -> MONEY-BOUNDARY in
# NISH (fleet-ops#1534: writer class-gate tags walled ladders), exit 0
# (fleet-ops#623: a walled ladder is a quiet Nish escalation, not a unit
# failure).  This is the bound: the loop does NOT keep re-picking a dead seat.
: > "$STOP_ESCALATION_NISH"
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "1354 fire 3: expected exit 0 (ladder walled, quiet), got $rc"
grep -q "LADDER-WALLED hash=$hash1354" "$STOP_ESCALATION_AUDITOR_LOG" \
  || fail "1354 fire 3: benched wall must land in auditor LOG (storm fix: not a money page)"
! grep -q "hash=$hash1354" "$STOP_ESCALATION_NISH" \
  || fail "1354 fire 3: benched wall must NOT reach NISH"

# Exactly 2 dispatches across 3 fires — never an unbounded same-seat loop.
dispatch_count=$(grep -c "DISPATCH hash=$hash1354" "$STOP_ESCALATION_AUDITOR_LOG" || true)
[[ "$dispatch_count" == "2" ]] \
  || fail "1354: expected exactly 2 dispatches (rotation), got $dispatch_count"
# Budget never consumed (no-block does not consume the 2-dispatch cap).
count=$(awk -v h="$hash1354" '$1==h{print $2}' "$STOP_ESCALATION_SEEN" 2>/dev/null || true)
[[ -z "$count" ]] || fail "1354: no-block must not consume dispatch budget (got count=$count)"
ok "fleet-ops#1354: rc=0/empty seat benches + rotates, never unbounded loop"

# ---------------------------------------------------------------------------
# Invariant 11 (fleet-ops#1354): need_capable=1 excludes a tools=0 flash seat
# at pick time, so the auditor is never dispatched to a seat that cannot drive
# tools.  The only candidate is ollama/flash (not capable) -> MONEY-BOUNDARY
# (fleet-ops#1534: writer class-gate tags walled ladders) immediately, no
# DISPATCH line written.
# ---------------------------------------------------------------------------
: > "$STOP_ESCALATION_SEEN"
: > "$STOP_ESCALATION_KILLS"
: > "$STOP_ESCALATION_AUDITOR_LOG"
: > "$STOP_ESCALATION_NISH"
: > "$STOP_ESCALATION_TEST_BENCH_FILE"
cat >"$STOP_ESCALATION_STOP_REASON" <<'JSON'
{"reason":"max_auto_continues","detail":{"unit":"pi-issue@fleet-ops-1354-flash.service"}}
JSON
hashflash=$(sha256sum "$STOP_ESCALATION_STOP_REASON" | awk '{print $1}')
export STOP_ESCALATION_TEST_SEAT_MODE=flash
export STOP_ESCALATION_TEST_PI_MODE=block
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "flash: expected exit 0 (ladder walled by need_capable, quiet), got $rc"
grep -q "LADDER-WALLED hash=$hashflash" "$STOP_ESCALATION_AUDITOR_LOG" \
  || fail "flash: capability wall must land in auditor LOG (storm fix: not a money page)"
! grep -q "hash=$hashflash" "$STOP_ESCALATION_NISH" \
  || fail "flash: capability wall must NOT reach NISH"
dispatch_count=$(grep -c "DISPATCH hash=$hashflash" "$STOP_ESCALATION_AUDITOR_LOG" || true)
[[ "$dispatch_count" == "0" ]] \
  || fail "flash: must not dispatch to a tools=0 seat (got $dispatch_count DISPATCH lines)"
ok "fleet-ops#1354: need_capable=1 excludes tools=0 flash seat at pick time"

# ---------------------------------------------------------------------------
# Invariant 12 (fleet-ops#623): a seat returning pi_rc=1 with an HTTP 402
# "Insufficient funds" billing wall MUST be benched (spawn-fail fallback) and
# rotate, never re-picked.  This is the live tight-loop cause: the #1354 fix
# only benched rc=0 seats, so a 402 seat was re-offered every trip and the
# unit failed 6x in 2 min.  Two capable seats, both 402 -> bench + rotate,
# then ladder walled (exit 0).
# ---------------------------------------------------------------------------
: > "$STOP_ESCALATION_SEEN"
: > "$STOP_ESCALATION_KILLS"
: > "$STOP_ESCALATION_AUDITOR_LOG"
: > "$STOP_ESCALATION_NISH"
: > "$STOP_ESCALATION_TEST_BENCH_FILE"
cat >"$STOP_ESCALATION_STOP_REASON" <<'JSON'
{"reason":"max_auto_continues","detail":{"unit":"pi-issue@fleet-ops-623.service"}}
JSON
hash623=$(sha256sum "$STOP_ESCALATION_STOP_REASON" | awk '{print $1}')
export STOP_ESCALATION_TEST_SEAT_MODE=rotate
export STOP_ESCALATION_TEST_PI_MODE=http402

# Fire 1: picks devin, 402 -> bench (spawn-fail, not quota: "insufficient
# funds" is not a quota_cap match), DISPATCH-NO-BLOCK, exit 1.
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "623 fire 1: expected exit 0, got $rc"
grep -q "DISPATCH-NO-BLOCK hash=$hash623 provider=devin" "$STOP_ESCALATION_AUDITOR_LOG" \
  || fail "623 fire 1: expected DISPATCH-NO-BLOCK on devin"
grep -q "bench=no_block:rc=1" "$STOP_ESCALATION_AUDITOR_LOG" \
  || fail "623 fire 1: expected bench=no_block:rc=1 (402 is not a quota wall)"
grep -qxF "devin/glm-5-2" "$STOP_ESCALATION_TEST_BENCH_FILE" \
  || fail "623 fire 1: devin must be benched (rc=1 402 -> spawn-fail bench)"

# Fire 2: devin benched -> rotates to cursor, 402 -> bench, exit 1.
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "623 fire 2: expected exit 0, got $rc"
grep -q "DISPATCH-NO-BLOCK hash=$hash623 provider=cursor" "$STOP_ESCALATION_AUDITOR_LOG" \
  || fail "623 fire 2: expected DISPATCH-NO-BLOCK on cursor (rotation)"
grep -qxF "cursor/sonnet-4" "$STOP_ESCALATION_TEST_BENCH_FILE" \
  || fail "623 fire 2: cursor must be benched"

# Fire 3: both benched -> ladder walled -> MONEY-BOUNDARY, exit 0 (quiet).
# (fleet-ops#1534: writer class-gate tags walled ladders with MONEY-BOUNDARY.)
: > "$STOP_ESCALATION_NISH"
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "623 fire 3: expected exit 0 (ladder walled, quiet), got $rc"
grep -q "LADDER-WALLED hash=$hash623" "$STOP_ESCALATION_AUDITOR_LOG" \
  || fail "623 fire 3: benched wall must land in auditor LOG (storm fix: not a money page)"
! grep -q "hash=$hash623" "$STOP_ESCALATION_NISH" \
  || fail "623 fire 3: benched wall must NOT reach NISH"
dispatch_count=$(grep -c "DISPATCH hash=$hash623" "$STOP_ESCALATION_AUDITOR_LOG" || true)
[[ "$dispatch_count" == "2" ]] \
  || fail "623: expected exactly 2 dispatches (rotation), got $dispatch_count"
count=$(awk -v h="$hash623" '$1==h{print $2}' "$STOP_ESCALATION_SEEN" 2>/dev/null || true)
[[ -z "$count" ]] || fail "623: no-block must not consume dispatch budget (got count=$count)"
ok "fleet-ops#623: rc=1 HTTP 402 seat benches + rotates, never unbounded loop"

# ---------------------------------------------------------------------------
# Invariant 13 (fleet-ops#623): a seat returning pi_rc=1 with a quota/cap wall
# ("quota exhausted, resets in 1h") is benched via the quota bench path, not
# the spawn-fail fallback.  Proves the longer-bench ladder is wired.
# ---------------------------------------------------------------------------
: > "$STOP_ESCALATION_SEEN"
: > "$STOP_ESCALATION_KILLS"
: > "$STOP_ESCALATION_AUDITOR_LOG"
: > "$STOP_ESCALATION_NISH"
: > "$STOP_ESCALATION_TEST_BENCH_FILE"
cat >"$STOP_ESCALATION_STOP_REASON" <<'JSON'
{"reason":"max_auto_continues","detail":{"unit":"pi-issue@fleet-ops-623-quota.service"}}
JSON
hashq=$(sha256sum "$STOP_ESCALATION_STOP_REASON" | awk '{print $1}')
export STOP_ESCALATION_TEST_SEAT_MODE=healthy
export STOP_ESCALATION_TEST_PI_MODE=quota
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "quota: expected exit 0, got $rc"
grep -q "DISPATCH-NO-BLOCK hash=$hashq provider=devin" "$STOP_ESCALATION_AUDITOR_LOG" \
  || fail "quota: expected DISPATCH-NO-BLOCK on devin"
grep -q "bench=quota_cap" "$STOP_ESCALATION_AUDITOR_LOG" \
  || fail "quota: expected bench=quota_cap (quota wall uses the long bench)"
grep -qxF "devin/glm-5-2" "$STOP_ESCALATION_TEST_BENCH_FILE" \
  || fail "quota: devin must be benched"
ok "fleet-ops#623: rc=1 quota wall -> quota bench path (long bench)"

# ---------------------------------------------------------------------------
# Invariant 13b (fleet-ops#3780): the xkiro free-tier daily-token-quota wall
# (HTTP 429, "free-model token quota ... wait for the daily reset",
# type=rate_limit_error code=rate_limit_exceeded) is a quota_cap, NOT a
# spawn_fail. The live seat accumulated 47 consecutive spawn_fail because
# the stub's is_quota_cap_error predated the #3816 free-model patterns; the
# real matcher classifies it, so the dispatcher must take the quota bench
# path (long bench until the daily reset), never the no_block:rc=1 fallback
# that drove the corpse park.
# ---------------------------------------------------------------------------
: > "$STOP_ESCALATION_SEEN"
: > "$STOP_ESCALATION_KILLS"
: > "$STOP_ESCALATION_AUDITOR_LOG"
: > "$STOP_ESCALATION_NISH"
: > "$STOP_ESCALATION_TEST_BENCH_FILE"
cat >"$STOP_ESCALATION_STOP_REASON" <<'JSON'
{"reason":"max_auto_continues","detail":{"unit":"pi-issue@fleet-ops-3780-xkiro.service"}}
JSON
hashx=$(sha256sum "$STOP_ESCALATION_STOP_REASON" | awk '{print $1}')
export STOP_ESCALATION_TEST_SEAT_MODE=healthy
export STOP_ESCALATION_TEST_PI_MODE=xkiro_quota
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "xkiro_quota: expected exit 0, got $rc"
grep -q "DISPATCH-NO-BLOCK hash=$hashx provider=devin" "$STOP_ESCALATION_AUDITOR_LOG" \
  || fail "xkiro_quota: expected DISPATCH-NO-BLOCK on devin"
grep -q "bench=quota_cap" "$STOP_ESCALATION_AUDITOR_LOG" \
  || fail "xkiro_quota: expected bench=quota_cap (xkiro free-model daily wall is a quota cap, not a spawn_fail)"
! grep -q "bench=no_block:rc=1" "$STOP_ESCALATION_AUDITOR_LOG" \
  || fail "xkiro_quota: must NOT fall through to no_block:rc=1 spawn_fail (the 47-count misclassification)"
grep -qxF "devin/glm-5-2" "$STOP_ESCALATION_TEST_BENCH_FILE" \
  || fail "xkiro_quota: devin must be benched via quota path"
ok "fleet-ops#3780: xkiro free-model daily-token-quota 429 -> quota_cap bench, not spawn_fail"

# ---------------------------------------------------------------------------
# Invariant 14 (fleet-ops#2661): escalate-lane provider-wedge check. A
# provider with >=2 seats in overload_bench within the last 30 min is WEDGED:
# the AUDITOR must NEVER be dispatched into that storm (it just killed the
# workers). The dispatcher exports FLEET_ESCALATION_WEDGE_CHECK=1; the real
# pick_seat (and this stub mirror of it) skip wedged providers entirely.
# Prove: wedge=cursor -> rotation skips cursor and dispatches devin; wedge=both
# -> no seat -> LADDER-WALLED (quiet auditor-log, exit 0,, NOT a dispatch.
# ---------------------------------------------------------------------------
: > "$STOP_ESCALATION_SEEN"
: > "$STOP_ESCALATION_KILLS"
: > "$STOP_ESCALATION_AUDITOR_LOG"
: > "$STOP_ESCALATION_NISH"
: > "$STOP_ESCALATION_TEST_BENCH_FILE"
cat >"$STOP_ESCALATION_STOP_REASON" <<'JSON'
{"reason":"max_auto_continues","detail":{"unit":"pi-issue@fleet-ops-2661-wedge.service"}}
JSON
hashw=$(sha256sum "$STOP_ESCALATION_STOP_REASON" | awk '{print $1}')
export STOP_ESCALATION_TEST_SEAT_MODE=rotate
export STOP_ESCALATION_TEST_PI_MODE=block
export STOP_ESCALATION_TEST_WEDGE_FILE="$scratch/wedged.txt"
printf '%s\n' cursor >"$STOP_ESCALATION_TEST_WEDGE_FILE"
export FLEET_ESCALATION_WEDGE_CHECK=1
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "wedge cursor: expected exit 0, got $rc"
grep -qE "DISPATCH hash=$hashw count=[0-9]+ provider=devin model=glm-5-2" "$STOP_ESCALATION_AUDITOR_LOG" \
  || fail "wedge cursor: must dispatch devin (cursor wedged), got: $(cat "$STOP_ESCALATION_AUDITOR_LOG")"
! grep -q "cursor" "$STOP_ESCALATION_AUDITOR_LOG" \
  || fail "wedge cursor: must NEVER dispatch cursor (wedged provider)"
# All candidates wedged -> no seat -> LADDER-WALLED (quiet, exit 0,, no budget.
printf '%s\n' devin cursor >"$STOP_ESCALATION_TEST_WEDGE_FILE"
: > "$STOP_ESCALATION_AUDITOR_LOG"
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "wedge all: expected exit 0 (quiet walled ladder), got $rc"
grep -q "LADDER-WALLED hash=$hashw" "$STOP_ESCALATION_AUDITOR_LOG" \
  || fail "wedge all: wedged ladder must land in auditor LOG: $(cat "$STOP_ESCALATION_AUDITOR_LOG")"
! grep -q "DISPATCH hash=$hashw" "$STOP_ESCALATION_AUDITOR_LOG" \
  || fail "wedge all: must NOT dispatch into a wedged ladder"
unset FLEET_ESCALATION_WEDGE_CHECK
ok "fleet-ops#2661: escalate lanes refuse overload-wedged providers (rotation skips; all-wedged ladder walls quietly"

ok "stop-escalation-dispatch: lane faults rotate, timeout/no-block quiet, cap enforced, kill-retry capped, dead-seat rotation (#1354), rc=1 benching + quiet walled ladder (#623)"

# ===========================================================================
# fleet-ops#5456: the resume-or-dispatch path (unit deaths terminate in an
# ACTION). reason=unit-failure / unit-stopped-without-deliverable /
# packet-exhausted never reaches the auditor seat ladder: hop<2 packet ->
# relaunch on the next healthy seat; hop>=2 or non-packet -> agent-ready
# issue + findings-ledger row + LOUD triage line; Nish only when BOTH rails
# fail; resume-drill-* units dispatch to the drill sink, never GitHub.
# ===========================================================================
cat >"$scratch/fake-gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >> "${STOP_ESCALATION_TEST_GH_LOG}"
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then :; exit 0; fi  # --jq '.[0].url' over no matches prints nothing
if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  printf 'https://github.com/Nishfleet/fleet-ops/issues/5456\n'; exit 0
fi
exit 0
EOF
chmod +x "$scratch/fake-gh"
cat >"$scratch/fake-hermes" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "hermes $*" >> "${STOP_ESCALATION_TEST_HERMES_LOG}"
exit 0
EOF
chmod +x "$scratch/fake-hermes"
cat >"$scratch/fake-pirun" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STOP_ESCALATION_TEST_PIRUN_LOG}"
exit 0
EOF
chmod +x "$scratch/fake-pirun"
# The dispatcher invokes the findings writer as `python3 <script>` (the
# canonical lib/findings_ledger.py is not executable), so the fake is python.
cat >"$scratch/fake-findings" <<'EOF'
import os, sys
with open(os.environ["STOP_ESCALATION_TEST_FINDINGS_LOG"], "a") as fh:
    fh.write(" ".join(sys.argv[1:]) + "\n")
EOF
export STOP_ESCALATION_TEST_GH_LOG="$AS/resume-gh.log"
export STOP_ESCALATION_TEST_HERMES_LOG="$AS/resume-hermes.log"
export STOP_ESCALATION_TEST_PIRUN_LOG="$AS/resume-pirun.log"
export STOP_ESCALATION_TEST_FINDINGS_LOG="$AS/resume-findings.log"
export STOP_ESCALATION_RESUME_GH="$scratch/fake-gh"
export STOP_ESCALATION_RESUME_HERMES="$scratch/fake-hermes"
export STOP_ESCALATION_RESUME_PI_RUN="$scratch/fake-pirun"
export STOP_ESCALATION_RESUME_FINDINGS="$scratch/fake-findings"
export STOP_ESCALATION_RESUME_AS="$AS"
export STOP_ESCALATION_RESUME_LEDGER="$AS/resume-ledger.jsonl"
export STOP_ESCALATION_RESUME_TRIAGE="$AS/resume-triage.md"
export STOP_ESCALATION_RESUME_SYSTEMCTL="/bin/true"
export STOP_ESCALATION_RESUME_DRYRUN=0

resume_sr() {  # resume_sr <unit> <reason>
  python3 -c 'import json,sys;json.dump({"reason":sys.argv[2],"detail":{"unit":sys.argv[1],"journal":[],"journal_errors":[],"result":"exit-code","exit_status":"1","memory_peak":"","oom_signal":"no"},"timestamp":"2026-09-11T18:00:00Z","extension":"unit-escalation","source":"unit-escalation"},sys.stdout)' "$1" "$2" > "$STOP_ESCALATION_STOP_REASON"
}

# --- resume: hop<2 packet -> relaunch on the next healthy seat --------------
: > "$STOP_ESCALATION_RESUME_LEDGER"; : > "$STOP_ESCALATION_TEST_PIRUN_LOG"
printf 'packet body\n' > "$AS/resume-packet.md"
python3 -c 'import json,sys;print(json.dumps({"id":"rid-1","chain_id":"chain-1","hop":0,"ts":"2026-09-11T17:00:00Z","unit":"resume-test-pkt","packet_path":"'"$AS"'/resume-packet.md","provider":"oldp","model":"oldm","deadline_min":30,"deadline_ts":"","cmdline":"pi --print --provider oldp --model oldm","workdir":"'"$scratch"'","deliverable":"'"$AS"'/resume-deliv.md","status":"open","retries":0}))' >> "$STOP_ESCALATION_RESUME_LEDGER"
resume_sr "resume-test-pkt.service" "unit-failure"
set +e; "$dispatch"; rc=$?; set -e
[[ $rc -eq 0 ]] || fail "resume relaunch: expected exit 0, got $rc"
grep -q -- '--hop 1' "$STOP_ESCALATION_TEST_PIRUN_LOG" || fail "resume relaunch: pi-systemd-run not invoked with --hop 1: $(cat "$STOP_ESCALATION_TEST_PIRUN_LOG")"
grep -q -- '--chain-id chain-1' "$STOP_ESCALATION_TEST_PIRUN_LOG" || fail "resume relaunch: chain-id not carried: $(cat "$STOP_ESCALATION_TEST_PIRUN_LOG")"
grep -q -- '--provider devin' "$STOP_ESCALATION_TEST_PIRUN_LOG" && grep -q -- '--model glm-5-2' "$STOP_ESCALATION_TEST_PIRUN_LOG" \
  || fail "resume relaunch: seat not rotated to the picked seat: $(cat "$STOP_ESCALATION_TEST_PIRUN_LOG")"
[[ -s "$STOP_ESCALATION_NISH" ]] && fail "resume relaunch: must never page Nish"
ok "resume: dead packet at hop 0 relaunched at hop 1 on the next healthy seat (chain-id carried)"

# --- resume: hop>=2 -> dispatch (issue + triage + findings), no relaunch ----
: > "$STOP_ESCALATION_RESUME_LEDGER"; : > "$STOP_ESCALATION_TEST_GH_LOG"
: > "$STOP_ESCALATION_RESUME_TRIAGE"; : > "$STOP_ESCALATION_TEST_FINDINGS_LOG"; : > "$STOP_ESCALATION_TEST_PIRUN_LOG"
python3 -c 'import json,sys;print(json.dumps({"id":"rid-2","chain_id":"chain-2","hop":2,"ts":"2026-09-11T17:00:00Z","unit":"resume-test-pkt","packet_path":"'"$AS"'/resume-packet.md","provider":"oldp","model":"oldm","deadline_min":30,"deadline_ts":"","cmdline":"pi --print --provider oldp --model oldm","workdir":"'"$scratch"'","deliverable":"","status":"open","retries":2}))' >> "$STOP_ESCALATION_RESUME_LEDGER"
resume_sr "resume-test-pkt.service" "unit-failure"
set +e; "$dispatch"; rc=$?; set -e
[[ $rc -eq 0 ]] || fail "resume dispatch: expected exit 0, got $rc"
[[ -s "$STOP_ESCALATION_TEST_PIRUN_LOG" ]] && fail "resume dispatch: hop>=2 must NOT relaunch"
grep -q 'issue create' "$STOP_ESCALATION_TEST_GH_LOG" || fail "resume dispatch: no agent-ready issue created: $(cat "$STOP_ESCALATION_TEST_GH_LOG")"
grep -q '\[unit-death\] resume-test-pkt.service' "$STOP_ESCALATION_TEST_GH_LOG" || fail "resume dispatch: issue title must name the unit"
grep -q 'UNIT-DEATH-DISPATCH' "$STOP_ESCALATION_RESUME_TRIAGE" || fail "resume dispatch: LOUD triage line missing"
grep -q 'carried_over' "$STOP_ESCALATION_TEST_FINDINGS_LOG" || fail "resume dispatch: findings-ledger row (carried_over) missing"
[[ -s "$STOP_ESCALATION_NISH" ]] && fail "resume dispatch: healthy rails must not page Nish"
ok "resume: hop>=2 dispatches agent-ready issue + findings row + LOUD triage line"

# --- resume: non-packet unit -> dispatch (no ledger row) ---------------------
: > "$STOP_ESCALATION_TEST_GH_LOG"; : > "$STOP_ESCALATION_RESUME_TRIAGE"; : > "$STOP_ESCALATION_TEST_PIRUN_LOG"
resume_sr "fleet-some-canary.service" "unit-failure"
set +e; "$dispatch"; rc=$?; set -e
[[ $rc -eq 0 ]] || fail "non-packet dispatch: expected exit 0, got $rc"
[[ -s "$STOP_ESCALATION_TEST_PIRUN_LOG" ]] && fail "non-packet dispatch: must not relaunch"
grep -q 'issue create' "$STOP_ESCALATION_TEST_GH_LOG" || fail "non-packet dispatch: no issue created"
ok "resume: non-packet unit dispatches (never relaunches, never auditor-summons)"

# --- resume: both rails down -> the Nish last-resort + exit 1 ---------------
cat >"$scratch/failing-gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$scratch/failing-gh"
cat >"$scratch/failing-hermes" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$scratch/failing-hermes"
set +e
STOP_ESCALATION_RESUME_GH="$scratch/failing-gh" STOP_ESCALATION_RESUME_HERMES="$scratch/failing-hermes" \
  STOP_ESCALATION_RESUME_LEDGER="/nonexistent-ledger" "$dispatch"; rc=$?
set -e
[[ $rc -eq 1 ]] || fail "both rails down: expected exit 1, got $rc"
grep -q 'UNIT-DEATH-PAGE' "$AS/nish-escalations-archive/$(date -u +%Y-%m-%d).md" 2>/dev/null \
  || fail "both rails down: LOUD archive line missing"
ok "resume: issue-create AND hermes both failing -> LOUD archive line + exit 1 (the only Nish page)"

# --- resume: drill unit -> drill sink, never GitHub --------------------------
: > "$STOP_ESCALATION_TEST_GH_LOG"; : > "$STOP_ESCALATION_RESUME_TRIAGE"
resume_sr "resume-drill-crash-test.service" "unit-failure"
set +e; "$dispatch"; rc=$?; set -e
[[ $rc -eq 0 ]] || fail "drill sink: expected exit 0, got $rc"
[[ -s "$STOP_ESCALATION_TEST_GH_LOG" ]] && fail "drill sink: must never touch GitHub"
grep -q '\[unit-death\]' "$AS/resume-drill/issues.jsonl" || fail "drill sink: issue payload not recorded"
ok "resume: resume-drill-* dispatches to the drill sink (hourly drill stays hermetic)"

# --- resume: circuit-trip reasons never take the resume path -----------------
: > "$STOP_ESCALATION_TEST_PIRUN_LOG"; : > "$STOP_ESCALATION_TEST_GH_LOG"
resume_sr "resume-test-pkt.service" "max_auto_continues"
export STOP_ESCALATION_TEST_SEAT_MODE=empty
set +e
"$dispatch"; rc=$?
set -e
[[ $rc -eq 0 ]] || fail "circuit trip: expected exit 0 (walled ladder quiet), got $rc"
[[ -s "$STOP_ESCALATION_TEST_PIRUN_LOG" ]] && fail "circuit trip: must not resume"
[[ -s "$STOP_ESCALATION_TEST_GH_LOG" ]] && fail "circuit trip: must not dispatch"
ok "resume: circuit-breaker trips keep the auditor path (never resume/dispatch)"

ok "stop-escalation-dispatch: #5456 resume-or-dispatch (relaunch hop+1, dispatch on exhaustion, Nish only when both rails fail, drill sink)"
