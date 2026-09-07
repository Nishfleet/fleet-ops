#!/usr/bin/env bash
# tests/unit-escalation-write-recurrence-suppress.test.sh
#
# fleet-ops#2912: a unit that keeps failing on every scheduler tick with the
# SAME fault class (fleet-heartbeat's 5 persistent structural reds — 35 trips
# in ~2 days, each dispatching a fresh senior auditor who closeout-skips per
# PR #433) writes a fresh STOP-REASON per tick. Each fresh sha256 hash bypasses
# the dispatcher's 2-dispatch-per-hash cap, so the trip layer re-summons an
# auditor for the same in-class fault every tick. The writer-side recurrence
# gate suppresses STOP-REASON writes (and therefore auditor dispatch) once the
# same class has been closeout-skipped RECURRENCE_SUPPRESS_N consecutive times.
#
# Runs entirely offline with a stubbed systemctl + journalctl on PATH, exactly
# like tests/unit-escalation-write-same-unit-rerun-dedupe.test.sh. The gate is
# evaluated AFTER the same-unit re-fire dedupe and BEFORE the atomic SR write,
# so every guard the writer already has (exclusion list, NRestarts, scout
# futility, same-unit re-fire) is exercised before this one.
#
# Class lock (fleet-ops#366 — every fix ships its mechanism):
#   A/B/C. A closeout-skipped class must write fresh for the first
#          (N-1) repeats and be suppressed from the Nth repeat onward —
#          SR unchanged, hash unchanged, loud skip in the unit journal.
#   D. A materially different class (different exit status / LOUD tag set)
#      after N closeouts must RESET the count and write fresh — a new fault
#      is never silently swallowed by stale suppression state.
#   E. An OOM-kill on a recurring unit must always write fresh (existing
#      #2614 carve-out) — recurrent OOM is new evidence, not a closeout class.
#   F. A prior STOP-REASON that is NOT an auditor-resolved closeout (a trip
#      still in flight) must reset the counter and write fresh.
#   G. An auditor-resolved STOP-REASON for a DIFFERENT unit is not a
#      closeout of this unit — write fresh (no cross-unit suppression).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
writer="$repo_root/bin/unit-escalation-write"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$writer" ]] || fail "$writer not executable"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t escalate-recurrence.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

mkdir -p "$scratch/bin" "$scratch/agent-state"
PATH="$scratch/bin:$PATH"
export PATH

AS="$scratch/agent-state"
SR="$AS/STOP-REASON.json"
REC="$AS/unit-escalation-recurrence.json"
export UNIT_ESCALATION_AGENT_STATE="$AS"
export UNIT_ESCALATION_RECURRENCE_STATE="$REC"
export UNIT_ESCALATION_RECURRENCE_SUPPRESS_N=3

# journalctl stub — emits the same two LOUD detector tags every call so the
# class fingerprint is stable across the A/B/C repeat (same class recurring).
cat > "$scratch/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
cat <<'LINES'
LOUD [FAILED-COMMAND-SWALLOWED]
LOUD [DEBUG-PLAYBOOK-MISSING]
LINES
STUB
chmod +x "$scratch/bin/journalctl"

# systemctl stub — default exit-code/1 (the alarm-rc class of the 5
# structural reds). Cases that need a different class or an OOM replace it.
cat > "$scratch/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
prop=""
for a in "$@"; do
  case "$a" in
    -p) prop_next=1 ;;
    -p*) prop="${a#-p}" ;;
    *)
      if [ "${prop_next:-0}" = "1" ]; then prop="$a"; prop_next=0; fi
      ;;
  esac
done
case "$prop" in
  NRestarts)        echo "5" ;;
  StartLimitBurst)  echo "3" ;;
  Restart)          echo "on-failure" ;;
  Result)           echo "exit-code" ;;
  ExecMainStatus)   echo "1" ;;
  MemoryPeak)       echo "" ;;
  Unit)             echo "test.service" ;;
  Description)      echo "stub" ;;
  LoadState)        echo "loaded" ;;
  *)                echo "" ;;
esac
STUB
chmod +x "$scratch/bin/systemctl"

# Seed an auditor-resolved STOP-REASON for the given unit (live closeout
# shape: the summoning trip is nested under detail.summoning_trip).
seed_closeout() {
  local unit="${1:-fleet-heartbeat.service}"
  cat > "$SR" <<EOF
{"reason":"auditor-resolved","detail":{"summoning_trip":{"reason":"unit-failure","detail":{"unit":"$unit","result":"exit-code","exit_status":"1","memory_peak":"","oom_signal":"no"},"timestamp":"2026-09-02T10:00:00.000Z"},"resolution":"35th-in-class trip; closeout-skip per PR #433"},"timestamp":"2026-09-02T10:30:00.000Z","extension":"senior-auditor","source":"senior-auditor"}
EOF
}

