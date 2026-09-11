#!/usr/bin/env bash
# tests/pi-intake-rate-limit-precheck-cadence.test.sh
#
# fleet-ops#5616: the gh rate-limit pre-check max-age default must exceed the
# side-car writer cadence. The exporter (fleet-metrics-export.timer,
# OnCalendar=*:0/5) refreshes the state file every ~300s; a max-age of 120s
# made every routine tick trip the stale fail-open branch (98 rows in 6h),
# so the #5489 throttle sat permanently failing open.
#
# Proves, offline:
#   1. tick default max-age >= writer period (grep guard pins the constant).
#   2. With the default max-age, age = one writer period + slack does NOT
#      fire the stale branch (the regression pin).
#   3. age = ~2 writer (abandoned writer) DOES fire the stale branch.
#   4. The stale branch stays loud (fail-open message present when fired).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "tick script missing: $tick"

# --- Grep guard 1: no max-age default below the 300s writer cadence. --------
if grep -E 'PI_INTAKE_GH_RATE_LIMIT_MAX_AGE:-[0-9]+' "$tick" \
    | grep -Ev 'PI_INTAKE_GH_RATE_LIMIT_MAX_AGE:-360' ; then
    fail "reintroduced a max-age default below/other than the writer cadence (must be :-360, writer period 300s + slack): see grep output above"
fi
ok "max-age default is 360s (writer period 300s + 60s slack)"

# --- Grep guard 2: the writer-cadence constant exists and is actionable. ----
grep -q 'gh_rl_pre_writer_period=300' "$tick" \
    || fail "writer-cadence constant gh_rl_pre_writer_period=300 missing from tick"
ok "writer-cadence constant pinned in tick"

scratch="$(mktemp -d -t pirt-rl-cadence.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

stubs="$scratch/seat-lib-stub.sh"
cat >"$stubs" <<'SH'
#!/usr/bin/env bash
total_seat_cap() { echo 8; }
issue_seat_cap() { echo 5; }
pick_seat() { echo "commandcode	deepseek/deepseek-v4-flash		0"; return 0; }
precedence_band_phase() { echo "band"; }
precedence_band_pending_clear() { true; }
precedence_band_pending_starvation_clear() { true; }
precedence_band_is_leverage_issue() { return 1; }
precedence_band_allow_claim() { return 0; }
SH
chmod +x "$stubs"

gh() {
    if [[ "$1" == "issue" && "$2" == "list" ]]; then
        printf '%s\n' '[{"number":12345,"title":"test claim"}]'
        return 0
    fi
    echo "stub gh: $*" >&2
    return 0
}
git() {
    if [[ "$1" == "-C" ]]; then
        shift 2
    fi
    if [[ "$1" == "fetch" ]]; then
        return 0
    fi
    if [[ "$1" == "ls-remote" ]]; then
        printf '%s\t%s\n' '0000000000000000000000000000000000000000' 'refs/heads/claim/issue-12345'
        return 0
    fi
    if [[ "$1" == "push" ]]; then
        return 1
    fi
    echo "stub git: $*" >&2
    return 0
}
systemctl() { echo "inactive"; return 0; }
export -f gh git systemctl

mkdir -p "$scratch/run" "$scratch/.local/bin"
# PRIOR_ART_BIN override (fleet-ops#1250): the tick hard-requires the binary
# by line 241; tests stub it.
cat >"$scratch/prior-art-claim-check-stub" <<'SH'
#!/usr/bin/env bash
# writable -> claim proceeds
exit 0
SH
chmod +x "$scratch/prior-art-claim-check-stub"

write_state() {
    # $1 = age of fetched_at, seconds
    cat >"$scratch/gh-rate-limit.json" <<JSON
{
  "low": 0,
  "remaining": 4800,
  "limit": 5000,
  "reset": $(( $(date +%s) + 3600 )),
  "fetched_at": $(( $(date +%s) - $1 )).0,
  "resources": {"core": {"remaining": 4800, "limit": 5000, "reset": $(( $(date +%s) + 3600 )), "low": 0}}
}
JSON
}

run_tick() {
    local age="$1"
    shift || true
    local -a env_extra=()
    if (($#)); then
        env_extra=("PI_INTAKE_GH_RATE_LIMIT_MAX_AGE=$1")
    fi
    write_state "$age"
    env \
        PATH="$stubs:${PATH}" \
        HOME="$scratch" \
        XDG_RUNTIME_DIR="$scratch/run" \
        PI_INTAKE_LOCKDIR="$scratch" \
        PI_INTAKE_RECONCILER_PROM="$scratch/reconciler" \
        PI_INTAKE_GH_RATE_LIMIT_STATE="$scratch/gh-rate-limit.json" \
        PI_INTAKE_ISSUE_STATE_DIR="$scratch/pi-issues" \
        PRIOR_ART_CLAIM_CHECK="$scratch/prior-art-claim-check-stub" \
        "${env_extra[@]+"${env_extra[@]}"}" \
        FLEET_ISSUE_REPO="Nishfleet/fleet-ops" \
        bash "$tick" fleet-ops 2>&1
}

# Test 2 (acceptance pin): default max-age, age = one writer period + slack
# (350s) must NOT fire the stale branch.
out="$(run_tick 350)"
rc=$?
[[ "$rc" == "0" ]] || fail "age=350 default tick must exit 0, got rc=$rc"
echo "$out" | grep -qF 'pre-check state stale' \
    && fail "age=350 (one writer period + slack) must NOT be stale under default max-age: $out" \
    || true
ok "age=350s (< 360s default) does not fire stale branch"

# Test 3: age = ~2 writer periods (610s) fires the stale branch.
out="$(run_tick 610)"
rc=$?
[[ "$rc" == "0" ]] || fail "age=610 tick must exit 0 (fail-open), got rc=$rc"
echo "$out" | grep -qF 'pre-check state stale' \
    || fail "age=610 (~2 writer periods) must fire stale branch: $out"
ok "age=610s fires stale branch (abandoned writer)"

# Test 4: stale fail-open stays loud (never silent).
echo "$out" | grep -qF 'failing open' \
    || fail "stale branch must stay loud (failing open in journal line): $out"
ok "stale fail-open is loud in output"

# Test 5: explicit env override still honored (age=350, max=200 -> stale).
out="$(run_tick 350 200)"
echo "$out" | grep -qF 'pre-check state stale' \
    || fail "PI_INTAKE_GH_RATE_LIMIT_MAX_AGE=200 with age=350 must fire stale branch: $out"
ok "explicit max-age override honored"

echo "all pi-intake rate-limit precheck cadence tests passed"
