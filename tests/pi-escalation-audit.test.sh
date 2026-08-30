#!/usr/bin/env bash
# tests/pi-escalation-audit.test.sh
#
# fleet-ops#234 drill: the escalate-senior intake path routes open
# escalate-senior issues to the three-senior panel, and the tally files an
# agent-ready fix issue on 2-of-3 PASS (admit) or comments + closes on
# 2-of-3 FAIL (dismiss), with an already-closed guard so a retried tally can
# never double-file.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
audit="$repo_root/bin/pi-escalation-audit"
tally="$repo_root/bin/pi-escalation-audit-tally"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$audit" ]] || fail "not executable: $audit"
[[ -x "$tally" ]] || fail "not executable: $tally"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT INT TERM
export AUDIT_STATE_DIR="$scratch/votes"
export AUDIT_ESCALATION_REPO="Nishfleet/fleet-ops"
mkdir -p "$AUDIT_STATE_DIR"

write_vote() { # repo cand role verdict reason
    local dir="$AUDIT_STATE_DIR/$1/$2"
    mkdir -p "$dir"
    jq -n --arg repo "$1" --arg candidate "$2" --arg role "$3" \
        --arg verdict "$4" --arg reason "$5" \
        '{repo:$repo,candidate:$candidate,role:$role,verdict:$verdict,reason:$reason,at:"2026-08-27T00:00:00Z"}' \
        >"$dir/$3.vote"
}

# --- mock gh: logs every call, canned responses per scenario -----------------
mk_gh() { # $1 = gh log path
    local ghlog="$1"
    cat >"$scratch/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$ghlog"
if [[ "\$*" == *"issue list"* ]]; then
  cat <<'ISSUES'
[{"number": 456, "title": "escalation 456", "labels": [{"name": "agent-ready"}, {"name": "escalate-senior"}]}]
ISSUES
  exit 0
fi
if [[ "\$*" == *"--json state"* ]]; then
  echo "$GH_ISSUE_STATE"
  exit 0
fi
if [[ "\$*" == *"--json title,body"* ]]; then
  echo '{"title": "escalation 456", "body": "a red CI check"}'
  exit 0
fi
if [[ "\$*" == *"issue create"* ]]; then
  echo "https://github.com/Nishfleet/fleet-ops/issues/999"
  exit 0
fi
if [[ "\$*" == *"issue comment"* ]] || [[ "\$*" == *"issue close"* ]]; then
  exit 0
fi
echo "unexpected gh: \$*" >&2
exit 1
EOF
    chmod +x "$scratch/gh"
}
GH_ISSUE_STATE="OPEN"

# --- mock systemctl: inactive units, record starts ---------------------------
mk_systemctl() { # $1 = systemctl log path
    local syslog="$1"
    cat >"$scratch/systemctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$syslog"
if [[ "\$*" == *"is-active"* ]]; then
  echo "inactive"
  exit 0
fi
if [[ "\$*" == *"start"* ]] || [[ "\$*" == *"reset-failed"* ]]; then
  exit 0
fi
exit 0
EOF
    chmod +x "$scratch/systemctl"
}

# --- mock tally: records invocation ------------------------------------------
mk_tally_stub() { # $1 = tally log path
    local tlog="$1"
    cat >"$scratch/tally" <<EOF
#!/usr/bin/env bash
echo "TALLY \$*" >>"$tlog"
exit 0
EOF
    chmod +x "$scratch/tally"
}

# =============================================================================
# Scenario 1: orchestrator starts the three panel units for an open
# escalate-senior issue, and calls the tally once all votes are present.
# =============================================================================
ghlog="$scratch/gh1.log"; syslog="$scratch/sys1.log"; tlog="$scratch/tally1.log"
mk_gh "$ghlog"; mk_systemctl "$syslog"; mk_tally_stub "$tlog"

AUDIT_GH="$scratch/gh" SYSTEMCTL="$scratch/systemctl" AUDIT_TALLY_BIN="$scratch/tally" \
    "$audit" >/dev/null 2>&1

for role in devin free-glm-5-3 straitly; do
    grep -q "start --no-block pi-escalation-audit@fleet-ops--456--$role.service" "$syslog" \
        || fail "scenario1: orchestrator must start $role panel unit: $(cat "$syslog")"
