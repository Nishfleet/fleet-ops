#!/usr/bin/env bash
# tests/gh-webhook-receiver-hmac.test.sh
#
# fleet-ops#1464: proves the VPS-side gh-webhook-receiver (libexec/
# gh-webhook-receiver/serve.py) in a real running subprocess. We do NOT
# shell-mock: we start the server on an ephemeral port, sign real
# payloads with real HMACs, and assert the dispatcher picks the right
# unit (or the right "ignored" reason).
#
# Proves:
#   1. serve.py compiles and the module-level helpers (verify_hmac,
#      dispatch, fire_unit in DRY=1) behave as documented.
#   2. A valid issues/labeled/agent-ready payload dispatches
#      pi-intake@<repo>.service.
#   3. A valid workflow_run/completed/success dispatches
#      fleet-deploy-check.service.
#   4. A tampered body returns 401 (HMAC FAIL — fail-closed).
#   5. An unknown event returns 200 with "ignored" (Worker must always
#      see 200; the receiver never bounces).
#   6. A bad repo name returns 200 with "ignored: bad repo".
#   7. The /healthz endpoint returns 200 + JSON without auth.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
serve="$repo_root/libexec/gh-webhook-receiver/serve.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$serve" ]] || fail "missing: $serve"
python3 -m py_compile "$serve" || fail "serve.py: python syntax error"
ok "1: serve.py compiles"

# --- DRY mode unit checks: import the module directly and exercise the
# module-level helpers (verify_hmac, dispatch). The subprocess phase
# below exercises the HTTP layer.
python3 - "$serve" <<'PYEOF' || fail "DRY unit checks failed"
import hmac
import hashlib
import importlib.util
import json
import sys

path = sys.argv[1]
spec = importlib.util.spec_from_file_location("serve", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

secret = b"unit-test-secret"
body = b'{"action":"labeled","label":{"name":"agent-ready"}}'
sig = "sha256=" + hmac.new(secret, body, hashlib.sha256).hexdigest()

# valid signature
assert mod.verify_hmac(secret, body, sig) is True, "valid signature must pass"
# tampered body
assert mod.verify_hmac(secret, body + b"x", sig) is False, "tampered body must fail"
# wrong scheme
assert mod.verify_hmac(secret, body, "sha1=" + sig.split("=", 1)[1]) is False, \
    "sha1 scheme must fail"
# missing scheme
assert mod.verify_hmac(secret, body, "") is False, "empty header must fail"
# malformed hex
assert mod.verify_hmac(secret, body, "sha256=not-hex") is False, \
    "malformed hex must fail"
assert mod.verify_hmac(secret, body, "sha256=zz") is False
# wrong secret
bad = hmac.new(b"other", body, hashlib.sha256).hexdigest()
assert mod.verify_hmac(secret, body, "sha256=" + bad) is False

# dispatch table (no dry — but we want the unit name, not the fire call)
unit, reason = mod.dispatch("issues", "labeled", "agent-ready", "fleet-ops",
                            "", dry=False)
assert unit == "pi-intake@fleet-ops.service", unit
assert "issues/labeled/agent-ready" in reason, reason

unit, reason = mod.dispatch("issues", "labeled", "pipeline-red", "fleet-ops",
                            "", dry=False)
assert unit == "fleet-deploy-check.service", unit

unit, reason = mod.dispatch("workflow_run", "completed", "", "fleet-ops",
                            "success", dry=False)
assert unit == "fleet-deploy-check.service", unit

unit, reason = mod.dispatch("issues", "labeled", "do-not-route",
                            "fleet-ops", "", dry=False)
assert unit == "", unit
assert "ignored" in reason, reason

unit, reason = mod.dispatch("issues", "labeled", "agent-ready", "bad repo name!",
                            "", dry=False)
assert unit == "", unit
assert "bad repo" in reason, reason

unit, reason = mod.dispatch("ping", "", "", "", "", dry=False)
assert unit == "", unit
assert "ping" in reason, reason

unit, reason = mod.dispatch("unknown_event", "x", "y", "z", "w", dry=False)
assert unit == "", unit
assert "unknown" in reason, reason

print("DRY unit checks OK")
PYEOF
ok "2: HMAC verify + dispatch table behave as documented"

# --- Subprocess phase: run the HTTP server on an ephemeral port and
# exercise the real /webhook and /healthz endpoints.
scratch="$(mktemp -d -t gh-webhook-rx.XXXXXX)"
trap 'rm -rf "$scratch"; kill "$server_pid" 2>/dev/null || true' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME/.config/fleet-ops"
echo -n "live-secret-$(date +%s)" > "$HOME/.config/fleet-ops/gh-webhook.secret"
chmod 600 "$HOME/.config/fleet-ops/gh-webhook.secret"

# Bind to an ephemeral port + DRY=1 so the dispatch is a no-op (we are
# not actually firing pi-intake@fleet-ops.service — that would spawn a
# real worker unit). We pick a free port via python instead of letting
# the server bind to port 0 (the server has no way to expose the picked
# port back to the test).
export GH_WEBHOOK_SECRET_FILE="$HOME/.config/fleet-ops/gh-webhook.secret"
export GH_WEBHOOK_RECEIVER_BIND="127.0.0.1"
export GH_WEBHOOK_RECEIVER_DRY="1"
export GH_WEBHOOK_RECEIVER_PROM="$scratch/receiver.prom"
# Pick an unused TCP port via the stdlib so two parallel test runs do
# not collide. If another run grabbed it first, the curl loop will
# timeout and the test will fail loud.
TEST_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
export GH_WEBHOOK_RECEIVER_PORT="$TEST_PORT"

python3 "$serve" &
server_pid=$!
# Wait for the server to come up (it logs to stderr; /healthz is the probe).
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null -w "%{http_code}" "http://127.0.0.1:$TEST_PORT/healthz" 2>/dev/null | grep -q 200; then
        break
    fi
    sleep 0.1
done

# --- 3: valid issues/labeled/agent-ready → dispatched unit name ---
secret="$(cat "$HOME/.config/fleet-ops/gh-webhook.secret")"
body='{"action":"labeled","label":{"name":"agent-ready"},"issue":{"number":1464},"repository":{"name":"fleet-ops"}}'
sig="sha256=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$secret" -hex | awk '{print $NF}')"
resp="$(curl -sS -X POST "http://127.0.0.1:$TEST_PORT/webhook" \
    -H "Content-Type: application/json" \
    -H "X-GitHub-Event: issues" \
    -H "X-GitHub-Delivery: test-1464" \
    -H "X-Hub-Signature-256: $sig" \
    -w "\n%{http_code}" --data "$body")"
