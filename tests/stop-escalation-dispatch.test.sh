#!/usr/bin/env bash
# tests/stop-escalation-dispatch.test.sh
#
# fleet-ops#95: stop-escalation.service failed 3x in one night because the
# seat-health snapshot happened to be unhealthy AT DISPATCH MOMENT, every time
# with dead=false and the seat healthy again within minutes. Each trip cost a
# failed unit + a SEAT-UNHEALTHY NISH-ESCALATIONS line for a transient lane
# fault — which violates the provider-wall rule (transient walls are lane
# faults, never Nish-escalations).
#
# This test pins the fix in bin/stop-escalation-dispatch:
#   A. Transient blip (rate_limited/transient_fault/unknown, dead=false,
#      not poison) clears within one bounded re-read  -> DISPATCH, NO NISH
#      line, exit 0, budget consumed.
#   B. dead=true  -> fail loud IMMEDIATELY (no re-read wait), NISH line,
#      exit 1.
#   C. poison_ladder=true  -> fail loud immediately, NISH line, exit 1.
#   D. Transient blip that does NOT clear within the re-read  -> NISH line,
#      exit 1 (persistent unhealth is a real escalation).
#   E. The 2-per-hash cap is unchanged: a third trip for the same hash writes
#      CAP-REACHED to NISH and exits 0 without dispatching.
#
# All paths are env-overridable in the dispatcher, so this is a pure unit
# test: a stub STOP-REASON, a scratch SEEN/NISH/LOG, DRY_RUN=1 (no pi call),
# and a seat-health file we can flip between reads. No live fleet, no pi,
# no network.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/stop-escalation-dispatch"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch="$(mktemp -d -t stop-escalation.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Shared env for every run.
export STOP_ESCALATION_AS="$scratch"
SR="$scratch/STOP-REASON.json"
SH="$scratch/seat-health.json"
SEEN="$scratch/stop-escalation-seen.txt"
NISH="$scratch/NISH-ESCALATIONS.md"
LOG="$scratch/AUDITOR-LOG.md"
: >"$SEEN"; : >"$NISH"; : >"$LOG"
export STOP_ESCALATION_STOP_REASON="$SR"
export STOP_ESCALATION_SEAT_HEALTH="$SH"
export STOP_ESCALATION_SEEN="$SEEN"
export STOP_ESCALATION_NISH="$NISH"
export STOP_ESCALATION_AUDITOR_LOG="$LOG"
export STOP_ESCALATION_DRY_RUN=1
export STOP_ESCALATION_TRANSIENT_DELAY=1   # fast re-read in tests

# A real circuit-trip STOP-REASON (max_auto_continues) — the kind that
# escalates. boundary:* and cooldown_active are skipped, so do not use those.
write_stop_reason() {
  cat >"$SR" <<'JSON'
{"reason":"max_auto_continues","detail":"circuit breaker tripped","session":"test"}
JSON
}

