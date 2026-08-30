#!/usr/bin/env bash
# tests/unit-escalation-write-retry-absorb.test.sh
#
# fleet-ops#1467: unit-escalation-write must NOT write STOP-REASON when a
# unit with Restart=on-failure is still in its retry cycle (NRestarts <
# StartLimitBurst). systemd fires OnFailure= on the FIRST failure transition,
# before Restart=on-failure executes its retry — so without this guard a
# transient fault (e.g. a 503 overload) escalates to the auditor even though
# the retry was about to absorb it. After StartLimitBurst exhaustion the unit
# enters permanent failed state and the next OnFailure trigger sees
# NRestarts >= burst and escalates normally.
#
# Proven live: pi-audit@0509--1467 hit a 503 on the first run, OnFailure
# wrote STOP-REASON (false trip), then the retry succeeded and wrote a PASS/FAIL
# vote. This test locks the fix: a NRestarts < burst Retry unit is skipped.
#
# Runs entirely offline with a stubbed systemctl + journalctl on PATH so the
# writer reads controlled property values instead of a live unit.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
writer="$repo_root/bin/unit-escalation-write"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$writer" ]] || fail "$writer not executable"

scratch="$(mktemp -d -t escalate-retry-absorb.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Stub path must override the real systemctl/journalctl.
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

# Helper: emit a stub systemctl that returns the given NRestarts / Burst /
# Restart triple for `systemctl --user show -p <Property> --value <unit>`.
# All other properties return empty (matching a real show --value).
emit_systemctl() {
  local nr="$1" burst="$2" restart="$3"
  cat > "$scratch/bin/systemctl" <<STUB
#!/usr/bin/env bash
# args: --user show -p <Property> --value <unit>
prop=""
for a in "\$@"; do
  case "\$a" in
    -p) prop_next=1 ;;
    -p*) prop="\${a#-p}" ;;
    *)
      if [ "\${prop_next:-0}" = "1" ]; then prop="\$a"; prop_next=0; fi
      ;;
  esac
done
case "\$prop" in
  NRestarts)        echo "$nr" ;;
  StartLimitBurst)  echo "$burst" ;;
  Restart)          echo "$restart" ;;
  Result)           echo "exit-code" ;;
  ExecMainStatus)   echo "1" ;;
  MemoryPeak)       echo "" ;;
  *)                echo "" ;;
esac
STUB
  chmod +x "$scratch/bin/systemctl"
}

# The writer writes STOP-REASON under
# ${UNIT_ESCALATION_STOP_REASON:-$AS/STOP-REASON.json}. Override the env var
# so the test controls the path without touching the live file.
export UNIT_ESCALATION_AGENT_STATE="$AS"

# ---- Case A: Restart=on-failure, NRestarts=0 < Burst=2 -> SKIP ----
printf '{"reason":"should-not-change"}\n' > "$SR"
emit_systemctl 0 2 on-failure
out=$("$writer" "test-retry-absorb.service" 2>&1)
grep -q "retry cycle in flight" <<<"$out" \
  || fail "expected 'retry cycle in flight' skip message, got: $out"
! grep -q '"unit-failure"' "$SR" \
  || fail "writer must NOT write STOP-REASON while retry cycle is in flight (got: $(cat "$SR"))"
ok "NRestarts=0 < Burst=2 with Restart=on-failure -> STOP-REASON not written (retry absorbs transient fault)"

# ---- Case B: NRestarts >= Burst -> write STOP-REASON (escalate after burst) ----
printf '{"reason":"should-not-change"}\n' > "$SR"
emit_systemctl 2 2 on-failure
out=$("$writer" "test-retry-exhausted.service" 2>&1)
grep -q "wrote STOP-REASON" <<<"$out" \
  || fail "writer should write STOP-REASON when NRestarts >= Burst (got: $out)"
grep -q '"unit-failure"' "$SR" \
  || fail "STOP-REASON must be written when burst exhausted"
grep -q "test-retry-exhausted.service" "$SR" \
  || fail "STOP-REASON must record the unit name"
ok "NRestarts=2 >= Burst=2 -> STOP-REASON written (escalation after retry exhaustion)"

# ---- Case C: Restart=no (no retry mechanism) -> write STOP-REASON immediately ----
printf '{"reason":"should-not-change"}\n' > "$SR"
emit_systemctl 0 0 no
out=$("$writer" "test-no-retry.service" 2>&1)
grep -q "wrote STOP-REASON" <<<"$out" \
  || fail "writer should write STOP-REASON when Restart=no (no retry to absorb)"
ok "Restart=no -> STOP-REASON written immediately (no retry to absorb)"

# ---- Case D: Restart=always, NRestarts < Burst -> SKIP ----
printf '{"reason":"should-not-change"}\n' > "$SR"
emit_systemctl 0 3 always
out=$("$writer" "test-always-retry.service" 2>&1)
grep -q "retry cycle in flight" <<<"$out" \
  || fail "expected skip for Restart=always with NRestarts < burst (got: $out)"
! grep -q '"unit-failure"' "$SR" \
  || fail "writer must NOT write STOP-REASON for Restart=always while in retry cycle"
ok "Restart=always, NRestarts=0 < Burst=3 -> skipped (retry absorbs transient fault)"

echo
echo "unit-escalation-write: retry-absorption guard proven (fleet-ops#1467)"
