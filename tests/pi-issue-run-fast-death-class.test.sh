#!/usr/bin/env bash
# fleet-ops#3766: a fast death (pi exits non-zero, 0 tool calls) must carry a
# classifiable literal into the PACKET-VERDICT line and the seat ledger's
# last_error_class/bench_reason. An unclassifiable death is error_class=unknown
# with the raw tail, never healthy. Replay drill: stub pi exiting 1 with a
# provider error on stderr and 0 tools (case 1), then empty stderr with the
# jsonl tail (case 2).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; repo_root="$(cd "$here/.." && pwd)"; bin="$repo_root/bin/pi-issue-run"
fail() { echo "FAIL: $*" >&2; exit 1; }; ok() { echo "OK: $*"; }
scratch="$(mktemp -d -t pi-issue-fast-death.XXXXXX)"; trap 'rm -rf "$scratch"' EXIT INT TERM
export HOME="$scratch/home"; mkdir -p "$HOME/.config/fleet-worker"; : >"$HOME/.config/fleet-worker/nishfleet-worker.env"; chmod 600 "$HOME/.config/fleet-worker/nishfleet-worker.env"
STATE_DIR="$scratch/state"; mkdir -p "$STATE_DIR/attempts" "$STATE_DIR/active-seats"; ISSUES_DIR="$scratch/issues"; mkdir -p "$ISSUES_DIR"; LEDGER="$scratch/ledger"; mkdir -p "$LEDGER"
export PI_PACKET_STATE="$STATE_DIR" PI_SEAT_HEALTH_LEDGER_DIR="$LEDGER" PI_ISSUES_DIR="$ISSUES_DIR" PI_MODELS_JSON="$scratch/models.json" SEAT_CAPS_JSON="$scratch/seat-caps.json" XDG_RUNTIME_DIR="$scratch/xdg" PI_SEAT_LIB_CHECK_SYSTEMD=0 FLEET_DEBUG_PLAYBOOK_GATE=0 EMPTY_RUN_RETRY_MAX=0 SPAWN_FAIL_MAX_S=1 PI_HANG_TIMEOUT_S=60 PI_HANG_BENCH_MIN_S=1
mkdir -p "$XDG_RUNTIME_DIR"; stub_bin="$scratch/stub-bin"; mkdir -p "$stub_bin"
printf 'exit 0\n' >"$stub_bin/gh"; chmod +x "$stub_bin/gh"
printf 'printf "export GH_TOKEN=fake-test-token-cccccccccccccccc\\n"\nexit 0\n' >"$stub_bin/worker-token"; chmod +x "$stub_bin/worker-token"; export WORKER_TOKEN_BIN="$stub_bin/worker-token"
printf 'exit 0\n' >"$stub_bin/systemctl"; chmod +x "$stub_bin/systemctl"
export PATH="$stub_bin:/usr/local/bin:/usr/bin:/bin"
cat >"$PI_MODELS_JSON" <<'JSON'
{ "providers": { "commandcode": { "models": [ { "id": "laguna-s-2.1-free", "cost": { "input": 0 }, "reasoning": false, "contextWindow": 200000 } ] } } }
JSON
cat >"$SEAT_CAPS_JSON" <<'JSON'
{ "ram_gb_per_worker": 1.5, "free_providers_in_order": ["commandcode"], "providers": { "commandcode": { "cap": 1, "class": "free", "models": { "laguna-s-2.1-free": 1 } } } }
JSON
export PI_PACKET_SEAT_LIB="$repo_root/lib/seat-lib.sh"
export FLEET_DEBUG_PLAYBOOK_SESSION_DIR="$scratch/sessions"