state_n() {
  jq -r ".\"$1\".n // 0" "$REC" 2>/dev/null || echo missing
}

writer_run() {
  local unit="${1:-fleet-heartbeat.service}"
  ( "$writer" "$unit" 2>&1 || true )
}

# ---- Case A: first closeout-skipped repeat writes fresh (n=1) ------------
# With suppress_n=3, the first and second repeats still dispatch an auditor
# (they confirm the class is still in-class); only from the 3rd onward does
# the trip layer stop re-summoning.
rm -f "$REC"
seed_closeout
old_hash=$(sha256sum "$SR" | awk '{print $1}')

out=$(writer_run)
grep -q "verdict=WRITE" <<<"$out" \
  || fail "first repeat must be verdict=WRITE, got: $out"
grep -q "suppressing recurring" <<<"$out" \
  && fail "first repeat must NOT suppress, got: $out"
new_reason=$(jq -r '.reason // ""' "$SR")
[[ "$new_reason" = "unit-failure" ]] \
  || fail "first repeat must overwrite SR with reason=unit-failure, got: $new_reason"
[[ "$(state_n fleet-heartbeat.service)" = "1" ]] \
  || fail "closeout count must be 1 after first repeat, got: $(state_n fleet-heartbeat.service)"
ok "first closeout-skipped repeat -> fresh STOP-REASON (auditor still dispatched), n=1"

# ---- Case B: second closeout-skipped repeat writes fresh (n=2) -----------
seed_closeout
out=$(writer_run)
grep -q "verdict=WRITE" <<<"$out" \
  || fail "second repeat must be verdict=WRITE, got: $out"
grep -q "suppressing recurring" <<<"$out" \
  && fail "second repeat must NOT suppress, got: $out"
[[ "$(state_n fleet-heartbeat.service)" = "2" ]] \
  || fail "closeout count must be 2 after second repeat, got: $(state_n fleet-heartbeat.service)"
ok "second closeout-skipped repeat -> fresh STOP-REASON (auditor still dispatched), n=2"

# ---- Case C: third closeout-skipped repeat SUPPRESSES --------------------
# The trip layer must stop re-summoning the auditor: SR stays the previous
# auditor-resolved closeout (hash unchanged), the writer says so loudly.
seed_closeout
old_hash=$(sha256sum "$SR" | awk '{print $1}')

out=$(writer_run)
grep -q "suppressing recurring closeout-skipped class" <<<"$out" \
  || fail "third repeat must be suppressed, got: $out"
[[ "$(state_n fleet-heartbeat.service)" = "3" ]] \
  || fail "closeout count must be 3 after suppression, got: $(state_n fleet-heartbeat.service)"
new_hash=$(sha256sum "$SR" | awk '{print $1}')
[[ "$old_hash" = "$new_hash" ]] \
  || fail "suppressed trip must NOT overwrite STOP-REASON (hash changed $old_hash -> $new_hash)"
[[ "$(jq -r '.reason // ""' "$SR")" = "auditor-resolved" ]] \
  || fail "suppressed trip must leave the prior auditor-resolved closeout in place"
ok "third closeout-skipped repeat -> STOP-REASON write suppressed, no new auditor dispatch"

# ---- Case D: a different class after N closeouts resets + writes fresh ----
# The class changes (exit status 2 instead of 1) — a new fault must not be
# swallowed by stale suppression state even though the count already hit N.
seed_closeout
cat > "$scratch/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
prop=""
for a in "$@"; do
  case "$a" in
    -p) prop_next=1 ;;
    -p*) prop="${a#-p}" ;;
    *)
      if [ "${prop_next:-0}" = "1" ]; then prop="$a"; prop_next=0; fi
      ;;
  esac
done
case "$prop" in
  NRestarts)        echo "5" ;;
  StartLimitBurst)  echo "3" ;;
  Restart)          echo "on-failure" ;;
  Result)           echo "exit-code" ;;
  ExecMainStatus)   echo "2" ;;
  MemoryPeak)       echo "" ;;
  Unit)             echo "test.service" ;;
  Description)      echo "stub" ;;
  LoadState)        echo "loaded" ;;
  *)                echo "" ;;
esac
STUB
chmod +x "$scratch/bin/systemctl"

out=$(writer_run)
grep -q "suppressing recurring" <<<"$out" \
  && fail "class changed -> must NOT suppress, got: $out"
[[ "$(state_n fleet-heartbeat.service)" = "1" ]] \
  || fail "class change must reset count to 1, got: $(state_n fleet-heartbeat.service)"
[[ "$(jq -r '.reason // ""' "$SR")" = "unit-failure" ]] \
  || fail "class change must write a fresh STOP-REASON (reason=unit-failure)"
ok "different class after N closeouts -> count reset, fresh STOP-REASON (new fault surfaces)"

