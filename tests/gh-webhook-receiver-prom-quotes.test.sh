#!/usr/bin/env bash
# tests/gh-webhook-receiver-prom-quotes.test.sh
#
# fleet-ops#1464 root-cause regression: the receiver's heartbeat prom
# file MUST use double-quoted label values. Python's repr() emits
# single quotes (unit='(ignored)') which node-exporter's textfile
# parser silently drops — the series vanishes, absent() fires forever,
# and FleetGhWebhookReceiverAbsent never clears even though the
# channel is provably alive (the synthetic canary is hitting it every
# 5 min). This is the exact live failure that reopened #1464.
#
# This test pins BOTH halves of the fix:
#   1. write_prom() double-quotes every label value (no single quotes).
#   2. the receiver bumps last_green_seconds on every VERIFIED event,
#      dispatched OR ignored — so the synthetic canary (non-enrolled
#      repo 'fleet-ops-canary') keeps the heartbeat green without
#      spawning a real intake tick.
#   3. a non-enrolled repo is NOT dispatched to pi-intake@<repo>
#      (enrollment guard — stops the canary from firing gh calls +
#      OnFailure repair units every 5 min on a non-existent repo).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
serve="$repo_root/libexec/gh-webhook-receiver/serve.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$serve" ]] || fail "missing: $serve"
python3 -m py_compile "$serve" || fail "serve.py: python syntax error"
ok "1: serve.py compiles"

# --- 2: write_prom emits double-quoted labels, never single-quoted ---
python3 - "$serve" <<'PYEOF' || fail "2: prom label quoting is wrong"
import importlib.util, sys
path = sys.argv[1]
spec = importlib.util.spec_from_file_location("serve", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

import tempfile, os
fd, prom = tempfile.mkstemp(suffix=".prom")
os.close(fd)
try:
    mod.write_prom(prom, 1700000000.0, "pi-intake@fleet-ops.service",
                   0, 3, "issues")
    text = open(prom).read()
finally:
    os.unlink(prom)

# The headline metric line MUST use double-quoted labels.
import re
m = re.search(r'^fleet_gh_webhook_receiver_last_green_seconds\{[^}]*\} \d+$',
              text, re.MULTILINE)
assert m, f"heartbeat metric line missing in:\n{text}"
line = m.group(0)
# Double-quoted label values are valid Prometheus exposition format.
assert 'unit="pi-intake@fleet-ops.service"' in line, \
    f"label not double-quoted: {line}"
# Single-quoted labels (Python repr) are the bug — node-exporter drops them.
assert "unit='" not in line, \
    f"single-quoted label found (the #1464 root cause): {line}"
assert "event=\"issues\"" in line, f"event label not double-quoted: {line}"
print("write_prom double-quotes labels OK")
PYEOF
ok "2: write_prom emits double-quoted labels (no single-quote repr)"

# --- 3: dispatch() refuses pi-intake@<repo> for a non-enrolled repo ---
python3 - "$serve" <<'PYEOF' || fail "3: enrollment guard missing"
import importlib.util, sys
path = sys.argv[1]
spec = importlib.util.spec_from_file_location("serve", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# fleet-ops#3270: dispatch() now returns a list of (unit, reason) pairs
# (multi-fan-out). first_fireable returns the first non-empty unit, or
# the sentinel ("", reason) for an ignored event.
def first_fireable(pairs):
    for u, r in pairs:
        if u:
            return u, r
    if pairs:
        return pairs[0]
    return "", ""

# Enrolled set does NOT contain the synthetic canary repo.
enrolled = {"fleet-ops", "0509"}

# canary repo → NOT dispatched (enrollment guard)
unit, reason = first_fireable(mod.dispatch("issues", "labeled", "agent-ready",
                            "fleet-ops-canary", "", dry=True,
                            enrolled=enrolled))
assert unit == "", f"canary repo must NOT dispatch, got unit={unit!r}"
assert "not enrolled" in reason, f"reason must name enrollment: {reason!r}"

# enrolled repo → dispatched (pi-intake is in the fan-out alongside
# lifecycle-label-sweep; fleet-ops#3270).
pairs = mod.dispatch("issues", "labeled", "agent-ready",
                     "fleet-ops", "", dry=True, enrolled=enrolled)
fireable = [u for u, _ in pairs if u]
assert "pi-intake@fleet-ops.service" in fireable, fireable

# fleet-deploy-check is fleet-wide, NOT enrollment-gated (pipeline-red)
unit, reason = first_fireable(mod.dispatch("issues", "labeled", "pipeline-red",
                            "fleet-ops-canary", "", dry=True,
                            enrolled=enrolled))
assert unit == "fleet-deploy-check.service", \
    f"pipeline-red must dispatch regardless of enrollment: {unit!r}"

# workflow_run/completed/success is fleet-wide, NOT enrollment-gated
unit, reason = first_fireable(mod.dispatch("workflow_run", "completed", "",
                            "fleet-ops-canary", "success", dry=True,
                            enrolled=enrolled))
assert unit == "fleet-deploy-check.service", \
    f"workflow_run must dispatch regardless of enrollment: {unit!r}"

# enrolled=None (legacy callers / tests) → no gating, backwards compatible
pairs = mod.dispatch("issues", "labeled", "agent-ready",
                     "fleet-ops", "", dry=True, enrolled=None)
fireable = [u for u, _ in pairs if u]
assert "pi-intake@fleet-ops.service" in fireable, fireable
print("enrollment guard OK")
PYEOF
ok "3: dispatch() gates pi-intake on enrollment, leaves fleet-deploy-check ungated"

# --- 4: end-to-end — an ignored (non-enrolled) event still bumps the
# heartbeat, via the real HTTP server in DRY mode. This is the live
# behaviour that makes the synthetic canary keep the alert green. ---
scratch="$(mktemp -d -t gh-webhook-rx-prom.XXXXXX)"
trap 'rm -rf "$scratch"; kill "$server_pid" 2>/dev/null || true' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME/.config/fleet-ops"
echo -n "prom-quote-secret-$(date +%s)" > "$HOME/.config/fleet-ops/gh-webhook.secret"
chmod 600 "$HOME/.config/fleet-ops/gh-webhook.secret"

# Point intake-repos at a scratch file that does NOT enroll the canary
# repo, so the canary event is ignored by the dispatch table.
intake_json="$scratch/intake-repos.json"
cat > "$intake_json" <<'JSON'
{"repos": [{"name": "fleet-ops"}, {"name": "0509"}]}
JSON

export GH_WEBHOOK_SECRET_FILE="$HOME/.config/fleet-ops/gh-webhook.secret"
export GH_WEBHOOK_INTAKE_REPOS="$intake_json"
export GH_WEBHOOK_RECEIVER_BIND="127.0.0.1"
export GH_WEBHOOK_RECEIVER_DRY="1"
export GH_WEBHOOK_RECEIVER_PROM="$scratch/receiver.prom"
TEST_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
export GH_WEBHOOK_RECEIVER_PORT="$TEST_PORT"

python3 "$serve" &
server_pid=$!
for _ in $(seq 1 30); do
    if curl -sS -o /dev/null -w "%{http_code}" "http://127.0.0.1:$TEST_PORT/healthz" 2>/dev/null | grep -q 200; then
        break
    fi
    sleep 0.1
done

secret="$(cat "$HOME/.config/fleet-ops/gh-webhook.secret")"
# Synthetic canary payload — repo 'fleet-ops-canary' is NOT enrolled.
body='{"action":"labeled","label":{"name":"agent-ready"},"issue":{"number":999999},"repository":{"name":"fleet-ops-canary"}}'
sig="sha256=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$secret" -hex | awk '{print $NF}')"
resp="$(curl -sS -X POST "http://127.0.0.1:$TEST_PORT/webhook" \
    -H "Content-Type: application/json" \
    -H "X-GitHub-Event: issues" \
    -H "X-GitHub-Delivery: prom-quote-test" \
    -H "X-Hub-Signature-256: $sig" \
    -w "\n%{http_code}" --data "$body")"
