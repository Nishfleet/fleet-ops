#!/usr/bin/env bash
# fleet-ops#3238: a provider error that only exists in the session jsonl must reach the seat detectors.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; repo_root="$(cd "$here/.." && pwd)"; bin="$repo_root/bin/pi-issue-run"
fail() { echo "FAIL: $*" >&2; exit 1; }; ok() { echo "OK: $*"; }
scratch="$(mktemp -d -t pi-issue-session-err.XXXXXX)"; trap 'rm -rf "$scratch"' EXIT INT TERM
export HOME="$scratch/home"; mkdir -p "$HOME/.config/fleet-worker"; : >"$HOME/.config/fleet-worker/nishfleet-worker.env"; chmod 600 "$HOME/.config/fleet-worker/nishfleet-worker.env"
STATE_DIR="$scratch/state"; mkdir -p "$STATE_DIR/attempts" "$STATE_DIR/active-seats"; ISSUES_DIR="$scratch/issues"; mkdir -p "$ISSUES_DIR"; LEDGER="$scratch/ledger"; mkdir -p "$LEDGER"
export PI_PACKET_STATE="$STATE_DIR" PI_SEAT_HEALTH_LEDGER_DIR="$LEDGER" PI_ISSUES_DIR="$ISSUES_DIR" PI_MODELS_JSON="$scratch/models.json" SEAT_CAPS_JSON="$scratch/seat-caps.json" XDG_RUNTIME_DIR="$scratch/xdg" PI_SEAT_LIB_CHECK_SYSTEMD=0 FLEET_DEBUG_PLAYBOOK_GATE=0 EMPTY_RUN_RETRY_MAX=0 SPAWN_FAIL_MAX_S=1
mkdir -p "$XDG_RUNTIME_DIR"; stub_bin="$scratch/stub-bin"; mkdir -p "$stub_bin"
# pi stub: writes the live devin error into the session dir and exits 1 with EMPTY stderr/stdout (the real shape)
cat >"$stub_bin/pi" <<'STUB'
#!/usr/bin/env bash
sd=""; while [[ $# -gt 0 ]]; do case "$1" in --session-dir) sd="$2"; shift 2;; *) shift;; esac; done
mkdir -p "$sd"; printf '%s\n' '{"type":"message","message":{"role":"assistant","provider":"devin","model":"swe-1-7","stopReason":"error","errorMessage":"Devin exited with code 1: Error: Agent error: Connection error, send a message to continue retrying (error id: 7a85): { \"cognition.ai/errorKind\": \"resource_exhausted\", \"cognition.ai/retryable\": true }","content":[]}}' >"$sd/2026-09-05T00-00-00-000Z_test.jsonl"
exit 1
STUB
chmod +x "$stub_bin/pi"; export PI_BIN="$stub_bin/pi"
printf 'exit 0\n' >"$stub_bin/gh"; chmod +x "$stub_bin/gh"
printf 'printf "export GH_TOKEN=fake-test-token-cccccccccccccccc\\n"\nexit 0\n' >"$stub_bin/worker-token"; chmod +x "$stub_bin/worker-token"; export WORKER_TOKEN_BIN="$stub_bin/worker-token"
printf 'exit 0\n' >"$stub_bin/systemctl"; chmod +x "$stub_bin/systemctl"
export PATH="$stub_bin:/usr/local/bin:/usr/bin:/bin"
cat >"$PI_MODELS_JSON" <<'JSON'
{ "providers": { "devin": { "models": [ { "id": "swe-1-7", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 } ] } } }
JSON
cat >"$SEAT_CAPS_JSON" <<'JSON'
{ "ram_gb_per_worker": 1.5, "free_providers_in_order": [], "providers": { "devin": { "cap": 4, "class": "subscription", "quota_bench_default_s": 900, "models": { "swe-1-7": 4 } } } }
JSON
export PI_PACKET_SEAT_LIB="$repo_root/lib/seat-lib.sh"
inst="fleet-ops-1"; printf 'Implement one GitHub issue: fleet-ops#1.\n' >"$ISSUES_DIR/${inst}.in"
export FLEET_DEBUG_PLAYBOOK_SESSION_DIR="$scratch/sessions"
set +e; bash "$bin" "$inst" >"$scratch/run.out" 2>"$scratch/run.err"; rc=$?; set -e
[[ "$rc" == "1" ]] || fail "runner must exit 1 for systemd re-seat (got $rc): $(tail -3 "$scratch/run.err")"
grep -q 'session-error: Devin exited with code 1' "$ISSUES_DIR/${inst}.err" || fail "session error was not appended to the err file: $(cat "$ISSUES_DIR/${inst}.err")"
ok "Test 1: session errorMessage is surfaced into the err file"
ledger="$LEDGER/devin__swe-1-7.json"; [[ -f "$ledger" ]] || fail "no ledger written for devin/swe-1-7 — detectors did not see the error"
hc=$(jq -r '.health_class' "$ledger"); [[ "$hc" == "quota_bench" ]] || fail "expected quota_bench for resource_exhausted, got '$hc'"
ok "Test 2: devin resource_exhausted from the session benches the seat (quota_bench)"
echo "PASS: pi-issue-run-session-error-feed"
