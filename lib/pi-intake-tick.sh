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

# SYSTEMCTL seam (fleet-ops#1546): tests inject a fake to drive the
# start-limit healer + post-condition verification deterministically.
SYSTEMCTL="${SYSTEMCTL:-systemctl}"

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
# Overridable for tests (like SEAT_LIB / PRECEDENCE_BAND_LIB / the other
# PI_INTAKE_* knobs): a test drives the tick down its low=0 claim path, and
# a hardcoded /home/nish path crashes `set -e` with exit 1 on a GitHub-hosted
# runner where the runner user cannot create /home/nish (fleet-ops#1407).
ISSUE_STATE_DIR="${PI_INTAKE_ISSUE_STATE_DIR:-/home/nish/.local/state/pi-issues}"
# fleet-ops#1455: the claims index is the durable record of which issues were
# actually claimed in this tick. opus-heartbeat-gather counts it for
# claims_last_2h; fleet-restore-drill (B.2) reads it to know which issues are
# claimed after a restore. Overridable for tests so a GitHub-hosted runner
# does not have to write under /home/nish.
CLAIMS_LOG="${PI_INTAKE_CLAIMS_LOG:-/home/nish/workspaces/agent-state/ready-work-claims.log}"
# fleet-ops#2133: reclaim cooldown. When pi-issue-failed-reap releases a
# failed worker's claim back to agent-ready, it writes a per-issue
# .cooldown marker file (UTC timestamp). Intake skips the issue for this
# many seconds so the spawn-die-respawn loop is broken: the seat-health
# ledger gets time to bench the killing seat, and the issue does not
# immediately re-enter the claimable pool. 900s = 15min is > the seat
# bench backoff (300s) and ~2x the intake timer interval, so recovery is
# automatic once the cooldown expires. Overridable for tests.
RECLAIM_COOLDOWN_S="${PI_INTAKE_RECLAIM_COOLDOWN_S:-900}"
# fleet-ops#2462: hard cap on total re-claims per issue. The reclaim cooldown
# (above) breaks the tight spawn-die-respawn loop, but an issue whose every
# seat fails with a systemic provider error (503/429/500 storm, fleet-ops#1526)
# still drains the seat pool one 900s cooldown at a time — 27 re-claims in
# 24h despite the cooldown. MAX_RECLAIMS caps the TOTAL number of times an
# issue can be re-claimed (first claim + re-claims) across all seats before
# intake stops re-claiming it and escalates. The counter is per-issue in
# $ATTEMPTS_DIR/pi-issue-${REPO}-${N}.reclaim-count; pi-issue-failed-reap
# increments it when it releases a failed claim, and pi-issue-run records
# the first (initial) claim. A successful PR open resets the counter to 0
# so a legitimately-fixed issue is never permanently locked out.
# Default 8: 1 initial + 7 re-claims gives the seat pool time to recover
# (each seat bench is 600-900s, so 8 passes covers ~2h of provider storm)
# without letting a stuck item starve the fleet for days.
MAX_RECLAIMS="${PI_INTAKE_MAX_RECLAIMS:-8}"
# fleet-ops#2772: claim-loop window gate. The #2462 reclaim-count cap is a
# per-issue bump file that pi-issue-run RESETS on any non-empty-output run
# (even one that opens no PR) and that only the failed-reap path increments
# — so a seat-storm spin survives the cap (observed: fleet-ops line=2672
# claimed 11x in 12h, 4x in the last 2h, dispatches_last_2h=0, #2772). This
# gate counts raw claims for the same line from the claims log (the durable
# append-only record, fleet-ops#1455) over a sliding window and fails the
# claim LOUD (agent-blocked + machine-readable blocked-on) once
# MAX_CLAIMS_IN_WINDOW claims happened inside RECLAIM_WINDOW_S — immune to
# counter-file resets and to reap-path gaps. Defaults match the loop shape
# that first flagged the spin: 4 claims in 2h. The 15-min reclaim cooldown
# spaces failed claims, so 4-in-window is ~1h of continuous spinning, not a
# burst of legitimate retries; and the gate sits AFTER the branch-liveness
# check, so a live worker or open PR never trips it. Overridable for tests.
RECLAIM_WINDOW_S="${PI_INTAKE_RECLAIM_WINDOW_S:-7200}"
MAX_CLAIMS_IN_WINDOW="${PI_INTAKE_RECLAIM_MAX_CLAIMS:-4}"
# The reclaim-cooldown reader below reads $ATTEMPTS_DIR/pi-issue-*.cooldown
# — the same dir pi-issue-failed-reap writes (both use
# ${PI_PACKET_STATE:-$HOME/.local/state/pi-packet}/attempts). seat-lib.sh
# binds ATTEMPTS_DIR when it is sourced, but the test stub path (SEAT_LIB
# override) does not, so under `set -u` the cooldown read killed the tick
# mid-claim with an unbound variable and P14 CI went red on main
# (fleet-ops#2281/#2326). Bind it here with the same default so every path
# reaches that read with a defined value; seat-lib.sh re-sets the identical
# path when it is sourced live, so behavior is unchanged.
ATTEMPTS_DIR="${ATTEMPTS_DIR:-${PI_PACKET_STATE:-$HOME/.local/state/pi-packet}/attempts}"
WORKER_PROMPT="/home/nish/.pi/agent/prompts/worker.md"
# SEAT_LIB may be overridden by tests via env var (like pi-issue-run).
# Default is the live install path; tests inject a stub via SEAT_LIB.
SEAT_LIB="${SEAT_LIB:-/home/nish/.local/lib/pi-packet/seat-lib.sh}"
# fleet-ops#1250: claim-step prior-art gate. Tests override the path.
PRIOR_ART_BIN="${PRIOR_ART_CLAIM_CHECK:-$HOME/.local/bin/prior-art-claim-check}"
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
# shellcheck disable=SC1091  # external lib, absent in hosted CI
. "$SEAT_LIB"
# shellcheck source=/home/nish/.local/lib/pi-packet/precedence-band.sh
# shellcheck disable=SC1091  # external lib, absent in hosted CI
. "$PRECEDENCE_BAND_LIB"
# Each tick starts with a clean floor latch. The file is keyed on $$ so a
# leftover from a recycled PID cannot freeze the floor for this tick
# (fleet-ops#1452). The flock above already serializes fleet-ops ticks.
precedence_band_pending_clear
# Same for the starvation floor latch (fleet-ops#1448): both one-lane
# reservations must start unspent each tick, else a recycled PID leaves the
# starvation floor frozen for the whole tick.
precedence_band_pending_starvation_clear

