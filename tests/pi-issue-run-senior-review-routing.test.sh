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
stub_pid=""
cleanup() {
    # PI_SENIOR_KEEP=1 keeps the scratch (watch.log receipts) for inspection.
    if [[ -n "${stub_pid:-}" ]]; then kill "$stub_pid" 2>/dev/null || true; fi
    [[ "${PI_SENIOR_KEEP:-0}" == 1 ]] || rm -rf "$scratch"
}
trap cleanup EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME" "$scratch/xdg" "$scratch/bin"
# P14 hosts (worker-token-fail-closed) export WORKER_APP_CREDS_FILE into their
# own scratch. Unset so this test's HOME creds file is the one read.
unset WORKER_APP_CREDS_FILE || true

# fleet-ops#6163: HERMETIC PROXY STUB. lib/litellm-seat.sh documents the
# LITELLM_HEALTH_URL override as the hermetic escape for tests; without it
# this test curled the LIVE 127.0.0.1:4000 proxy on the VPS, so the #5889
# glob host rolled live dice: in the #6315 wedged state (2026-09-13,
# readiness 0-byte timeouts under load) litellm_ready went false, the
# direct-fallback/walled path ran, and the watch.log 'running on
# litellm/senior' line never appeared — ci-standards-audit red on a clean
# tree while this same child passed standalone seconds later and the ci.yml
# leg passed on its own GITHUB_ACTIONS fail-open. The stub answers readiness
# healthy (and 1-token completions 200), so the routing assertions below
# exercise the real bin/pi-issue-run + real lib/litellm-seat.sh against a
# proxy this test owns — never live seat/proxy state. Same job as #4398's
# ci.yml stub, in-test; same house shape as worker-app-bootstrap.test.sh.
free_port() {
    python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}
LITELLM_STUB_PORT="$(free_port)"
cat >"$scratch/litellm_stub.py" <<'PY'
#!/usr/bin/env python3
"""Stand-in for the LiteLLM proxy: readiness healthy + 1-token completions 200."""
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port, log_path = int(sys.argv[1]), sys.argv[2]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def _healthy(self):
        # Request log = the hermeticity receipt: the routing assertions must
        # be decided by THIS stub, never by the live proxy (fleet-ops#6163).
        with open(log_path, "a", encoding="utf-8") as f:
            f.write(self.path + "\n")
        body = b'{"status":"healthy","db":"connected"}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = _healthy

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n:
            self.rfile.read(n)
        self._healthy()


HTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
LITELLM_STUB_LOG="$scratch/litellm_stub.log"
python3 "$scratch/litellm_stub.py" "$LITELLM_STUB_PORT" "$LITELLM_STUB_LOG" & stub_pid=$!
export LITELLM_HEALTH_URL="http://127.0.0.1:${LITELLM_STUB_PORT}/health/readiness"
# Fail loud, never roll live dice: the stub must answer before the cases run.
n=0
until curl -sf -o /dev/null "$LITELLM_HEALTH_URL"; do
    n=$((n + 1))
    (( n < 50 )) || fail "litellm stub on 127.0.0.1:${LITELLM_STUB_PORT} never answered — refusing to fall back to the live proxy (fleet-ops#6163)"
    sleep 0.1
done

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

# fleet-ops#6163 guard: the runs must have consulted THIS stub. If a future
# edit drops the LITELLM_HEALTH_URL export above, the pick silently reverts
# to live 127.0.0.1:4000 state (the #6315 wedging dice) while the assertions
# here can still pass — the empty stub log catches that revert and fails
# loud instead of green-on-live-state-luck.
grep -q '/health/readiness' "$LITELLM_STUB_LOG" \
    || fail "runs never consulted the hermetic litellm stub — LITELLM_HEALTH_URL override not in effect; refusing a live-proxy verdict (fleet-ops#6163)"
ok "routing verdicts came from the hermetic stub, not the live proxy"

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
