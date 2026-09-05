#!/usr/bin/env bash
# tests/pi-audit-tally-escalate-senior.test.sh
#
# fleet-ops#3574 replay drill: the admission tally counts EVIDENCE-REFUSED
# per candidate in its state dir and, on the Nth refusal (ESCALATE_AFTER,
# default 3), adds escalate-senior, drops scout-candidate so the candidate is
# no longer re-queued, and posts one comment citing the 3 refusals — never
# re-queuing the same evidence-less panel forever. Fails on the pre-fix
# binary (which never counted refusals or escalated) and passes on this one.
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

# gh shim: log every call, return 0. Nothing here touches a real API.
mk_gh() { # $1 = gh log path
    cat >"$scratch/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$1"
exit 0
EOF
    chmod +x "$scratch/gh"
}

run_tally() { # repo cand
    AUDIT_GH="$scratch/gh" ESCALATE_AFTER=3 "$tally" "$1" "$2" >/dev/null 2>&1
}

# vote files: 2-of-3 PASS with keyword-only reasons => evidence gate refuses.
write_votes() { # repo cand
    local dir="$AUDIT_STATE_DIR/$1/$2"
    mkdir -p "$dir"
    jq -n '{repo:"'"$1"'",candidate:"'"$2"'",role:"devin",verdict:"PASS",reason:"meets the acceptance criteria",at:"2026-09-05T00:00:00Z"}' >"$dir/devin.vote"
    jq -n '{repo:"'"$1"'",candidate:"'"$2"'",role:"free-glm",verdict:"PASS",reason:"ready to proceed",at:"2026-09-05T00:00:00Z"}' >"$dir/free-glm.vote"
    jq -n '{repo:"'"$1"'",candidate:"'"$2"'",role:"senior",verdict:"FAIL",reason:"not ready",at:"2026-09-05T00:00:00Z"}' >"$dir/senior.vote"
}

# =============================================================================
# Scenario 1: 2 prior refusals -> 3rd refusal escalates (escalate-senior,
# drop scout-candidate, one comment citing the refusals). No 4th audit.
# =============================================================================
rm -rf "$AUDIT_STATE_DIR/0509/1240"; rm -f "$scratch/gh1.log"
mk_gh "$scratch/gh1.log"
write_votes 0509 1240
mkdir -p "$AUDIT_STATE_DIR/0509/1240"
printf '2\n' >"$AUDIT_STATE_DIR/0509/1240/.evidence-refusals"
cat >"$AUDIT_STATE_DIR/0509/1240/.evidence-refusal-reasons" <<'LEDGER'

== evidence refusal #1 (2026-09-01T00:00:00Z) ==
meets the acceptance criteria
ready to proceed

== evidence refusal #2 (2026-09-03T00:00:00Z) ==
meets the acceptance criteria
ready to proceed
LEDGER

run_tally 0509 1240
grep -q -- '--remove-label scout-candidate --add-label escalate-senior' "$scratch/gh1.log" \
    || fail "scenario1: 3rd refusal must escalate-senior and drop scout-candidate: $(cat "$scratch/gh1.log")"
grep -q 'escalate-senior' "$scratch/gh1.log" || fail "scenario1: escalate comment missing: $(cat "$scratch/gh1.log")"
grep -q 'refused for evidence 3 times' "$scratch/gh1.log" || fail "scenario1: escalate comment must cite 3 refusals: $(cat "$scratch/gh1.log")"
grep -q '== evidence refusal #1 (' "$scratch/gh1.log" || fail "scenario1: escalate comment must cite the refusal history: $(cat "$scratch/gh1.log")"
grep -q '== evidence refusal #2 (' "$scratch/gh1.log" || fail "scenario1: escalate comment must cite refusal #2: $(cat "$scratch/gh1.log")"
# No re-add of scout-candidate (candidate leaves the re-queue loop).
grep -q -- '--add-label scout-candidate' "$scratch/gh1.log" && fail "scenario1: must not re-add scout-candidate (no re-queue)"
# Counter lands exactly at 3 — no 4th audit increment on the same tally.
[[ "$(cat "$AUDIT_STATE_DIR/0509/1240/.evidence-refusals")" == "3" ]] \
    || fail "scenario1: refusal counter must be exactly 3: $(cat "$AUDIT_STATE_DIR/0509/1240/.evidence-refusals")"
