#!/usr/bin/env bash
# tests/pi-issue-run-debug-playbook-gate.test.sh
#
# fleet-ops#2005: a successful pi worker session is blocked from closing if its
# JSONL has two or more real failed attempts and no four-heading vault playbook
# note. The gate is enforced by bin/fleet-debug-playbook gate <session.jsonl>.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/pi-issue-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch="$(mktemp -d -t pi-issue-dp-gate.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
mkdir -p "$HOME/.config/fleet-worker"
: > "$HOME/.config/fleet-worker/nishfleet-worker.env"
chmod 600 "$HOME/.config/fleet-worker/nishfleet-worker.env"

STATE_DIR="$scratch/state"
mkdir -p "$STATE_DIR/attempts" "$STATE_DIR/active-seats"
LEDGER="$scratch/ledger"
mkdir -p "$LEDGER"
ISSUES_DIR="$scratch/issues"
mkdir -p "$ISSUES_DIR"

export PI_PACKET_STATE="$STATE_DIR"
export PI_SEAT_HEALTH_LEDGER_DIR="$LEDGER"
export PI_ISSUES_DIR="$ISSUES_DIR"
export PI_PACKET_SEAT_LIB="$repo_root/lib/litellm-seat.sh"

stub_bin="$scratch/stub-bin"
mkdir -p "$stub_bin"

# Pi stub: copies a fixture JSONL into the --session-dir (if supplied) and
# prints enough output to pass the no-op / OUT_MIN check. The fixture path is
# driven by $PI_STUB_SESSION_FILE so the same test can run both gate cases.
cat >"$stub_bin/pi" <<'STUB'
#!/usr/bin/env bash
session_dir=""
session_id=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-dir) session_dir="$2"; shift 2 ;;
    --session-id)  session_id="$2";  shift 2 ;;
    --provider|--model) shift 2 ;;
    --print) shift ;;
    *) shift ;;
  esac
done
if [[ -n "$session_dir" && -n "$session_id" && -n "${PI_STUB_SESSION_FILE:-}" ]]; then
  mkdir -p "$session_dir"
  # Name pattern is <timestamp>_<session_id>.jsonl, same as real pi.
  now=$(date -u +%Y%m%dT%H%M%SZ)
  cp "$PI_STUB_SESSION_FILE" "$session_dir/${now}_${session_id}.jsonl"
fi
# fleet-ops#4976: the PR-URL line is opt-in (PI_STUB_PR_URL=1) so the test can
# run a blocked gate both with and without a shipped PR.
if [[ "${PI_STUB_PR_URL:-0}" == "1" ]]; then
  printf 'OK https://github.com/Nishfleet/fleet-ops/pull/9999\n'
else
  printf 'OK\n'
fi
printf 'The session completed and produced well over twenty bytes of output.\n'
exit 0
STUB
chmod +x "$stub_bin/pi"
export PI_BIN="$stub_bin/pi"

cat >"$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$stub_bin/gh"

cat >"$stub_bin/systemctl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$stub_bin/systemctl"

cat >"$stub_bin/worker-token" <<'STUB'
#!/usr/bin/env bash
printf 'export GH_TOKEN=fake-test-token-cccccccccccccccc\n'
exit 0
STUB
chmod +x "$stub_bin/worker-token"
export WORKER_TOKEN_BIN="$stub_bin/worker-token"

# Put the real fleet-debug-playbook on PATH (and stub_BIN before it for gh/pi/systemctl).
export PATH="$stub_bin:$repo_root/bin:/usr/local/bin:/usr/bin:/bin"

export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export PI_MODELS_JSON="$scratch/models.json"

cat >"$SEAT_CAPS_JSON" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": [],
  "providers": {
    "devin": {
      "cap": 4,
      "class": "subscription",
      "models": { "swe-1-7": 4 }
    }
  }
}
JSON

cat >"$PI_MODELS_JSON" <<'JSON'
{
  "providers": {
    "devin": {
      "models": [
        { "id": "swe-1-7", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 }
      ]
    }
  }
}
JSON

