#!/usr/bin/env bash
# fleet-ops#5788 part 2: a WORK death (tools>0) caused by the provider/model mid-run must
# NOT exit 1 and lose the session. The runner re-seats in-process and RESUMES the same
# session file on a different seat (`pi --session <file>`). Replay drill of the
# 2026-09-12 07:19Z death (pi recorded stopReason=error on the assistant turn) on paretoinference
# after 412s of real work.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; repo_root="$(cd "$here/.." && pwd)"; bin="$repo_root/bin/pi-issue-run"
fail() { echo "FAIL: $*" >&2; exit 1; }; ok() { echo "OK: $*"; }
scratch="$(mktemp -d -t pi-issue-resume.XXXXXX)"; trap 'rm -rf "$scratch"' EXIT INT TERM
export HOME="$scratch/home"; mkdir -p "$HOME/.config/fleet-worker"; : >"$HOME/.config/fleet-worker/nishfleet-worker.env"; chmod 600 "$HOME/.config/fleet-worker/nishfleet-worker.env"
STATE_DIR="$scratch/state"; mkdir -p "$STATE_DIR/attempts" "$STATE_DIR/active-seats"; ISSUES_DIR="$scratch/issues"; mkdir -p "$ISSUES_DIR"; LEDGER="$scratch/ledger"; mkdir -p "$LEDGER"
export PI_PACKET_STATE="$STATE_DIR" PI_SEAT_HEALTH_LEDGER_DIR="$LEDGER" PI_ISSUES_DIR="$ISSUES_DIR" PI_MODELS_JSON="$scratch/models.json" SEAT_CAPS_JSON="$scratch/seat-caps.json" XDG_RUNTIME_DIR="$scratch/xdg" PI_SEAT_LIB_CHECK_SYSTEMD=0 FLEET_DEBUG_PLAYBOOK_GATE=0
mkdir -p "$XDG_RUNTIME_DIR"; stub_bin="$scratch/stub-bin"; mkdir -p "$stub_bin"
printf 'exit 0\n' >"$stub_bin/gh"; chmod +x "$stub_bin/gh"
printf 'printf "export GH_TOKEN=fake-test-token-cccccccccccccccc\\n"\nexit 0\n' >"$stub_bin/worker-token"; chmod +x "$stub_bin/worker-token"; export WORKER_TOKEN_BIN="$stub_bin/worker-token"
printf 'exit 0\n' >"$stub_bin/systemctl"; chmod +x "$stub_bin/systemctl"
export PATH="$stub_bin:/usr/local/bin:/usr/bin:/bin"
# Two free seats so the in-process re-seat has somewhere to go.
cat >"$PI_MODELS_JSON" <<'JSON'
{ "providers": { "commandcode": { "models": [ { "id": "laguna-s-2.1-free", "cost": { "input": 0 }, "reasoning": false, "contextWindow": 200000 } ] },
                 "xkiro": { "models": [ { "id": "deepseek/deepseek-v4-pro", "cost": { "input": 0 }, "reasoning": false, "contextWindow": 200000 } ] } } }
