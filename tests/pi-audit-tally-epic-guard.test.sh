#!/usr/bin/env bash
# tests/pi-audit-tally-epic-guard.test.sh
#
# fleet-ops#4451 replay drill for the three panel faults that discarded all six
# scoped items of Nish-ratified EPIC Nishfleet/0509#1367 (#1382-#1387) and left
# 243 identical "discarded" comments on #1382:
#
#   1. idempotence  - a candidate already labelled discarded/agent-ready is
#                     never re-tallied and never re-commented.
#   2. epic guard   - a 2-of-3 FAIL on an epic-linked candidate marks it
#                     spec-needed and KEEPS scout-candidate; it is never
#                     discarded.
#   3. SKIP arithmetic - a SKIP is not a vote. 2 FAIL + 1 SKIP is PENDING,
#                     not a 2-of-2 discard.
#
# Fails on the pre-fix binary (which re-commented, discarded epic children, and
# treated 2-of-2 as a majority) and passes on this one.
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

# gh shim: logs every call. `issue view --json ...` answers from a fixture file
# so the tally sees real labels/title/body; every other verb is a no-op 0.
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

# =============================================================================
# 1. idempotence: already discarded -> zero writes, zero comments
# =============================================================================
log1="$scratch/gh1.log"; : >"$log1"
cat >"$scratch/issue1.json" <<'J'
{"title":"Q1 evals harness for full-site watch","body":"plain body, no epic","labels":[{"name":"discarded"}]}
J
mk_gh "$log1" "$scratch/issue1.json"
d="$AUDIT_STATE_DIR/0509/1382"
write_vote "$d" devin FAIL "no direct user-facing product impact, duplicate check done, north-star"
write_vote "$d" free-glm FAIL "not the smallest durable fix, not a duplicate, parity only"
write_vote "$d" senior FAIL "no customer impact, no duplicate"
run_tally 0509 1382
grep -q 'issue comment' "$log1" && fail "idempotence: re-commented on an already-discarded candidate"
grep -q 'issue edit' "$log1" && fail "idempotence: re-labelled an already-discarded candidate"
grep -q 'issue view' "$log1" || fail "idempotence: never read the labels"
ok "already-discarded candidate: read labels, wrote nothing (no 243-comment repeat)"

# same for an already-admitted candidate
log1b="$scratch/gh1b.log"; : >"$log1b"
cat >"$scratch/issue1b.json" <<'J'
{"title":"some candidate","body":"body","labels":[{"name":"agent-ready"},{"name":"priority"}]}
J
mk_gh "$log1b" "$scratch/issue1b.json"
run_tally 0509 1382
grep -qE 'issue (comment|edit)' "$log1b" && fail "idempotence: wrote to an already-agent-ready candidate"
ok "already-agent-ready candidate: no re-tally write"

# =============================================================================
# 2. epic guard: 2-of-3 FAIL on an epic child -> spec-needed, NOT discarded
# =============================================================================
for fixture in \
  '{"title":"EPIC #1367 Q1: evals harness","body":"scoped item","labels":[{"name":"scout-candidate"}]}' \
  '{"title":"Q2 wiring","body":"Part of the chain in docs/epics/full-site-watch.md","labels":[{"name":"scout-candidate"}]}' \
  '{"title":"Q3 UI","body":"serves EPIC (Nish): full-site watch","labels":[{"name":"scout-candidate"}]}'
do
    log2="$scratch/gh2.log"; : >"$log2"
    printf '%s\n' "$fixture" >"$scratch/issue2.json"
    mk_gh "$log2" "$scratch/issue2.json"
    d="$AUDIT_STATE_DIR/0509/1383"; rm -rf "$d"
    write_vote "$d" devin FAIL "eval harness has no direct user-facing product impact, not a duplicate, north-star"
    write_vote "$d" free-glm FAIL "not the smallest durable fix, no duplicate, parity"
    write_vote "$d" senior PASS "see #1383 and app/lib/x.ts, no duplicate, customer edge"
    run_tally 0509 1383
    grep -q 'add-label discarded' "$log2" && fail "epic guard: discarded an epic-linked candidate ($fixture)"
    grep -q 'remove-label scout-candidate' "$log2" && fail "epic guard: dropped scout-candidate ($fixture)"
    grep -q 'add-label spec-needed' "$log2" || fail "epic guard: did not mark spec-needed ($fixture)"
    grep -q 'issue comment' "$log2" || fail "epic guard: did not name the failing bar ($fixture)"
