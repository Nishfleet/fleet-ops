#!/usr/bin/env bash
# tests/pi-intake-tick-seat-slot-gate.test.sh
#
# fleet-ops#3732: replay drill for the usable-seat-slot gate in
# lib/pi-intake-tick.sh. Live incident 2026-09-05: the tick claimed 12
# cap-exempt critical-path issues in 4 min while the ONLY usable seat
# (devin/glm-5-2) was already at its learned cap 2. The capacity `slots`
# math counts RAM/config headroom and the heavy gate (pick_seat need_capable=1)
# proves only that ONE seat is pickable — an AIMD probe or a seat-floor
# fail-open can satisfy it even when no real slot is free. Every spawned
# unit died on NO USABLE SEAT, the claims were released, and reclaim
# counters climbed toward the re-claim-cap block.
#
# The fix: usable_light_slots() in seat-lib.sh sums
# max(0, effective_cap - active) over exactly the seats a light pick_seat
# would accept (learned caps/AIMD + benches honoured, probe headroom NOT
# counted). The tick holds all claims when the count is 0 and caps claims
# at min(slots, usable) otherwise.
#
# This test drives the REAL tick against the REAL seat-lib on a fixture
# seat map (scratch models.json + seat-caps.json + learned-caps.json +
# active-seats registry); only gh/git/systemctl and the precedence-band /
# prior-art organs are stubbed.
#
# Proves:
#   1. The gate wiring exists (usable_light_slots call + required hold line).
#   2. REPLAY A — the incident: one usable seat at its learned cap (2/2),
#      two agent-ready issues -> 0 claims and the exact gate line
#      "holding claims this tick — gate: no usable seat slot".
#   3. REPLAY B — same map with one free slot (1/2) -> exactly 1 claim,
#      the second issue is skipped-capacity.
#   4. usable_light_slots returns the raw counts (0 and 1) directly.
#   5. shellcheck is clean on both touched files.
#
# Not listed in .github/workflows/ci.yml: the nishfleet-worker GitHub App
# cannot push .github/workflows/** (fleet-ops#2772 precedent). Hosted from
# tests/pi-intake-tick-seat-gate.test.sh (already reachable via
# pi-intake-run.test.sh -> ci.yml); a human with workflow scope can add the
# direct ci.yml line later.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"
seatlib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"
[[ -f "$seatlib" ]] || fail "lib/seat-lib.sh missing"
command -v jq >/dev/null || fail "jq required"
command -v python3 >/dev/null || fail "python3 required (spec gate)"

# === Test 1: gate wiring present ===
grep -qF 'usable_light_slots' "$seatlib" \
    || fail "usable_light_slots missing from seat-lib.sh"
grep -qF 'usable_light=$(usable_light_slots "$_tick_privacy"' "$tick" \
    || fail "tick does not call usable_light_slots"
grep -qF 'holding claims this tick — gate: no usable seat slot' "$tick" \
    || fail "required hold line missing from tick"
grep -qF 'slots=$usable_light' "$tick" \
    || fail "tick does not cap slots at the usable count"
ok "Test 1: gate wiring present (counter + hold line + min() cap)"

# --- fixture -----------------------------------------------------------
scratch="$(mktemp -d -t pi3732-slot-gate.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
mkdir -p "$scratch/run" "$scratch/ledger" "$scratch/secondary" \
    "$scratch/pi-issues" "$scratch/pi-packet/active-seats" \
    "$scratch/pi-packet/attempts" "$scratch/stubbin"

# Seat map: ONE provider (devin), ONE seat (glm-5-2) — the incident shape.
# Model declared cap 2 with a probe ceiling of 4 (a ceiling above declared
# is required for model-level learned state to bind at all — see
# effective_model_cap's early return when ceiling <= declared). The AIMD
# learned cap is 2 under a live bench, so effective_model_cap returns 2 —
# "at its learned cap" means the learned value binds, not a declared one.
cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "devin": {
      "models": [ { "id": "glm-5-2", "cost": { "input": 0 } } ]
    }
  }
}
JSON

