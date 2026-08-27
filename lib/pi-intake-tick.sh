#!/usr/bin/env bash
# pi-intake-tick.sh — deterministic fleet issue intake tick for ONE repo.
#
# Replaces the model-based intake (pi-packet-run + intake.md prompt) for the
# fleet-ops instance via a systemd drop-in. The intake is deterministic work:
# list agent-ready issues, check fleet capacity, atomically claim, spawn one
# worker unit per claim, print a summary, exit. Routing it through a model
# session was the bug: the model often ended on a tool call with empty final
# text, so `pi --print` wrote 0 bytes to stdout and pi-packet-run's no-op
# detector (stdout < 256B) misclassified a SUCCESSFUL intake as a no-op
# failure. systemd restarted, the tried-seats file accumulated across failed
# ticks, and the unit eventually hit "no alternate seat" storms. A
# deterministic bash tick has no model, no stdout-size dependency, and no seat
# rotation — that failure class is eliminated.
#
# Complementary to the per-instance RuntimeDirectory fix (fleet-ops#72): that
# stops sibling instances wiping each other's *.run.out; this stops the model
# itself emitting empty text. Both are needed.
#
# Args:
#   $1 = repo name (the %i from pi-intake@<repo>.service), e.g. fleet-ops
#
# Exit codes:
#   0 = tick completed (claimed 0+ issues; summary on stdout)
#   1 = a gh/git command errored (auth/network) — fail loud, systemd retries
#
# Hard rules (mirror the old intake.md prompt):
#   - Never close issues, never merge PRs, never push to main, never edit repo code.
#   - Touch only the TARGET repo.
#   - A REJECTED claim push is NOT an error: another agent won the race; skip.

set -euo pipefail

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export HOME="${HOME:-/home/nish}"
export PATH="/home/nish/.local/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"