if [[ ! -x "$PRIOR_ART_BIN" ]]; then
    echo "pi-intake-tick: prior-art-claim-check missing at $PRIOR_ART_BIN" >&2
    exit 1
fi

# Step 1: list ready work
# Limit 250 (auditor 2026-08-28, summon unit-failure fleet-heartbeat): the
# prior --limit 50 returned only the 50 NEWEST agent-ready issues (gh issue
# list sorts by creation desc). With 221 ready issues, the older
# surge_leverage_issues (#1010-#1146) fell beyond position 50 and were
# invisible to the tick — the surge phase then had nothing to dispatch
# (all visible issues were non-leverage → skip-surge-leverage), causing
# fleet starvation (222 ready, 0 running). 250 covers the observed ceiling
# with headroom; the early surge skip below keeps the tick fast.
issues_json=$(gh issue list -R "$FULL" -l agent-ready --state open --json number,title,labels --limit 250 2>&1) || {
    echo "gh issue list failed: $issues_json" >&2
    exit 1
}

# fleet-ops#234: escalate-senior issues are senior-panel-owned, never a
# regular-worker claim. The model-based orderer (pi-intake-priority order,
# lib/intake-priority.sh) drops them via select(.escalation != true); the
# deterministic tick must do the same or regular workers get dispatched on
# senior-auditor escalations (the #2007 live class: pi-issue@fleet-ops-2007
# claimed an [escalate-senior] scout-futility wrapper that
# pi-escalation-audit was already convening a three-senior panel on). The
# label is fetched above so the filter is a pure jq pass; the senior-auditor
# panel lists escalate-senior directly (not agent-ready), so dropping them
# here does not hide them from the panel.
ESCALATE_LABEL="${PI_INTAKE_ESCALATE_LABEL:-escalate-senior}"
issues_json=$(jq -c --arg esc "$ESCALATE_LABEL" \
    '[.[] | select((.labels // []) | map(if type == "object" then (.name // empty) else . end) | index($esc) == null)]' \
    <<<"$issues_json" 2>/dev/null || printf '[]')

# fleet-ops#1464 — reconciler-caught counter. Every time the poll finds
# ready work, it means the GH webhook (workers/github-push-forward/ →
# gh-webhook-receiver.service) DID NOT trigger pi-intake@<repo> for this
# issue first. The counter bumps by the number of ready issues found, so
# a sustained rise means the push channel is degraded and the dead-man
# on the canary should also be firing. The metric is informational only:
# it is NOT a blocker for the tick. A rising counter is what
# fleet-intake-reconciler-stale alerts on (see config/fleet_rules.yml).
#
# Per-repo prom file (matches the existing per-repo metric convention,
# e.g. fleet-opus-heartbeat.prom is repo-scoped via Pi seat labels):
# a single shared file would be clobbered by parallel pi-intake@<repo>
# timers. Naming: ${base}-<repo>.prom, default base fleet-intake-reconciler.
reconciler_caught=0
reconciler_prom_base="${PI_INTAKE_RECONCILER_PROM:-/var/lib/prometheus/node-exporter/fleet-intake-reconciler}"
reconciler_prom="${reconciler_prom_base}-${REPO}.prom"

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

# fleet-ops#3120: conditionally append repo-specific worker prompt blocks.
# The worker prompt itself is small (≤80 lines). Extra blocks are appended
# by intake only when the issue context demands them, so most packets stay
# under the 12 KB non-0509 budget and 0509 packets stay under 20 KB.
PROMPT_DIR=$(dirname "$WORKER_PROMPT")
conditional_worker_blocks() {
    local repo="$1" title="$2" body="$3" labels="$4"
    if [[ "$repo" == "0509" ]]; then
        if printf '%s%s' "$title" "$body" | grep -qi 'migrations/'; then
            cat "$PROMPT_DIR/worker-0509-migrations.md" 2>/dev/null || true
        fi
        if printf '%s%s' "$title" "$body" | grep -qi '\.github/'; then
            cat "$PROMPT_DIR/worker-0509-gate-integrity.md" 2>/dev/null || true
        fi
    fi
    # GEO/AEO block is driven by the geo/aeo label, not free-text matches.
    if printf '%s' "$labels" | grep -qiE '"(geo|aeo)"'; then
        cat "$PROMPT_DIR/worker-geo-aeo.md" 2>/dev/null || true
    fi
}

