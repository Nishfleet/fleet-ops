#!/usr/bin/env bash
# pi-intake-tick-scout-low-water.test.sh — low-water supply trigger (fleet-ops#4450).
#
# When the end of an intake tick leaves the ready pool at or below the
# measured drain rate, the tick must start the repo's existing
# pi-scout@<repo>.service (--no-block) instead of waiting for the 4h scout
# timer. Contract:
#   1. ready_after < drain_per_hour + scout inactive  -> one `systemctl --user
#      start --no-block pi-scout@<repo>.service`, tick exits 0.
#   2. ready_after < drain_per_hour + scout active/activating -> no start
#      (debounce), "low-water ... skip (debounce)" logged.
#   3. ready_after >= drain_per_hour -> no start (pool can feed workers).
#   4. PI_INTAKE_SCOUT_LOW_WATER=0 -> no start.
# Drain is injected via WORK_SUPPLY_CLAIMED_COUNT (work-supply seam): 96
# claims in a 6h window = 16 issues/hour; 0 claims = the 1/h fallback.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }
[[ -f "$tick" ]] || fail "tick script missing: $tick"

scratch="$(mktemp -d -t pirt-scout-lowwater.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
mkdir -p "$scratch/run" "$scratch/secondary" "$scratch/bin"

stubs="$scratch/seatlib-stub.sh"
cat >"$stubs" <<'SH'
total_seat_cap() { echo 8; }
seat_max_concurrent() { echo 8; }
issue_seat_cap() { echo 5; }
litellm_seat() { echo "commandcode	deepseek/deepseek-v4-flash		0"; return 0; }
precedence_band_phase() { echo "band"; }
precedence_band_pending_clear() { true; }
precedence_band_pending_starvation_clear() { true; }
precedence_band_is_leverage_issue() { return 1; }
precedence_band_allow_claim() { return 0; }
product_first_export_product_ratio() { return 0; }
product_first_is_self_maintenance() { return 1; }
product_first_ratio() { return 1; }
product_first_hold() { return 1; }
SH
prior_art_stub="$scratch/prior-art-claim-check"
printf 'exit 0\n' >"$prior_art_stub"
chmod +x "$prior_art_stub"

cat >"$scratch/bin/fake-systemctl" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_SYSTEMCTL_LOG:?}"
if [[ "$*" == *"show -p ActiveState"* ]]; then
    echo "${FAKE_SCOUT_STATE:-inactive}"
    exit 0
fi
if [[ "$*" == *"is-active"* ]]; then
    echo "inactive"
    exit 3
fi
exit 0
SH
chmod +x "$scratch/bin/fake-systemctl"

cat >"$scratch/gh-rate-limit.json" <<JSON
{"low": 0, "remaining": 5000, "limit": 5000, "resource": "core",
 "reset": $(( $(date +%s) + 3600 )), "fetched_at": $(date +%s)}
JSON

gh() {
    if [[ "$1" == "issue" && "$2" == "list" ]]; then
        printf '%s\n' "${GH_ISSUES:-[]}"
        return 0
    fi
    echo "stub gh: $*" >&2
    return 0
}
git() {
    if [[ "$1" == "-C" ]]; then shift 2; fi
    case "$1" in
        fetch) return 0 ;;
        ls-remote) printf '%s\t%s\n' '0000000000000000000000000000000000000000' 'refs/heads/claim/issue-12345'; return 0 ;;
        push) return 1 ;;
    esac
    echo "stub git: $*" >&2
    return 0
}
export -f gh git

