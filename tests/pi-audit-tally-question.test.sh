#!/usr/bin/env bash
# tests/pi-audit-tally-question.test.sh
#
# fleet-ops#4474 (part 1: one store + conference gate). Proves the senior
# panel's NISH-vs-MATRIX verdict on an open `question` issue routes correctly:
#
#   1. 2-of-3 NISH        -> add `nish-reserved` (stays on the Nish tab),
#                           comment only, `question` label kept.
#   2. 2-of-3 MATRIX       -> apply the majority route and REMOVE `question`:
#                            orchestrator -> body marker rewritten to
#                            `blocked-on: orchestrator`; precedent -> post
#                            `decision-resolved:` ; worker -> add agent-ready.
#   3. SKIP never counts   -> 2 MATRIX + 1 SKIP is PENDING (fleet-ops#4451).
#   4. idempotent          -> an already nish-reserved question is never
#                            re-committed / re-routed.
#   5. no 2-of-3 consensus -> PENDING.
#
# The tally's decision is exercised through the real binary; gh is stubbed.
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

# Emit a single-line JSON fixture so jq always parses the `question` label
# (a real newline inside a JSON string is invalid and jq drops the whole item).
mk_fixture() { # $1 = out   $2 = title   $3 = body (literal \n escapes)   $4 = labels-json
    printf '{"title":%s,"body":%s,"labels":%s}\n' \
        "$(printf '%s' "$2" | jq -R .)" \
        "$(printf '%s' "$3" | jq -Rs .)" \
        "$4" > "$1"
}

QUESTION_BODY='question: should we top up straitly?\noptions: a | b | c\n\nNish-reserved ask (money). blocked-on: nish-decision (money: top up straitly)'