# --- case 1: pi exits 1 with a provider error on stderr and 0 tool calls -----
# The error text contains NO quota/overload/ETIMEDOUT/mid-session keyword, so
# every existing detector misses -> error_class=unknown, and the fallthrough
# bench must fire so the seat stops flapping.
inst="fleet-ops-3766a"
mkdir -p "$FLEET_DEBUG_PLAYBOOK_SESSION_DIR"
printf 'Implement one GitHub issue: fleet-ops#3766 case A.\n' >"$ISSUES_DIR/${inst}.in"
cat >"$stub_bin/pi" <<'STUB'
#!/usr/bin/env bash
sd=""; while [[ $# -gt 0 ]]; do case "$1" in --session-dir) sd="$2"; shift 2;; *) shift;; esac; done
mkdir -p "$sd"; printf '%s\n' '{"type":"session","version":3,"id":"x","timestamp":"2026-09-06T00:00:00.000Z","cwd":"/tmp"}' >"$sd/2026-09-06T00-00-00-000Z_caseA.jsonl"
echo 'provider transport error: upstream connection reset by peer (no retry)' >&2
exit 1
STUB
chmod +x "$stub_bin/pi"; export PI_BIN="$stub_bin/pi"
set +e; bash "$bin" "$inst" >"$scratch/runA.out" 2>"$scratch/runA.err"; rcA=$?; set -e
[[ "$rcA" == "1" ]] || fail "case A: runner must exit 1 for systemd re-seat (got $rcA): $(tail -3 "$scratch/runA.err")"
# The synthetic PACKET-VERDICT line must carry error_class=unknown + the literal.
grep -qE 'PACKET-VERDICT[[:space:]]+tools=0[[:space:]]+class=no-tools[[:space:]]+error_class=unknown' "$ISSUES_DIR/${inst}.out" \
  || fail "case A: synthetic verdict line missing error_class=unknown: $(cat "$ISSUES_DIR/${inst}.out")"
grep -q 'upstream connection reset' "$ISSUES_DIR/${inst}.out" \
  || fail "case A: verdict line must carry the literal error tail: $(cat "$ISSUES_DIR/${inst}.out")"
ok "case A: synthetic PACKET-VERDICT carries error_class=unknown + literal"
# The ledger must carry last_error_class=unknown + bench_reason, never healthy.
ledger="$LEDGER/commandcode__laguna-s-2.1-free.json"; [[ -f "$ledger" ]] || fail "case A: no ledger written for commandcode/laguna-s-2.1-free"
lec=$(jq -r '.last_error_class // ""' "$ledger"); [[ "$lec" == "unknown" ]] || fail "case A: ledger last_error_class must be 'unknown', got '$lec'"
br=$(jq -r '.bench_reason // ""' "$ledger"); [[ "$br" == *"upstream connection reset"* ]] || fail "case A: ledger bench_reason must carry the literal, got '$br'"
hc=$(jq -r '.health_class // ""' "$ledger"); [[ "$hc" != "healthy" ]] || fail "case A: ledger must NOT stay healthy for a fast death (got '$hc')"
ok "case A: ledger carries last_error_class=unknown + bench_reason, not healthy"

# --- case 2: empty stderr, the error lives only in the session jsonl --------
# pi exits 1 with EMPTY stderr and 0 tools; the session jsonl carries the
# errorMessage (#3238 surfaces it into $err_file as session-error:). The
# verdict line + ledger must still carry error_class=unknown + the jsonl tail.
inst="fleet-ops-3766b"
# Clear case A's bench (ledger + clobber-proof spawn-bench marker) so pick_seat
# re-offers the only seat; case B is a fresh fast-death replay.
rm -f "$LEDGER/commandcode__laguna-s-2.1-free.json" "$LEDGER/commandcode__laguna-s-2.1-free.spawn-bench.json"
printf 'Implement one GitHub issue: fleet-ops#3766 case B.\n' >"$ISSUES_DIR/${inst}.in"
cat >"$stub_bin/pi" <<'STUB'
#!/usr/bin/env bash
sd=""; while [[ $# -gt 0 ]]; do case "$1" in --session-dir) sd="$2"; shift 2;; *) shift;; esac; done
mkdir -p "$sd"; printf '%s\n' '{"type":"session","version":3,"id":"y","timestamp":"2026-09-06T00:00:01.000Z","cwd":"/tmp"}' >"$sd/2026-09-06T00-00-01-000Z_caseB.jsonl"
printf '%s\n' '{"type":"message","id":"m1","parentId":null,"timestamp":"2026-09-06T00:00:01.100Z","message":{"role":"assistant","provider":"commandcode","model":"laguna-s-2.1-free","stopReason":"error","errorMessage":"model backend returned 502: gateway timeout from upstream","content":[]}}' >>"$sd/2026-09-06T00-00-01-000Z_caseB.jsonl"
exit 1
STUB
chmod +x "$stub_bin/pi"
set +e; bash "$bin" "$inst" >"$scratch/runB.out" 2>"$scratch/runB.err"; rcB=$?; set -e
[[ "$rcB" == "1" ]] || fail "case B: runner must exit 1 for systemd re-seat (got $rcB): $(tail -3 "$scratch/runB.err")"
grep -qE 'PACKET-VERDICT[[:space:]]+tools=0[[:space:]]+class=no-tools[[:space:]]+error_class=unknown' "$ISSUES_DIR/${inst}.out" \
  || fail "case B: synthetic verdict line missing error_class=unknown: $(cat "$ISSUES_DIR/${inst}.out")"
grep -q 'gateway timeout from upstream' "$ISSUES_DIR/${inst}.out" \
  || fail "case B: verdict line must carry the jsonl error tail: $(cat "$ISSUES_DIR/${inst}.out")"
ok "case B: synthetic PACKET-VERDICT carries error_class=unknown + jsonl tail"
ledger="$LEDGER/commandcode__laguna-s-2.1-free.json"; [[ -f "$ledger" ]] || fail "case B: no ledger written for commandcode/laguna-s-2.1-free"
lec=$(jq -r '.last_error_class // ""' "$ledger"); [[ "$lec" == "unknown" ]] || fail "case B: ledger last_error_class must be 'unknown', got '$lec'"
br=$(jq -r '.bench_reason // ""' "$ledger"); [[ "$br" == *"gateway timeout from upstream"* ]] || fail "case B: ledger bench_reason must carry the jsonl tail, got '$br'"
ok "case B: ledger carries last_error_class=unknown + jsonl tail"

echo "PASS: pi-issue-run-fast-death-class"
