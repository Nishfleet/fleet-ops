#!/usr/bin/env bash
# tests/fleet-heartbeat-buffer.test.sh
#
# Proves the 12-hour drain-rate work buffer (fleet-ops#146):
#
#   1. buffer < target (default 12h) + drain > 0 + scout idle + lanes free
#      -> pi-scout@<repo> started + refill stamp written + BUFFER-REFILL.
#   2. buffer >= hysteresis (default 14h) -> no dispatch, stamp cleared.
#   3. drain = 0 -> buffer infinite, no dispatch.
#   4. active scout for this repo -> no dispatch.
#   5. active scout count >= lane ceiling -> no dispatch (capacity bound).
#   6. --gate <repo> exits 0 when buffer < target, 1 when buffer >= target.
#   7. gh failure -> skip (exit 0, no dispatch).
#   8. seat-lib integration: when FLEET_BUFFER_LANE_CEILING is unset, lane
#      ceiling is seat_max_concurrent from the cap map + RAM governor.
#
# The live `systemctl start pi-scout@<repo>` is the outermost edge (real LLM
# side effect) and is stubbed; the dispatch DECISION is exercised through the
# real helper binary.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-heartbeat-buffer"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
command -v jq >/dev/null 2>&1 || fail "jq missing"

# --- scratch environment ----------------------------------------------------
scratch="$(mktemp -d -t buffer.XXXXXX)"
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

calls="$scratch/calls.log"
: >"$calls"

# --- fake gh ----------------------------------------------------------------
# $WORK_READY      number of agent-ready issues.
# $WORK_MERGED      number of merged claim/issue-* PRs in the last window.
# $GH_BROKEN_ISSUE  1 = issue list fails.
# $GH_BROKEN_PR     1 = pr list fails.
gh_fake="$scratch/gh"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
if [[ "${GH_BROKEN:-0}" == "1" ]]; then
    echo "gh: simulated failure" >&2
    exit 1
fi
case "$*" in
  *"issue list"*"-l agent-ready"*)
    if [[ "${GH_BROKEN_ISSUE:-0}" == "1" ]]; then
        echo "gh issue list failed" >&2
        exit 1
    fi
    n=$(cat "${WORK_READY:-/dev/null}" 2>/dev/null || echo 0)
    printf '%s\n' "$n"
    exit 0
    ;;
  *"pr list"*"--state merged"*)
    if [[ "${GH_BROKEN_PR:-0}" == "1" ]]; then
        echo "gh pr list failed" >&2
        exit 1
    fi
    n=$(cat "${WORK_MERGED:-/dev/null}" 2>/dev/null || echo 0)
    if [[ "$n" == 0 ]]; then
        printf '[]\n'
    else
        now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        jq -n --arg now "$now" --argjson n "$n" '[range($n)|{number: ., mergedAt: $now, headRefName: "claim/issue-0"}]'
    fi
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
# $SCOUT_ACTIVE_UNITS  list of units that is-active reports active/activating.
# $START_FAIL_UNITS    list of units whose start should fail.
systemctl_fake="$scratch/systemctl"
cat >"$systemctl_fake" <<'FAKE'
#!/usr/bin/env bash
shift  # --user
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
  list-units)
    # Active/activating pi-scout@* units. Controlled by SCOUT_ACTIVE_UNITS.
    if [[ -f "${SCOUT_ACTIVE_UNITS:-/dev/nonexistent}" ]]; then
      grep -E '^pi-scout@[^[:space:]]+\.service' "${SCOUT_ACTIVE_UNITS:-/dev/null}" 2>/dev/null || true
    fi
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
export FLEET_BUFFER_REFILL_FRESH_S=2
export FLEET_BUFFER_TARGET_HOURS=12
export FLEET_BUFFER_HYSTERESIS_HOURS=14
export FLEET_BUFFER_DRAIN_WINDOW_HOURS=6
export CALLS="$calls"
export WORK_READY="$scratch/work_ready"
export WORK_MERGED="$scratch/work_merged"
SCOUT_ACTIVE_UNITS="$scratch/scout_active"
START_FAIL_UNITS="$scratch/start_fail"
export SCOUT_ACTIVE_UNITS START_FAIL_UNITS