done
ok "epic-linked candidates (title EPIC #n / docs/epics/ / EPIC (Nish):) never discarded, marked spec-needed"

# a NON-epic candidate with the same votes is still discarded (guard is narrow)
log3="$scratch/gh3.log"; : >"$log3"
cat >"$scratch/issue3.json" <<'J'
{"title":"tweak the footer margin","body":"no epic anywhere","labels":[{"name":"scout-candidate"}]}
J
mk_gh "$log3" "$scratch/issue3.json"
d="$AUDIT_STATE_DIR/0509/1400"; rm -rf "$d"
write_vote "$d" devin FAIL "refactor for its own sake, not a duplicate, parity"
write_vote "$d" free-glm FAIL "no customer impact, no duplicate"
write_vote "$d" senior FAIL "duplicate of nothing, no north-star"
run_tally 0509 1400
grep -q 'add-label discarded' "$log3" || fail "narrowness: a non-epic 2-of-3 FAIL must still be discarded"
ok "non-epic candidate with 2-of-3 FAIL still discarded (guard does not leak)"

# =============================================================================
# 2b. epic guard, #6151 shapes: the bare "EPIC:" title (colon, no #number) and
#     the `epic` label. 0509#3171 sailed through all four #4451 patterns and
#     was discarded 2026-09-12 despite a senior PASS vote.
# =============================================================================
# case A: the 0509#3171 replay - title starts "EPIC: ", plain body, no epic
# label. The title shape alone must save it.
log8="$scratch/gh8.log"; : >"$log8"
cat >"$scratch/issue8.json" <<'J'
{"title":"EPIC: track self and competitors across the internet - media mentions + blogging/social platforms (Nish direction 2026-09-12)","body":"plain body, no epic markers, no docs/epics/ path","labels":[{"name":"scout-candidate"}]}
J
mk_gh "$log8" "$scratch/issue8.json"
d4="$AUDIT_STATE_DIR/0509/3171"; rm -rf "$d4"
write_vote "$d4" devin FAIL "no direct user-facing product impact, not a duplicate"
write_vote "$d4" free-glm FAIL "not the smallest durable fix, no duplicate"
write_vote "$d4" senior PASS "see #3171 and app/lib/x.ts, no duplicate, customer edge"
run_tally 0509 3171
grep -q 'add-label discarded' "$log8" && fail "epic guard #6151: discarded a bare 'EPIC:'-title candidate (0509#3171 replay)"
grep -q 'remove-label scout-candidate' "$log8" && fail "epic guard #6151: dropped scout-candidate on a bare 'EPIC:'-title candidate"
grep -q 'add-label spec-needed' "$log8" || fail "epic guard #6151: did not mark spec-needed on a bare 'EPIC:'-title candidate"
ok "0509#3171 replay: bare 'EPIC:'-title candidate never discarded, marked spec-needed"