bad_session="$scratch/bad-session.jsonl"
cat >"$bad_session" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"a","name":"bash","arguments":{"command":"false"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"a","toolName":"bash","isError":true,"content":[{"type":"text","text":"Command exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"b","name":"bash","arguments":{"command":"false"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"b","toolName":"bash","isError":true,"content":[{"type":"text","text":"Command exited with code 1"}]}}
JSONL

good_session="$scratch/good-session.jsonl"
# Only one real failure + final text, so the gate has <2 failures and exits clean.
cat >"$good_session" <<'JSONL'
{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"ok","name":"bash","arguments":{"command":"true"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"ok","toolName":"bash","isError":false,"content":[{"type":"text","text":"ok"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Done. SIGNATURE: run passed. ROOT CAUSE: typo. FIX THAT WORKED: edit. DEAD ENDS: none."}]}}
JSONL

pkt="$ISSUES_DIR/dp-gate.in"
mkdir -p "$ISSUES_DIR"
cat >"$pkt" <<'EOF'
TARGET: repo Nishfleet/fleet-ops issue 2005 unit dp-gate
EOF

export FLEET_DEBUG_PLAYBOOK_GATE=1
export FLEET_DEBUG_PLAYBOOK_BIN="$repo_root/bin/fleet-debug-playbook"
export FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md"

# --- 1. missing playbook blocks the successful session close -----------------
rm -f "$ISSUES_DIR/dp-gate.out" "$ISSUES_DIR/dp-gate.err" "$STATE_DIR/attempts/pi-issue-dp-gate.tried-seats" "$FLEET_HEARTBEAT_TRIAGE"
export PI_STUB_SESSION_FILE="$bad_session"
export PI_STUB_PR_URL=0
set +e
"$bin" dp-gate >"$scratch/out1" 2>"$scratch/err1"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "missing playbook must block close (rc=$rc); err=$(cat "$scratch/err1")"
grep -q 'DEBUG-PLAYBOOK-GATE-BLOCK' "$scratch/err1" \
  || fail "expected DEBUG-PLAYBOOK-GATE-BLOCK in stderr; got $(cat "$scratch/err1")"
ok "pi-issue-run blocks a missing-playbook session from exiting 0"

# --- 2. clean session (or <2 failures) passes the gate ----------------------
rm -f "$ISSUES_DIR/dp-gate.out" "$ISSUES_DIR/dp-gate.err" "$STATE_DIR/attempts/pi-issue-dp-gate.tried-seats"
export PI_STUB_SESSION_FILE="$good_session"
export PI_STUB_PR_URL=0
set +e
"$bin" dp-gate >"$scratch/out2" 2>"$scratch/err2"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "clean session must close (rc=$rc); err=$(cat "$scratch/err2")"
grep -q 'DEBUG-PLAYBOOK-GATE-OK' "$scratch/err2" \
  || fail "expected DEBUG-PLAYBOOK-GATE-OK in stderr; got $(cat "$scratch/err2")"
ok "pi-issue-run lets a clean session close"

# --- 3. fleet-ops#4976: blocked gate + shipped PR exits 0 --------------------
# A bad session (gate blocks) that still shipped a PR must NOT exit 1 — the
# deliverable exists, so Restart=on-failure re-dispatch would re-claim an
# already-delivered issue. The gate's LOUD filing must still fire.
rm -f "$ISSUES_DIR/dp-gate.out" "$ISSUES_DIR/dp-gate.err" "$STATE_DIR/attempts/pi-issue-dp-gate.tried-seats" "$FLEET_HEARTBEAT_TRIAGE"
export PI_STUB_SESSION_FILE="$bad_session"
export PI_STUB_PR_URL=1
set +e
"$bin" dp-gate >"$scratch/out3" 2>"$scratch/err3"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "blocked gate with shipped PR must exit 0 (rc=$rc); err=$(cat "$scratch/err3")"
grep -q 'debug-playbook-gate-block-pr-shipped' "$scratch/err3" \
  || fail "expected debug-playbook-gate-block-pr-shipped in stderr; got $(cat "$scratch/err3")"
grep -q 'DEBUG-PLAYBOOK-GATE-BLOCK' "$scratch/err3" \
  || fail "gate block must still be LOUD on stderr; got $(cat "$scratch/err3")"
grep -q 'DEBUG-PLAYBOOK-GATE-BLOCK' "$FLEET_HEARTBEAT_TRIAGE" \
  || fail "gate block must still be LOUD-filed to triage; got $(cat "$FLEET_HEARTBEAT_TRIAGE" 2>/dev/null || echo '<missing>')"
ok "pi-issue-run exits 0 on a blocked gate when the session shipped a PR"

echo "OK: pi-issue-run debug-playbook gate (fleet-ops#2005, fleet-ops#4976)"
