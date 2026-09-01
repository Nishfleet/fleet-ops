#!/usr/bin/env bash
# tests/unit-escalation-write-same-unit-rerun-dedupe.test.sh
#
# fleet-ops#2614: when a unit (e.g. fleet-heartbeat.service) keeps failing on
# every scheduler tick while a structural fault is unfixed, the writer must
# NOT generate a fresh STOP-REASON per fire — that orphan-prunes the prior
# chain state file, holds fleet_chain_open{plane=unit-escalation,hop=trip}
# at 1 forever, and burns the senior-auditor's 2-dispatch budget on a single
# root cause. The writer-side dedupe collapses same-unit re-fires inside
# SAME_UNIT_REFIRE_WINDOW_S (default 600s) to a single STOP-REASON; the
# chain stays anchored on the original hash and the metric reflects one
# open trip, not N.
#
# Runs entirely offline with a stubbed systemctl + journalctl on PATH. The
# dedupe fires BEFORE the python atomic write but AFTER every other guard
# (exclusion list, NRestarts, scout-futility). The dedupe is evaluated
# with jq on the existing STOP-REASON.json; tests must seed that file with
# the exact field shape the writer expects (reason, detail.unit, timestamp).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
writer="$repo_root/bin/unit-escalation-write"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$writer" ]] || fail "$writer not executable"

scratch="$(mktemp -d -t escalate-rerun-dedupe.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

mkdir -p "$scratch/bin" "$scratch/agent-state"
PATH="$scratch/bin:$PATH"
export PATH

AS="$scratch/agent-state"
SR="$AS/STOP-REASON.json"
export UNIT_ESCALATION_AGENT_STATE="$AS"
export UNIT_ESCALATION_SAME_UNIT_WINDOW=600

# Stub journalctl (returns empty — no journal lines).
cat > "$scratch/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$scratch/bin/journalctl"

# Stub systemctl — the dedupe does not need any property; every other guard
# (exclusion list / NRestarts / Restart) is evaluated AFTER the dedupe, so
# we just need plausible values to satisfy the existing code paths.
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

# Seed timestamp helper: produces an ISO 8601 string N seconds in the past.
seed_timestamp() {
    local secs="$1"
    date -u -d "@$(($(date -u +%s) - secs))" +"%Y-%m-%dT%H:%M:%S.000Z"
}

# ---- Case A: same-unit re-fire within window -> SKIPPED ----
# Seed: existing STOP-REASON for fleet-heartbeat.service, reason=unit-failure,
# timestamp 30s ago. Run writer with the same unit. Expect: skip message,
# STOP-REASON unchanged (timestamp still 30s ago, hash unchanged).
old_ts=$(seed_timestamp 30)
cat > "$SR" <<EOF
{"reason":"unit-failure","detail":{"unit":"fleet-heartbeat.service","result":"exit-code","exit_status":"1","memory_peak":"","oom_signal":"no"},"timestamp":"$old_ts","extension":"unit-escalation","source":"unit-escalation"}
EOF
old_hash=$(sha256sum "$SR" | awk '{print $1}')

out=$("$writer" "fleet-heartbeat.service" 2>&1) || rc=$?
rc=${rc:-0}
grep -q "skipping same-unit re-fire" <<<"$out" \
  || fail "expected 'skipping same-unit re-fire' skip message, got: $out"
grep -q "fleet-heartbeat.service" <<<"$out" \
  || fail "skip message must name the unit, got: $out"
new_hash=$(sha256sum "$SR" | awk '{print $1}')
new_ts=$(jq -r '.timestamp // ""' "$SR")
[[ "$old_hash" = "$new_hash" ]] \
  || fail "writer must NOT overwrite STOP-REASON on same-unit re-fire (hash changed $old_hash -> $new_hash)"
[[ "$old_ts" = "$new_ts" ]] \
  || fail "timestamp must be unchanged on skip (got $new_ts, expected $old_ts)"
[[ "$rc" -eq 0 ]] \
  || fail "writer must exit 0 on dedupe skip (got rc=$rc)"
ok "same-unit re-fire within 600s window -> STOP-REASON NOT overwritten (chain stays anchored on original hash)"

# ---- Case B: same-unit re-fire AFTER window -> writes fresh ----
# Seed: existing STOP-REASON for fleet-heartbeat.service, timestamp 700s
# ago (just past the 600s window). Run writer. Expect: fresh write, new
# hash, current timestamp.
old_ts=$(seed_timestamp 700)
cat > "$SR" <<EOF
{"reason":"unit-failure","detail":{"unit":"fleet-heartbeat.service","result":"exit-code","exit_status":"1","memory_peak":"","oom_signal":"no"},"timestamp":"$old_ts","extension":"unit-escalation","source":"unit-escalation"}
EOF
old_hash=$(sha256sum "$SR" | awk '{print $1}')

out=$("$writer" "fleet-heartbeat.service" 2>&1) || rc=$?
rc=${rc:-0}
! grep -q "skipping same-unit re-fire" <<<"$out" \
  || fail "writer MUST write fresh after window expired (got skip: $out)"
new_hash=$(sha256sum "$SR" | awk '{print $1}')
[[ "$old_hash" != "$new_hash" ]] \
  || fail "writer must overwrite STOP-REASON after window (hash unchanged)"
