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
precedence_band_pending_starvation_clear() { true; }
precedence_band_is_leverage_issue() { return 1; }
precedence_band_allow_claim() { return 0; }
# fleet-ops#2519: product-first precedence gate (sourced from the same
# PRECEDENCE_BAND_LIB). This test exercises the gh rate-limit hold path,
# not the product-first hold, so stub the gate to never hold: export is a
# no-op, the repo is not self-maintenance here, and hold returns 1 (ADMIT).
product_first_export_product_ratio() { return 0; }
product_first_is_self_maintenance() { return 1; }
product_first_ratio() { return 1; }
product_first_hold() { return 1; }
SH
chmod +x "$stubs"

# Stub prior-art-claim-check (fleet-ops#1250) so the claim-step gate passes
# and the tick reaches the rate-limit path under test. Exits 0 = CLAIM_OK.
prior_art_stub="$scratch/prior-art-claim-check"
cat >"$prior_art_stub" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$prior_art_stub"

# Functions beat PATH, so we override gh/git/systemctl in the child bash.
# GH_CALL_LOG (when set) records every gh invocation so a test can assert the
# pre-check skipped the tick WITHOUT making any gh call (fleet-ops#2523).
gh() {
    if [[ -n "${GH_CALL_LOG:-}" ]]; then
        printf '%s\n' "$*" >>"$GH_CALL_LOG"
    fi
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
    # fleet-ops#2523: the pre-check (remaining < 500 OR headroom < 10%) runs
    # before the mid-tick gate. To exercise the mid-tick gate (low==1, 20%
    # threshold) WITHOUT tripping the stricter pre-check, low=1 uses
    # remaining=1500/limit=10000 (headroom 15%, remaining >= 500) so only the
    # mid-tick gate fires. low=0 uses a healthy remaining=3000/limit=5000.
    if [[ "$low" == "1" ]]; then
        cat >"$scratch/gh-rate-limit.json" <<JSON
{
  "low": 1,
  "remaining": 1500,
  "limit": 10000,
  "resource": "search",
  "reset": $(( $(date +%s) + 3600 )),
  "fetched_at": $(date +%s)
}
JSON
    else
        cat >"$scratch/gh-rate-limit.json" <<JSON
{
  "low": 0,
  "remaining": 3000,
  "limit": 5000,
  "resource": "search",
  "reset": $(( $(date +%s) + 3600 )),
  "fetched_at": $(date +%s)
}
JSON
    fi
}

