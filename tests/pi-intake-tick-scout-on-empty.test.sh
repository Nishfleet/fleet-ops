#!/usr/bin/env bash
# pi-intake-tick-scout-on-empty.test.sh — event-driven work supply (fleet-ops#4016).
#
# When the intake tick finds zero ready issues for a repo it must start the
# repo's existing pi-scout@<repo>.service (--no-block) instead of waiting for
# the 4-hourly scout timer. Contract:
#   1. ready pool empty + scout unit inactive  -> `systemctl --user start
#      --no-block pi-scout@<repo>.service` is issued exactly once, tick exits 0.
#   2. ready pool empty + scout unit active/activating -> no start (debounce).
#   3. PI_INTAKE_SCOUT_ON_EMPTY=0 -> no start.
#   4. ready pool non-empty -> no start (the normal claim path is untouched).
# The systemctl seam is the existing SYSTEMCTL variable (fleet-ops#1546).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }
[[ -f "$tick" ]] || fail "tick script missing: $tick"

scratch="$(mktemp -d -t pirt-scout-empty.XXXXXX)"
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

# Fake systemctl: records every argv line; answers `show -p ActiveState`
# from $FAKE_SCOUT_STATE so the debounce branch is testable.
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

# $GH_ISSUES is what `gh issue list` returns.
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
    # $1 = repo, $2 = scout ActiveState, $3 = GH issues json, $4 = flag (1/0)
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
        WORK_SUPPLY_CLAIMED_COUNT="0" \
        SEAT_LIB="$stubs" \
        PRECEDENCE_BAND_LIB="$stubs" \
        PRIOR_ART_CLAIM_CHECK="$prior_art_stub" \
        FLEET_ISSUE_REPO="Nishfleet/fleet-ops" \
        SYSTEMCTL="$scratch/bin/fake-systemctl" \
        FAKE_SYSTEMCTL_LOG="$log" \
        FAKE_SCOUT_STATE="$2" \
        GH_ISSUES="$3" \
        PI_INTAKE_SCOUT_ON_EMPTY="$4" \
        bash "$tick" "$1" >"$scratch/out" 2>&1 || fail "tick rc=$? for $1/$2: $(cat "$scratch/out")"
    cat "$log"
}

starts() { grep -cF -- "start --no-block pi-scout@$1.service" || true; }

# 1. empty + inactive -> exactly one start, exit 0
calls="$(run_tick 0509 inactive '[]' 1)"
n="$(printf '%s\n' "$calls" | starts 0509)"
[[ "$n" == "1" ]] || fail "empty+inactive must start pi-scout@0509.service once, got $n: $calls / $(cat "$scratch/out")"
grep -qF 'no ready issues' "$scratch/out" || fail "empty branch must still log 'no ready issues'"
grep -qF 'scout-on-empty: ready=0 for 0509' "$scratch/out" || fail "must log the scout-on-empty start line: $(cat "$scratch/out")"
ok "empty pool + inactive scout -> one --no-block start of pi-scout@0509.service"

# 2. empty + activating -> debounce, no start
calls="$(run_tick 0509 activating '[]' 1)"
n="$(printf '%s\n' "$calls" | starts 0509)"
[[ "$n" == "0" ]] || fail "empty+activating must NOT start the scout (debounce), got $n"
grep -qF 'skip (debounce)' "$scratch/out" || fail "debounce must be logged: $(cat "$scratch/out")"
ok "empty pool + live scout run -> debounced, no start"

# 3. flag off -> no start
calls="$(run_tick 0509 inactive '[]' 0)"
n="$(printf '%s\n' "$calls" | starts 0509)"
[[ "$n" == "0" ]] || fail "PI_INTAKE_SCOUT_ON_EMPTY=0 must NOT start the scout, got $n"
ok "PI_INTAKE_SCOUT_ON_EMPTY=0 -> no start"

# 4. non-empty pool -> no scout start (claim path untouched)
calls="$(run_tick fleet-ops inactive '[{"number":12345,"title":"test claim"}]' 1)"
n="$(printf '%s\n' "$calls" | starts fleet-ops)"
[[ "$n" == "0" ]] || fail "non-empty pool must NOT start the scout, got $n"
ok "non-empty pool -> no scout start"

# Contract pin: the seam uses the SYSTEMCTL variable, not a bare systemctl.
grep -qE '"\$SYSTEMCTL" --user start --no-block "\$unit"' "$tick" \
    || fail "scout_on_empty must start the unit through the SYSTEMCTL seam"
ok "scout_on_empty routes through the SYSTEMCTL seam"

# fleet-ops#4450: the low-water sibling test. The worker App cannot push
# .github/workflows/**, so this (already-listed) test hosts it to keep it in
# the P14 reachable set (p14-test-listing-gate).
bash "$here/pi-intake-tick-scout-low-water.test.sh"
echo "PASS: pi-intake-tick-scout-on-empty"
