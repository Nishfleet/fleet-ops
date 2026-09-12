#!/usr/bin/env bash
# tests/pi-intake-app-budget.test.sh
#
# fleet-ops#5489: App installation-token budget exhaustion has a graded path.
#   (a) App exhausted -> the tick still LISTS agent-ready issues via the HUMAN
#       gh identity (read-only-for-organs contract, fleet-ops#3445) and holds
#       the claim/write path until the x-ratelimit-reset time; once the budget
#       returns, the tick lists and claims via the App token again.
#   (b) a WRITE is never executed through the human identity.
#   (c) exactly ONE `LOUD [GH-APP-BUDGET]` line per tick reaches the heartbeat
#       triage file while exhausted (and a stale state gets its own LOUD line —
#       never a silent fail-open).
#
# Offline: exported-function stubs for gh/git/systemctl (same pattern as
# tests/pi-intake-gh-rate-limit.test.sh / tests/pi-intake-run.test.sh).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }
[[ -f "$tick" ]] || fail "tick script missing: $tick"

scratch="$(mktemp -d -t pi-app-budget.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

stubs="$scratch/seatlib-stub.sh"
cat >"$stubs" <<'SH'
#!/usr/bin/env bash
total_seat_cap() { echo 8; }
issue_seat_cap() { echo 5; }
worker_memory_for_difficulty() { return 1; }
worker_env_for_repo() { return 1; }
load_seat_caps() { return 0; }
litellm_seat() {
    if [[ "${PICK_SEAT_COUNT_SLOTS:-0}" == "1" ]]; then
        echo 1
        return 0
    fi
    echo "commandcode	deepseek/deepseek-v4-flash		0"
    return 0
}
precedence_band_phase() { echo "band"; }
precedence_band_pending_clear() { true; }
precedence_band_pending_starvation_clear() { true; }
precedence_band_is_leverage_issue() { return 1; }
precedence_band_allow_claim() { echo allow; return 0; }
product_first_export_product_ratio() { return 0; }
product_first_is_self_maintenance() { return 1; }
product_first_ratio() { echo "0.1"; }
product_first_hold() { return 1; }
SH
chmod +x "$stubs"

prior_art_stub="$scratch/prior-art-claim-check"
printf '#!/usr/bin/env bash\nexit 0\n' >"$prior_art_stub"
chmod +x "$prior_art_stub"

