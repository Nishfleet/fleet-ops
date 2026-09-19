#!/usr/bin/env bash
# tests/ci-queue-alerts.test.sh
#
# fleet-ops#5807: merge-queue head wait + hosted-CI queue depth detector.
# Hermetic: gh is stubbed on PATH, the probe textfile is redirected with
# FLEET_PROM_OUT, and bin/am-executor-claim is drilled with a synthetic
# Alertmanager payload. Proves:
#
#   1. promtool check accepts config/fleet_rules.yml.
#   2. promtool test rules on the issue's 10:50 IST snapshot fires BOTH
#      CiMergeQueueHeadWaitHigh and CiHostedQueueDepthHigh (and
#      FleetProbeStale on the producer-dead case); the below-threshold
#      control repo fires neither.
#   3. The probe emits every ci_* series for the enrolled set from stubbed
#      API answers — totals, by_workflow splits, per-workflow median, and the
#      merge-queue head wait — and SKIPS the GraphQL call while the App core
#      budget is under the fleet-ops#5762 20% floor.
#   4. Drill: a synthetic 25-min head wait firing through am-executor-claim
#      dispatches a packet (payload reaches the command's stdin naming the
#      alert and the consolidation issues), and the claim clears on exit —
#      the next firing dispatches again.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
probe="$repo_root/libexec/fleet-metrics-probe.sh"
rules="$repo_root/config/fleet_rules.yml"
fixture="$here/fixtures/ci-queue-alerts.promtool.yml"
claim_bin="$repo_root/bin/am-executor-claim"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

TD="$(mktemp -d)"
trap 'rm -rf "$TD"' EXIT INT TERM
mkdir -p "$TD/bin"

command -v promtool >/dev/null || fail "promtool not on PATH"
command -v jq >/dev/null || fail "jq not on PATH"

# --- 1. rules file is valid -------------------------------------------------
promtool check rules "$rules" >/dev/null || fail "promtool check rules failed"
ok "promtool check rules $rules"

# --- 2. promtool unit test on the 10:50 IST snapshot ------------------------
promtool test rules "$fixture" >/dev/null || fail "promtool test rules failed on the snapshot fixture"
ok "snapshot fixture fires both issue rules + FleetProbeStale, control repo silent"

# --- 3. probe emits the series from stubbed API answers ---------------------
# gh stub: dispatches on the endpoint arg; honours --jq like real gh.
# GH_FAKE_RATE_REMAINING overrides .rate.remaining for the gate case.
cat >"$TD/bin/gh" <<'EOF'
#!/bin/sh
endpoint=""; jq_expr=""; is_graphql=0
while [ $# -gt 0 ]; do
  case "$1" in
    api) shift ;;
    --jq) jq_expr="$2"; shift 2 ;;
    -f) shift 2 ;;
    *) endpoint="$1"; shift ;;
  esac
done
emit() { if [ -n "$jq_expr" ]; then jq -r "$jq_expr"; else cat; fi; }
case "$endpoint" in
  rate_limit)
    printf '{"rate":{"remaining":%s,"limit":5000}}\n' "${GH_FAKE_RATE_REMAINING:-4200}" | emit ;;
  graphql)
    enq=$(date -u -d "@$(( ${CI_PROBE_NOW:-$(date +%s)} - 1500 ))" +%Y-%m-%dT%H:%M:%SZ)
    printf '{"data":{"repository":{"mergeQueue":{"entries":{"totalCount":14,"nodes":[{"enqueuedAt":"%s"}]}}}}}\n' "$enq" | emit ;;
  *branch=main*)
    printf '{"workflow_runs":[{"conclusion":"success"}]}\n' | emit ;;
  *status=queued*)
    cat <<'JSON' | emit
{"total_count":58,"workflow_runs":[
 {"name":"ci"},{"name":"ci"},{"name":"ci"},
 {"name":"p14"},{"name":"p14"},
 {"name":"CodeQL"}]}
JSON
    ;;
  *status=in_progress*)
    cat <<'JSON' | emit
{"total_count":11,"workflow_runs":[
 {"name":"ci"},{"name":"ci"},{"name":"p14"}]}
JSON
    ;;
  *status=completed*)
    cat <<'JSON' | emit
{"total_count":30,"workflow_runs":[
 {"name":"ci","run_started_at":"2026-09-19T10:00:00Z","updated_at":"2026-09-19T10:05:00Z"},
 {"name":"ci","run_started_at":"2026-09-19T10:10:00Z","updated_at":"2026-09-19T10:16:40Z"},
 {"name":"ci","run_started_at":"2026-09-19T10:20:00Z","updated_at":"2026-09-19T10:28:20Z"},
 {"name":"p14","run_started_at":"2026-09-19T10:00:00Z","updated_at":"2026-09-19T10:01:40Z"},
 {"name":"p14","run_started_at":"2026-09-19T10:05:00Z","updated_at":"2026-09-19T10:08:20Z"}]}
JSON
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TD/bin/gh"

run_probe() {
  env -i \
    HOME="$TD" \
    PATH="$TD/bin:/usr/bin:/bin" \
    FLEET_PROM_OUT="$TD/fleet.prom" \
    CI_PROBE_NOW=1774156800 \
    CI_PROBE_REPOS="0509" \
    ${GH_FAKE_RATE_REMAINING:+GH_FAKE_RATE_REMAINING="$GH_FAKE_RATE_REMAINING"} \
    /bin/sh "$probe"
}

