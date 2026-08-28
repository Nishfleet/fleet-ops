#!/usr/bin/env bash
# tests/gh-webhook-organ-heartbeat.test.sh
#
# fleet-ops#1464 — every new fleet organ (gh-webhook-receiver +
# gh-webhook-canary) ships an absent() heartbeat rule in
# config/fleet_rules.yml in the same PR (fleet-ops#1010 standing
# pattern). This test proves the registry + the absent() rules are
# wired together and that the organ-heartbeat gate would not REJECT this
# PR on that basis.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-organ-heartbeat-check"
registry="$repo_root/config/fleet-organs.json"
rules="$repo_root/config/fleet_rules.yml"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "missing or not executable: $bin"
[[ -f "$registry" ]] || fail "missing: $registry"
[[ -f "$rules" ]] || fail "missing: $rules"

# --- 1: registry has the two new organs with the right heartbeat_metric
python3 - "$registry" <<'PY' || fail "1: registry missing new organs"
import json, sys
data = json.load(open(sys.argv[1]))
organs = {o["name"]: o for o in data["organs"]}
assert "gh-webhook-receiver" in organs, "gh-webhook-receiver organ missing"
assert "gh-webhook-canary" in organs, "gh-webhook-canary organ missing"
rx = organs["gh-webhook-receiver"]
assert rx["heartbeat_metric"] == "fleet_gh_webhook_receiver_last_green_seconds", rx
assert rx["absent_alert"] == "FleetGhWebhookReceiverAbsent", rx
assert "libexec/gh-webhook-receiver/serve.py" in rx["files"]
assert "systemd/gh-webhook-receiver.service" in rx["files"]
cn = organs["gh-webhook-canary"]
assert cn["heartbeat_metric"] == "fleet_gh_webhook_canary_last_green_seconds", cn
assert cn["absent_alert"] == "FleetGhWebhookCanaryAbsent", cn
assert "bin/gh-webhook-canary" in cn["files"]
assert "bin/gh-webhook-canary-deadman" in cn["files"]
assert "systemd/gh-webhook-canary.timer" in cn["files"]
assert "systemd/gh-webhook-canary-deadman.timer" in cn["files"]
print("registry OK")
PY
ok "1: registry has gh-webhook-receiver + gh-webhook-canary with right fields"

# --- 2: rules carry both absent() expressions for the new metrics.
grep -q 'absent(fleet_gh_webhook_receiver_last_green_seconds)' "$rules" \
    || fail "2: FleetGhWebhookReceiverAbsent expr missing absent()"
grep -q 'FleetGhWebhookReceiverAbsent' "$rules" \
    || fail "2: FleetGhWebhookReceiverAbsent alert missing"
grep -q 'absent(fleet_gh_webhook_canary_last_green_seconds)' "$rules" \
    || fail "2: FleetGhWebhookCanaryAbsent expr missing absent()"
grep -q 'FleetGhWebhookCanaryAbsent' "$rules" \
    || fail "2: FleetGhWebhookCanaryAbsent alert missing"
grep -q 'fleet-ops#1464' "$rules" \
    || fail "2: rules must reference fleet-ops#1464"
ok "2: rules carry both absent() expressions and reference fleet-ops#1464"

# --- 3: the verify drill passes on the live repo (every registered
# organ has its rule, including the two new ones).
"$bin" verify >/tmp/organ-verify.out 2>&1 || {
    cat /tmp/organ-verify.out >&2
    fail "3: verify drill failed on the live repo"
}
grep -q 'gh-webhook-receiver -> FleetGhWebhookReceiverAbsent absent(' /tmp/organ-verify.out \
    || fail "3: verify drill did not name gh-webhook-receiver: $(cat /tmp/organ-verify.out)"
grep -q 'gh-webhook-canary -> FleetGhWebhookCanaryAbsent absent(' /tmp/organ-verify.out \
    || fail "3: verify drill did not name gh-webhook-canary: $(cat /tmp/organ-verify.out)"
ok "3: verify drill passes; both new organs wired to absent() rules"

# --- 4: gate dry-run on the actual diff against origin/main would not
# REJECT. We approximate by running the gate against a synthetic name-
# status that touches the new organ files; if the gate had no missing
# rule, it would exit 1.
ns="$(mktemp)"
trap 'rm -f "$ns"' EXIT INT TERM
{
    echo "M\tlibexec/gh-webhook-receiver/serve.py"
    echo "M\tbin/gh-webhook-canary"
    echo "M\tbin/gh-webhook-canary-deadman"
    echo "M\tsystemd/gh-webhook-receiver.service"
    echo "M\tsystemd/gh-webhook-canary.timer"
    echo "M\tsystemd/gh-webhook-canary-deadman.timer"
} > "$ns"
"$bin" gate \
    --name-status "$ns" \
    --rules "$rules" \
    --rules-diff /dev/null \
    --body /dev/null \
    --registry "$registry" \
    >/tmp/organ-gate.out 2>&1 \
    || { cat /tmp/organ-gate.out >&2; fail "4: gate simulated REJECT on the new organ files"; }
ok "4: gate would PASS on the new organ files (absent() rules ship in same PR)"
exit 0