# Recording gh stub. Identifies the human identity by GH_TOKEN/GITHUB_TOKEN
# being unset at call time; writes one CALL line per invocation.
gh() {
    local ident="human" cmd
    if [[ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then ident="app"; fi
    cmd="$1 $2"
    [[ $# -ge 1 ]] && cmd="$*"
    printf 'CALL token=%s %s\n' "$ident" "$*" >>"${GH_CALL_LOG:?GH_CALL_LOG required}"
    if [[ "$1" == "issue" && "$2" == "list" ]]; then
        printf '%s\n' '[{"number":5489,"title":"intake starves","labels":[{"name":"agent-ready"}]}]'
        return 0
    fi
    return 0
}

claim_lost="1"
git() {
    if [[ "$1" == "-C" ]]; then shift 2; fi
    if [[ "$1" == "ls-remote" ]]; then
        if [[ "${claim_lost:-0}" == "1" ]]; then
            printf '%s\t%s\n' '0000000000000000000000000000000000000000' 'refs/heads/claim/issue-5489'
        fi
        return 0
    fi
    return 0
}

systemctl() { echo "inactive"; return 0; }
export -f gh git systemctl

# Write fixture state; $1 exhausted(0|1); $2 stale(0|1).
write_state() {
    local exhausted="$1" stale="${2:-0}"
    local now fetched remaining reset
    now=$(date +%s); reset=$(( now + 1800 )); fetched="$now"; remaining=3000
    if [[ "$stale" == "1" ]]; then fetched=$(( now - 600 )); fi
    if [[ "$exhausted" == "1" ]]; then remaining=100; fi
    cat >"$scratch/gh-rate-limit.json" <<EOF
{"low": 0, "remaining": $remaining, "limit": 5000, "resource": "core",
 "reset": $reset, "fetched_at": $fetched}
EOF
}

run_tick() {
    local exhausted="$1" stale="${2:-0}"
    mkdir -p "$scratch/secondary" "$scratch/pi-issues" "$scratch/rl-skip" "$scratch/run"
    : >"$scratch/gh-calls.log"
    rm -f "$scratch/triage.md"
    write_state "$exhausted" "$stale"
    env \
        GITHUB_ACTIONS=true \
        GH_TOKEN=app-token-fixture \
        PATH="/usr/bin:/bin" \
        HOME="$scratch" \
        XDG_RUNTIME_DIR="$scratch/run" \
        PI_INTAKE_LOCKDIR="$scratch" \
        PI_INTAKE_DEBOUNCE_SEC=0 \
        PI_INTAKE_RECONCILER_PROM="$scratch/reconciler" \
        PI_INTAKE_GH_RATE_LIMIT_STATE="$scratch/gh-rate-limit.json" \
        PI_INTAKE_GH_RATE_LIMIT_MAX_AGE=120 \
        PI_INTAKE_GH_SECONDARY_STATE_DIR="$scratch/secondary" \
        PI_INTAKE_ISSUE_STATE_DIR="$scratch/pi-issues" \
        PI_INTAKE_RL_SKIP_PROM="$scratch/rl-skip/fleet-intake-tick-skipped-rate-limit" \
        GH_CALL_LOG="$scratch/gh-calls.log" \
        SEAT_LIB="$stubs" \
        PRECEDENCE_BAND_LIB="$stubs" \
        PRIOR_ART_CLAIM_CHECK="$prior_art_stub" \
        FLEET_ISSUE_REPO="Nishfleet/fleet-ops" \
        FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
        bash "$tick" fleet-ops 2>&1
}

count_calls() {
    local ident="$1" cmd="$2"
    awk -v t="token=$ident" -v c="$cmd" \
        '$1=="CALL" && $2==t {print}' "$scratch/gh-calls.log" \
        | grep -c -- "$cmd" || true
}

# --- Test (a)+(b)+(c): App exhausted -> human reads, held writes, 1 LOUD line
out="$(run_tick 1 0)"
rc=$?
[[ "$rc" == "0" ]] || fail "exhausted tick must exit 0 (hold, not crash), got rc=$rc"

echo "$out" | grep -qF 'gliding intake tick onto human-gh reads' \
    || fail "exhausted tick must log the glide line: $out"
echo "$out" | grep -qF 'holding claims this tick' \
    || fail "exhausted tick must hold claims: $out"

# (a) the agent-ready LISTS ran on the HUMAN identity.
_human_lists=$(count_calls human "issue list")
(( _human_lists >= 1 )) || fail "must list agent-ready issues via HUMAN gh; calls: $(cat "$scratch/gh-calls.log")  out=$out"
# ...and NOTHING ran as human that is a write (issue edit, comment, label, PR).
_human_writes=$(awk '$1=="CALL" && $2=="token=human" && ($3=="issue" || $3=="label" || $3=="pr") && \
    ($0 ~ /edit/ || $0 ~ /comment/ || $0 ~ /create/) {n++} END{print n+0}' "$scratch/gh-calls.log")
(( _human_writes == 0 )) || fail "a WRITE ran through the human identity! $(grep 'token=human' "$scratch/gh-calls.log" | grep -Ev 'issue list|issue view|pr list|pr view|api ' || true)"

# (a) claims are held while exhausted: the App token made no claim-write.
_app_writes=$(awk '$1=="CALL" && $2=="token=app" && ($3=="issue" || $3=="label") && \
    ($0 ~ /agent-in-progress/ || $0 ~ /edit/) {n++} END{print n+0}' "$scratch/gh-calls.log")
(( _app_writes == 0 )) || fail "exhausted tick must back writes off, not claim via App: $(cat "$scratch/gh-calls.log")"

# (c) exactly ONE LOUD [GH-APP-BUDGET] line in the triage file this tick.
_triage_louds=$(grep -c 'LOUD \[GH-APP-BUDGET\]' "$scratch/triage.md" 2>/dev/null || echo 0)
(( _triage_louds == 1 )) || fail "exhausted tick must write exactly ONE LOUD GH-APP-BUDGET line, got $_triage_louds in: $(cat "$scratch/triage.md" 2>/dev/null || echo MISSING)"
grep -q 'LOUD \[GH-APP-BUDGET\] remaining=100 reset_in=' "$scratch/triage.md" \
    || fail "LOUD line must carry remaining + reset_in: $(cat "$scratch/triage.md")"

ok "exhausted: human reads, held writes, exactly one LOUD triage line"

# --- Once budget returns: list + claim BOTH via the App token --------------
# Reset the fixture: healthy state; the claim stub frees the branch and gh
# success lets the tick claim (issue edit with agent-in-progress).
claim_lost="0"

out="$(run_tick 0 0)"
rc=$?
[[ "$rc" == "0" ]] || fail "healthy tick must exit 0, got rc=$rc: $out"
echo "$out" | grep -qF 'gliding intake tick onto human-gh reads' \
    && fail "healthy tick must NOT glide onto human reads: $out" || true
[[ -s "$scratch/triage.md" ]] && fail "healthy tick must not write a LOUD GH-APP-BUDGET line: $(cat "$scratch/triage.md")" || true
_app_claims=$(awk '/token=app/ && /agent-in-progress/ {n++} END{print n+0}' "$scratch/gh-calls.log")
(( _app_claims >= 1 )) || fail "healthy tick must claim via the App token (agent-in-progress edit): $(cat "$scratch/gh-calls.log") out=$out"
ok "budget returned: lists and claims via the App token"

# --- Stale state is loud too ------------------------------------------------
sqlite_stub_out="$(run_tick 0 1)"
rc=$?
[[ "$rc" == "0" ]] || fail "stale-state tick must exit 0, got rc=$rc: $sqlite_stub_out"
_triage_louds=$(grep -c 'LOUD \[GH-APP-BUDGET\]' "$scratch/triage.md" 2>/dev/null || echo 0)
(( _triage_louds >= 1 )) || fail "stale state must write a LOUD GH-APP-BUDGET line: $sqlite_stub_out"
echo "$sqlite_stub_out" | grep -qF 'gh rate-limit pre-check state stale' \
    || fail "stale line must still be named in output: $sqlite_stub_out"
ok "stale state: LOUD + fail-open"

echo "ALL TESTS PASSED (tests/pi-intake-app-budget.test.sh)"