# Vacation park (fleet-ops#1165, vacation-audit-20260827 finding 12):
# 0509's required-verifier-integrity gate blocks any PR that touches a
# protected verifier/deploy file unless a repo admin posts an exact
# `verifier-attest: <40-hex head sha>` comment. The repo has exactly one
# collaborator, so independent APPROVED review is structurally impossible
# and the sole-admin attestation is the only unblock — and workers must
# NEVER post that comment (the 2026-08-26 attestation breach). During
# Nish's vacation window, parking these issues at intake prevents workers
# from opening attest-stuck PRs that sit red until Nish returns (existing
# red PRs #1295/#1281/#1273 stay open; this only stops NEW claims).
#
# The skip is date-bounded: after PROTECTED_VERIFIER_VACATION_UNTIL the
# filter passes and intake resumes — the issue stays agent-ready throughout
# the window, so no unpark/relabel mechanism is needed. The gate itself is
# unchanged (do not weaken or remove it). All seams are env-overridable so
# the regression test can drive the date, repo, and file list without
# touching the real 0509 checkout or the clock.
PROTECTED_VERIFIER_VACATION_REPO="${PI_INTAKE_PROTECTED_VERIFIER_VACATION_REPO:-0509}"
PROTECTED_VERIFIER_VACATION_FROM="${PI_INTAKE_PROTECTED_VERIFIER_VACATION_FROM:-2026-08-28}"
PROTECTED_VERIFIER_VACATION_UNTIL="${PI_INTAKE_PROTECTED_VERIFIER_VACATION_UNTIL:-2026-09-08}"
# Mirrors the protected_files list in
# 0509 .github/scripts/required-verifier-integrity.sh. A drift here vs.
# that script is a follow-up, not a blocker for this park.
_pvv_default_files=(
    ".github/workflows/ci.yml"
    ".github/workflows/secret-scan.yml"
    ".github/workflows/required-verifier-integrity.yml"
    ".github/scripts/required-verifier-integrity.sh"
    ".github/scripts/test-required-verifier-integrity.sh"
    ".github/workflows/deploy-production.yml"
    ".github/workflows/finalize-production-soak.yml"
    "scripts/ci-verify-production-candidate.sh"
    "scripts/ci-verify-provider-main-cas.sh"
)
protected_verifier_vacation_filter() {
    # $1 = issue body. Returns 0 (skip this issue) when a protected
    # verifier/deploy path appears in the body AND today is inside the
    # vacation window [FROM, UNTIL] inclusive. Returns 1 otherwise.
    local body="$1"
    [[ "$REPO" == "$PROTECTED_VERIFIER_VACATION_REPO" ]] || return 1
    local today="${PI_INTAKE_PROTECTED_VERIFIER_VACATION_TODAY:-$(date -u +%Y-%m-%d)}"
    # YYYY-MM-DD lexicographic compare == chronological. Skip only inside
    # the window; after UNTIL the filter passes so intake resumes.
    if [[ "$today" < "$PROTECTED_VERIFIER_VACATION_FROM" \
          || "$today" > "$PROTECTED_VERIFIER_VACATION_UNTIL" ]]; then
        return 1
    fi
    local f
    if [[ -n "${PI_INTAKE_PROTECTED_VERIFIER_VACATION_FILES:-}" ]]; then
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            if printf '%s' "$body" | grep -qF -- "$f"; then
                return 0
            fi
        done <<<"$PI_INTAKE_PROTECTED_VERIFIER_VACATION_FILES"
    else
        for f in "${_pvv_default_files[@]}"; do
            if printf '%s' "$body" | grep -qF -- "$f"; then
                return 0
            fi
        done
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

# fleet-ops#1464 — bump the reconciler-caught counter. We found ready
# work via the SLOW poll; the GH webhook path either did not fire or did
# not win the race for these issues. The counter is the visibility
# signal that drives the dead-man / alert. Tests can override the
# prom path via PI_INTAKE_RECONCILER_PROM (see
# tests/fleet-intake-reconciler-counter.test.sh).
#
# Per-repo prom file means there is no read-modify-write race with
# parallel pi-intake@<other>.timer ticks (each repo owns its own file).
# Within the same repo, the flock at the top of the tick ensures only
# one tick is in flight, so the read-modify-write below is safe.
reconciler_caught=$ready_count
reconciler_ts="$(date -u +%s)"

# Read the previous cumulative value (if any) so we can add this tick's
# delta. Default 0 when the file is missing or the line is malformed.
_reconciler_prev_total=0
if [[ -f "$reconciler_prom" ]]; then
    _reconciler_prev_total=$(awk -v r="$REPO" '
        $0 ~ "fleet_intake_reconciler_caught_total\\{repo=\""r"\"\\}" {
            gsub(/[^0-9.]/, "", $2); v = int($2);
            if (v > 0) print v; else print 0; exit
        }
        END { if (NR == 0) print 0 }
    ' "$reconciler_prom" 2>/dev/null || echo 0)
    _reconciler_prev_total="${_reconciler_prev_total:-0}"
fi
_reconciler_new_total=$(( _reconciler_prev_total + reconciler_caught ))

mkdir -p "$(dirname "$reconciler_prom")" 2>/dev/null || true
# Best-effort prom export: an if/then (not A && B || C) keeps set -e from
# killing the tick on a transient prom-write failure (SC2015-safe).
if {
    printf '# HELP fleet_intake_reconciler_caught_total Cumulative number of agent-ready issues the slow poll caught that the GitHub webhook did not catch first (fleet-ops#1464).\n'
    printf '# TYPE fleet_intake_reconciler_caught_total counter\n'
    printf 'fleet_intake_reconciler_caught_total{repo="%s"} %d\n' "$REPO" "$_reconciler_new_total"
    printf '# HELP fleet_intake_reconciler_last_caught_timestamp_seconds Epoch seconds of the last time the slow poll caught at least one ready issue.\n'
    printf '# TYPE fleet_intake_reconciler_last_caught_timestamp_seconds gauge\n'
    printf 'fleet_intake_reconciler_last_caught_timestamp_seconds{repo="%s"} %d\n' "$REPO" "$reconciler_ts"
    printf '# HELP fleet_intake_reconciler_last_count Number of agent-ready issues found by the most recent slow poll (per repo).\n'
    printf '# TYPE fleet_intake_reconciler_last_count gauge\n'
    printf 'fleet_intake_reconciler_last_count{repo="%s"} %d\n' "$REPO" "$reconciler_caught"
} > "$reconciler_prom.tmp" 2>/dev/null; then
    mv "$reconciler_prom.tmp" "$reconciler_prom" 2>/dev/null || true
fi
echo "reconciler-caught: delta=$reconciler_caught total=$_reconciler_new_total repo=$REPO prom=$reconciler_prom"

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

# GitHub API rate-limit gate (fleet-ops#1350, 2026-08-27 #1167 ceiling
# addendum). The 5000/hr core budget is the next binding constraint past
# RAM: claiming N more issues this tick would burn N claim-pushes + N
# issue-view body fetches + N future worker draws against the budget, and
# a rate-limited fleet is slower than a governed one. The exporter writes
# a side-car state file (agent-state/pi-intake/gh-rate-limit.json) every
# 60s; we read it here and hold claims when ANY of the three consumed
# resources (core/search/graphql) is below the 20% threshold. A missing
# or unparseable file fails OPEN: the throttle is a soft gate, not a
# blocker, and a dead exporter must not silently freeze the fleet. The
# fetched_at age check (120s = 2x the 60s TTL) catches a stale file
# without preventing the first run after a fresh start.
gh_rl_path="${PI_INTAKE_GH_RATE_LIMIT_STATE:-/home/nish/workspaces/agent-state/pi-intake/gh-rate-limit.json}"
gh_rl_max_age="${PI_INTAKE_GH_RATE_LIMIT_MAX_AGE:-120}"
if [[ -r "$gh_rl_path" ]]; then
    _gh_rl_json=$(cat "$gh_rl_path" 2>/dev/null) || _gh_rl_json=
    if [[ -n "$_gh_rl_json" ]]; then
        _gh_rl_low=$(printf '%s' "$_gh_rl_json" | jq -r '.low // 0' 2>/dev/null) || _gh_rl_low=0
        _gh_rl_fetched=$(printf '%s' "$_gh_rl_json" | jq -r '.fetched_at // 0' 2>/dev/null) || _gh_rl_fetched=0
        _gh_rl_now=$(date +%s)
        _gh_rl_age=$(( _gh_rl_now - ${_gh_rl_fetched%.*} ))
        if (( _gh_rl_age > gh_rl_max_age )); then
            echo "gh rate-limit state stale (age=${_gh_rl_age}s > max=${gh_rl_max_age}s); ignoring — gate: gh_rate_limit stale"
        elif (( _gh_rl_low == 1 )); then
            _gh_rl_remaining=$(printf '%s' "$_gh_rl_json" | jq -r '.remaining // 0' 2>/dev/null) || _gh_rl_remaining=0
            _gh_rl_limit=$(printf '%s' "$_gh_rl_json" | jq -r '.limit // 0' 2>/dev/null) || _gh_rl_limit=0
            _gh_rl_reset=$(printf '%s' "$_gh_rl_json" | jq -r '.reset // 0' 2>/dev/null) || _gh_rl_reset=0
            _gh_rl_wait=$(( _gh_rl_reset - _gh_rl_now ))
            (( _gh_rl_wait < 0 )) && _gh_rl_wait=0
            echo "gh rate-limit low (remaining=${_gh_rl_remaining}/${_gh_rl_limit}, resets in ${_gh_rl_wait}s); holding claims this tick — gate: gh_rate_limit low"
            exit 0
        fi
    else
        echo "gh rate-limit state file unreadable or empty; failing open — gate: gh_rate_limit missing"
    fi
else
    echo "gh rate-limit state file missing; failing open — gate: gh_rate_limit missing"
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

# Product-first precedence (fleet-ops#2519): when the queue
# self-maintenance ratio exceeds PRODUCT_FIRST_SELF_RATIO_MAX (default
# 0.5), hold the self-maintenance repo (fleet-ops) in the intake buffer —
# its agent-ready issues are not admitted to the dispatch queue, so fleet
# capacity goes to product repos. Product repos are never gated. Fails
# open (admits) when the ratio is unavailable, so a dead metrics exporter
# never freezes the fleet; the fleet_queue_product_ratio metric is
# exported best-effort every tick so the precedence is observable.
#
# Only the self-maintenance repo is held: the gate checks
# config/self-maintenance-repos.json (default ["fleet-ops"]), not a
# hardcoded name, so a repo graduating to product is not gated.
#
# fleet-ops#2626: the hold must NOT hard-exit the tick. If it did, a
# self-maintenance ratio inflated by duplicate/churn agent-ready issues
# while product repos are simultaneously blocked (an all-up hard stall)
# would leave the whole fleet at 0 dispatches — the FleetUndersaturated
# failure this issue fixes. So we mark the repo held (_pfirst_held=1) and
# let the precedence-band FLOOR lanes below (machinery #1452, starvation
# #1448, band bootstrap, surge floor, leverage, multiplier) admit EXACTLY
# ONE claim per tick. That keeps the only-available-supply repo from
# starving the fleet to idle while still sending capacity to product repos
# when product work exists.
product_first_export_product_ratio
_pfirst_held=0
if product_first_is_self_maintenance "$REPO"; then
    _pfirst_ratio="$(product_first_ratio 2>/dev/null || echo unavail)"
    if product_first_hold; then
        echo "held-in-buffer: ($REPO is self-maintenance, self-maintenance ratio $_pfirst_ratio > $PRODUCT_FIRST_SELF_RATIO_MAX) — product-first precedence, product repos only; floor lanes still dispatch one claim"
        _pfirst_held=1
    fi
fi

# Pre-fetch origin once before the loop
git -C "$REPO_DIR" fetch origin 2>&1 || {
    echo "git fetch origin failed" >&2
    exit 1
}

mkdir -p "$ISSUE_STATE_DIR"

# fleet-ops#2772: snapshot the claims log once per tick for the claim-loop
# gate below. A single read keeps the per-issue awk pass cheap (the log is
# small and append-only; every worker already appends one line per claim).
# Same-tick claims cannot be missed: a claim record for issue N is appended
# only AFTER N has passed the gate, so the snapshot is consistent for every
# N processed in this tick. Missing/unreadable log -> empty snapshot -> the
# gate no-ops (fail-open), which also keeps drove-tick tests inert.
_claims_log_snapshot=""
if [[ -r "$CLAIMS_LOG" ]]; then
    _claims_log_snapshot=$(cat "$CLAIMS_LOG" 2>/dev/null || true)
fi

# Step 3: process issues in ascending number order
mapfile -t numbers < <(jq -r 'sort_by(.number) | .[].number' <<<"$issues_json")
mapfile -t titles  < <(jq -r 'sort_by(.number) | .[].title'  <<<"$issues_json")
mapfile -t labels  < <(jq -c 'sort_by(.number) | .[].labels'  <<<"$issues_json")

# Cache the precedence-band phase once (auditor 2026-08-28): with 221 ready
# issues, calling precedence_band_phase per-issue would re-read the JSON 221
# times. The phase cannot change mid-tick (it is a clock comparison).
_band_phase="$(precedence_band_phase 2>/dev/null || echo unknown)"

# fleet-ops#1431: surge-exhaustion probe. During the precedence-band surge
# phase, fleet-ops intake claims only surge_leverage_issues. When NONE of
# those are currently agent-ready (all claimed / blocked / done), a pure skip
# leaves the queue at 0 dispatches for up to the whole surge window, which
# watchers misread as "dispatcher starvation" and auto-file a false issue
# cluster. The ready set is already in hand, so detect exhaustion ONCE here
# and let the early surge skip below fall through to `precedence_band_allow_claim`,
# whose surge floor admits exactly one machinery/repair lane so the queue can
# never hard-stall. `precedence_band_is_leverage_issue` is a cheap jq probe on
# the same policy JSON already loaded by precedence_band_phase.
_surge_has_leverage=0
if [[ "$REPO" == "fleet-ops" && "$_band_phase" == "surge" ]]; then
    for _probe in "${numbers[@]}"; do
        if precedence_band_is_leverage_issue "$_probe" 2>/dev/null; then
            _surge_has_leverage=1
            break
        fi
    done
fi

for i in "${!numbers[@]}"; do
    N="${numbers[$i]}"
    title="${titles[$i]}"

    if (( slots <= 0 )); then
        echo "issue $N ($title): skipped-capacity"
        continue
    fi

    # Early surge-phase skip (auditor 2026-08-28, summon unit-failure
    # fleet-heartbeat): during surge, only surge_leverage_issues are
    # claimable. Checking this BEFORE the body fetch avoids 200+ gh issue
    # view + git fetch + git ls-remote calls for non-leverage issues that
    # would be skipped anyway. The body is only needed for the blocker
    # filter (both phases) and the band-multiplier check (band phase only).
    # Product repos are never gated (allow-product) so this only applies to
    # the machinery repo (fleet-ops).
    # fleet-ops#1431: when surge work is exhausted (no leverage issue in the
    # ready set), the early skip is RELAXED so the ordinary
    # precedence_band_allow_claim path runs and its surge floor can admit one
    # repair lane — the queue must never hard-stall at 0 dispatches through a
    # surge window. Leverage work, when present, keeps strict priority (skip
    # everything non-leverage cheaply, claim the leverage issues).
    if [[ "$REPO" == "fleet-ops" && "$_band_phase" == "surge" && "$_surge_has_leverage" == "1" ]]; then
        if ! precedence_band_is_leverage_issue "$N" 2>/dev/null; then
            echo "issue $N ($title): skipped-precedence-band (skip-surge-leverage)"
            continue
        fi
    fi

    # fleet-ops#2133: reclaim cooldown. A failed worker's claim was released
    # by pi-issue-failed-reap, which wrote a .cooldown marker. Skip this issue
    # for RECLAIM_COOLDOWN_S so the spawn-die-respawn loop is broken (the
    # seat-health ledger gets time to bench the killing seat). After expiry,
    # remove the marker and allow the claim. Checked BEFORE the git fetch /
    # ls-remote so a cooldown'd issue costs zero network calls this tick.
    _cooldown_file="$ATTEMPTS_DIR/pi-issue-${REPO}-${N}.cooldown"
    if [[ -f "$_cooldown_file" ]]; then
        _cd_ts=$(cat "$_cooldown_file" 2>/dev/null || true)
        _cd_epoch=$(date -u -d "$_cd_ts" +%s 2>/dev/null) || _cd_epoch=0
        _now_epoch=$(date -u +%s)
        _cd_age=$(( _now_epoch - _cd_epoch ))
        if (( _cd_epoch > 0 && _cd_age < RECLAIM_COOLDOWN_S )); then
            echo "issue $N ($title): skipped-reclaim-cooldown (age=${_cd_age}s < ${RECLAIM_COOLDOWN_S}s)"
            continue
        fi
        # Cooldown expired — clear the marker so the issue is claimable again.
        rm -f "$_cooldown_file" 2>/dev/null || true
    fi

    # fleet-ops#2462: reclaim-count cap. A failed worker's claim is released
    # by pi-issue-failed-reap, which increments a per-issue reclaim-count file.
    # If the issue has been re-claimed past MAX_RECLAIMS, intake stops
    # re-claiming and escalates: the issue is labelled agent-blocked with a
    # machine-readable blocked-on line so a human reviews why every seat fails.
    # A successful PR open resets the counter so a legitimately-fixed issue is
    # never permanently locked out. Checked before the git fetch / ls-remote
    # for zero network cost.
    _rc_now_epoch=$(date -u +%s)
    _reclaim_count_file="$ATTEMPTS_DIR/pi-issue-${REPO}-${N}.reclaim-count"
    _rc_current=0
    if [[ -f "$_reclaim_count_file" ]]; then
        _rc_current=$(cat "$_reclaim_count_file" 2>/dev/null || echo 0)
        _rc_current=${_rc_current//[^0-9]/}
        _rc_current=${_rc_current:-0}
    fi
    if (( _rc_current >= MAX_RECLAIMS )); then
        echo "issue $N ($title): skipped-max-reclaims (count=$_rc_current >= $MAX_RECLAIMS) - escalating to agent-blocked" >&2
        gh issue edit "$N" -R "$FULL" --add-label agent-blocked --remove-label agent-ready 2>/dev/null || true
        gh issue comment "$N" -R "$FULL" --body "fleet-ops#2462: issue $N has been re-claimed $_rc_current times (cap=$MAX_RECLAIMS). Every usable seat has failed with provider errors; re-claiming would starve the seat pool. Escalating to senior conference for review.

blocked-on: nish-decision" 2>/dev/null || true
        continue
    fi

    # fleet-ops#2462: systemic-failure skip. When every usable seat fails
    # for the same issue within a recovery window, the failure is systemic
    # (a provider-wide outage, not a seat fault). pi-issue-failed-reap writes
    # a .systemic marker when it detects the issue exhausted every usable
    # seat. Intake respects it: the issue stays agent-ready but is not
    # re-claimed until the marker ages out, giving the seat pool time to
    # recover from the provider storm.
    _systemic_file="$ATTEMPTS_DIR/pi-issue-${REPO}-${N}.systemic"
    if [[ -f "$_systemic_file" ]]; then
        _sys_ts=$(cat "$_systemic_file" 2>/dev/null || true)
        if [[ -n "$_sys_ts" ]]; then
            _sys_epoch=$(date -u -d "$_sys_ts" +%s 2>/dev/null) || _sys_epoch=0
            _sys_age=$(( _rc_now_epoch - _sys_epoch ))
            if (( _sys_epoch > 0 && _sys_age < RECLAIM_COOLDOWN_S )); then
                echo "issue $N ($title): skipped-systemic-failure (seeded $_sys_age ago, all seats failed - waiting for provider recovery)"
                continue
            fi
            rm -f "$_systemic_file" 2>/dev/null || true
        fi
    fi

    # Per-issue fetch (keeps origin/main fresh)
    git -C "$REPO_DIR" fetch origin 2>&1 || {
        echo "git fetch origin failed for issue $N" >&2
        exit 1
    }

    # Check if another agent already holds the claim branch.
    # fleet-ops#2133: a bare skip on ANY claim branch left stale claims stuck
    # forever (skipped-claim-lost) — a worker that died without the reaper
    # firing, or exited 0 without opening a PR, left a branch that intake
    # skipped every tick while the issue stayed agent-ready. Now: if the
    # worker unit is live OR an open PR exists from this branch, skip
    # correctly (work in flight / in review). Otherwise the claim is stale —
    # delete the branch and fall through to re-claim.
    remote=$(git -C "$REPO_DIR" ls-remote origin "refs/heads/claim/issue-$N" 2>&1) || {
        echo "git ls-remote failed for issue $N: $remote" >&2
        exit 1
    }
    if [[ -n "$remote" ]]; then
        _claim_unit="pi-issue@${REPO}-${N}.service"
        _claim_state=$("$SYSTEMCTL" --user is-active "$_claim_unit" 2>/dev/null || true)
        if [[ "$_claim_state" == "active" || "$_claim_state" == "activating" ]]; then
            echo "issue $N ($title): skipped-claim-live (worker $_claim_unit $_claim_state)"
            continue
        fi
        # No live worker. Is there an open PR from this branch? If so, the
        # work is done and in review — skip (do not re-claim finished work).
        _claim_prs=$(gh api "repos/$FULL/pulls?state=open&head=${FULL#*/}:claim/issue-$N&per_page=1" 2>/dev/null || true)
        _claim_pr_count=$(printf '%s' "$_claim_prs" | jq 'length // 0' 2>/dev/null || echo 0)
        if (( _claim_pr_count > 0 )); then
            echo "issue $N ($title): skipped-claim-pr-open (open PR from claim/issue-$N)"
            continue
        fi
        # Stale claim: no live worker, no open PR. The worker died without
        # the reaper firing (or the reaper failed transiently). Release the
        # stale branch so this tick can re-claim it cleanly.
        if git -C "$REPO_DIR" push origin ":refs/heads/claim/issue-$N" >/dev/null 2>&1; then
            echo "issue $N ($title): released-stale-claim (no live worker, no open PR — branch deleted, re-claiming)"
        else
            echo "issue $N ($title): skipped-claim-lost (stale branch delete failed; will retry next tick)"
            continue
        fi
    fi

    # fleet-ops#2772: claim-loop gate. By this point the branch-liveness
    # check above has ruled out a live worker (skipped-claim-live) and an
    # open PR (skipped-claim-pr-open), so every claim in the window that got
    # this far was a dead spawn. Count this line's raw claims in the claims
    # log over the sliding window; at or past the cap, the next claim is
    # another paddle into the seat pool — fail it LOUD instead of spinning:
    # agent-blocked + machine-readable blocked-on so blocked-reconcile / the
    # senior conference pick it up (same escalate pattern as #2462
    # skipped-max-reclaims). The record format is 4 space-separated fields:
    # <ISO-Z ts> claimed line=<N> repo=<repo>; timestamps compare
    # lexicographically (ISO-8601 UTC, zero-padded) — no mktime needed.
    if [[ -n "$_claims_log_snapshot" ]]; then
        _cl_now_epoch=$(date -u +%s)
        _cl_cutoff=$(date -u -d "@$(( _cl_now_epoch - RECLAIM_WINDOW_S ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) \
            || _cl_cutoff="1970-01-01T00:00:00Z"
        _cl_window_claims=$(awk -v n="$N" -v repo="$REPO" -v cutoff="$_cl_cutoff" '
            $3 == "line=" n && $4 == "repo=" repo && $1 >= cutoff { c++ }
            END { print c+0 }
        ' <<<"$_claims_log_snapshot" 2>/dev/null || echo 0)
        if (( _cl_window_claims >= MAX_CLAIMS_IN_WINDOW )); then
            echo "issue $N ($title): skipped-claim-loop (claimed ${_cl_window_claims}x in ${RECLAIM_WINDOW_S}s window, cap=$MAX_CLAIMS_IN_WINDOW) - escalating to agent-blocked" >&2
            gh issue edit "$N" -R "$FULL" --add-label agent-blocked --remove-label agent-ready 2>/dev/null || true
            gh issue comment "$N" -R "$FULL" --body "fleet-ops#2772: issue $N has been claimed ${_cl_window_claims} times in the last ${RECLAIM_WINDOW_S}s (cap=$MAX_CLAIMS_IN_WINDOW) with no open PR — the claim path is spinning dead workers into the seat pool instead of completing. Escalating to senior conference for review.

blocked-on: nish-decision" 2>/dev/null || true
            continue
        fi
    fi

    # One body fetch serves the blocker filter (blocked-on: in body).
    # The rent-paying band (band-multiplier) now uses labels (priority/emergency)
    # from the initial issue list. A failed view is fail-closed: skip
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

    # fleet-ops#1250: build-shaped issues without a Prior art section bounce
    # (agent-blocked) and must not push a claim branch. The checker fetches
    # the body itself unless PRIOR_ART_CLAIM_CHECK is a stub.
    set +e
    bounce_out=$("$PRIOR_ART_BIN" bounce -R "$FULL" --issue "$N" 2>&1)
    bounce_rc=$?
    set -e
    if (( bounce_rc == 1 )); then
        echo "issue $N ($title): skipped-spec-incomplete"
        continue
    fi
    if (( bounce_rc != 0 )); then
        echo "prior-art-claim-check bounce failed for issue $N (rc=$bounce_rc): $bounce_out" >&2
        exit 1
    fi

    # Vacation park (fleet-ops#1165, audit finding 12): for 0509, skip
    # claiming any agent-ready issue whose body names a protected
    # verifier/deploy file while inside the vacation window. This is the
    # intake-side prevention so workers do not open attest-stuck PRs that
    # sit red until Nish returns. The issue stays agent-ready and becomes
    # claimable again after the window; the gate is unchanged.
    if protected_verifier_vacation_filter "$body"; then
        echo "issue $N ($title): skipped-protected-verifier-vacation"
        continue
    fi

    # Rent-paying band (fleet-ops#1223): until cutoff_utc, fleet-ops intake
    # claims only surge_leverage_issues; after cutoff, a new machinery claim
    # that would push live share over machinery_max_pct is skipped unless the
    # issue carries a `priority` or `emergency` label. One repair lane always runs when
    # live machinery == 0 (fleet-ops#1452 floor). Skip, do not fail the tick —
    # product ticks still run, and the next fleet-ops tick retries when a
    # slot opens.
    # Legit-work guard (fleet-ops#1516): pass title and body for quality classification
    # to allow empty-product surge expansion only for upgrade/repair work.
    band_reason=$(precedence_band_allow_claim "$REPO" "$N" "${labels[$i]}" "$body" "$title") || {
        echo "issue $N ($title): skipped-precedence-band ($band_reason)"
        continue
    }

    # Product-first held repo (fleet-ops#2626): when the self-maintenance
    # ratio holds this repo, only the precedence-band FLOOR lanes may claim
    # (one lane per tick, latched by precedence_band_allow_claim) so the
    # queue can never hard-stall at 0 dispatches. Every other fleet-ops
    # claim stays held so capacity still goes to product repos when product
    # work exists. Without this, a ratio inflated by duplicate/churn issues
    # while product repos are blocked would idle every worker.
    # allow-band-surge-legit (fleet-ops#1516) is admitted too: it only fires
    # when BAND_PRODUCT==0 (precedence-band.sh:363), i.e. no product work is
    # competing, so holding it would idle every worker for nothing — the
    # exact FleetUndersaturated stall fleet-ops#2841 diagnosed.
    if [[ "$_pfirst_held" == "1" ]]; then
        case "$band_reason" in
            allow-band-bootstrap|allow-band-floor|allow-starvation-floor|allow-surge-floor|allow-surge-leverage|allow-multiplier|allow-band-surge-legit)
                echo "issue $N ($title): held-in-buffer floor lane ($band_reason) — one claim, queue not hard-stalled"
                ;;
            *)
                echo "issue $N ($title): skipped-product-first-held ($band_reason)"
                continue
                ;;
        esac
    fi

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

    # Mark the issue — retry on GitHub secondary rate limits.
    # Tolerate permanent label-state errors (agent-ready already removed
    # by a prior tick/auditor): if agent-in-progress is already set and
    # agent-ready is gone, the issue is in the desired state — no-op.
    edit_out=""
    edit_rc=0
    for _ in 1 2 3; do
        edit_rc=0
        edit_out=$(gh issue edit "$N" -R "$FULL" --remove-label agent-ready --add-label agent-in-progress 2>&1) || edit_rc=$?
        if [[ $edit_rc -eq 0 ]]; then break; fi
        case "$edit_out" in
            *"submitted too quickly"*|*"secondary rate"*|*"429"*) sleep 5 ;;
            *) break ;;
        esac
    done
    if [[ $edit_rc -ne 0 ]]; then
        labels_json=$(gh issue view "$N" -R "$FULL" --json labels --jq '.labels | map(.name)' 2>/dev/null || true)
        if echo "$labels_json" | grep -q '"agent-in-progress"' && ! echo "$labels_json" | grep -q '"agent-ready"'; then
            echo "issue $N: labels already in target state (agent-in-progress set, agent-ready removed) — idempotent skip"
        else
            echo "gh issue edit failed for $N: $edit_out" >&2
            exit 1
        fi
    fi

    # GitHub secondary rate limits on addComment ("submitted too quickly")
    # are transient — retry with backoff (fleet-ops#1350 pattern). A
    # permanent failure (auth, 404, etc.) still exits 1 after exhaustion.
    comment_body="claimed by pi-issue-${REPO}-${N} at $(date -u +%FT%TZ)"
    comment_out=""
    comment_rc=0
    for _ in 1 2 3; do
        comment_rc=0
        comment_out=$(gh issue comment "$N" -R "$FULL" --body "$comment_body" 2>&1) || comment_rc=$?
        if [[ $comment_rc -eq 0 ]]; then break; fi
        case "$comment_out" in
            *"submitted too quickly"*|*"secondary rate"*|*"429"*) sleep 5 ;;
            *) break ;;  # permanent error — do not retry
        esac
    done
    if [[ $comment_rc -ne 0 ]]; then
        # The comment is a GH-visibility nicety, not load-bearing: the claim
        # branch + label flip + claims log are the authoritative record, and
        # the worker packet + unit start below do not depend on it. A
        # sustained GitHub secondary rate limit ("submitted too quickly")
        # must not abandon an otherwise-valid claim and orphan the worker
        # spawn — that is the same loss the set -e guard above prevents.
        # Log loud and continue to spawn the worker.
        echo "issue $N: claim comment skipped (gh secondary rate limit after 3 retries: $comment_out)" >&2
    fi

    # Write the worker packet so pi-issue-run can pick its own seat at run time.
    # fleet-ops#3120: append repo-specific conditional blocks after the small
    # base prompt, not inside it, so the static prompt stays under 80 lines and
    # the per-packet size stays under 12 KB (non-0509) / 20 KB (0509).
    packet_path="$ISSUE_STATE_DIR/${REPO}-${N}.in"
    {
        cat "$WORKER_PROMPT"
        conditional_worker_blocks "$REPO" "$title" "$body" "${labels[$i]}"
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
    pre_state=$("$SYSTEMCTL" --user is-active "$unit" 2>/dev/null || true)
    if [[ "$pre_state" == "active" || "$pre_state" == "activating" ]]; then
        echo "issue $N ($title): skipped-already-live"
        continue
    fi

    # fleet-ops#1558: per-repo MemoryMax/MemoryHigh via per-instance drop-in
    # before start. Template keeps MemoryMax=6G/MemoryHigh=3G; this overrides
    # for known repos (fleet-ops light 1536M/1G, 0509 browser 2G/1536M). Missing
    # table row = keep template. daemon-reload so the fresh drop-in is seen
    # on the subsequent start (oneshot units are not lingering-loaded).
    mem_row=$(worker_memory_for_repo "$REPO" 2>/dev/null || true)
    if [[ -n "$mem_row" ]]; then
        IFS=$'\t' read -r mem_max mem_high <<<"$mem_row"
        drop_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/${unit}.d"
        mkdir -p "$drop_dir"
        drop_tmp="$drop_dir/memory.conf.tmp.$$"
        {
            printf '# fleet-ops#1558: per-repo memory cap (written by intake)\n'
            printf '[Service]\n'
            [[ -n "$mem_max" ]] && printf 'MemoryMax=%s\n' "$mem_max"
            [[ -n "$mem_high" ]] && printf 'MemoryHigh=%s\n' "$mem_high"
        } > "$drop_tmp"
        if ! cmp -s "$drop_tmp" "$drop_dir/memory.conf" 2>/dev/null; then
            mv -f "$drop_tmp" "$drop_dir/memory.conf"
            systemctl --user daemon-reload 2>/dev/null || true
        else
            rm -f "$drop_tmp"
        fi
    fi

    # fleet-ops#1587: per-repo Environment variables via per-instance drop-in.
    # Limits test parallelism (vitest forks, playwright workers) on browser-
    # heavy repos so per-worker MemoryPeak stays under the lowered cap.
    env_lines=$(worker_env_for_repo "$REPO" 2>/dev/null || true)
    if [[ -n "$env_lines" ]]; then
        drop_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/${unit}.d"
        mkdir -p "$drop_dir"
        drop_tmp="$drop_dir/environment.conf.tmp.$$"
        {
            printf '# fleet-ops#1587: per-repo test-parallelism limit (written by intake)\n'
            printf '[Service]\n'
            while IFS= read -r line; do
                [[ -n "$line" ]] && printf 'Environment=%s\n' "$line"
            done <<<"$env_lines"
        } > "$drop_tmp"
        if ! cmp -s "$drop_tmp" "$drop_dir/environment.conf" 2>/dev/null; then
            mv -f "$drop_tmp" "$drop_dir/environment.conf"
            systemctl --user daemon-reload 2>/dev/null || true
        else
            rm -f "$drop_tmp"
        fi
    fi

    # fleet-ops#1546: start-limit lockout healer + post-condition verification.
    # After a seat storm (402/429/503), dozens of pi-issue@ units sit in
    # `failed` state with StartLimitBurst exhausted. `systemctl start --no-block`
    # returns exit 0 even when the unit is in `failed`/start-limit lockout —
    # the unit never runs, but the intake logged `claimed+spawned` (the
    # spawn-vs-alive divergence: 56 claimed+spawned, 2 alive). Two fixes:
    #
    # (a) Start-limit healer: after start --no-block, check ActiveState. If
    #     `failed`, the unit is in start-limit lockout — reset-failed (the
    #     systemd-native way to clear it) and retry start once. This is the
    #     mechanical clear the issue asks for ("systemd-native: OnFailure
    #     reset, or StartLimitIntervalSec tuned"). One retry, not a loop —
    #     a second failure is reported, not papered over.
    # (b) Post-condition verification: only print `claimed+spawned` after
    #     verifying the unit is active/activating AND the packet file exists
    #     AND the claim branch exists on remote. Intentions are not success.
    start_status=0
    start_out=$("$SYSTEMCTL" --user start --no-block "$unit" 2>&1) || start_status=$?
    if (( start_status != 0 )); then
        echo "issue $N ($title): spawn failed for ${REPO}-${N}: $start_status; output: $start_out"
        continue
    fi

    # --no-block returns exit 0 even when the unit is in `failed`
    # (start-limit lockout). Verify the unit actually activated; if it is
    # still `failed`, reset-failed and retry once (the systemd-native
    # start-limit clear). A second failure is reported, not logged as success.
    post_state=$("$SYSTEMCTL" --user is-active "$unit" 2>/dev/null || true)
    if [[ "$post_state" == "failed" ]]; then
        "$SYSTEMCTL" --user reset-failed "$unit" >/dev/null 2>&1 || true
        "$SYSTEMCTL" --user start --no-block "$unit" >/dev/null 2>&1 || true
        post_state=$("$SYSTEMCTL" --user is-active "$unit" 2>/dev/null || true)
    fi

    # Post-condition verification (fleet-ops#1546): claimed+spawned must
    # mean branch + packet + unit all exist, not that start --no-block
    # returned 0. A unit that is not active/activating did not spawn.
    if [[ "$post_state" != "active" && "$post_state" != "activating" ]]; then
        echo "issue $N ($title): spawn failed (start-limit lockout, unit=$post_state) for ${REPO}-${N}"
        continue
    fi
    [[ -f "$packet_path" ]] || {
        echo "issue $N ($title): spawn failed (packet missing after write) for ${REPO}-${N}"
        continue
    }
    # Verify the claim branch survived on the remote (post-condition, not
    # intention). A missing branch means the push was rolled back or lost.
    branch_check=$(git -C "$REPO_DIR" ls-remote origin "refs/heads/claim/issue-$N" 2>/dev/null || true)
    if [[ -z "$branch_check" ]]; then
        echo "issue $N ($title): spawn failed (claim branch missing post-spawn) for ${REPO}-${N}"
        continue
    fi

    echo "issue $N ($title): claimed+spawned"
    # fleet-ops#1455: write a durable claim record so opus-heartbeat-gather
    # and fleet-restore-drill can see the claim. Guard above means we only
    # append after a verified branch+packet+unit spawn.
    _claims_dir="$(dirname "$CLAIMS_LOG")"
    mkdir -p "$_claims_dir" 2>/dev/null || true
    printf '%s claimed line=%s repo=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$N" "$REPO" >> "$CLAIMS_LOG" 2>/dev/null || true
    # fleet-ops#2462: initialize the reclaim-count to 1 on the first claim.
    # pi-issue-failed-reap increments it on each failed re-claim; when it
    # reaches MAX_RECLAIMS, intake skips the issue. A stale count file from
    # a prior claim cycle would have been cleared by the success/reset path
    # -- only write if absent so a re-claim (after cooldown expiry) does not
    # clobber an already-incremented count.
    _rc_init_file="$ATTEMPTS_DIR/pi-issue-${REPO}-${N}.reclaim-count"
    if [[ ! -f "$_rc_init_file" ]]; then
        printf '1' > "$_rc_init_file" 2>/dev/null || true
    fi
    slots=$(( slots - 1 ))
done

exit 0