status="$(printf '%s' "$resp" | tail -n1)"
body_resp="$(printf '%s' "$resp" | head -n-1)"
[[ "$status" == "200" ]] || fail "3: valid issues/labeled/agent-ready got $status; body=$body_resp"
echo "$body_resp" | grep -q '"dispatched": "pi-intake@fleet-ops.service"' \
    || fail "3: dispatched unit not in response: $body_resp"
ok "3: valid issues/labeled/agent-ready → pi-intake@fleet-ops.service (DRY=1)"

# --- 4: tampered body → 401 ---
body_tampered='{"action":"closed"}'
resp="$(curl -sS -X POST "http://127.0.0.1:$TEST_PORT/webhook" \
    -H "Content-Type: application/json" \
    -H "X-GitHub-Event: issues" \
    -H "X-Hub-Signature-256: $sig" \
    -w "\n%{http_code}" --data "$body_tampered")"
status="$(printf '%s' "$resp" | tail -n1)"
[[ "$status" == "401" ]] || fail "4: tampered body got $status; expected 401"
ok "4: tampered body → 401 (HMAC FAIL)"

# --- 5: unknown event → 200 + ignored ---
body_unknown='{"hello":"world"}'
sig_unknown="sha256=$(printf '%s' "$body_unknown" | openssl dgst -sha256 -hmac "$secret" -hex | awk '{print $NF}')"
resp="$(curl -sS -X POST "http://127.0.0.1:$TEST_PORT/webhook" \
    -H "Content-Type: application/json" \
    -H "X-GitHub-Event: star" \
    -H "X-Hub-Signature-256: $sig_unknown" \
    -w "\n%{http_code}" --data "$body_unknown")"
status="$(printf '%s' "$resp" | tail -n1)"
body_resp="$(printf '%s' "$resp" | head -n-1)"
[[ "$status" == "200" ]] || fail "5: unknown event got $status; expected 200"
echo "$body_resp" | grep -q '"ignored"' \
    || fail "5: unknown event must return ignored: $body_resp"
