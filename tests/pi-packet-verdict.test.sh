#!/usr/bin/env bash
# tests/pi-packet-verdict.test.sh — unit tests for the VERIFY-block checker
# (fleet-ops#1134). The checker is the "real verdict" engine; this file
# proves it can parse, run, and detect worker/real mismatch.
#
# Hosted under tests/seat.lib.test.sh per the worker-token CI constraint
# (workers cannot add a ci.yml line). The host line is pinned by
# tests/p14-test-listing-gate.test.sh (fleet-ops#1200). Run with
# `bash tests/seat.lib.test.sh` or directly:
# `bash tests/pi-packet-verdict.test.sh`.
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

# --- LIVE-claim gate (fleet-ops#5786) ----------------------------------------
# A deliverable may only claim LIVE/DEPLOYED/live-on-host when the same line
# cites a SHA that is an ancestor of origin/main. Fixture repo: main_sha is
# on origin/main; branch_sha is still on the worker's branch.
scratch="$(mktemp -d -t verdict-live.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
fixture="$scratch/claim-repo"
git init -q -b main "$fixture"
git -C "$fixture" config user.email t@t
git -C "$fixture" config user.name t
git -C "$fixture" commit -qm init --allow-empty
main_sha=$(git -C "$fixture" rev-parse HEAD)
git -C "$fixture" remote add origin "$fixture"
git -C "$fixture" fetch -q origin
git -C "$fixture" checkout -qb fix/issue-x
git -C "$fixture" commit -qm wip --allow-empty
branch_sha=$(git -C "$fixture" rev-parse HEAD)
git -C "$fixture" checkout -q main
export PI_VERDICT_LIVE_FETCH=0

# run_live <name> <body> <want: pass|fail>
# --live-claims mode: exit 1 + violations on a false claim, exit 0 clean.
run_live() {
    local name="$1" body="$2" want="$3"
    local tmp; tmp=$(mktemp)
    printf '%s' "$body" > "$tmp"
    local out rc
    set +e
    out=$(python3 "$CHECKER" --live-claims "$tmp" \
        --repo-dir "$fixture" --no-default-repos 2>&1)
    rc=$?
    set -e
    rm -f "$tmp"
    local got="pass"
    [ "$rc" -ne 0 ] && got="fail"
    if [ "$got" = "$want" ]; then
        echo "OK   $name (live-claims rc=$rc)"
        PASS=$((PASS + 1))
    else
        echo "FAIL $name (expected $want, got rc=$rc): $out"
        FAIL=$((FAIL + 1))
    fi
}

# 10. REPLAY — the verbatim 2026-09-12 actions.log deliverable. The worker
#     cited the PR and the branch but no merged SHA: rejected.
run_live "10. replay rejects the 2026-09-12 actions.log claim" \
"2026-09-12T03:52Z FleetSloGhRateLimitHeadroomLow RESOLVED-VERIFIED exit=0 — durable fix: lib/issue-file.py cmd_file now defers while the exporter side-car says fresh low=1; landed as PR https://github.com/Nishfleet/fleet-ops/pull/5762 (branch fix/issue-file-gh-rate-limit-gate) and LIVE on this host (deploy-clone checked out on the branch = symlink target of /home/nish/.local/{bin,lib/pi-packet}/fleet-issue-file paths); after merge, return deploy-clone to main." \
fail

# 11. REPLAY — the verbatim unit-journal line from the same incident.
run_live "11. replay rejects the 2026-09-12 journal claim" \
"- **Live on this host immediately**: deploy-clone (the canonical checkout the deployed symlinks point into) is checked out on the fix branch; noted in actions.log that it should return to main after merge." \
fail

# 12. A claim that cites a merged SHA on the same line passes.
run_live "12. LIVE claim with merged origin/main SHA passes" \
"gate is LIVE on this host: $main_sha is on origin/main" \
pass

# 13. A claim whose SHA is still on the worker's branch is rejected —
#     the exact incident shape (PR open, auto-merge off).
run_live "13. LIVE claim citing an unmerged branch SHA rejected" \
"fix is DEPLOYED to production: $branch_sha" \
fail

# 14. Claim tokens with no SHA at all are rejected; so is a SHA cited on a
#     different line (same-line rule).
run_live "14. claim with no SHA rejected" \
"the rate-limit gate is deployed and live on this host" \
fail
run_live "15. sha on a different line does not save the claim" \
"fix is DEPLOYED.
merged sha: $main_sha" \
fail

# 16. A clean deliverable (no claim tokens) is untouched by the gate.
run_live "16. deliverable without live claims passes" \
"fix landed as PR https://github.com/Nishfleet/fleet-ops/pull/5762 — merge pending; verified the checker test suite is green." \
pass

# 17. --body integration: a VERIFY-passing body with a false claim fails.
tmpb="$scratch/body17.md"
printf '<!--VERIFY-->\nmust-run: echo ok\nmust-match: ok\nverdict: PASS\n<!--END-VERIFY-->\n\nit is now live on the host\n' >"$tmpb"
if python3 "$CHECKER" --body "$tmpb" --repo-dir "$fixture" --no-default-repos >"$scratch/o17.json" 2>&1; then
    echo "FAIL 17. --body must exit 1 on a false live claim even when VERIFY blocks pass"
    FAIL=$((FAIL + 1))
elif python3 -c "import json,sys; d=json.load(open('$scratch/o17.json')); sys.exit(0 if d.get('live_claim_violations') else 1)"; then
    echo "OK   17. --body fails a VERIFY-clean deliverable with a false live claim"
    PASS=$((PASS + 1))
else
    echo "FAIL 17. --body must report live_claim_violations: $(cat "$scratch/o17.json")"
    FAIL=$((FAIL + 1))
fi

# CI host lock (fleet-ops#1200). Workers cannot add a verify-command
# line. This file must stay invoked from seat.lib.test.sh (already
# listed in ci.yml). Dropping the host is the class this issue exists
# to prevent. A filename mention in a comment is not an invoke.
host="$ROOT/tests/seat""-lib.test.sh"
if [ ! -f "$host" ]; then
    echo "FAIL 18. CI host missing: $host"
    FAIL=$((FAIL + 1))
elif grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/pi-packet-verdict\.test\.sh"?' "$host"; then
    echo "OK   18. CI host lock (seat.lib.test.sh bash-invokes this file)"
    PASS=$((PASS + 1))
else
    echo "FAIL 18. CI host lock: tests/seat.lib.test.sh must bash-invoke this file (fleet-ops#1200)"
    FAIL=$((FAIL + 1))
fi

echo
echo "RESULT: pass=$PASS fail=$FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
echo "OK: $PASS scenarios green"
exit 0
