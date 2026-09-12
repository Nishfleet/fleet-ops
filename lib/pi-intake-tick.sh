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
command -v gh >/dev/null 2>&1 || export PATH=/home/nish/.local/bin:/usr/local/bin:/usr/bin:/bin:${PATH}

# Use the nishfleet-worker App token for any GitHub write. Fail closed if
# the App cannot mint and no token was inherited from a parent organ, so a
# dead App never falls through to the human gh identity (fleet-ops#3445).
# Human gh is read-only for organs; GH Actions (tests) has no App creds and
# stubs gh as read-only, so skip minting there.
if [[ -z "${GH_TOKEN:-}" && "${GITHUB_ACTIONS:-}" != "true" && "${GH:-gh}" == "gh" ]]; then
    command -v gh >/dev/null 2>&1 || export PATH=/home/nish/.local/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}
    _wt="${NISHFLEET_WORKER_TOKEN_BIN:-${HOME:-/home/nish}/.local/bin/worker-token}"
    _minted="$("$_wt" --print)" || { echo "fleet-ops#3445: $_wt --print failed - refusing human-gh writes" >&2; exit 1; }
    eval "$_minted"
    unset _wt _minted
fi

# GitHub secondary rate-limit state (fleet-ops#3445). Written when a write
# fails with "submitted too quickly"; the gate below holds the whole tick
# until the 60s x attempt backoff expires instead of failing the tick.
GH_SECONDARY_STATE_DIR="${PI_INTAKE_GH_SECONDARY_STATE_DIR:-/home/nish/workspaces/agent-state/pi-intake}"
GH_SECONDARY_STATE="$GH_SECONDARY_STATE_DIR/gh-secondary-rate.json"

# fleet-ops#5489: read-only gh seam. When the pre-check found the App
# installation budget exhausted, READ-ONLY calls (issue list, issue view,
# pr list, run list, gh api GET) take this wrapper and run WITHOUT the App
# token — gh then uses the human identity, which the fleet contract allows
# for organ READS only (fleet-ops#3445 "Human gh is read-only for organs").
# A WRITE call must never use _gh_read: writes go through plain gh with the
# App GH_TOKEN and are held by the mid-tick exhausted gate below.
_gh_read() {
    if [[ "${_gh_rl_pre_exhausted:-0}" == "1" ]]; then
        ( unset GH_TOKEN GITHUB_TOKEN; gh "$@" )
    else
        gh "$@"
    fi
}

_gh_secondary_read() {
    if [[ -f "$GH_SECONDARY_STATE" ]]; then
        cat "$GH_SECONDARY_STATE" 2>/dev/null || echo '{}'
    else
        echo '{}'
    fi
}

_gh_secondary_write() {
    local attempt="$1" backoff_until="$2"
    mkdir -p "$GH_SECONDARY_STATE_DIR"
    python3 -c "import json,sys; json.dump({'submitted_too_quickly':1,'attempt':$attempt,'backoff_until':$backoff_until,'updated_at':$(date +%s)}, sys.stdout)" > "$GH_SECONDARY_STATE.tmp"
    mv -f "$GH_SECONDARY_STATE.tmp" "$GH_SECONDARY_STATE"
}

_gh_secondary_clear() {
    mkdir -p "$GH_SECONDARY_STATE_DIR"
    python3 -c "import json,sys; json.dump({'submitted_too_quickly':0,'attempt':0,'backoff_until':0,'updated_at':$(date +%s)}, sys.stdout)" > "$GH_SECONDARY_STATE.tmp"
    mv -f "$GH_SECONDARY_STATE.tmp" "$GH_SECONDARY_STATE"
}

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
# fleet-ops#3695: worker-exit top-up debounce. pi-issue@ workers start this
# tick from their stop path (systemd/pi-issue@.service ExecStopPost) so a
# freed slot is refilled within a minute instead of at the next 20-minute
# timer tick. A cohort finishing together must cost ONE tick, not one per
# worker: a tick that starts within PI_INTAKE_DEBOUNCE_SEC of the previous
# tick's finish sleeps out the remainder — holding the flock, so the rest of
# the cohort no-ops above — and then runs once, seeing every slot the cohort
# freed. It sleeps rather than skips so the last worker of a cohort can never
# leave its slot idle until the timer. The timer tick pays the delay at most
# once. The stamp lives in the runtime lockdir (tmpfs, per boot).
_debounce_sec="${PI_INTAKE_DEBOUNCE_SEC:-60}"
_debounce_stamp="$lockdir/${REPO}.last-tick"
if [[ -f "$_debounce_stamp" ]]; then
    _debounce_mtime=$(stat -c %Y "$_debounce_stamp" 2>/dev/null || echo 0)
    _debounce_age=$(( $(date +%s) - _debounce_mtime ))
    if (( _debounce_age >= 0 && _debounce_age < _debounce_sec )); then
        echo "pi-intake-tick: $REPO tick finished ${_debounce_age}s ago (debounce ${_debounce_sec}s) — coalescing: sleep $(( _debounce_sec - _debounce_age ))s, then run"
        sleep $(( _debounce_sec - _debounce_age ))
    fi
fi
trap 'touch "$_debounce_stamp" 2>/dev/null || true' EXIT
# ISSUE_STATE_DIR is used for the worker packet written for pi-issue-run.
# It must NOT be named STATE_DIR: litellm-seat.sh redefines that for its own
# pi-packet state (watch.log, active-seats, attempts) when it is sourced below.
# Overridable for tests (like SEAT_LIB / PRECEDENCE_BAND_LIB / the other
# PI_INTAKE_* knobs): a test drives the tick down its low=0 claim path, and
# a hardcoded /home/nish path crashes `set -e` with exit 1 on a GitHub-hosted
# runner where the runner user cannot create /home/nish (fleet-ops#1407).
ISSUE_STATE_DIR="${PI_INTAKE_ISSUE_STATE_DIR:-/home/nish/.local/state/pi-issues}"
# fleet-ops#1455: the claims index is the durable record of which issues were
# actually claimed in this tick. The fleet judge (fable-check.md) reads it
# for the claims-signal; fleet-restore-drill (B.2) reads it to know which
# issues are claimed after a restore. Overridable for tests so a GitHub-hosted runner
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
# fleet-ops#4540: park cap for the protected-merged slow-spaced reclaim
# spin. A protected (owner-authored or critical-path) OPEN issue whose
# delivery PR is already MERGED and whose body carries a `termination:`
# clause naming a future runtime event stays OPEN by design (observe-to-close
# is comment-only on protected issues, fleet-ops#1435). The existing
# anti-loop gates all miss the SLOW spin: MAX_RECLAIMS (#2462) resets to 0
# on any non-empty-output run and the window gate (#2772) sees only ~3
# claims per 2h at the 15-min cooldown spacing (< cap 4). Live case: #4460
# re-claimed 9x in 9h after PR #4498 merged (~36 wasted runs over 4 days).
# This cap counts CUMULATIVE (all-time, not windowed) claims for the issue
# line from the claims log; past it, a protected issue with a
# termination clause and a merged claim-branch delivery PR is parked under
# the awaiting-runtime-gate label until the named runtime event fires or
# Nish closes the issue. The same cap gates the two non-protected parks:
# land-or-close (fleet-ops#4553: no merged claim-branch PR, termination:
# names other PRs) and mention-strand (fleet-ops#5045: every merged
# claim-branch PR is a Relates-to mention, never a delivery).
# No new timer — the label is the state. Overridable
# for tests.
PARK_MAX_CLAIMS="${PI_INTAKE_PARK_MAX_CLAIMS:-3}"
# fleet-ops#5082: lookback bound for the duplicate-of-merged-work probe —
# the number of most recent merged PRs scanned for a files:-set overlap
# when a protected issue's own claim branch never merged a delivery PR.
PARK_DUP_LOOKBACK="${PI_INTAKE_PARK_DUP_LOOKBACK:-30}"
# The reclaim-cooldown reader below reads $ATTEMPTS_DIR/pi-issue-*.cooldown
# — the same dir pi-issue-failed-reap writes (both use
# ${PI_PACKET_STATE:-$HOME/.local/state/pi-packet}/attempts). litellm-seat.sh
# binds ATTEMPTS_DIR when it is sourced, but the test stub path (SEAT_LIB
# override) does not, so under `set -u` the cooldown read killed the tick
# mid-claim with an unbound variable and P14 CI went red on main
# (fleet-ops#2281/#2326). Bind it here with the same default so every path
# reaches that read with a defined value; litellm-seat.sh re-sets the identical
# path when it is sourced live, so behavior is unchanged.
ATTEMPTS_DIR="${ATTEMPTS_DIR:-${PI_PACKET_STATE:-$HOME/.local/state/pi-packet}/attempts}"
# Overridable for tests. A hardcoded /home/nish path crashes `set -e` on a
# GitHub-hosted runner (fleet-ops#1407 / #4820): the armed-rung claim loop
# `cat`s this file, and a missing path aborts the tick before ordinary-work
# can be skipped-repair-rung.
WORKER_PROMPT="${PI_INTAKE_WORKER_PROMPT:-/home/nish/.pi/agent/prompts/worker.md}"
# fleet-ops#3247: repo-conditional worker prompt blocks. The D1 schema +
# gate-integrity block ships only for 0509 (ideally only when the issue body
# names migrations/ or .github/); the GEO/AEO block ships only when the issue
# carries a geo/aeo label. Assembled at packet-write below so non-0509 and
# non-geo packets stay lean. Overridable for tests; checkout fallback so a
# worktree run resolves the fragments before install.sh copies them.
WORKER_BLOCKS_DIR="${PI_INTAKE_WORKER_BLOCKS_DIR:-/home/nish/.pi/agent/prompts/worker-blocks}"
D1_GATE_INTEGRITY_BLOCK="d1-gate-integrity.md"
GEO_AEO_BLOCK="geo-aeo.md"
# Repo that receives the D1 + gate-integrity block. Overridable for tests.
D1_GATE_REPO="${PI_INTAKE_D1_GATE_REPO:-0509}"
# When non-empty, the D1 + gate-integrity block is further gated on the issue
# body naming one of these substrings (newline-separated). Empty = always
# append for the D1_GATE_REPO (the core requirement). Overridable for tests.
D1_GATE_BODY_NEEDLES="${PI_INTAKE_D1_GATE_BODY_NEEDLES:-migrations/
.github/}"
# SEAT_LIB may be overridden by tests via env var (like pi-issue-run).
# Default is the live install path; tests inject a stub via SEAT_LIB.
SEAT_LIB="${SEAT_LIB:-/home/nish/.local/lib/pi-packet/litellm-seat.sh}"
# fleet-ops#1250: claim-step prior-art gate. Tests override the path.
PRIOR_ART_BIN="${PRIOR_ART_CLAIM_CHECK:-$HOME/.local/bin/prior-art-claim-check}"
# fleet-ops#3254: self-maintenance claim budget. In a fleet-ops tick every
# claim is a self-maintenance (control-plane) claim, so the tick caps them
# at SELF_MAINT_CLAIM_PCT of the available slots (floor 1) so control-plane
# work cannot devour the fleet; product ticks (0509) stay uncapped. A
# critical-path / escalate-senior issue is exempt (claims even past the
# cap). The fleet-ops#180 gap-audit yield rule (which made product repos
# yield to fleet-ops gap-audit work) is retired by this cap. Overridable
# for tests.
SELF_MAINT_CLAIM_PCT="${PI_INTAKE_SELF_MAINT_CLAIM_PCT:-20}"
# Label that marks a self-maintenance issue as exempt from the 20% cap.
CRITICAL_PATH_LABEL="${PI_INTAKE_CRITICAL_PATH_LABEL:-critical-path}"
# PRECEDENCE_BAND_LIB may be overridden by tests. Checkout fallback so a
# worktree run still loads the sibling lib before install.sh copies it.
PRECEDENCE_BAND_LIB="${PRECEDENCE_BAND_LIB:-/home/nish/.local/lib/pi-packet/precedence-band.sh}"
_tick_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$PRECEDENCE_BAND_LIB" && -f "$_tick_dir/precedence-band.sh" ]]; then
    PRECEDENCE_BAND_LIB="$_tick_dir/precedence-band.sh"
fi
# Checkout fallback for the worker-blocks dir (same pattern as
# PRECEDENCE_BAND_LIB above): a worktree run resolves the fragments from the
# repo checkout before install.sh symlinks them into ~/.pi/agent/prompts.
if [[ ! -d "$WORKER_BLOCKS_DIR" ]]; then
    _blocks_fallback="$_tick_dir/../prompts/worker-blocks"
    if [[ -d "$_blocks_fallback" ]]; then
        WORKER_BLOCKS_DIR="$(cd "$_blocks_fallback" && pwd)"
    fi
fi
# Checkout fallback for worker.md (same pattern): CI and a worktree run
# resolve the prompt from the repo before install.sh copies it into ~/.pi.
if [[ ! -f "$WORKER_PROMPT" ]]; then
    _prompt_fallback="$_tick_dir/../prompts/worker.md"
    if [[ -f "$_prompt_fallback" ]]; then
        WORKER_PROMPT="$(cd "$(dirname "$_prompt_fallback")" && pwd)/worker.md"
    fi
fi
# fleet-ops#3309: claim-step size bounce. Tests override the path.
SPEC_GATE_PY="${AGENT_READY_SPEC_GATE:-}"
if [[ -z "$SPEC_GATE_PY" ]]; then
    if [[ -f "$_tick_dir/agent-ready-spec-gate.py" ]]; then
        SPEC_GATE_PY="$_tick_dir/agent-ready-spec-gate.py"
    elif [[ -f "$_tick_dir/../lib/agent-ready-spec-gate.py" ]]; then
        SPEC_GATE_PY="$_tick_dir/../lib/agent-ready-spec-gate.py"
    else
        SPEC_GATE_PY="$HOME/.local/lib/pi-packet/agent-ready-spec-gate.py"
    fi
fi
[[ -f "$PRECEDENCE_BAND_LIB" ]] || {
    echo "pi-intake-tick: precedence-band lib missing: $PRECEDENCE_BAND_LIB" >&2
    exit 1
}

# shellcheck source=/home/nish/.local/lib/pi-packet/litellm-seat.sh
# shellcheck disable=SC1091  # external lib, absent in hosted CI
. "$SEAT_LIB"
# fleet-ops#4450: shared work-supply drain math (claims/hour fallback,
# low-water drain rate). Best-effort source so a missing lib never bricks the
# tick; the low-water trigger degrades to a no-op when the lib is absent.
# shellcheck disable=SC1091  # external lib, absent in hosted CI
WS_LIB="${PI_INTAKE_WS_LIB:-/home/nish/.local/lib/pi-packet/work-supply.sh}"
if [[ -f "$WS_LIB" ]]; then
    # shellcheck disable=SC1091
    . "$WS_LIB"
fi
# shellcheck source=/home/nish/.local/lib/pi-packet/precedence-band.sh
# shellcheck disable=SC1091  # external lib, absent in hosted CI
. "$PRECEDENCE_BAND_LIB"
# fleet-ops#4801: spec-judge lib (Kimi K3 Max over shared-file batches
# before claim). Sourced like precedence-band; not executed. The judge
# prompt path resolves from the repo checkout first (worktree run), then
# the live install path, mirroring the WORKER_BLOCKS_DIR fallback above.
SPEC_JUDGE_LIB="${SPEC_JUDGE_LIB:-}"
if [[ -z "$SPEC_JUDGE_LIB" ]]; then
    if [[ -f "$_tick_dir/spec-judge.sh" ]]; then
        SPEC_JUDGE_LIB="$_tick_dir/spec-judge.sh"
    elif [[ -f "$_tick_dir/../lib/spec-judge.sh" ]]; then
        SPEC_JUDGE_LIB="$_tick_dir/../lib/spec-judge.sh"
    else
        SPEC_JUDGE_LIB="$HOME/.local/lib/pi-packet/spec-judge.sh"
    fi
fi
if [[ -f "$SPEC_JUDGE_LIB" ]]; then
    # shellcheck source=/dev/null
    . "$SPEC_JUDGE_LIB"
fi
# The judge prompt (prompts/spec-judge.md). Resolve from the repo checkout
# first (worktree run), then the live install path.
SPEC_JUDGE_PROMPT="${SPEC_JUDGE_PROMPT:-}"
if [[ -z "$SPEC_JUDGE_PROMPT" ]]; then
    if [[ -f "$_tick_dir/../prompts/spec-judge.md" ]]; then
        SPEC_JUDGE_PROMPT="$_tick_dir/../prompts/spec-judge.md"
    else
        SPEC_JUDGE_PROMPT="$HOME/.pi/agent/prompts/spec-judge.md"
    fi
fi
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
if [[ ! -f "$SPEC_GATE_PY" ]]; then
    echo "pi-intake-tick: agent-ready-spec-gate missing at $SPEC_GATE_PY" >&2
    exit 1
fi

# GitHub API rate-limit PRE-CHECK (fleet-ops#2523). The tick makes several
# gh calls (issue list, PR list, label edits) before the mid-tick rate-limit
# gate (fleet-ops#1350) below. When the core budget is nearly exhausted, those
# calls fail or burn seats on retries, stalling dispatch. This pre-check runs
# BEFORE the first gh call and skips the whole tick (exit 0) when headroom is
# low. It reads the SAME side-car state file the exporter writes every 60s
# (agent-state/pi-intake/gh-rate-limit.json) — a cached result, never a fresh
# gh api call that would itself consume quota. The tick runs every 5 min, so
# skipping one tick is safe; the next tick re-checks. Thresholds: skip when
# remaining < 500 OR headroom < 10% (remaining/limit). A missing or stale
# state file fails OPEN (the throttle is a soft gate, not a blocker).
# fleet-ops#5489: when the App installation budget is EXHAUSTED, the tick no
# longer skips the whole intake. READ-ONLY gh calls (issue/pr/run list,
# gh api GET) fall back to the human _gh_read wrapper — "Human gh is read-only
# for organs" is the fleet contract (fleet-ops#3445). WRITES (claims, labels,
# comments, PR creation) stay on the App token and back off until the
# x-ratelimit-reset time: the mid-tick gate reads the _gh_rl_pre_exhausted
# flag and holds claims; _gh_read is used ONLY for reads, so a write can
# never ride the human identity. A stale or exhausted state is never silent
# either: ONE LOUD line per tick goes to the heartbeat triage file.
_gh_app_loud() {
    local triage="${FLEET_HEARTBEAT_TRIAGE:-/home/nish/workspaces/agent-state/FLEET-HEARTBEAT-TRIAGE.md}"
    _loud_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '[%s] LOUD [GH-APP-BUDGET] %s\n' "${_loud_ts}" "$*" \
        >>"$triage" 2>/dev/null || true
}