cat >"$scratch/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 0.25,
  "free_providers_in_order": [],
  "providers": {
    "devin": { "cap": 4, "class": "prepaid-quota",
               "models": { "glm-5-2": { "cap": 2, "max_probe_ceiling": 4 } } }
  }
}
JSON

# Learned cap 2 with a live bench -> effective_model_cap = 2 (the learned
# value binds while benched; the declared floor applies only once the
# bench expires).
future_bench="$(date -u -d "+2 hours" +%Y-%m-%dT%H:%M:%SZ)"
jq -nc --arg bu "$future_bench" \
    '{providers:{"devin/glm-5-2":{learned_cap:2,last_result:"backoff",bench_until:$bu}}}' \
    > "$scratch/learned-caps.json"
: > "$scratch/learned-caps-audit.log"

cat >"$scratch/repo-privacy.json" <<'JSON'
{ "default_policy": "private", "public": ["fleet-ops"], "private": [] }
JSON

printf 'worker prompt fixture\n' > "$scratch/worker.md"

# Precedence-band stub: neutral — never holds, never surge-skips.
cat >"$scratch/band-stub.sh" <<'SH'
precedence_band_phase() { echo "post"; }
precedence_band_pending_clear() { return 0; }
precedence_band_pending_starvation_clear() { return 0; }
precedence_band_is_leverage_issue() { return 1; }
precedence_band_allow_claim() { echo "allow-band-normal"; return 0; }
product_first_export_product_ratio() { return 0; }
product_first_is_self_maintenance() { return 0; }
product_first_ratio() { return 1; }
product_first_hold() { return 1; }
SH

cat >"$scratch/prior-art-claim-check" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$scratch/prior-art-claim-check"

# Two agent-ready issues, both light.
cat >"$scratch/issues.json" <<'JSON'
[
  {"number":101,"title":"seat-slot drill issue A","labels":[{"name":"agent-ready"}]},
  {"number":102,"title":"seat-slot drill issue B","labels":[{"name":"agent-ready"}]}
]
JSON
printf 'Fix the widget.\n\n- required: keep the change small\n' > "$scratch/issue-body.txt"

