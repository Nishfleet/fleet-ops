#!/usr/bin/env bash
# tests/unit-escalation-write-scout-futility-dedupe.test.sh
#
# fleet-ops#2054-class loop (proven 2026-08-30): pi-scout@<repo> and
# pi-scout-repair@<repo> die on EVERY run while the repo is in a structural
# scout-dry state (drained backlog + no healthy heavy-capable seat). Each
# failure writes a fresh STOP-REASON (fresh timestamp = fresh hash), so the
# stop-escalation pipeline summons a fresh SENIOR AUDITOR every scout run on
# the SAME root cause already escalated by scout-futility-check (issue with
# marker `signal: scout-futility/<repo>`). Trips at 08:15:07Z and 10:01:19Z
# on 2026-08-30 were that loop.
#
# This test locks the dedupe gate: when the unit is a scout (or scout-repair)
# instance AND the repo's futility bin has tripped (consecutive_dry >= N=3)
# AND an open issue carries the futility marker, the writer exits 0 WITHOUT
# writing STOP-REASON. Everything else (dry below threshold, no open marker
# issue, non-scout unit) still writes normally — fail-open on gh errors.
#
# Runs entirely offline with stubbed systemctl + journalctl + gh on PATH.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
writer="$repo_root/bin/unit-escalation-write"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$writer" ]] || fail "$writer not executable"

scratch="$(mktemp -d -t escalate-futility.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

mkdir -p "$scratch/bin"
PATH="$scratch/bin:$PATH"
export PATH

# Writer's state seams -> scratch.
AS="$scratch/agent-state"
mkdir -p "$AS"
export UNIT_ESCALATION_AGENT_STATE="$AS"
FUTDIR="$scratch/futility"
mkdir -p "$FUTDIR"
export SCOUT_FUTILITY_STATE_DIR="$FUTDIR"

# Stub journalctl: no journal lines, exit 0.
cat > "$scratch/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$scratch/bin/journalctl"

# Stub systemctl: no retry-absorb interference (Restart=no, zero counters).
cat > "$scratch/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"-p Restart"*) echo "no" ;;
  *"-p NRestarts"*) echo "0" ;;
  *"-p StartLimitBurst"*) echo "0" ;;
  *"-p Result"*) echo "exit-code" ;;
  *"-p ExecMainStatus"*) echo "1" ;;
  *"-p MemoryPeak"*) echo "1024" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$scratch/bin/systemctl"

# Stub gh: emulates the writer's `--jq '... .number'` filter on issue-list
# (the writer expects the FILTERED number, empty when no marker issue).
# Honors GH_STUB_HAS_FUTILITY (open marker issue present or not). Every other
# call fails (fail-open read => escalate normally).
cat > "$scratch/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "list" ]; then
  if [ -n "${GH_STUB_HAS_FUTILITY:-}" ]; then
    printf '2054\n'
  else
    printf ''
  fi
  exit 0
fi
exit 1
STUB
chmod +x "$scratch/bin/gh"

expect_written() {
  local unit="$1" label="$2"
  if [ -f "$AS/STOP-REASON.json" ]; then
    local got
    got=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["detail"]["unit"])' "$AS/STOP-REASON.json")
    [ "$got" = "$unit" ] || fail "$label: wrote wrong unit '$got' (want '$unit')"
    ok "$label: STOP-REASON written for $unit"
  else
    fail "$label: STOP-REASON NOT written for $unit"
  fi
}

expect_skipped() {
  local unit="$1" label="$2" out
  out=$("$writer" "$unit" 2>&1)
  if [ -f "$AS/STOP-REASON.json" ]; then
    fail "$label: STOP-REASON written for $unit (dedupe gate failed)"
  fi
  case "$out" in
    *"already escalated"*) ok "$label: skipped '$unit' with LOUD dedupe note" ;;
    *) fail "$label: skip had no dedupe note: $out" ;;
  esac
}

# Scenario 1: scout in futility (dry=14) + open marker issue -> SKIP.
printf 'consecutive_dry=14\n' > "$FUTDIR/0509.state"
export GH_STUB_HAS_FUTILITY=1
expect_skipped "pi-scout@0509.service" "scenario 1 (scout, dry>=N, marker open)"

# Scenario 2: scout-repair unit, same state -> SKIP (repair twin covered).
rm -f "$AS/STOP-REASON.json"
expect_skipped "pi-scout-repair@0509.service" "scenario 2 (scout-repair twin)"

# Scenario 3: scout, dry>=N, but NO open marker issue -> WRITE (fail-open).
rm -f "$AS/STOP-REASON.json"
unset GH_STUB_HAS_FUTILITY
"$writer" "pi-scout@0509.service" >/dev/null 2>&1
expect_written "pi-scout@0509.service" "scenario 3 (no open marker issue still escalates)"

# Scenario 4: scout, dry below threshold (0) + open marker -> WRITE.
rm -f "$AS/STOP-REASON.json"
printf 'consecutive_dry=0\n' > "$FUTDIR/0509.state"
export GH_STUB_HAS_FUTILITY=1
"$writer" "pi-scout@0509.service" >/dev/null 2>&1
expect_written "pi-scout@0509.service" "scenario 4 (futility bin not tripped still escalates)"

# Scenario 5: missing state file + open marker -> WRITE (absence = escalate).
rm -f "$AS/STOP-REASON.json"
rm -f "$FUTDIR/0509.state"
export GH_STUB_HAS_FUTILITY=1
"$writer" "pi-scout@0509.service" >/dev/null 2>&1
expect_written "pi-scout@0509.service" "scenario 5 (missing state still escalates)"

# Scenario 6: non-scout unit -> untouched path WRITES.
rm -f "$AS/STOP-REASON.json"
export GH_STUB_HAS_FUTILITY=1
"$writer" "fleet-heartbeat.service" >/dev/null 2>&1
expect_written "fleet-heartbeat.service" "scenario 6 (non-scout unit unaffected)"

echo "ALL OK: unit-escalation-write scout-futility dedupe (6 scenarios)"