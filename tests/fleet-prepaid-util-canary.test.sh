#!/usr/bin/env bash
# tests/fleet-prepaid-util-canary.test.sh
#
# fleet-ops#6114: the reader is back. #5993 retired the canary to a 9-line
# no-op and #6037 kept it, which froze /var/lib/prometheus/node-exporter/
# prepaid-spend.prom — the pacing rules (fleet_cursor_prepaid_pacing in
# config/fleet_rules.yml) read fleet_prepaid_pool_usd -
# fleet_prepaid_spend_usd{provider=cursor} and both sat at 0.000000 while the
# REAL expiring $400 (Cursor Ultra Included API bucket, $235.704 used) went
# into the #4566 field names the rules never read.
#
#   1. Offline (no auth, no fixture): exit 0, "no data" log, heartbeat-tier1
#      still invokes the canary (the #4263 block-38 slot contract).
#   2. THE #6114 regression: a live-shaped GetCurrentPeriodUsage fixture with
#      a non-zero Included-API bucket and a 0/0 SpendLimitUsage (Nish keeps
#      the on-demand overage at 0) must plant the BUCKET figures under the
#      #4206 names — fleet_prepaid_spend_usd{provider=cursor} 235.704000 and
#      fleet_prepaid_pool_usd 400.000000, both NON-ZERO — and append a FRESH
#      history sample (updated_s == the state's, never the stale 1788894598
#      replication the issue caught).
#   3. 24h delta: usd_today = vendor 24h delta of the bucket, count preserved
#      (spend overlay, not a pick), never the token-derived 0.000000 (#4621).
#   4. Warming history: usd_today = UNAVAILABLE:cursor-history-warming, never
#      a fabricated 0 (#4621).
#   5. Missing fixture: no .prom (the absent() rule fires), still exit 0.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$here"
bin="$repo_root/bin/fleet-prepaid-util-canary"
tier1="$repo_root/bin/fleet-heartbeat-tier1"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
command -v jq >/dev/null 2>&1 || fail "jq required"

scratch="$(mktemp -d -t prepaid-util-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
export PI_PACKET_STATE="$scratch/state"
spend_state="$PI_PACKET_STATE/prepaid-spend"
mkdir -p "$spend_state" "$PI_PACKET_STATE/prepaid-usage"
prom_out="$scratch/prepaid-spend.prom"
export FLEET_PREPAID_SPEND_DIR="$spend_state"
export FLEET_PREPAID_PROM_PATH="$prom_out"

# --- 1. offline: no fixture, no ~/.config/cursor/auth.json ------------------
set +e
offline_out=$("$bin" 2>&1)
offline_rc=$?
set -e
[[ "$offline_rc" == "0" ]] || fail "scenario1: offline canary must exit 0 (heartbeat tier1 must not page), got $offline_rc ($offline_out)"
grep -q 'cursor spend reader: no data' <<<"$offline_out" \
  || fail "scenario1: offline must log the no-data line, got: $offline_out"
[[ ! -s "$prom_out" ]] || fail "scenario1: no .prom must be written when there is no data"
grep -F 'fleet-prepaid-util-canary' "$tier1" >/dev/null \
  || fail "heartbeat-tier1 must still invoke fleet-prepaid-util-canary (block-38 slot, #4263)"
ok "scenario1: offline exit 0, no .prom, tier1 slot wired"

