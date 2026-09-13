#!/usr/bin/env bash
# tests/pi-issue-run-senior-review-routing.test.sh
#
# fleet-ops#6393: a packet whose front-matter carries difficulty: senior-review
# was picked by the LiteLLM WORKER-CHEAP group (0509-3330, 2026-09-13: watch.log
# "running on litellm/worker-cheap (weight=senior-review, tried: 1 seat(s))")
# because the #4263 P3b group pick keyed on privacy alone and never consulted
# the difficulty it had already parsed. The regression: a PUBLIC senior-review
# packet must pick the senior ladder (group=senior, seat litellm/senior) and
# never worker-cheap; the #520 private -> worker-private mapping and the
# #4639 armed repair reservation (judge) precedence must be untouched.
#
# The REAL lib/litellm-seat.sh is sourced (no function overrides): the fixture
# exercises packet_difficulty, repo_privacy, litellm_ready and litellm_seat
# exactly as the unit does. Fixture packets mirror the 0509-3330 volatile tail
# (fleet-ops#4643: difficulty marker after the prompt body, TARGET last).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/pi-issue-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch="$(mktemp -d -t pi-issue-senior.XXXXXX)"
# PI_SENIOR_KEEP=1 keeps the scratch (watch.log receipts) for inspection.
trap '[[ "${PI_SENIOR_KEEP:-0}" == 1 ]] || rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME" "$scratch/xdg" "$scratch/bin"
# P14 hosts (worker-token-fail-closed) export WORKER_APP_CREDS_FILE into their
# own scratch. Unset so this test's HOME creds file is the one read.
unset WORKER_APP_CREDS_FILE || true

# P14 (fleet-ops#568) class lock: the App-identity stub, exactly as
# pi-issue-run-failure-reason.test.sh.
mkdir -p "$HOME/.config/fleet-worker"
: >"$HOME/.config/fleet-worker/nishfleet-worker.env"
chmod 600 "$HOME/.config/fleet-worker/nishfleet-worker.env"
cat >"$scratch/bin/worker-token" <<'EOF'
#!/usr/bin/env bash
printf 'export GH_TOKEN=fake-test-token-cccccccccccccccc\n'
exit 0
EOF
chmod +x "$scratch/bin/worker-token"

# Fake pi: fails loudly (non-empty stderr) so the wrapper treats it as a real
# failure and exits 1 instead of spinning the empty-run re-seat loop. The
# group/running-on lines land in watch.log BEFORE pi runs.
cat >"$scratch/bin/pi" <<'EOF'
#!/usr/bin/env bash
echo 'simulated pi failure: boom' >&2
exit 1
EOF
chmod +x "$scratch/bin/pi"

# #520 privacy fixture: the live config/repo-privacy.json classifies 0509 as
# public and 0509-telemetry as private; unknown repos fail closed to private.
mkdir -p "$HOME/.local/state/pi-packet"
printf '%s' '{"default_policy":"private","public":["0509"],"private":["0509-telemetry"]}' \
    >"$HOME/.local/state/pi-packet/repo-privacy.json"

issues_dir="$scratch/issues"
mkdir -p "$issues_dir"
export PI_ISSUES_DIR="$issues_dir"

# Hermetic readiness: the fixture sources the REAL litellm_seat, so it must
# not depend on this VPS's live 127.0.0.1:4000 (the 2026-09-13T18:2xZ flake
# class: a transient readiness miss fails the pick open to the #6315 direct
# prepaid lane and the litellm/senior assertion dies). Point the probe at a
# dead port — connection-refused is instant — and let the #6315/#5889
# test fail-open answer READY, exactly as CI does. The completion probe
# derives its URL from LITELLM_HEALTH_URL, so both misses are deterministic;
# GITHUB_ACTIONS has no other effect in the exercised paths (lib only).
export LITELLM_HEALTH_URL="http://127.0.0.1:1/health/readiness"
export GITHUB_ACTIONS=true

write_pkt() {
    # write_pkt <inst> <target-repo> [extra marker lines...]
    local inst="$1" repo="$2" extra; shift 2
    {
        printf 'packet body: senior-review routing fixture\n'
        printf 'difficulty: senior-review\n'
        for extra in "$@"; do printf '%s\n' "$extra"; done
        printf 'TARGET: repo %s issue 3330 unit pi-issue-%s\n' "$repo" "$inst"
    } >"$issues_dir/$inst.in"
}

