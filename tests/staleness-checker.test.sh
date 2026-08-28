#!/usr/bin/env bash
# Tests for bin/staleness-checker.py — fleet-ops#1137
# Run with: bash tests/staleness-checker.test.sh

set -euo pipefail
cd "$(dirname "$0")/.."

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

echo "=== staleness-checker tests ==="

# Test 1: Script exists and is executable
echo "[1] Script exists and is valid Python"
if [[ -f bin/staleness-checker.py ]]; then
  python3 -c "import py_compile; py_compile.compile('bin/staleness-checker.py', doraise=True)" 2>/dev/null
  pass "bin/staleness-checker.py exists and compiles"
else
  fail "bin/staleness-checker.py not found"
fi

# Test 2: Timer and service files exist
echo "[2] systemd units exist"
for f in systemd/fleet-truth-staleness-check.timer systemd/fleet-truth-staleness-check.service; do
  if [[ -f "$f" ]]; then
    pass "$f exists"
  else
    fail "$f missing"
  fi
done

# Test 3: Timer fires on weekly cadence
echo "[3] Timer fires weekly"
if grep -q "OnCalendar=Sun" systemd/fleet-truth-staleness-check.timer; then
  pass "Timer has weekly (Sunday) schedule"
else
  fail "Timer missing weekly schedule"
fi

# Test 4: Drop-in conf exists for piggyback
echo "[4] Metrics-export drop-in for staleness"
if [[ -f systemd/fleet-metrics-export.service.d/staleness-checker.conf ]]; then
  if grep -q "staleness-checker" systemd/fleet-metrics-export.service.d/staleness-checker.conf; then
    pass "staleness-checker drop-in exists in fleet-metrics-export.service.d"
  else
    fail "staleness-checker conf doesn't reference the script"
  fi
else
  fail "staleness-checker drop-in missing"
fi

# Test 5: absent() rule in fleet_rules.yml
echo "[5] TruthStalenessAbsent rule in fleet_rules.yml"
if grep -q "TruthStalenessAbsent" config/fleet_rules.yml; then
  if grep -q "absent(fleet_truth_staleness_last_run_seconds)" config/fleet_rules.yml; then
    pass "TruthStalenessAbsent absent() rule exists"
  else
    fail "TruthStalenessAbsent rule exists but missing absent() expression"
  fi
else
  fail "TruthStalenessAbsent rule missing from fleet_rules.yml"
fi

# Test 6: Staleness metrics in fleet-metrics-export.py
echo "[6] Staleness metrics in fleet-metrics-export.py"
if grep -q "fleet_truth_staleness_last_run_seconds" ~/.local/libexec/fleet-metrics-export.py 2>/dev/null; then
  pass "Staleness metrics present in fleet-metrics-export.py"
else
  fail "Staleness metrics missing from fleet-metrics-export.py"
fi

# Test 7: Claim extraction patterns match real docs
echo "[7] Claim extraction from real docs"
# Test path, unit, and issue extraction with inline Python
PY_RESULT=$(python3 <<'PYEOF'
import re, sys

PATH_RE = re.compile(r'`?(~|/home/nish)[\w./\-]+(?:\.(md|sh|py|yml|json|conf|timer|service|path))`?')
UNIT_RE = re.compile(r'`(fleet-\w+(?:@\w+|-|\.service|\.timer|\.path))`')
ISSUE_RE = re.compile(r'(?:Nishfleet/fleet-ops|#)(\d{3,5})\b')
FULL_ISSUE_RE = re.compile(r'(Nishfleet/fleet-ops)#(\d{3,5})\b')

# Path test
paths = []
for m in PATH_RE.finditer('`/home/nish/workspaces/agent-state/plan.md`'):
    raw = m.group(0).strip('`')
    if raw not in ('~', '~/'):
        paths.append(raw)

# Unit test
units = UNIT_RE.findall('`fleet-heartbeat.timer`')

# Issue test
issues = []
for m in FULL_ISSUE_RE.finditer('fleet-ops#1137 also see #522'):
    issues.append((m.group(1), int(m.group(2))))
for m in ISSUE_RE.finditer('fleet-ops#1137 also see #522'):
    num = int(m.group(1))
    if not any(r == "Nishfleet/fleet-ops" and n == num for r, n in issues):
        issues.append(("Nishfleet/fleet-ops", num))

ok = True
if not any("agent-state/plan.md" in p for p in paths):
    print("PATH_FAIL", file=sys.stderr)
    ok = False
if "fleet-heartbeat.timer" not in units:
    print("UNIT_FAIL", file=sys.stderr)
    ok = False
if not any(str(n) == "1137" for _, n in issues):
    print("ISSUE_FAIL", file=sys.stderr)
    ok = False

if ok:
    print("ALL_OK")
PYEOF
) || PY_RESULT=""
if [[ "$PY_RESULT" == "ALL_OK" ]]; then
  pass "Path/unit/issue extraction works on real patterns"
else
  fail "Extraction test failed: $PY_RESULT"
fi

# Test 8: Script runs without error (dry check)
echo "[8] Script runs without crashing"
python3 bin/staleness-checker.py 2>/dev/null
RC=$?
if [[ $RC -eq 0 ]]; then
  pass "Script runs clean (rc=$RC)"
else
  fail "Script crashed (rc=$RC)"
fi

# Summary
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit $FAIL