status="$(printf '%s' "$resp" | tail -n1)"
body_resp="$(printf '%s' "$resp" | head -n-1)"
[[ "$status" == "200" ]] || fail "4: canary event got $status; body=$body_resp"
echo "$body_resp" | grep -q '"received": true' \
    || fail "4: canary event not received: $body_resp"
echo "$body_resp" | grep -q '"ignored"' \
    || fail "4: non-enrolled canary must be ignored (not dispatched): $body_resp"
ok "4: non-enrolled canary event → 200 + ignored (no dispatch)"

# The prom file MUST now carry a fresh, double-quoted heartbeat.
[[ -f "$GH_WEBHOOK_RECEIVER_PROM" ]] || fail "5: prom file not written"
prom_text="$(cat "$GH_WEBHOOK_RECEIVER_PROM")"
# Heartbeat bumped (not the startup 0.0).
hb_line="$(printf '%s\n' "$prom_text" | grep -E '^fleet_gh_webhook_receiver_last_green_seconds\{')"
[[ -n "$hb_line" ]] || fail "5: heartbeat metric line missing in prom file"
printf '%s\n' "$hb_line" | grep -qE 'unit="[^"]*"' \
    || fail "5: heartbeat label not double-quoted: $hb_line"
printf '%s\n' "$hb_line" | grep -q "unit='" \
    && fail "5: single-quoted label found (the #1464 root cause): $hb_line" || true
# The timestamp must be > 0 (bumped by the verified receive, not the
# startup write_prom(0.0, ...)).
ts="$(printf '%s\n' "$hb_line" | awk '{print $NF}')"
[[ "$ts" -gt 1700000000 ]] \
    || fail "5: heartbeat not bumped by verified receive (ts=$ts): $hb_line"
# dispatch_total stays 0 — the canary was ignored, not dispatched.
printf '%s\n' "$prom_text" | grep -qE '^fleet_gh_webhook_receiver_dispatch_total 0$' \
    || fail "5: dispatch_total must stay 0 for an ignored event: $prom_text"
ok "5: ignored canary event bumped the heartbeat (double-quoted), dispatch_total stayed 0"

kill "$server_pid" 2>/dev/null || true
wait "$server_pid" 2>/dev/null || true
exit 0
