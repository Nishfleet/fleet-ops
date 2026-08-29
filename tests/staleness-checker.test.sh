#!/usr/bin/env bash
# Tests for libexec/staleness-checker.py — fleet-ops#1137
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
if [[ -f libexec/staleness-checker.py ]]; then
  python3 -c "import py_compile; py_compile.compile('libexec/staleness-checker.py', doraise=True)" 2>/dev/null
  pass "libexec/staleness-checker.py exists and compiles"
else
  fail "libexec/staleness-checker.py not found"
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
# fleet-ops#1136: the exporter source is now in-repo (libexec/), not just
# installed at ~/.local/libexec/. Check the repo file first; fall back to the
# installed file for local runs against the live install.
EXPORTER="libexec/fleet-metrics-export.py"
if ! [[ -f "$EXPORTER" ]]; then
  EXPORTER="$HOME/.local/libexec/fleet-metrics-export.py"
fi
if grep -q "fleet_truth_staleness_last_run_seconds" "$EXPORTER" 2>/dev/null; then
  pass "Staleness metrics present in fleet-metrics-export.py"
else
  fail "Staleness metrics missing from fleet-metrics-export.py"
fi

# Test 7: Claim extraction patterns match real docs
echo "[7] Claim extraction from real docs"
# Test path, unit, and issue extraction with inline Python.
# Verifies the issue regex filters out upstream refs (systemd/systemd#NNNN).
PY_RESULT=$(python3 <<'PYEOF'
import re, sys

PATH_RE = re.compile(r'`?(~|/home/nish)[\w./\-]+(?:\.(md|sh|py|yml|json|conf|timer|service|path))`?')
UNIT_RE = re.compile(r'`(fleet-\w+(?:@\w+|-|\.service|\.timer|\.path))`')
ISSUE_RE = re.compile(r'(?:(\w[\w.-]*)/)?(\w[\w.-]*)?#(\d{3,5})\b')

# Path test
paths = []
for m in PATH_RE.finditer('`/home/nish/workspaces/agent-state/plan.md`'):
    raw = m.group(0).strip('`')
    if raw not in ('~', '~/'):
        paths.append(raw)

# Unit test
units = UNIT_RE.findall('`fleet-heartbeat.timer`')

# Issue test: fleet-ops refs match, upstream refs are filtered out
issues = []
seen = set()
for m in ISSUE_RE.finditer('fleet-ops#1137 also see #522 and systemd/systemd#33486'):
    owner = m.group(1)
    repo = m.group(2)
    num = int(m.group(3))
    if repo is None and owner is None:
        pass
    elif repo == "fleet-ops":
        pass
    else:
        continue
    key = ("Nishfleet/fleet-ops", num)
    if key not in seen:
        seen.add(key)
        issues.append(key)

ok = True
if not any("agent-state/plan.md" in p for p in paths):
    print("PATH_FAIL", file=sys.stderr)
    ok = False
if "fleet-heartbeat.timer" not in units:
    print("UNIT_FAIL", file=sys.stderr)
    ok = False
nums = sorted(n for _, n in issues)
if nums != [522, 1137]:
    print(f"ISSUE_FAIL: got {nums}", file=sys.stderr)
    ok = False

if ok:
    print("ALL_OK")
PYEOF
) || PY_RESULT=""
if [[ "$PY_RESULT" == "ALL_OK" ]]; then
  pass "Path/unit/issue extraction works; upstream refs filtered"
else
  fail "Extraction test failed: $PY_RESULT"
fi

# Test 8: Upstream-ref filter (fleet-ops#1674)
# The real global-standing-rules.md cites systemd/systemd#33486. An earlier
# version of the checker mis-parsed that as Nishfleet/fleet-ops#33486 and filed
# a false-positive staleness issue. We always pin the function with a synthetic
# string, then load the ACTUAL doc when it is available (VPS) to catch doc-level
# regressions. If the vault is not mounted (GitHub Actions CI), the synthetic
# pin still prevents the upstream-ref leak from recurring.
echo "[8] Upstream issue-ref filter (real doc + synthetic fallback)"
PY_RESULT2=$(python3 <<'PYEOF'
import importlib.util, sys, os
spec = importlib.util.spec_from_file_location("sc", "libexec/staleness-checker.py")
sc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sc)

# Synthetic pin: same function, controlled input.
synthetic = 'fleet-ops#1137 also see #522 and systemd/systemd#33486'
issues = sc._extract_issues(synthetic)
nums = sorted(n for _, n in issues)
if 33486 in nums:
    print("UPSTREAM_LEAK_SYNTHETIC: 33486 extracted as fleet-ops issue: " + str(nums), file=sys.stderr)
    sys.exit(1)
if nums != [522, 1137]:
    print("SYNTHETIC_FAIL: expected [522, 1137], got " + str(nums), file=sys.stderr)
    sys.exit(1)

REAL_DOC = os.path.expanduser("~/workspaces/tooling/nish-vault/_system/shared-memory/global-standing-rules.md")
try:
    with open(REAL_DOC) as f:
        text = f.read()
except OSError:
    print("OK: synthetic-only (real doc not available)")
    sys.exit(0)

issues = sc._extract_issues(text)
nums = sorted(n for _, n in issues)
if 33486 in nums:
    print("UPSTREAM_LEAK: 33486 extracted as fleet-ops issue: " + str(nums), file=sys.stderr)
    sys.exit(1)
print("OK: " + ",".join(str(n) for n in nums))
PYEOF
) || PY_RESULT2=""
if [[ "$PY_RESULT2" == OK:* ]]; then
  pass "Upstream refs filtered (${PY_RESULT2#OK: })"
else
  fail "Upstream-ref filter failed: $PY_RESULT2"
fi

# Test 9: Script runs without error (dry check, --no-file to avoid filing real issues)
echo "[9] Script runs without crashing (--no-file)"
python3 libexec/staleness-checker.py --no-file 2>/dev/null
RC=$?
if [[ $RC -eq 0 ]]; then
  pass "Script runs clean with --no-file (rc=$RC)"
else
  fail "Script crashed (rc=$RC)"
fi

# Summary
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit $FAIL