ok "same-unit re-fire after 600s window -> fresh STOP-REASON written (new hash)"

# ---- Case C: different unit -> always writes fresh ----
# Seed: STOP-REASON for fleet-heartbeat.service, recent. Run writer for
# siterep-live-canary.service. Expect: fresh write, hash changed.
old_ts=$(seed_timestamp 30)
cat > "$SR" <<EOF
{"reason":"unit-failure","detail":{"unit":"fleet-heartbeat.service","result":"exit-code","exit_status":"1","memory_peak":"","oom_signal":"no"},"timestamp":"$old_ts","extension":"unit-escalation","source":"unit-escalation"}
EOF
old_hash=$(sha256sum "$SR" | awk '{print $1}')

out=$("$writer" "siterep-live-canary.service" 2>&1) || rc=$?
rc=${rc:-0}
! grep -q "skipping same-unit re-fire" <<<"$out" \
  || fail "writer MUST write fresh for a different unit (got skip: $out)"
new_hash=$(sha256sum "$SR" | awk '{print $1}')
[[ "$old_hash" != "$new_hash" ]] \
  || fail "writer must overwrite STOP-REASON for a different unit (hash unchanged)"
new_unit=$(jq -r '.detail.unit // ""' "$SR")
[[ "$new_unit" = "siterep-live-canary.service" ]] \
  || fail "STOP-REASON must record the new unit, got: $new_unit"
ok "different unit -> fresh STOP-REASON, hash changed (no cross-unit overlap)"

# ---- Case D: existing STOP-REASON with terminal reason -> always writes fresh ----
# Seed: existing STOP-REASON with reason=auditor-resolved (terminal) for
# the same unit. A new failure on that unit must produce a fresh chain
# (the previous trip closed; this is a new fault).
old_ts=$(seed_timestamp 30)
cat > "$SR" <<EOF
{"reason":"auditor-resolved","detail":{"unit":"fleet-heartbeat.service","resolved_from":"unit-failure"},"timestamp":"$old_ts","extension":"unit-escalation","source":"unit-escalation"}
EOF
old_hash=$(sha256sum "$SR" | awk '{print $1}')

out=$("$writer" "fleet-heartbeat.service" 2>&1) || rc=$?
rc=${rc:-0}
! grep -q "skipping same-unit re-fire" <<<"$out" \
  || fail "writer MUST write fresh after auditor-resolved (terminal reason, got skip: $out)"
new_hash=$(sha256sum "$SR" | awk '{print $1}')
[[ "$old_hash" != "$new_hash" ]] \
  || fail "writer must overwrite STOP-REASON after auditor-resolved (hash unchanged)"
new_reason=$(jq -r '.reason // ""' "$SR")
[[ "$new_reason" = "unit-failure" ]] \
  || fail "fresh write must record reason=unit-failure, got: $new_reason"
ok "existing auditor-resolved + same-unit re-fire -> fresh unit-failure chain (prior trip closed)"

# ---- Case E: existing STOP-REASON has no detail.unit (corrupt) -> writes fresh ----
# Defensive: a corrupted prior file (jq returns "") must not block a fresh
# write. The dedupe's [ "$_rf_unit" = "$UNIT" ] short-circuits to false.
cat > "$SR" <<EOF
{"reason":"unit-failure","detail":{},"timestamp":"$old_ts","extension":"unit-escalation","source":"unit-escalation"}
EOF

out=$("$writer" "fleet-heartbeat.service" 2>&1) || rc=$?
rc=${rc:-0}
! grep -q "skipping same-unit re-fire" <<<"$out" \
  || fail "writer MUST write fresh when prior STOP-REASON has no detail.unit (got skip: $out)"
ok "corrupt prior STOP-REASON (no detail.unit) -> fresh write (defensive, no infinite skip)"

# ---- Case F: OOM-kill re-fire -> always writes fresh ----
# A recurrent OOM-kill is new evidence even on the same unit; the writer
# must not collapse it. Seed a recent unit-failure STOP-REASON, then stub
# systemctl to report Result=oom-kill so the writer flags oom_signal=yes.
cat > "$SR" <<EOF
{"reason":"unit-failure","detail":{"unit":"fleet-heartbeat.service","result":"exit-code","exit_status":"1","memory_peak":"","oom_signal":"no"},"timestamp":"$old_ts","extension":"unit-escalation","source":"unit-escalation"}
EOF
old_hash=$(sha256sum "$SR" | awk '{print $1}')

# Swap the systemctl stub to return oom-kill for this case.
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

out=$("$writer" "fleet-heartbeat.service" 2>&1) || rc=$?
rc=${rc:-0}
! grep -q "skipping same-unit re-fire" <<<"$out" \
  || fail "OOM-kill re-fire MUST write fresh (got skip: $out)"
new_hash=$(sha256sum "$SR" | awk '{print $1}')
[[ "$old_hash" != "$new_hash" ]] \
  || fail "OOM-kill re-fire must overwrite STOP-REASON (hash unchanged)"
ok "OOM-kill re-fire -> fresh STOP-REASON (new evidence, never collapse)"

# Restore default systemctl stub for any future tests in this file (none
# beyond here, but defensive against later additions).
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

echo
echo "unit-escalation-write: same-unit re-fire dedupe proven (fleet-ops#2614)"