run_tick() {
    # $1 = repo, $2 = scout ActiveState, $3 = GH issues json, $4 = claimed count
    local log="$scratch/systemctl.$RANDOM.log"
    : >"$log"
    env \
        GITHUB_ACTIONS=true \
        PATH="$scratch/bin:${PATH}" \
        HOME="$scratch" \
        XDG_RUNTIME_DIR="$scratch/run" \
        PI_INTAKE_LOCKDIR="$scratch" \
        PI_INTAKE_RECONCILER_PROM="$scratch/reconciler" \
        PI_INTAKE_GH_RATE_LIMIT_STATE="$scratch/gh-rate-limit.json" \
        PI_INTAKE_GH_RATE_LIMIT_MAX_AGE=999999 \
        PI_INTAKE_DEBOUNCE_SEC=0 \
        PI_INTAKE_GH_SECONDARY_STATE_DIR="$scratch/secondary" \
        PI_INTAKE_ISSUE_STATE_DIR="$scratch/pi-issues" \
        PI_INTAKE_WS_LIB="$repo_root/lib/work-supply.sh" \
        WORK_SUPPLY_CLAIMED_COUNT="$4" \
        SEAT_LIB="$stubs" \
        PRECEDENCE_BAND_LIB="$stubs" \
        PRIOR_ART_CLAIM_CHECK="$prior_art_stub" \
        FLEET_ISSUE_REPO="Nishfleet/fleet-ops" \
        SYSTEMCTL="$scratch/bin/fake-systemctl" \
        FAKE_SYSTEMCTL_LOG="$log" \
        FAKE_SCOUT_STATE="$2" \
        GH_ISSUES="$3" \
        bash "$tick" "$1" >"$scratch/out" 2>&1 || fail "tick rc=$? for $1/$2: $(cat "$scratch/out")"
    cat "$log"
}

starts() { grep -cF -- "start --no-block pi-scout@$1.service" || true; }

# 1. ready_after(=1) < drain(16/h via 96 claims) + inactive -> start once
calls="$(run_tick 0509 inactive '[{"number":12345,"title":"low"}]' 96)"
n="$(printf '%s\n' "$calls" | starts 0509)"
[[ "$n" == "1" ]] || fail "low pool below drain must start pi-scout@0509.service once, got $n: $calls / $(cat "$scratch/out")"
grep -qF 'low-water: ready=' "$scratch/out" || fail "must log the low-water line: $(cat "$scratch/out")"
grep -qF 'drain=16' "$scratch/out" || fail "low-water log must show the drain rate: $(cat "$scratch/out")"
ok "low-water: pool below drain -> one --no-block start (drain 16/h)"

# 2. low + scout activating -> debounce, no start
calls="$(run_tick 0509 activating '[{"number":12345,"title":"low"}]' 96)"
n="$(printf '%s\n' "$calls" | starts 0509)"
[[ "$n" == "0" ]] || fail "low+activating must NOT start the scout (debounce), got $n"
grep -qF 'low-water:' "$scratch/out" || fail "low-water debounce must be logged: $(cat "$scratch/out")"
ok "low-water + live scout run -> debounced, no start"

# 3. ready_after >= drain -> no start (pool can feed workers)
# drain=1/h (0 claims fallback); pool of 50 ready issues stays above 1 even
# if this tick claims a few.
pool50=$(jq -n '[range(1;51) | {number:(12000+.), title:("t"+tostring)}]')
calls="$(run_tick 0509 inactive "$pool50" 0)"
n="$(printf '%s\n' "$calls" | starts 0509)"
[[ "$n" == "0" ]] || fail "pool at/above drain must NOT start the scout, got $n"
ok "ready_after >= drain -> no scout start"

# 4. PI_INTAKE_SCOUT_LOW_WATER=0 -> no start
calls="$(PI_INTAKE_SCOUT_LOW_WATER=0 run_tick 0509 inactive '[{"number":12345,"title":"low"}]' 96)"
n="$(printf '%s\n' "$calls" | starts 0509)"
[[ "$n" == "0" ]] || fail "PI_INTAKE_SCOUT_LOW_WATER=0 must NOT start the scout, got $n"
ok "PI_INTAKE_SCOUT_LOW_WATER=0 -> no start"

# Contract pin: routes through the SYSTEMCTL seam, reuses pi-scout@<repo>.
grep -qF '"$SYSTEMCTL" --user start --no-block "$unit"' "$tick" \
    || fail "scout_low_water must start the unit through the SYSTEMCTL seam"
grep -qF 'low-water: ready=' "$tick" \
    || fail "low-water must log the start line with ready + drain"
ok "scout_low_water routes through the SYSTEMCTL seam"
echo "PASS: pi-intake-tick-scout-low-water"
