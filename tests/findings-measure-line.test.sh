#!/usr/bin/env bash
# findings-measure-line.test.sh — the judges' measure.sh emits the findings
# ledger line (fleet-ops#5443) and fails closed (never a fabricated green).
# Hermetic: FINDINGS_LEDGER_TEST points at a fake ledger.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
LED=/tmp/findings-measure-line.test.jsonl
rm -f "$LED"

# 1. with a ledger containing carried_over: the line reports it, not zeros
python3 "$HERE/lib/findings_ledger.py" append --ledger "$LED" \
  --source-organ fleet-blind-audit --run-id 20260901T000000Z \
  --title "Test carry" --evidence-ref "$HERE/measure.sh" \
  --disposition carried_over --ref "audit_fix_pending:blind-audit-cap" \
  --reason "test" >/dev/null 2>&1
out=$(FINDINGS_LEDGER_TEST=1 python3 "$HERE/lib/findings_ledger.py" measure --ledger "$LED")
echo "$out" | grep -Eq '^findings: total=[0-9]+ filed=[0-9]+ carried_over=1 oldest_carry_h=[0-9]+ panel_fail=0$'
[ "$?" = 0 ] || { echo "FAIL: measure over carried_over ledger"; fail=1; }

# 2. empty/missing ledger: real zeros, still the exact line format
python3 "$HERE/lib/findings_ledger.py" measure --ledger /tmp/fl-missing.jsonl \
  | grep -Eq '^findings: total=0 filed=0 carried_over=0 oldest_carry_h=0 panel_fail=0$'
[ "$?" = 0 ] || { echo "FAIL: missing-ledger zeros"; fail=1; }

# 3. measure.sh (the judge feed) emits the line in the live repo tree
bf=$(FINDINGS_LEDGER_TEST=1 bash "$HERE/measure.sh" 2>/dev/null | grep -c '^findings: ')
[ "$bf" -ge 1 ] || { echo "FAIL: measure.sh carries no findings line"; fail=1; }
# (test 3 runs against the LIVE canonical ledger — a carry-over backlog in the
# fleet makes this non-zero by design; we only assert the LINE exists.)

rm -f "$LED" /tmp/fl-measure-line-real.jsonl
exit "$fail"
