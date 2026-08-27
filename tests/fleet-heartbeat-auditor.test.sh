#!/usr/bin/env bash
# tests/fleet-heartbeat-auditor.test.sh
#
# Proves the senior-auditor admission panel (fleet-ops#146):
#
#   1. fleet-heartbeat-auditor lists scout-candidate issues and starts the
#      three pi-audit@<repo>--<candidate>--<role>.service units for each.
#   2. If any audit unit is active/activating, it is not started again.
#   2b. If any needed unit is failed (StartLimitBurst exhausted), it
#       reset-failed then starts it (fleet-ops#616). A vote already on
#       disk is not restarted.
#   3. When all three votes are present, it calls pi-audit-tally.
#   4. pi-audit-tally: 2-of-3 PASS -> agent-ready, drop scout-candidate.
#   5. pi-audit-tally: 2-of-3 FAIL -> discarded, drop scout-candidate,
#      comment with reasons.
#   6. pi-audit-tally: no 2-of-3 consensus -> no label change.
#   7. A pending candidate with no active audit unit for more than one tick
#      raises an AUDITOR-PANEL-PENDING loud finding.
#
# The live `systemctl start` and `gh issue edit/comment` are the outermost
# edges and are stubbed; the dispatch and tally DECISIONS are exercised
# through the real binaries.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
auditor_bin="$repo_root/bin/fleet-heartbeat-auditor"
tally_bin="$repo_root/bin/pi-audit-tally"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$auditor_bin" ]] || fail "not executable: $auditor_bin"
[[ -x "$tally_bin" ]] || fail "not executable: $tally_bin"
command -v jq >/dev/null 2>&1 || fail "jq missing"

# --- scratch environment ----------------------------------------------------
scratch="$(mktemp -d -t auditor.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"

intake_json="$scratch/intake-repos.json"
cat >"$intake_json" <<'JSON'
{
  "repos": [{ "name": "demo" }],
  "excluded": [],
  "deferred": []
}
JSON

log_dir="$scratch/log"
triage="$scratch/triage.md"
mkdir -p "$log_dir"
: >"$triage"

state_dir="$scratch/audit-state"
mkdir -p "$state_dir"

calls="$scratch/calls.log"
: >"$calls"

gh_calls="$scratch/gh_calls.log"
: >"$gh_calls"

# --- fake gh ----------------------------------------------------------------
# $CANDIDATES    file with one issue number per line (scout-candidate list).
# $GH_FAIL       1 = all gh calls fail.
gh_fake="$scratch/gh"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_CALLS:-/dev/null}"
if [[ "${GH_FAIL:-0}" == "1" ]]; then
    echo "gh: simulated failure" >&2
    exit 1
fi
case "$*" in
  *"issue list"*"-l scout-candidate"*)
    if [[ -f "${CANDIDATES:-/dev/nonexistent}" ]]; then
      jq -R -s -c 'split("\n") | map(select(length>0)) | map({number: tonumber})' "${CANDIDATES:-/dev/null}"
    else
      printf '[]\n'
    fi
    exit 0
    ;;
  *"issue list"*"-l agent-ready"*)
    printf '[]\n'
    exit 0
    ;;
  *"pr list"*)
    printf '[]\n'
    exit 0
    ;;
  *"issue view"*)
    printf '{"title":"test","body":"body","labels":[]}\n'
    exit 0
    ;;
  *"issue edit"*)
    exit 0
    ;;
  *"issue comment"*)
    exit 0
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$gh_fake"

# --- fake systemctl ---------------------------------------------------------
# $ACTIVE_UNITS  list of units reported active/activating.
# $FAILED_UNITS  list of units reported failed (StartLimitBurst exhausted).
systemctl_fake="$scratch/systemctl"
cat >"$systemctl_fake" <<'FAKE'
#!/usr/bin/env bash
shift  # --user
cmd="$1"; shift
case "$cmd" in
  is-active)
    unit="$1"
    if [[ -f "${ACTIVE_UNITS:-/dev/nonexistent}" ]] \
       && grep -qxF "$unit" "${ACTIVE_UNITS:-/dev/nonexistent}" 2>/dev/null; then
      echo active
    elif [[ -f "${FAILED_UNITS:-/dev/nonexistent}" ]] \
       && grep -qxF "$unit" "${FAILED_UNITS:-/dev/nonexistent}" 2>/dev/null; then
      echo failed
    else
      echo inactive
    fi
    exit 0
    ;;
  reset-failed)
    printf 'reset-failed %s\n' "$1" >>"${CALLS:-/dev/null}"
    exit 0
    ;;
  start)
    unit=""
    for a in "$@"; do
      case "$a" in
        --*) ;;
        *) unit="$a"; break ;;
      esac
    done
    printf 'start %s\n' "$unit" >>"${CALLS:-/dev/null}"
    exit 0
    ;;
  *)
    printf 'unexpected systemctl call: %s %s\n' "$cmd" "$*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$systemctl_fake"

