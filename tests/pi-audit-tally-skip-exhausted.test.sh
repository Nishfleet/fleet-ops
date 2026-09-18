#!/usr/bin/env bash
# tests/pi-audit-tally-skip-exhausted.test.sh
#
# fleet-ops#4503 replay drill: a recast-exhausted SKIP (fleet-ops#3962
# "<role>.skip-exhausted" marker) must not wedge the panel at PENDING forever.
# Live case: Nishfleet/0509#1948 reached FAIL=2 + SKIP=1 with the free-glm
# seat recast-capped, so the SKIP gate blocked every verdict and the heartbeat
# alarm AUDITOR-PANEL-PENDING fired on every tick.
#
#   1. exhausted skip   - 2 FAIL + exhausted SKIP -> 2-of-2 DISCARD.
#   2. unexhausted skip - 2 FAIL + fresh SKIP stays PENDING (fleet-ops#4451
#                         arithmetic regression guard).
#   3. no majority      - 1 PASS + 1 FAIL + exhausted SKIP stays PENDING.
#   4. question path    - same exclusion in tally_question: 2 MATRIX +
#                         exhausted SKIP routes, does not stay pending.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tally="$repo_root/bin/pi-audit-tally"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$tally" ]] || fail "not executable: $tally"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT INT TERM
export AUDIT_STATE_DIR="$scratch/votes"
mkdir -p "$AUDIT_STATE_DIR"

mk_gh() { # $1 = call log   $2 = issue-json fixture
    cat >"$scratch/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$1"
if [ "\$1" = "issue" ] && [ "\$2" = "view" ]; then
    cat "$2"
    exit 0
fi
exit 0
EOF
    chmod +x "$scratch/gh"
}

run_tally() { AUDIT_GH="$scratch/gh" "$tally" "$1" "$2" >>"$scratch/tally.log" 2>&1; }

write_vote() { # dir role verdict reason
    mkdir -p "$1"
    jq -n --arg r "$2" --arg v "$3" --arg reason "$4" \
        '{role:$r,verdict:$v,reason:$reason,at:"2026-09-08T00:00:00Z"}' >"$1/$2.vote"
}

issue_json() { cat <<J
{"title":"candidate under audit","body":"plain body","labels":[{"name":"scout-candidate"}]}
J
}

# =============================================================================
# 1. 2 FAIL + exhausted SKIP -> discarded (2-of-2, the seat can never vote)
# =============================================================================
log1="$scratch/gh1.log"; : >"$log1"
issue_json >"$scratch/issue1.json"
mk_gh "$log1" "$scratch/issue1.json"
d="$AUDIT_STATE_DIR/0509/1948"
write_vote "$d" devin FAIL "pure CI tooling, no user-facing product impact, no research-delta"
write_vote "$d" senior FAIL "self-maintenance, no customer impact, no duplicate"
write_vote "$d" free-glm SKIP "provider returned exit 1"
date -u +%Y-%m-%dT%H:%M:%SZ >"$d/free-glm.skip-exhausted"
run_tally 0509 1948
grep -q -- '--add-label discarded' "$log1" || fail "case1: 2 FAIL + exhausted SKIP must discard (got calls: $(tr '\n' ' ' <"$log1"))"
ok "exhausted SKIP: 2-of-2 real votes decide -> discarded"

# =============================================================================
# 2. 2 FAIL + fresh (non-exhausted) SKIP stays PENDING (fleet-ops#4451 guard)
# =============================================================================
log2="$scratch/gh2.log"; : >"$log2"
issue_json >"$scratch/issue2.json"
mk_gh "$log2" "$scratch/issue2.json"
d="$AUDIT_STATE_DIR/0509/1999"
write_vote "$d" devin FAIL "no user-facing impact"
write_vote "$d" senior FAIL "no customer impact"
write_vote "$d" free-glm SKIP "provider returned exit 1"
run_tally 0509 1999
grep -q 'issue edit' "$log2" && fail "case2: fresh SKIP must stay PENDING, no label write (calls: $(tr '\n' ' ' <"$log2"))"
ok "fresh SKIP: still PENDING, no verdict"

# =============================================================================
# 3. 1 PASS + 1 FAIL + exhausted SKIP -> no majority, PENDING
# =============================================================================
log3="$scratch/gh3.log"; : >"$log3"
issue_json >"$scratch/issue3.json"
mk_gh "$log3" "$scratch/issue3.json"
d="$AUDIT_STATE_DIR/0509/2001"
write_vote "$d" devin PASS "fixes Nishfleet/0509 path config/auto-merge-arm.yml for dependabot"
write_vote "$d" senior FAIL "no customer impact"
write_vote "$d" free-glm SKIP "provider returned exit 1"
date -u +%Y-%m-%dT%H:%M:%SZ >"$d/free-glm.skip-exhausted"
run_tally 0509 2001
grep -q 'issue edit' "$log3" && fail "case3: 1-1 split must stay PENDING (calls: $(tr '\n' ' ' <"$log3"))"
ok "exhausted SKIP with split real votes: PENDING, no write"

# =============================================================================
# 4. question path: 2 MATRIX + exhausted SKIP -> routed, question label removed
# =============================================================================
log4="$scratch/gh4.log"; : >"$log4"
cat >"$scratch/issue4.json" <<'J'
{"title":"should we do X?","body":"blocked-on: nish-decision (money: pricing)","labels":[{"name":"question"}]}
J
mk_gh "$log4" "$scratch/issue4.json"
d="$AUDIT_STATE_DIR/0509/2003"
write_vote "$d" devin MATRIX "orchestrator route - not a Nish-reserved authority"
write_vote "$d" senior MATRIX "orchestrator route - pricing here is internal cost, not a customer ask"
write_vote "$d" free-glm SKIP "provider returned exit 1"
date -u +%Y-%m-%dT%H:%M:%SZ >"$d/free-glm.skip-exhausted"
run_tally 0509 2003
grep -q -- '--remove-label question' "$log4" || fail "case4: 2 MATRIX + exhausted SKIP must route and drop question label (calls: $(tr '\n' ' ' <"$log4"))"
ok "question path: exhausted SKIP does not block the MATRIX route"

echo "all skip-exhausted tally cases passed"