ok "scenario1: 3rd EVIDENCE-REFUSED -> escalate-senior + comment citing 3 refusals, no re-queue"

# =============================================================================
# Scenario 2: 1 prior refusal -> 2nd refusal re-queues (evidence-refused
# comment only, no escalate; counter advances to 2).
# =============================================================================
rm -rf "$AUDIT_STATE_DIR/0509/1241"; rm -f "$scratch/gh2.log"
mk_gh "$scratch/gh2.log"
write_votes 0509 1241
printf '1\n' >"$AUDIT_STATE_DIR/0509/1241/.evidence-refusals"

run_tally 0509 1241
grep -q 'evidence-refused' "$scratch/gh2.log" || fail "scenario2: must post evidence-refused comment when re-queued: $(cat "$scratch/gh2.log")"
grep -q 'escalate-senior' "$scratch/gh2.log" && fail "scenario2: must NOT escalate at 2 refusals: $(cat "$scratch/gh2.log")"
grep -q -- '--remove-label scout-candidate' "$scratch/gh2.log" && fail "scenario2: must keep scout-candidate (re-queued) at 2 refusals: $(cat "$scratch/gh2.log")"
[[ "$(cat "$AUDIT_STATE_DIR/0509/1241/.evidence-refusals")" == "2" ]] \
    || fail "scenario2: refusal counter must advance to 2: $(cat "$AUDIT_STATE_DIR/0509/1241/.evidence-refusals")"
ok "scenario2: 2nd EVIDENCE-REFUSED -> re-queued (evidence-refused comment, no escalate)"

# =============================================================================
# Scenario 3: 2-of-3 PASS with evidence-citing reasons admits (no refusal
# counter change) — the evidence gate is not short-circuited by the new path.
# =============================================================================
rm -rf "$AUDIT_STATE_DIR/0509/1242"; rm -f "$scratch/gh3.log"
mk_gh "$scratch/gh3.log"
mkdir -p "$AUDIT_STATE_DIR/0509/1242"
jq -n '{repo:"0509",candidate:"1242",role:"devin",verdict:"PASS",reason:"see #1234, tests/foo",at:"2026-09-05T00:00:00Z"}' >"$AUDIT_STATE_DIR/0509/1242/devin.vote"
jq -n '{repo:"0509",candidate:"1242",role:"free-glm",verdict:"PASS",reason:"path tests/foo",at:"2026-09-05T00:00:00Z"}' >"$AUDIT_STATE_DIR/0509/1242/free-glm.vote"
jq -n '{repo:"0509",candidate:"1242",role:"senior",verdict:"FAIL",reason:"no",at:"2026-09-05T00:00:00Z"}' >"$AUDIT_STATE_DIR/0509/1242/senior.vote"
printf '1\n' >"$AUDIT_STATE_DIR/0509/1242/.evidence-refusals"

run_tally 0509 1242
grep -q 'evidence-refused' "$scratch/gh3.log" && fail "scenario3: must not refuse when reasons cite evidence: $(cat "$scratch/gh3.log")"
grep -q 'escalate-senior' "$scratch/gh3.log" && fail "scenario3: must not escalate when reasons cite evidence: $(cat "$scratch/gh3.log")"
[[ "$(cat "$AUDIT_STATE_DIR/0509/1242/.evidence-refusals")" == "1" ]] \
    || fail "scenario3: refusal counter must stay unchanged when evidence gate passes: $(cat "$AUDIT_STATE_DIR/0509/1242/.evidence-refusals")"
ok "scenario3: evidence-citing PASS reasons pass the evidence gate (no refusal, counter unchanged)"

# =============================================================================
# Scenario 4: contracts — MANIFEST installs the tally.
# =============================================================================
grep -q 'bin/pi-audit-tally' "$repo_root/MANIFEST" || fail "MANIFEST must install bin/pi-audit-tally"
ok "scenario4: MANIFEST installs bin/pi-audit-tally"