ok "5: unknown event → 200 + ignored"

# --- 6: bad repo name → 200 + ignored: bad repo ---
# REPO_RE rejects names with whitespace, slashes, or characters outside
# [A-Za-z0-9._-]. We use 'bad repo name!' which fails on the space and
# the bang. (Double-dot names like 'bad..repo' are intentionally ALLOWED
# by the regex — they match the per-repo systemd unit naming rules used
# elsewhere in the fleet.)
body_bad='{"action":"labeled","label":{"name":"agent-ready"},"repository":{"name":"bad repo name!"}}'
sig_bad="sha256=$(printf '%s' "$body_bad" | openssl dgst -sha256 -hmac "$secret" -hex | awk '{print $NF}')"
resp="$(curl -sS -X POST "http://127.0.0.1:$TEST_PORT/webhook" \
    -H "Content-Type: application/json" \
    -H "X-GitHub-Event: issues" \
    -H "X-Hub-Signature-256: $sig_bad" \
    -w "\n%{http_code}" --data "$body_bad")"
status="$(printf '%s' "$resp" | tail -n1)"
body_resp="$(printf '%s' "$resp" | head -n-1)"
[[ "$status" == "200" ]] || fail "6: bad repo got $status; expected 200"
echo "$body_resp" | grep -q 'bad repo' \
    || fail "6: bad repo must surface in response: $body_resp"
ok "6: bad repo name → 200 + ignored (defense-in-depth)"

# --- 7: workflow_run/completed/success → fleet-deploy-check ---
body_wf='{"action":"completed","workflow_run":{"conclusion":"success"},"repository":{"name":"fleet-ops"}}'
sig_wf="sha256=$(printf '%s' "$body_wf" | openssl dgst -sha256 -hmac "$secret" -hex | awk '{print $NF}')"
resp="$(curl -sS -X POST "http://127.0.0.1:$TEST_PORT/webhook" \
    -H "Content-Type: application/json" \
    -H "X-GitHub-Event: workflow_run" \
    -H "X-Hub-Signature-256: $sig_wf" \
    -w "\n%{http_code}" --data "$body_wf")"
status="$(printf '%s' "$resp" | tail -n1)"
body_resp="$(printf '%s' "$resp" | head -n-1)"
[[ "$status" == "200" ]] || fail "7: workflow_run got $status; expected 200"
echo "$body_resp" | grep -q '"dispatched": "fleet-deploy-check.service"' \
    || fail "7: workflow_run should dispatch fleet-deploy-check: $body_resp"
ok "7: workflow_run/completed/success → fleet-deploy-check.service"

# --- 8: /healthz works without auth ---
healthz="$(curl -sS "http://127.0.0.1:$TEST_PORT/healthz")"
echo "$healthz" | grep -q '"status": "ok"' || fail "8: /healthz body: $healthz"
echo "$healthz" | grep -q '"version"' || fail "8: /healthz missing version: $healthz"
ok "8: /healthz → 200 + JSON"

# --- 9: the prom file was written by the receiver ---
[[ -f "$GH_WEBHOOK_RECEIVER_PROM" ]] || fail "9: prom file not written: $GH_WEBHOOK_RECEIVER_PROM"
grep -q 'fleet_gh_webhook_receiver_last_green_seconds' "$GH_WEBHOOK_RECEIVER_PROM" \
    || fail "9: prom file missing heartbeat metric"
ok "9: receiver wrote heartbeat prom file"

# --- 10: prom counter advanced for each successful dispatch (2 in this
# test: the issues/labeled/agent-ready + the workflow_run/completed/success).
# Tampered bodies and ignored events do NOT increment — they fail before
# the dispatcher runs.
grep -E '^fleet_gh_webhook_receiver_dispatch_total 2$' "$GH_WEBHOOK_RECEIVER_PROM" \
    || fail "10: dispatch counter != 2 (expected exactly the two successful events): $(cat "$GH_WEBHOOK_RECEIVER_PROM")"
ok "10: dispatch counter advanced for every dispatched event (2 verified + dispatched)"

kill "$server_pid" 2>/dev/null || true
wait "$server_pid" 2>/dev/null || true
exit 0