mk_gh() { # $1 = call log   $2 = issue-json fixture   $3 = body-file to capture
    cat >"$scratch/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$1"
if [ "\$1" = "issue" ] && [ "\$2" = "view" ]; then
    cat "$2"
    exit 0
fi
if [ "\$1" = "issue" ] && [ "\$2" = "edit" ]; then
    prev=""; bf=""
    for a in "\$@"; do
        [ "\$prev" = "--body-file" ] && bf="\$a"
        prev="\$a"
    done
    [ -n "\$bf" ] && [ -f "\$bf" ] && cat "\$bf" > "$3"
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
# 1. 2-of-3 NISH -> nish-reserved, question kept, comment only, no route edit
# =============================================================================
log1="$scratch/gh1.log"; : >"$log1"
body1="$scratch/body1.out"; : >"$body1"
mk_fixture "$scratch/issue1.json" "top up straitly" "$QUESTION_BODY" '[{"name":"question"}]'
mk_gh "$log1" "$scratch/issue1.json" "$body1"
d="$AUDIT_STATE_DIR/fleet-ops/4278"
write_vote "$d" devin NISH   "reserved: money decision, not decided in the ledger"
write_vote "$d" free-glm NISH "reserved: billing/payment, no ledger answer, not decided"
write_vote "$d" senior NISH   "reserved money ask; not decided; needs Nish"
run_tally fleet-ops 4278
grep -q 'add-label nish-reserved' "$log1" || fail "NISH: did not add nish-reserved"
grep -q 'remove-label question' "$log1" && fail "NISH: removed the question label (must stay on tab)"
grep -q 'issue comment' "$log1" || fail "NISH: did not comment that Nish must answer"
grep -q -- '--body-file' "$log1" && fail "NISH: edited the body on an admit (should be a pure admit)"
ok "2-of-3 NISH -> nish-reserved, question kept, comment only"

# =============================================================================
# 2. MATRIX orchestrator -> body marker rewritten + question removed
# =============================================================================
log2="$scratch/gh2.log"; : >"$log2"
body2="$scratch/body2.out"; : >"$body2"
mk_fixture "$scratch/issue2.json" "routable ask" "$QUESTION_BODY" '[{"name":"question"}]'
mk_gh "$log2" "$scratch/issue2.json" "$body2"
d="$AUDIT_STATE_DIR/fleet-ops/1234"
write_vote "$d" devin MATRIX   "orchestrator — not reserved, a senior decision-sweep resolves it"
write_vote "$d" free-glm MATRIX "orchestrator — no money/legal/product direction here"
write_vote "$d" senior MATRIX   "orchestrator, not a Nish question"
run_tally fleet-ops 1234
grep -q 'remove-label question' "$log2" || fail "orchestrator: did not remove the question label"
grep -q -- '--body-file' "$log2" || fail "orchestrator: did not edit the body to rewrite the marker"
grep -q 'blocked-on: orchestrator' "$body2" || (echo "body2=[$body2] (body2 file: $(cat "$body2"))"; fail "orchestrator: body marker not rewritten to blocked-on: orchestrator")
grep -q 'issue comment' "$log2" || fail "orchestrator: did not comment the routing"
ok "2-of-3 MATRIX orchestrator -> body rewritten to blocked-on: orchestrator, question removed"

# =============================================================================
# 3. MATRIX precedent -> decision-resolved comment posted, question removed
# =============================================================================
log3="$scratch/gh3.log"; : >"$log3"
body3="$scratch/body3.out"; : >"$body3"
mk_fixture "$scratch/issue3.json" "decided ask" 'question: reopen a decided thing?\noptions: a | b\nblocked-on: nish-decision' '[{"name":"question"}]'
mk_gh "$log3" "$scratch/issue3.json" "$body3"
d="$AUDIT_STATE_DIR/fleet-ops/5678"
write_vote "$d" devin MATRIX   "precedent: 2026-09-08 decisions-ledger already answers this"
write_vote "$d" free-glm MATRIX "precedent: ledger line covers it, already decided yes"
write_vote "$d" senior MATRIX   "precedent: decided already in the ledger, no Nish needed"
run_tally fleet-ops 5678
grep -q 'remove-label question' "$log3" || fail "precedent: did not remove the question label"
grep -q 'decision-resolved:' "$log3" || fail "precedent: did not post a decision-resolved comment"
ok "2-of-3 MATRIX precedent -> decision-resolved posted, question removed"

# =============================================================================
# 4. MATRIX worker -> question removed + agent-ready added
# =============================================================================
log4="$scratch/gh4.log"; : >"$log4"
body4="$scratch/body4.out"; : >"$body4"
mk_fixture "$scratch/issue4.json" "plain work task" 'question: just file the fix?\noptions: a | b\nblocked-on: nish-decision' '[{"name":"question"}]'
mk_gh "$log4" "$scratch/issue4.json" "$body4"
d="$AUDIT_STATE_DIR/fleet-ops/42"
write_vote "$d" devin MATRIX   "worker: this is a work task, not a question for Nish"
write_vote "$d" free-glm MATRIX "worker route, relabel agent-ready with the answer"
write_vote "$d" senior MATRIX   "worker: plain implementation work"
run_tally fleet-ops 42
grep -q 'remove-label question' "$log4" || fail "worker: did not remove the question label"
grep -q 'add-label agent-ready' "$log4" || fail "worker: did not relabel agent-ready"
body4_out=$(cat "$body4"); grep -q 'blocked-on: nish-decision' <<<"$body4_out" && fail "worker: nish-decision blocker not cleared from body"
ok "2-of-3 MATRIX worker -> agent-ready, question removed, blocker cleared"

# =============================================================================
# 5. SKIP not counted toward 2-of-3 for questions (fleet-ops#4451)
# =============================================================================
log5="$scratch/gh5.log"; : >"$log5"
body5="$scratch/body5.out"; : >"$body5"
mk_fixture "$scratch/issue5.json" "pending ask" "$QUESTION_BODY" '[{"name":"question"}]'
mk_gh "$log5" "$scratch/issue5.json" "$body5"
d="$AUDIT_STATE_DIR/fleet-ops/4321"
write_vote "$d" devin MATRIX "orchestrator — not reserved"
write_vote "$d" free-glm MATRIX "orchestrator"
write_vote "$d" senior SKIP  "transient seat error"
run_tally fleet-ops 4321
grep -qE 'remove-label question|add-label nish-reserved' "$log5" && fail "SKIP: 2 MATRIX + 1 SKIP decided a verdict for a question"
ok "question: 2 MATRIX + 1 SKIP stays PENDING (SKIP does not count toward 2-of-3)"

# =============================================================================
# 6. idempotent: already nish-reserved -> zero writes
# =============================================================================
log6="$scratch/gh6.log"; : >"$log6"
body6="$scratch/body6.out"; : >"$body6"
mk_fixture "$scratch/issue6.json" "already reserved" "$QUESTION_BODY" '[{"name":"question"},{"name":"nish-reserved"}]'
mk_gh "$log6" "$scratch/issue6.json" "$body6"
run_tally fleet-ops 9000
grep -qE 'issue (comment|edit)' "$log6" && fail "idempotent: wrote to an already nish-reserved question"
ok "idempotent: already nish-reserved question is never re-written"

# =============================================================================
# 7. no 2-of-3 consensus -> pending
# =============================================================================
log7="$scratch/gh7.log"; : >"$log7"
body7="$scratch/body7.out"; : >"$body7"
mk_fixture "$scratch/issue7.json" "split ask" "$QUESTION_BODY" '[{"name":"question"}]'
mk_gh "$log7" "$scratch/issue7.json" "$body7"
d="$AUDIT_STATE_DIR/fleet-ops/7777"
write_vote "$d" devin NISH   "reserved: money"
write_vote "$d" free-glm MATRIX "orchestrator — not reserved"
write_vote "$d" senior SKIP  "transient — could not vote"
run_tally fleet-ops 7777
grep -qE 'remove-label question|add-label nish-reserved' "$log7" && fail "split: 1 NISH 1 MATRIX 1 SKIP must stay PENDING"
ok "no 2-of-3 consensus stays PENDING"

echo "PASS: tests/pi-audit-tally-question.test.sh"
