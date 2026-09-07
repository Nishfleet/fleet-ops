#!/usr/bin/env bash
# tests/claim-reconcile.test.sh
#
# Proves the claim reconciler (fleet-ops#39) self-heals the split-brain and
# garbage claim states that tier 1 §3 cannot see (§3 iterates
# agent-in-progress issues; B/C/orphan are branch-side):
#   B. claim/issue-<N> branch + issue open + label NOT agent-in-progress
#      (intake's ls-remote sees the branch and skips the issue forever)
#      -> branch released, label left alone, comment posted
#   C. claim/issue- (empty N) or non-numeric N -> deleted, no comment
#   Orphaned: branch for a missing/closed issue, no open PR -> deleted
#   - live worker (active/activating) holds the lane -> NOT released
#   - open claim PR = work in flight -> NOT released
#   - agent-in-progress issue is DEFERRED to tier 1 §3 -> NOT touched here
#   - overlapping sweeps no-op
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/claim-reconcile"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/live"

# --- fake gh: file-backed, mirrors blocked-reconcile.test.sh style --------
cat >"$scratch/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  api)
    path="$2"
    # Strip any query string for filesystem lookup.
    base="${path%%\?*}"
    if [[ "${3:-}" == "-X" && "${4:-}" == "DELETE" ]]; then
      printf '%s\n' "$base" >>"$FAKE_DIR/deletes.log"
      # Mark the ref gone so a follow-up GET 404s.
      rm -f "$FAKE_DIR/api/${base#repos/}.json"
      exit 0
    fi
    rel="${base#repos/}"
    f="$FAKE_DIR/api/${rel}.json"
    if [[ -f "$f" ]]; then
      cat "$f"
      exit 0
    fi
    echo '{"message":"Not Found"}' >&2
    exit 1
    ;;
  issue)
    case "$2" in
      view)
        num="$3"
        # -R <repo> --json ...
        repo=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            -R) repo="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        f="$FAKE_DIR/issues/${repo}/${num}.json"
        if [[ -f "$f" ]]; then
          cat "$f"
          exit 0
        fi
        echo '{"message":"Not Found"}' >&2
        exit 1
        ;;
      comment)
        num="$3"; body=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --body) body="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        printf '%s\n' "$body" >>"$FAKE_DIR/comments-${num}.log"
        exit 0
        ;;
      edit)
        printf '%s\n' "$*" >>"$FAKE_DIR/edits.log"
        exit 0
        ;;
      *) echo "unexpected gh issue $*" >&2; exit 1 ;;
    esac
    ;;
  pr)
    # pr list -R <repo> --head <branch> --state open --json number
    repo=""; head=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -R) repo="$2"; shift 2 ;;
        --head) head="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    n="${head#claim/issue-}"
    f="$FAKE_DIR/prs/${repo}/${n}.json"
    if [[ -f "$f" ]]; then
      cat "$f"
    else
      echo '[]'
    fi
    exit 0
    ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$scratch/bin/gh"

# --- fake systemctl: live-unit marker files -------------------------------
cat >"$scratch/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
# Minimal fake: honors --user list-units <pattern> --state=<list> and
# --user show <unit> --property=SubState --value. A unit is "live" iff a
# marker file $FAKE_DIR/live/<unit> exists.
shift  # --user
case "$1" in
  list-units)
    shift
    declare -a want=()
    pattern=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --state=*) IFS=',' read -ra want <<<"${1#--state=}"; shift ;;
        --state)   IFS=',' read -ra want <<<"$2"; shift 2 ;;
        --no-legend|--type=service) shift ;;
        --*) shift ;;
        *) pattern="$1"; shift ;;
      esac
    done
    [[ -z "$pattern" ]] && exit 0
    if [[ -f "$FAKE_DIR/live/$pattern" ]]; then
      cur="active"
      for s in "${want[@]}"; do
        [[ "$s" == "$cur" || "$s" == "activating" ]] && { printf '%s loaded active running\tfake\n' "$pattern"; exit 0; }
        [[ "$s" == "running" ]] && { printf '%s loaded active running\tfake\n' "$pattern"; exit 0; }
      done
    fi
    exit 0
    ;;
  show)
    unit=""; prop=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -p) prop="$2"; shift 2 ;;
        --value) shift ;;
        *) unit="$1"; shift ;;
      esac
    done
    case "$prop" in
      SubState) cat "$FAKE_DIR/live/$unit" 2>/dev/null || echo running ;;
      *) echo "" ;;
    esac
    exit 0
    ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$scratch/bin/systemctl"

