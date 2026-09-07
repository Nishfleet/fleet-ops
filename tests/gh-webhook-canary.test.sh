#!/usr/bin/env bash
# tests/gh-webhook-canary.test.sh
#
# fleet-ops#1464 pattern 2 — synthetic canary exercises the entire push
# channel end-to-end (Worker -> Tunnel -> Receiver -> systemd unit).
# In production the Worker + Tunnel live in Cloudflare, but the canary
# only needs to reach the VPS-side receiver to prove the path is alive.
# This test runs the canary in DRY=1 mode and asserts the HMAC + headers
# are well-formed; the live HTTP path is covered by
# tests/gh-webhook-receiver-hmac.test.sh.
#
# The dead-man is the FleetGhWebhookCanaryAbsent absent() rule in
# config/fleet_rules.yml plus an optional healthchecks.io ping-on-success
# (GH_WEBHOOK_HEALTHCHECKS_URL). The hand-built deadman unit was retired
# (fleet-ops#4146); this test covers the canary DRY shape and the
# healthchecks.io ping seam.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
canary="$repo_root/bin/gh-webhook-canary.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$canary" ]] || fail "canary missing or not executable: $canary"
python3 -m py_compile "$canary" || fail "canary: python syntax error"
ok "1: script compiles"

scratch="$(mktemp -d -t gh-webhook-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
export HOME="$scratch/home"
mkdir -p "$HOME/.config/fleet-ops"
echo -n "canary-secret-$(date +%s)" > "$HOME/.config/fleet-ops/gh-webhook.secret"
chmod 600 "$HOME/.config/fleet-ops/gh-webhook.secret"

export GH_WEBHOOK_CANARY_SECRET_FILE="$HOME/.config/fleet-ops/gh-webhook.secret"
export GH_WEBHOOK_CANARY_PROM="$scratch/canary.prom"
export GH_WEBHOOK_CANARY_DRY="1"

# --- 2: DRY output has the expected shape: X-GitHub-Event: issues +
# X-Hub-Signature-256: sha256=<hex> + a JSON body whose label.name is
# agent-ready and whose repo is fleet-ops-canary (clearly synthetic).
out="$(python3 "$canary")" || fail "2: canary DRY exited non-zero"
echo "$out" | grep -q "^---HEADERS---$" || fail "2: missing ---HEADERS--- marker"
echo "$out" | grep -q "^X-GitHub-Event: issues$" || fail "2: missing issues event header"
echo "$out" | grep -qE "^X-Hub-Signature-256: sha256=[0-9a-f]{64}$" \
    || fail "2: HMAC header malformed: $(echo "$out" | grep X-Hub)"
echo "$out" | grep -q "^---BODY---$" || fail "2: missing ---BODY--- marker"
echo "$out" | grep -q '"agent-ready"' || fail "2: payload missing agent-ready label"
echo "$out" | grep -q '"fleet-ops-canary"' || fail "2: payload missing synthetic repo name"
ok "2: DRY output: well-formed HMAC + issues event + agent-ready label + synthetic repo"

# --- 3: HMAC in DRY output matches the secret for the body it sent.
secret="$(cat "$HOME/.config/fleet-ops/gh-webhook.secret")"
body="$(echo "$out" | awk '/^---BODY---$/{flag=1; next} flag')"
header_sig="$(echo "$out" | grep -E '^X-Hub-Signature-256:' | sed -E 's/.*sha256=([0-9a-f]+).*/\1/')"
expected_sig="$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$secret" -hex | awk '{print $NF}')"
[[ "$header_sig" == "$expected_sig" ]] \
    || fail "3: HMAC mismatch — DRY header=$header_sig expected=$expected_sig body=$body"
ok "3: HMAC header matches secret for the synthetic body"

# --- 4: healthchecks.io ping-on-success seam (fleet-ops#4146). With
# GH_WEBHOOK_HEALTHCHECKS_URL set and DRY=1, the canary prints the ping
# it would make; with the URL empty it stays silent. The ping is
# best-effort and never fails the canary.
export GH_WEBHOOK_HEALTHCHECKS_URL="https://hc-ping.example/abc123"
out="$(python3 "$canary")" || fail "4: canary DRY with HC_URL exited non-zero"
echo "$out" | grep -q "would ping https://hc-ping.example/abc123" \
    || fail "4: DRY must print the healthchecks.io ping: $out"
ok "4: healthchecks.io ping-on-success seam prints in DRY mode"

export GH_WEBHOOK_HEALTHCHECKS_URL=""
out="$(python3 "$canary")" || fail "4b: canary DRY with empty HC_URL exited non-zero"
echo "$out" | grep -q "would ping" && fail "4b: empty HC_URL must not ping: $out"
ok "4b: empty healthchecks.io URL stays silent"
exit 0
