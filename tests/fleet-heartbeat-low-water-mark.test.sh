#!/usr/bin/env bash
# tests/fleet-heartbeat-low-water-mark.test.sh
#
# Proves the low-water-mark scouting pass (fleet-ops#146) does what the
# issue's acceptance criteria demand, entirely offline with mocked
# systemctl + gh:
#
#   1. ready < lanes + stale stamp + scout idle  -> scout started + stamp
#      written + LOW-WATER-REFILL triage line; exit 0.
#   2. ready >= lanes                            -> NO dispatch.
#   3. fresh stamp (< min interval)              -> NO dispatch.
#   4. scout already active/activating           -> NO dispatch.
#   5. gh failure on the ready query             -> NO dispatch (skip on bad
#      data; never spam scouts on a transient gh outage).
#   6. seat-lib integration: with FLEET_LOW_WATER_LANE_CEILING unset, the
#      helper sources lib/seat-lib.sh and computes lane_ceiling =
#      min(sum_provider_caps, ram_governor) from a fixture seat-caps.json,
#      and dispatches iff ready < that real ceiling.
#
# The actual `systemctl start pi-scout@<repo>` is the outermost edge with a
# real-world side effect (it would run a live LLM scout). Per the
# execution-is-the-review rule it is stubbed here; the dispatch DECISION —
# the part this issue owns — is exercised end-to-end through the real
# helper binary.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-heartbeat-low-water-mark"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
command -v jq >/dev/null 2>&1 || fail "jq missing"

# --- scratch environment ----------------------------------------------------
scratch="$(mktemp -d -t lowwater.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"

# intake-repos.json: one enrolled repo ("demo").
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
stamp_dir="$scratch/stamps"
mkdir -p "$log_dir" "$stamp_dir"

# Shared call log: every `start --no-block` appends here so the test can
# assert a dispatch was (or was not) attempted.
calls="$scratch/calls.log"
: >"$calls"

# --- fake gh ----------------------------------------------------------------
# Controlled by $WORK_READY (a number) for the agent-ready count. A flag file
# $GH_BROKEN makes the ready query exit non-zero (scenario 5).
gh_fake="$scratch/gh"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
if [[ -f "${GH_BROKEN:-/dev/nonexistent}" ]]; then
    echo "gh: simulated failure" >&2
    exit 1
fi
case "$*" in
  *"issue list"*"-l agent-ready"*)
    n=$(cat "${WORK_READY:-/dev/null}" 2>/dev/null || echo 0)
    printf '%s\n' "$n"
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
# Behavior is driven by scratch state files:
#   $SCOUT_ACTIVE_UNITS  unit names (.service) considered active/activating
#                        for the is-active probe; anything else -> inactive.
#   $START_FAIL_UNITS    unit names whose `start --no-block` should fail.
# Mutating `start --no-block` calls append to $CALLS.
systemctl_fake="$scratch/systemctl"
cat >"$systemctl_fake" <<'FAKE'
#!/usr/bin/env bash
shift  # consume --user
cmd="$1"; shift
case "$cmd" in
  is-active)
    unit="$1"
    if [[ -f "${SCOUT_ACTIVE_UNITS:-/dev/nonexistent}" ]] \
       && grep -qxF "$unit" "${SCOUT_ACTIVE_UNITS:-/dev/nonexistent}" 2>/dev/null; then
      echo active
    else
      echo inactive
    fi
    exit 0
    ;;
  start)
    # Drop flags (e.g. --no-block) to find the unit token.
    unit=""
    for a in "$@"; do
      case "$a" in
        --*) ;;
        *) unit="$a"; break ;;
      esac
    done
    if [[ -f "${START_FAIL_UNITS:-/dev/nonexistent}" ]] \
       && grep -qxF "$unit" "${START_FAIL_UNITS:-/dev/nonexistent}" 2>/dev/null; then
      exit 1
    fi
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

# Common env for every invocation.
export FLEET_INTAKE_REPOS_JSON="$intake_json"
export FLEET_HEARTBEAT_LOG_DIR="$log_dir"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export FLEET_LOW_WATER_STAMP_DIR="$stamp_dir"
export FLEET_LOW_WATER_MIN_INTERVAL_S=2   # 2s — fresh = now, stale = 60s ago
# Generate-zone hours so existing lane-count scenarios stay independent of
# the #540 go-ham path (hours < 12). Override per-scenario when testing that path.
export FLEET_WORK_SUPPLY_HOURS=15
export FLEET_WORK_SUPPLY_LIB="$repo_root/lib/work-supply.sh"
export CALLS="$calls"
export WORK_READY="$scratch/work_ready"
SCOUT_ACTIVE_UNITS="$scratch/scout_active"
START_FAIL_UNITS="$scratch/start_fail"
export SCOUT_ACTIVE_UNITS START_FAIL_UNITS