export PATH="$scratch/bin:$PATH"
export SYSTEMCTL="$scratch/bin/systemctl"
export FAKE_DIR="$scratch"
export CLAIM_RECONCILE_REPOS="Nishfleet/fleet-ops"
export CLAIM_RECONCILE_LOCKDIR="$scratch/lock"
export CLAIM_RECONCILE_NOW="2026-08-26T00:00:00Z"

REPO="Nishfleet/fleet-ops"
mkdir -p "$scratch/api/$REPO/git/refs/heads/claim" "$scratch/issues/$REPO" "$scratch/prs/$REPO"

# Helper: write a branches list JSON for the repo.
write_branches() {
    local arr="$1"
    printf '%s' "$arr" >"$scratch/api/$REPO/branches.json"
}
# Helper: mark a claim/issue-N branch as existing (so GET succeeds).
mark_branch() {
    local n="$1"
    : >"$scratch/api/$REPO/git/refs/heads/claim/issue-${n}.json"
    printf '{"ref":"refs/heads/claim/issue-%s","object":{"sha":"deadbeef"}}\n' "$n" >"$scratch/api/$REPO/git/refs/heads/claim/issue-${n}.json"
}
# Helper: write an issue's view JSON.
write_issue() {
    local n="$1" state="$2"; shift 2
    local labels="$*"
    local lbl="["
    local first=1
    for l in $labels; do
        (( first )) || lbl+=","
        lbl+="{\"name\":\"$l\"}"
        first=0
    done
    lbl+="]"
    printf '{"number":%s,"state":"%s","labels":%s}\n' "$n" "$state" "$lbl" \
        >"$scratch/issues/$REPO/${n}.json"
}
# Helper: mark a unit live.
mark_live() {
    printf 'running\n' >"$scratch/live/pi-issue@fleet-ops-${1}.service"
}
# Helper: mark an open PR for claim/issue-N.
mark_pr() {
    printf '[{"number":1}]\n' >"$scratch/prs/$REPO/${1}.json"
}
# Helper: mark an alert-repair claim branch as existing on origin.
# The fake gh maps repos/<owner>/<repo>/git/refs/heads/<branch> to
# $FAKE_DIR/api/<owner>/<repo>/git/refs/heads/<branch>.json.
mark_alert_branch() {
    local branch="$1"
    mkdir -p "$scratch/api/$REPO/git/refs/heads/claim"
    printf '{"ref":"refs/heads/%s","object":{"sha":"deadbeef"}}\n' "$branch" \
        >"$scratch/api/$REPO/git/refs/heads/${branch}.json"
}
# Helper: write an alert-repair claim state file (what alert-repair-claim
# writes under ALERT_STATE_DIR on acquisition, fleet-ops#1199).
write_alert_state() {
    local name="$1" branch="$2" acquired="$3"
    printf '{"repo":"fleet-ops","alert":"FleetMainRed","scope":"fleet-main-red","branch":"%s","acquired_at":"%s"}\n' "$branch" "$acquired" \
        >"$ALERT_STATE_DIR/${name}.json"
}
# Helper: mark a live alert-repair worker unit (any active alert-repair-*).
mark_live_alert() {
    printf 'running\n' >"$scratch/live/alert-repair-*"
}
# Helper: mark an open PR whose head is an alert-repair claim branch.
mark_pr_head() {
    local branch="$1"
    mkdir -p "$scratch/prs/$REPO/claim"
    printf '[{"number":1}]\n' >"$scratch/prs/$REPO/${branch}.json"
}

reset_logs() {
    rm -f "$scratch"/deletes.log "$scratch"/comments-*.log "$scratch"/edits.log
    : >"$scratch/deletes.log"
    : >"$scratch/edits.log"
}

deleted_branch() {
    grep -qx "repos/$REPO/git/refs/heads/$1" "$scratch/deletes.log"
}
commented_on() {
    [[ -s "$scratch/comments-${1}.log" ]]
}
edited_any() {
    [[ -s "$scratch/edits.log" ]]
}

# --- Case 1: direction C, unnumbered claim/issue- -----------------------
reset_logs
mark_branch ""   # claim/issue- (empty N)
write_branches '[{"name":"claim/issue-"},{"name":"claim/issue-22"}]'
# (issue 22 not set up yet; only the empty branch matters for this case)
out=$("$bin" 2>"$scratch/err.log")
deleted_branch "claim/issue-" || fail "C: unnumbered branch not deleted: $(cat "$scratch/deletes.log")"
ok "C: unnumbered claim/issue- branch deleted"