JSON
cat >"$SEAT_CAPS_JSON" <<'JSON'
{ "ram_gb_per_worker": 1.5, "free_providers_in_order": ["commandcode", "xkiro"], "providers": { "commandcode": { "cap": 1, "class": "free", "models": { "laguna-s-2.1-free": 1 } }, "xkiro": { "cap": 1, "class": "free", "models": { "deepseek/deepseek-v4-pro": 1 } } } }
JSON
export PI_PACKET_SEAT_LIB="$repo_root/lib/seat-lib.sh"
export FLEET_DEBUG_PLAYBOOK_SESSION_DIR="$scratch/sessions"; mkdir -p "$FLEET_DEBUG_PLAYBOOK_SESSION_DIR"
CALLS="$scratch/pi.calls"; : >"$CALLS"; export CALLS
# Stub pi: call 1 = real work (3 tool results in the session) then a mid-run model error, exit 1.
#          call 2 = must arrive with --session <that file>; finishes with a verdict + PR URL, exit 0.
cat >"$stub_bin/pi" <<'STUB'
#!/usr/bin/env bash
sd=""; sess=""; prov=""; model=""; while [[ $# -gt 0 ]]; do case "$1" in --session-dir) sd="$2"; shift 2;; --session) sess="$2"; shift 2;; --provider) prov="$2"; shift 2;; --model) model="$2"; shift 2;; *) shift;; esac; done
n=$(wc -l < "$CALLS"); n=$((n+1)); printf 'call=%s provider=%s model=%s session=%s stdin=%s\n' "$n" "$prov" "$model" "$sess" "$(head -c 60 | tr '\n' ' ')" >>"$CALLS"
mkdir -p "$sd"
if [[ "$n" == "1" ]]; then
  f="$sd/2026-09-12T07-12-00-000Z_first.jsonl"
  printf '%s\n' '{"type":"session","version":3,"id":"first","timestamp":"2026-09-12T07:12:00.000Z","cwd":"/tmp"}' >"$f"
  for i in 1 2 3; do printf '%s\n' "{\"type\":\"message\",\"message\":{\"role\":\"toolResult\",\"toolCallId\":\"tc$i\",\"content\":\"ok\"}}" >>"$f"; done
  printf '%s\n' '{"type":"message","message":{"role":"assistant","stopReason":"error","errorMessage":"The model returned invalid tool arguments. Please retry the request."}}' >>"$f"
  echo "PACKET-VERDICT tools=3 class=worked" >&2
  exit 1
fi
[[ -n "$sess" && -f "$sess" ]] || { echo "stub: call $n expected --session <existing file>, got '$sess'" >&2; exit 97; }
printf '%s\n' '{"type":"message","message":{"role":"toolResult","toolCallId":"tc4","content":"ok"}}' >>"$sess"
echo "PACKET-VERDICT tools=4 class=worked" >&2
echo "Resumed and finished. https://github.com/Nishfleet/fleet-ops/pull/999"
exit 0
STUB
chmod +x "$stub_bin/pi"; export PI_BIN="$stub_bin/pi"
inst="fleet-ops-5788r"
printf 'Implement one GitHub issue: fleet-ops#5788 resume drill.\n' >"$ISSUES_DIR/${inst}.in"
set +e; bash "$bin" "$inst" >"$scratch/run.out" 2>"$scratch/run.err"; rc=$?; set -e
[[ "$rc" == "0" ]] || fail "runner must exit 0 after resuming on a second seat (got $rc): $(tail -6 "$scratch/run.err")"
[[ "$(wc -l < "$CALLS")" == "2" ]] || fail "pi must be invoked exactly twice (die, then resume): $(cat "$CALLS")"
grep -qE '^call=2 .*session=.*first\.jsonl' "$CALLS" || fail "second invocation must pass --session <first session file>: $(cat "$CALLS")"
grep -qE '^call=2 .*stdin=RESUME' "$CALLS" || fail "second invocation must receive the RESUME prompt on stdin, not the packet: $(cat "$CALLS")"
p1=$(sed -n '1p' "$CALLS" | grep -oE 'provider=[^ ]+'); p2=$(sed -n '2p' "$CALLS" | grep -oE 'provider=[^ ]+')
[[ "$p1" != "$p2" ]] || fail "resume must land on a DIFFERENT seat (tried-seats exclusion): $p1 == $p2"
grep -q 'RESUMING session' "$scratch/run.err" || fail "runner must log the in-process resume: $(tail -5 "$scratch/run.err")"
ok "provider/model mid-run death: session resumed in-process on a different seat, exit 0 (fleet-ops#5788 part 2)"
# --- exhaustion: every seat dies the same way -> bounded, then exit 1 (never an unbounded loop)
: >"$CALLS"; rm -rf "$STATE_DIR/attempts"/* "$FLEET_DEBUG_PLAYBOOK_SESSION_DIR"/* 2>/dev/null || true
cat >"$stub_bin/pi" <<'STUB'
#!/usr/bin/env bash
sd=""; while [[ $# -gt 0 ]]; do case "$1" in --session-dir) sd="$2"; shift 2;; *) shift;; esac; done
n=$(wc -l < "$CALLS"); printf 'call=%s\n' "$((n+1))" >>"$CALLS"; mkdir -p "$sd"
f="$sd/2026-09-12T07-12-00-000Z_s$((n+1)).jsonl"; printf '%s\n' '{"type":"session","version":3,"id":"s","timestamp":"2026-09-12T07:12:00.000Z","cwd":"/tmp"}' >"$f"
printf '%s\n' '{"type":"message","message":{"role":"toolResult","toolCallId":"tc1","content":"ok"}}' >>"$f"
printf '%s\n' '{"type":"message","message":{"role":"assistant","stopReason":"error","errorMessage":"upstream 503"}}' >>"$f"
exit 1
STUB
chmod +x "$stub_bin/pi"
inst="fleet-ops-5788x"; printf 'Implement one GitHub issue: exhaustion drill.\n' >"$ISSUES_DIR/${inst}.in"
set +e; PI_ISSUE_RESUME_RETRY_MAX=1 bash "$bin" "$inst" >"$scratch/run2.out" 2>"$scratch/run2.err"; rc2=$?; set -e
[[ "$rc2" != "0" ]] || fail "exhausted resumes must still fail loud (exit non-zero)"
calls=$(wc -l < "$CALLS"); [[ "$calls" -le 2 ]] || fail "resume must be bounded by PI_ISSUE_RESUME_RETRY_MAX=1 (+1 original): got $calls calls"
grep -q 'resume attempts exhausted' "$scratch/run2.err" || fail "runner must log resume exhaustion: $(tail -4 "$scratch/run2.err")"
ok "resume is bounded: exhausted -> loud exit, no unbounded loop"
echo "ALL pi-issue-run-resume-on-provider-death tests passed"