# --- 2. THE #6114 regression: non-zero bucket -> non-zero #4206 metrics -----
# Live-shaped response (fleet-ops#4566): SpendLimitUsage carries NO limits
# (the on-demand overage is 0), planUsage carries the Included-API bucket:
# 58.926% x $400 = $235.704 used, $164.296 remaining (the 2026-09-12T12:59Z
# live sample the issue cited).
cat >"$scratch/cursor-usage-live.json" <<'JSON'
{"billingCycleStart":"1787371371000","billingCycleEnd":"1790049771000","planUsage":{"totalSpend":242731,"includedSpend":40000,"bonusSpend":202731,"limit":40000,"autoPercentUsed":80.437,"apiPercentUsed":58.926,"totalPercentUsed":93.44},"spendLimitUsage":{"limitType":"user"},"enabled":true,"displayMessage":"You've hit your usage limit"}
JSON
set +e
read_out=$(CURSOR_USAGE_URL="$scratch/cursor-usage-live.json" "$bin" 2>&1)
read_rc=$?
set -e
[[ "$read_rc" == "0" ]] || fail "scenario2: reader must exit 0, got $read_rc ($read_out)"

# THE assertion: the #4206 metric names the PACING RULES read are NON-ZERO.
grep -q '^fleet_prepaid_spend_usd{provider="cursor"} 235.704000$' "$prom_out" \
  || fail "scenario2: fleet_prepaid_spend_usd{provider=cursor} must be 235.704000 (the Included-API-bucket spend), got: $(grep 'fleet_prepaid_spend_usd' "$prom_out" || echo MISSING)"
grep -q '^fleet_prepaid_pool_usd{provider="cursor"} 400.000000$' "$prom_out" \
  || fail "scenario2: fleet_prepaid_pool_usd{provider=cursor} must be 400.000000 (the Included-API-bucket limit), got: $(grep 'fleet_prepaid_pool_usd' "$prom_out" || echo MISSING)"
grep -q '^fleet_cursor_api_bucket_used_usd{provider="cursor"} 235.704000$' "$prom_out" \
  || fail "scenario2: api bucket used must be 235.704 (58.926% x 400)"
grep -q '^fleet_cursor_api_bucket_remaining_usd{provider="cursor"} 164.296000$' "$prom_out" \
  || fail "scenario2: api bucket remaining must be 164.296"
grep -q '^fleet_prepaid_included_exhausted{provider="cursor"} 0$' "$prom_out" \
  || fail "scenario2: included_exhausted must be 0 (totalPercentUsed 93.44 < 100)"
grep -q '^fleet_prepaid_cycle_end_timestamp{provider="cursor"} 1790049771$' "$prom_out" \
  || fail "scenario2: cycle_end must be 1790049771 (2026-09-22T04:02Z)"
grep -q '"api_bucket_used_usd": 235.704' "$spend_state/cursor.json" \
  || fail "scenario2: state must carry api_bucket_used_usd"
updated_s=$(jq -r '.updated_s' "$spend_state/cursor.json")
[[ "$updated_s" =~ ^[0-9]+$ ]] || fail "scenario2: state updated_s must be an epoch, got '$updated_s'"
now_s=$(date -u +%s)
(( now_s - updated_s < 300 )) || fail "scenario2: state updated_s must be FRESH (a successful fetch just happened), got $((now_s - updated_s))s old"
# "history must append fresh samples" — one sample, stamped with the SAME
# fresh updated_s (never the stale updated_s replication of #6114's symptom).
hist="$spend_state/cursor-history.jsonl"
[[ -s "$hist" ]] || fail "scenario2: cursor-history.jsonl must gain a sample"
[[ "$(wc -l <"$hist")" == "1" ]] || fail "scenario2: exactly one history sample expected, got $(wc -l <"$hist")"
h1_s=$(jq -r '.updated_s' "$hist"); h1_u=$(jq -r '.api_bucket_used_usd' "$hist")
[[ "$h1_s" == "$updated_s" ]] \
  || fail "scenario2: history sample must carry the FRESH updated_s $updated_s, got $h1_s"
[[ "$(printf '%.3f' "$h1_u")" == "235.704" ]] \
  || fail "scenario2: history sample must carry the 235.704 bucket spend, got $h1_u"
ok "scenario2: #4206 metric names carry the 235.704/400.000 Included-API-bucket figures; history sample is fresh"

