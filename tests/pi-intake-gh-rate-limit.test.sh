#!/usr/bin/env bash
# tests/pi-intake-gh-rate-limit.test.sh
#
# fleet-ops#1350: pin the GitHub API rate-limit throttle in lib/pi-intake-tick.sh.
#
# Proves, offline:
#   1. pi-intake-tick.sh consults the side-car state file.
#   2. When low=1 the tick holds claims and exits 0.
#   3. When low=0 (or missing/stale state) the tick does NOT hold and continues
#      to attempt claims (we stub the rest of the flow so it does not spawn).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "tick script missing: $tick"

scratch="$(mktemp -d -t pirt-gh-rl.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Stub seat-lib and precedence-band functions. These are sourced by the tick.
stubs="$scratch/seat-lib-stub.sh"
cat >"$stubs" <<'SH'
#!/usr/bin/env bash
total_seat_cap() { echo 8; }
issue_seat_cap() { echo 5; }
pick_seat() { echo "commandcode	deepseek/deepseek-v4-flash		0"; return 0; }
precedence_band_phase() { echo "band"; }
precedence_band_pending_clear() { true; }
precedence_band_is_leverage_issue() { return 1; }
precedence_band_allow_claim() { return 0; }
SH
chmod +x "$stubs"

# Functions beat PATH, so we override gh/git/systemctl in the child bash.
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
        # branch exists -> claim is lost, skip the issue without spawning
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

mkdir -p "$scratch/run"

write_state() {
    local low="$1"
    cat >"$scratch/gh-rate-limit.json" <<JSON
{
  "low": $low,
  "remaining": 5,
  "limit": 30,
  "resource": "search",
  "reset": $(( $(date +%s) + 3600 )),
  "fetched_at": $(date +%s)
}
JSON
}

run_tick() {
    local low="$1"
    local max_age="$2"
    if [[ "$low" == "missing" ]]; then
        rm -f "$scratch/gh-rate-limit.json"
    else
        write_state "$low"
    fi
    env \
        PATH="$stubs:${PATH}" \
        HOME="$scratch" \
        XDG_RUNTIME_DIR="$scratch/run" \
        PI_INTAKE_LOCKDIR="$scratch" \
        PI_INTAKE_RECONCILER_PROM="$scratch/reconciler" \
        PI_INTAKE_GH_RATE_LIMIT_STATE="$scratch/gh-rate-limit.json" \
        PI_INTAKE_GH_RATE_LIMIT_MAX_AGE="$max_age" \
        PI_INTAKE_ISSUE_STATE_DIR="$scratch/pi-issues" \
        SEAT_LIB="$stubs" \
        PRECEDENCE_BAND_LIB="$stubs" \
        FLEET_ISSUE_REPO="Nishfleet/fleet-ops" \
        bash "$tick" fleet-ops 2>&1
}

# Test 1: low=1 -> hold
out="$(run_tick 1 120)"
rc=$?
[[ "$rc" == "0" ]] || fail "low=1 tick must exit 0, got rc=$rc"
echo "$out" | grep -qF 'gh rate-limit low' || fail "low=1 must log gh rate-limit low: $out"
echo "$out" | grep -qF 'holding claims this tick' || fail "low=1 must hold claims: $out"
ok "low=1 holds claims and exits 0"

# Test 2: low=0 -> does not hold (it will ls-remote and skip-claim-lost)
out="$(run_tick 0 120)"
rc=$?
[[ "$rc" == "0" ]] || fail "low=0 tick must exit 0, got rc=$rc"
echo "$out" | grep -qF 'holding claims this tick' && fail "low=0 must NOT hold claims: $out" || true
# fleet-ops#1407: the tick's low=0 claim path mkdirs ISSUE_STATE_DIR. It must
# honor the PI_INTAKE_ISSUE_STATE_DIR override (its own env knob, like
# SEAT_LIB / PI_INTAKE_LOCKDIR) so it writes under scratch, never a
# /home/nish path the GitHub-hosted runner user cannot create under set -e.
[[ -d "$scratch/pi-issues" ]] || fail "low=0 tick must create ISSUE_STATE_DIR under scratch (env override), not /home/nish"
ok "low=0 continues without holding"
ok "low=0 writes ISSUE_STATE_DIR under PI_INTAKE_ISSUE_STATE_DIR (no /home/nish dependency)"

# Test 3: missing state fail-open (no gh sidecar, no claim made because stub ls-remote says branch exists)
out="$(run_tick missing 120)"
rc=$?
[[ "$rc" == "0" ]] || fail "missing state tick must exit 0 (fail-open), got rc=$rc"
echo "$out" | grep -qF 'holding claims this tick' && fail "missing state must NOT hold claims (fail-open): $out" || true
echo "$out" | grep -qF 'gh rate-limit state file missing' || fail "missing state should warn: $out"
ok "missing gh rate-limit state is fail-open"