run_probe || fail "probe exited non-zero"
[[ -s "$TD/fleet.prom" ]] || fail "probe did not write the textfile"
grep -q 'ci_merge_queue_head_wait_seconds{repo="0509"} 1500' "$TD/fleet.prom" \
  || fail "head wait: expected 1500 from enqueuedAt=NOW-1500; got: $(grep ci_merge_queue "$TD/fleet.prom")"
grep -q 'ci_merge_queue_entries{repo="0509"} 14' "$TD/fleet.prom" \
  || fail "merge-queue entries 14 not emitted"
grep -q 'ci_hosted_runs_queued{repo="0509"} 58' "$TD/fleet.prom" \
  || fail "queued total 58 not emitted (total_count must win over page length)"
grep -q 'ci_hosted_runs_in_progress{repo="0509"} 11' "$TD/fleet.prom" \
  || fail "in_progress total 11 not emitted"
grep -q 'ci_hosted_runs_queued_by_workflow{repo="0509",workflow="ci"} 3' "$TD/fleet.prom" \
  || fail "queued by_workflow split missing"
grep -q 'ci_hosted_runs_in_progress_by_workflow{repo="0509",workflow="p14"} 1' "$TD/fleet.prom" \
  || fail "in_progress by_workflow split missing"
# ci durations 300/400/500 -> median 400; p14 durations 100/200 -> lower median 100.
grep -q 'ci_workflow_run_median_seconds{repo="0509",workflow="ci"} 400' "$TD/fleet.prom" \
  || fail "median seconds wrong; got: $(grep ci_workflow "$TD/fleet.prom")"
grep -q 'ci_workflow_run_median_seconds{repo="0509",workflow="p14"} 100' "$TD/fleet.prom" \
  || fail "p14 median seconds wrong"
ok "probe emits totals, by_workflow splits, medians, and merge-queue head wait"

# Rate-limit floor: under 20% remaining the GraphQL block is skipped and the
# ci_merge_queue_* series are simply absent; REST series still emit.
GH_FAKE_RATE_REMAINING=800 run_probe || fail "probe (low-budget) exited non-zero"
if grep -q '^ci_merge_queue_' "$TD/fleet.prom"; then
  fail "merge-queue series emitted while App budget under the 20% floor"
fi
grep -q 'ci_hosted_runs_queued{repo="0509"} 58' "$TD/fleet.prom" \
  || fail "queued series missing on the low-budget run"
ok "under the #5762 20% floor the GraphQL call is skipped, REST series still emit"

# --- 4. drill: synthetic firing dispatches a packet and clears --------------
cat >"$TD/bin/systemctl" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TD/bin/systemctl"

state="$TD/alert-state"; mkdir -p "$state"
payload='{"status":"firing","commonLabels":{"alertname":"CiMergeQueueHeadWaitHigh","severity":"critical","repo":"0509"},"groupLabels":{"alertname":"CiMergeQueueHeadWaitHigh"},"alerts":[{"status":"firing","labels":{"alertname":"CiMergeQueueHeadWaitHigh","severity":"critical","repo":"0509"},"annotations":{"summary":"synthetic 25-min head wait drill","description":"consolidation issues Nishfleet/0509#3069, Nishfleet/0509#3068, Nishfleet/0509#3070"}}]}'

run_claim() {
  env -i \
    HOME="$TD" \
    PATH="$TD/bin:/usr/bin:/bin" \
    ALERT_STATE_DIR="$state" \
    SYSTEMCTL="$TD/bin/systemctl" \
    AM_EXECUTOR_CLAIM_UNIT="am-executor-claim-test" \
    "$claim_bin" "$@"
}

# The claim file lives only while the worker runs (the wrapper's EXIT trap is
# the sweep), so the packet-capture command also asserts it exists mid-dispatch.
printf '%s\n' "$payload" | run_claim -- /bin/sh -c 'cat >"$1" && test -s "$2"' _ \
    "$TD/drill-packet.json" "$state/ci-merge-queue-head-wait-high.json" \
  || fail "am-executor-claim dispatch failed (or no live claim record during it)"
[[ -s "$TD/drill-packet.json" ]] || fail "no packet reached the command stdin"
grep -q 'CiMergeQueueHeadWaitHigh' "$TD/drill-packet.json" \
  || fail "packet does not name the alert"
grep -q '0509#3069' "$TD/drill-packet.json" \
  || fail "packet does not carry the consolidation issues"
ok "drill: firing dispatched a packet naming the alert + consolidation issues"

# Clears: the claim file is removed and the flock released on exit, so the
# NEXT firing dispatches again.
[[ ! -e "$state/ci-merge-queue-head-wait-high.json" ]] \
  || fail "claim record not cleared on exit"
printf '%s\n' "$payload" | run_claim -- /bin/sh -c 'cat >"$1"' _ "$TD/drill-packet-2.json" \
  || fail "second dispatch after clear failed"
[[ -s "$TD/drill-packet-2.json" ]] || fail "second firing did not dispatch after clear"
ok "drill: claim cleared on exit; the next firing dispatches again"

echo "PASS: ci-queue-alerts"