# --- 3. 24h delta: usd_today is the vendor 24h delta, count preserved -------
now_s=$(date -u +%s); old_s=$((now_s - 25 * 3600))
printf '%s\n' "{\"updated_s\":$old_s,\"api_bucket_used_usd\":5.0}" >"$hist"
printf '%s\n' '{"week":"2026-W37","count":7,"usd_today":"0.000000"}' \
  >"$PI_PACKET_STATE/prepaid-usage/cursor.json"
set +e
delta_out=$(CURSOR_USAGE_URL="$scratch/cursor-usage-live.json" "$bin" 2>&1)
delta_rc=$?
set -e
[[ "$delta_rc" == "0" ]] || fail "scenario3: expected rc=0, got $delta_rc ($delta_out)"
usage_f="$PI_PACKET_STATE/prepaid-usage/cursor.json"
ut=$(jq -r '.usd_today // empty' "$usage_f")
[[ "$ut" == "230.7040" ]] \
  || fail "scenario3: usd_today must be the 24h delta 230.7040 (235.704-5.0), got '$ut'"
[[ "$(jq -r '.count' "$usage_f")" == "7" ]] \
  || fail "scenario3: overlay must preserve pick count 7, got $(jq -r '.count' "$usage_f")"
[[ "$(jq -r '.usd_today_source' "$usage_f")" == "cursor-dashboard-getcurrentperiodusage" ]] \
  || fail "scenario3: usd_today_source must name the vendor endpoint"
[[ "$(jq -r '.billing_lane' "$usage_f")" == "ultra-included-api-bucket" ]] \
  || fail "scenario3: billing_lane must name the Included API bucket"
cycle=$(jq -r '.cursor_api_cycle_usd' "$usage_f")
[[ "$cycle" == "235.704000" || "$cycle" == "235.704" ]] \
  || fail "scenario3: cursor_api_cycle_usd must be the cycle-to-date vendor figure, got '$cycle'"
ok "scenario3: usd_today overlay is the vendor 24h delta (230.7040), never token 0 (fleet-ops#4621)"

# --- 4. warming history: UNAVAILABLE, never a fabricated 0 ------------------
rm -f "$hist"
set +e
warm_out=$(CURSOR_USAGE_URL="$scratch/cursor-usage-live.json" "$bin" 2>&1)
warm_rc=$?
set -e
[[ "$warm_rc" == "0" ]] || fail "scenario4: expected rc=0, got $warm_rc ($warm_out)"
ut=$(jq -r '.usd_today // empty' "$usage_f")
[[ "$ut" == "UNAVAILABLE:cursor-history-warming" ]] \
  || fail "scenario4: warming must be UNAVAILABLE:cursor-history-warming, not a fabricated 0 (got '$ut')"
[[ "$ut" != "0.000000" && "$ut" != "0" ]] \
  || fail "scenario4: fabricated 0.000000 is the #4621 bug"
ok "scenario4: warming usd_today is UNAVAILABLE, never 0.000000 (fleet-ops#4621)"

# --- 5. missing fixture: no .prom, exit 0 (absent() rule fires) -------------
rm -f "$prom_out"
set +e
no_out=$(CURSOR_USAGE_URL="$scratch/nonexistent.json" "$bin" 2>&1)
no_rc=$?
set -e
[[ "$no_rc" == "0" ]] || fail "scenario5: dead reader must exit 0, got $no_rc ($no_out)"
[[ ! -s "$prom_out" ]] || fail "scenario5: no .prom must be written when the read fails"
grep -q 'cursor spend reader: no data' <<<"$no_out" \
  || fail "scenario5: must log no-data, got: $no_out"
ok "scenario5: dead reader exits 0, no .prom — FleetCursorPrepaidSpendReaderAbsent's absent() fires"

ok "fleet-prepaid-util-canary: #6114 reader restored — #4206 pacing inputs non-zero, history fresh, #4621 overlay honest"
