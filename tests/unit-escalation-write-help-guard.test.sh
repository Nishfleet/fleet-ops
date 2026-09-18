#!/usr/bin/env bash
# tests/unit-escalation-write-help-guard.test.sh
#
# fleet-ops false-trip class (observed 2026-09-09T06:08Z AND
# 2026-09-12T08:42Z — the 09-09 diagnosis never landed a source fix, so it
# recurred): agents legitimately probe this CLI for usage
# (`unit-escalation-write --help`). Without a usage guard $1 is taken as the
# unit name and the writer emits a bogus unit-failure STOP-REASON for unit
# "--help" (journal "-- No entries --", result = the systemctl help text),
# tripping the never-say-next circuit breaker and summoning a senior auditor
# for nothing. systemd unit names never begin with "-", so ANY leading-dash
# argument is a usage probe, not a unit. This test pins: -h/--help → usage,
# exit 0; other leading-dash args → loud refusal, exit 2; and in BOTH cases
# NO STOP-REASON.json is written.
#
# Runs entirely offline; no systemctl/journalctl stubs are even needed — the
# guard must fire before any systemd call.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
writer="$repo_root/bin/unit-escalation-write"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$writer" ]] || fail "$writer not executable"

scratch="$(mktemp -d -t escalate-help-guard.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

AS="$scratch/agent-state"
SR="$AS/STOP-REASON.json"
mkdir -p "$AS"

# Case 1: --help → usage, exit 0, no STOP-REASON.
out="$("$writer" --help 2>&1)" || rc=$?
rc=${rc:-0}
[ "$rc" = "0" ] || fail "--help must exit 0, got $rc"
echo "$out" | grep -q "usage: unit-escalation-write" || fail "--help must print usage, got: $out"
[ ! -e "$SR" ] || fail "--help must NOT write STOP-REASON.json"

# Case 2: -h → same contract.
out="$("$writer" -h 2>&1)" || rc=$?
rc=${rc:-0}
[ "$rc" = "0" ] || fail "-h must exit 0, got $rc"
echo "$out" | grep -q "usage: unit-escalation-write" || fail "-h must print usage, got: $out"
[ ! -e "$SR" ] || fail "-h must NOT write STOP-REASON.json"

# Case 3: an arbitrary leading-dash argument → loud refusal, exit 2, no write.
out="$("$writer" --version 2>&1)" && rc=0 || rc=$?
[ "$rc" = "2" ] || fail "leading-dash arg must exit 2, got $rc (out: $out)"
echo "$out" | grep -q "refusing leading-dash argument" || fail "refusal must be loud, got: $out"
[ ! -e "$SR" ] || fail "leading-dash arg must NOT write STOP-REASON.json"

# Case 4 (regression): a REAL unit name still passes the guard and proceeds
# into the writer body (it will fail later on show/journal — but the guard
# must not swallow it). Stub systemctl/journalctl to control the path and
# prove the write still happens for a legit name.
mkdir -p "$scratch/bin"
cat > "$scratch/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
# Last arg is the unit; return properties matching a failed exit-code unit.
while [ $# -gt 0 ]; do
  if [ "$1" = "--value" ]; then shift; case "$2" in
    Result) echo "exit-code"; exit 0 ;;
    ExecMainStatus) echo "1"; exit 0 ;;
    MemoryPeak) echo ""; exit 0 ;;
    Restart) echo "no"; exit 0 ;;
    NRestarts) echo "0"; exit 0 ;;
    StartLimitBurst) echo "0"; exit 0 ;;
  esac; fi
  shift
done
exit 0
STUB
cat > "$scratch/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$scratch/bin/systemctl" "$scratch/bin/journalctl"

PATH="$scratch/bin:$PATH" UNIT_ESCALATION_AGENT_STATE="$AS" \
  UNIT_ESCALATION_RECURRENCE_STATE="$AS/recurrence.json" \
  UNIT_ESCALATION_GH="$scratch/bin/gh" \
  bash "$writer" "real-failed-unit.service" >/dev/null 2>&1 || true
[ -f "$SR" ] || fail "a real unit name must still reach the writer body (STOP-REASON missing)"
jq -r '.detail.unit' "$SR" | grep -q '^real-failed-unit\.service$' || fail "STOP-REASON unit mismatch: $(jq -r '.detail.unit' "$SR")"

ok "help-guard: 4/4 cases pass"