_gh_rl_pre_reset_in() {
    local reset now wait
    reset=$(printf '%s' "${_gh_rl_pre_json:-}" | jq -r '.reset // 0' 2>/dev/null) || reset=0
    now=$(date +%s)
    wait=$(( reset - now )); (( wait < 0 )) && wait=0
    echo "$wait"
}

gh_rl_pre_path="${PI_INTAKE_GH_RATE_LIMIT_STATE:-/home/nish/workspaces/agent-state/pi-intake/gh-rate-limit.json}"
_gh_rl_pre_exhausted=0
_gh_rl_pre_reads=app
gh_rl_pre_max_age="${PI_INTAKE_GH_RATE_LIMIT_MAX_AGE:-120}"
gh_rl_pre_skip_min="${PI_INTAKE_GH_RATE_LIMIT_SKIP_MIN:-500}"
gh_rl_pre_skip_pct="${PI_INTAKE_GH_RATE_LIMIT_SKIP_PCT:-10}"
if [[ -r "$gh_rl_pre_path" ]]; then
    _gh_rl_pre_json=$(cat "$gh_rl_pre_path" 2>/dev/null) || _gh_rl_pre_json=
    if [[ -n "$_gh_rl_pre_json" ]]; then
        # Prefer resources.core: the exporter MIN-aggregates remaining/limit
        # across core/search/graphql, so top-level is the search floor (30/30)
        # while REST core is ~5000. The #4352 pre-check remaining<500 then
        # skipped every tick. Fall back to top-level for old sidecars.
        _gh_rl_pre_remaining=$(printf '%s' "$_gh_rl_pre_json" | jq -r '.resources.core.remaining // .remaining // 0' 2>/dev/null) || _gh_rl_pre_remaining=0
        _gh_rl_pre_limit=$(printf '%s' "$_gh_rl_pre_json" | jq -r '.resources.core.limit // .limit // 0' 2>/dev/null) || _gh_rl_pre_limit=0
        _gh_rl_pre_fetched=$(printf '%s' "$_gh_rl_pre_json" | jq -r '.fetched_at // 0' 2>/dev/null) || _gh_rl_pre_fetched=0
        _gh_rl_pre_now=$(date +%s)
        _gh_rl_pre_age=$(( _gh_rl_pre_now - ${_gh_rl_pre_fetched%.*} ))
        _gh_rl_pre_reset_in=$(_gh_rl_pre_reset_in)
        if (( _gh_rl_pre_age > gh_rl_pre_max_age )); then
            echo "gh rate-limit pre-check state stale (age=${_gh_rl_pre_age}s > max=${gh_rl_pre_max_age}s); failing open — gate: gh_rate_limit pre-check stale"
            # fleet-ops#5489: stale is fail-open, never silent.
            _gh_app_loud "remaining=${_gh_rl_pre_remaining} reset_in=- reads=app state_stale_age=${_gh_rl_pre_age}s (fleet-ops#5489: stale fail-open not silent)"
        else
            _gh_rl_pre_headroom=0
            if (( _gh_rl_pre_limit > 0 )); then
                _gh_rl_pre_headroom=$(( _gh_rl_pre_remaining * 100 / _gh_rl_pre_limit ))
            fi
            if (( _gh_rl_pre_remaining < gh_rl_pre_skip_min )) || (( _gh_rl_pre_headroom < gh_rl_pre_skip_pct )); then
                # Export fleet_intake_tick_skipped_rate_limit_total (per-repo
                # prom file, same convention as the reconciler/umbrella counters).
                _rl_skip_prom_base="${PI_INTAKE_RL_SKIP_PROM:-/var/lib/prometheus/node-exporter/fleet-intake-tick-skipped-rate-limit}"
                _rl_skip_prom="${_rl_skip_prom_base}-${REPO}.prom"
                _rl_skip_prev=0
                if [[ -f "$_rl_skip_prom" ]]; then
                    _rl_skip_prev=$(awk -v r="$REPO" '
                        $0 ~ "fleet_intake_tick_skipped_rate_limit_total\\{repo=\""r"\"\\}" {
                            gsub(/[^0-9.]/, "", $2); v = int($2);
                            if (v > 0) print v; else print 0; exit
                        }
                        END { if (NR == 0) print 0 }
                    ' "$_rl_skip_prom" 2>/dev/null || echo 0)
                    _rl_skip_prev="${_rl_skip_prev:-0}"
                fi
                _rl_skip_new=$(( _rl_skip_prev + 1 ))
                mkdir -p "$(dirname "$_rl_skip_prom")" 2>/dev/null || true
                if {
                    printf '# HELP fleet_intake_tick_skipped_rate_limit_total Cumulative number of intake ticks skipped because GitHub API rate-limit headroom was low (fleet-ops#2523).
'
                    printf '# TYPE fleet_intake_tick_skipped_rate_limit_total counter
'
                    printf 'fleet_intake_tick_skipped_rate_limit_total{repo="%s"} %d\n' "$REPO" "$_rl_skip_new"
                } > "$_rl_skip_prom.tmp" 2>/dev/null; then
                    mv "$_rl_skip_prom.tmp" "$_rl_skip_prom" 2>/dev/null || true
                fi
                # fleet-ops#5489: budget exhausted -> do NOT skip the tick.
                # Reads fall back to the human identity; writes back off at the
                # mid-tick gate until the x-ratelimit-reset time.
                _gh_rl_pre_exhausted=1
                _gh_rl_pre_reads=human
                _gh_app_loud "remaining=${_gh_rl_pre_remaining} reset_in=${_gh_rl_pre_reset_in}s reads=human (fleet-ops#5489)"
                echo "rate-limit headroom low, gliding intake tick onto human-gh reads, holding writes until reset (remaining=${_gh_rl_pre_remaining}/${_gh_rl_pre_limit}, headroom=${_gh_rl_pre_headroom}% < ${gh_rl_pre_skip_pct}% or < ${gh_rl_pre_skip_min}); skipped_total=$_rl_skip_new"
            fi
        fi
    else
        echo "gh rate-limit pre-check state file unreadable or empty; failing open — gate: gh_rate_limit pre-check missing"
    fi
else
    echo "gh rate-limit pre-check state file missing; failing open — gate: gh_rate_limit pre-check missing"
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
issues_json=$(_gh_read issue list -R "$FULL" -l agent-ready --state open --json number,title,labels --limit 250 2>&1) || {
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

# fleet-ops#3295: umbrella-labeled issues are tracking parents, not
# claimable work (label desc: "tracking parent; not claimable"). The
# lifecycle-label-sweep guard stops NEW umbrella issues from getting
# agent-ready, but an umbrella issue may already carry agent-ready (e.g.
# #3128 was labeled agent-ready before this guard landed, or a manual
# label edit re-added it). This filter is the intake-side guard so the
# tick never dispatches a worker on a tracker with no implementable work
# — the dead-seat loop where the worker claims, finds nothing to do, and
# dies or releases. Same jq shape as the escalate-senior filter above;
# the label is fetched in the initial list so this is a pure jq pass.
# fleet_umbrella_dispatch_total counts umbrella issues found in the
# agent-ready list BEFORE this filter drops them — a non-zero value means
# the sweep guard broke or someone manually labeled an umbrella issue
# agent-ready, but this filter still prevents the dispatch. The counter
# is informational (not a blocker); a sustained rise is a regression
# signal on the sweep guard.
UMBRELLA_LABEL="${PI_INTAKE_UMBRELLA_LABEL:-umbrella}"
umbrella_dispatch_seen=$(printf '%s' "$issues_json" | jq --arg umb "$UMBRELLA_LABEL" \
    '[(. // []) | .[] | select((.labels // []) | map(if type == "object" then (.name // empty) else . end) | index($umb) != null)] | length' 2>/dev/null || echo 0)
issues_json=$(jq -c --arg umb "$UMBRELLA_LABEL" \
    '[.[] | select((.labels // []) | map(if type == "object" then (.name // empty) else . end) | index($umb) == null)]' \
    <<<"$issues_json" 2>/dev/null || printf '[]')

# fleet-ops#3295: export fleet_umbrella_dispatch_total — cumulative count
# of umbrella-labeled issues found in the agent-ready list (the near-
# dispatch count). With both guards (sweep + intake filter) this trends to
# 0; a non-zero value means the sweep guard broke or a manual label edit
# re-added agent-ready to an umbrella issue, but the intake filter still
# prevents the dispatch. Same per-repo prom-file convention as the
# reconciler counter. Written BEFORE the no-ready-issues early exit so a
# tick that found only umbrella issues still records them. Tests override
# the path via PI_INTAKE_UMBRELLA_PROM.
umbrella_prom_base="${PI_INTAKE_UMBRELLA_PROM:-/var/lib/prometheus/node-exporter/fleet-umbrella-dispatch}"
umbrella_prom="${umbrella_prom_base}-${REPO}.prom"
_umbrella_prev_total=0
if [[ -f "$umbrella_prom" ]]; then
    _umbrella_prev_total=$(awk -v r="$REPO" '
        $0 ~ "fleet_umbrella_dispatch_total\\{repo=\""r"\"\\}" {
            gsub(/[^0-9.]/, "", $2); v = int($2);
            if (v > 0) print v; else print 0; exit
        }
        END { if (NR == 0) print 0 }
    ' "$umbrella_prom" 2>/dev/null || echo 0)
    _umbrella_prev_total="${_umbrella_prev_total:-0}"
fi
_umbrella_new_total=$(( _umbrella_prev_total + umbrella_dispatch_seen ))
if {
    printf '# HELP fleet_umbrella_dispatch_total Cumulative number of umbrella-labeled issues found in the agent-ready list by the intake tick (fleet-ops#3295). Trends to 0 with both guards; non-zero means the sweep guard broke but the intake filter still prevents dispatch.\n'
    printf '# TYPE fleet_umbrella_dispatch_total counter\n'
    printf 'fleet_umbrella_dispatch_total{repo="%s"} %d\n' "$REPO" "$_umbrella_new_total"
} > "$umbrella_prom.tmp" 2>/dev/null; then
    mv "$umbrella_prom.tmp" "$umbrella_prom" 2>/dev/null || true
fi
if (( umbrella_dispatch_seen > 0 )); then
    echo "umbrella-dispatch-seen: delta=$umbrella_dispatch_seen total=$_umbrella_new_total repo=$REPO (intake filter prevented dispatch)"
fi

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
# e.g. fleet-intake-reconciler-<repo>.prom is repo-scoped via Pi seat labels):
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
# fleet-ops#4395 belt-and-braces: a `blocked-on:` line naming an issue/PR that
# is CLOSED/MERGED must NOT count as blocked. blocked-reconcile owns the
# agent-blocked label and clears closed-ref blockers on its 30-min sweep, but
# the intake-side guard must not re-claim an issue whose blocker is already
# resolved (the stale-label window). This helper resolves each machine-
# checkable blocker target's live state via gh and returns 0 (blocked) only
# while at least one target is still open. Special markers (nish-decision,
# orchestrator, infra, senior-review) are not issue refs and always count as
# blocked. Fail-safe: a gh error leaves the issue blocked (never claim on a
# lookup failure).
#
# Args: $1=body  $2=repo (Nishfleet/<repo>)  $3=issue number  $4=latest comment only
# The comment scan closes fleet-ops#3575: the worker bounce protocol puts
# machine-readable `blocked-on:` lines in a comment, not the body, so a
# blocked issue whose blocker lives only in comments must not re-claim.
# blocked-reconcile already reads comments (issue JSON), so this keeps the
# intake-side guard consistent with reconcile's view of the same blocker.
# Returns: 0 = blocked (do not claim), 1 = not blocked (claimable)
blocked_filter() {
    local body="$1" repo="$2" num="$3" comments="${4:-}"
    local line ref owner rname target_num
    local any_machine=0 any_open=0 text
    text="$(printf '%s\n%s' "$body" "${comments:-}")"
    if ! printf '%s' "$text" | grep -qE '^blocked-on:'; then
        return 1
    fi
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        ref=$(printf '%s' "$line" | sed -E 's/^blocked-on:[[:space:]]*//' | sed -E 's/[[:space:]]+$//')
        case "$ref" in
            nish-decision|orchestrator|infra|senior-review|senior-conference)
                # Special marker — not an issue ref; always a live blocker.
                any_open=1
                continue
                ;;
            re-open-*)
                # fleet-ops#4626: date-gate. A future timestamp is a live
                # blocker; a past timestamp is stale (blocked-reconcile owns
                # the smoke + label flip; intake must not re-wedge a flipped
                # issue whose body still carries the spent gate).
                _dg_rest="${ref#re-open-}"
                if [[ "$_dg_rest" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?Z) ]]; then
                    _dg_iso="${BASH_REMATCH[1]}"
                    any_machine=1
                    _dg_epoch=$(date -u -d "$_dg_iso" +%s 2>/dev/null) || _dg_epoch=""
                    _now_epoch=$(date -u +%s)
                    if [ -z "$_dg_epoch" ] || [ "$_now_epoch" -lt "$_dg_epoch" ]; then
                        any_open=1
                    fi
                else
                    any_open=1
                fi
                continue
                ;;
            split)
                # Spec-gate bounce record, not an independent blocker: the
                # agent-ready spec gate re-counts live required: lines and
                # re-bounces (agent-blocked, no claim) on every tick, so a
                # stale `blocked-on: split` must not wedge an issue whose
                # split was judge-rejected (0509#1383, 2026-09-08: 4 stale
                # split comments kept an agent-ready issue unclaimable 7h).
                # any_machine=1 so an all-split blocker set reads as stale.
                any_machine=1
                continue
                ;;
        esac
        # Resolve the target ref to owner/repo/number.
        if [[ "$ref" =~ ^https://github\.com/([^/]+)/([^/]+)/(issues|pull)/([0-9]+)/?$ ]]; then
            owner="${BASH_REMATCH[1]}"; rname="${BASH_REMATCH[2]}"
            target_num="${BASH_REMATCH[4]}"
        elif [[ "$ref" =~ ^([^/]+)/([^/]+)#([0-9]+)$ ]]; then
            owner="${BASH_REMATCH[1]}"; rname="${BASH_REMATCH[2]}"; target_num="${BASH_REMATCH[3]}"
        elif [[ "$ref" =~ ^#([0-9]+)$ ]]; then
            owner="${repo%%/*}"; rname="${repo#*/}"; target_num="${BASH_REMATCH[1]}"
        else
            # Unparseable ref — treat as a live blocker (fail-safe).
            any_open=1
            continue
        fi
        any_machine=1
        # Resolve the target's live state. A PR is checked via the pulls
        # endpoint so a merged PR counts as cleared.
        local state_json is_pr state merged
        if ! state_json=$(_gh_read api "repos/${owner}/${rname}/issues/${target_num}" 2>/dev/null); then
            any_open=1
            continue
        fi
        is_pr=$(printf '%s' "$state_json" | jq -r 'if .pull_request then "yes" else "no" end' 2>/dev/null || echo no)
        if [ "$is_pr" = "yes" ]; then
            if ! state_json=$(_gh_read api "repos/${owner}/${rname}/pulls/${target_num}" 2>/dev/null); then
                any_open=1
                continue
            fi
            merged=$(printf '%s' "$state_json" | jq -r '.merged' 2>/dev/null || echo false)
            if [ "$merged" = "true" ]; then
                # Merged PR clears the blocker.
                continue
            fi
            # A closed-unmerged PR is still a blocker (fleet-ops#364).
            any_open=1
            continue
        fi
        state=$(printf '%s' "$state_json" | jq -r '.state' 2>/dev/null || echo open)
        if [ "$state" != "closed" ]; then
            any_open=1
        fi
    done < <(printf '%s' "$text" | grep -E '^blocked-on:')
    if [ "$any_machine" -eq 1 ] && [ "$any_open" -eq 0 ]; then
        echo "issue $num ($repo): stale blocker — all blocked-on targets closed/merged; letting through"
        return 1
    fi
    return 0
}

# _depends_on_refs — read an issue body on stdin, print candidate
# dependency refs (one per line) for the depends-on gate. Two forms count
# (fleet-ops#5107):
#   1. a line-start `depends-on:` line (the structured line) — refs from
#      the whole line, the original gate behaviour, unchanged;
#   2. a mid-line `depends-on:` token, but ONLY inside an appended
#      `## ...edits (binding…)` section: a judge bullet like
#      "add `depends-on: #2359`" never matched the line-start form, so the
#      gate claimed those tickets anyway. Outside a binding section a
#      mid-line token is prose ABOUT the gate (evidence lists like
#      "`depends-on:` is still `none`: #2352, #2383"), and a bare mid-line
#      match would misread those trailing issue numbers as live deps and
#      park the ticket on its own evidence list. For a mid-line token,
#      refs are read only from the text AFTER it, so a `#<n>` before the
#      token is not misread.
# Candidate refs are emitted in leftmost-longest order (owner/repo#n,
# repo#n, #n) so an org-less `repo#<n>` token survives intact for the
# caller's shape check to drop.
_depends_on_refs() {
    local in_binding=0 line frag
    while IFS= read -r line; do
        if [[ "$line" =~ ^##[[:space:]]+.*edits[[:space:]]+\(binding ]]; then
            in_binding=1
        elif [[ "$line" =~ ^##[[:space:]]+ ]]; then
            in_binding=0
        fi
        if [[ "$line" =~ ^depends-on: ]]; then
            frag="$line"
        elif (( in_binding == 1 )) && [[ "$line" == *depends-on:* ]]; then
            frag="${line#*depends-on:}"
        else
            continue
        fi
        printf '%s\n' "$frag" \
            | grep -oE '[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+|[A-Za-z0-9_.-]+#[0-9]+|#[0-9]+' || true
    done
}

# fleet-ops#4808 + fleet-ops#5165: ticket-gate filter. An agent-ready issue
# can carry body gate lines naming issues/PRs that must be DONE before it is
# claimable:
#   - `depends-on:` — ordering dependencies (e.g. a seam batch where #2218
#     must land before the six sources that depend on it), and
#   - `collision-gate:` — the 0509 ticket format's same-file blockers
#     ("collision-gate (Fable <ts>): shares <file> with #a, #b"). The gate
#     also lives in Fable's judge packet and ticket-gates.json, but the body
#     line is the ticket's own declaration and is honoured even when the
#     gate file is stale or absent. 0509#2408 was claimed past an open
#     blocker because nothing parsed the line — one wasted worker slot, and
#     a same-file PR racing the blocker on a worse day.
# Claiming such an issue spawns a worker that cannot make progress — it
# would have to hand-gate by removing agent-ready. This filter resolves
# each named ticket and skips the issue (stays agent-ready, no de-label)
# until every named ticket is DONE.
#
# A named ticket is DONE when the referenced issue is:
#   - closed (state=closed), OR
#   - has a merged PR whose branch is claim/issue-<n> or fable/issue-<n>, OR
#   - has any merged PR linked via "closes #n" (a cross-referenced PR).
#
# Cycle: if A depends on B and B depends on A, neither can ever be DONE
# while the other is open, so both are skipped with `depends-on-cycle`
# instead of a misleading `skipped-depends-on:#n`. (depends-on only —
# collision gates are one-directional: the later ticket names the earlier
# blockers it must not race.)
#
# fleet-ops#5107: inside an appended `## *edits (binding…)` section the
# depends-on: token also counts MID-LINE — a judge bullet like
# "add `depends-on: #2359`" never matched `^depends-on:`, so the gate let
# those tickets be claimed anyway. Outside binding sections only the
# line-start form counts: issue prose discusses the gate itself
# ("`depends-on:` is still `none`: #2352, #2383…"), and a bare mid-line
# match would misread those trailing issue numbers as live deps and park
# the ticket on its own evidence list. See _depends_on_refs above.
#
# Ref shapes: `#<n>` (same repo) and `owner/repo#<n>` (cross-repo). An
# org-less `repo#<n>` token — e.g. the "permanent fix fleet-ops#4808"
# trailer every 0509 collision-gate line carries — is NOT a ref and is
# ignored; sliced to `#<n>` it would resolve in the wrong repo and wedge
# the gate on a nonexistent same-repo issue.
#
# Caching: resolution is memoised per tick in the _dep_state_cache and
# _dep_body_cache associative arrays (one gh call per referenced issue per
# tick), so a ticket named by many issues costs one lookup.
#
# Args: $1=body  $2=repo (Nishfleet/<repo>)  $3=issue number
# Returns: 0 = claimable (no gate refs, or all DONE); 1 = skip. On skip,
# prints the reason (skipped-depends-on:#n, skipped-collision-gate:#n, or
# depends-on-cycle) to stdout.
depends_on_filter() {
    local body="$1" repo="$2" num="$3"
    local ref owner rname target_num dep_key dep_state dep_body
    local gate_re skip_reason gi
    local -a deps=()

    # Gate line regex -> skip reason. depends-on is checked first: when both
    # lines name unmet tickets the ordering gate's reason is the more
    # actionable one. The collision-gate line may carry a parenthetical
    # annotation before the colon ("collision-gate (Fable <ts>):").
    local -a _gate_res=(
        '^depends-on:'
        '^collision-gate([[:space:]]*\([^)]*\))?[[:space:]]*:'
    )
    local -a _gate_reasons=('skipped-depends-on' 'skipped-collision-gate')

    for gi in 0 1; do
        gate_re="${_gate_res[$gi]}"
        skip_reason="${_gate_reasons[$gi]}"

        # Parse the gate line(s). Candidate refs are emitted in
        # leftmost-longest order so an org-less `repo#<n>` token survives
        # intact for the shape check below to drop — the bare-`#<n>`
        # alternative alone would slice `#4808` out of `fleet-ops#4808` and
        # resolve it in the wrong repo. Prose like "none" or "any of" yields
        # no refs.
        # fleet-ops#5107: for depends-on the parse is _depends_on_refs —
        # line-start anywhere plus the mid-line token inside an appended
        # `## ...edits (binding…)` section (a judge bullet like
        # "add `depends-on: #2359`"). collision-gate stays line-start only.
        if [[ "$skip_reason" == "skipped-depends-on" ]]; then
            mapfile -t deps < <(printf '%s\n' "$body" | _depends_on_refs)
        else
            mapfile -t deps < <(printf '%s\n' "$body" \
                | grep -E "$gate_re" \
                | grep -oE '[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+|[A-Za-z0-9_.-]+#[0-9]+|#[0-9]+' || true)
        fi
        (( ${#deps[@]} == 0 )) && continue

        for ref in "${deps[@]}"; do
            if [[ "$ref" =~ ^#([0-9]+)$ ]]; then
                owner="${repo%%/*}"; rname="${repo#*/}"; target_num="${BASH_REMATCH[1]}"
            elif [[ "$ref" =~ ^([^/]+)/([^/]+)#([0-9]+)$ ]]; then
                owner="${BASH_REMATCH[1]}"; rname="${BASH_REMATCH[2]}"; target_num="${BASH_REMATCH[3]}"
            else
                continue  # not a ref shape (org-less repo#n etc.) — ignore
            fi
            dep_key="${owner}/${rname}#${target_num}"

            # Resolve the named ticket's DONE state (memoised per tick).
            if [[ -n "${_dep_state_cache[$dep_key]:-}" ]]; then
                dep_state="${_dep_state_cache[$dep_key]}"
            else
                dep_state="$(resolve_dep "$owner" "$rname" "$target_num")"
                _dep_state_cache[$dep_key]="$dep_state"
            fi
            if [[ "$dep_state" != "DONE" ]]; then
                if [[ "$skip_reason" == "skipped-depends-on" ]]; then
                    # Cycle detection: does the dependency itself depend on
                    # THIS issue? (A depends on B depends on A.) Fetch the
                    # dependency's body (memoised) and check its depends-on:
                    # refs — the same parse as the dep side above, so a
                    # binding-bullet back-reference counts (fleet-ops#5107).
                    if [[ -n "${_dep_body_cache[$dep_key]:-}" ]]; then
                        dep_body="${_dep_body_cache[$dep_key]}"
                    else
                        dep_body="$(_gh_read issue view "$target_num" -R "${owner}/${rname}" --json body --jq '.body // ""' 2>/dev/null || true)"
                        _dep_body_cache[$dep_key]="$dep_body"
                    fi
                    if printf '%s\n' "$dep_body" | _depends_on_refs \
                        | grep -qE "#${num}\b|${repo}#${num}\b"; then
                        echo "depends-on-cycle"
                        return 1
                    fi
                fi
                echo "${skip_reason}:${ref}"
                return 1
            fi
        done
    done
    return 0
}

# resolve_dep — is a referenced issue DONE? Prints DONE when the issue is
# closed OR has a merged PR (claim/issue-<n>, fable/issue-<n>, or any PR
# linked via "closes #n"); prints NOT_DONE otherwise. Fail-safe: a gh error
# resolves to NOT_DONE (never claim on a lookup failure).
# Args: $1=owner  $2=rname  $3=issue number
resolve_dep() {
    local owner="$1" rname="$2" num="$3"
    local state_json state
    state_json=$(_gh_read api "repos/${owner}/${rname}/issues/${num}" 2>/dev/null) || { echo "NOT_DONE"; return; }
    state=$(printf '%s' "$state_json" | jq -r '.state // "open"' 2>/dev/null || echo open)
    if [[ "$state" == "closed" ]]; then
        echo "DONE"; return
    fi
    # Merged PR with claim/issue-<n> or fable/issue-<n> branch.
    if _gh_read pr list -R "${owner}/${rname}" --head "claim/issue-${num}" --state merged --json number 2>/dev/null \
        | jq -e 'length > 0' >/dev/null 2>&1; then
        echo "DONE"; return
    fi
    if _gh_read pr list -R "${owner}/${rname}" --head "fable/issue-${num}" --state merged --json number 2>/dev/null \
        | jq -e 'length > 0' >/dev/null 2>&1; then
        echo "DONE"; return
    fi
    # Any PR linked via "closes #n" that is merged (cross-referenced PR).
    if _gh_read api "repos/${owner}/${rname}/issues/${num}/timeline" 2>/dev/null \
        | jq -e '[.[]? | select(.event == "cross-referenced") | .source.issue | select(.pull_request != null and .pull_request.merged_at != null)] | length > 0' >/dev/null 2>&1; then
        echo "DONE"; return
    fi
    echo "NOT_DONE"
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

# fleet-ops#3247: repo-conditional worker prompt blocks. Two helpers decide
# whether a conditional fragment is appended to the packet at write time:
#   d1_gate_integrity_needed: repo == D1_GATE_REPO (0509) AND, when
#     D1_GATE_BODY_NEEDLES is non-empty, the issue body names at least one
#     needle (migrations/ or .github/). Returns 0 = append, 1 = skip.
#   geo_aeo_needed: the issue labels include a name containing "geo" or "aeo"
#     (case-insensitive). Returns 0 = append, 1 = skip.
# Both are pure functions of ($REPO, $body, labels_json) — no side effects, no
# network — so the bash drill in the regression test can reproduce them
# verbatim without a live gh/systemd environment.
d1_gate_integrity_needed() {
    # $1 = issue body. Uses $REPO from the tick scope.
    local body="$1"
    [[ "$REPO" == "$D1_GATE_REPO" ]] || return 1
    # No body needles configured = always append for the D1 gate repo.
    [[ -n "$D1_GATE_BODY_NEEDLES" ]] || return 0
    local needle
    while IFS= read -r needle; do
        [[ -n "$needle" ]] || continue
        if printf '%s' "$body" | grep -qF -- "$needle"; then
            return 0
        fi
    done <<<"$D1_GATE_BODY_NEEDLES"
    return 1
}

# fleet-ops#3120/#3238 (2026-09-05): difficulty comes from the ISSUE, never from
# the packet size. The packet is worker.md (~32 KB) + a TARGET line, so
# litellm-seat's task_weight fallback (HEAVY_PKT_BYTES=8192) classified EVERY issue
# heavy and routed all work to the small capable pool while ollama and the free
# seats sat idle. Rules: keystone label/title -> keystone; label heavy, or body
# > DIFFICULTY_HEAVY_BODY_BYTES, or more than DIFFICULTY_HEAVY_REQUIRED
# `- required:` lines -> heavy; else light. Emitted AFTER the stable prompt
# (fleet-ops#4643: prefix cache needs a byte-identical prefix; difficulty
# is per-issue so it lives in the volatile tail). packet_difficulty scans
# the whole packet for a standalone `difficulty:` line and still honours it.
DIFFICULTY_HEAVY_BODY_BYTES="${PI_INTAKE_DIFFICULTY_HEAVY_BODY_BYTES:-6000}"
DIFFICULTY_HEAVY_REQUIRED="${PI_INTAKE_DIFFICULTY_HEAVY_REQUIRED:-2}"
issue_difficulty() {
    local labels_json="$1" title="$2" body="$3" lowered bytes req marker
    # keystone only by LABEL or an explicit `keystone:` title prefix — a title that
    # merely mentions the word (e.g. "Manager loop for heavy/keystone issues — part 3/9")
    # must not route a one-line child to the senior seats (2026-09-05 misfire).
    lowered="${title,,}"
    if [[ "$labels_json" == *'"keystone"'* || "$lowered" == keystone:* ]]; then echo "keystone"; return; fi
    if [[ "$labels_json" == *'"heavy"'* ]]; then echo "heavy"; return; fi
    # fleet-ops#4248: an explicit author marker in the issue body decides the
    # class when no keystone/heavy LABEL already did. Nish's standing lever for
    # spending the Cursor senior pool is "put `difficulty: senior-review` at the
    # top of the issue body so it routes to the senior group", but
    # intake recomputed the header from title/labels/body-size and wrote its own
    # value as the packet's FIRST line; packet_difficulty() (lib/litellm-seat.sh)
    # takes the first match, so the marker was silently dropped and
    # senior-review work ran as weight=light on a worker seat. Deliberately
    # placed AFTER the label checks: the marker can only decide an unlabelled
    # packet, never downgrade a curated keystone/heavy label. Vocabulary is kept
    # identical to packet_difficulty(): keystone|senior-review|heavy|light, plus
    # the `keystone: true` / `senior-review: true` boolean forms it already
    # documents. An unknown value falls through to the size heuristic, so a typo
    # degrades to the previous behaviour rather than emitting an unroutable
    # packet.
    marker=$(printf '%s\n' "${body,,}" \
        | grep -oE '^[[:space:]]*difficulty:[[:space:]]*(keystone|senior-review|heavy|light)[[:space:]]*$' \
        | head -1 || true)
    if [[ -n "$marker" ]]; then
        marker="${marker#*:}"
        echo "${marker//[[:space:]]/}"
        return
    fi
    if printf '%s\n' "${body,,}" \
        | grep -qE '^[[:space:]]*keystone:[[:space:]]*(true|yes|1)[[:space:]]*$'; then
        echo "keystone"; return
    fi
    if printf '%s\n' "${body,,}" \
        | grep -qE '^[[:space:]]*senior-review:[[:space:]]*(true|yes|1)[[:space:]]*$'; then
        echo "senior-review"; return
    fi
    bytes=$(printf '%s' "$body" | wc -c); bytes=${bytes//[^0-9]/}
    req=$(printf '%s\n' "$body" | grep -ciE '^[[:space:]]*-[[:space:]]*required[^:]*:' || true)
    if (( ${bytes:-0} > DIFFICULTY_HEAVY_BODY_BYTES )) || (( ${req:-0} > DIFFICULTY_HEAVY_REQUIRED )); then
        echo "heavy"; return
    fi
    echo "light"
}

geo_aeo_needed() {
    # $1 = labels JSON array (from gh issue list --json labels), e.g.
    # [{"name":"agent-ready",...},{"name":"geo",...}]. Returns 0 when any
    # label name contains "geo" or "aeo" (case-insensitive).
    local labels_json="${1:-}"
    [[ -n "$labels_json" ]] || return 1
    printf '%s' "$labels_json" | jq -e \
        'any(.[]?; (.name // "") | test("geo|aeo"; "i"))' >/dev/null 2>&1
}

# fleet-ops#5082: duplicate-of-merged-work probe for the park detector. A
# PROTECTED issue past PARK_MAX_CLAIMS whose own claim/issue-$N branch never
# merged a delivery PR can still have its `do:` already delivered — by
# ANOTHER issue's merged claim PR (live case: 0509#2369, delivered by
# claim/issue-2363's merged PR #2641 while #2369's own PR #2643 closed
# unmerged on a content conflict; #2641's body never named #2369). The #4540
# head-branch probe can never see that delivery. Deterministic, no LLM:
# scan the last PARK_DUP_LOOKBACK merged PRs for one whose changed-file set
# overlaps the issue's `files:` line AND that either came from a different
# claim/issue-<M> branch or names `#N` in its title/body. No `files:` line,
# no file overlap, or a prose mention alone -> no match (fleet-ops#3231).
# $1 = repo (Nishfleet/<name>), $2 = issue number, $3 = issue body.
# Echoes the duplicate PR number on match; empty output = no duplicate.
# Always returns 0 — a probe failure must never abort the tick.
park_duplicate_delivery() {
    local full="$1" n="$2" body="$3"
    local files_line recent
    files_line=$(printf '%s\n' "$body" | sed -n 's/^files:[[:space:]]*//p' | head -1 || true)
    [[ -n "$files_line" ]] || return 0
    recent=$(gh pr list -R "$full" --state merged \
        --json number,title,body,headRefName,files \
        --limit "${PARK_DUP_LOOKBACK:-30}" 2>/dev/null || echo "[]")
    printf '%s' "$recent" | jq -r --arg n "$n" --arg files "$files_line" '
        ($files | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $paths
        | [ .[] | . as $pr
            | ([$pr.files[]?.path // empty]) as $have
            | select(($paths | length) > 0)
            | select([$paths[] | select(. as $p | ($have | index($p)) != null)] | length > 0)
            | select(
                (($pr.headRefName // "") | test("^claim/issue-[0-9]+$") and $pr.headRefName != ("claim/issue-" + $n))
                or ((($pr.title // "") + "\n" + ($pr.body // "")) | test("#" + $n + "\\b"))
              )
          ] | .[0].number // empty' 2>/dev/null || true
    return 0
}

# fleet-ops#4016: event-driven work supply. An empty ready pool is the one
# signal that this repo ran out of work; do not sit on it until the
# 4-hourly pi-scout@<repo>.timer fires (2026-09-06T16:47Z: 0509 ready=0 for
# hours while the scout timer's next slot was 20:00Z). Start the repo's own
# scout unit from the empty branch. No new organ: the unit's ExecCondition
# (fleet-work-supply-canary gate: rest at >=24h runway) and the futility
# tracker (ExecStartPre/ExecStopPost) still apply, so this only runs a
# scout the timer would have been allowed to run. Debounce: skip while a
# scout run is live (active/activating); the 20-min tick period bounds
# re-triggers when the run stays dry. PI_INTAKE_SCOUT_ON_EMPTY=0 disables.
scout_on_empty() {
    [[ "${PI_INTAKE_SCOUT_ON_EMPTY:-1}" == "1" ]] || return 0
    local unit="pi-scout@${REPO}.service" state
    state=$("$SYSTEMCTL" --user show -p ActiveState --value "$unit" 2>/dev/null || true)
    case "$state" in
        active|activating|reloading)
            echo "scout-on-empty: $unit $state — skip (debounce)"
            return 0
            ;;
    esac
    echo "scout-on-empty: ready=0 for $REPO — starting $unit (ExecCondition gate applies)"
    "$SYSTEMCTL" --user start --no-block "$unit" 2>&1 \
        || echo "scout-on-empty: start $unit failed rc=$? (non-fatal)"
    return 0
}

# fleet-ops#4450 item 2: LOW-WATER supply trigger, fired from the end of the
# tick. scout_on_empty only reacts at ready==0; the low-water branch reacts
# as soon as the ready pool falls AT OR BELOW the measured drain rate — at
# 16/h the pool would otherwise sit empty most of the hour waiting for the
# 4h scout timer. Event-driven; reuses the repo's existing pi-scout@<repo>
# service via the SYSTEMCTL seam, same debounce as scout_on_empty, and the
# unit's ExecCondition (fleet-work-supply-canary gate) still decides whether
# a scout is allowed. No new timer, no new unit. PI_INTAKE_SCOUT_LOW_WATER=0
# disables. Drain comes from lib/work-supply.sh (closed-window first, then
# the intake journal claims/hour); absent lib -> no-op.
scout_low_water() {
    local unit="pi-scout@${REPO}.service" state drain after="${1:-0}"
    [[ "${PI_INTAKE_SCOUT_LOW_WATER:-1}" == "1" ]] || return 0
    if ! declare -F work_supply_drain_per_hour >/dev/null 2>&1; then
        echo "low-water: work-supply lib absent — no-op (fleet-ops#4450)"
        return 0
    fi
    drain=$(work_supply_drain_per_hour "$REPO" 2>/dev/null || printf '1\n')
    case "$drain" in
        ''|*[!0-9.]*) drain=0 ;;
    esac
    # ready_after < drain_per_hour -> the pool drains faster than it is
    # replenished; fire the scout now rather than at the next 4h timer.
    if ! awk -v a="$after" -v d="$drain" 'BEGIN{exit !(a < d)}' 2>/dev/null; then
        return 0
    fi
    state=$("$SYSTEMCTL" --user show -p ActiveState --value "$unit" 2>/dev/null || true)
    case "$state" in
        active|activating|reloading)
            echo "low-water: $unit $state — skip (debounce) ready=$after drain=$drain/h"
            return 0
            ;;
    esac
    echo "low-water: ready=${after} drain=${drain}/h -> scout started"
    "$SYSTEMCTL" --user start --no-block "$unit" 2>&1 \
        || echo "low-water: start $unit failed rc=$? (non-fatal)"
    return 0
}

# fleet-ops#4801: spec-judge apply + failure fallback. These run EVERY
# tick (even when there are no ready issues) so a landed verdict is applied
# and a dead judge unit is handled regardless of the ready pool. The apply
# step reads any verdict file for this repo and applies it mechanically;
# the failure fallback relaunches a dead judge once and, on a second
# failure, lets intake claim the batch unjudged after the window.
if [[ -f "$SPEC_JUDGE_LIB" ]]; then
    spec_judge_failure_fallback "$REPO" "$FULL"
    # Apply any landed verdict for this repo. Iterate verdict files.
    _sj_state="$(spec_judge_state_dir)"
    _sj_glob="$_sj_state/verdict-${REPO}-*.md"
    for _sj_verdict in $_sj_glob; do
        [[ -e "$_sj_verdict" ]] || continue
        _sj_sha="${_sj_verdict##*-}"
        _sj_sha="${_sj_sha%.md}"
        spec_judge_apply "$REPO" "$FULL" "$_sj_sha" "$_sj_verdict"
    done
fi

if [[ -z "$issues_json" ]] || [[ "$issues_json" == "[]" ]]; then
    echo "no ready issues"
    scout_on_empty
    exit 0
fi

ready_count=$(jq 'length' <<<"$issues_json" 2>/dev/null || echo 0)
# fleet-ops#4450: count claims actually spawned this tick so the closing
# low-water check sees the READY POOL AFTER this tick's drain, not the pool
# at tick start.
_claimed_this_tick=0
if (( ready_count == 0 )); then
    echo "no ready issues"
    scout_on_empty
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

# >>> audition-lane funcs BEGIN (extracted by tests/audition-lane.test.sh — keep both markers)
# fleet-ops#3322: audition lane. Inject new candidate seats from
# config/model-candidates.json (a committed seed from the Last30Days best-value
# research doc) into the LIVE caps as cap 1, audition: true, light issues only.
# Retire audition seats at 10 sessions / 7 days / $1 cost cap, and file a
# verdict issue (promote or audition-failed) via fleet-issue-file so a worker
# lands the config/seat-caps.json PR. No new organ — reuses the existing
# fleet-issue-file filer and the existing yield ledger. Prepaid-quota
# providers are never auditioned (defence in depth at read time).
MODEL_CANDIDATES_JSON="${PI_MODEL_CANDIDATES_JSON:-$HOME/.local/state/pi-packet/model-candidates.json}"
AUDITION_DROPPED_JSON="${PI_AUDITION_DROPPED_JSON:-$HOME/.local/state/pi-packet/audition-dropped.json}"
# fleet-ops#3811: seats the tick may NOT remove (config-declared provider-level
# audition:true, e.g. xkiro) get their verdict filed once into this map so the
# tick does not re-file the same verdict issue every tick while the seat waits
# on its config/seat-caps.json PR.
AUDITION_VERDICTED_JSON="${PI_AUDITION_VERDICTED_JSON:-$HOME/.local/state/pi-packet/audition-verdicted.json}"
# HOTFIX 2026-09-12: deployed lineage sources lib/litellm-seat.sh (pre-split),
# which never defines SEAT_YIELD_JSON — the audition retire phase read an
# unbound variable under set -u and killed every intake tick (pi-intake@
# fleet-ops failed loop). Default mirrors lib/seat-lib.sh (canonical, ad65020a):
SEAT_YIELD_JSON="${SEAT_YIELD_JSON:-$HOME/.local/state/pi-packet/seat-yield.json}"
AUDITION_MAX_SESSIONS="${PI_AUDITION_MAX_SESSIONS:-10}"
AUDITION_MAX_AGE_S="${PI_AUDITION_MAX_AGE_S:-604800}"   # 7 days
AUDITION_MAX_COST_USD="${PI_AUDITION_MAX_COST_USD:-1}"
AUDITION_RETRY_DAYS="${PI_AUDITION_RETRY_DAYS:-30}"
_ISSUE_FILE_BIN="${FLEET_ISSUE_FILE:-$(cd "$_tick_dir/.." && pwd)/bin/fleet-issue-file}"
[[ -x "$_ISSUE_FILE_BIN" ]] || _ISSUE_FILE_BIN="${FLEET_ISSUE_FILE:-$HOME/.local/bin/fleet-issue-file}"

audition_inject_and_retire() {
    [[ -f "$MODEL_CANDIDATES_JSON" ]] || return 0
    [[ -f "$SEAT_CAPS_JSON" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    # Load the prepaid provider set from the LIVE caps (defence in depth:
    # the candidate file excludes prepaid, but the tick re-checks here so a
    # stale or hand-edited candidate file can never audition a prepaid seat).
    local prepaid
    prepaid=$(jq -r '.prepaid_providers_in_order // [] | .[]' "$SEAT_CAPS_JSON" 2>/dev/null)

    # Load the dropped-candidate cooldown map ({provider/model: drop_date}).
    # A candidate dropped < AUDITION_RETRY_DAYS ago is not re-injected.
    local now_epoch
    now_epoch=$(date +%s)
    local _dropped_json=""
    [[ -f "$AUDITION_DROPPED_JSON" ]] && _dropped_json=$(cat "$AUDITION_DROPPED_JSON" 2>/dev/null || true)

    local now_iso
    now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # --- Phase 1: inject new candidates ---
    # For each candidate not already in the LIVE caps and not prepaid, inject
    # it as a new provider entry with cap 1, audition: true, and a model row
    # with cap 1, audition: true. The LIVE caps file is the only place these
    # live until promoted (config/seat-caps.json is untouched by the tick).
    local injected=0
    local tmp_caps
    tmp_caps=$(mktemp)
    # Start from the current LIVE caps; jq merges each candidate in.
    cp -f "$SEAT_CAPS_JSON" "$tmp_caps"

    while IFS=$'\t' read -r cp cm cc; do
        [[ -n "$cp" && -n "$cm" ]] || continue
        # Skip prepaid providers (never auditioned — standing rule).
        if [[ -n "$prepaid" ]] && grep -qx "$cp" <<<"$prepaid"; then
            echo "audition: skip $cp/$cm (prepaid-quota provider — never auditioned)"
            continue
        fi
        # Skip if dropped < AUDITION_RETRY_DAYS ago.
        local _ck="$cp/$cm" _drop_ts _drop_age
        if [[ -n "$_dropped_json" ]]; then
            _drop_ts=$(printf '%s' "$_dropped_json" | jq -r --arg k "$_ck" '.[$k] // empty' 2>/dev/null || true)
            if [[ "$_drop_ts" =~ ^[0-9]+$ ]]; then
                _drop_age=$(( now_epoch - _drop_ts ))
                if (( _drop_age < AUDITION_RETRY_DAYS * 86400 )); then
                    echo "audition: skip $cp/$cm (dropped ${_drop_age}s ago, retry in $(( AUDITION_RETRY_DAYS * 86400 - _drop_age ))s)"
                    continue
                fi
            fi
        fi
        local class="${cc:-metered}"
        [[ "$class" == "subscription" ]] && class="prepaid-quota"
        # Defence in depth: never inject a prepaid-quota class candidate.
        [[ "$class" == "prepaid-quota" ]] && { echo "audition: skip $cp/$cm (class prepaid-quota — never auditioned)"; continue; }
        # Skip if the model is already in the LIVE caps (already wired or
        # auditioning) — the candidate is only injected when the MODEL is new.
        if jq -e --arg p "$cp" --arg m "$cm" '.providers[$p].models[$m]' "$tmp_caps" >/dev/null 2>&1; then
            continue
        fi
        local next_caps
        if jq -e --arg p "$cp" '.providers[$p]' "$tmp_caps" >/dev/null 2>&1; then
            # Provider already exists (a prior candidate on the same provider,
            # or a live provider): add the model to its models map with cap 1,
            # audition: true. Model-level audition only — the provider's other
            # models are untouched. If the provider cap is 0 (a parked/stale
            # provider), bump it to 1 so the audition model can actually run.
            next_caps=$(jq --arg p "$cp" --arg m "$cm" --arg ts "$now_iso" '
                .providers[$p].models[$m] = { "cap": 1, "audition": true }
                | if ((.providers[$p].audition_started // "") == "") then .providers[$p].audition_started = $ts else . end
                | if ((.providers[$p].cap // 0) == 0) then .providers[$p].cap = 1 else . end
            ' "$tmp_caps" 2>/dev/null) || continue
        else
            # Provider does not exist: create it with cap 1, class, audition:
            # true, and the model row with cap 1, audition: true.
            # audition_started records the injection time for the 7-day age cap.
            next_caps=$(jq --arg p "$cp" --arg m "$cm" --arg cls "$class" --arg ts "$now_iso" '
                .providers[$p] = {
                    "cap": 1,
                    "class": $cls,
                    "audition": true,
                    "audition_started": $ts,
                    "models": { ($m): { "cap": 1, "audition": true } }
                }
            ' "$tmp_caps" 2>/dev/null) || continue
        fi
        printf '%s' "$next_caps" > "$tmp_caps"
        echo "audition: injected $cp/$cm (cap 1, class $class, light only, $now_iso)"
        injected=$((injected + 1))
    done < <(jq -r '.candidates[]? | [.provider, .model, .class] | @tsv' "$MODEL_CANDIDATES_JSON" 2>/dev/null || true)

    # --- Phase 2: retire audition seats that hit a cap ---
    # Walk the LIVE caps for providers/models carrying audition: true, read
    # the yield ledger for their session count and cost, and retire any that
    # hit 10 sessions / 7 days / $1 cost. A retired seat is removed from the
    # LIVE caps and a verdict issue is filed via fleet-issue-file.
    #
    # fleet-ops#3811: the tick may only REMOVE seats it injected itself —
    # a model entry that is an object with audition: true. A provider-level
    # audition: true on SCALAR model rows is config-declared (e.g. xkiro was
    # wired via config PR #3505): the tick does not own those rows. Deleting
    # them here strands the seat's health ledgers as SEAT-KEY-INVALID phantoms
    # for fleet-seat-comeback-release (their walls can never drain) until the
    # next deploy reinstalls them — a permanent flap that was observed live as
    # FleetSeatComebackNeverReleased. Config-declared seats still get their
    # verdict issue filed once (it drives the promote/drop config PR) but are
    # left in the LIVE caps.
    local retired=0
    local yield_json=""
    [[ -f "$SEAT_YIELD_JSON" ]] && yield_json=$(cat "$SEAT_YIELD_JSON" 2>/dev/null || true)

    # Collect audition seats from the (potentially updated) tmp caps. The 4th
    # field is 1 when the MODEL row is a tick-injected object
    # ({cap:1,audition:true}) — only those rows may be deleted below.
    local audition_seats=""
    audition_seats=$(jq -r '
        .providers | to_entries[] | .key as $p | .value as $v |
        (if ($v|type) == "object" then ($v.models // {}) else {} end) | to_entries[] |
        select( ((.value|type) == "object" and .value.audition == true) or (($v.audition // false) == true) ) |
        "\($p)\t\(.key)\t\($v.audition_started // "")\t\(if ((.value|type) == "object" and (.value.audition // false) == true) then "1" else "0" end)"
    ' "$tmp_caps" 2>/dev/null || true)

    # Seats whose verdict issue was already filed (config-declared seats are
    # kept, so without this map the tick would re-file every run).
    local _verdicted_json=""
    [[ -f "$AUDITION_VERDICTED_JSON" ]] && _verdicted_json=$(cat "$AUDITION_VERDICTED_JSON" 2>/dev/null || true)

    # Fleet median yield (for the promote threshold). Computed from the yield
    # ledger across all seats with >= 20 sessions (non-provisional).
    local fleet_median=0.0
    if [[ -n "$yield_json" ]]; then
        fleet_median=$(printf '%s' "$yield_json" | jq -r '
            [to_entries[] | select(.value.provisional != true) | .value.yield]
            | if length > 0 then sort | .[length / 2 | floor] else 0.0 end
        ' 2>/dev/null || echo 0.0)
    fi

    while IFS=$'\t' read -r rp rm rstarted rtick_injected; do
        [[ -n "$rp" && -n "$rm" ]] || continue
        local _sessions=0 _cost=0.0 _yield=0.5 _age=0
        if [[ -n "$yield_json" ]]; then
            _sessions=$(printf '%s' "$yield_json" | jq -r --arg k "$rp/$rm" '.[$k].sessions // 0' 2>/dev/null || echo 0)
            _cost=$(printf '%s' "$yield_json" | jq -r --arg k "$rp/$rm" '.[$k].cost_usd // (.cost_per_session // 0) * (.sessions // 0)' 2>/dev/null || echo 0)
            _yield=$(printf '%s' "$yield_json" | jq -r --arg k "$rp/$rm" '.[$k].yield // 0.5' 2>/dev/null || echo 0.5)
        fi
        if [[ "$rstarted" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
            local _started_epoch
            _started_epoch=$(date -u -d "$rstarted" +%s 2>/dev/null) || _started_epoch=0
            [[ "$_started_epoch" =~ ^[0-9]+$ ]] && _age=$(( now_epoch - _started_epoch ))
        fi
        # Retirement thresholds: 10 sessions OR 7 days OR $1 cost.
        if (( _sessions >= AUDITION_MAX_SESSIONS )) \
            || (( _age >= AUDITION_MAX_AGE_S )) \
            || awk -v c="$_cost" -v m="$AUDITION_MAX_COST_USD" 'BEGIN{exit !(c+0 >= m+0)}'; then
            local _verdict
            # fleet-ops#3811: config-declared seat (provider-level audition:
            # true, scalar model row — the tick did not inject it). Removing
            # it from the LIVE caps strands its health ledgers as
            # SEAT-KEY-INVALID phantoms for comeback-release until the next
            # deploy reinstalls it — a permanent flap. File the verdict issue
            # once (it drives the promote/drop config PR) and keep the seat.
            if [[ "$rtick_injected" != "1" ]]; then
                if _audition_verdicted_has "$rp/$rm" "$_verdicted_json"; then
                    : # verdict already filed — config PR pending
                elif _verdict=$(_audition_file_verdict "$rp" "$rm" "$_yield" "$_sessions" "$_cost" "$fleet_median"); then
                    _audition_record_verdict "$rp/$rm" "$now_epoch"
                    echo "audition: config-declared seat $rp/$rm at cap — verdict $_verdict filed, seat kept in live caps (removal is a config/seat-caps.json PR, fleet-ops#3811)"
                else
                    echo "audition: config-declared seat $rp/$rm at cap — verdict filing failed, seat kept in live caps (fleet-ops#3811)"
                fi
                continue
            fi
            # Tick-injected seat: file the verdict BEFORE deleting. If the
            # filing fails the seat stays in the LIVE caps and the tick
            # retries next run — retiring without the verdict issue is silent
            # seat loss: the promote/drop never reaches config/seat-caps.json
            # (fleet-ops#3811 — observed live: --repo "fleet-ops" was rejected
            # by gh's OWNER/REPO check and the captured error text also
            # polluted _verdict, breaking the drop-cooldown compare).
            if ! _verdict=$(_audition_file_verdict "$rp" "$rm" "$_yield" "$_sessions" "$_cost" "$fleet_median"); then
                echo "audition: keep $rp/$rm (verdict filing failed — seat stays in live caps, retry next tick; fleet-ops#3811)"
                continue
            fi
            # Retire: remove the model from the provider, and if the provider
            # has no models left, remove the provider entirely. Write via a
            # temp file so tmp_caps (the path) is not clobbered by the jq
            # output before the write.
            local _retire_tmp
            _retire_tmp=$(mktemp)
            if jq --arg p "$rp" --arg m "$rm" '
                del(.providers[$p].models[$m])
                | if (.providers[$p].models | length) == 0 then del(.providers[$p]) else . end
            ' "$tmp_caps" > "$_retire_tmp" 2>/dev/null; then
                mv -f "$_retire_tmp" "$tmp_caps"
            else
                rm -f "$_retire_tmp"
            fi
            # Only a DROPPED (audition-failed) seat gets the 30-day cooldown —
            # a promoted seat is no longer a candidate, so it must not be
            # blocked from re-audition if it is later dropped from
            # config/seat-caps.json.
            if [[ "$_verdict" == "audition-failed" ]]; then
                _audition_record_drop "$rp/$rm" "$now_epoch"
            fi
            echo "audition: retired $rp/$rm (sessions=$_sessions age=${_age}s cost=\$$_cost yield=$_yield fleet_median=$fleet_median verdict=$_verdict)"
            retired=$((retired + 1))
        fi
    done <<<"$audition_seats"

    # Commit the updated LIVE caps atomically (only if changed).
    if ! cmp -s "$tmp_caps" "$SEAT_CAPS_JSON"; then
        mv -f "$tmp_caps" "$SEAT_CAPS_JSON"
        # Force litellm-seat to reload caps on the next caps read.
        _seat_caps_loaded=0
    else
        rm -f "$tmp_caps"
    fi

    if (( injected > 0 || retired > 0 )); then
        echo "audition: injected=$injected retired=$retired"
    fi
}

# Record a dropped candidate in the cooldown map.
_audition_record_drop() {
    local key="$1" epoch="$2"
    [[ -n "$key" ]] || return 0
    local tmp
    tmp=$(mktemp)
    local cur=""
    [[ -f "$AUDITION_DROPPED_JSON" ]] && cur=$(cat "$AUDITION_DROPPED_JSON" 2>/dev/null || true)
    if [[ -z "$cur" ]]; then cur='{}'; fi
    printf '%s' "$cur" | jq --arg k "$key" --argjson t "$epoch" '.[$k] = $t' > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
    mv -f "$tmp" "$AUDITION_DROPPED_JSON"
}

# True when the verdict for $1 (provider/model) was already filed. $2 is the
# preloaded AUDITION_VERDICTED_JSON content (may be empty).
_audition_verdicted_has() {
    local key="$1" json="${2:-}"
    [[ -n "$key" && -n "$json" ]] || return 1
    printf '%s' "$json" | jq -e --arg k "$key" '.[$k] != null' >/dev/null 2>&1
}

# Record a filed verdict for a kept (config-declared) seat so it is not
# re-filed every tick (fleet-ops#3811).
_audition_record_verdict() {
    local key="$1" epoch="$2"
    [[ -n "$key" ]] || return 0
    local tmp
    tmp=$(mktemp)
    local cur=""
    [[ -f "$AUDITION_VERDICTED_JSON" ]] && cur=$(cat "$AUDITION_VERDICTED_JSON" 2>/dev/null || true)
    if [[ -z "$cur" ]]; then cur='{}'; fi
    printf '%s' "$cur" | jq --arg k "$key" --argjson t "$epoch" '.[$k] = $t' > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
    mv -f "$tmp" "$AUDITION_VERDICTED_JSON"
}

# File a promote or audition-failed verdict issue via fleet-issue-file.
# Reuses the existing organ (fleet-ops#3322 orchestrator decision Q2: option c).
# Prints the verdict ("promote" or "audition-failed") on stdout so the caller
# can apply the 30-day cooldown only to dropped seats. Returns non-zero when
# the issue could not be filed — the caller must then keep the seat in the
# LIVE caps (retirement without a filed verdict is silent seat loss,
# fleet-ops#3811).
_audition_file_verdict() {
    local p="$1" m="$2" y="$3" s="$4" c="$5" median="$6"
    local title body verdict
    # A seat with zero yield must not "promote" on a degenerate fleet median of
    # 0.0 (no non-provisional baseline) — promotion needs a positive yield at
    # or above the median (fleet-ops#3811: xkiro seats at yield 0.0 after 20
    # sessions were about to be filed as "promote").
    if awk -v y="$y" -v m="$median" 'BEGIN{exit !((y+0) > 0 && (y+0) >= (m+0))}'; then
        verdict="promote"
        title="promote $p/$m into seat-caps (yield $(printf '%.0f' "$(awk "BEGIN{print $y*100}")")%, cost \$$c)"
        body="Audition complete (fleet-ops#3322). The seat $p/$m reached $s sessions with yield $(printf '%.1f' "$(awk "BEGIN{print $y*100}")")% (fleet median $(printf '%.1f' "$(awk "BEGIN{print $median*100}")")%) and total cost \$$c. Promote: add $p/$m to config/seat-caps.json with an appropriate cap. Numbers: sessions=$s yield=$y cost_usd=$c fleet_median=$median."
    else
        verdict="audition-failed"
        title="drop $p/$m — audition-failed: yield $(printf '%.0f' "$(awk "BEGIN{print $y*100}")")%, cost \$$c"
        body="Audition complete (fleet-ops#3322). The seat $p/$m reached $s sessions with yield $(printf '%.1f' "$(awk "BEGIN{print $y*100}")")% (fleet median $(printf '%.1f' "$(awk "BEGIN{print $median*100}")")%) and total cost \$$c. Drop: add a dated \`audition-failed:\` note to config/seat-caps.json so $p/$m is not re-tried for 30 days. Numbers: sessions=$s yield=$y cost_usd=$c fleet_median=$median."
    fi
    # File via fleet-issue-file with the agent-ready label so a worker picks
    # it up. gh requires the OWNER/REPO form (fleet-ops#3811: "--repo fleet-ops"
    # failed every filing). The filer's output is captured into _file_out —
    # sending it to this function's stdout would pollute the caller's
    # $(verdict) capture and silently break the drop-cooldown compare.
    if [[ -x "$_ISSUE_FILE_BIN" ]]; then
        local _file_out
        if ! _file_out=$("$_ISSUE_FILE_BIN" file --repo "Nishfleet/fleet-ops" --title "$title" --body "$body" --label agent-ready 2>&1); then
            echo "audition: WARNING — fleet-issue-file failed for $verdict $p/$m: $_file_out (seat kept, retry next tick)" >&2
            return 1
        fi
    else
        echo "audition: WARNING — fleet-issue-file not executable at $_ISSUE_FILE_BIN for $verdict $p/$m (seat kept, retry next tick)" >&2
        return 1
    fi
    printf '%s' "$verdict"
}

# <<< audition-lane funcs END

# Run the audition lane (fail-open: any error is logged and the tick continues).
audition_inject_and_retire 2>&1 || echo "audition: non-fatal error (fail-open)"

# Step 2: capacity (P4-A — fleet-ops config/seat-caps.json declared caps, not a
# hardcoded cap; fleet-ops#4263: the RAM-charge governor is gone — per-worker
# RAM is bounded by the per-instance MemoryMax drop-in + oomd, and the LiteLLM
# proxy owns seat routing/cooldown).
total_cap=$(seat_max_concurrent 2>/dev/null || echo 0)
active=$(count_active_workers 2>/dev/null || echo 0)
# slots = remaining worker capacity (integer count of how many more workers fit).
slots=$(( total_cap - active ))
(( slots < 0 )) && slots=0

if (( slots <= 0 )); then
    echo "at capacity (total_cap=$total_cap, active=$active)"
    exit 0
fi

# fleet-ops#3861: load_seat_caps must run in the PARENT shell so the
# spawn_stagger_s (SEAT_SPAWN_STAGGER_S) the claim loop sleeps actually
# carries the config/seat-caps.json value. Command-substitution call sites
# run in a subshell where load_seat_caps sets SEAT_* vars that die when the
# subshell exits — so SEAT_SPAWN_STAGGER_S never reached the parent and the
# 5s cohort stagger stayed inert (fleet-ops#3784). Audition (above) may have
# rewritten the LIVE caps, so load AFTER it reads the current file for the
# probes and the claim loop below. Fail-open: a missing/unparseable caps
# file falls back to SEAT_SPAWN_STAGGER_S=0 inside load_seat_caps.
_seat_caps_loaded=0
load_seat_caps || true

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
# fleet-ops#5489: the pre-check already classified the App budget as
# exhausted this tick (and the issue list happened before this gate). WRITES (claims, labels, comments, PR creation) back off until the
# App x-ratelimit-reset instead of failing open or burning App calls. This
# hold runs BEFORE the exporter-based gate so the exhausted hold applies
# even if the side-car exporter flags disagree.
if (( ${_gh_rl_pre_exhausted:-0} == 1 )); then
    echo "gh_app budget exhausted (remaining=${_gh_rl_pre_remaining:-unknown}, resets in ${_gh_rl_pre_reset_in:-0}s); reads ran on human gh, holding claims this tick until reset — gate: gh_app_budget exhausted (fleet-ops#5489)"
    exit 0
fi
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

# GitHub secondary rate-limit gate (fleet-ops#3445): the write loops below
# persist this state when "submitted too quickly" exhausts its retries and
# give the tick a 60s x attempt backoff. While the backoff is active, hold
# the whole tick (do not fail it) so the claim push is not orphaned and the
# human-gh secondary limit is not hammered further.
_gh_secondary_json=$(_gh_secondary_read)
_gh_secondary_active=$(printf '%s' "$_gh_secondary_json" | jq -r '.submitted_too_quickly // 0')
_gh_secondary_backoff=$(printf '%s' "$_gh_secondary_json" | jq -r '.backoff_until // 0')
_gh_secondary_now=$(date +%s)
if [[ "$_gh_secondary_active" == "1" && $_gh_secondary_backoff -gt $_gh_secondary_now ]]; then
    _gh_secondary_attempt=$(printf '%s' "$_gh_secondary_json" | jq -r '.attempt // 0')
    _gh_secondary_wait=$(( _gh_secondary_backoff - _gh_secondary_now ))
    echo "gh secondary rate-limit active (attempt=${_gh_secondary_attempt}, back in ${_gh_secondary_wait}s); holding claims this tick — gate: gh_rate_limit secondary"
    exit 0
elif [[ "$_gh_secondary_active" == "1" && $_gh_secondary_backoff -le $_gh_secondary_now ]]; then
    _gh_secondary_clear
fi

# Repair rung state helpers (fleet-ops#4639). A RESERVED escape from the
# capacity deadlock: worker capacity exhausted so the repair issues
# themselves sit skipped-capacity every tick. Trigger: usable headroom < 2
# for >= 2 consecutive ticks. Then intake claims critical-path fleet-ops
# ONLY, exempt from yield caps and the light-only/audition filter, capped
# at 2 concurrent rung workers, every use logged REPAIR-RUNG.
# fleet-ops#4820: the rung stands down only after usable headroom returns
# for DISARM_AFTER consecutive ticks (mirrors the arm rule). Remaining-slot
# COUNT staying 0 was the latch this issue closed — COUNT is not the disarm
# signal. While armed, a product-repo tick must still claim at least one
# issue, or log why it cannot. The worker-side route is the reserved
# litellm `judge` group (PI_REPAIR_RUNG=1 in pi-issue-run), which falls back
# to senior inside the proxy — never a lane outside the sanctioned config
# (money stays Nish's, fleet-ops#3284).
PI_INTAKE_REPAIR_RUNG_AFTER="${PI_INTAKE_REPAIR_RUNG_AFTER:-2}"
PI_INTAKE_REPAIR_RUNG_MAX_CONCURRENT="${PI_INTAKE_REPAIR_RUNG_MAX_CONCURRENT:-2}"
# fleet-ops#4820: the rung stands down only after this many CONSECUTIVE
# ticks with a usable seat (mirrors the arm rule so a single recovered tick
# cannot flap the rung off and back on).
PI_INTAKE_REPAIR_RUNG_DISARM_AFTER="${PI_INTAKE_REPAIR_RUNG_DISARM_AFTER:-2}"
repair_rung_state_file() {
    printf '%s' "${PI_INTAKE_REPAIR_RUNG_STATE:-/home/nish/workspaces/agent-state/pi-intake/repair-rung-state}"
}

# State file holds two space-separated integers: <strikes> <disarm_count>.
# strikes = consecutive low-slot/outage ticks (arms the rung at AFTER).
# disarm_count = consecutive ticks while armed where headroom returned a
# usable level (disarms at DISARM_AFTER). One line, two integers, so an
# old single-number state file still reads as strikes=N disarm=0.
repair_rung_read() {
    local f _s=0 _d=0
    f=$(repair_rung_state_file)
    if [[ -f "$f" ]]; then
        read -r _s _d <"$f" 2>/dev/null || true
    fi
    _s=$(printf '%s' "$_s" | tr -cd '0-9')
    _d=$(printf '%s' "$_d" | tr -cd '0-9')
    [[ "$_s" =~ ^[0-9]+$ ]] || _s=0
    [[ "$_d" =~ ^[0-9]+$ ]] || _d=0
    printf '%s %s' "$_s" "$_d"
}

repair_rung_strikes() {
    local _s _d
    read -r _s _d < <(repair_rung_read)
    printf '%s' "$_s"
}

repair_rung_write() {
    local f
    f=$(repair_rung_state_file)
    mkdir -p "$(dirname "$f")" 2>/dev/null || true
    printf '%s %s' "$1" "$2" >"$f" 2>/dev/null || true
}

# Count one low-slot/outage tick and return the consecutive strike count.
# A low-slot tick also resets the disarm counter (recovery is not
# consecutive across an outage).
repair_rung_note_outage() {
    local _s _d
    read -r _s _d < <(repair_rung_read)
    _s=$(( _s + 1 ))
    repair_rung_write "$_s" 0
    printf '%s' "$_s"
}

# Count one usable-slot tick while the rung is armed and return the
# consecutive recovery count. Only meaningful when armed; a non-armed tick
# never calls this.
repair_rung_note_recovery() {
    local _s _d
    read -r _s _d < <(repair_rung_read)
    _d=$(( _d + 1 ))
    repair_rung_write "$_s" "$_d"
    printf '%s' "$_d"
}

repair_rung_reset() {
    repair_rung_write 0 0
    return 0
}

# Live rung workers: pi-issue@ fleet-ops units whose packet carries the
# seat-rung marker. Counting liveness (not a hand-maintained list) means a
# finished or failed unit stops counting and the 2-concurrent cap
# self-heals — no second state file to leak. SYSTEMCTL is the tick's test
# seam, so the drill can stub it.
repair_rung_concurrent() {
    local _live=0 _pkt _st
    [[ -d "${ISSUE_STATE_DIR:-}" ]] || { printf '0'; return; }
    for _pkt in "$ISSUE_STATE_DIR"/fleet-ops-*.in; do
        [[ -f "$_pkt" ]] || continue
        grep -q '^seat-rung:[[:space:]]*repair[[:space:]]*$' "$_pkt" 2>/dev/null || continue
        _st=$($SYSTEMCTL --user is-active "pi-issue@$(basename "$_pkt" .in).service" 2>/dev/null || true)
        if [[ "$_st" == "active" || "$_st" == "activating" ]]; then
            _live=$(( _live + 1 ))
        fi
    done
    printf '%s' "$_live"
}

# Seat gate (auditor 2026-08-26T18:1xZ, summon fleet-ops-378 unit-failure):
# capacity slots are NOT proof a worker can run. With every allowlisted
# heavy-capable seat benched/quota-exhausted, a claimed issue used to spawn
# a pi-issue@ unit that died instantly on NO USABLE SEAT and auto-restarted
# until StartLimitBurst, then OnFailure reaped the claim back to
# agent-ready, then the NEXT tick re-claimed it — a spawn churn that burned
# 37 units activating and summoned the auditor.
# fleet-ops#4263 P3b: proxy health is the usable-seat gate. A dead proxy
# means workers cannot run, so hold claims this tick. Fail-open when
# litellm_ready is unavailable (tests stub the helper).
if declare -F litellm_ready >/dev/null 2>&1; then
    if ! litellm_ready; then
        echo "no usable LiteLLM proxy (slots=$slots); holding claims this tick — gate: litellm_ready"
        exit 0
    fi
else
    echo "litellm_ready unavailable; seat-slot gate fails open, keeping slots=$slots (fleet-ops#4263)"
fi

# P3b: proxy health is the only usable-seat gate. A healthy proxy means all
# LiteLLM groups are reachable (fallbacks, cooldown, budgets). Keep the
# _light_only_claims latch for the per-issue filter below; a dead proxy already
# exited above, so claims are not light-only when we reach here.
_light_only_claims=0
_repair_rung_armed=0
_repair_rung_product_reserve=0
_product_skip_reason=""
_repo_is_product=0
if declare -F repo_is_product >/dev/null 2>&1 && repo_is_product "$REPO"; then
    _repo_is_product=1
fi
# Route probes for rung messages: while the proxy is healthy every group
# route exists; the names below identify which lane cleared the rung.
heavy_route=$(litellm_seat "worker-capable" 2>/dev/null || true)
light_route=$(litellm_seat "worker-cheap" 2>/dev/null || true)

# Usable seat-slot gate (fleet-ops#3732 / #4263): the claim bound above is a
# worker count. Headroom comes from litellm_headroom (proxy health gate +
# caps minus live units); a non-numeric reply fails OPEN so a broken counter
# never freezes intake.
usable_light_slots=""
if declare -F litellm_headroom >/dev/null 2>&1; then
    usable_light_slots=$(litellm_headroom 2>/dev/null || echo "")
fi
if [[ ! "$usable_light_slots" =~ ^[0-9]+$ ]]; then
    echo "usable seat-slot count unavailable (litellm_headroom returned '${usable_light_slots:0:60}'); seat-slot gate fails open, keeping slots=$slots (fleet-ops#3732)"
    usable_light_slots=$slots
fi
# fleet-ops#4820: usable headroom (>= 2) is recovery. COUNT staying 0 while
# a route still existed was the live latch — the count alone disarms now.
_rung_has_seat=0
if (( usable_light_slots >= 2 )); then
    _rung_has_seat=1
fi
if (( _rung_has_seat == 1 )); then
    _rung_strikes=$(repair_rung_strikes)
    if (( _rung_strikes >= PI_INTAKE_REPAIR_RUNG_AFTER )); then
        _rung_disarm=$(repair_rung_note_recovery)
        if (( _rung_disarm >= PI_INTAKE_REPAIR_RUNG_DISARM_AFTER )); then
            repair_rung_reset
            echo "REPAIR-RUNG disarmed: route ${light_route:-unknown} usable for ${_rung_disarm} consecutive ticks (fleet-ops#4820)"
            _repair_rung_armed=0
        else
            echo "REPAIR-RUNG recovery ${_rung_disarm}/${PI_INTAKE_REPAIR_RUNG_DISARM_AFTER}: route ${light_route:-slots $usable_light_slots} usable, standing down after ${PI_INTAKE_REPAIR_RUNG_DISARM_AFTER} consecutive ticks (fleet-ops#4820)"
            if [[ "$REPO" == "fleet-ops" ]]; then
                _repair_rung_armed=1
            elif (( ${_repo_is_product:-0} == 1 )); then
                _repair_rung_product_reserve=1
            fi
        fi
    else
        _rung_prev=$_rung_strikes
        repair_rung_reset
        if (( _rung_prev > 0 )); then
            echo "REPAIR-RUNG released: route ${light_route:-slots $usable_light_slots} usable (was ${_rung_prev} consecutive low-slot ticks, fleet-ops#4639)"
        fi
    fi
else
    # Judge spec (fleet-ops#4639): usable slots < 2 for >= 2 consecutive
    # ticks opens the rung. A non-fleet-ops, non-product tick never arms it
    # (rung admits critical-path fleet-ops only). A product tick while the
    # rung is armed globally must not hold — reserve one claim, or log why
    # none is possible (fleet-ops#4820).
    _rung_strikes=$(repair_rung_note_outage)
    if (( _rung_strikes >= PI_INTAKE_REPAIR_RUNG_AFTER )); then
        if [[ "$REPO" == "fleet-ops" ]]; then
            _repair_rung_armed=1
            echo "REPAIR-RUNG armed: ${_rung_strikes} consecutive ticks with usable slots ${usable_light_slots} < 2 — claiming critical-path fleet-ops issues only, cap ${PI_INTAKE_REPAIR_RUNG_MAX_CONCURRENT} concurrent rung workers (fleet-ops#4639)"
        elif (( ${_repo_is_product:-0} == 1 )); then
            echo "REPAIR-RUNG armed globally (${_rung_strikes} ticks) — product-reserve on $REPO (fleet-ops#4820)"
            _repair_rung_product_reserve=1
            _product_skip_reason="no usable capacity"
        else
            echo "REPAIR-RUNG strike ${_rung_strikes} but repo $REPO is not fleet-ops; holding claims this tick — gate: repair-rung is fleet-ops-only (fleet-ops#4639)"
            exit 0
        fi
    elif (( usable_light_slots <= 0 )) && [[ -z "$heavy_route" ]]; then
        echo "no usable seat (heavy and light pools empty); holding claims this tick — gate: no usable seat slot (repair-rung strike ${_rung_strikes}/${PI_INTAKE_REPAIR_RUNG_AFTER}, fleet-ops#4639)"
        exit 0
    fi
fi
# The rung claims do NOT come out of the light-slot pool (a critical-path
# repair issue is usually heavy), so the light-slot clamp below is bypassed
# while the rung is armed; the rung's own 2-concurrent cap applies instead.
# fleet-ops#4820: a product-reserve tick with usable headroom gets one slot
# even when COUNT is 0, so product intake is never zeroed by the latch.
if (( _repair_rung_armed == 1 )); then
    slots=$PI_INTAKE_REPAIR_RUNG_MAX_CONCURRENT
elif (( ${_repair_rung_product_reserve:-0} == 1 )) && [[ -n "${light_route:-}" || -n "$heavy_route" ]]; then
    if (( slots < 1 )); then
        slots=1
    fi
    echo "REPAIR-RUNG product-reserve: granting 1 claim slot on $REPO (fleet-ops#4820)"
elif (( usable_light_slots <= 0 )) && [[ -n "$heavy_route" || -n "${light_route:-}" ]]; then
    slots=1
elif (( usable_light_slots < slots )); then
    echo "usable seat slots $usable_light_slots < capacity slots $slots; claiming at most $usable_light_slots this tick (fleet-ops#3732)"
    slots=$usable_light_slots
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

# Step 3: process issues critical-path first, then ascending number order
# (0509#1691, fleet-ops#3710). A plain ascending order let a late, deploy-blocking
# critical-path issue (0509#1691) sit "skipped-capacity" behind 18 older
# ready issues for four ticks. Same rule as lib/intake-priority.sh rule 2
# (critical before the tail; lowest number first inside a tier). ONE
# expression builds all three arrays so numbers/titles/labels stay aligned.
# shellcheck disable=SC2016  # jq program: $cp is a jq --arg, not shell
_claim_order='sort_by([(if (((.labels // []) | map(if type == "object" then (.name // empty) else . end) | index($cp)) != null) then 0 else 1 end), .number])'
mapfile -t numbers < <(jq -r --arg cp "$CRITICAL_PATH_LABEL" "$_claim_order | .[].number" <<<"$issues_json")
mapfile -t titles  < <(jq -r --arg cp "$CRITICAL_PATH_LABEL" "$_claim_order | .[].title"  <<<"$issues_json")
mapfile -t labels  < <(jq -c --arg cp "$CRITICAL_PATH_LABEL" "$_claim_order | .[].labels" <<<"$issues_json")

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

# fleet-ops#3254: self-maintenance (fleet-ops) claim budget. Product repos
# (0509) are never capped. For a fleet-ops tick, cap the number of
# self-maintenance claims at SELF_MAINT_CLAIM_PCT of this tick's available
# slots (floor 1), so a giant fleet-ops agent-ready backlog cannot flood the
# fleet while product work waits. A critical-path / escalate-senior issue is
# exempt from the cap and claims even past the budget. Computed once from the
# tick-start slots count (slots already includes the per-claim decrement
# below, so capture the base once here).
# Repair-rung knobs (PI_INTAKE_REPAIR_RUNG_AFTER / MAX_CONCURRENT) are
# defined with the seat-gate helpers above so they exist before first use.
_self_maint_cap=0
_self_maint_claims=0
if product_first_is_self_maintenance "$REPO" || [[ "$REPO" == "fleet-ops" ]]; then
    _self_maint_cap=$(( slots * SELF_MAINT_CLAIM_PCT / 100 ))
    (( _self_maint_cap < 1 )) && _self_maint_cap=1
fi

# fleet-ops#4808: depends-on resolution caches, shared across every issue
# in this tick so a dependency named by many issues costs one gh call.
# _dep_state_cache: owner/repo#num -> DONE|NOT_DONE
# _dep_body_cache:  owner/repo#num -> body (for cycle detection)
declare -A _dep_state_cache=()
declare -A _dep_body_cache=()

# fleet-ops#4801: spec-judge batch detection + gate. Among agent-ready
# issues, group those whose `files:` lines share a path (exact or same
# directory). A group of >= 2 without a `spec-judged: <sha>` marker is a
# batch needing judging. For such a batch, do NOT claim any member; launch
# ONE judge run via pi-systemd-run (cursor/kimi-k3-max, judge-only). At
# most one judge in flight per repo, never more than 3/hour fleet-wide.
# Members of a batch being judged are skipped in the claim loop below via
# the in-flight marker (spec_judge_skip_member).
if [[ -f "$SPEC_JUDGE_LIB" && -f "$SPEC_JUDGE_PROMPT" ]]; then
    _sj_issues=$(spec_judge_fetch_bodies "$FULL")
    if [[ -n "$_sj_issues" && "$_sj_issues" != "[]" ]]; then
        _sj_batches=$(spec_judge_group_batches "$_sj_issues")
        if [[ -n "$_sj_batches" && "$_sj_batches" != "[]" ]]; then
            printf '%s' "$_sj_batches" | jq -c '.[]' | while IFS= read -r _sj_batch; do
                _sj_count=$(printf '%s' "$_sj_batch" | jq '.numbers | length' 2>/dev/null || echo 0)
                (( _sj_count < 2 )) && continue
                _sj_nums=$(printf '%s' "$_sj_batch" | jq -c '.numbers')
                # Compute the batch sha over the member bodies.
                _sj_bodies=$(printf '%s' "$_sj_batch" | jq -r '.numbers[]' | while IFS= read -r _sj_n; do
                    printf '%s\n' "$_sj_issues" | jq -r --arg n "$_sj_n" '.[] | select(.number == ($n|tonumber)) | .body'
                done)
                _sj_sha=$(spec_judge_batch_sha "$_sj_bodies")
                _sj_newest=$(printf '%s' "$_sj_batch" | jq -r '.numbers | max' 2>/dev/null || echo "")
                # Marker present and matching -> already judged, no re-judge.
                if [[ -n "$_sj_newest" ]] && spec_judge_has_marker "$FULL" "$_sj_newest" "$_sj_sha"; then
                    continue
                fi
                # A judge already in flight for this repo -> members stay skipped.
                if spec_judge_inflight "$REPO"; then
                    echo "spec-judge: batch ${_sj_nums} skipped (judge in flight for $REPO)"
                    continue
                fi
                # Fleet-wide hourly rate cap.
                if ! spec_judge_rate_ok; then
                    echo "spec-judge: batch ${_sj_nums} skipped (fleet-wide rate cap reached)"
                    continue
                fi
                # Launch the judge.
                if spec_judge_launch "$REPO" "$FULL" "$_sj_batch" "$_sj_sha" "$SPEC_JUDGE_PROMPT"; then
                    echo "spec-judge: launched judge for batch ${_sj_nums} (sha=$_sj_sha)"
                else
                    echo "spec-judge: launch failed for batch ${_sj_nums}" >&2
                fi
            done
        fi
    fi
fi

for i in "${!numbers[@]}"; do
    N="${numbers[$i]}"
    title="${titles[$i]}"

    if (( slots <= 0 )); then
        echo "issue $N ($title): skipped-capacity"
        continue
    fi

    # fleet-ops#3254: self-maintenance (fleet-ops) claim cap. Once this tick
    # has spent its SELF_MAINT_CLAIM_PCT budget on non-exempt fleet-ops
    # claims, stop admitting more ordinary control-plane issues so capacity
    # stays for product. A critical-path label marks the issue exempt (it
    # claims even past the cap); escalate-senior issues were already dropped
    # from the ready set above. Checked here (on the cheap labels array)
    # before the body fetch so a capped-out tick does no per-issue network.
    if (( _self_maint_cap > 0 && _self_maint_claims >= _self_maint_cap )); then
        if printf '%s' "${labels[$i]}" | jq -e --arg cp "$CRITICAL_PATH_LABEL" \
            '[.[]?.name // empty] | index($cp) != null' >/dev/null 2>&1; then
            : # exempt — claim even past the cap
        else
            echo "issue $N ($title): skipped-self-maintenance-cap (claimed $_self_maint_claims >= cap $_self_maint_cap)"
            continue
        fi
    fi

    # fleet-ops#4639: repair-rung claim filter. While the rung is armed only
    # critical-path fleet-ops issues are claimable (the whole point: let the
    # seat-repair issues through when every seat is dead). Cheap label check
    # before the body fetch so a skipped issue costs zero network; the rung's
    # concurrency cap is checked on the same cheap pass.
    if [[ "$_repair_rung_armed" == "1" ]]; then
        if printf '%s' "${labels[$i]:-}" | jq -e --arg cp "$CRITICAL_PATH_LABEL" \
            '[.[]?.name // empty] | index($cp) != null' >/dev/null 2>&1; then
            _rung_live=$(repair_rung_concurrent)
            if (( _rung_live >= PI_INTAKE_REPAIR_RUNG_MAX_CONCURRENT )); then
                echo "issue $N ($title): skipped-repair-rung-cap ($_rung_live live rung workers >= cap $PI_INTAKE_REPAIR_RUNG_MAX_CONCURRENT, fleet-ops#4639)"
                continue
            fi
        else
            echo "issue $N ($title): skipped-repair-rung (rung claims critical-path fleet-ops only, fleet-ops#4639)"
            continue
        fi
    fi

    # fleet-ops#4540: parked issues are never re-claimed. A protected issue
    # with a merged delivery PR and a future-date-gate `termination:` clause
    # carries the awaiting-runtime-gate label (applied by this tick's park
    # detector below, or by bin/fleet-merged-pr-close when it posts the
    # protected observe-to-close note). The label check is cheap (labels
    # from the initial issue list, no network) and precedes the body fetch
    # so a parked issue costs zero per-issue network calls.
    if printf '%s' "${labels[$i]:-}" | jq -e 'map(.name // empty) | index("awaiting-runtime-gate") != null' >/dev/null 2>&1; then
        echo "issue $N ($title): skipped-awaiting-runtime-gate (parked: merged delivery PR + future runtime gate, fleet-ops#4540)"
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
        # fleet-ops#4639: the rung is exempt from the surge-leverage skip —
        # a critical-path repair issue must claim even mid-surge.
        if [[ "$_repair_rung_armed" == "1" ]]; then
            :
        elif ! precedence_band_is_leverage_issue "$N" 2>/dev/null; then
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
        _cd_ts=$(head -n 1 "$_cooldown_file" 2>/dev/null || true)
        _cd_epoch=$(date -u -d "$_cd_ts" +%s 2>/dev/null) || _cd_epoch=0
        _now_epoch=$(date -u +%s)
        _cd_age=$(( _now_epoch - _cd_epoch ))
        # fleet-ops#5743: bench-aware requeue. pi-issue-failed-reap may append
        # an absolute `until: <UTC>` line when the last failure was a
        # classified transient-overload (503) seat bench that outlives
        # RECLAIM_COOLDOWN_S: the issue stays unclaimable until the bench
        # itself expires, so the next worker does not re-hit the same dead
        # seat — no hand-added READY-WORK `after:` row required.
        _cd_until_ts=$(sed -n 's/^until: //p' "$_cooldown_file" 2>/dev/null | head -n 1)
        _cd_until_epoch=0
        if [[ -n "$_cd_until_ts" ]]; then
            _cd_until_epoch=$(date -u -d "$_cd_until_ts" +%s 2>/dev/null) || _cd_until_epoch=0
        fi
        if (( _cd_epoch > 0 && _cd_age < RECLAIM_COOLDOWN_S )); then
            echo "issue $N ($title): skipped-reclaim-cooldown (age=${_cd_age}s < ${RECLAIM_COOLDOWN_S}s)"
            continue
        fi
        if (( _cd_until_epoch > _now_epoch )); then
            echo "issue $N ($title): skipped-reclaim-cooldown-bench (until=$_cd_until_ts, $(( _cd_until_epoch - _now_epoch ))s left)"
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
        # fleet-ops#3310: the WORK cap (real work failures) does not block on
        # first hit — it forces the next claim onto a DIFFERENT seat CLASS via
        # a per-issue .prefer-class ladder (prepaid -> metered -> senior),
        # resetting reclaim-count to 1 so the new class gets a fresh budget.
        # Only when every class has been tried (ladder exhausted) does intake
        # block — and then with a machine-readable blocked-on: infra
        # (the senior conference is the orchestrator's job, and a conference
        # that never runs must not be the only unblocking path; blocked-reconcile
        # auto-releases an infra block after 2h when a healthy capable seat
        # exists, and escalates to blocked-on: senior-review on a second release
        # within 24h). Infra deaths
        # never reach this cap at all (pi-issue-run / -failed-reap split them
        # onto .infra-death), so a provider storm can no longer park the issue.
        _pref_file="$ATTEMPTS_DIR/pi-issue-${REPO}-${N}.prefer-class"
        _cur_pref=""
        if [[ -f "$_pref_file" ]]; then
            _cur_pref=$(cat "$_pref_file" 2>/dev/null || true)
        fi
        _next_pref="prepaid"
        case "$_cur_pref" in
            "")        _next_pref="prepaid" ;;
            prepaid)   _next_pref="metered" ;;
            metered)   _next_pref="senior" ;;
            senior)    _next_pref="block" ;;
        esac
        if [[ "$_next_pref" != "block" ]]; then
            printf '%s' "$_next_pref" > "$_pref_file" 2>/dev/null || true
            # Fresh class budget: the new class starts at 1, not at the cap.
            printf '1' > "$_reclaim_count_file" 2>/dev/null || true
            echo "issue $N ($title): skipped-max-reclaims (work-cap=$_rc_current) - advancing seat class to $_next_pref (fresh claim budget)" >&2
            continue
        fi
        echo "issue $N ($title): skipped-max-reclaims (count=$_rc_current) - every seat class (prepaid/metered/senior) exhausted, escalating to agent-blocked" >&2
        gh issue edit "$N" -R "$FULL" --add-label agent-blocked --remove-label agent-ready 2>/dev/null || true
        gh issue comment "$N" -R "$FULL" --body "fleet-ops#3310: issue $N has been re-claimed $_rc_current times (work-cap=$MAX_RECLAIMS) across every seat class (prepaid/metered/senior). Real work failures have exhausted the seat pool; re-queuing is the orchestrator's decision, not a senior conference that never runs.

blocked-on: infra" 2>/dev/null || true
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
        _claim_prs=$(_gh_read api "repos/$FULL/pulls?state=open&head=${FULL%%/*}:claim/issue-$N&per_page=1" 2>/dev/null || true)
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
            # fleet-ops#4848: the orchestrator sweep may have ALREADY decided this
            # issue (posted a `decision-resolved:` line and released it
            # agent-ready). Re-parking a decided issue to needs-orchestrator
            # re-asks a settled question and loops the sweep against the
            # claim-loop (FleetNeedsOrchestratorStale). When a live
            # `decision-resolved:` marker exists, keep agent-blocked but do
            # NOT add needs-orchestrator; post blocked-on: infra so the
            # seat-fault escalator (blocked-reconcile, auto-release after 2h
            # on a healthy seat, senior-review on second release) owns it —
            # matching the alert's "escalate the seat fault, do not re-park"
            # guidance. The comment fetch is only done when the gate is about
            # to fire, so an ordinary issue costs nothing extra.
            _cl_decided=0
            _cl_cjson=$(gh issue view "$N" -R "$FULL" --json comments 2>/dev/null) || _cl_cjson=""
            # The sweep posts `decision-resolved:` either on its own line at
            # the end of the DECISION comment (canonical, per the sweep
            # prompt) or inline at the end of the same line (observed
            # 2026-09-10). Match a `decision-resolved:` token anywhere in
            # the joined comments — the only source of that token in
            # practice is the sweep's own DECISION verdict.
            if [[ -n "$_cl_cjson" ]] && printf '%s' "$_cl_cjson" | jq -r '[.comments[]?.body // empty] | join("\n")' 2>/dev/null | grep -q 'decision-resolved:'; then
                _cl_decided=1
            fi
            if (( _cl_decided == 1 )); then
                echo "issue $N ($title): skipped-claim-loop (claimed ${_cl_window_claims}x in ${RECLAIM_WINDOW_S}s window, cap=$MAX_CLAIMS_IN_WINDOW) - already decided (decision-resolved:), escalating seat fault, not re-parking to orchestrator" >&2
                gh issue edit "$N" -R "$FULL" --add-label agent-blocked --remove-label agent-ready 2>/dev/null || true
                gh issue comment "$N" -R "$FULL" --body "fleet-ops#4848: issue $N has been claimed ${_cl_window_claims} times in the last ${RECLAIM_WINDOW_S}s (cap=$MAX_CLAIMS_IN_WINDOW) with no open PR, but the orchestrator sweep already posted a \`decision-resolved:\` verdict — the decision is settled, so re-parking to needs-orchestrator would only re-ask it. Keeping agent-blocked and escalating the seat fault instead (fleet-ops#3310/#3527): the claim path is spinning dead workers into the seat pool. The seat-fault escalator owns this until a healthy seat can run it.

blocked-on: infra" 2>/dev/null || true
                continue
            fi
            echo "issue $N ($title): skipped-claim-loop (claimed ${_cl_window_claims}x in ${RECLAIM_WINDOW_S}s window, cap=$MAX_CLAIMS_IN_WINDOW) - escalating to agent-blocked" >&2
            gh issue edit "$N" -R "$FULL" --add-label agent-blocked --add-label needs-orchestrator --remove-label agent-ready 2>/dev/null || true
            gh issue comment "$N" -R "$FULL" --body "fleet-ops#2772: issue $N has been claimed ${_cl_window_claims} times in the last ${RECLAIM_WINDOW_S}s (cap=$MAX_CLAIMS_IN_WINDOW) with no open PR — the claim path is spinning dead workers into the seat pool instead of completing. Routing to the orchestrator decision sweep (fleet-ops#4260), not Nish: a claim-loop break is not a money/legal/product-direction/customer-data question.

blocked-on: orchestrator" 2>/dev/null || true
            continue
        fi
    fi

    # One body fetch serves the blocker filter (blocked-on: in body/comments).
    # The rent-paying band (band-multiplier) now uses labels (priority/emergency)
    # from the initial issue list. A failed view is fail-closed: skip
    # this issue this tick rather than claim a possibly-blocked or
    # out-of-band issue. The next tick retries.
    _body_json=$(_gh_read issue view "$N" -R "$FULL" --json body,author 2>/dev/null) || {
        echo "issue $N ($title): skipped-body-unreadable"
        continue
    }
    body=$(printf '%s' "$_body_json" | jq -r '.body // ""')
    _issue_author=$(printf '%s' "$_body_json" | jq -r '.author.login // ""')

    # fleet-ops#4540/#4553/#5048: park detector — high-claim slow-spaced
    # reclaim spin. Cumulative (all-time) claim count from the claims-log
    # snapshot; past PARK_MAX_CLAIMS, an issue whose remaining work is already
    # delivered is parked under the awaiting-runtime-gate label:
    #   - #4540: protected + termination: + merged claim-branch delivery PR
    #   - #4553/#5835: non-protected + termination: + gh pr <verb>
    #     (view|checks|list|merge) + no merged claim-branch
    #   - #5048: protected + no termination: + no merged claim-branch + either
    #     an active user .timer/.service or merged PR(s) on a non-claim branch.
    # The gh pr list probe runs only when the cheap preconditions
    # (claim volume + protection) hold, so an ordinary issue costs nothing extra.
    _park_claims=0
    if [[ -n "$_claims_log_snapshot" ]]; then
        _park_claims=$(awk -v n="$N" -v repo="$REPO" '$3 == "line=" n && $4 == "repo=" repo { c++ } END { print c+0 }' <<<"$_claims_log_snapshot" 2>/dev/null || echo 0)
    fi
    if (( _park_claims > PARK_MAX_CLAIMS )); then
        _park_protected=0
        # fleet-ops#5082: _park_merged is bound per-issue so the duplicate
        # branch below can reuse the head-branch probe when the #4540 or
        # #4553 branch already ran it, or fill it lazily when they did not.
        _park_merged=""
        if printf '%s' "${labels[$i]:-}" | jq -e '[.[]?.name // empty] | index("critical-path") != null' >/dev/null 2>&1; then
            _park_protected=1
        fi
        [[ "$_issue_author" == "nish3451" ]] && _park_protected=1

        # Probe for a merged claim-branch PR once, reused by all three park
        # branches. The body rides along: the #5045 mention classification
        # (the #3231/#1138 relates_to_issue Relates-to trailer) needs it.
        _park_merged=$(_gh_read pr list -R "$FULL" --head "claim/issue-$N" --state merged --json number,url,mergedAt,body 2>/dev/null || echo "[]")
        _park_merged_count=0
        if printf '%s' "$_park_merged" | jq -e 'length > 0' >/dev/null 2>&1; then
            _park_merged_count=$(printf '%s' "$_park_merged" | jq 'length' 2>/dev/null || echo 0)
        fi

        if (( _park_protected == 1 )) && printf '%s' "$body" | grep -qi 'termination:' \
            && (( _park_merged_count > 0 )); then
            # fleet-ops#4540: protected issue with a termination clause and a
            # merged claim-branch delivery PR. The merged-claim-PR condition
            # moved into the branch guard (#5689): when NO claim-branch PR is
            # merged, the #5048 delivered-scan below must still run — the live
            # case was #4625 (protected + termination: naming a retired
            # provider, delivered via merged non-claim PR #5081, claim branch
            # closed conflicting, ~15 re-claims since 2026-09-10).
            _park_pr=$(printf '%s' "$_park_merged" | jq -r '.[0].number')
            echo "issue $N ($title): skipped-parked-protected-merged ($_park_claims cumulative claims > cap $PARK_MAX_CLAIMS; merged PR #$_park_pr delivered it; awaiting runtime gate)" >&2
            # fleet-ops#4540: gh issue edit --add-label does NOT auto-create a
            # missing label (it fails \"<name> not found\"), so ensure the park
            # label exists first (idempotent --force). Without this the add
            # fails silently and the slow-spaced reclaim spin is NOT stopped.
            gh label create awaiting-runtime-gate -R "$FULL" --color D4C5F9 \
                --description "Parked: protected issue + merged delivery PR awaiting a future runtime gate; do not claim (fleet-ops#4540)" --force >/dev/null 2>&1 || true
            gh issue edit "$N" -R "$FULL" --add-label awaiting-runtime-gate --remove-label agent-ready 2>/dev/null || true
            gh issue comment "$N" -R "$FULL" --body "fleet-ops#4540: issue $N is protected (owner-authored or critical-path) with a merged delivery PR (claim/issue-$N, PR #$_park_pr) and a \`termination:\` clause naming a future runtime event. observe-to-close stays comment-only on protected issues (fleet-ops#1435), so the issue stays OPEN by design — but it has been re-claimed ${_park_claims} times since the merge on a slow spin every anti-loop gate misses (#2462 counter resets on non-empty output; #2772 window sees only ~3 claims per 2h at the 15-min cooldown spacing). Parking it: labelled \`awaiting-runtime-gate\`, removed from agent-ready; the intake will not re-claim it until the named runtime event fires (clear the label then) or Nish closes the issue. No new timer." 2>/dev/null || true
            continue
        elif (( _park_protected == 0 )); then
            # fleet-ops#4553 + #5835 + fleet-ops#5045: the two NON-protected park
            # shapes share the hoisted merged claim-branch PR probe (body
            # included — the #5045 mention classification needs the trailer).
            if (( _park_merged_count == 0 )) \
                && printf '%s' "$body" | grep -qi 'termination:' \
                && printf '%s' "$body" | grep -Eiq 'gh pr (view|checks|list|merge)'; then
                # fleet-ops#4553 + #5835: land-or-close spin. A NON-protected
                # (bot-authored, no critical-path) OPEN issue whose
                # \`termination:\` clause NAMES OTHER PRs via any
                # \`gh pr <verb>\` probe (\`view\`, \`checks\`, \`list\`,
                # \`merge\`) — the land-or-close shape. Live miss (#5835):
                # #5761's termination is \`gh pr checks 5744 -R
                # Nishfleet/fleet-ops\`, which the original \`gh pr view\`-only
                # grep never matched, so the park never fired past
                # PARK_MAX_CLAIMS. Acceptance is met by driving other
                # PRs to merge (#1992, #4070), the worker cannot
                # \`gh issue close\` (land-or-close issues are closed by Nish),
                # and there is NO claim-branch delivery PR, so the #4540
                # detector (which requires protection + a merged claim-branch
                # PR) and the reset (#2462) / window (#2772) gates all miss the
                # same slow-spaced spin. Park when no merged claim-branch PR.
                echo "issue $N ($title): skipped-parked-land-or-close ($_park_claims cumulative claims > cap $PARK_MAX_CLAIMS; termination: names other PRs; no claim-branch delivery PR; awaiting Nish to close)" >&2
                gh label create awaiting-runtime-gate -R "$FULL" --color D4C5F9 \
                    --description "Parked: land-or-close issue whose termination: met by other PRs; do not claim (fleet-ops#4553)" --force >/dev/null 2>&1 || true
                gh issue edit "$N" -R "$FULL" --add-label awaiting-runtime-gate --remove-label agent-ready 2>/dev/null || true
                gh issue comment "$N" -R "$FULL" --body "fleet-ops#4553 + #5835: issue $N is a land-or-close ticket — its \`termination:\` clause names OTHER PRs via a \`gh pr\` probe (\`view\`, \`checks\`, \`list\`, or \`merge\`) and it has no merged claim-branch delivery PR, so acceptance is met without opening its own PR. Land-or-close issues stay OPEN by design (the worker cannot \`gh issue close\`), and the reset (#2462) and window (#2772) gates miss the slow-spaced spin, so this issue has been re-claimed ${_park_claims} times since its PRs landed. Parking it: labelled \`awaiting-runtime-gate\`, removed from agent-ready; the intake will not re-claim it until Nish closes the issue or the label is cleared." 2>/dev/null || true
                continue
            elif printf '%s' "$_park_merged" | jq -e 'length > 0' >/dev/null 2>&1; then
                # fleet-ops#5045: mention-strand spin — the middle shape both
                # parks missed. A NON-protected OPEN issue whose merged
                # claim-branch PRs are ALL mention-classified (\`Relates to
                # #N\` trailer — the same relates_to_issue classification
                # fleet-merged-pr-close applies, fleet-ops#3231/#1138) is
                # delivered-but-stranded: observe-to-close posts comment-only
                # and never closes (a mention is not a fix), the #4540 park
                # needs protected, and the #4553 park needs NO merged
                # claim-branch PR, so every gate misses the re-claim spin
                # (live: #4980 re-claimed 4x in ~3h after PR #4993 merged with
                # a Relates-to trailer; 2 of those died in StartLimitBurst
                # crash loops). Park when every merged claim-branch PR is a
                # mention; a real delivery PR (no Relates-to trailer) means
                # observe-to-close owns the close and this issue is not the
                # strand shape.
                _park_all_mention=1
                _park_pr=""
                while IFS=$'\t' read -r _pn _pb64; do
                    [ -z "$_pn" ] && continue
                    [ -z "$_park_pr" ] && _park_pr="$_pn"
                    # The body travels base64 so its real newlines survive —
                    # relates_to_issue needs the `Relates` trailer preceded by
                    # a line break (a @tsv-escaped \n would leave `n` before
                    # it and the (non-alnum) bound would never match).
                    _pb=$(printf '%s' "$_pb64" | base64 -d 2>/dev/null || printf '')
                    if ! printf '%s' "$_pb" | grep -Eiq "(^|[^0-9A-Za-z])Relat(es|ed)[[:space:]]+to[[:space:]]+#${N}([^0-9A-Za-z]|$)"; then
                        _park_all_mention=0
                        break
                    fi
                done < <(printf '%s' "$_park_merged" | jq -r '.[] | [.number, ((.body // "") | @base64)] | @tsv' 2>/dev/null)
                if (( _park_all_mention == 1 )); then
                    echo "issue $N ($title): skipped-parked-mention-strand ($_park_claims cumulative claims > cap $PARK_MAX_CLAIMS; merged claim-branch PR #$_park_pr is mention-classified (Relates-to), not a delivery; awaiting Nish to close)" >&2
                    gh label create awaiting-runtime-gate -R "$FULL" --color D4C5F9 \
                        --description "Parked: non-protected issue whose merged claim-branch PR is a Relates-to mention, not a delivery; do not claim (fleet-ops#5045)" --force >/dev/null 2>&1 || true
                    gh issue edit "$N" -R "$FULL" --add-label awaiting-runtime-gate --remove-label agent-ready 2>/dev/null || true
                    gh issue comment "$N" -R "$FULL" --body "fleet-ops#5045: issue $N is non-protected with a merged claim-branch PR (claim/issue-$N, PR #$_park_pr) that carries a \`Relates to\` trailer — a MENTION under the fleet-ops#3231 delivery rules, so observe-to-close posts comment-only and never closes. The delivery already landed, but every anti-loop gate misses this middle shape (#4540 needs protected; #4553 needs no merged claim-branch PR), so the issue has been re-claimed ${_park_claims} times since the merge. Parking it: labelled \`awaiting-runtime-gate\`, removed from agent-ready; the intake will not re-claim it. Nish closes the issue (delivery landed) or clears the label to release it." 2>/dev/null || true
                    continue
                fi
            fi
        elif (( _park_protected == 1 )) && (( _park_merged_count == 0 )); then
            # fleet-ops#5048: protected issue with NO merged claim-branch
            # delivery PR. If the remaining work was already delivered by
            # merged PR(s) on a non-claim branch, or is delegated to an active
            # user .timer/.service, the slow-spaced reclaim spin is the same
            # as #4540 — park it. A termination: clause is NOT an exemption
            # (fleet-ops#5689): a clause naming a gate that can never fire
            # (retired provider) is exactly the delivered-spin shape. The
            # merged_count == 0 guard moved here from the inner if (#5689).
            _park_text=""
            _park_comments=""
            _park_cjson=$(gh issue view "$N" -R "$FULL" --json comments 2>/dev/null) || _park_cjson='{"comments":[]}'
            _park_comments=$(printf '%s' "$_park_cjson" | jq -r '[.comments[]?.body // empty] | join("\n")' 2>/dev/null || true)
            _park_text="${body}"$'\n'"${_park_comments}"

            _park_runtime_unit=""
            if [[ -n "$_park_text" ]]; then
                while IFS= read -r _park_unit; do
                    [[ -z "$_park_unit" ]] && continue
                    if XDG_RUNTIME_DIR="/run/user/$(id -u)" systemctl --user is-active "$_park_unit" >/dev/null 2>&1; then
                        _park_runtime_unit="$_park_unit"
                        break
                    fi
                done <<<"$(printf '%s' "$_park_text" | grep -oE '[A-Za-z0-9_.@:-]+\.(timer|service)' | sort -u || true)"
            fi

            _park_nonclaim_merged=0
            _park_delivered_pr=""
            if [[ -z "$_park_runtime_unit" ]]; then
                _park_refs=""
                if [[ -n "$_park_text" ]]; then
                    _park_refs=$(printf '%s' "$_park_text" | grep -oE '[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+|[A-Za-z0-9_.-]+#[0-9]+|#[0-9]+' | sed 's/^#//' | sort -u) || true
                fi
                if [[ -n "$_park_refs" ]]; then
                    while IFS= read -r _park_ref; do
                        if [[ "$_park_ref" =~ ^[0-9]+$ ]]; then
                            _park_ref_full="$FULL"
                        elif [[ "$_park_ref" == */* ]]; then
                            _park_ref_owner="${_park_ref%%/*}"
                            _park_ref_rest="${_park_ref#*/}"
                            _park_ref_repo="${_park_ref_rest%%#*}"
                            _park_ref_full="${_park_ref_owner}/${_park_ref_repo}"
                        else
                            _park_ref_repo="${_park_ref%#*}"
                            _park_ref_full="Nishfleet/${_park_ref_repo}"
                        fi
                        _park_ref_num="${_park_ref##*#}"
                        # fleet-ops#5991: a MERGED non-claim reference counts
                        # as delivery ONLY if the PR actually CLOSES this
                        # issue — `closingIssuesReferences` must include issue
                        # $N in $FULL. Any comment that merely mentions an
                        # unrelated merged PR (e.g. `Relates to`, a
                        # `blocked-on:` target, or discussion of another
                        # issue) used to park the issue; mentions never equal
                        # delivery (fleet-ops#3231).
                        _park_pr_info=$(_gh_read pr view "$_park_ref_num" -R "$_park_ref_full" --json state,headRefName,closingIssuesReferences 2>/dev/null || true)
                        if [[ -n "$_park_pr_info" ]] && printf '%s' "$_park_pr_info" | jq -e '.state == "MERGED" and .headRefName != "claim/issue-'"$N"'"' >/dev/null 2>&1; then
                            _park_closes_it=$(printf '%s' "$_park_pr_info" | jq -e --arg full "$FULL" --argjson n "$N" 'any(.closingIssuesReferences[]?; .number == $n and ((.repository.owner.login // "") + "/" + (.repository.name // "") | ascii_downcase) == ($full | ascii_downcase))' 2>/dev/null || true)
                            if [[ "$_park_closes_it" == "true" ]]; then
                                _park_nonclaim_merged=1
                                _park_delivered_pr="$_park_ref_num"
                                break
                            fi
                        fi
                    done <<<"$_park_refs"
                fi
            fi

            if [[ -n "$_park_runtime_unit" || $_park_nonclaim_merged -eq 1 ]]; then
                if [[ -n "$_park_runtime_unit" ]]; then
                    _park_reason="active user unit $_park_runtime_unit"
                else
                    _park_reason="merged non-claim PR #$_park_delivered_pr delivered it"
                fi
                echo "issue $N ($title): skipped-parked-protected-delivered ($_park_claims cumulative claims > cap $PARK_MAX_CLAIMS; $_park_reason; awaiting runtime gate, fleet-ops#5048)" >&2
                gh label create awaiting-runtime-gate -R "$FULL" --color D4C5F9 \
                    --description "Parked: protected issue + delivered work awaiting a runtime gate; do not claim (fleet-ops#5048)" --force >/dev/null 2>&1 || true
                gh issue edit "$N" -R "$FULL" --add-label awaiting-runtime-gate --remove-label agent-ready 2>/dev/null || true
                gh issue comment "$N" -R "$FULL" --body "fleet-ops#5048: issue $N is protected (owner-authored or critical-path) with no merged claim-branch delivery PR, but its remaining work is already delivered on a non-claim branch or delegated to an active runtime unit (${_park_reason}). It has been re-claimed ${_park_claims} times while the runtime gate is not yet met. Parking it: labelled \`awaiting-runtime-gate\`, removed from agent-ready; the intake will not re-claim it until the runtime event fires (clear the label then) or Nish closes the issue. No new timer." 2>/dev/null || true
                continue
            fi
        fi
        # fleet-ops#5082: duplicate-of-merged-work branch — the probe itself
        # is park_duplicate_delivery() above. Runs for every protected
        # past-cap issue whose own claim-branch merged probe is empty —
        # termination: clause or not (the #4540 branch above already
        # continue'd on a merged claim-branch delivery). Deterministic only:
        # a `files:` overlap plus a different claim/issue-<M> head or a `#N`
        # reference; a bare prose mention never parks (fleet-ops#3231).
        if (( _park_protected == 1 )); then
            if [[ -z "$_park_merged" ]]; then
                _park_merged=$(gh pr list -R "$FULL" --head "claim/issue-$N" --state merged --json number,url,mergedAt 2>/dev/null || echo "[]")
            fi
            if ! printf '%s' "$_park_merged" | jq -e 'length > 0' >/dev/null 2>&1; then
                _park_dup=$(park_duplicate_delivery "$FULL" "$N" "$body")
                if [[ -n "$_park_dup" ]]; then
                    echo "issue $N ($title): skipped-parked-protected-duplicate ($_park_claims cumulative claims > cap $PARK_MAX_CLAIMS; no merged claim/issue-$N PR; merged PR #$_park_dup delivered the files: work; awaiting runtime gate)" >&2
                    gh label create awaiting-runtime-gate -R "$FULL" --color D4C5F9 \
                        --description "Parked: protected issue already delivered by another issue's merged PR; do not claim (fleet-ops#5082)" --force >/dev/null 2>&1 || true
                    gh issue edit "$N" -R "$FULL" --add-label awaiting-runtime-gate --remove-label agent-ready 2>/dev/null || true
                    gh issue comment "$N" -R "$FULL" --body "fleet-ops#5082: issue $N is protected (owner-authored or critical-path) and has been claimed ${_park_claims} times, but no PR on its own claim branch (\`claim/issue-$N\`) ever merged — its \`do:\` was already delivered by merged PR #$_park_dup, whose diff overlaps the issue's \`files:\` set. observe-to-close stays comment-only on protected issues (fleet-ops#1435), so the issue stays OPEN by design while every anti-loop gate misses the slow-spaced spin (the #4540 head-branch probe can only see delivery on the issue's OWN claim branch). Parking it: labelled \`awaiting-runtime-gate\`, removed from agent-ready; the intake will not re-claim it until Nish closes the issue or the label is cleared." 2>/dev/null || true
                    continue
                fi
            fi
        fi
    fi

    # fleet-ops#3575: fetch comments up-front so a comment-level `blocked-on:`
    # stops the re-claim. Comments were already needed for the spec gate
    # below; fetching here (before the blocker filter) lets blocked_filter
    # scan them. Fail-closed (never claim on a lookup failure) — the same
    # skip the spec gate used to emit.
    # Pass ONLY the latest comment into blocked_filter. Joining every comment
    # made released agent-ready issues (DECISION + relabel) stay
    # skipped-blocked-on forever because older bounce lines still said
    # `blocked-on: orchestrator` / `blocked-on: split` (0509#1383/#1981).
    # The bounce protocol writes blocked-on on the comment that *is* latest
    # at bounce time, so comments[-1] still catches a live bounce.
    _cjson=$(gh issue view "$N" -R "$FULL" --json comments 2>/dev/null) || {
        echo "issue $N ($title): skipped-comments-unreadable"
        continue
    }
    comments=$(printf '%s' "$_cjson" | jq -r '[.comments[]?.body // empty] | join("\n")')
    last_comment=$(printf '%s' "$_cjson" | jq -r '.comments[-1].body // ""')

    # Blocker filter: never claim an issue whose body or LATEST comment carry
    # a blocked-on: line (machine dep or nish-decision). The claim is a no-op
    # spawn churn otherwise. fleet-ops#3575: the worker bounce protocol puts
    # machine-readable blocked-on: lines in a comment, not the body, so the
    # filter must scan that comment too. Audit finding 2026-08-26: fleet-ops#87
    # looped exactly this way.
    if blocked_filter "$body" "$FULL" "$N" "$last_comment"; then
        echo "issue $N ($title): skipped-blocked-on"
        continue
    fi

    # fleet-ops#4801: skip members of a batch being judged (not de-labelled).
    # The in-flight marker lists the batch; while the judge runs, intake does
    # not claim any member so the verdict lands before a worker touches them.
    if [[ -f "$SPEC_JUDGE_LIB" ]] && spec_judge_skip_member "$REPO" "$N"; then
        echo "issue $N ($title): skipped-spec-judge (member of a batch being judged)"
        continue
    fi

    # fleet-ops#4808: depends-on gate. Never claim an issue whose body
    # carries a `depends-on:` line naming an issue/PR that is not yet DONE
    # (closed or merged). The issue stays agent-ready (no de-label); the
    # next tick re-checks once the dependency lands. The filter prints the
    # skip reason (skipped-depends-on:#n or depends-on-cycle) and returns 1.
    #
    # The filter is called in the CURRENT shell (stdout redirected to a
    # temp file, not a $(...) subshell) so the per-tick memo caches
    # (_dep_state_cache / _dep_body_cache) persist across every issue in
    # this tick — a dependency named by many issues costs one gh call.
    _dep_reason_file="$(mktemp)"
    if ! depends_on_filter "$body" "$FULL" "$N" >"$_dep_reason_file"; then
        _dep_reason="$(cat "$_dep_reason_file")"
        rm -f "$_dep_reason_file"
        echo "issue $N ($title): $_dep_reason"
        continue
    fi
    rm -f "$_dep_reason_file"

    # fleet-ops#3309: more than 2 live required: lines bounce (agent-blocked)
    # and must not push a claim branch. Struck-through lines do not count.
    # Umbrella-labeled issues are exempt (tracking parents, never claimable).
    _size_dir=$(mktemp -d)
    printf '%s' "$body" >"$_size_dir/body"
    printf '%s' "$comments" >"$_size_dir/comments"
    set +e
    size_out=$(python3 "$SPEC_GATE_PY" check-size --body "$_size_dir/body" --comments "$_size_dir/comments" --labels "${labels[$i]:-}" 2>&1)
    size_rc=$?
    set -e
    rm -rf "$_size_dir"
    if (( size_rc == 1 )); then
        echo "issue $N ($title): skipped-oversized"
        gh issue edit "$N" -R "$FULL" --remove-label agent-ready --add-label agent-blocked 2>/dev/null || true
        gh issue comment "$N" -R "$FULL" --body "$size_out" 2>/dev/null || true
        continue
    fi
    if (( size_rc != 0 )); then
        echo "agent-ready-spec-gate check-size failed for issue $N (rc=$size_rc): $size_out" >&2
        exit 1
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

    # fleet-ops#4639 (orchestrator append): heavy seat missing -> LIGHT-ONLY
    # claims this tick. Claiming a heavy issue used to spawn a unit that died
    # on the heavy pick — exactly the churn the seat gate exists to stop. The
    # difficulty is computed once here (the light-only filter and the packet
    # header share it). While the repair rung is armed the light-only filter
    # does NOT apply — the rung is the reserved exemption.
    difficulty="$(issue_difficulty "${labels[$i]}" "$title" "$body")"
    if [[ "$_light_only_claims" == "1" && "$_repair_rung_armed" == "0" && "$difficulty" != "light" ]]; then
        echo "issue $N ($title): skipped-heavy-no-heavy-seat (light-only tick — no usable heavy-capable seat, fleet-ops#4639)"
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
    # fleet-ops#4639: the rung is exempt from yield caps — admit without the
    # band check and tag the reason so the floor-lane case below sees it.
    if [[ "$_repair_rung_armed" == "1" ]]; then
        band_reason="allow-repair-rung"
    else
        band_reason=$(precedence_band_allow_claim "$REPO" "$N" "${labels[$i]}" "$body" "$title") || {
            echo "issue $N ($title): skipped-precedence-band ($band_reason)"
            continue
        }
    fi

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
            allow-band-bootstrap|allow-band-floor|allow-starvation-floor|allow-surge-floor|allow-surge-leverage|allow-multiplier|allow-band-surge-legit|allow-repair-rung)
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
    # Secondary rate limit ("submitted too quickly") backs off 60s x attempt
    # and, when it exhausts all retries, persists the backoff state so the
    # gate above holds future ticks instead of hammering the limit (fleet-ops#3445).
    edit_attempt=0
    edit_out=""
    edit_rc=0
    for _ in 1 2 3; do
        edit_attempt=$(( edit_attempt + 1 ))
        edit_rc=0
        edit_out=$(gh issue edit "$N" -R "$FULL" --remove-label agent-ready --add-label agent-in-progress 2>&1) || edit_rc=$?
        if [[ $edit_rc -eq 0 ]]; then break; fi
        case "$edit_out" in
            *"submitted too quickly"*|*"secondary rate"*|*"429"*) sleep $((60 * edit_attempt)) ;;
            *) break ;;
        esac
    done
    if [[ $edit_rc -ne 0 ]]; then
        case "$edit_out" in
            *"submitted too quickly"*|*"secondary rate"*|*"429"*)
                _ss_state=$(_gh_secondary_read)
                _ss_attempt=$(printf '%s' "$_ss_state" | jq -r '.attempt // 0')
                _ss_new_attempt=$(( _ss_attempt + edit_attempt ))
                _ss_now=$(date +%s)
                _ss_backoff=$(( _ss_now + 60 * _ss_new_attempt ))
                _gh_secondary_write "$_ss_new_attempt" "$_ss_backoff"
                git -C "$REPO_DIR" push origin ":refs/heads/claim/issue-$N" >/dev/null 2>&1 || true
                echo "issue $N ($title): gh secondary rate limit after $edit_attempt attempts; backing off 60s x $_ss_new_attempt and releasing claim branch — gate: gh_rate_limit secondary" >&2
                exit 0
                ;;
        esac
        labels_json=$(_gh_read issue view "$N" -R "$FULL" --json labels --jq '.labels | map(.name)' 2>/dev/null || true)
        if echo "$labels_json" | grep -q '"agent-in-progress"' && ! echo "$labels_json" | grep -q '"agent-ready"'; then
            echo "issue $N: labels already in target state (agent-in-progress set, agent-ready removed) — idempotent skip"
        else
            echo "gh issue edit failed for $N: $edit_out" >&2
            exit 1
        fi
    fi

    # GitHub secondary rate limits on addComment ("submitted too quickly")
    # are transient — retry with 60s x attempt backoff (fleet-ops#3445). A
    # permanent failure (auth, 404, etc.) still exits 1 after exhaustion.
    comment_body="claimed by pi-issue-${REPO}-${N} at $(date -u +%FT%TZ)"
    comment_out=""
    comment_rc=0
    comment_attempt=0
    for _ in 1 2 3; do
        comment_attempt=$(( comment_attempt + 1 ))
        comment_rc=0
        comment_out=$(gh issue comment "$N" -R "$FULL" --body "$comment_body" 2>&1) || comment_rc=$?
        if [[ $comment_rc -eq 0 ]]; then break; fi
        case "$comment_out" in
            *"submitted too quickly"*|*"secondary rate"*|*"429"*) sleep $((60 * comment_attempt)) ;;
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
    # fleet-ops#4643: [stable prefix][volatile tail]. Stable prefix is worker.md
    # plus the repo-conditional fragments (D1 / GEO files are themselves stable).
    # Difficulty and TARGET are per-issue so they come AFTER the last stable byte.
    # fleet-ops#3247: D1 + gate-integrity ships only for 0509 (ideally only when
    # the body names migrations/ or .github/) and GEO/AEO ships only for
    # geo/aeo-labelled issues. Non-0509 / non-geo packets stay lean. A missing
    # fragment file is non-fatal: the packet is still written with the base
    # prompt + TARGET line so the worker runs rather than not at all (same
    # fail-open posture as the keystone marker in pi-issue-start).
    packet_path="$ISSUE_STATE_DIR/${REPO}-${N}.in"
    # difficulty was computed at the light-only filter above (fleet-ops#4639:
    # one issue_difficulty pass per issue; the filter and the header share it).
    {
        if [[ -f "$WORKER_PROMPT" ]]; then
            cat "$WORKER_PROMPT"
        else
            echo "pi-intake-tick: worker prompt missing at $WORKER_PROMPT; writing TARGET-only packet (fail-open, fleet-ops#1407)" >&2
        fi
        if d1_gate_integrity_needed "$body" \
            && [[ -f "$WORKER_BLOCKS_DIR/$D1_GATE_INTEGRITY_BLOCK" ]]; then
            echo
            cat "$WORKER_BLOCKS_DIR/$D1_GATE_INTEGRITY_BLOCK"
        fi
        if geo_aeo_needed "${labels[$i]}" \
            && [[ -f "$WORKER_BLOCKS_DIR/$GEO_AEO_BLOCK" ]]; then
            echo
            cat "$WORKER_BLOCKS_DIR/$GEO_AEO_BLOCK"
        fi
        echo
        # Volatile tail (fleet-ops#4643): difficulty, seat-rung and TARGET are
        # per-issue, so they come AFTER the last stable byte. fleet-ops#4639:
        # repair-rung claims carry the seat-rung marker so pi-issue-run arms
        # PI_REPAIR_RUNG and routes the worker to the reserved rung lane
        # (litellm judge group, proxy fallback to senior) when ordinary
        # capacity is exhausted.
        echo "difficulty: $difficulty"
        if [[ "$_repair_rung_armed" == "1" ]]; then
            echo "seat-rung: repair"
        fi
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

    # fleet-ops#1558 + #3281: per-repo MemoryMax/MemoryHigh via per-instance
    # drop-in before start. Template keeps MemoryMax=6G/MemoryHigh=3G; this
    # overrides for known repos (fleet-ops + 0509 MemoryMax=4G, throttle band
    # removed per fleet-ops#3930) and for heavy|keystone issues (heavy class
    # 3G/2G, fleet-ops#3281).
    # Missing table row = keep template. daemon-reload so the fresh drop-in is
    # seen on the subsequent start (oneshot units are not lingering-loaded).
    mem_row=$(worker_memory_for_difficulty "$REPO" "$difficulty" 2>/dev/null || true)
    if [[ -n "$mem_row" ]]; then
        IFS=$'\t' read -r mem_max mem_high <<<"$mem_row"
        drop_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/${unit}.d"
        mkdir -p "$drop_dir"
        drop_tmp="$drop_dir/memory.conf.tmp.$$"
        {
            printf '# fleet-ops#1558/#3281: per-repo/per-difficulty memory cap (written by intake)\n'
            printf '[Service]\n'
            [[ -n "$mem_max" ]] && printf 'MemoryMax=%s\n' "$mem_max"
            # fleet-ops#3930 correction: an empty mem_high means the row DROPPED
            # the throttle band (fleet-ops + 0509). An OMITTED MemoryHigh= line
            # does not clear it -- the unit still inherits the template's
            # MemoryHigh=3G, so the pressure-kill fix never took effect on live
            # workers (measured: every running pi-issue@* unit still showed
            # MemoryHigh=3221225472 after #3938/#3950 merged). Writing the key
            # with an EMPTY value is systemd's own reset syntax and clears the
            # inherited template value (verified: systemctl --user show reports
            # MemoryHigh=infinity after an empty override, vs MemoryHigh=3G with
            # the key omitted).
            if [[ -n "$mem_high" ]]; then
                printf 'MemoryHigh=%s\n' "$mem_high"
            else
                printf 'MemoryHigh=\n'
            fi
            # fleet-ops#3611: keep the worker off swap so a runaway is OOM-killed
            # locally instead of thrashing the host and killing unrelated units.
            printf 'MemorySwapMax=0\n'
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
    # fleet-ops#4639: REPAIR-RUNG is the rung-usage log line the termination
    # drill greps the intake journal for (accept 1/3).
    if [[ "$_repair_rung_armed" == "1" ]]; then
        echo "REPAIR-RUNG: claimed critical-path issue $N on the repair rung (concurrency cap $PI_INTAKE_REPAIR_RUNG_MAX_CONCURRENT, fleet-ops#4639)"
    elif (( ${_repair_rung_product_reserve:-0} == 1 )); then
        echo "REPAIR-RUNG product-reserve: claimed issue $N on $REPO while rung armed (fleet-ops#4820)"
    fi
    _claimed_this_tick=$(( _claimed_this_tick + 1 ))
    # fleet-ops#3784: stagger cohort spawns so clone/npm/pi startup peaks do
    # not overlap (oomd slice-pressure kills at tick time). Sleep a few
    # seconds between systemctl start --no-block calls. 0 disables. The value
    # is loaded from seat-caps.json spawn_stagger_s by load_seat_caps (called
    # in the parent shell after the capacity step above — fleet-ops#3861, so
    # the value survives the routing subshells into this read); default 0
    # if the caps file is absent.
    SEAT_SPAWN_STAGGER_S=${SEAT_SPAWN_STAGGER_S:-0}
    if (( SEAT_SPAWN_STAGGER_S > 0 )); then
        # Log the value actually slept so a claim tick proves the configured
        # stagger engaged (fleet-ops#3861).
        echo "issue $N ($title): spawn stagger ${SEAT_SPAWN_STAGGER_S}s (seat-caps spawn_stagger_s)"
        sleep "$SEAT_SPAWN_STAGGER_S"
    fi
    # fleet-ops#1455: write a durable claim record so the fleet judge
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
    # fleet-ops#3254: count this self-maintenance claim toward the 20% cap.
    # Exempt issues (critical-path label) were admitted past the cap, so skip
    # the increment for them — only ordinary control-plane claims consume the
    # budget and eventually cap the tick.
    if (( _self_maint_cap > 0 )); then
        if printf '%s' "${labels[$i]}" | jq -e --arg cp "$CRITICAL_PATH_LABEL" \
            '[.[]?.name // empty] | index($cp) != null' >/dev/null 2>&1; then
            : # exempt — does not consume the self-maintenance budget
        else
            _self_maint_claims=$(( _self_maint_claims + 1 ))
        fi
    fi
    _rc_init_file="$ATTEMPTS_DIR/pi-issue-${REPO}-${N}.reclaim-count"
    if [[ ! -f "$_rc_init_file" ]]; then
        printf '1' > "$_rc_init_file" 2>/dev/null || true
    fi
    slots=$(( slots - 1 ))
done

# fleet-ops#4450 item 2: LOW-WATER supply trigger at the end of the tick.
# ready_after = the agent-ready pool left after this tick's claims. When it
# is at or below the measured drain rate the pool cannot feed the workers
# until the next scout timer, so start the repo's own pi-scout@<repo>
# service now. Ready_after can be 0 when this tick drained the pool (the
# scout_on_empty branch above only fires when the pool was empty at START);
# the low-water branch re-fires when it became empty BECAUSE of this tick.
_ready_after=$(( ready_count - _claimed_this_tick ))
(( _ready_after < 0 )) && _ready_after=0
scout_low_water "$_ready_after"

# fleet-ops#4820: while the rung is armed a product tick must either claim
# one issue or say why it could not. A silent 0-claim product tick is
# the starvation this issue closes.
if (( ${_repair_rung_product_reserve:-0} == 1 )); then
    if (( _claimed_this_tick > 0 )); then
        echo "REPAIR-RUNG product-reserve: claimed $_claimed_this_tick issue(s) on $REPO while rung armed (fleet-ops#4820)"
    else
        echo "REPAIR-RUNG product-reserve: no product claim this tick — ${_product_skip_reason:-no agent-ready issue claimed} (fleet-ops#4820)"
    fi
fi

exit 0