[[ $# -ge 1 ]] || { echo "pi-intake-tick: need 1 arg: repo" >&2; exit 1; }
REPO="$1"
FULL="Nishfleet/${REPO}"
REPO_DIR="/home/nish/workspaces/products/${REPO}"

# Non-blocking flock so overlapping timer/manual starts no-op instead of racing.
# Matches the lock used by the old pi-intake-run wrapper.
lockdir="${PI_INTAKE_LOCKDIR:-${XDG_RUNTIME_DIR}/pi-intake}"
mkdir -p "$lockdir"
exec 9>"$lockdir/${REPO}.lock"
if ! flock -n 9; then
    echo "pi-intake-tick: $REPO tick already running (no-op)"
    exit 0
fi
# ISSUE_STATE_DIR is used for the worker packet written for pi-issue-run.
# It must NOT be named STATE_DIR: seat-lib.sh redefines that for its own
# pi-packet state (watch.log, active-seats, attempts) when it is sourced below.
ISSUE_STATE_DIR="/home/nish/.local/state/pi-issues"
WORKER_PROMPT="/home/nish/.pi/agent/prompts/worker.md"
# SEAT_LIB may be overridden by tests via env var (like pi-issue-run).
# Default is the live install path; tests inject a stub via SEAT_LIB.
SEAT_LIB="${SEAT_LIB:-/home/nish/.local/lib/pi-packet/seat-lib.sh}"
# PRECEDENCE_BAND_LIB may be overridden by tests. Checkout fallback so a
# worktree run still loads the sibling lib before install.sh copies it.
PRECEDENCE_BAND_LIB="${PRECEDENCE_BAND_LIB:-/home/nish/.local/lib/pi-packet/precedence-band.sh}"
_tick_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$PRECEDENCE_BAND_LIB" && -f "$_tick_dir/precedence-band.sh" ]]; then
    PRECEDENCE_BAND_LIB="$_tick_dir/precedence-band.sh"
fi
[[ -f "$PRECEDENCE_BAND_LIB" ]] || {
    echo "pi-intake-tick: precedence-band lib missing: $PRECEDENCE_BAND_LIB" >&2
    exit 1
}

# shellcheck source=/home/nish/.local/lib/pi-packet/seat-lib.sh
. "$SEAT_LIB"
# shellcheck source=/home/nish/.local/lib/pi-packet/precedence-band.sh
. "$PRECEDENCE_BAND_LIB"

# Step 1: list ready work
issues_json=$(gh issue list -R "$FULL" -l agent-ready --state open --json number,title --limit 50 2>&1) || {
    echo "gh issue list failed: $issues_json" >&2
    exit 1
}

# Blocker filter (auditor 2026-08-26, summon fleet-ops-87): an agent-ready
# issue can carry a body `blocked-on:` line (machine-checkable dep or
# nish-decision). Claiming such an issue spawns a worker that cannot make
# progress — it posts the blocker and exits, then the next tick re-claims it:
# a spawn churn. blocked-reconcile owns the agent-blocked label; this filter
# is the intake-side guard so the two never fight. Filtering on body text
# (not just label) also covers the stale-label window where an issue is still
# agent-ready but carries a blocker.
blocked_filter() {
    local body="$1"
    if printf '%s' "$body" | grep -qE '^blocked-on:'; then
        return 0
    fi
    return 1
}

if [[ -z "$issues_json" ]] || [[ "$issues_json" == "[]" ]]; then
    echo "no ready issues"
    exit 0
fi

ready_count=$(jq 'length' <<<"$issues_json" 2>/dev/null || echo 0)
if (( ready_count == 0 )); then
    echo "no ready issues"
    exit 0
fi

# Step 2: capacity (P4-A — fleet-ops config/seat-caps.json, not a hardcoded cap)
caps_sum=$(total_seat_cap 2>/dev/null || echo 0)
ram_cap=$(ram_governor_cap 2>/dev/null || echo 9999)
if (( caps_sum > 0 && caps_sum < ram_cap )); then
    total_cap=$caps_sum
else
    total_cap=$ram_cap
fi
active=$(count_active_total 2>/dev/null || echo 0)
issue=$(count_active_issue 2>/dev/null || echo 0)
org=$(count_active_org 2>/dev/null || echo 0)
org_res=$(org_reserve 2>/dev/null || echo 2)
slots=$(( total_cap - active ))

if (( slots <= 0 )); then
    echo "at capacity (total_cap=$total_cap, active=$active, issue=$issue, org=$org, org_reserve=$org_res)"
    exit 0
fi

# Seat gate (auditor 2026-08-26T18:1xZ, summon fleet-ops-378 unit-failure):
# capacity slots are NOT proof a worker can run. With every allowlisted
# heavy-capable seat benched/quota-exhausted, a claimed issue spawns a
# pi-issue@ unit that dies instantly on pick_seat(heavy) -> NO USABLE SEAT
# and auto-restarts until StartLimitBurst, then OnFailure reaps the claim
# back to agent-ready, then the NEXT tick re-claims it — a spawn churn that
# burned 37 units activating and summoned the auditor. The intake must probe
# a usable heavy-capable seat BEFORE claiming; if none exists, hold all
# claims this tick (workers pick their own seat at run time, and the queue
# is heavy product work — a light-only fleet cannot run it). The recheck
# timer re-fires the tick when seats recover.
# shellcheck disable=SC2034
if ! heavy_seat=$(pick_seat "" "" 1 2>/dev/null); then
    echo "no usable heavy-capable seat (slots=$slots); holding claims this tick — gate: pick_seat need_capable=1"
    exit 0
fi

# Pre-fetch origin once before the loop
git -C "$REPO_DIR" fetch origin 2>&1 || {
    echo "git fetch origin failed" >&2
    exit 1
}

mkdir -p "$ISSUE_STATE_DIR"

# Step 3: process issues in ascending number order
mapfile -t numbers < <(jq -r 'sort_by(.number) | .[].number' <<<"$issues_json")
mapfile -t titles  < <(jq -r 'sort_by(.number) | .[].title'  <<<"$issues_json")

for i in "${!numbers[@]}"; do
    N="${numbers[$i]}"
    title="${titles[$i]}"

    if (( slots <= 0 )); then
        echo "issue $N ($title): skipped-capacity"
        continue
    fi

    # Per-issue fetch (keeps origin/main fresh)
    git -C "$REPO_DIR" fetch origin 2>&1 || {
        echo "git fetch origin failed for issue $N" >&2
        exit 1
    }

    # Check if another agent already holds the claim branch
    remote=$(git -C "$REPO_DIR" ls-remote origin "refs/heads/claim/issue-$N" 2>&1) || {
        echo "git ls-remote failed for issue $N: $remote" >&2
        exit 1
    }
    if [[ -n "$remote" ]]; then
        echo "issue $N ($title): skipped-claim-lost"
        continue
    fi

    # One body fetch serves both the blocker filter and the rent-paying band
    # (band-multiplier lives on the body). A failed view is fail-closed: skip
    # this issue this tick rather than claim a possibly-blocked or
    # out-of-band issue. The next tick retries.
    body=$(gh issue view "$N" -R "$FULL" --json body --jq '.body // ""' 2>/dev/null) || {
        echo "issue $N ($title): skipped-body-unreadable"
        continue
    }

    # Blocker filter: never claim an issue whose body carries a blocked-on:
    # line (machine dep or nish-decision). The claim is a no-op spawn churn
    # otherwise. Audit finding 2026-08-26: fleet-ops#87 looped exactly this way.
    if blocked_filter "$body"; then
        echo "issue $N ($title): skipped-blocked-on"
        continue
    fi

    # Rent-paying band (fleet-ops#1223): until cutoff_utc, fleet-ops intake
    # claims only surge_leverage_issues; after cutoff, a new machinery claim
    # that would push live share over machinery_max_pct is skipped unless the
    # body carries `band-multiplier: N`. Skip, do not fail the tick — product
    # ticks still run, and the next fleet-ops tick retries when a slot opens.
    band_reason=$(precedence_band_allow_claim "$REPO" "$N" "$body") || {
        echo "issue $N ($title): skipped-precedence-band ($band_reason)"
        continue
    }

    # Atomic create-only claim push (claim branch IS the work branch)
    status=0
    push_out=$(git -C "$REPO_DIR" push --force-with-lease="refs/heads/claim/issue-$N:" origin "origin/main:refs/heads/claim/issue-$N" 2>&1) || status=$?
    if (( status != 0 )); then
        if [[ "$push_out" == *"stale info"* ]] || [[ "$push_out" == *"rejected"* ]]; then
            echo "issue $N ($title): skipped-claim-lost"
            continue
        fi
        echo "git push failed for issue $N: $push_out" >&2
        exit 1
    fi

    # Mark the issue
    edit_out=$(gh issue edit "$N" -R "$FULL" --remove-label agent-ready --add-label agent-in-progress 2>&1) || {
        echo "gh issue edit failed for $N: $edit_out" >&2
        exit 1
    }

    comment_body="claimed by pi-issue-${REPO}-${N} at $(date -u +%FT%TZ)"
    comment_out=$(gh issue comment "$N" -R "$FULL" --body "$comment_body" 2>&1) || {
        echo "gh issue comment failed for $N: $comment_out" >&2
        exit 1
    }

    # Write the worker packet so pi-issue-run can pick its own seat at run time
    packet_path="$ISSUE_STATE_DIR/${REPO}-${N}.in"
    {
        cat "$WORKER_PROMPT"
        echo
        echo "TARGET: repo $FULL issue $N unit pi-issue-${REPO}-${N}"
    } > "$packet_path"

    # Activate the worker unit. --no-block is mandatory: pi-issue@.service is
    # Type=oneshot, so a plain `systemctl start` blocks until the worker finishes
    # (up to 45 min each) and serializes the whole tick past its own timeout.
    # Fire-and-forget the start job; the worker's own Restart=/OnFailure= handle
    # completion and failure. If the unit is already active/activating, skip it
    # so another agent's worker is not double-started.
    unit="pi-issue@${REPO}-${N}.service"
    pre_state=$(systemctl --user is-active "$unit" 2>/dev/null || true)
    if [[ "$pre_state" == "active" || "$pre_state" == "activating" ]]; then
        echo "issue $N ($title): skipped-already-live"
        continue
    fi

    start_status=0
    start_out=$(systemctl --user start --no-block "$unit" 2>&1) || start_status=$?
    if (( start_status != 0 )); then
        echo "issue $N ($title): spawn failed for ${REPO}-${N}: $start_status; output: $start_out"
        continue
    fi

    echo "issue $N ($title): claimed+spawned"
    slots=$(( slots - 1 ))
done

exit 0
