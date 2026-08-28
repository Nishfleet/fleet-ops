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

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
canary="$repo_root/bin/gh-webhook-canary.py"
deadman="$repo_root/bin/gh-webhook-canary-deadman.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$canary" ]] || fail "canary missing or not executable: $canary"
[[ -x "$deadman" ]] || fail "deadman missing or not executable: $deadman"
python3 -m py_compile "$canary" || fail "canary: python syntax error"
python3 -m py_compile "$deadman" || fail "deadman: python syntax error"
ok "1: scripts compile"

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

# --- 4: deadman dry-run reports status when prom file is missing.
export GH_WEBHOOK_CANARY_PROM="$scratch/never-written.prom"
export GH_WEBHOOK_DEADMAN_DRY="1"
export GH_WEBHOOK_DEADMAN_TRIAGE_FILE="$scratch/triage.md"
export GH_WEBHOOK_DEADMAN_STALE_AFTER="900"
out="$(python3 "$deadman")" || fail "4: deadman DRY exited non-zero"
echo "$out" | grep -q "status=missing" \
    || fail "4: deadman must report status=missing when prom absent: $out"
ok "4: deadman DRY: status=missing when prom absent"

# --- 5: deadman dry-run reports status=stale when prom is older than
# the threshold. We synthesise a fake prom file with a ts from the
# dawn of time.
fake_prom="$scratch/old.prom"
{
    echo "# HELP fleet_gh_webhook_canary_last_green_seconds epoch"
    echo "# TYPE fleet_gh_webhook_canary_last_green_seconds gauge"
    echo "fleet_gh_webhook_canary_last_green_seconds 1000000000"
} > "$fake_prom"
export GH_WEBHOOK_CANARY_PROM="$fake_prom"
export GH_WEBHOOK_DEADMAN_STALE_AFTER="900"
out="$(python3 "$deadman")" || fail "5: deadman DRY exited non-zero"
echo "$out" | grep -q "status=stale" \
    || fail "5: deadman must report status=stale when prom old: $out"
ok "5: deadman DRY: status=stale when prom older than threshold"

# --- 6: deadman dry-run reports status=ok when prom is fresh.
fresh_prom="$scratch/fresh.prom"
{
    echo "# HELP fleet_gh_webhook_canary_last_green_seconds epoch"
    echo "# TYPE fleet_gh_webhook_canary_last_green_seconds gauge"
    echo "fleet_gh_webhook_canary_last_green_seconds $(date -u +%s)"
} > "$fresh_prom"
export GH_WEBHOOK_CANARY_PROM="$fresh_prom"
out="$(python3 "$deadman")" || fail "6: deadman DRY exited non-zero on fresh prom"
echo "$out" | grep -q "status=ok" \
    || fail "6: deadman must report status=ok when prom fresh: $out"
ok "6: deadman DRY: status=ok when prom fresh"

# --- 7: deadman LIVE: with status=stale, it appends to the triage file
# and writes fleet_gh_webhook_canary_deadman_paged_total to the prom.
export GH_WEBHOOK_DEADMAN_DRY=""
export GH_WEBHOOK_DEADMAN_TRIAGE_FILE="$scratch/triage.md"
export GH_WEBHOOK_CANARY_PROM="$fake_prom"
out="$(python3 "$deadman" 2>&1)" || true  # exits 1 by design when paging
[[ -s "$scratch/triage.md" ]] || fail "7: triage file empty: $(ls -la $scratch/triage.md 2>&1)"
grep -q 'gh-webhook-canary-deadman' "$scratch/triage.md" \
    || fail "7: triage file missing deadman marker: $(cat $scratch/triage.md)"
grep -q '^fleet_gh_webhook_canary_deadman_paged_total 1$' "$fake_prom" \
    || fail "7: paged_total counter not in prom: $(cat $fake_prom)"
ok "7: deadman LIVE: triage file written + paged_total counter advanced"

# --- 8: deadman LIVE throttle: a second run within the throttle window
# does NOT re-page (the triage file is unchanged, paged_total stays 1).
before="$(wc -c < "$scratch/triage.md")"
out="$(python3 "$deadman" 2>&1)" || true
after="$(wc -c < "$scratch/triage.md")"
[[ "$before" == "$after" ]] || fail "8: throttle failed: triage file grew from $before to $after"
grep -q '^fleet_gh_webhook_canary_deadman_paged_total 1$' "$fake_prom" \
    || fail "8: throttle must not re-increment paged_total: $(grep deadman $fake_prom)"
ok "8: deadman LIVE: throttle prevents re-paging within 30m"
exit 0
