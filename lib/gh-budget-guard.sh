#!/usr/bin/env bash
# lib/gh-budget-guard.sh — shared GitHub App budget visibility + reserve helpers
# (fleet-ops#5489). Sourced, never executed — the shebang exists so
# the SC2148 hint is satisfied and `bash -n` is meaningful.
#
# The nishfleet-worker App token has a hard 5000/hr core budget shared by the
# whole fleet. When it exhausts, intake starves silently. The three helpers
# here are the shared primitive for every organ gate that must NOT fail open
# silently (issue required item 1) and that must respect the intake reserve
# floor (item 4):
#
#   gh_budget_read          — parse the exporter side-car (reads the SAME
#                             cached state file; NEVER a fresh `gh api
#                             rate_limit` call — the guard must not consume
#                             the budget it is guarding).
#   gh_budget_line          — the `gh_app: remaining=<n> reset_in=<m>` field
#                             text named by the issue's required item 1.
#   gh_budget_loud          — ONE deduped LOUD line to the judges' triage file
#                             (fleet-ops#5489: a fail-open that is a mystery is
#                             not visible; the heartbeat tier-2 judges walk
#                             the triage file every hour). Deduped so a
#                             broken exporter cannot spam the triage every
#                             5-min tick.
#   gh_budget_reserve_hold  — the item 4 reserve: prints a loud pause line and
#                             returns 0 when fresh state shows remaining below
#                             the reserve floor (the caller exits 0 / pauses),
#                             so sweeps/organs pause while intake claims keep
#                             their floor. Returns 1 to proceed.

# Paths are env-overridable so tests run offline against scratch dirs. The
# defaults derive from $HOME (prod HOME is /home/nish, so this is the same
# absolute path the intake tick uses) — a test that stubs HOME to a scratch
# dir then sees a missing side-car and fails open instead of reading the
# live VPS state (hermetic tests, fleet-ops#5489 reserve gate).
GH_BUDGET_STATE="${GH_BUDGET_STATE:-${HOME:-/home/nish}/workspaces/agent-state/pi-intake/gh-rate-limit.json}"
GH_BUDGET_TRIAGE="${GH_BUDGET_TRIAGE:-${FLEET_HEARTBEAT_TRIAGE:-${HOME:-/home/nish}/workspaces/agent-state/FLEET-HEARTBEAT-TRIAGE.md}}"
GH_BUDGET_LAST_LOUD="${GH_BUDGET_LAST_LOUD:-${HOME:-/home/nish}/workspaces/agent-state/pi-intake/gh-budget-last-loud}"
GH_BUDGET_LOUD_WINDOW_S="${GH_BUDGET_LOUD_WINDOW_S:-1800}"

# gh_budget_read [path] -> "remaining limit reset fetched_at" or empty.
# Prefers resources.core (the exporter MIN-aggregates top-level remaining to
# the search floor, ~30/30, while REST core is the ~5000 budget this guard
# exists to read; fleet-ops#2523 hit the same trap).
gh_budget_read() {
    local p="${1:-$GH_BUDGET_STATE}"
    [[ -r "$p" ]] || return 1
    local j
    j=$(cat "$p" 2>/dev/null) || return 1
    [[ -n "$j" ]] || return 1
    printf '%s' "$j" | jq -r '
        (.resources.core // .) as $c
        | [($c.remaining // 0), ($c.limit // 0), ($c.reset // 0), (.fetched_at // 0)]
        | @tsv
    ' 2>/dev/null
}

# gh_budget_line <remaining> <reset> -> "gh_app: remaining=<n> reset_in=<m>"
# reset_in is seconds to window reset, floored at 0. Unknown budget prints
# remaining=unknown so the field never fakes a number.
gh_budget_line() {
    local remaining="${1:-unknown}" reset="${2:-}"
    if [[ "$remaining" == "unknown" || -z "$remaining" ]]; then
        printf 'gh_app: remaining=unknown reset_in=unknown'
        return 0
    fi
    local now reset_in
    now=$(date +%s)
    reset_in=$(( ${reset:-0} - now ))
    (( reset_in < 0 )) && reset_in=0
    printf 'gh_app: remaining=%s reset_in=%s' "$remaining" "$reset_in"
}

# gh_budget_loud <msg> — append ONE deduped LOUD line to the judges' triage
# file. Dedup window (default 30 min) means a flapping state cannot flood the
# triage the judges read every hour. Never consumes gh quota.
gh_budget_loud() {
    local msg="$1"
    local now last=""
    now=$(date +%s)
    if [[ -r "$GH_BUDGET_LAST_LOUD" ]]; then
        # cat, not `read ... || last=0`: read returns 1 on a file with no
        # trailing newline AFTER it has populated the variable, so the `||`
        # fallback would clobber the good timestamp with 0 and defeat the
        # dedup window on every second call.
        last="$(cat "$GH_BUDGET_LAST_LOUD" 2>/dev/null || true)"
        last=$(printf '%s' "$last" | tr -cd '0-9')
        [[ "$last" =~ ^[0-9]+$ ]] || last=0
        if (( now - last < GH_BUDGET_LOUD_WINDOW_S )); then
            return 0
        fi
    fi
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf '\n[%s] [GH-APP-BUDGET] %s\n' "$ts" "$msg" >>"$GH_BUDGET_TRIAGE" 2>/dev/null \
        || echo "gh-app-budget: could not write triage line to $GH_BUDGET_TRIAGE: $msg" >&2
    mkdir -p "$(dirname "$GH_BUDGET_LAST_LOUD")" 2>/dev/null || true
    printf '%s' "$now" > "$GH_BUDGET_LAST_LOUD" 2>/dev/null || true
    echo "LOUD [GH-APP-BUDGET] $msg"
}

# gh_budget_reserve_hold <floor> — read fresh state; if remaining is below
# $1, print a pause line naming the reserve, write the deduped loud line,
# and return 0 (the caller exits 0 / pauses gh ops). Fresh-but-healthy or
# unreadable (fail-open) state returns 1 (caller proceeds).
gh_budget_reserve_hold() {
    local floor="${1:-0}"
    local row
    row=$(gh_budget_read) || { echo "gh-app-budget: reserve check state unreadable; proceeding (fail-open, gate: gh_budget reserve missing)"; return 1; }
    local remaining limit reset fetched_at now age max_age
    read -r remaining limit reset fetched_at <<<"$row" || return 1
    max_age="${GH_BUDGET_MAX_AGE:-420}"
    now=$(date +%s)
    age=$(( now - ${fetched_at%.*} ))
    if (( age > max_age )); then
        echo "gh-app-budget: reserve check state stale (age=${age}s > max=${max_age}s); proceeding (fail-open) — gate: gh_budget reserve stale"
        return 1
    fi
    if (( remaining >= floor )); then
        return 1
    fi
    local reset_in
    reset_in=$(( reset - now )); (( reset_in < 0 )) && reset_in=0
    echo "gh-app-budget: reserve floor reached (remaining=${remaining} < reserve=${floor}, limit=${limit}, reset_in=${reset_in}s); holding GitHub ops so intake claims keep a floor — gate: gh_app_budget reserve"
    gh_budget_loud "GH App budget reserve floor reached: remaining=${remaining} < reserve=${floor} (limit=${limit}, reset in ${reset_in}s). Sweeps/organs pause so intake claims keep their floor (fleet-ops#5489)."
    return 0
}
