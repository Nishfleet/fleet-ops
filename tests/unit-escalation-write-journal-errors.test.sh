#!/usr/bin/env bash
# tests/unit-escalation-write-journal-errors.test.sh
#
# fleet-ops#1526 (fleet-ops#1521 line 5): the escalation pipeline must carry
# the failing unit's last N journal ERROR lines inside STOP-REASON.json, so
# the senior auditor has the evidence without a hand journalctl grep. The
# raw 5-line tail (detail.journal) is often systemd boilerplate ("Failed to
# start X." / "Main process exited"); the real error output can sit further
# back. unit-escalation-write therefore also captures the last N
# error-priority (journalctl -p err) lines into detail.journal_errors, with
# the unit name always taken from systemd's %i instance (never an "unknown
# unit" placeholder).
#
# This test locks:
#   1. detail.unit is the exact unit name passed on argv.
#   2. detail.journal carries the raw tail.
#   3. detail.journal_errors carries the error-priority lines (only those).
#   4. UNIT_ESCALATION_JOURNAL_ERROR_LINES caps N.
#   5. A unit with no error-priority lines gets an empty journal_errors
#      array (best-effort, never a crash).
#
# Runs entirely offline with a stubbed systemctl + journalctl on PATH.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
writer="$repo_root/bin/unit-escalation-write"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$writer" ]] || fail "$writer not executable"

scratch="$(mktemp -d -t escalate-journal-errors.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

mkdir -p "$scratch/bin"
PATH="$scratch/bin:$PATH"
export PATH

AS="$scratch/agent-state"
mkdir -p "$AS"
export UNIT_ESCALATION_AGENT_STATE="$AS"

# Stub systemctl: no retry-absorb interference, plausible failure props.
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

# Stub journalctl:
#   -p err invocation -> the error-priority lines (JOURNALCTL_ERRORS env),
#     truncated to the last N lines when -n N is passed (real journalctl
#     semantics; the writer passes N via UNIT_ESCALATION_JOURNAL_ERROR_LINES).
#   -n 20 -q           -> OOM grep probe: no oom evidence.
#   anything else      -> the raw tail (JOURNALCTL_TAIL env).
cat > "$scratch/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"-p err"* ]]; then
  n=10
  for a in "$@"; do
    if [ "$a" = "-n" ]; then want_next=1; continue; fi
    if [ "${want_next:-0}" = 1 ]; then n="$a"; want_next=0; fi
  done
  printf '%s\n' "${JOURNALCTL_ERRORS:-}" | tail -n "$n"
elif [[ "$*" == *"-n 20"* ]]; then
  exit 0
else
  printf '%s\n' "${JOURNALCTL_TAIL:-}"
fi
exit 0
STUB
chmod +x "$scratch/bin/journalctl"

expect_written() {
  local unit="$1" label="$2"
  [ -f "$AS/STOP-REASON.json" ] || fail "$label: STOP-REASON.json not written"
  local got_unit got
  got_unit=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["detail"]["unit"])' "$AS/STOP-REASON.json")
  [ "$got_unit" = "$unit" ] || fail "$label: detail.unit='$got_unit', want '$unit'"
  got=$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))["detail"]
print("J=" + "|".join(d["journal"]))
print("E=" + "|".join(d["journal_errors"]))
' "$AS/STOP-REASON.json")
  printf '%s\n' "$got" > "$scratch/found-$label.txt"
}

# ---- Case A: raw tail + error tail both written, unit name exact. -----
export JOURNALCTL_TAIL="Starting stale-worker.service...
stale-worker.service: Main process exited, code=exited, status=1/FAILURE
stale-worker.service: Failed with result 'exit-code'.
Failed to start stale-worker.service.
stale-worker.service: Triggering OnFailure= dependencies."
export JOURNALCTL_ERRORS="2026-08-30T02:11:00+00:00 host stale-worker.service: KeyError: 'input_domain'
2026-08-30T02:11:01+00:00 host systemd: Failed to start stale-worker.service."
rm -f "$AS/STOP-REASON.json"

"$writer" "stale-worker.service" >/dev/null 2>&1 \
  || fail "writer exited non-zero for stale-worker.service"
expect_written "stale-worker.service" A
grep -q '^E=2026-08-30T02:11:00+00:00 host stale-worker.service: KeyError' "$scratch/found-A.txt" \
  || fail "journal_errors must carry the error-priority lines: $(cat "$scratch/found-A.txt")"
grep -q '^J=Starting stale-worker.service' "$scratch/found-A.txt" \
  || fail "journal must carry the raw tail: $(cat "$scratch/found-A.txt")"
! grep -q 'unknown unit' "$scratch/found-A.txt" \
  || fail "unit name must never be 'unknown unit'"
ok "detail.unit exact + detail.journal raw tail + detail.journal_errors error lines"

# ---- Case B: UNIT_ESCALATION_JOURNAL_ERROR_LINES caps N. ----------------
export JOURNALCTL_ERRORS="line-1
line-2
line-3"
export UNIT_ESCALATION_JOURNAL_ERROR_LINES=2
rm -f "$AS/STOP-REASON.json"
"$writer" "capped-errors.service" >/dev/null 2>&1 \
  || fail "writer exited non-zero for capped-errors.service"
expect_written "capped-errors.service" B
grep -q '^E=line-2|line-3$' "$scratch/found-B.txt" \
  || fail "journal_errors must be capped at N=2: $(cat "$scratch/found-B.txt")"
unset UNIT_ESCALATION_JOURNAL_ERROR_LINES
ok "journal_errors respects UNIT_ESCALATION_JOURNAL_ERROR_LINES cap"

# ---- Case C: no error-priority lines -> empty array, no crash. ----------
export JOURNALCTL_ERRORS=""
rm -f "$AS/STOP-REASON.json"
"$writer" "quiet-failure.service" >/dev/null 2>&1 \
  || fail "writer exited non-zero for quiet-failure.service (no error lines)"
expect_written "quiet-failure.service" C
grep -q '^E=$' "$scratch/found-C.txt" \
  || fail "journal_errors must be empty when no error lines exist: $(cat "$scratch/found-C.txt")"
ok "no error lines -> empty journal_errors array (best-effort)"

echo
echo "unit-escalation-write: journal error lines attached to STOP-REASON (fleet-ops#1526)"