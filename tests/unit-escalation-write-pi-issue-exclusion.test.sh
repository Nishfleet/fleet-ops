#!/usr/bin/env bash
# tests/unit-escalation-write-pi-issue-exclusion.test.sh
#
# fleet-ops#2133 / #2475 / PR #2193: unit-escalation-write must NOT write
# STOP-REASON for pi-issue@*.service failures. pi-issue workers already
# have their own failure handling:
#   - systemd Restart=on-failure with StartLimitBurst=3 (the per-worker
#     StartLimitBurst exhausted -> systemd marks the unit failed -> the
#     OnFailure=pi-issue-failed@%i.service reaper runs)
#   - OnFailure=pi-issue-failed@%i.service (reaps the claim, releases
#     labels, re-dispatches on the next intake tick)
# Without this exclusion, a pi-issue worker failure triggers the writer ->
# writes STOP-REASON -> stop-escalation SENIOR AUDITOR fires -> auditor
# consumes a healthy seat + 1.1G RAM -> if auditor dispatch fails (no_block,
# bench=overload_503) it benches that seat -> next worker fails -> repeat.
# Measured 2026-08-30 05:00Z hour: 59 pi-issue failures -> 62
# unit-escalation firings -> 33 stop-escalation auditor dispatches, each
# burning a seat the workers needed (full-wedge: 49 ready, 0 running,
# 25-worker floor violated).
#
# Runs entirely offline with a stubbed systemctl + journalctl on PATH so the
# writer reads controlled property values instead of a live unit. The
# exclusion is evaluated BEFORE the NRestarts / StartLimitBurst guard, so
# any Restart/NRestarts combination for pi-issue@*.service must skip.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
writer="$repo_root/bin/unit-escalation-write"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$writer" ]] || fail "$writer not executable"

scratch="$(mktemp -d -t escalate-pi-issue-exclusion.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

mkdir -p "$scratch/bin"
PATH="$scratch/bin:$PATH"
export PATH

AS="$scratch/agent-state"
mkdir -p "$AS"
SR="$AS/STOP-REASON.json"

# Stub journalctl (returns empty — no journal lines).
cat > "$scratch/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$scratch/bin/journalctl"

# Stub systemctl — returns plausible values for any Restart=N/always/on-failure
# / NRestarts=* / StartLimitBurst=* / Result / ExecMainStatus / MemoryPeak /
# Unit / Description / LoadState. The writer's exclusion is evaluated FIRST,
# so any property values are fine for these tests; the writer must skip
# pi-issue@*.service before it ever asks for a property.
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

# The writer writes STOP-REASON under
# ${UNIT_ESCALATION_STOP_REASON:-$AS/STOP-REASON.json}. Override the env var
# so the test controls the path without touching the live file.
export UNIT_ESCALATION_AGENT_STATE="$AS"

# Sanity seed: if the writer is broken and skips the exclusion, the writer
# would otherwise write STOP-REASON into $SR. Start with a sentinel.
printf '{"reason":"should-not-change"}\n' > "$SR"

# ---- Case A: pi-issue@fleet-ops-2475.service -> SKIPPED ----
out=$("$writer" "pi-issue@fleet-ops-2475.service" 2>&1) || rc=$?
rc=${rc:-0}
grep -q "skipping excluded unit" <<<"$out" \
  || fail "expected 'skipping excluded unit' skip message, got: $out"
grep -q "pi-issue@fleet-ops-2475.service" <<<"$out" \
  || fail "skip message must name the unit, got: $out"
! grep -q '"unit-failure"' "$SR" \
  || fail "writer must NOT write STOP-REASON for pi-issue@fleet-ops-2475.service (got: $(cat "$SR"))"
[[ "$rc" -eq 0 ]] \
  || fail "writer must exit 0 on exclusion skip (got rc=$rc)"
ok "pi-issue@fleet-ops-2475.service -> STOP-REASON not written (own failure handling: OnFailure=pi-issue-failed@%i)"

# ---- Case B: pi-issue@.service (no instance) -> SKIPPED ----
printf '{"reason":"should-not-change"}\n' > "$SR"
out=$("$writer" "pi-issue@.service" 2>&1)
grep -q "skipping excluded unit" <<<"$out" \
  || fail "expected 'skipping excluded unit' for pi-issue@.service, got: $out"
! grep -q '"unit-failure"' "$SR" \
  || fail "writer must NOT write STOP-REASON for pi-issue@.service (got: $(cat "$SR"))"
ok "pi-issue@.service -> STOP-REASON not written (template, would match no instance)"

# ---- Case C: pi-issue-failed@fleet-ops-2475.service -> NOT excluded (reaper keeps writing) ----
# Note: the reaper unit runs after the burst exhausts. Excluding
# pi-issue@* here covers the WORKER, but the reaper itself (pi-issue-failed@%i)
# is allowed to escalate on the FLEET-WIDE never-say-next path — it shares
# the stop-judge pipeline, so excluding it would orphan failure signal.
printf '{"reason":"should-not-change"}\n' > "$SR"
out=$("$writer" "pi-issue-failed@fleet-ops-2475.service" 2>&1) || rc=$?
rc=${rc:-0}
! grep -q "skipping excluded unit" <<<"$out" \
  || fail "pi-issue-failed@fleet-ops-2475.service MUST NOT be excluded (only pi-issue@*.service, the worker, is). Got skip: $out"
ok "pi-issue-failed@fleet-ops-2475.service -> NOT excluded (reaper keeps STOP-REASON path)"

# ---- Case D: unrelated unit (fleet-heartbeat.service) -> NOT excluded ----
printf '{"reason":"should-not-change"}\n' > "$SR"
out=$("$writer" "fleet-heartbeat.service" 2>&1) || rc=$?
rc=${rc:-0}
! grep -q "skipping excluded unit" <<<"$out" \
  || fail "fleet-heartbeat.service MUST NOT be excluded. Got skip: $out"
ok "fleet-heartbeat.service -> NOT excluded (genuine never-say-next stays routed)"

echo
echo "unit-escalation-write: pi-issue@* exclusion proven (fleet-ops#2133/#2475, PR #2193)"