export FLEET_INTAKE_REPOS_JSON="$intake_json"
export FLEET_HEARTBEAT_LOG_DIR="$log_dir"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export AUDIT_STATE_DIR="$state_dir"
export AUDIT_PENDING_AGE_S=1
export AUDIT_TALLY_BIN="$tally_bin"
export CANDIDATES="$scratch/candidates"
export ACTIVE_UNITS="$scratch/active_units"
export FAILED_UNITS="$scratch/failed_units"
export CALLS="$calls"
export GH_CALLS="$gh_calls"

write_vote() {
    local repo="$1" candidate="$2" role="$3" verdict="$4" reason="$5"
    local dir="$state_dir/$repo/$candidate"
    mkdir -p "$dir"
    jq -n \
        --arg repo "$repo" \
        --arg candidate "$candidate" \
        --arg role "$role" \
        --arg verdict "$verdict" \
        --arg reason "$reason" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{repo:$repo,candidate:$candidate,role:$role,verdict:$verdict,reason:$reason,at:$at}' \
        > "$dir/$role.vote"
}

run_auditor() {
  set +e
  env_out=$(env GH="$gh_fake" SYSTEMCTL="$systemctl_fake" "$auditor_bin" 2>&1)
  env_rc=$?
  set -e
}

reset_state() {
  # shellcheck disable=SC2115
  rm -rf "$state_dir"/*
  # shellcheck disable=SC2115
  rm -rf "$log_dir"/*
  rm -f "$triage" "$calls" "$gh_calls" "$scratch"/active_units "$scratch"/failed_units "$scratch"/candidates 2>/dev/null || true
  : >"$calls"; : >"$gh_calls"; : >"$ACTIVE_UNITS"; : >"$FAILED_UNITS"
}

# ============================================================================
# Scenario 1: no votes, no active audit units -> start all three
# ============================================================================
reset_state
printf '42\n' >"$CANDIDATES"
: >"$ACTIVE_UNITS"

run_auditor

[[ "$env_rc" == 0 ]] || fail "scenario1: must exit 0, got $env_rc ($env_out)"
for role in devin free-glm-5-3 straitly; do
  grep -qx "start pi-audit@demo--42--$role.service" "$calls" \
      || fail "scenario1: missing start for $role ($(cat "$calls"))"
done
ok "scenario1: auditor starts all three audit units for a scout-candidate"

# ============================================================================
# Scenario 2: active audit unit -> not re-started
# ============================================================================
reset_state
printf '42\n' >"$CANDIDATES"
printf 'pi-audit@demo--42--devin.service\n' >"$ACTIVE_UNITS"

run_auditor

grep -qx 'start pi-audit@demo--42--devin.service' "$calls" \
    && fail "scenario2: devin unit should not be restarted"
grep -qx 'start pi-audit@demo--42--free-glm-5-3.service' "$calls" \
    || fail "scenario2: free-glm-5-3 should be started"
grep -qx 'start pi-audit@demo--42--straitly.service' "$calls" \
    || fail "scenario2: straitly should be started"
ok "scenario2: active audit unit is not re-started; missing ones are"

# ============================================================================
# Scenario 3: all PASS -> tally calls agent-ready
# ============================================================================
reset_state
printf '42\n' >"$CANDIDATES"
: >"$ACTIVE_UNITS"
write_vote demo 42 devin PASS "clear user impact; no duplicate; aligns with north star"
write_vote demo 42 free-glm-5-3 PASS "unique; beats customer edge AI; no duplicate"
write_vote demo 42 straitly PASS "north star fit; no duplication"

run_auditor

[[ "$env_rc" == 0 ]] || fail "scenario3: must exit 0, got $env_rc ($env_out)"
# The tally should have edited the issue.
grep -q 'issue edit' "$GH_CALLS" || fail "scenario3: tally did not call gh issue edit"
# Should be 2 start calls? No, all votes present, no units started; tally only.
if grep -qE '^start ' "$calls"; then
    fail "scenario3: should not start units when votes present"
fi
ok "scenario3: 3 PASS -> tally runs, no new unit starts"

# ============================================================================
# Scenario 4: 2 PASS 1 FAIL -> admit (2-of-3)
# ============================================================================
reset_state
write_vote demo 43 devin PASS "north star; no duplicates"
write_vote demo 43 free-glm-5-3 PASS "customer edge; unique"
write_vote demo 43 straitly FAIL "vague termination command"

# Run the real tally with a fake gh that captures add/remove labels.

# Reset and run directly with tally fake to assert the edit command.
rm -rf "$state_dir"/demo/43
write_vote demo 43 devin PASS "north star; no duplicates"
write_vote demo 43 free-glm-5-3 PASS "customer edge; unique"
write_vote demo 43 straitly FAIL "vague termination command"

set +e
AUDIT_DRY_RUN=0 AUDIT_GH="$gh_fake" "$tally_bin" demo 43 >"$scratch/tally_out" 2>&1
tally_rc=$?
set -e
[[ "$tally_rc" == 0 ]] || fail "scenario4: tally exit $tally_rc"
grep -q 'issue edit' "$GH_CALLS" || fail "scenario4: tally did not call gh issue edit"
ok "scenario4: 2 PASS 1 FAIL -> tally edits labels (admit)"

# ============================================================================
# Scenario 5: 2 FAIL 1 PASS -> discard
# ============================================================================
reset_state
: >"$GH_CALLS"
write_vote demo 44 devin FAIL "duplicate of #1; no north star"
write_vote demo 44 free-glm-5-3 FAIL "parity work only"
write_vote demo 44 straitly PASS "ok"

set +e
AUDIT_DRY_RUN=0 AUDIT_GH="$gh_fake" "$tally_bin" demo 44 >"$scratch/tally_out2" 2>&1
tally_rc=$?
set -e
[[ "$tally_rc" == 0 ]] || fail "scenario5: tally exit $tally_rc"
[[ $(grep -c 'issue edit' "$GH_CALLS") -ge 1 ]] || fail "scenario5: tally did not call gh issue edit"
[[ $(grep -c 'issue comment' "$GH_CALLS") -ge 1 ]] || fail "scenario5: tally did not call gh issue comment"
ok "scenario5: 2 FAIL 1 PASS -> tally edits labels and comments (discard)"

# ============================================================================
# Scenario 6: 1 PASS 1 FAIL -> pending, no label change
# ============================================================================
reset_state
: >"$GH_CALLS"
write_vote demo 45 devin PASS "ok"
write_vote demo 45 free-glm-5-3 FAIL "no duplicates mention"

set +e
AUDIT_DRY_RUN=0 AUDIT_GH="$gh_fake" "$tally_bin" demo 45 >"$scratch/tally_out3" 2>&1
tally_rc=$?
set -e
[[ "$tally_rc" == 0 ]] || fail "scenario6: tally exit $tally_rc"
! grep -q 'issue edit' "$GH_CALLS" || fail "scenario6: must not edit issue on 1-1 split"
ok "scenario6: 1 PASS 1 FAIL -> no label change (pending)"

# ============================================================================
# Scenario 7: long-pending candidate with no active unit -> LOUD finding
# ============================================================================
reset_state
printf '46\n' >"$CANDIDATES"
: >"$ACTIVE_UNITS"
# Mark the candidate as first seen 60 seconds ago.
mkdir -p "$state_dir/demo/46"
date -u -d '60 seconds ago' +%Y-%m-%dT%H:%M:%SZ >"$state_dir/demo/46/.pending"

run_auditor

grep -q 'AUDITOR-PANEL-PENDING' "$triage" || fail "scenario7: triage missing AUDITOR-PANEL-PENDING"
ok "scenario7: stale pending candidate -> AUDITOR-PANEL-PENDING loud finding"

# ============================================================================
# Scenario 8: failed unit (StartLimitBurst exhausted) -> reset-failed + start
# ============================================================================
# The 2026-08-26 incident: pi-audit@...--free-glm-5-3 and --devin sat
# failed after two seat faults. systemd would not start them again for
# an hour. The next tick must clear the burst and start, so a recovered
# seat is used instead of waiting out StartLimitIntervalSec.
reset_state
printf '47\n' >"$CANDIDATES"
: >"$ACTIVE_UNITS"
printf 'pi-audit@demo--47--devin.service\n' >"$FAILED_UNITS"
printf 'pi-audit@demo--47--free-glm-5-3.service\n' >>"$FAILED_UNITS"

run_auditor

[[ "$env_rc" == 0 ]] || fail "scenario8: must exit 0, got $env_rc ($env_out)"
for role in devin free-glm-5-3; do
  unit="pi-audit@demo--47--$role.service"
  grep -qx "reset-failed $unit" "$calls" \
      || fail "scenario8: missing reset-failed for $role ($(cat "$calls"))"
  grep -qx "start $unit" "$calls" \
      || fail "scenario8: missing start for $role ($(cat "$calls"))"
  reset_line=$(grep -n "^reset-failed $unit$" "$calls" | head -1 | cut -d: -f1)
  start_line=$(grep -n "^start $unit$" "$calls" | head -1 | cut -d: -f1)
  [[ -n "$reset_line" && -n "$start_line" && "$reset_line" -lt "$start_line" ]] \
      || fail "scenario8: reset-failed must precede start for $role (calls=$(cat "$calls"))"
done
grep -qx 'start pi-audit@demo--47--straitly.service' "$calls" \
    || fail "scenario8: inactive straitly must still be started"
grep -q 'reset-failed pi-audit@demo--47--straitly.service' "$calls" \
    && fail "scenario8: inactive straitly must not be reset-failed"
ok "scenario8: failed pi-audit units get reset-failed then start; inactive ones only start"

# ============================================================================
# Scenario 9: failed unit whose vote is already on disk is not restarted
# ============================================================================
reset_state
printf '48\n' >"$CANDIDATES"
: >"$ACTIVE_UNITS"
printf 'pi-audit@demo--48--devin.service\n' >"$FAILED_UNITS"
write_vote demo 48 devin PASS "already voted; unit leftover failed"

run_auditor

[[ "$env_rc" == 0 ]] || fail "scenario9: must exit 0, got $env_rc ($env_out)"
grep -q 'reset-failed pi-audit@demo--48--devin.service' "$calls" \
    && fail "scenario9: voted failed unit must not be reset-failed ($(cat "$calls"))"
grep -q 'start pi-audit@demo--48--devin.service' "$calls" \
    && fail "scenario9: voted failed unit must not be started"
grep -qx 'start pi-audit@demo--48--free-glm-5-3.service' "$calls" \
    || fail "scenario9: missing vote still starts free-glm-5-3"
grep -qx 'start pi-audit@demo--48--straitly.service' "$calls" \
    || fail "scenario9: missing vote still starts straitly"
ok "scenario9: failed unit with a vote on disk is left alone"

# ============================================================================
# Scenario 10: class lock — tier1 must invoke the auditor (fleet-ops#366)
# ============================================================================
# The incident class is "helper exists but is never called". A future edit
# that drops block 4b fails this test instead of wedging pi-audit units
# for an hour again.
# fleet-ops#615: a FATAL auditor exit must land in auditor_rc. Swallowing
# it as _aud_rc + "next tick retries" leaves the admission gate dead
# while the heartbeat stays green.
tier1="$repo_root/bin/fleet-heartbeat-tier1"
[[ -f "$tier1" ]] || fail "missing $tier1"
grep -q 'FLEET_HEARTBEAT_AUDITOR' "$tier1" \
    || fail "tier1 must honour FLEET_HEARTBEAT_AUDITOR (block 4b)"
grep -q 'AUDITOR_BIN=' "$tier1" \
    || fail "tier1 must set AUDITOR_BIN"
grep -F -- 'require_manifest_helper "$AUDITOR_BIN"' "$tier1" >/dev/null \
    || fail "tier1 must call require_manifest_helper on AUDITOR_BIN"
grep -F -- 'senior-auditor helper missing at $AUDITOR_BIN' "$tier1" >/dev/null \
    || fail "tier1 must loud HELPER-MISSING when the auditor dest is absent"
grep -F -- 'auditor_rc=$?' "$tier1" >/dev/null \
    || fail "tier1 must assign auditor_rc from the auditor helper exit (fleet-ops#615); swallowed _aud_rc leaves a broken panel green"
grep -F -- 'if [ "${auditor_rc:-0}" -ne 0 ]; then' "$tier1" >/dev/null \
    || fail "tier1 exit-code list must propagate auditor_rc"
if awk '
    /# 4b\. SENIOR AUDITOR PANEL/ { in_block=1 }
    in_block && /^# 5\./ { in_block=0 }
    in_block && /next tick retries/ { found=1 }
    END { exit found ? 0 : 1 }
' "$tier1"; then
    fail "tier1 4b must not swallow a failed auditor as 'next tick retries' (fleet-ops#615)"
fi
ok "scenario10: tier1 block 4b invokes fleet-heartbeat-auditor and fails the tick on helper FATAL (not-called + swallowed-rc class locked)"

# Nested CI host (workers cannot add a ci.yml line).
grep -Fq 'bash "$here/fleet-heartbeat-auditor.test.sh"' "$here/fleet-heartbeat-low-water-mark.test.sh" \
    || fail "fleet-heartbeat-low-water-mark.test.sh must host this file (CI cannot gain a new workflow line)"
ok "hosted by fleet-heartbeat-low-water-mark.test.sh"

ok "fleet-heartbeat-auditor: starts missing pi-audit units, recovers failed ones, tallies 2-of-3, fails closed, raises stale-pending alarm"