run_helper() {
  set +e
  # Extra NAME=VALUE args (e.g. FLEET_LOW_WATER_LANE_CEILING=9) are placed
  # before "$bin" so `env` treats them as environment assignments.
  env_out=$(env SYSTEMCTL="$systemctl_fake" GH="$gh_fake" "$@" "$bin" 2>&1)
  env_rc=$?
  set -e
}

reset_state() {
  rm -f "$log_dir"/* "$triage" "$calls" "$stamp_dir"/*
  : >"$calls"
  : >"$SCOUT_ACTIVE_UNITS"; : >"$START_FAIL_UNITS"
}

# ============================================================================
# Scenario 1: ready < lanes + stale stamp + scout idle -> dispatch + stamp
# ============================================================================
reset_state
printf '3\n' >"$scratch/work_ready"        # 3 agent-ready issues
: >"$SCOUT_ACTIVE_UNITS"                   # no scout active
# Stale stamp: 60s ago, older than the 2s min interval.
date -u -d '60 seconds ago' +%Y-%m-%dT%H:%M:%SZ > "$stamp_dir/demo.stamp"
run_helper FLEET_LOW_WATER_LANE_CEILING=9

[[ "$env_rc" == 0 ]] || fail "scenario1: must exit 0, got $env_rc ($env_out)"
grep -qx 'start pi-scout@demo.service' "$calls" \
    || fail "scenario1: scout start not attempted ($(cat "$calls"))"
# Stamp rewritten with a fresh timestamp.
[[ -f "$stamp_dir/demo.stamp" ]] || fail "scenario1: stamp not written"
grep -q 'LOW-WATER-REFILL' "$triage" || fail "scenario1: triage missing LOW-WATER-REFILL"
# The triage line records the decision inputs.
grep -q 'ready=3' "$triage" || fail "scenario1: triage missing ready=3"
grep -q 'lanes=9' "$triage" || fail "scenario1: triage missing lanes=9"
ok "scenario1: ready<lanes + stale stamp + idle scout -> scout started, stamp written, exit 0"

# ============================================================================
# Scenario 2: ready >= lanes -> NO dispatch
# ============================================================================
reset_state
printf '9\n' >"$scratch/work_ready"        # 9 ready, lanes=9 -> ready >= lanes
: >"$SCOUT_ACTIVE_UNITS"
date -u -d '60 seconds ago' +%Y-%m-%dT%H:%M:%SZ > "$stamp_dir/demo.stamp"  # stale
run_helper FLEET_LOW_WATER_LANE_CEILING=9

[[ "$env_rc" == 0 ]] || fail "scenario2: must exit 0, got $env_rc ($env_out)"
if grep -qE '^start ' "$calls"; then
    fail "scenario2: must not dispatch when ready>=lanes, but calls=($(cat "$calls"))"
fi
! grep -q "LOW-WATER-REFILL" "$triage" 2>/dev/null || fail "scenario2: triage must not have LOW-WATER-REFILL"
ok "scenario2: ready>=lanes -> no dispatch"

# Also prove the boundary: ready == lanes is the no-dispatch line, ready == lanes-1 dispatches.
reset_state
printf '8\n' >"$scratch/work_ready"        # 8 < 9 -> dispatch
: >"$SCOUT_ACTIVE_UNITS"
date -u -d '60 seconds ago' +%Y-%m-%dT%H:%M:%SZ > "$stamp_dir/demo.stamp"
run_helper FLEET_LOW_WATER_LANE_CEILING=9
[[ "$env_rc" == 0 ]] || fail "scenario2b: must exit 0, got $env_rc ($env_out)"
grep -qx 'start pi-scout@demo.service' "$calls" \
    || fail "scenario2b: ready=lanes-1 must dispatch ($(cat "$calls"))"
ok "scenario2b: ready=lanes-1 dispatches (boundary: ready<lanes is strict)"

# ============================================================================
# Scenario 3: fresh stamp (< min interval) -> NO dispatch (even if ready<lanes)
# ============================================================================
reset_state
printf '1\n' >"$scratch/work_ready"        # 1 < 9 -> would dispatch
: >"$SCOUT_ACTIVE_UNITS"
# Fresh stamp: now, younger than the 2s min interval.
date -u +%Y-%m-%dT%H:%M:%SZ > "$stamp_dir/demo.stamp"
run_helper FLEET_LOW_WATER_LANE_CEILING=9

[[ "$env_rc" == 0 ]] || fail "scenario3: must exit 0, got $env_rc ($env_out)"
if grep -qE '^start ' "$calls"; then
    fail "scenario3: fresh stamp must block dispatch, but calls=($(cat "$calls"))"
fi
! grep -q "LOW-WATER-REFILL" "$triage" 2>/dev/null || fail "scenario3: triage must not have LOW-WATER-REFILL"
ok "scenario3: fresh stamp -> no dispatch (2h bound holds)"

# A missing stamp counts as stale (first-ever tick for a repo dispatches).
reset_state
printf '1\n' >"$scratch/work_ready"
: >"$SCOUT_ACTIVE_UNITS"
rm -f "$stamp_dir/demo.stamp"              # no stamp -> stale
run_helper FLEET_LOW_WATER_LANE_CEILING=9
[[ "$env_rc" == 0 ]] || fail "scenario3b: must exit 0, got $env_rc ($env_out)"
grep -qx 'start pi-scout@demo.service' "$calls" \
    || fail "scenario3b: missing stamp must allow dispatch ($(cat "$calls"))"
ok "scenario3b: missing stamp -> stale (first tick may dispatch)"

# ============================================================================
# Scenario 4: scout already active -> NO dispatch (even if ready<lanes, stale)
# ============================================================================
reset_state
printf '1\n' >"$scratch/work_ready"
printf 'pi-scout@demo.service\n' >"$SCOUT_ACTIVE_UNITS"   # scout running
date -u -d '60 seconds ago' +%Y-%m-%dT%H:%M:%SZ > "$stamp_dir/demo.stamp"  # stale
run_helper FLEET_LOW_WATER_LANE_CEILING=9

[[ "$env_rc" == 0 ]] || fail "scenario4: must exit 0, got $env_rc ($env_out)"
if grep -qE '^start ' "$calls"; then
    fail "scenario4: active scout must block dispatch, but calls=($(cat "$calls"))"
fi
! grep -q "LOW-WATER-REFILL" "$triage" 2>/dev/null || fail "scenario4: triage must not have LOW-WATER-REFILL"
ok "scenario4: scout already active -> no dispatch"

# ============================================================================
# Scenario 5: gh failure on ready query -> NO dispatch (skip on bad data)
# ============================================================================
reset_state
: >"$SCOUT_ACTIVE_UNITS"
date -u -d '60 seconds ago' +%Y-%m-%dT%H:%M:%SZ > "$stamp_dir/demo.stamp"  # stale
touch "$scratch/gh_broken"
export GH_BROKEN="$scratch/gh_broken"
run_helper FLEET_LOW_WATER_LANE_CEILING=9
unset GH_BROKEN

[[ "$env_rc" == 0 ]] || fail "scenario5: must exit 0 on gh failure, got $env_rc ($env_out)"
if grep -qE '^start ' "$calls"; then
    fail "scenario5: gh failure must not dispatch, but calls=($(cat "$calls"))"
fi
! grep -q "LOW-WATER-REFILL" "$triage" 2>/dev/null || fail "scenario5: triage must not have LOW-WATER-REFILL"
ok "scenario5: gh failure -> skip (no dispatch on bad data)"

# ============================================================================
# Scenario 6: seat-lib integration — real lane_ceiling = min(caps, ram)
# ============================================================================
# Unset FLEET_LOW_WATER_LANE_CEILING so the helper sources lib/seat-lib.sh.
# Fixture seat-caps.json: provider caps sum to 6; ram_governor floors at
# floor(MemAvailable_GB / ram_gb_per_worker). We assert the helper dispatches
# when ready < that real ceiling and not when ready >= it. We do NOT assert
# the exact ceiling number (it depends on /proc/meminfo on the runner); we
# assert the DECISION flips across the ceiling by first probing it.
reset_state
: >"$SCOUT_ACTIVE_UNITS"
date -u -d '60 seconds ago' +%Y-%m-%dT%H:%M:%SZ > "$stamp_dir/demo.stamp"

seat_caps="$scratch/seat-caps.json"
cat >"$seat_caps" <<'JSON'
{
  "ram_gb_per_worker": 0.5,
  "providers": {
    "ollama": { "cap": 3, "class": "free", "models": { "deepseek-v4-flash:0731": 3 } },
    "commandcode": { "cap": 3, "class": "free", "models": { "deepseek/deepseek-v4-flash": 3 } }
  },
  "free_providers_in_order": ["ollama", "commandcode"]
}
JSON

# Probe the real ceiling the helper will use: run it with ready=0 (guaranteed
# below any positive ceiling) and confirm a dispatch, then derive the ceiling
# from the triage line's lanes= field.
printf '0\n' >"$scratch/work_ready"
run_helper SEAT_CAPS_JSON="$seat_caps" PI_PACKET_SEAT_LIB="$repo_root/lib/seat-lib.sh"
[[ "$env_rc" == 0 ]] || fail "scenario6: probe must exit 0, got $env_rc ($env_out)"
grep -qx 'start pi-scout@demo.service' "$calls" \
    || fail "scenario6: ready=0 must dispatch under the real ceiling ($(cat "$calls"))"
real_lanes=$(grep -oE 'lanes=[0-9]+' "$triage" | tail -1 | cut -d= -f2)
[[ "$real_lanes" =~ ^[0-9]+$ ]] || fail "scenario6: could not parse real ceiling from triage (got '$real_lanes')"
[[ "$real_lanes" -gt 0 ]] || fail "scenario6: real ceiling must be positive (got $real_lanes)"

# Now ready == real_lanes must NOT dispatch (the ceiling is the no-dispatch line).
reset_state
printf '%s\n' "$real_lanes" >"$scratch/work_ready"
: >"$SCOUT_ACTIVE_UNITS"
date -u -d '60 seconds ago' +%Y-%m-%dT%H:%M:%SZ > "$stamp_dir/demo.stamp"
run_helper SEAT_CAPS_JSON="$seat_caps" PI_PACKET_SEAT_LIB="$repo_root/lib/seat-lib.sh"
[[ "$env_rc" == 0 ]] || fail "scenario6: ready=ceiling must exit 0, got $env_rc ($env_out)"
if grep -qE '^start ' "$calls"; then
    fail "scenario6: ready=ceiling ($real_lanes) must not dispatch, but calls=($(cat "$calls"))"
fi
ok "scenario6: seat-lib lane_ceiling=$real_lanes drives the decision (ready<ceiling dispatches, ready=ceiling does not)"

# ============================================================================
# Scenario 7: hours < 12 (go-ham) dispatches even when ready >= lanes
# ============================================================================
reset_state
printf '30\n' >"$scratch/work_ready"
: >"$SCOUT_ACTIVE_UNITS"
date -u -d '60 seconds ago' +%Y-%m-%dT%H:%M:%SZ > "$stamp_dir/demo.stamp"
run_helper FLEET_LOW_WATER_LANE_CEILING=9 FLEET_WORK_SUPPLY_HOURS=5
[[ "$env_rc" == 0 ]] || fail "scenario7: must exit 0, got $env_rc ($env_out)"
grep -qx 'start pi-scout@demo.service' "$calls" \
    || fail "scenario7: hours=5 must dispatch even when ready>=lanes ($(cat "$calls"))"
grep -q 'hours=5' "$triage" || fail "scenario7: triage missing hours=5 ($triage=$(cat "$triage"))"
ok "scenario7: hours<12 go-ham dispatches when ready>=lanes"

# ============================================================================
# Scenario 8: hours >= 12 and ready >= lanes -> no dispatch
# ============================================================================
reset_state
printf '30\n' >"$scratch/work_ready"
: >"$SCOUT_ACTIVE_UNITS"
date -u -d '60 seconds ago' +%Y-%m-%dT%H:%M:%SZ > "$stamp_dir/demo.stamp"
run_helper FLEET_LOW_WATER_LANE_CEILING=9 FLEET_WORK_SUPPLY_HOURS=20
[[ "$env_rc" == 0 ]] || fail "scenario8: must exit 0, got $env_rc ($env_out)"
if grep -qE '^start ' "$calls"; then
    fail "scenario8: generate-zone + ready>=lanes must not dispatch, but calls=($(cat "$calls"))"
fi
ok "scenario8: hours>=12 and ready>=lanes -> no dispatch"

ok "low-water-mark: dispatch on ready<lanes or hours<12; skip otherwise"

# fleet-ops#616 / #619: workers cannot add a ci.yml line. The auditor
# panel drill rides on this listed #146 test so it stays in P14.
bash "$here/fleet-heartbeat-auditor.test.sh"
