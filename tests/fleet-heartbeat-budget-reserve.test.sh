#!/usr/bin/env bash
# tests/fleet-heartbeat-budget-reserve.test.sh
#
# fleet-ops#5489 required item 4: the GH App budget RESERVE in
# bin/fleet-heartbeat-tier1 (the seat org_reserve analogue, for the shared
# 5000/hr App core budget). When fresh side-car state shows remaining below
# the reserve floor, the tier-1 tick is HELD — exit 0 before any section —
# so sweeps cannot starve the workers' intake claims. Proves:
#
#   1. tier1 wires the guard: sources lib/gh-budget-guard.sh and calls
#      gh_budget_reserve_hold with an explicit early exit (grep contract,
#      the same pattern the canary tests use for tier1 wiring).
#   2. EXECUTION: fresh side-car below the floor -> tier1 exits 0, prints
#     the reserve pause line, raises the deduped [GH-APP-BUDGET] triage
#     line, and makes ZERO gh calls (the hold precedes every section).
#   3. GITHUB_ACTIONS=true never engages the reserve (CI has no side-car
#      and must not read one).
#
# A stale or missing side-car fails open (proceed); that path is pinned at
# the guard level in tests/fleet-gh-budget-guard.test.sh — executing the
# whole tick for it here would run every tier-1 section, which a unit test
# must not do.
#
# Hosted by tests/fleet-heartbeat-throughput-split.test.sh so it runs in
# CI without a workflow-file edit (fleet-ops#566).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tier1="$repo_root/bin/fleet-heartbeat-tier1"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$tier1" ]] || fail "not executable: $tier1"

scratch="$(mktemp -d -t ghbudgetreserve.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# --- 1. wiring contract (grep, like the canary tests) ------------------------
grep -q 'lib/gh-budget-guard.sh' "$tier1" || fail "tier1 must source lib/gh-budget-guard.sh"
grep -q 'gh_budget_reserve_hold' "$tier1" || fail "tier1 must call gh_budget_reserve_hold"
grep -q 'GH_APP_RESERVE_FLOOR' "$tier1" || fail "tier1 must honour the GH_APP_RESERVE_FLOOR override"
# The hold must exit 0 (a pause, not a failure) and sit before the sections.
grep -A2 'gh_budget_reserve_hold' "$tier1" | grep -q 'exit 0' \
    || fail "the reserve hold must exit 0 so the next tick re-checks"
ok "scenario1: tier1 wires the guard, the floor override, and the exit-0 hold"

# --- shared stub environment -------------------------------------------------
gh_stub="$scratch/gh"
: >"$scratch/gh.log"
cat >"$gh_stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:?}"
exit 0
STUB
chmod +x "$gh_stub"

run_tier1() { # <extra env assignments...> -- runs tier1 with scratch HOME
    env -i \
        HOME="$scratch/home" \
        PATH="/usr/bin:/bin" \
        GH="$gh_stub" \
        GH_TOKEN="stub-token" \
        GH_LOG="$scratch/gh.log" \
        GH_BUDGET_STATE="$scratch/gh-rate-limit.json" \
        GH_BUDGET_TRIAGE="$scratch/triage.md" \
        GH_BUDGET_LAST_LOUD="$scratch/last-loud" \
        FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
        "$@" \
        bash "$tier1"
}

mkdir -p "$scratch/home"

# --- 2. EXECUTION: below the floor -> held, zero gh calls --------------------
: >"$scratch/triage"
now=$(date +%s)
cat >"$scratch/gh-rate-limit.json" <<JSON
{"resources":{"core":{"remaining":300,"limit":5000,"reset":$(( now + 1500 ))}},"fetched_at":$now}
JSON
hold_out="$(run_tier1 2>&1)" && rc=0 || rc=$?
[[ "$rc" == "0" ]] || fail "reserve hold must exit 0 (a pause), got rc=$rc: $hold_out"
grep -q "reserve floor reached" <<<"$hold_out" || fail "pause line missing from tick output: $hold_out"
grep -q "remaining=300 < reserve=1200" <<<"$hold_out" || fail "pause line lost the numbers: $hold_out"
grep -q "GH-APP-BUDGET" "$scratch/triage.md" || fail "hold did not raise the [GH-APP-BUDGET] triage line"
[[ ! -s "$scratch/gh.log" ]] || fail "a held tick must make ZERO gh calls, made: $(cat "$scratch/gh.log")"
ok "scenario2: below the floor the tick is held — exit 0, LOUD triage line, zero gh calls"

# --- 2b. floor override: GH_APP_RESERVE_FLOOR=100 with remaining=300 proceeds
# (returns past the hold into the sections — so prove only that the hold did
# NOT fire and gh calls start, then kill the tick's output; the sections
# themselves are covered by their own tests).
: >"$scratch/gh.log"
proceed_out="$(GH_APP_RESERVE_FLOOR=100 timeout 20 run_tier1 2>&1 || true)"
if grep -q "reserve floor reached" <<<"$proceed_out"; then
    fail "floor=100 with remaining=300 must NOT hold"
fi
[[ -s "$scratch/gh.log" ]] || fail "above the floor the tick must proceed into its sections (gh calls expected)"
ok "scenario2b: GH_APP_RESERVE_FLOOR override is honoured; above the floor the tick proceeds"

# --- 3. GITHUB_ACTIONS=true never engages the reserve ------------------------
: >"$scratch/triage"
engage_out="$(run_tier1 GITHUB_ACTIONS=true 2>&1 || true)"
grep -q "reserve floor reached" <<<"$engage_out" \
    && fail "GITHUB_ACTIONS=true must skip the reserve check entirely"
ok "scenario3: GITHUB_ACTIONS=true skips the reserve (CI has no side-car)"

echo "ALL TESTS PASSED (tests/fleet-heartbeat-budget-reserve.test.sh)"