done
[[ -s "$tlog" ]] && fail "scenario1: tally must NOT run before votes exist"
ok "scenario1: orchestrator starts all three panel units, no tally before votes"

# Now write votes and re-run -> tally fires.
write_vote fleet-ops 456 devin PASS "duplicate no; real fix needed"
write_vote fleet-ops 456 free-glm-5-3 PASS "duplicates none; durable regression"
write_vote fleet-ops 456 straitly PASS "no duplicate; fix the red check"
: >"$tlog"
AUDIT_GH="$scratch/gh" SYSTEMCTL="$scratch/systemctl" AUDIT_TALLY_BIN="$scratch/tally" \
    "$audit" >/dev/null 2>&1
grep -q 'TALLY fleet-ops 456' "$tlog" || fail "scenario1: tally must run when all votes present: $(cat "$tlog")"
ok "scenario1: orchestrator calls tally when all three votes are present"

# =============================================================================
# Scenario 2: tally — 2-of-3 PASS admits: files an agent-ready fix issue,
# comments, and closes the escalate-senior wrapper.
# =============================================================================
rm -rf "$AUDIT_STATE_DIR/fleet-ops/456"; rm -f "$scratch/tally2.log" "$scratch/gh2.log"
mk_gh "$scratch/gh2.log"
write_vote fleet-ops 456 devin PASS "no duplicate; durable mechanism fix needed"
write_vote fleet-ops 456 free-glm-5-3 FAIL "duplicate of open issue; dismiss"
write_vote fleet-ops 456 straitly PASS "no duplicate; fix the regression"
AUDIT_GH="$scratch/gh" "$tally" fleet-ops 456 >/dev/null 2>&1
grep -q 'issue create' "$scratch/gh2.log" || fail "scenario2: admit must file a fix issue: $(cat "$scratch/gh2.log")"
grep -q 'issue close 456' "$scratch/gh2.log" || fail "scenario2: admit must close the wrapper: $(cat "$scratch/gh2.log")"
grep -q 'agent-ready' "$scratch/gh2.log" || fail "scenario2: fix issue must carry agent-ready"
ok "scenario2: 2-of-3 PASS files an agent-ready fix issue and closes the wrapper"

# =============================================================================
# Scenario 3: tally — 2-of-3 FAIL dismisses: comments reasons and closes, no fix issue.
# =============================================================================
rm -rf "$AUDIT_STATE_DIR/fleet-ops/456"; rm -f "$scratch/gh3.log"
mk_gh "$scratch/gh3.log"
write_vote fleet-ops 456 devin FAIL "duplicate of #123; no durable work"
write_vote fleet-ops 456 free-glm-5-3 FAIL "transient flake already self-resolved; not durable"
write_vote fleet-ops 456 straitly PASS "no duplicate but low value"
AUDIT_GH="$scratch/gh" "$tally" fleet-ops 456 >/dev/null 2>&1
grep -q 'issue close 456' "$scratch/gh3.log" || fail "scenario3: dismiss must close the wrapper: $(cat "$scratch/gh3.log")"
grep -q 'issue comment' "$scratch/gh3.log" || fail "scenario3: dismiss must comment the reasons: $(cat "$scratch/gh3.log")"
grep -q 'issue create' "$scratch/gh3.log" && fail "scenario3: dismiss must NOT file a fix issue: $(cat "$scratch/gh3.log")"
ok "scenario3: 2-of-3 FAIL dismisses (comment + close, no fix issue)"

# =============================================================================
# Scenario 4: tally — pending (no 2-of-3) does nothing.
# =============================================================================
rm -rf "$AUDIT_STATE_DIR/fleet-ops/456"; rm -f "$scratch/gh4.log"
mk_gh "$scratch/gh4.log"
write_vote fleet-ops 456 devin PASS "no duplicate; fix it"
write_vote fleet-ops 456 free-glm-5-3 FAIL "duplicate"
# straitly vote absent
AUDIT_GH="$scratch/gh" "$tally" fleet-ops 456 >/dev/null 2>&1
grep -q 'issue create' "$scratch/gh4.log" && fail "scenario4: pending must not file"
grep -q 'issue close' "$scratch/gh4.log" && fail "scenario4: pending must not close"
ok "scenario4: pending panel takes no action"

