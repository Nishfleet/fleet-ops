#!/usr/bin/env bash
# tests/repair-rung-disarm.test.sh
#
# fleet-ops#4820: the #4639 repair rung had an arm condition and no disarm
# that survived a healthy ledger with remaining-slot COUNT=0. This file
# is the issue's required new test: fails before the latch fix, passes after.
#
# Accept:
#   1. Arm, then pick-seat returns a seat for 2 ticks (COUNT stays 0) ->
#      REPAIR-RUNG disarmed and the next tick does not skip non-critical-path.
#   2. Rung armed + product repo has agent-ready work -> product-reserve
#      claim slot, or an explicit logged reason.
#   3. measure.sh prints repair_rung=armed|off ticks=<n>.
#
# Hosted by tests/pi-intake-run.test.sh (CI already lists that file).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"
measure="$repo_root/measure.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"
[[ -f "$measure" ]] || fail "measure.sh missing"

# --- pins ---
grep -qF 'PI_INTAKE_REPAIR_RUNG_DISARM_AFTER="${PI_INTAKE_REPAIR_RUNG_DISARM_AFTER:-2}"' "$tick" \
    || fail "DISARM_AFTER default 2 missing"
grep -qF 'REPAIR-RUNG disarmed:' "$tick" || fail "disarmed log missing"
grep -qF 'REPAIR-RUNG product-reserve:' "$tick" || fail "product-reserve log missing"
grep -qF 'WORKER_PROMPT="${PI_INTAKE_WORKER_PROMPT:-' "$tick" \
    || fail "WORKER_PROMPT must be overridable (CI has no /home/nish/.pi worker.md)"
grep -qF 'repair_rung=armed' "$measure" || fail "measure.sh armed line missing"
grep -qF 'repair_rung=off' "$measure" || fail "measure.sh off line missing"
grep -qF 'repair_rung_disarm_count()' "$tick" \
    && fail "repair_rung_disarm_count is unused and trips SC2317 on P14"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "$tick" || fail "shellcheck not clean on $tick"
fi
ok "pins: disarm log, product-reserve, measure.sh repair_rung line, worker.md override"

scratch="$(mktemp -d -t repair-rung-disarm.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

stubs="$scratch/seatlib-stub.sh"
cat >"$stubs" <<'SH'
#!/usr/bin/env bash
total_seat_cap() { echo 8; }
issue_seat_cap() { echo 5; }
load_seat_caps() { return 0; }
worker_memory_for_difficulty() { return 1; }
worker_env_for_repo() { return 1; }
litellm_seat() {
    if [[ "${PICK_SEAT_COUNT_SLOTS:-0}" == "1" ]]; then
        echo "${STUB_LIGHT_SLOTS:-0}"
        return 0
    fi
    if [[ "${STUB_HEAVY:-0}" == "1" ]]; then
        printf 'cursor\tcursor-grok-4.6-high\n'
        return 0
    fi
    return 1
}
precedence_band_phase() { echo "band"; }
precedence_band_pending_clear() { true; }
precedence_band_pending_starvation_clear() { true; }
precedence_band_is_leverage_issue() { return 1; }
precedence_band_allow_claim() { echo "allow-repair-rung"; return 0; }
product_first_export_product_ratio() { return 0; }
product_first_is_self_maintenance() { return 1; }
product_first_ratio() { echo "0.1"; }
product_first_hold() { return 1; }
repo_is_product() { [[ "${1:-}" == "0509" ]]; }
SH
chmod +x "$stubs"

prior_art_stub="$scratch/prior-art-claim-check"
cat >"$prior_art_stub" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$prior_art_stub"

write_rl() {
    cat >"$scratch/gh-rate-limit.json" <<JSON
{
  "low": 0,
  "remaining": 3000,
  "limit": 5000,
  "resource": "core",
  "reset": $(( $(date +%s) + 3600 )),
  "fetched_at": $(date +%s)
}
JSON
}
write_rl

gh() {
    if [[ "$1" == "issue" && "$2" == "list" ]]; then
        local repo="" i j
        for ((i=1; i<=$#; i++)); do
            if [[ "${!i}" == "-R" ]]; then
                j=$((i+1))
                repo="${!j}"
            fi
        done
        case "$repo" in
            *0509*)
                printf '%s\n' '[{"number":4278,"title":"product-work","labels":[{"name":"agent-ready"}]}]'
                ;;
            *)
                printf '%s\n' '[{"number":4639,"title":"seat deadlock","labels":[{"name":"agent-ready"},{"name":"critical-path"}]},{"number":4820,"title":"ordinary-work","labels":[{"name":"agent-ready"}]}]'
                ;;
        esac
        return 0
    fi
    return 0
}
git() {
    if [[ "$1" == "-C" ]]; then shift 2; fi
    if [[ "$1" == "fetch" || "$1" == "ls-remote" || "$1" == "push" ]]; then
        return 0
    fi
    return 0
}
systemctl() { echo "inactive"; return 0; }
export -f gh git systemctl