# gh/git/systemctl are functions so they beat PATH inside the tick child.
gh() {
    case "${1:-}" in
        issue)
            case "${2:-}" in
                list) cat "$GH_STUB_DIR/issues.json"; return 0 ;;
                view)
                    if [[ "$*" == *"--json body"* ]]; then cat "$GH_STUB_DIR/issue-body.txt"; return 0; fi
                    if [[ "$*" == *"--json comments"* ]]; then printf '\n'; return 0; fi
                    if [[ "$*" == *"--json labels"* ]]; then printf '["agent-ready"]\n'; return 0; fi
                    return 0 ;;
                edit|comment) return 0 ;;
            esac
            return 0 ;;
        api) printf '[]\n'; return 0 ;;
    esac
    return 0
}
git() {
    while [[ "${1:-}" == "-C" || "${1:-}" == "-c" ]]; do shift 2; done
    case "${1:-}" in
        fetch) return 0 ;;
        ls-remote)
            local ref="${!#}"
            if [[ -f "$GIT_STUB_DIR/branches" ]] && grep -qxF "$ref" "$GIT_STUB_DIR/branches" 2>/dev/null; then
                printf '0000000000000000000000000000000000000000\t%s\n' "$ref"
            fi
            return 0 ;;
        push)
            local arg
            for arg in "$@"; do
                case "$arg" in
                    :*) : ;;  # delete refspec — never records existence
                    *:refs/heads/*) printf '%s\n' "${arg#*:}" >> "$GIT_STUB_DIR/branches" ;;
                esac
            done
            return 0 ;;
    esac
    return 0
}
systemctl() {
    case "${1:-}/${2:-}" in
        --user/is-active)
            [[ -f "$SYSC_STUB_DIR/live-${3:-}" ]] && echo active || echo inactive ;;
        --user/start)
            : > "$SYSC_STUB_DIR/live-${4:-}" ;;
        --user/reset-failed|--user/daemon-reload) : ;;
    esac
    return 0
}
export GH_STUB_DIR="$scratch" GIT_STUB_DIR="$scratch" SYSC_STUB_DIR="$scratch"
export -f gh git systemctl

seed_active() {
    # $1 = number of active workers to register on devin/glm-5-2.
    rm -f "$scratch/pi-packet/active-seats"/*.json 2>/dev/null || true
    local i
    for (( i = 0; i < $1; i++ )); do
        jq -nc --arg u "pi-issue-fleet-ops-seed$i" \
            '{provider:"devin", model:"glm-5-2", unit:$u, started_at:"2026-09-05T00:00:00Z"}' \
            > "$scratch/pi-packet/active-seats/pi-issue-fleet-ops-seed$i.json"
    done
}

run_tick() {
    env \
        GITHUB_ACTIONS=true \
        HOME="$scratch" \
        XDG_RUNTIME_DIR="$scratch/run" \
        PI_INTAKE_LOCKDIR="$scratch/lock" \
        PI_INTAKE_DEBOUNCE_SEC=0 \
        PI_INTAKE_RECONCILER_PROM="$scratch/reconciler" \
        PI_INTAKE_UMBRELLA_PROM="$scratch/umbrella" \
        PI_INTAKE_GH_RATE_LIMIT_STATE="$scratch/gh-rate-limit.json" \
        PI_INTAKE_GH_SECONDARY_STATE_DIR="$scratch/secondary" \
        PI_INTAKE_ISSUE_STATE_DIR="$scratch/pi-issues" \
        PI_INTAKE_CLAIMS_LOG="$scratch/claims.log" \
        PI_INTAKE_WORKER_PROMPT="$scratch/worker.md" \
        SEAT_LIB="$seatlib" \
        PRECEDENCE_BAND_LIB="$scratch/band-stub.sh" \
        PRIOR_ART_CLAIM_CHECK="$scratch/prior-art-claim-check" \
        PI_MODELS_JSON="$scratch/models.json" \
        SEAT_CAPS_JSON="$scratch/seat-caps.json" \
        REPO_PRIVACY_JSON="$scratch/repo-privacy.json" \
        PI_PACKET_STATE="$scratch/pi-packet" \
        PI_ISSUES_DIR="$scratch/pi-issues" \
        PI_SEAT_HEALTH_LEDGER_DIR="$scratch/ledger" \
        LEARNED_CAPS_JSON="$scratch/learned-caps.json" \
        LEARNED_CAPS_AUDIT="$scratch/learned-caps-audit.log" \
        SEAT_YIELD_JSON="$scratch/seat-yield.json" \
        QUALITY_ROUTING_JSON="$scratch/quality-routing.json" \
        QUALITY_SCOREBOARD_JSON="$scratch/quality-scoreboard.json" \
        PI_SEAT_LIB_CHECK_SYSTEMD=0 \
        PI_SEAT_CREDENTIAL_PRECHECK=0 \
        FLEET_ISSUE_REPO="Nishfleet/fleet-ops" \
        bash "$tick" fleet-ops 2>&1
}

count_claims() { grep -c 'claimed+spawned' <<<"$1" || true; }

# === Test 4 first (unit-level sanity so a drill failure is diagnosable) ==
seed_active 2
n0=$(env \
    HOME="$scratch" \
    PI_MODELS_JSON="$scratch/models.json" \
    SEAT_CAPS_JSON="$scratch/seat-caps.json" \
    REPO_PRIVACY_JSON="$scratch/repo-privacy.json" \
    PI_PACKET_STATE="$scratch/pi-packet" \
    PI_ISSUES_DIR="$scratch/pi-issues" \
    PI_SEAT_HEALTH_LEDGER_DIR="$scratch/ledger" \
    LEARNED_CAPS_JSON="$scratch/learned-caps.json" \
    LEARNED_CAPS_AUDIT="$scratch/learned-caps-audit.log" \
    SEAT_YIELD_JSON="$scratch/seat-yield.json" \
    QUALITY_ROUTING_JSON="$scratch/quality-routing.json" \
    QUALITY_SCOREBOARD_JSON="$scratch/quality-scoreboard.json" \
    PI_SEAT_LIB_CHECK_SYSTEMD=0 \
    PI_SEAT_CREDENTIAL_PRECHECK=0 \
    bash -c 'source "$1" 2>/dev/null; usable_light_slots public' _ "$seatlib" 2>/dev/null || echo ERR)
[[ "$n0" == "0" ]] || fail "usable_light_slots at learned cap (2/2) must be 0, got: $n0"
seed_active 1
n1=$(env \
    HOME="$scratch" \
    PI_MODELS_JSON="$scratch/models.json" \
    SEAT_CAPS_JSON="$scratch/seat-caps.json" \
    REPO_PRIVACY_JSON="$scratch/repo-privacy.json" \
    PI_PACKET_STATE="$scratch/pi-packet" \
    PI_ISSUES_DIR="$scratch/pi-issues" \
    PI_SEAT_HEALTH_LEDGER_DIR="$scratch/ledger" \
    LEARNED_CAPS_JSON="$scratch/learned-caps.json" \
    LEARNED_CAPS_AUDIT="$scratch/learned-caps-audit.log" \
    SEAT_YIELD_JSON="$scratch/seat-yield.json" \
    QUALITY_ROUTING_JSON="$scratch/quality-routing.json" \
    QUALITY_SCOREBOARD_JSON="$scratch/quality-scoreboard.json" \
    PI_SEAT_LIB_CHECK_SYSTEMD=0 \
    PI_SEAT_CREDENTIAL_PRECHECK=0 \
    bash -c 'source "$1" 2>/dev/null; usable_light_slots public' _ "$seatlib" 2>/dev/null || echo ERR)
[[ "$n1" == "1" ]] || fail "usable_light_slots with one free slot (1/2) must be 1, got: $n1"
ok "Test 4: usable_light_slots counts 0 at learned cap, 1 with one free slot"

# === Test 2: REPLAY A — the incident. Seat at learned cap (2/2), two
# agent-ready issues -> the tick must hold with the new gate line and make
# ZERO claims. ===
seed_active 2
rm -f "$scratch/claims.log" "$scratch"/live-* 2>/dev/null || true
rm -f "$GIT_STUB_DIR/branches" 2>/dev/null || true
set +e
out="$(run_tick)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "saturated tick must exit 0, got rc=$rc: $out"
echo "$out" | grep -qF 'holding claims this tick — gate: no usable seat slot' \
    || fail "saturated tick must log the seat-slot hold line: $out"
[[ "$(count_claims "$out")" == "0" ]] \
    || fail "saturated tick must make 0 claims, got: $out"
ok "Test 2: replay A — seat at learned cap, 2 agent-ready issues -> 0 claims + gate line"

# === Test 3: REPLAY B — same seat map, one free slot (1/2) -> exactly one
# claim; the second issue is skipped-capacity. ===
seed_active 1
rm -f "$scratch/claims.log" "$scratch"/live-* 2>/dev/null || true
rm -f "$GIT_STUB_DIR/branches" 2>/dev/null || true
set +e
out="$(run_tick)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "one-slot tick must exit 0, got rc=$rc: $out"
[[ "$(count_claims "$out")" == "1" ]] \
    || fail "one-slot tick must make exactly 1 claim, got: $out"
echo "$out" | grep -qF 'issue 101' \
    || fail "one-slot tick must claim issue 101: $out"
echo "$out" | grep -qF 'issue 102 (seat-slot drill issue B): skipped-capacity' \
    || fail "issue 102 must be skipped-capacity when the free slot is spent: $out"
echo "$out" | grep -qF 'capping claims this tick — gate: usable seat slots' \
    || fail "one-slot tick must log the cap line: $out"
ok "Test 3: replay B — one free slot, 2 agent-ready issues -> exactly 1 claim"

# === Test 5: shellcheck on both touched files ===
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "$tick" --severity=warning
    shellcheck -x "$seatlib" --severity=warning
    ok "Test 5: shellcheck clean on pi-intake-tick.sh + seat-lib.sh"
else
    echo "SKIP: Test 5: shellcheck not installed"
fi

echo "ALL OK: intake seat-slot gate replay drill (fleet-ops#3732)"