# case B: the `epic` label alone (plain title, plain body) must also save it.
log9="$scratch/gh9.log"; : >"$log9"
cat >"$scratch/issue9.json" <<'J'
{"title":"competitor watch tactics","body":"plain body, no epic markers, no docs/epics/ path","labels":[{"name":"scout-candidate"},{"name":"epic"}]}
J
mk_gh "$log9" "$scratch/issue9.json"
d5="$AUDIT_STATE_DIR/0509/3172"; rm -rf "$d5"
write_vote "$d5" devin FAIL "no direct user-facing product impact, not a duplicate"
write_vote "$d5" free-glm FAIL "not the smallest durable fix, no duplicate"
write_vote "$d5" senior PASS "see #3172 and app/lib/x.ts, no duplicate, customer edge"
run_tally 0509 3172
grep -q 'add-label discarded' "$log9" && fail "epic guard #6151: discarded an epic-labelled candidate"
grep -q 'remove-label scout-candidate' "$log9" && fail "epic guard #6151: dropped scout-candidate on an epic-labelled candidate"
grep -q 'add-label spec-needed' "$log9" || fail "epic guard #6151: did not mark spec-needed on an epic-labelled candidate"
ok "epic-labelled candidate (plain title, plain body) never discarded, marked spec-needed"

# =============================================================================
# 3. SKIP arithmetic: 2 FAIL + 1 SKIP is PENDING, never a 2-of-2 discard
# =============================================================================
log4="$scratch/gh4.log"; : >"$log4"
cat >"$scratch/issue4.json" <<'J'
{"title":"ordinary candidate","body":"no epic","labels":[{"name":"scout-candidate"}]}
J
mk_gh "$log4" "$scratch/issue4.json"
d="$AUDIT_STATE_DIR/0509/1401"; rm -rf "$d"
write_vote "$d" devin FAIL "no customer impact, not a duplicate"
write_vote "$d" free-glm FAIL "not the smallest durable fix, no duplicate"
write_vote "$d" straitly SKIP "transient provider error"
run_tally 0509 1401
grep -qE 'add-label (discarded|agent-ready)' "$log4" && fail "SKIP arithmetic: 2 FAIL + 1 SKIP decided a verdict (2-of-2)"
ok "2 FAIL + 1 SKIP stays PENDING - a SKIP does not shrink the denominator"

# and once the third seat really votes, the verdict lands
log5="$scratch/gh5.log"; : >"$log5"
mk_gh "$log5" "$scratch/issue4.json"
write_vote "$d" straitly FAIL "no north-star fit, not a duplicate"
run_tally 0509 1401
grep -q 'add-label discarded' "$log5" || fail "SKIP arithmetic: 3 real FAIL votes must discard"
ok "third real vote returns -> 2-of-3 FAIL discards as before"

# 2 PASS + 1 SKIP is likewise pending, not an admission
log6="$scratch/gh6.log"; : >"$log6"
mk_gh "$log6" "$scratch/issue4.json"
d2="$AUDIT_STATE_DIR/0509/1402"; rm -rf "$d2"
write_vote "$d2" devin PASS "see #1402 and app/lib/x.ts, not a duplicate, customer edge"
write_vote "$d2" free-glm PASS "see #1402 and app/lib/x.ts, no duplicate, north-star"
write_vote "$d2" straitly SKIP "transient"
run_tally 0509 1402
grep -q 'add-label agent-ready' "$log6" && fail "SKIP arithmetic: 2 PASS + 1 SKIP admitted on a 2-of-2"
ok "2 PASS + 1 SKIP stays PENDING too"

# narrowness: with NO SkIP recorded the tally has no evidence a third seat was
# ever dispatched, so the pre-existing "the arrived votes decide" convention
# stands (pinned by tests/fleet-heartbeat-auditor.test.sh scenario 4b). The
# quorum gate must fire on a RECORDED SKIP only.
log7="$scratch/gh7.log"; : >"$log7"
mk_gh "$log7" "$scratch/issue4.json"
d3="$AUDIT_STATE_DIR/0509/1403"; rm -rf "$d3"
write_vote "$d3" devin FAIL "no customer impact, not a duplicate"
write_vote "$d3" free-glm FAIL "not the smallest durable fix, no duplicate"
run_tally 0509 1403
grep -q 'add-label discarded' "$log7" || fail "narrowness: 2 FAIL and NO recorded SKIP must still decide (legacy convention)"
ok "2 FAIL with no SKIP recorded still decides - quorum gate fires on a recorded SKIP only"

echo "PASS: tests/pi-audit-tally-epic-guard.test.sh"