printf 'test-worker-prompt\n' >"$scratch/worker.md"

run_tick() {
    local repo="${1:-fleet-ops}"
    mkdir -p "$scratch/secondary" "$scratch/run" "$scratch/pi-issues" "$scratch/umbrella"
    env \
        GITHUB_ACTIONS=true \
        HOME="$scratch" \
        XDG_RUNTIME_DIR="$scratch/run" \
        PI_INTAKE_LOCKDIR="$scratch" \
        PI_INTAKE_DEBOUNCE_SEC=0 \
        PI_INTAKE_RECONCILER_PROM="$scratch/reconciler" \
        PI_INTAKE_UMBRELLA_PROM="$scratch/umbrella/fleet-umbrella-dispatch" \
        PI_INTAKE_CLAIMS_LOG="$scratch/claims.log" \
        PI_INTAKE_WORKER_PROMPT="$scratch/worker.md" \
        PI_INTAKE_GH_RATE_LIMIT_STATE="$scratch/gh-rate-limit.json" \
        PI_INTAKE_GH_RATE_LIMIT_MAX_AGE=120 \
        PI_INTAKE_GH_SECONDARY_STATE_DIR="$scratch/secondary" \
        PI_INTAKE_ISSUE_STATE_DIR="$scratch/pi-issues" \
        PI_INTAKE_REPAIR_RUNG_STATE="${PI_INTAKE_REPAIR_RUNG_STATE:-$scratch/repair-rung-state}" \
        PI_INTAKE_SCOUT_ON_EMPTY=0 \
        PI_INTAKE_SCOUT_LOW_WATER=0 \
        SEAT_LIB="$stubs" \
        PRECEDENCE_BAND_LIB="$stubs" \
        PRIOR_ART_CLAIM_CHECK="$prior_art_stub" \
        STUB_LIGHT_SLOTS="${STUB_LIGHT_SLOTS:-0}" \
        STUB_HEAVY="${STUB_HEAVY:-0}" \
        FLEET_ISSUE_REPO="Nishfleet/${repo}" \
        bash "$tick" "$repo" 2>&1
}

# --- accept 1: COUNT stays 0, pick-seat returns a seat for 2 ticks -> disarm ---
state1="$scratch/repair-rung-state-latch"
rm -f "$state1"
export PI_INTAKE_REPAIR_RUNG_STATE="$state1"

out1="$(STUB_LIGHT_SLOTS=0 STUB_HEAVY=0 run_tick fleet-ops)" || true
echo "$out1" | grep -qF 'holding claims this tick' \
    || fail "latch tick 1 must hold, got: $out1"
ok "latch tick 1: hold"

out2="$(STUB_LIGHT_SLOTS=0 STUB_HEAVY=0 run_tick fleet-ops)" || true
echo "$out2" | grep -qF 'REPAIR-RUNG armed' \
    || fail "latch tick 2 must arm, got: $out2"
echo "$out2" | grep -qF 'skipped-repair-rung (rung claims critical-path fleet-ops only' \
    || fail "latch tick 2 must skip ordinary-work, got: $out2"
ok "latch tick 2: armed, ordinary-work skipped"

# Live latch: COUNT stays 0, but pick-seat now returns a seat.
out3="$(STUB_LIGHT_SLOTS=0 STUB_HEAVY=1 run_tick fleet-ops)" || true
echo "$out3" | grep -qF 'REPAIR-RUNG recovery 1/2' \
    || fail "latch tick 3 COUNT=0 with a seat must be recovery 1/2, got: $out3"
echo "$out3" | grep -qF 'REPAIR-RUNG disarmed' \
    && fail "latch tick 3 must not disarm yet, got: $out3"
ok "latch tick 3: recovery 1/2 while COUNT=0"

out4="$(STUB_LIGHT_SLOTS=0 STUB_HEAVY=1 run_tick fleet-ops)" || true
echo "$out4" | grep -qF 'REPAIR-RUNG disarmed' \
    || fail "latch tick 4 second usable-seat tick must disarm, got: $out4"
echo "$out4" | grep -qF 'cursor	cursor-grok-4.6-high' \
    || fail "disarm log must name the clearing seat, got: $out4"
ok "latch tick 4: disarmed (COUNT still 0)"