# ---- Case E: OOM-kill on a recurring unit always writes fresh -------------
# A recurrent OOM is new evidence, never a closeout class (the same carve-out
# the #2614 re-fire dedupe honours).
cat > "$scratch/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
prop=""
for a in "$@"; do
  case "$a" in
    -p) prop_next=1 ;;
    -p*) prop="${a#-p}" ;;
    *)
      if [ "${prop_next:-0}" = "1" ]; then prop="$a"; prop_next=0; fi
      ;;
  esac
done
case "$prop" in
  NRestarts)        echo "5" ;;
  StartLimitBurst)  echo "3" ;;
  Restart)          echo "on-failure" ;;
  Result)           echo "oom-kill" ;;
  ExecMainStatus)   echo "137" ;;
  MemoryPeak)       echo "" ;;
  Unit)             echo "test.service" ;;
  Description)      echo "stub" ;;
  LoadState)        echo "loaded" ;;
  *)                echo "" ;;
esac
STUB
chmod +x "$scratch/bin/systemctl"

seed_closeout
# Push the stored count past the suppression threshold first.
jq -n --arg u fleet-heartbeat.service \
  '{"fleet-heartbeat.service": {"n": 9, "fingerprint": "exit-code|1|FAILED-COMMAND-SWALLOWED,DEBUG-PLAYBOOK-MISSING", "last": 1}}' \
  > "$REC"

out=$(writer_run)
grep -q "suppressing recurring" <<<"$out" \
  && fail "OOM-kill must never suppress, got: $out"
[[ "$(jq -r '.reason // ""' "$SR")" = "unit-failure" ]] \
  || fail "OOM-kill must write a fresh STOP-REASON (reason=unit-failure)"
[[ "$(jq -r '.detail.oom_signal // ""' "$SR")" = "yes" ]] \
  || fail "OOM-kill STOP-REASON must carry oom_signal=yes"
ok "OOM-kill -> always fresh STOP-REASON (recurrent OOM is new evidence, never suppressed)"

# ---- Case F: prior SR is a trip in flight (unit-failure) -> reset+write ---
# No auditor-resolved closeout on the prior trip: the recurrence gate cannot
# suppress (fail-open), the counter resets to 0.
cat > "$scratch/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
prop=""
for a in "$@"; do
  case "$a" in
    -p) prop_next=1 ;;
    -p*) prop="${a#-p}" ;;
    *)
      if [ "${prop_next:-0}" = "1" ]; then prop="$a"; prop_next=0; fi
      ;;
  esac
done
case "$prop" in
  NRestarts)        echo "5" ;;
  StartLimitBurst)  echo "3" ;;
  Restart)          echo "on-failure" ;;
  Result)           echo "exit-code" ;;
  ExecMainStatus)   echo "1" ;;
  MemoryPeak)       echo "" ;;
  Unit)             echo "test.service" ;;
  Description)      echo "stub" ;;
  LoadState)        echo "loaded" ;;
  *)                echo "" ;;
esac
STUB
chmod +x "$scratch/bin/systemctl"

cat > "$SR" <<'EOF'
{"reason":"unit-failure","detail":{"unit":"fleet-heartbeat.service","result":"exit-code","exit_status":"1","memory_peak":"","oom_signal":"no"},"timestamp":"2026-09-02T10:00:00.000Z","extension":"unit-escalation","source":"unit-escalation"}
EOF
jq -n '{"fleet-heartbeat.service": {"n": 7, "fingerprint": "exit-code|1|FAILED-COMMAND-SWALLOWED,DEBUG-PLAYBOOK-MISSING", "last": 1}}' \
  > "$REC"

out=$(writer_run)
grep -q "suppressing recurring" <<<"$out" \
  && fail "trip in flight -> must NOT suppress, got: $out"
[[ "$(state_n fleet-heartbeat.service)" = "0" ]] \
  || fail "trip in flight must reset count to 0, got: $(state_n fleet-heartbeat.service)"
ok "prior SR not a closeout (trip in flight) -> counter reset, fresh STOP-REASON"

# ---- Case G: closeout is for a DIFFERENT unit -> fresh write ---------------
# An auditor-resolved SR for another unit says nothing about this unit; never
# suppress across units.
rm -f "$REC"
seed_closeout "siterep-live-canary.service"

out=$(writer_run "fleet-heartbeat.service")
grep -q "suppressing recurring" <<<"$out" \
  && fail "closeout of another unit must NOT suppress this unit, got: $out"
[[ "$(jq -r '.reason // ""' "$SR")" = "unit-failure" ]] \
  || fail "different-unit closeout must write a fresh STOP-REASON"
[[ "$(state_n fleet-heartbeat.service)" = "0" ]] \
  || fail "different-unit closeout must keep this unit's count at 0, got: $(state_n fleet-heartbeat.service)"
ok "closeout for a different unit -> fresh STOP-REASON (no cross-unit suppression)"

echo "ALL OK: unit-escalation-write closeout-skipped recurrence suppression (fleet-ops#2912)"