# --- Case 2: direction C, non-numeric N ----------------------------------
reset_logs
write_branches '[{"name":"claim/issue-abc"}]'
: >"$scratch/api/$REPO/git/refs/heads/claim/issue-abc.json"
out=$("$bin" 2>"$scratch/err.log")
deleted_branch "claim/issue-abc" || fail "C: non-numeric branch not deleted"
ok "C: non-numeric claim/issue-abc branch deleted"

# --- Case 3: direction B, branch + agent-ready label --------------------
reset_logs
mark_branch "22"
write_branches '[{"name":"claim/issue-22"}]'
write_issue 22 open agent-ready
out=$("$bin" 2>"$scratch/err.log")
deleted_branch "claim/issue-22" || fail "B: branch not deleted: $(cat "$scratch/deletes.log")"
commented_on 22 || fail "B: no comment posted"
! edited_any || fail "B: must NOT touch labels (label left alone): $(cat "$scratch/edits.log")"
grep -q 'direction B' "$scratch/comments-22.log" || fail "B: comment must name direction B"
ok "B: branch without agent-in-progress released; label left alone; comment posted"

# --- Case 4: direction B, branch + agent-blocked label (label kept) -----
reset_logs
mark_branch "30"
write_branches '[{"name":"claim/issue-30"}]'
write_issue 30 open agent-blocked
out=$("$bin" 2>"$scratch/err.log")
deleted_branch "claim/issue-30" || fail "B-blocked: branch not deleted"
commented_on 30 || fail "B-blocked: no comment"
! edited_any || fail "B-blocked: must NOT flip agent-blocked label: $(cat "$scratch/edits.log")"
grep -q 'agent-blocked' "$scratch/comments-30.log" || fail "B-blocked: comment should note agent-blocked kept"
ok "B: branch with agent-blocked issue released; agent-blocked label kept"

# --- Case 5: orphaned, issue missing ------------------------------------
reset_logs
mark_branch "99"
write_branches '[{"name":"claim/issue-99"}]'
rm -f "$scratch/issues/$REPO/99.json"
out=$("$bin" 2>"$scratch/err.log")
deleted_branch "claim/issue-99" || fail "orphan-missing: branch not deleted"
ok "orphaned: branch for missing issue deleted"

# --- Case 6: orphaned, issue closed -------------------------------------
reset_logs
mark_branch "88"
write_branches '[{"name":"claim/issue-88"}]'
write_issue 88 closed agent-in-progress
out=$("$bin" 2>"$scratch/err.log")
deleted_branch "claim/issue-88" || fail "orphan-closed: branch not deleted"
commented_on 88 || fail "orphan-closed: no comment"
ok "orphaned: branch for closed issue deleted + commented"

# --- Case 7: live worker holds the lane (NOT released) ------------------
reset_logs
mark_branch "7"
write_branches '[{"name":"claim/issue-7"}]'
write_issue 7 open agent-ready
mark_live 7
out=$("$bin" 2>"$scratch/err.log")
! deleted_branch "claim/issue-7" || fail "live-worker: must NOT delete branch"
ok "live worker: branch held (not released)"

# --- Case 8: open PR = work in flight (NOT released) --------------------
reset_logs
mark_branch "5"
write_branches '[{"name":"claim/issue-5"}]'
write_issue 5 open agent-ready
mark_pr 5
out=$("$bin" 2>"$scratch/err.log")
! deleted_branch "claim/issue-5" || fail "open-pr: must NOT delete branch"
ok "open PR: branch held (work in flight)"

# --- Case 9: agent-in-progress DEFERRED to tier1 §3 (NOT touched) -------
reset_logs
mark_branch "10"
write_branches '[{"name":"claim/issue-10"}]'
write_issue 10 open agent-in-progress
out=$("$bin" 2>"$scratch/err.log")
! deleted_branch "claim/issue-10" || fail "defer: must NOT delete agent-in-progress branch (§3 owns it)"
! commented_on 10 || fail "defer: must NOT comment on agent-in-progress issue"
! edited_any || fail "defer: must NOT edit agent-in-progress issue: $(cat "$scratch/edits.log")"
ok "agent-in-progress deferred to tier1 §3 (not touched)"

# --- Case A1: stale alert-repair claim (no worker, no PR) deleted -------
reset_logs
export CLAIM_RECONCILE_ALERT_STATE_DIR="$scratch/alert-state"
export ALERT_STATE_DIR="$scratch/alert-state"
mkdir -p "$ALERT_STATE_DIR"
mark_alert_branch "claim/fleet-main-red-fleet-ops"
# 3h before CLAIM_RECONCILE_NOW (2026-08-26T00:00:00Z) -> stale (>2h).
write_alert_state "fleet-ops-fleet-main-red" "claim/fleet-main-red-fleet-ops" "2026-08-25T21:00:00Z"
out=$("$bin" 2>"$scratch/err.log")
deleted_branch "claim/fleet-main-red-fleet-ops" \
    || fail "A1: stale alert claim not deleted: $(cat "$scratch/deletes.log")"