# =============================================================================
# Scenario 5: tally — already-closed guard prevents a double-file on retry.
# =============================================================================
rm -rf "$AUDIT_STATE_DIR/fleet-ops/456"; rm -f "$scratch/gh5.log"
GH_ISSUE_STATE="CLOSED"
mk_gh "$scratch/gh5.log"
write_vote fleet-ops 456 devin PASS "no duplicate; fix"
write_vote fleet-ops 456 free-glm-5-3 PASS "no duplicate; durable"
write_vote fleet-ops 456 straitly PASS "no duplicate; fix the red"
AUDIT_GH="$scratch/gh" "$tally" fleet-ops 456 >/dev/null 2>&1
grep -q 'issue create' "$scratch/gh5.log" && fail "scenario5: closed guard must not re-file: $(cat "$scratch/gh5.log")"
ok "scenario5: already-closed wrapper is not re-filed (double-file guard)"

# =============================================================================
# Scenario 6: orchestrator re-runs a role whose vote is a SKIP, instead of
# treating it as present and calling the tally (fleet-ops#1424 wedge: a
# transient provider SKIP counted as neither PASS nor FAIL and left the
# panel stuck at 1-1 forever).
# =============================================================================
rm -rf "$AUDIT_STATE_DIR/fleet-ops/456"; rm -f "$scratch/tally6.log" "$scratch/sys6.log"
mk_gh "$scratch/gh6.log"
mk_systemctl "$scratch/sys6.log"; mk_tally_stub "$scratch/tally6.log"
write_vote fleet-ops 456 devin PASS "no duplicate; durable fix needed"
write_vote fleet-ops 456 free-glm-5-3 FAIL "duplicate of open issue"
write_vote fleet-ops 456 straitly SKIP "provider returned exit 1: transient failure"
AUDIT_GH="$scratch/gh" SYSTEMCTL="$scratch/systemctl" AUDIT_TALLY_BIN="$scratch/tally" \
    "$audit" >/dev/null 2>&1
[[ -s "$scratch/sys6.log" ]] || fail "scenario6: orchestrator must act on the SKIP'd role"
grep -q 'start --no-block pi-escalation-audit@fleet-ops--456--straitly.service' "$scratch/sys6.log" \
    || fail "scenario6: must re-run the SKIP'd straitly role: $(cat "$scratch/sys6.log")"
[[ -s "$scratch/tally6.log" ]] && fail "scenario6: must NOT tally with a SKIP vote in place: $(cat "$scratch/tally6.log")"
# And the SKIP vote file must be gone so it cannot wedge a later tally.
[ -f "$AUDIT_STATE_DIR/fleet-ops/456/straitly.vote" ] \
    && fail "scenario6: SKIP vote must be discarded, not left in place"
ok "scenario6: SKIP vote is discarded and the role re-run instead of wedging the panel"

# =============================================================================
# Scenario 7: contracts — MANIFEST installs the new files.
# =============================================================================
grep -q 'bin/pi-escalation-audit ' "$repo_root/MANIFEST" \
    || fail "MANIFEST must install bin/pi-escalation-audit"
grep -q 'bin/pi-escalation-audit-tally' "$repo_root/MANIFEST" \
    || fail "MANIFEST must install bin/pi-escalation-audit-tally"
grep -q 'systemd/pi-escalation-audit@.service' "$repo_root/MANIFEST" \
    || fail "MANIFEST must install systemd/pi-escalation-audit@.service"
grep -q 'systemd/pi-escalation-audit.service' "$repo_root/MANIFEST" \
    || fail "MANIFEST must install systemd/pi-escalation-audit.service"
grep -q 'systemd/pi-escalation-audit.timer' "$repo_root/MANIFEST" \
    || fail "MANIFEST must install systemd/pi-escalation-audit.timer"
grep -q 'prompts/escalation-auditor.md' "$repo_root/MANIFEST" \
    || fail "MANIFEST must install prompts/escalation-auditor.md"
ok "scenario6: MANIFEST installs the escalation panel files"

echo "all pi-escalation-audit cases passed"
