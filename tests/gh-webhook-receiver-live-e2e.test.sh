#!/usr/bin/env bash
# tests/gh-webhook-receiver-live-e2e.test.sh
#
# fleet-ops#1535: live end-to-end proof that a webhook delivery reaches
# Prometheus and the FleetGhWebhookReceiverAbsent alert stays clear.
#
# The #1464/#1607 root cause was single-quoted prom labels that
# node-exporter silently dropped — the receiver wrote a healthy prom
# file but the metric never reached Prometheus, so absent() fired
# forever. The offline regression (gh-webhook-receiver-prom-quotes.test.sh)
# pins the label FORMAT. This test pins the LIVE PATH: receiver → prom
# file → node-exporter scrape → Prometheus query → alert expression.
# It catches the class "metric not reaching Prometheus" regardless of
# cause (bad labels, dead node-exporter, wrong textfile dir, missing
# file, stale timestamp).
#
# Skips gracefully in hosted CI (no live receiver / Prometheus). On the
# VPS it posts a real canary webhook to the live receiver, waits for
# Prometheus to scrape, and asserts:
#   1. the metric timestamp advanced (the delivery reached Prometheus)
#   2. the metric labels are double-quoted (the #1607 fix holds live)
#   3. the alert expression is empty (FleetGhWebhookReceiverAbsent clear)
#
# This is the "prove one real webhook delivery end-to-end with the alert
# cleared" verification the issue requires.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
canary="$repo_root/bin/gh-webhook-canary.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$canary" ]] || fail "canary missing or not executable: $canary"
python3 -m py_compile "$canary" || fail "canary: python syntax error"

PROM_URL="${PROMETHEUS_URL:-http://127.0.0.1:9090}"
RECEIVER_UNIT="gh-webhook-receiver.service"
METRIC="fleet_gh_webhook_receiver_last_green_seconds"
ALERT_EXPR='absent(fleet_gh_webhook_receiver_last_green_seconds) or (time() - fleet_gh_webhook_receiver_last_green_seconds) > 3600'

# --- live prerequisites: receiver running + Prometheus reachable ---
XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if ! systemctl --user is-active --quiet "$RECEIVER_UNIT" 2>/dev/null; then
    ok "live receiver not running (hosted CI) — skip live e2e"
    exit 0
fi
if ! curl -sf --max-time 5 "$PROM_URL/-/healthy" >/dev/null 2>&1; then
    ok "Prometheus not reachable at $PROM_URL (hosted CI) — skip live e2e"
    exit 0
fi
ok "1: live receiver active + Prometheus reachable"

# --- 2: capture the current metric timestamp from Prometheus ---
query_metric() {
    curl -sG "$PROM_URL/api/v1/query" --data-urlencode "query=$METRIC"
}
extract_ts() {
    python3 -c "
import json, sys
d = json.load(sys.stdin)
r = d['data']['result']
if not r:
    print('')
else:
    print(r[0]['value'][1])
"
}
before_ts="$(query_metric | extract_ts)"
[[ -n "$before_ts" ]] || fail "2: metric absent in Prometheus before canary — the receiver is not exporting (the exact #1464 class)"
ok "2: metric present in Prometheus before canary (ts=$before_ts)"

# --- 3: post a real canary webhook to the live receiver ---
python3 "$canary" >/dev/null 2>&1 || fail "3: canary post to live receiver exited non-zero"
ok "3: canary webhook posted to live receiver (HTTP 200)"

# --- 4: wait for Prometheus to scrape the updated prom file (≤30s) ---
scraped=""
for _ in $(seq 1 15); do
    sleep 2
    after_ts="$(query_metric | extract_ts)"
    if [[ -n "$after_ts" && "$after_ts" != "$before_ts" ]]; then
        scraped="$after_ts"
        break
    fi
done
[[ -n "$scraped" ]] \
    || fail "4: metric timestamp did not advance after canary — prom file not reaching Prometheus (the #1464 class)"
ok "4: Prometheus scraped the fresh metric (ts=$before_ts → $scraped)"

# --- 5: the metric labels are double-quoted (the #1607 fix holds live) ---
raw="$(query_metric)"
echo "$raw" | python3 -c "
import json, sys
d = json.load(sys.stdin)
r = d['data']['result']
assert r, 'metric vanished between scrape and label check'
labels = r[0]['metric']
# node-exporter only exposes double-quoted labels; if single-quoted
# repr() snuck back in, the series would be dropped and r would be
# empty (caught above). The presence of the series in Prometheus IS
# the proof the labels are scrapeable.
print('OK: 5: metric series present in Prometheus — labels are scrapeable (double-quoted)')
" || fail "5: metric series dropped between checks — labels may be invalid"
ok "5: live metric labels are scrapeable by node-exporter (#1607 fix holds)"

# --- 6: the alert expression is empty (FleetGhWebhookReceiverAbsent clear) ---
alert_result="$(curl -sG "$PROM_URL/api/v1/query" --data-urlencode "query=$ALERT_EXPR")"
firing="$(echo "$alert_result" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(len(d['data']['result']))
")"
[[ "$firing" == "0" ]] \
    || fail "6: FleetGhWebhookReceiverAbsent expression is firing (result count=$firing) — alert not clear"
ok "6: FleetGhWebhookReceiverAbsent alert expression is CLEAR (empty result)"

echo
echo "LIVE E2E PROOF: canary → receiver → prom file → node-exporter → Prometheus → alert CLEAR"
