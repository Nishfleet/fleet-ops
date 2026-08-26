# shellcheck shell=bash
# lib/orphan-release.sh — the heartbeat §3 per-issue orphan release, extracted
# so the detector drill (bin/orphan-release-drill, fleet-ops#180) proves the
# EXACT production code path instead of a re-implementation. fleet-ops#222:
# the live-check and the release action each had drifted copies; one function
# each, sourced by tier1 §3 and the drill, pinned by tests.
#
# Preconditions for the caller:
#   - source lib/worker-live.sh FIRST (defines worker_unit_is_live).
#   - define a `log <msg>` function (tier1 and the drill each have their own).
#   - jq on PATH; gh on PATH (or ${GH} injected); systemctl (or ${SYSTEMCTL}).
#
# orphan_release_for_issue <repo> <issue_n> <short>
#   Returns 0 if the claim was released (label flipped agent-in-progress ->
#   agent-ready). Returns 1 if skipped: live worker, transient worker, open
#   claim PR, branch-delete failed, or label-flip failed. The caller counts
#   releases by the return code (tier1: released=$((released+1))).
#
# Injectable seams (so the drill can run without real systemd/gh):
#   ${SYSTEMCTL:-systemctl}  — fake systemctl modelling unit state.
#   ${GH:-gh}                — fake gh recording branch deletes + label flips.
#   ${JQ:-jq}                — fake jq for the open-PR check.

orphan_release_for_issue() {
    [ $# -ge 3 ] || return 1
    local repo="$1" issue_n="$2" short="$3"
    local unit="pi-issue@${short}-${issue_n}.service"
    local systemctl_cmd="${SYSTEMCTL:-systemctl}"
    local gh_cmd="${GH:-gh}"
    local jq_cmd="${JQ:-jq}"

    # Live worker (MainPID-aware): active, or activating with a real process.
    # auto-restart with MainPID=0 (process exited, restart timer pending) is
    # NOT live — orphan shape (c) (fleet-ops#222).
    if worker_unit_is_live "$unit"; then
        local sub
        sub="$("$systemctl_cmd" --user show "$unit" --property=SubState --value 2>/dev/null || echo unknown)"
        log "3.  - $repo#$issue_n: worker $unit LIVE (sub=$sub) — not orphan"
        return 1
    fi
    # Transient fable-p* / pi-issue worker that may be working on it.
    if "$systemctl_cmd" --user list-units --no-legend --type=service --state=running 2>/dev/null \
        | awk '{print $1}' | grep -E "(fable-p|pi-issue)" | grep -q "${short}-${issue_n}"; then
        log "3.  - $repo#$issue_n: transient worker active — not orphan"
        return 1
    fi

    # Open PR from claim/issue-<N>? Leave it to the queue pass.
    if "$gh_cmd" pr list -R "$repo" --head "claim/issue-${issue_n}" --state open --json number 2>/dev/null \
        | "$jq_cmd" -e 'length > 0' >/dev/null 2>&1; then
        log "3.  - $repo#$issue_n: open claim PR exists — not orphan (leave to queue pass)"
        return 1
    fi

    # Orphan. If the unit is still activating (auto-restart, MainPID=0), STOP
    # it so the pending restart is cancelled and intake's pi-issue-start can
    # re-dispatch a fresh worker. Without this stop, pi-issue-start no-ops on
    # the activating unit and the issue stays un-dispatchable after the label
    # flip — a worse strand than the one we are fixing (fleet-ops#222).
    local active_state
    active_state="$("$systemctl_cmd" --user show -p ActiveState --value "$unit" 2>/dev/null || echo "")"
    if [ "$active_state" = "activating" ]; then
        if "$systemctl_cmd" --user stop "$unit" 2>/dev/null; then
            log "3.  - $repo#$issue_n: stopped auto-restarting unit $unit (MainPID=0) so intake can re-dispatch"
        else
            log "3.  - $repo#$issue_n: WARN stop of auto-restarting $unit failed — release continues, may retry next tick"
        fi
    fi

    # Release. The branch may already be gone (shape (b): the reaper deleted
    # it but partial-failed the label flip) — skip the delete then.
    local branch="claim/issue-${issue_n}"
    if "$gh_cmd" api "repos/${repo}/git/refs/heads/${branch}" >/dev/null 2>&1; then
        if "$gh_cmd" api "repos/${repo}/git/refs/heads/${branch}" -X DELETE >/dev/null 2>&1; then
            log "3.  - $repo#$issue_n: deleted branch $branch"
        else
            log "3.  - $repo#$issue_n: branch delete FAILED ($branch) — will retry next tick"
            return 1
        fi
    fi

    if "$gh_cmd" issue edit "$issue_n" -R "$repo" \
        --remove-label agent-in-progress --add-label agent-ready 2>/dev/null; then
        "$gh_cmd" issue comment "$issue_n" -R "$repo" \
            --body "claim branch released by fleet-heartbeat at $(date -u +%FT%TZ) (no live worker, no open PR)" \
            >/dev/null 2>&1 || true
        log "3.  - $repo#$issue_n: RELEASED -> agent-ready"
        return 0
    fi
    log "3.  - $repo#$issue_n: label flip FAILED — will retry next tick"
    return 1
}
