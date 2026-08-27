#!/usr/bin/env bash
# tests/pi-packet-verdict.test.sh — unit tests for the VERIFY-block checker
# (fleet-ops#1134). The checker is the "real verdict" engine; this file
# proves it can parse, run, and detect worker/real mismatch.
#
# Hosted under tests/seat-lib.test.sh per the worker-token CI constraint
# (workers cannot add a ci.yml line). Run with `bash seat-lib.test.sh` or
# directly: `bash tests/pi-packet-verdict.test.sh`.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CHECKER="$ROOT/lib/pi-packet-verdict.py"

if [ ! -f "$CHECKER" ]; then
    echo "FAIL: checker not found at $CHECKER"
    exit 1
fi

PASS=0
FAIL=0

# run_case <name> <body> <expected_real_pass> <expected_block_pass>
#   expected_real_pass: "true" | "false"   (top-level "passed" field)
#   expected_block_pass: "true" | "false"  (block-level "passed" field, block 0)
run_case() {
    local name="$1"
    local body="$2"
    local expected_real="$3"
    local expected_block="$4"

    local tmp; tmp=$(mktemp)
    printf '%s' "$body" > "$tmp"

    local out
    out=$(python3 "$CHECKER" --body "$tmp" 2>&1 || true)
    rm -f "$tmp"

    local real_pass block_pass
    real_pass=$(echo "$out" | python3 -c "import sys, json
try:
    d = json.load(sys.stdin)
    print('true' if d.get('passed') is True else 'false' if d.get('passed') is False else 'none')
except: print('none')" 2>/dev/null)
    block_pass=$(echo "$out" | python3 -c "import sys, json
try:
    d = json.load(sys.stdin)
    blocks = d.get('blocks') or []
    if not blocks: print('none')
    else: print('true' if blocks[0].get('passed') is True else 'false')
except: print('none')" 2>/dev/null)

    if [ "$real_pass" = "$expected_real" ] && [ "$block_pass" = "$expected_block" ]; then
        echo "OK   $name (real=$real_pass block0=$block_pass)"
        PASS=$((PASS + 1))
    else
        echo "FAIL $name (expected real=$expected_real block0=$expected_block, got real=$real_pass block0=$block_pass)"
        FAIL=$((FAIL + 1))
    fi
}

# --- Scenarios ---

# 1. Pass: must-run + matching must-match
run_case "1. block passes when must-match matches" \
"<!--VERIFY-->
must-run: echo hello world
must-match: hello
verdict: PASS
<!--END-VERIFY-->" true true

# 2. Fail: must-match doesn't match → real verdict FAIL
run_case "2. block fails when must-match misses" \
"<!--VERIFY-->
must-run: echo hello
must-match: bonjour
verdict: PASS
<!--END-VERIFY-->" false false

# 3. Multiple must-match in one block — all must match
run_case "3. block fails if ANY must-match misses" \
"<!--VERIFY-->
must-run: echo abc def
must-match: abc
must-match: xyz
verdict: PASS
<!--END-VERIFY-->" false false

# 4. Worker claims PASS but real verdict FAIL — the override trigger
run_case "4. override trigger: worker claims PASS, real is FAIL" \
"<!--VERIFY-->
must-run: false
must-match: anything
verdict: PASS
<!--END-VERIFY-->" false false

# 5. Worker correctly claims FAIL → real verdict matches
run_case "5. no override: worker correctly claimed FAIL" \
"<!--VERIFY-->
must-run: false
must-match: anything
verdict: FAIL
<!--END-VERIFY-->" false false

# 6. No VERIFY blocks → no real verdict (passed: None)
run_case "6. body with no VERIFY blocks reports no-op" \
"just some prose, no blocks" none none

# 7. Multiple blocks: any failure → whole body FAIL
run_case "7. body FAIL when second block fails" \
"<!--VERIFY-->
must-run: echo a
must-match: a
verdict: PASS
<!--END-VERIFY-->

<!--VERIFY-->
must-run: echo b
must-match: zzz
verdict: PASS
<!--END-VERIFY-->" false true

# 8. EOF-unclosed block is still parsed (graceful)
run_case "8. unclosed block at EOF still parsed" \
"<!--VERIFY-->
must-run: echo ok
must-match: ok
verdict: PASS" true true

# 9. Real worker-claim mismatch — the bug class this checker exists to catch
#    (worker says PASS, but `false` (rc=1) + must-match on success output fails)
run_case "9. catch the silent-mismatch: PASS-claim + non-zero exit + no-match" \
"<!--VERIFY-->
must-run: bash -c 'echo broken >&2; exit 7'
must-match: success-marker
verdict: PASS
<!--END-VERIFY-->" false false

echo
echo "RESULT: pass=$PASS fail=$FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
echo "OK: 9 scenarios green"
exit 0