run_tick() {
    local low="$1"
    local max_age="$2"
    if [[ "$low" == "missing" ]]; then
        rm -f "$scratch/gh-rate-limit.json"
    else
        write_state "$low"
    fi
    # fleet-ops#3445: isolate the secondary-limit state dir and force GH
    # Actions mode so the offline test never mints a real token or reads the
    # live VPS secondary-limit state.
    mkdir -p "$scratch/secondary"
    env \
        GITHUB_ACTIONS=true \
        PATH="$stubs:${PATH}" \
        HOME="$scratch" \
        XDG_RUNTIME_DIR="$scratch/run" \
        PI_INTAKE_LOCKDIR="$scratch" \
        PI_INTAKE_DEBOUNCE_SEC=0 \
        PI_INTAKE_RECONCILER_PROM="$scratch/reconciler" \
        PI_INTAKE_GH_RATE_LIMIT_STATE="$scratch/gh-rate-limit.json" \
        PI_INTAKE_GH_RATE_LIMIT_MAX_AGE="$max_age" \
        PI_INTAKE_GH_SECONDARY_STATE_DIR="$scratch/secondary" \
        PI_INTAKE_ISSUE_STATE_DIR="$scratch/pi-issues" \
        SEAT_LIB="$stubs" \
        PRECEDENCE_BAND_LIB="$stubs" \
        PRIOR_ART_CLAIM_CHECK="$prior_art_stub" \
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

# --- fleet-ops#2523 rate-limit PRE-CHECK (skip tick before any gh call) ---
# The pre-check runs at the very start of the tick, before the first gh call.
# When headroom is low (remaining < 500 OR headroom < 10%) it must exit 0 with
# the "rate-limit headroom low, skipping intake tick" log line and export the
# fleet_intake_tick_skipped_rate_limit_total metric, WITHOUT making any gh call.

write_state_full() {
    local remaining="$1" limit="$2"
    cat >"$scratch/gh-rate-limit.json" <<JSON
{
  "low": 0,
  "remaining": $remaining,
  "limit": $limit,
  "resource": "core",
  "reset": $(( $(date +%s) + 3600 )),
  "fetched_at": $(date +%s)
}
JSON
}

run_tick_precheck() {
    local remaining="$1" limit="$2"
    write_state_full "$remaining" "$limit"
    rm -f "$scratch/gh-calls.log"
    mkdir -p "$scratch/secondary" "$scratch/pi-issues" "$scratch/rl-skip"
    env \
        GITHUB_ACTIONS=true \
        PATH="$stubs:${PATH}" \
        HOME="$scratch" \
        XDG_RUNTIME_DIR="$scratch/run" \
        PI_INTAKE_LOCKDIR="$scratch" \
        PI_INTAKE_DEBOUNCE_SEC=0 \
        PI_INTAKE_RECONCILER_PROM="$scratch/reconciler" \
        PI_INTAKE_GH_RATE_LIMIT_STATE="$scratch/gh-rate-limit.json" \
        PI_INTAKE_GH_RATE_LIMIT_MAX_AGE="120" \
        PI_INTAKE_GH_SECONDARY_STATE_DIR="$scratch/secondary" \
        PI_INTAKE_ISSUE_STATE_DIR="$scratch/pi-issues" \
        PI_INTAKE_RL_SKIP_PROM="$scratch/rl-skip/fleet-intake-tick-skipped-rate-limit" \
        GH_CALL_LOG="$scratch/gh-calls.log" \
        SEAT_LIB="$stubs" \
        PRECEDENCE_BAND_LIB="$stubs" \
        PRIOR_ART_CLAIM_CHECK="$prior_art_stub" \
        FLEET_ISSUE_REPO="Nishfleet/fleet-ops" \
        bash "$tick" fleet-ops 2>&1
}

# Test 3b: low remaining (< 500) -> pre-check skips the tick, no gh call
out="$(run_tick_precheck 100 5000)"
rc=$?
[[ "$rc" == "0" ]] || fail "pre-check low-remaining tick must exit 0, got rc=$rc"
# fleet-ops#5489: exhausted budget no longer skips the tick — it glides the
# reads onto the human gh identity and holds the writes.
echo "$out" | grep -qF 'gliding intake tick onto human-gh reads' || fail "must log gliding line: $out"
echo "$out" | grep -qF 'gh_app budget exhausted' || fail "exhausted hold line missing: $out"

# The metric must be exported when skipped.
[[ -f "$scratch/rl-skip/fleet-intake-tick-skipped-rate-limit-fleet-ops.prom" ]] || fail "pre-check must export fleet_intake_tick_skipped_rate_limit_total prom file"
grep -qF 'fleet_intake_tick_skipped_rate_limit_total{repo="fleet-ops"} 1' "$scratch/rl-skip/fleet-intake-tick-skipped-rate-limit-fleet-ops.prom" || fail "pre-check prom file must record skipped_total=1"
ok "pre-check low remaining (<500) skips tick, exports metric, no gh call"

# Test 3c: low headroom (< 10%) with remaining >= 500 -> pre-check skips
# fleet-ops#5489: stale-state exhaust path pins (LOUD + glide, not fail-open
# silence) live in tests/pi-intake-app-budget.test.sh; this pin keeps the
# glide, prom counter and no-skip behavior for low headroom too.
out="$(run_tick_precheck 400 5000)"
rc=$?
[[ "$rc" == "0" ]] || fail "pre-check low-headroom tick must exit 0, got rc=$rc"
echo "$out" | grep -qF 'gliding intake tick onto human-gh reads' || fail "must log gliding line: $out"
ok "pre-check low headroom (<10%) skips tick, no gh call"

# Test 3d: healthy headroom (remaining >= 500 and >= 10%) -> pre-check does NOT
# skip; the tick proceeds to the gh issue list call (stub returns a claim).
out="$(run_tick_precheck 3000 5000)"
rc=$?
[[ "$rc" == "0" ]] || fail "pre-check healthy tick must exit 0, got rc=$rc"
echo "$out" | grep -qF 'rate-limit headroom low, skipping intake tick' && fail "pre-check healthy tick must NOT skip: $out" || true
# The tick must have reached the gh issue list call (healthy path).
grep -qF 'issue list' "$scratch/gh-calls.log" || fail "pre-check healthy tick must reach gh issue list: $(cat "$scratch/gh-calls.log" 2>/dev/null)"
ok "pre-check healthy headroom does not skip; tick reaches gh"

# fleet-ops#2523 follow-up: the live sidecar MIN-aggregates remaining/limit
# across core/search/graphql, so top-level is search 30/30 while core is
# healthy (~4800/5000). The pre-check comment says it gates on the CORE
# budget. Reading top-level remaining<500 skipped every tick (observed
# 2026-09-07T18:21:56Z remaining=30/30 headroom=100%). Prefer
# .resources.core, fall back to top-level for old sidecars.
write_state_core_nested() {
    local core_rem="$1" core_lim="$2" top_rem="$3" top_lim="$4"
    cat >"$scratch/gh-rate-limit.json" <<JSON
{
  "low": 0,
  "remaining": $top_rem,
  "limit": $top_lim,
  "reset": $(( $(date +%s) + 3600 )),
  "fetched_at": $(date +%s),
  "resources": {
    "core": {"remaining": $core_rem, "limit": $core_lim, "reset": $(( $(date +%s) + 3600 )), "low": 0},
    "search": {"remaining": $top_rem, "limit": $top_lim, "reset": $(( $(date +%s) + 60 )), "low": 0},
    "graphql": {"remaining": 4000, "limit": 5000, "reset": $(( $(date +%s) + 3600 )), "low": 0}
  }
}
JSON
}

run_tick_core_nested() {
    local core_rem="$1" core_lim="$2" top_rem="$3" top_lim="$4"
    write_state_core_nested "$core_rem" "$core_lim" "$top_rem" "$top_lim"
    rm -f "$scratch/gh-calls.log"
    mkdir -p "$scratch/secondary" "$scratch/pi-issues" "$scratch/rl-skip"
    env \
        GITHUB_ACTIONS=true \
        PATH="$stubs:${PATH}" \
        HOME="$scratch" \
        XDG_RUNTIME_DIR="$scratch/run" \
        PI_INTAKE_LOCKDIR="$scratch" \
        PI_INTAKE_DEBOUNCE_SEC=0 \
        PI_INTAKE_RECONCILER_PROM="$scratch/reconciler" \
        PI_INTAKE_GH_RATE_LIMIT_STATE="$scratch/gh-rate-limit.json" \
        PI_INTAKE_GH_RATE_LIMIT_MAX_AGE="120" \
        PI_INTAKE_GH_SECONDARY_STATE_DIR="$scratch/secondary" \
        PI_INTAKE_ISSUE_STATE_DIR="$scratch/pi-issues" \
        PI_INTAKE_RL_SKIP_PROM="$scratch/rl-skip/fleet-intake-tick-skipped-rate-limit" \
        GH_CALL_LOG="$scratch/gh-calls.log" \
        SEAT_LIB="$stubs" \
        PRECEDENCE_BAND_LIB="$stubs" \
        PRIOR_ART_CLAIM_CHECK="$prior_art_stub" \
        FLEET_ISSUE_REPO="Nishfleet/fleet-ops" \
        bash "$tick" fleet-ops 2>&1
}

# Test 3e: live sidecar shape (search 30/30 at top-level, core healthy) must NOT skip
out="$(run_tick_core_nested 4839 5000 30 30)"
rc=$?
[[ "$rc" == "0" ]] || fail "live-shape healthy-core tick must exit 0, got rc=$rc"
echo "$out" | grep -qF 'rate-limit headroom low, skipping intake tick' && fail "live-shape healthy core must NOT skip (top-level is search 30/30): $out" || true
grep -qF 'issue list' "$scratch/gh-calls.log" || fail "live-shape healthy core must reach gh issue list: $(cat "$scratch/gh-calls.log" 2>/dev/null)"
ok "pre-check uses resources.core; search-min top-level 30/30 does not skip"

# Test 3f: nested core actually low (100/5000) still skips even if top-level looks 100%
out="$(run_tick_core_nested 100 5000 30 30)"
rc=$?
[[ "$rc" == "0" ]] || fail "nested-core-low tick must exit 0, got rc=$rc"
# fleet-ops#5489: a genuinely-exhausted nested core no longer skips the tick —
# it glides the reads onto the human identity and holds the writes.
echo "$out" | grep -qF 'gliding intake tick onto human-gh reads' || fail "nested core 100/5000 must glide onto human-gh reads: $out"
if ! grep -q 'issue list' "$scratch/gh-calls.log" 2>/dev/null; then
    fail "nested core 100/5000 tick must still reach gh issue list (human reads): $(cat "$scratch/gh-calls.log" 2>/dev/null)"
fi
echo "$out" | grep -qF 'holding claims this tick' || fail "nested core 100/5000 must hold claims: $out"
ok "pre-check glides to human reads when resources.core remaining is actually low"

# --- fleet-ops#3445 secondary rate-limit gate -----------------------------

write_secondary() {
    local active="$1" backoff_until="$2"
    mkdir -p "$scratch/secondary"
    cat >"$scratch/secondary/gh-secondary-rate.json" <<JSON
{"submitted_too_quickly": $active, "attempt": 3, "backoff_until": $backoff_until, "updated_at": $(date +%s)}
JSON
}

run_tick_quiet() {
    # like run_tick but suppress the per-issue echo noise by only setting a
    # single env block (primary gate is low=0 so it reaches the secondary gate)
    mkdir -p "$scratch/secondary" "$scratch/pi-issues"
    write_state "0"
    env \
        GITHUB_ACTIONS=true \
        PATH="$stubs:${PATH}" \
        HOME="$scratch" \
        XDG_RUNTIME_DIR="$scratch/run" \
        PI_INTAKE_LOCKDIR="$scratch" \
        PI_INTAKE_DEBOUNCE_SEC=0 \
        PI_INTAKE_RECONCILER_PROM="$scratch/reconciler" \
        PI_INTAKE_GH_RATE_LIMIT_STATE="$scratch/gh-rate-limit.json" \
        PI_INTAKE_GH_RATE_LIMIT_MAX_AGE="120" \
        PI_INTAKE_GH_SECONDARY_STATE_DIR="$scratch/secondary" \
        PI_INTAKE_ISSUE_STATE_DIR="$scratch/pi-issues" \
        SEAT_LIB="$stubs" \
        PRECEDENCE_BAND_LIB="$stubs" \
        PRIOR_ART_CLAIM_CHECK="$prior_art_stub" \
        FLEET_ISSUE_REPO="Nishfleet/fleet-ops" \
        bash "$tick" fleet-ops 2>&1
}

# Test 4: active secondary backoff (backoff_until in the future) -> hold the tick
write_secondary 1 $(( $(date +%s) + 600 ))
out="$(run_tick_quiet)"
rc=$?
[[ "$rc" == "0" ]] || fail "secondary-backoff tick must exit 0, got rc=$rc"
echo "$out" | grep -qF 'gh secondary rate-limit active' || fail "must log gh secondary rate-limit active: $out"
echo "$out" | grep -qF 'holding claims this tick' || fail "active secondary backoff must hold claims: $out"
ok "active secondary backoff holds claims and exits 0"

# Test 5: expired secondary backoff (backoff_until in the past) -> clear and continue
write_secondary 1 $(( $(date +%s) - 600 ))
out="$(run_tick_quiet)"
rc=$?
[[ "$rc" == "0" ]] || fail "expired-secondary tick must exit 0, got rc=$rc"
echo "$out" | grep -qF 'gh secondary rate-limit active' && fail "expired secondary backoff must NOT hold: $out" || true
# expired state must be cleared back to submitted_too_quickly=0
if [[ -f "$scratch/secondary/gh-secondary-rate.json" ]]; then
    val=$(jq -r '.submitted_too_quickly' "$scratch/secondary/gh-secondary-rate.json" 2>/dev/null || echo '?')
    [[ "$val" == "0" ]] || fail "expired secondary backoff must clear state, got submitted_too_quickly=$val"
fi
ok "expired secondary backoff clears state and continues"

# fleet-ops#3445: the intake's gh write is one organ; run the class-prevention
# gate that asserts EVERY fleet writer organ mints the nishfleet-worker App
# token before any GitHub write (so the human-gh-author regression cannot
# come back). Hosted here so it runs in CI without a workflow-file edit.
bash "$here/fleet-writer-token.test.sh"