seat_healthy()    { cat >"$SH" <<'JSON'
{"provider":"devin","model":"glm-5-2","http_status":200,"retry_after":null,"health_class":"healthy","retryable":false,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-26T00:00:00Z","source":"test"}
JSON
}

seat_rate_limited() { cat >"$SH" <<'JSON'
{"provider":"devin","model":"glm-5-2","http_status":429,"retry_after":1,"health_class":"rate_limited","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-26T00:00:00Z","source":"test"}
JSON
}

seat_dead() { cat >"$SH" <<'JSON'
{"provider":"devin","model":"glm-5-2","http_status":0,"retry_after":null,"health_class":"dead","retryable":false,"seat_dead":true,"poison_ladder":false,"observed_at":"2026-08-26T00:00:00Z","source":"test"}
JSON
}

seat_poison() { cat >"$SH" <<'JSON'
{"provider":"devin","model":"glm-5-2","http_status":403,"retry_after":null,"health_class":"poison_ladder","retryable":false,"seat_dead":false,"poison_ladder":true,"observed_at":"2026-08-26T00:00:00Z","source":"test"}
JSON
}

nish_lines() { [[ -s "$NISH" ]] && cat "$NISH" || echo "(no NISH lines)"; }
log_lines()  { [[ -s "$LOG"  ]] && cat "$LOG"  || echo "(no LOG lines)"; }

# --- A: transient blip clears within the re-read -> dispatch, no NISH --------
write_stop_reason
seat_rate_limited
# Flip the seat-health file to healthy shortly after the run starts, so the
# dispatcher's second read (after the 1s delay) sees a healthy seat.
( sleep 0.4 && seat_healthy ) &
flipper=$!
set +e
"$bin" >/dev/null 2>&1
rc=$?
set -e
wait "$flipper" 2>/dev/null || true
[[ "$rc" -eq 0 ]] || fail "A: transient blip that cleared must exit 0, got $rc; NISH=$(nish_lines); LOG=$(log_lines)"
grep -q SEAT-UNHEALTHY "$NISH" && fail "A: clearing blip must NOT write a NISH line; got $(nish_lines)"
grep -q 'dispatched auditor' "$LOG" || fail "A: must dispatch on recovery; LOG=$(log_lines)"
# Budget consumed once.
cnt=$(awk '{print $2}' "$SEEN"); [[ "$cnt" == "1" ]] || fail "A: budget must be 1 after dispatch, got $cnt"
ok "A: transient blip clears within re-read -> dispatched, no NISH line, budget=1"

# --- B: dead=true -> fail loud immediately, NISH line, exit 1 ---------------
: >"$SEEN"; : >"$NISH"; : >"$LOG"
write_stop_reason
seat_dead
start=$(date +%s)
set +e
"$bin" >/dev/null 2>&1
rc=$?
set -e
elapsed=$(( $(date +%s) - start ))
[[ "$rc" -eq 1 ]] || fail "B: dead=true must exit 1, got $rc"
# Must NOT have waited for a re-read (dead is hard-down, no delay).
[[ "$elapsed" -lt 4 ]] || fail "B: dead=true must fail immediately (no re-read wait), took ${elapsed}s"
grep -q 'SEAT-UNHEALTHY' "$NISH" || fail "B: dead=true must write a NISH line; got $(nish_lines)"
grep -q 'dead=true' "$NISH" || fail "B: NISH line must record dead=true; got $(nish_lines)"
grep -q 'dispatched auditor' "$LOG" && fail "B: dead=true must NOT dispatch"
ok "B: dead=true -> fail loud immediately, NISH line, exit 1, no dispatch"

# --- C: poison_ladder=true -> fail loud immediately, NISH line, exit 1 -------
: >"$SEEN"; : >"$NISH"; : >"$LOG"
write_stop_reason
seat_poison
start=$(date +%s)
set +e
"$bin" >/dev/null 2>&1
rc=$?
set -e
elapsed=$(( $(date +%s) - start ))
[[ "$rc" -eq 1 ]] || fail "C: poison_ladder must exit 1, got $rc"
[[ "$elapsed" -lt 4 ]] || fail "C: poison_ladder must fail immediately, took ${elapsed}s"
grep -q 'SEAT-UNHEALTHY' "$NISH" || fail "C: poison_ladder must write a NISH line; got $(nish_lines)"
grep -q 'poison=true' "$NISH" || fail "C: NISH line must record poison=true; got $(nish_lines)"
ok "C: poison_ladder=true -> fail loud immediately, NISH line, exit 1"

# --- D: transient blip that does NOT clear -> NISH line, exit 1 -------------
: >"$SEEN"; : >"$NISH"; : >"$LOG"
write_stop_reason
seat_rate_limited   # stays rate_limited — never flipped to healthy
set +e
"$bin" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "D: persistent unhealth must exit 1, got $rc"
grep -q 'SEAT-UNHEALTHY' "$NISH" || fail "D: persistent unhealth must write a NISH line; got $(nish_lines)"
grep -q 'dispatched auditor' "$LOG" && fail "D: persistent unhealth must NOT dispatch"
ok "D: transient blip that does not clear -> NISH line, exit 1, no dispatch"

# --- E: 2-per-hash cap unchanged --------------------------------------------
# Seed SEEN with count=2 for the current hash and prove a third trip writes
# CAP-REACHED and exits 0 without dispatching or re-reading the seat.
: >"$NISH"; : >"$LOG"
write_stop_reason
hash=$(sha256sum "$SR" | awk '{print $1}')
now=$(date +%s)
printf '%s 2 %s\n' "$hash" "$now" > "$SEEN"
seat_healthy
set +e
"$bin" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "E: cap-reached must exit 0, got $rc"
grep -q 'CAP-REACHED' "$NISH" || fail "E: third trip must write CAP-REACHED to NISH; got $(nish_lines)"
grep -q 'dispatched auditor' "$LOG" && fail "E: cap-reached must NOT dispatch"
ok "E: 2-per-hash cap unchanged -> CAP-REACHED, exit 0, no dispatch"

echo "ALL OK: stop-escalation-dispatch seat-health gate pinned (#95)"