# Runs the wrapper hermetically and leaves the rc in $rc. The inst's issue
# suffix is not numeric, so the parked-issue gh lookup (fleet-ops#5092) is
# skipped — no network — while the TARGET still drives packet_repo ->
# repo_privacy, the exact #6393 fault path. Watch.log is fresh per run.
run_one() {
    local inst="$1" state="$2"
    mkdir -p "$state" "$state/xdg"
    set +e
    env \
        HOME="$HOME" \
        XDG_RUNTIME_DIR="$state/xdg" \
        PI_PACKET_STATE="$state" \
        PI_SEAT_HEALTH_LEDGER_DIR="$state/seat-health" \
        PI_PACKET_SEAT_LIB="$repo_root/lib/litellm-seat.sh" \
        PI_ISSUES_DIR="$issues_dir" \
        PI_BIN="$scratch/bin/pi" \
        WORKER_TOKEN_BIN="$scratch/bin/worker-token" \
        PATH="$scratch/bin:$PATH" \
        bash "$bin" "$inst" >"$scratch/run.out" 2>"$scratch/run.err"
    rc=$?
    set -e
}

assert_pick() {
    # assert_pick <watch.log> <expected group= line> <expected running-on>
    local log="$1" groupline="$2" runningon="$3"
    [[ -f "$log" ]] || fail "watch.log missing at $log"
    grep -qF "$groupline" "$log" \
        || fail "watch.log must contain '$groupline', got: $(cat "$log")"
    grep -qF "$runningon" "$log" \
        || fail "watch.log must contain '$runningon', got: $(cat "$log")"
    grep -qF 'pi exited 1' "$scratch/run.err" \
        || fail "run must reach pi and report the failure, got: $(cat "$scratch/run.err")"
    if grep -qF 'DEAD APP IDENTITY' "$scratch/run.err"; then
        fail "App-identity stub failed, run never reached the pick: $(cat "$scratch/run.err")"
    fi
    return 0
}

# --- 1. public + senior-review: the filed fault (0509#3330) ------------------
# Before #6393 this exact fixture produced "group=worker-cheap (privacy=public)"
# with weight=senior-review — the required assertion is that it must NOT.
state1="$scratch/state1"
write_pkt "test-issue" "Nishfleet/0509"
run_one "test-issue" "$state1"
rc1=$rc
[[ "$rc1" == "1" ]] || fail "wrapper must exit 1 after the (faked) pi failure, got $rc1"
assert_pick "$state1/watch.log" 'group=senior (privacy=public)' \
    'running on litellm/senior (weight=senior-review'
if grep -qF 'group=worker-cheap (privacy=public)' "$state1/watch.log"; then
    fail "required #3: a public senior-review packet must not pick worker-cheap: $(cat "$state1/watch.log")"
fi
ok "public senior-review packet picks the senior ladder (group=senior, litellm/senior, not worker-cheap)"

# --- 2. private + senior-review: the #520 line holds --------------------------
# Private repos already reach the prepaid glm-5.3 class via worker-private;
# the #6393 condition is public-only so #520 keeps routing private work.
state2="$scratch/state2"
write_pkt "test-issue-2" "Nishfleet/0509-telemetry"
run_one "test-issue-2" "$state2"
rc2=$rc
[[ "$rc2" == "1" ]] || fail "wrapper must exit 1 after the (faked) pi failure, got $rc2"
assert_pick "$state2/watch.log" 'group=worker-private (privacy=private)' \
    'running on litellm/worker-private (weight=senior-review'
if grep -qF 'group=senior (privacy=private)' "$state2/watch.log"; then
    fail "a private senior-review packet must stay on worker-private (#520): $(cat "$state2/watch.log")"
fi
ok "private senior-review packet stays on worker-private (#520 untouched)"

# --- 3. armed repair reservation keeps precedence (#4639) ---------------------
# The #6393 condition sits between the privacy line and the #4639 line; a
# seat-rung: repair packet must still route to the reserved judge group.
state3="$scratch/state3"
write_pkt "test-issue-3" "Nishfleet/0509" 'seat-rung: repair'
run_one "test-issue-3" "$state3"
rc3=$rc
[[ "$rc3" == "1" ]] || fail "wrapper must exit 1 after the (faked) pi failure, got $rc3"
assert_pick "$state3/watch.log" 'group=judge (privacy=public)' \
    'running on litellm/judge (weight=senior-review'
ok "repair-rung reservation outranks the senior-review pick (judge, #4639 untouched)"

ok "all #6393 routing cases: senior ladder for public, #520 private, #4639 precedence"