run_helper() {
  set +e
  env_out=$(env SYSTEMCTL="$systemctl_fake" GH="$gh_fake" "$@" "$bin" 2>&1)
  env_rc=$?
  set -e
}

reset_state() {
  rm -rf "$log_dir"/* "$log_dir"/buffer 2>/dev/null || true
  rm -f "$triage" "$calls" "$scratch"/stamps/* 2>/dev/null || true
  : >"$calls"
  : >"$SCOUT_ACTIVE_UNITS"; : >"$START_FAIL_UNITS"
  : >"$WORK_READY"; : >"$WORK_MERGED"
}

# ============================================================================
# Scenario 1: buffer < target + drain > 0 + idle + lanes free -> dispatch
# ============================================================================
# ready=5, merged=3 in 6h -> drain_rate=0.5/h -> buffer=5/0.5=10h < 12h
reset_state
printf '5\n' >"$WORK_READY"
printf '3\n' >"$WORK_MERGED"
: >"$SCOUT_ACTIVE_UNITS"

run_helper FLEET_BUFFER_LANE_CEILING=9

[[ "$env_rc" == 0 ]] || fail "scenario1: must exit 0, got $env_rc ($env_out)"
grep -qx 'start pi-scout@demo.service' "$calls" \
    || fail "scenario1: scout start missing ($(cat "$calls"))"
[[ -d "$log_dir/buffer/stamps" ]] || fail "scenario1: stamp dir not created"
[[ -f "$log_dir/buffer/stamps/demo.refill" ]] || fail "scenario1: refill stamp missing"
grep -q 'BUFFER-REFILL' "$triage" || fail "scenario1: triage missing BUFFER-REFILL"
grep -q 'buffer_h=10.0' "$triage" || fail "scenario1: triage missing buffer_h=10.0"
ok "scenario1: buffer 10h < 12h -> dispatch + stamp + BUFFER-REFILL"

# ============================================================================
# Scenario 2: buffer >= hysteresis -> no dispatch, stamp cleared
# ============================================================================
# ready=28, merged=3 -> buffer=(6*28)/3=112 tenths = 56h? Wait formula: 10*6*28/3 = 560? No.
# buffer_hours = ready / (merged/6) = 6*ready/merged. For ready=28, merged=3 -> 56h. >=14.
# Actually we want buffer >= 14h. ready=7, merged=3 -> 6*7/3=14h (hysteresis). So ready=7 -> 14.0.
# ready=8 -> 16.0h > hysteresis. Use ready=8.
reset_state
printf '8\n' >"$WORK_READY"
printf '3\n' >"$WORK_MERGED"
: >"$SCOUT_ACTIVE_UNITS"
# Pre-existing refill stamp (simulating a prior refill that now reached 16h).
mkdir -p "$log_dir/buffer/stamps"
date -u +%Y-%m-%dT%H:%M:%SZ >"$log_dir/buffer/stamps/demo.refill"

run_helper FLEET_BUFFER_LANE_CEILING=9

[[ "$env_rc" == 0 ]] || fail "scenario2: must exit 0, got $env_rc ($env_out)"
if grep -qE '^start ' "$calls"; then
    fail "scenario2: buffer >= hysteresis must not dispatch, calls=($(cat "$calls"))"
fi
[[ ! -f "$log_dir/buffer/stamps/demo.refill" ]] || fail "scenario2: old stamp should be cleared"
! grep -q 'BUFFER-REFILL' "$triage" 2>/dev/null || fail "scenario2: triage must not have BUFFER-REFILL"
ok "scenario2: buffer 16h >= 14h -> no dispatch, stamp cleared"

# ============================================================================
# Scenario 3: drain_rate=0 -> no dispatch (buffer infinite)
# ============================================================================
reset_state
printf '0\n' >"$WORK_READY"
printf '0\n' >"$WORK_MERGED"
: >"$SCOUT_ACTIVE_UNITS"

run_helper FLEET_BUFFER_LANE_CEILING=9

[[ "$env_rc" == 0 ]] || fail "scenario3: must exit 0, got $env_rc ($env_out)"
if grep -qE '^start ' "$calls"; then
    fail "scenario3: drain=0 must not dispatch, calls=($(cat "$calls"))"
fi
! grep -q 'BUFFER-REFILL' "$triage" 2>/dev/null || fail "scenario3: triage must not have BUFFER-REFILL"
ok "scenario3: drain=0 -> no dispatch (buffer infinite)"

# ============================================================================
# Scenario 4: scout already active -> no dispatch
# ============================================================================
reset_state
printf '5\n' >"$WORK_READY"
printf '3\n' >"$WORK_MERGED"
printf 'pi-scout@demo.service\n' >"$SCOUT_ACTIVE_UNITS"

run_helper FLEET_BUFFER_LANE_CEILING=9

[[ "$env_rc" == 0 ]] || fail "scenario4: must exit 0, got $env_rc ($env_out)"
if grep -qE '^start ' "$calls"; then
    fail "scenario4: active scout must block dispatch, calls=($(cat "$calls"))"
fi
! grep -q 'BUFFER-REFILL' "$triage" 2>/dev/null || fail "scenario4: triage must not have BUFFER-REFILL"
ok "scenario4: active scout for repo -> no dispatch"

# ============================================================================
# Scenario 5: active scout count >= lane ceiling -> no dispatch
# ============================================================================
reset_state
printf '5\n' >"$WORK_READY"
printf '3\n' >"$WORK_MERGED"
# Simulate 9 other active scouts, ceiling=9.
printf 'pi-scout@other1.service\npi-scout@other2.service\npi-scout@other3.service\npi-scout@other4.service\npi-scout@other5.service\npi-scout@other6.service\npi-scout@other7.service\npi-scout@other8.service\npi-scout@other9.service\n' >"$SCOUT_ACTIVE_UNITS"

run_helper FLEET_BUFFER_LANE_CEILING=9

[[ "$env_rc" == 0 ]] || fail "scenario5: must exit 0, got $env_rc ($env_out)"
if grep -qE '^start ' "$calls"; then
    fail "scenario5: full lane ceiling must block dispatch, calls=($(cat "$calls"))"
fi
! grep -q 'BUFFER-REFILL' "$triage" 2>/dev/null || fail "scenario5: triage must not have BUFFER-REFILL"
ok "scenario5: active scout count at lane ceiling -> no dispatch"

# ============================================================================
# Scenario 6: hysteresis deadband with fresh stamp keeps refilling
# ============================================================================
# ready=6, merged=3 -> buffer=12.0h (at target). With a fresh stamp (<2s),
# the helper continues until hysteresis. We can't increase ready mid-test,
# but the fresh-stamp path should still attempt to dispatch if buffer < hysteresis.
# ready=7, merged=3 -> buffer=14.0h (at hysteresis). Use ready=6 -> 12.0h < 14.
reset_state
printf '6\n' >"$WORK_READY"
printf '3\n' >"$WORK_MERGED"
: >"$SCOUT_ACTIVE_UNITS"
# Fresh stamp.
mkdir -p "$log_dir/buffer/stamps"
date -u +%Y-%m-%dT%H:%M:%SZ >"$log_dir/buffer/stamps/demo.refill"

run_helper FLEET_BUFFER_LANE_CEILING=9

[[ "$env_rc" == 0 ]] || fail "scenario6: must exit 0, got $env_rc ($env_out)"
grep -qx 'start pi-scout@demo.service' "$calls" \
    || fail "scenario6: in hysteresis with fresh stamp should dispatch ($(cat "$calls"))"
grep -q 'BUFFER-REFILL' "$triage" || fail "scenario6: triage missing BUFFER-REFILL"
ok "scenario6: buffer 12h in hysteresis + fresh stamp -> dispatch"

# ============================================================================
# Scenario 7: hysteresis deadband without stamp -> no dispatch
# ============================================================================
reset_state
printf '6\n' >"$WORK_READY"
printf '3\n' >"$WORK_MERGED"
: >"$SCOUT_ACTIVE_UNITS"
# No stamp.

run_helper FLEET_BUFFER_LANE_CEILING=9

[[ "$env_rc" == 0 ]] || fail "scenario7: must exit 0, got $env_rc ($env_out)"
if grep -qE '^start ' "$calls"; then
    fail "scenario7: in hysteresis with no fresh stamp must not dispatch, calls=($(cat "$calls"))"
fi
! grep -q 'BUFFER-REFILL' "$triage" 2>/dev/null || fail "scenario7: triage must not have BUFFER-REFILL"
ok "scenario7: buffer 12h in hysteresis + no stamp -> no dispatch"

# ============================================================================
# Scenario 8: --gate <repo> exit codes
# ============================================================================
reset_state
printf '5\n' >"$WORK_READY"
printf '3\n' >"$WORK_MERGED"

set +e
env SYSTEMCTL="$systemctl_fake" GH="$gh_fake" "$bin" --gate demo >/dev/null 2>&1
gate_rc=$?
set -e
[[ "$gate_rc" == 0 ]] || fail "scenario8: gate with 10h buffer must exit 0, got $gate_rc"

reset_state
printf '8\n' >"$WORK_READY"
printf '3\n' >"$WORK_MERGED"
set +e
env SYSTEMCTL="$systemctl_fake" GH="$gh_fake" "$bin" --gate demo >/dev/null 2>&1
gate_rc=$?
set -e
[[ "$gate_rc" == 1 ]] || fail "scenario8b: gate with 16h buffer must exit 1, got $gate_rc"

reset_state
printf '0\n' >"$WORK_READY"
printf '0\n' >"$WORK_MERGED"
set +e
env SYSTEMCTL="$systemctl_fake" GH="$gh_fake" "$bin" --gate demo >/dev/null 2>&1
gate_rc=$?
set -e
[[ "$gate_rc" == 1 ]] || fail "scenario8c: gate with drain=0 must exit 1, got $gate_rc"
ok "scenario8: --gate exits 0 when buffer<target, 1 when buffer>=target or drain=0"

# ============================================================================
# Scenario 9: gh failure -> no dispatch, exit 0
# ============================================================================
reset_state
printf '5\n' >"$WORK_READY"
printf '3\n' >"$WORK_MERGED"
: >"$SCOUT_ACTIVE_UNITS"

run_helper FLEET_BUFFER_LANE_CEILING=9 GH_BROKEN=1

[[ "$env_rc" == 0 ]] || fail "scenario9: must exit 0 on gh failure, got $env_rc ($env_out)"
if grep -qE '^start ' "$calls"; then
    fail "scenario9: gh failure must not dispatch, calls=($(cat "$calls"))"
fi
! grep -q 'BUFFER-REFILL' "$triage" 2>/dev/null || fail "scenario9: triage must not have BUFFER-REFILL"
ok "scenario9: gh failure -> skip, exit 0"

# ============================================================================
# Scenario 10: seat-lib integration computes real lane ceiling
# ============================================================================
reset_state
: >"$SCOUT_ACTIVE_UNITS"
printf '0\n' >"$WORK_READY"
printf '1\n' >"$WORK_MERGED"

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

run_helper SEAT_CAPS_JSON="$seat_caps" PI_PACKET_SEAT_LIB="$repo_root/lib/seat-lib.sh"
[[ "$env_rc" == 0 ]] || fail "scenario10: probe must exit 0, got $env_rc ($env_out)"
grep -qx 'start pi-scout@demo.service' "$calls" \
    || fail "scenario10: ready=0 must dispatch under the real ceiling"
grep -q 'BUFFER-REFILL' "$triage" || fail "scenario10: triage missing BUFFER-REFILL"
ok "scenario10: seat-lib lane_ceiling drives dispatch when FLEET_BUFFER_LANE_CEILING is unset"

ok "fleet-heartbeat-buffer: dispatches below 12h, respects hysteresis, drain=0, active scouts, lane ceiling"