[ ! -f "$ALERT_STATE_DIR/fleet-ops-fleet-main-red.json" ] \
    || fail "A1: stale state file not removed"
ok "A1: stale alert-repair claim deleted; state file removed"

# --- Case A2: fresh alert-repair claim held ---------------------------------
reset_logs
mark_alert_branch "claim/fleet-main-red-fleet-ops"
# 10 min before NOW -> fresh (<2h).
write_alert_state "fleet-ops-fleet-main-red" "claim/fleet-main-red-fleet-ops" "2026-08-25T23:50:00Z"
out=$("$bin" 2>"$scratch/err.log")
! deleted_branch "claim/fleet-main-red-fleet-ops" || fail "A2: fresh alert claim must NOT be deleted"
ok "A2: fresh alert-repair claim held"

# --- Case A3: live alert-repair worker holds even a stale claim -------------
reset_logs
mark_alert_branch "claim/fleet-main-red-fleet-ops"
write_alert_state "fleet-ops-fleet-main-red" "claim/fleet-main-red-fleet-ops" "2026-08-25T21:00:00Z"
mark_live_alert
out=$("$bin" 2>"$scratch/err.log")
! deleted_branch "claim/fleet-main-red-fleet-ops" || fail "A3: live worker must hold the claim"
ok "A3: live alert-repair worker holds the claim"

# --- Case A4: open PR with the claim as head holds ---------------------------
reset_logs
rm -f "$scratch/live/alert-repair-*"  # A3's live marker must not leak here
mark_alert_branch "claim/fleet-main-red-fleet-ops"
write_alert_state "fleet-ops-fleet-main-red" "claim/fleet-main-red-fleet-ops" "2026-08-25T21:00:00Z"
mark_pr_head "claim/fleet-main-red-fleet-ops"
out=$("$bin" 2>"$scratch/err.log")
! deleted_branch "claim/fleet-main-red-fleet-ops" || fail "A4: open PR must hold the claim"
ok "A4: open PR with claim head holds it"

# --- Case A5: stray state file (branch already gone) cleaned up --------------
reset_logs
rm -f "$scratch/live/alert-repair-*"
rm -f "$scratch/api/$REPO/git/refs/heads/claim/fleet-main-red-fleet-ops.json"
rm -f "$scratch/prs/$REPO/claim/fleet-main-red-fleet-ops.json"
# No mark_alert_branch: the branch does not exist on origin.
write_alert_state "fleet-ops-fleet-main-red" "claim/fleet-main-red-fleet-ops" "2026-08-25T21:00:00Z"
out=$("$bin" 2>"$scratch/err.log")
[ ! -f "$ALERT_STATE_DIR/fleet-ops-fleet-main-red.json" ] \
    || fail "A5: orphaned state file not cleaned up"
ok "A5: state file for an already-gone claim is cleaned up"

# --- Case 10: overlapping flock no-op -----------------------------------
export CLAIM_RECONCILE_LOCKDIR="$scratch/lock-overlap"
mkdir -p "$CLAIM_RECONCILE_LOCKDIR"
exec 9>"$CLAIM_RECONCILE_LOCKDIR/sweep.lock"
flock -n 9 || fail "could not hold overlap lock"
out=$("$bin" 2>"$scratch/err.log")
exec 9>&-
printf '%s\n' "$out" | grep -q 'no-op' || fail "overlap must print no-op, got: $out"
ok "overlapping sweep is a no-op"

# --- Case 11: contracts wired -------------------------------------------
grep -q 'claim-reconcile' "$repo_root/bin/fleet-heartbeat-tier1" \
    || fail "tier1 must call claim-reconcile"
grep -q 'claim/issue-' "$repo_root/prompts/intake.md" \
    || fail "intake prompt must reference the claim branch"
grep -qi 'empty' "$repo_root/prompts/intake.md" \
    || fail "intake prompt must refuse empty-N claim pushes"
grep -q 'bin/claim-reconcile' "$repo_root/MANIFEST" \
    || fail "MANIFEST must install bin/claim-reconcile"
ok "contracts: tier1 call + intake guard + MANIFEST entry present"

echo "all claim-reconcile cases passed"
