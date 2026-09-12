#!/usr/bin/env bash
# findings-ledger.test.sh — the canonical findings ledger writer is strict.
# The rule it enforces: EVERY finding row carries a disposition AND a ref.
# A row without one is a silent drop and this writer refuses to make one.
# Hermetic: FLEET_FINDINGS_LEDGER points at a temp file; no gh calls when
# gh_issue_map is None (no-issues backfill mode).
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PY="$HERE/lib/findings_ledger.py"
LEDGER="${FINDINGS_LEDGER_TEST:-/tmp/findings-ledger.test.jsonl}"
rm -f "$LEDGER"
fail=0
t() { if [ "$1" = 0 ]; then echo ok; else echo "FAIL: ${2:-check}"; fail=1; fi }

LA() {
  python3 "$PY" append --ledger "$LEDGER" "$@" >/dev/null 2>&1
}

# 1. happy path
before=$(wc -l < "$LEDGER" 2>/dev/null || echo 0)
LA --source-organ test --run-id r1 --title "Overflow queue" --severity high \
   --evidence-ref /tmp/e.json --disposition filed --ref "fleet-ops#5442" --reason "test"
new=$(wc -l < "$LEDGER")
[ "$new" = 1 ]; t $? "append adds exactly one row"

# 2. missing disposition refused, nothing appended
python3 "$PY" append --ledger "$LEDGER" --source-organ t --run-id r \
  --title x --evidence-ref e --ref foo --disposition "" 2>/dev/null
rc=$?
[ "$rc" -ne 0 ] && [ "$(wc -l < "$LEDGER")" = 1 ]; t $?

# 3. missing ref refused
python3 "$PY" append --ledger "$LEDGER" --source-organ t --run-id t2 --title x \
  --evidence-ref e --disposition carried_over --ref "" 2>/dev/null
[ "$?" -ne 0 ] && [ "$(wc -l < "$LEDGER")" = 1 ]; t $?

# 4. bad disposition refused
python3 "$PY" append --ledger "$LEDGER" --source-organ t --run-id t3 --title x \
  --evidence-ref e --disposition maybe --ref fleet-ops#1 2>/dev/null
[ "$?" -ne 0 ] && [ "$(wc -l < "$LEDGER")" = 1 ]; t $?

# 5. idempotent append
python3 "$PY" append --ledger "$LEDGER" --source-organ test --run-id r1 \
  --title "Overflow queue" --severity high --evidence-ref /tmp/x \
  --disposition filed --ref "fleet-ops#5442" 2>/dev/null
rc=$?
[ "$rc" = 3 ] && [ "$(wc -l < "$LEDGER")" = 1 ]; t $?

# 6. finding_id stable + 16 hex chars, title-normalised
python3 "$PY" append --ledger "$LEDGER" --source-organ t --run-id s1 \
  --title "Hex check" --evidence-ref e --disposition carried_over --ref x --reason probe 2>/dev/null
head -1 </dev/null >/dev/null
last=$(tail -1 "$LEDGER")
echo "$last" | python3 -c "import json,sys; d=json.load(sys.stdin); assert len(d['finding_id'])==16, d"

# 6b. same organ+run+title -> same finding_id, idempotent row (fresh ledger)
L6=/tmp/fl-6.jsonl; rm -f "$L6"
python3 "$PY" append --ledger "$L6" --source-organ t --run-id s1 \
  --title "Same finding" --evidence-ref e --disposition carried_over --ref x 2>/dev/null
python3 "$PY" append --ledger "$L6" --source-organ t --run-id s1 \
  --title "same   finding" --severity low --evidence-ref e2 \
  --disposition carried_over --ref audit_fix_pending:cap 2>/dev/null
[ "$(wc -l < "$L6")" = 2 ]; t $?

# 6c. but a NEW disposition upserts (backfill can move carried_over -> filed later)
python3 "$PY" append --ledger "$L6" --source-organ t --run-id s1 \
  --title "same   finding" --evidence-ref e2 --disposition filed \
  --ref "Nishfleet/fleet-ops#6000" 2>/dev/null
[ "$(wc -l < "$L6")" = 3 ]; t $?

# 7. backfill from a synthetic reports dir (no gh set: issues match off)
D=/tmp/fl-reports; rm -rf "$D"; mkdir -p "$D/20260901T000000Z"
printf '%s\n' '{"timestamp":"t","rank":"1","title":"Big Leak","verdict":"PASS","reason":"skipped: max findings 1 reached","issue":""}' > "$D/20260901T000000Z/verdicts.jsonl"
printf '%s\n' '{"timestamp":"t","rank":"2","title":"Filing cap drops evidence","verdict":"PASS","reason":"skipped: max findings 1 reached"}' >> "$D/20260901T000000Z/verdicts.jsonl"
printf '%s\n' '{"timestamp":"t","rank":"2","title":"Filed thing","verdict":"PASS","reason":"ok","issue":"https://github.com/Nishfleet/fleet-ops/issues/1"}' >> "$D/20260901T000000Z/verdicts.jsonl"
printf '%s\n' '{"timestamp":"t","rank":"3","title":"Panel said no","verdict":"FAIL","reason":""}' >> "$D/20260901T000000Z/verdicts.jsonl"
n0=$(wc -l < "$LEDGER")
python3 "$PY" backfill --ledger "$LEDGER" --reports-dir "$D" --no-issues 2>/dev/null
[ "$?" = 0 ]; t $?

# 8. backfilled everything is carried_over / filed / duplicate_of — no silent drops
python3 "$PY" validate --ledger "$LEDGER" >/dev/null; [ "$?" = 0 ]; t $?

# 9. measure line shape
python3 "$PY" measure --ledger "$LEDGER" | grep -Eq \
  '^findings: total=[0-9]+ filed=[0-9]+ carried_over=[0-9]+ oldest_carry_h=[0-9]+ panel_fail=[0-9]+$'
t $?

# 10. import-md minimal shape
P=/tmp/fl-import.md
printf '| high | Outer-in red | 0509#2962 |\n' > "$P"
python3 "$PY" import-md --ledger /tmp/fl-imp.jsonl --source-organ outside-in-audit --file "$P" >/dev/null
grep -q '"disposition": "filed"' /tmp/fl-imp.jsonl && grep -q "0509#2962" /tmp/fl-imp.jsonl
t $?

# 11. corrupt JSONL row refuses validate
printf 'not-json\n' >> /tmp/fl-bad.jsonl
python3 "$PY" validate --ledger /tmp/fl-bad.jsonl >/dev/null 2>&1
[ "$?" -ne 0 ]; t $?

rm -f "$LEDGER" /tmp/fl-bf.jsonl /tmp/fl-imp.jsonl /tmp/fl-bad.jsonl /tmp/fl-reports.jsonl
exit "$fail"