out5="$(STUB_LIGHT_SLOTS=0 STUB_HEAVY=1 run_tick fleet-ops)" || true
echo "$out5" | grep -qF 'skipped-repair-rung (rung claims critical-path fleet-ops only' \
    && fail "tick after disarm must not skip ordinary-work, got: $out5"
ok "latch tick 5: non-critical-path is claimable after disarm"

# --- accept 2: product-reserve while armed ---
state2="$scratch/repair-rung-state-product"
rm -f "$state2"
export PI_INTAKE_REPAIR_RUNG_STATE="$state2"

STUB_LIGHT_SLOTS=0 STUB_HEAVY=0 run_tick fleet-ops >/dev/null || true
out_arm="$(STUB_LIGHT_SLOTS=0 STUB_HEAVY=0 run_tick fleet-ops)" || true
echo "$out_arm" | grep -qF 'REPAIR-RUNG armed' \
    || fail "product drill must start from an armed rung, got: $out_arm"

# No seat on the product tick: explicit reason, never the old hold-and-exit.
out_p0="$(STUB_LIGHT_SLOTS=0 STUB_HEAVY=0 run_tick 0509)" || true
echo "$out_p0" | grep -qF 'holding claims this tick' \
    && fail "armed product tick must not hold/exit, got: $out_p0"
echo "$out_p0" | grep -qF 'REPAIR-RUNG product-reserve' \
    || fail "armed product tick must log product-reserve, got: $out_p0"
echo "$out_p0" | grep -qF 'pick-seat returned empty' \
    || fail "no-seat product tick must log why, got: $out_p0"
ok "product tick, no seat: explicit reason, not a hold"

# Fresh arm, then a seat on the product tick: grant a claim slot.
state3="$scratch/repair-rung-state-product-seat"
rm -f "$state3"
export PI_INTAKE_REPAIR_RUNG_STATE="$state3"
STUB_LIGHT_SLOTS=0 STUB_HEAVY=0 run_tick fleet-ops >/dev/null || true
STUB_LIGHT_SLOTS=0 STUB_HEAVY=0 run_tick fleet-ops >/dev/null || true
out_p1="$(STUB_LIGHT_SLOTS=0 STUB_HEAVY=1 run_tick 0509)" || true
echo "$out_p1" | grep -qF 'holding claims this tick' \
    && fail "armed product tick with a seat must not hold, got: $out_p1"
echo "$out_p1" | grep -qF 'REPAIR-RUNG product-reserve' \
    || fail "armed product tick with a seat must log product-reserve, got: $out_p1"
ok "product tick with a seat: reserve, not a hold"

# --- accept 3: measure.sh prints the rung state ---
mkdir -p "$scratch/sessions"
printf '7 0\n' >"$scratch/measure-armed"
meas_armed="$(
    PI_INTAKE_REPAIR_RUNG_STATE="$scratch/measure-armed" \
    PI_INTAKE_REPAIR_RUNG_AFTER=2 \
    FLEET_SESSIONS_DIR="$scratch/sessions" \
    MEASURE_REPOS="" \
    bash "$measure" 2>/dev/null || true
)"
echo "$meas_armed" | grep -qE '^repair_rung=armed ticks=7$' \
    || fail "measure.sh must print repair_rung=armed ticks=7, got: $meas_armed"
ok "measure.sh armed: repair_rung=armed ticks=7"

printf '0 0\n' >"$scratch/measure-off"
meas_off="$(
    PI_INTAKE_REPAIR_RUNG_STATE="$scratch/measure-off" \
    PI_INTAKE_REPAIR_RUNG_AFTER=2 \
    FLEET_SESSIONS_DIR="$scratch/sessions" \
    MEASURE_REPOS="" \
    bash "$measure" 2>/dev/null || true
)"
echo "$meas_off" | grep -qE '^repair_rung=off ticks=0$' \
    || fail "measure.sh must print repair_rung=off ticks=0, got: $meas_off"
ok "measure.sh off: repair_rung=off ticks=0"

meas_missing="$(
    PI_INTAKE_REPAIR_RUNG_STATE="$scratch/no-such-rung-state" \
    PI_INTAKE_REPAIR_RUNG_AFTER=2 \
    FLEET_SESSIONS_DIR="$scratch/sessions" \
    MEASURE_REPOS="" \
    bash "$measure" 2>/dev/null || true
)"
echo "$meas_missing" | grep -qE '^repair_rung=off ticks=0$' \
    || fail "missing state file must print off ticks=0, got: $meas_missing"
ok "measure.sh missing state: repair_rung=off ticks=0"

echo ""
echo "ALL OK: repair rung disarm (fleet-ops#4820)"
