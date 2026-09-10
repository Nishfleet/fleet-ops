#!/usr/bin/env bash
# tests/fleet-prepaid-util-canary.test.sh
#
# Proves the prepaid max-utilization canary (fleet-ops#531) offline:
#   1. Clean: prepaid in order, mid-week, picks>0 -> OK, no file.
#   2. Ladder: cap>0 prepaid with models missing from
#      prepaid_providers_in_order -> exit 1, LOUD, auto-files.
#   3. subscription alias is treated as prepaid-quota for the ladder.
#   4. cap=0 prepaid is not required in the order.
#   5. Expiry-waste: last 24h of ISO week, picks=0, work>0, not benched
#      -> exit 0, files (discovery must not fail the heartbeat).
#   6. Expiry-waste skipped when the seat is quota-benched.
#   7. Expiry-waste skipped when ready work is 0.
#   8. Expiry-waste skipped when picks>0.
#   9. Mid-week 0 picks + work>0 is quiet (not yet the horizon).
#  10. Dedup: open issue already carrying the marker -> no second create.
#  11. Per-tick file cap throttles filings.
#  12. Missing seat-caps -> exit 1.
#  13. Production seat-caps: every cap>0 prepaid with models is in
#      prepaid_providers_in_order.
#  14. Heartbeat-tier1 wires the canary and propagates a gate fail-loud.
#  15. Cursor spend reader: DashboardService fixture -> .prom with
#      fleet_prepaid_spend_usd{provider=cursor} + pool/cycle/included.
#  16. Cursor spend reader: missing fixture -> no .prom (absent() rule fires).
#  17. ETIMEDOUT watch: cli_timeout at cap 2 -> files lower-cap-to-1.
#  18. ETIMEDOUT watch: cli_timeout at cap 1 -> quiet (watch is cap>=2 only).
#  19. ETIMEDOUT watch: stale cli_timeout (>24h) -> quiet.
#  20. fleet-ops#4621: overlay prepaid-usage/cursor.json usd_today with the
#      vendor 24h API-bucket delta (or UNAVAILABLE:<why>), never a fabricated
#      0.000000. Cycle-to-date is a sibling field. Pick count is preserved.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-prepaid-util-canary"
tier1="$repo_root/bin/fleet-heartbeat-tier1"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$tier1" ]] || fail "missing: $tier1"

scratch="$(mktemp -d -t prepaid-util-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
triage="$scratch/triage.md"
: >"$triage"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export FLEET_PREPAID_UTIL_REPO="Nishfleet/fleet-ops"
export FLEET_PREPAID_UTIL_FILE=1
export PI_PACKET_STATE="$scratch/state"
export PI_SEAT_HEALTH_LEDGER_DIR="$scratch/ledger"
mkdir -p "$PI_PACKET_STATE/prepaid-usage" "$PI_PACKET_STATE/active-seats" \
    "$PI_SEAT_HEALTH_LEDGER_DIR"

# fleet-ops#5022: the opencode-go reader must never reach the live endpoint or
# write outside the scratch tree during tests (CI has no key; a dev box does).
export OPENCODE_GO_ENV_FILE="$scratch/no-opencode-go.env"
export OPENCODE_GO_AUTH_JSON="$scratch/no-auth.json"
export FLEET_PREPAID_USAGE_PROM_PATH="$scratch/prepaid-usage.prom"

gh_log="$scratch/gh.log"
gh_fake="$scratch/gh"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
case "$*" in
  *"issue list"*)
    if [[ -f "${GH_OPEN_ISSUES:-/dev/null}" ]]; then
      cat "${GH_OPEN_ISSUES}"
    else
      echo '[]'
    fi
    exit 0
    ;;
  *"issue create"*)
    echo "https://github.com/Nishfleet/fleet-ops/issues/999"
    exit 0
    ;;
esac
exit 0
FAKE
chmod +x "$gh_fake"
export GH="$gh_fake"
export GH_LOG="$gh_log"
export PATH="$scratch:$PATH"

write_caps()     { cat >"$scratch/seat-caps.json"; }
write_entitled() { cat >"$scratch/entitled-seats.json"; }

run_canary() {
  set +e
  env_out=$(
    FLEET_ENTITLED_SEATS_JSON="$scratch/entitled-seats.json" \
    SEAT_CAPS_JSON="$scratch/seat-caps.json" \
    FLEET_OPS_REPO="$scratch" \
    "$bin" 2>&1
  )
  env_rc=$?
  set -e
}

base_entitled() {
  write_entitled <<'JSON'
{ "seats": [ { "id": "devin", "class": "prepaid-quota" }, { "id": "opencode", "class": "free" } ] }
JSON
}

# Mid-week Wednesday 2026-08-26 is ISO week 2026-W35 (Mon 24 - Sun 30).
# Last 24h of that week starts Sun 2026-08-30 00:00 UTC.
MIDWEEK="2026-08-26T12:00:00Z"
HORIZON="2026-08-30T12:00:00Z"

# --- 1. clean: in order, mid-week, picks>0 -> OK, no file ------------------
: >"$gh_log"; : >"$triage"
base_entitled
write_caps <<'JSON'
{ "prepaid_providers_in_order": ["devin"],
  "providers": { "devin": { "cap": 4, "class": "prepaid-quota", "models": { "glm-5-2": 4 } } } }
JSON
mkdir -p "$PI_PACKET_STATE/prepaid-usage"
printf '%s\n' '{"week":"2026-W35","count":3}' >"$PI_PACKET_STATE/prepaid-usage/devin.json"
export FLEET_PREPAID_UTIL_NOW="$MIDWEEK"
export FLEET_PREPAID_UTIL_WORK=2
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario1: expected rc=0, got $env_rc ($env_out)"
grep -q 'PREPAID-UTIL-OK' "$triage" || fail "scenario1: missing OK line"
grep -q 'PREPAID-UTIL' "$triage" || fail "scenario1: missing utilization line"
! grep -q 'issue create' "$gh_log" || fail "scenario1: must not file on the clean state"
ok "scenario1: wired prepaid in order mid-week is quiet"

# --- 2. ladder: cap>0 prepaid missing from order -> scream + file ----------
: >"$gh_log"; : >"$triage"
base_entitled
write_caps <<'JSON'
{ "prepaid_providers_in_order": [],
  "providers": { "devin": { "cap": 4, "class": "prepaid-quota", "models": { "glm-5-2": 4 } } } }
JSON
export FLEET_PREPAID_UTIL_NOW="$MIDWEEK"
export FLEET_PREPAID_UTIL_WORK=0
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario2: expected rc=1, got $env_rc ($env_out)"
grep -q 'PREPAID-UTIL-VIOLATION' "$triage" || fail "scenario2: missing VIOLATION"
grep -q 'issue create' "$gh_log" \
  || fail "scenario2: must auto-file ($gh_log)"
ok "scenario2: prepaid missing from order fails loud and files"

# --- 3. subscription alias is prepaid-quota --------------------------------
: >"$gh_log"; : >"$triage"
base_entitled
write_caps <<'JSON'
{ "prepaid_providers_in_order": [],
  "providers": { "devin": { "cap": 2, "class": "subscription", "models": { "glm-5-2": 2 } } } }
JSON
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario3: subscription alias must trip the ladder, got $env_rc ($env_out)"
ok "scenario3: subscription alias is treated as prepaid-quota"

# --- 4. cap=0 prepaid is not required in the order -------------------------
: >"$gh_log"; : >"$triage"
base_entitled
write_caps <<'JSON'
{ "prepaid_providers_in_order": ["devin"],
  "providers": {
    "devin": { "cap": 4, "class": "prepaid-quota", "models": { "glm-5-2": 4 } },
    "grok":  { "cap": 0, "class": "prepaid-quota", "reason": "2026-08-26 no adapter" }
  } }
JSON
export FLEET_PREPAID_UTIL_NOW="$MIDWEEK"
export FLEET_PREPAID_UTIL_WORK=0
printf '%s\n' '{"week":"2026-W35","count":1}' >"$PI_PACKET_STATE/prepaid-usage/devin.json"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario4: cap=0 prepaid must not trip the ladder, got $env_rc ($env_out)"
! grep -q 'issue create' "$gh_log" || fail "scenario4: must not file"
ok "scenario4: cap=0 prepaid (SuperGrok unwired) stays off the ladder gate"

# --- 5. expiry-waste: last 24h, 0 picks, work>0 -> file, tick green --------
: >"$gh_log"; : >"$triage"
rm -f "$PI_PACKET_STATE/prepaid-usage/devin.json"
base_entitled
write_caps <<'JSON'
{ "prepaid_providers_in_order": ["devin"],
  "providers": { "devin": { "cap": 4, "class": "prepaid-quota", "models": { "glm-5-2": 4 } } } }
JSON
export FLEET_PREPAID_UTIL_NOW="$HORIZON"
export FLEET_PREPAID_UTIL_WORK=3
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario5: detector must keep tick green, got $env_rc ($env_out)"
grep -q 'PREPAID-UTIL-EXPIRY-WASTE' "$triage" || fail "scenario5: missing EXPIRY-WASTE"
grep -q 'issue create' "$gh_log" || fail "scenario5: must auto-file expiry-waste"
ok "scenario5: expiry-waste files and keeps the tick green"

# --- 6. expiry-waste skipped when quota-benched ----------------------------
: >"$gh_log"; : >"$triage"
base_entitled
write_caps <<'JSON'
{ "prepaid_providers_in_order": ["devin"],
  "providers": { "devin": { "cap": 4, "class": "prepaid-quota", "models": { "glm-5-2": 4 } } } }
JSON
printf '%s\n' '{"health_class":"quota_bench","bench_until":"2026-08-31T00:00:00Z","observed_at":"2026-08-30T00:00:00Z"}' \
  >"$PI_SEAT_HEALTH_LEDGER_DIR/devin__glm-5-2.json"
export FLEET_PREPAID_UTIL_NOW="$HORIZON"
export FLEET_PREPAID_UTIL_WORK=3
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario6: expected rc=0, got $env_rc ($env_out)"
! grep -q 'PREPAID-UTIL-EXPIRY-WASTE' "$triage" || fail "scenario6: benched seat is not waste"
! grep -q 'issue create' "$gh_log" || fail "scenario6: must not file when benched"
ok "scenario6: quota-benched seat is not expiry-waste"
rm -f "$PI_SEAT_HEALTH_LEDGER_DIR/devin__glm-5-2.json"

# --- 7. expiry-waste skipped when ready work is 0 --------------------------
: >"$gh_log"; : >"$triage"
base_entitled
write_caps <<'JSON'
{ "prepaid_providers_in_order": ["devin"],
  "providers": { "devin": { "cap": 4, "class": "prepaid-quota", "models": { "glm-5-2": 4 } } } }
JSON
export FLEET_PREPAID_UTIL_NOW="$HORIZON"
export FLEET_PREPAID_UTIL_WORK=0
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario7: expected rc=0, got $env_rc ($env_out)"
! grep -q 'PREPAID-UTIL-EXPIRY-WASTE' "$triage" || fail "scenario7: no work is not withholding"
! grep -q 'issue create' "$gh_log" || fail "scenario7: must not file when work=0"
ok "scenario7: quiet week with no ready work is not waste"

# --- 8. expiry-waste skipped when picks>0 ----------------------------------
: >"$gh_log"; : >"$triage"
printf '%s\n' '{"week":"2026-W35","count":2}' >"$PI_PACKET_STATE/prepaid-usage/devin.json"
base_entitled
write_caps <<'JSON'
{ "prepaid_providers_in_order": ["devin"],
  "providers": { "devin": { "cap": 4, "class": "prepaid-quota", "models": { "glm-5-2": 4 } } } }
JSON
export FLEET_PREPAID_UTIL_NOW="$HORIZON"
export FLEET_PREPAID_UTIL_WORK=3
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario8: expected rc=0, got $env_rc ($env_out)"
! grep -q 'PREPAID-UTIL-EXPIRY-WASTE' "$triage" || fail "scenario8: picks>0 is not waste"
! grep -q 'issue create' "$gh_log" || fail "scenario8: must not file when picks>0"
ok "scenario8: prepaid with picks this week is not waste"
rm -f "$PI_PACKET_STATE/prepaid-usage/devin.json"

# --- 9. mid-week 0 picks + work is quiet -----------------------------------
: >"$gh_log"; : >"$triage"
base_entitled
write_caps <<'JSON'
{ "prepaid_providers_in_order": ["devin"],
  "providers": { "devin": { "cap": 4, "class": "prepaid-quota", "models": { "glm-5-2": 4 } } } }
JSON
export FLEET_PREPAID_UTIL_NOW="$MIDWEEK"
export FLEET_PREPAID_UTIL_WORK=5
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario9: expected rc=0, got $env_rc ($env_out)"
! grep -q 'PREPAID-UTIL-EXPIRY-WASTE' "$triage" || fail "scenario9: mid-week must not scream"
! grep -q 'issue create' "$gh_log" || fail "scenario9: must not file mid-week"
ok "scenario9: mid-week unused prepaid is not yet expiry-waste"

# --- 10. dedup: open issue already carrying the marker ---------------------
: >"$gh_log"; : >"$triage"
base_entitled
write_caps <<'JSON'
{ "prepaid_providers_in_order": ["devin"],
  "providers": { "devin": { "cap": 4, "class": "prepaid-quota", "models": { "glm-5-2": 4 } } } }
JSON
export FLEET_PREPAID_UTIL_NOW="$HORIZON"
export FLEET_PREPAID_UTIL_WORK=3
export GH_OPEN_ISSUES="$scratch/open.json"
printf '%s\n' '[{"number":42,"body":"prepaid-util-canary: devin expiry-waste"}]' \
  >"$GH_OPEN_ISSUES"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario10: expected rc=0, got $env_rc ($env_out)"
! grep -q 'issue create' "$gh_log" || fail "scenario10: must not create a second issue"
ok "scenario10: open marker is deduped"
unset GH_OPEN_ISSUES
rm -f "$scratch/open.json"

# --- 11. per-tick file cap -------------------------------------------------
: >"$gh_log"; : >"$triage"
base_entitled
write_caps <<'JSON'
{ "prepaid_providers_in_order": ["alpha", "beta"],
  "providers": {
    "alpha": { "cap": 2, "class": "prepaid-quota", "models": { "a": 2 } },
    "beta":  { "cap": 2, "class": "prepaid-quota", "models": { "b": 2 } }
  } }
JSON
export FLEET_PREPAID_UTIL_NOW="$HORIZON"
export FLEET_PREPAID_UTIL_WORK=3
export FLEET_PREPAID_UTIL_CAP=1
run_canary
unset FLEET_PREPAID_UTIL_CAP
creates=$(grep -c 'issue create' "$gh_log" || true)
[[ "$creates" == "1" ]] || fail "scenario11: cap=1 must file exactly once, got $creates ($gh_log)"
ok "scenario11: per-tick file cap throttles filings"

# --- 12. missing seat-caps -> exit 1 ---------------------------------------
: >"$gh_log"; : >"$triage"
base_entitled
rm -f "$scratch/seat-caps.json"
export FLEET_PREPAID_UTIL_NOW="$MIDWEEK"
export FLEET_PREPAID_UTIL_WORK=0
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario12: missing seat-caps must exit 1, got $env_rc ($env_out)"
grep -q 'PREPAID-UTIL-VIOLATION' "$triage" || fail "scenario12: missing VIOLATION"
ok "scenario12: missing seat-caps fails loud"

# --- 13. production seat-caps: prepaid ladder complete ---------------------
: >"$gh_log"; : >"$triage"
export FLEET_PREPAID_UTIL_NOW="$MIDWEEK"
export FLEET_PREPAID_UTIL_WORK=0
export FLEET_PREPAID_UTIL_FILE=0
set +e
prod_out=$(
  FLEET_ENTITLED_SEATS_JSON="$repo_root/config/entitled-seats.json" \
  SEAT_CAPS_JSON="$repo_root/config/seat-caps.json" \
  FLEET_OPS_REPO="$repo_root" \
  FLEET_PREPAID_UTIL_FILE=0 \
  FLEET_PREPAID_UTIL_NOW="$MIDWEEK" \
  FLEET_PREPAID_UTIL_WORK=0 \
  PI_PACKET_STATE="$scratch/state" \
  PI_SEAT_HEALTH_LEDGER_DIR="$scratch/ledger" \
  "$bin" 2>&1
)
prod_rc=$?
set -e
export FLEET_PREPAID_UTIL_FILE=1
[[ "$prod_rc" == "0" ]] || fail "scenario13: production gates must be clean, got rc=$prod_rc ($prod_out)"
while IFS=$'\t' read -r pid pclass pcap mcount; do
    [[ "$pclass" == "prepaid-quota" || "$pclass" == "subscription" ]] || continue
    [[ "$pcap" =~ ^[1-9][0-9]*$ ]] || continue
    [[ "$mcount" =~ ^[1-9][0-9]*$ ]] || continue
    jq -e --arg id "$pid" '.prepaid_providers_in_order | index($id)' \
        "$repo_root/config/seat-caps.json" >/dev/null \
      || fail "scenario13: production prepaid $pid missing from prepaid_providers_in_order"
done < <(jq -r '
    .providers | to_entries[] | .key as $k | .value as $v
    | [$k,
       (if ($v|type)=="number" then "free" else ($v.class // "free") end),
       (if ($v|type)=="number" then $v else ($v.cap // 0) end),
       (if ($v|type)=="object" and ($v.models|type)=="object" then ($v.models|length) else 0 end)]
    | @tsv
' "$repo_root/config/seat-caps.json")
ok "scenario13: production seat-caps passes the prepaid ladder gate"

# --- 14. heartbeat wiring --------------------------------------------------
grep -F 'fleet-prepaid-util-canary' "$tier1" >/dev/null \
  || fail "tier1 must invoke fleet-prepaid-util-canary"
grep -F 'prepaid_util_canary_rc' "$tier1" >/dev/null \
  || fail "tier1 must capture prepaid_util_canary_rc"
grep -F -- 'exit "$prepaid_util_canary_rc"' "$tier1" >/dev/null \
  || fail "tier1 must exit non-zero when a prepaid-util gate fails loud"
grep -q 'bin/fleet-prepaid-util-canary' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/fleet-prepaid-util-canary"
ok "scenario14: heartbeat-tier1 wires the canary, fail-loud on gate, MANIFEST installs it"

# --- 15. Cursor spend reader: fixture -> .prom with fleet_prepaid_spend_usd
: >"$gh_log"; : >"$triage"
base_entitled
write_caps <<'JSON'
{ "prepaid_providers_in_order": ["cursor"],
  "providers": { "cursor": { "cap": 2, "class": "prepaid-quota", "models": { "cursor-grok-4.6-high": 2 } } } }
JSON
export FLEET_PREPAID_UTIL_NOW="$MIDWEEK"
export FLEET_PREPAID_UTIL_WORK=0
export FLEET_PREPAID_UTIL_FILE=0
prom_out="$scratch/prepaid-spend.prom"
spend_state="$scratch/prepaid-spend"
mkdir -p "$spend_state"
cat >"$scratch/cursor-usage.json" <<'JSON'
{"billingCycleStart":"1787371371000","billingCycleEnd":"1790049771000","planUsage":{"totalSpend":215698,"includedSpend":40000,"bonusSpend":175698,"limit":40000,"autoPercentUsed":71.89,"apiPercentUsed":0.018,"totalPercentUsed":61.628},"spendLimitUsage":{"individualLimit":40000,"individualRemaining":25000,"limitType":"user"},"enabled":true}
JSON
set +e
spend_out=$(
  CURSOR_USAGE_URL="$scratch/cursor-usage.json" \
  FLEET_PREPAID_SPEND_DIR="$spend_state" \
  FLEET_PREPAID_PROM_PATH="$prom_out" \
  FLEET_ENTITLED_SEATS_JSON="$scratch/entitled-seats.json" \
  SEAT_CAPS_JSON="$scratch/seat-caps.json" \
  FLEET_OPS_REPO="$scratch" \
  "$bin" 2>&1
)
spend_rc=$?
set -e
[[ "$spend_rc" == "0" ]] || fail "scenario15: expected rc=0, got $spend_rc ($spend_out)"
[[ -f "$prom_out" ]] || fail "scenario15: .prom file not written"
grep -q '^fleet_prepaid_spend_usd{provider="cursor"} 150\.000000' "$prom_out" \
  || fail "scenario15: spend_usd must be 150.00 (40000-25000=15000 cents=$150), got: $(cat "$prom_out")"
grep -q '^fleet_prepaid_pool_usd{provider="cursor"} 400\.000000' "$prom_out" \
  || fail "scenario15: pool_usd must be 400.00"
grep -q '^fleet_prepaid_cycle_end_timestamp{provider="cursor"} 1790049771' "$prom_out" \
  || fail "scenario15: cycle_end_timestamp must be 1790049771"
# fleet-ops#4566: included_exhausted is now totalPercentUsed >= 100 (the old
# includedSpend>=limit compare misfired on bonus-exhausted accounts).
grep -q '^fleet_prepaid_included_exhausted{provider="cursor"} 0' "$prom_out" \
  || fail "scenario15: included_exhausted must be 0 (totalPercentUsed 61.628 < 100)"
# API bucket: apiPercentUsed 0.018 x $400 limit = $0.072 used.
grep -q '^fleet_cursor_api_bucket_used_usd{provider="cursor"} 0.072000' "$prom_out" \
  || fail "scenario15: api bucket used must be 0.072 (0.018% x 400)"
grep -q '^fleet_cursor_api_bucket_remaining_usd{provider="cursor"} 399.928000' "$prom_out" \
  || fail "scenario15: api bucket remaining must be 399.928"
grep -q '"api_bucket_used_usd": 0.072' "$spend_state/cursor.json" \
  || fail "scenario15: state must carry api_bucket_used_usd"
grep -q 'cursor spend reader: spend_usd=150' <<<"$spend_out" \
  || fail "scenario15: missing spend reader log line"
ok "scenario15: cursor spend reader emits fleet_prepaid_spend_usd{provider=cursor} from DashboardService fixture"

# --- 15b. fleet-ops#4566: live-shaped response — spendLimitUsage has NO
# limits (on-demand overage set to 0), the real $400 is the included API
# bucket (apiPercentUsed 2.84 x $400 = $11.36 used, $388.64 remaining).
: >"$gh_log"; : >"$triage"
rm -f "$prom_out"
cat >"$scratch/cursor-usage-live.json" <<'JSON'
{"billingCycleStart":"1787371371000","billingCycleEnd":"1790049771000","planUsage":{"totalSpend":242731,"includedSpend":40000,"bonusSpend":202731,"limit":40000,"autoPercentUsed":80.437,"apiPercentUsed":2.84,"totalPercentUsed":69.35},"spendLimitUsage":{"limitType":"user"},"enabled":true,"displayMessage":"You've hit your usage limit"}
JSON
set +e
live_out=$(
  CURSOR_USAGE_URL="$scratch/cursor-usage-live.json" \
  FLEET_PREPAID_SPEND_DIR="$spend_state" \
  FLEET_PREPAID_PROM_PATH="$prom_out" \
  FLEET_ENTITLED_SEATS_JSON="$scratch/entitled-seats.json" \
  SEAT_CAPS_JSON="$scratch/seat-caps.json" \
  FLEET_OPS_REPO="$scratch" \
  "$bin" 2>&1
)
live_rc=$?
set -e
[[ "$live_rc" == "0" ]] || fail "scenario15b: expected rc=0, got $live_rc ($live_out)"
grep -q '^fleet_prepaid_spend_usd{provider="cursor"} 0.000000' "$prom_out" \
  || fail "scenario15b: on-demand spend must parse 0 when spendLimitUsage carries no limits"
grep -q '^fleet_cursor_api_bucket_used_usd{provider="cursor"} 11.360000' "$prom_out" \
  || fail "scenario15b: api bucket used must be 11.36 (2.84% x 400)"
grep -q '^fleet_cursor_api_bucket_remaining_usd{provider="cursor"} 388.640000' "$prom_out" \
  || fail "scenario15b: api bucket remaining must be 388.64"
grep -q '^fleet_prepaid_included_exhausted{provider="cursor"} 0' "$prom_out" \
  || fail "scenario15b: included_exhausted must be 0 (totalPercentUsed 69.35 < 100)"
grep -q '"api_bucket_remaining_usd": 388.64' "$spend_state/cursor.json" \
  || fail "scenario15b: state must carry api_bucket_remaining_usd"
ok "scenario15b: live-shaped response parses the included API bucket (fleet-ops#4566)"

# --- 15c. fleet-ops#4621: overlay prepaid-usage usd_today with the 24h
# API-bucket delta. Token-derived 0.000000 must not survive a vendor sample
# that is >= 24h old. Count is preserved (this is a spend overlay, not a pick).
: >"$gh_log"; : >"$triage"
now_s=$(date -u +%s)
old_s=$((now_s - 25 * 3600))
printf '%s\n' "{\"updated_s\":$old_s,\"api_bucket_used_usd\":5.0}" \
  >"$spend_state/cursor-history.jsonl"
mkdir -p "$PI_PACKET_STATE/prepaid-usage"
printf '%s\n' '{"week":"2026-W35","count":7,"usd_today":"0.000000"}' \
  >"$PI_PACKET_STATE/prepaid-usage/cursor.json"
set +e
overlay_out=$(
  CURSOR_USAGE_URL="$scratch/cursor-usage-live.json" \
  FLEET_PREPAID_SPEND_DIR="$spend_state" \
  FLEET_PREPAID_PROM_PATH="$prom_out" \
  FLEET_ENTITLED_SEATS_JSON="$scratch/entitled-seats.json" \
  SEAT_CAPS_JSON="$scratch/seat-caps.json" \
  FLEET_OPS_REPO="$scratch" \
  "$bin" 2>&1
)
overlay_rc=$?
set -e
[[ "$overlay_rc" == "0" ]] || fail "scenario15c: expected rc=0, got $overlay_rc ($overlay_out)"
usage_f="$PI_PACKET_STATE/prepaid-usage/cursor.json"
[[ -f "$usage_f" ]] || fail "scenario15c: prepaid-usage/cursor.json missing"
ut=$(jq -r '.usd_today // empty' "$usage_f")
[[ "$ut" == "6.3600" ]] \
  || fail "scenario15c: usd_today must be the 24h delta 6.3600 (11.36-5.00), got '$ut'"
[[ "$(jq -r '.count' "$usage_f")" == "7" ]] \
  || fail "scenario15c: overlay must preserve pick count 7, got $(jq -r '.count' "$usage_f")"
[[ "$(jq -r '.usd_today_source' "$usage_f")" == "cursor-dashboard-getcurrentperiodusage" ]] \
  || fail "scenario15c: usd_today_source must name the vendor endpoint"
[[ "$(jq -r '.billing_lane' "$usage_f")" == "ultra-included-api-bucket" ]] \
  || fail "scenario15c: billing_lane must name the included API bucket, not on-demand"
cycle=$(jq -r '.cursor_api_cycle_usd' "$usage_f")
[[ "$cycle" == "11.360000" || "$cycle" == "11.36" ]] \
  || fail "scenario15c: cursor_api_cycle_usd must be the cycle-to-date vendor figure, got '$cycle'"
ok "scenario15c: usd_today overlay is the vendor 24h delta, never token 0"

# --- 15d. fleet-ops#4621: warming window is UNAVAILABLE:<why>, never 0.000000.
: >"$gh_log"; : >"$triage"
rm -f "$spend_state/cursor-history.jsonl"
printf '%s\n' '{"week":"2026-W35","count":7,"usd_today":"0.000000"}' \
  >"$PI_PACKET_STATE/prepaid-usage/cursor.json"
set +e
warm_out=$(
  CURSOR_USAGE_URL="$scratch/cursor-usage-live.json" \
  FLEET_PREPAID_SPEND_DIR="$spend_state" \
  FLEET_PREPAID_PROM_PATH="$prom_out" \
  FLEET_ENTITLED_SEATS_JSON="$scratch/entitled-seats.json" \
  SEAT_CAPS_JSON="$scratch/seat-caps.json" \
  FLEET_OPS_REPO="$scratch" \
  "$bin" 2>&1
)
warm_rc=$?
set -e
[[ "$warm_rc" == "0" ]] || fail "scenario15d: expected rc=0, got $warm_rc ($warm_out)"
ut=$(jq -r '.usd_today // empty' "$usage_f")
[[ "$ut" == "UNAVAILABLE:cursor-history-warming" ]] \
  || fail "scenario15d: warming must be UNAVAILABLE:cursor-history-warming, not a fabricated 0 (got '$ut')"
[[ "$ut" != "0.000000" && "$ut" != "0" ]] \
  || fail "scenario15d: fabricated 0.000000 is the #4621 bug"
ok "scenario15d: warming usd_today is UNAVAILABLE, never 0.000000"

# --- 16. Cursor spend reader: missing fixture -> no .prom (absent rule fires)
: >"$gh_log"; : >"$triage"
rm -f "$prom_out"
set +e
no_spend_out=$(
  CURSOR_USAGE_URL="$scratch/nonexistent.json" \
  FLEET_PREPAID_SPEND_DIR="$spend_state" \
  FLEET_PREPAID_PROM_PATH="$prom_out" \
  FLEET_ENTITLED_SEATS_JSON="$scratch/entitled-seats.json" \
  SEAT_CAPS_JSON="$scratch/seat-caps.json" \
  FLEET_OPS_REPO="$scratch" \
  "$bin" 2>&1
)
no_spend_rc=$?
set -e
[[ "$no_spend_rc" == "0" ]] || fail "scenario16: expected rc=0 (non-fatal), got $no_spend_rc"
[[ ! -f "$prom_out" ]] || fail "scenario16: .prom file must NOT be written on missing fixture"
grep -q 'cursor spend reader: no data' <<<"$no_spend_out" \
  || fail "scenario16: missing 'no data' log line"
ok "scenario16: cursor spend reader omits metric on failure (absent() rule fires)"

# --- 17. ETIMEDOUT watch: cli_timeout at cap 2 -> files lower-cap-to-1 -----
: >"$gh_log"; : >"$triage"
base_entitled
write_caps <<'JSON'
{ "prepaid_providers_in_order": ["cursor"],
  "providers": { "cursor": { "cap": 2, "class": "prepaid-quota", "models": { "cursor-grok-4.6-high": 2 } } } }
JSON
export FLEET_PREPAID_UTIL_NOW="2026-09-07T12:00:00Z"
export FLEET_PREPAID_UTIL_WORK=0
export FLEET_PREPAID_UTIL_FILE=1
printf '%s\n' '{"provider":"cursor","model":"cursor-grok-4.6-high","health_class":"transient_fault","failure_mode":"cli_timeout","observed_at":"2026-09-07T10:00:00Z","consecutive_failure_count":1}' \
  >"$PI_SEAT_HEALTH_LEDGER_DIR/cursor__cursor-grok-4.6-high.json"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario17: ETIMEDOUT watch must keep tick green, got $env_rc ($env_out)"
grep -q 'PREPAID-UTIL-CURSOR-ETIMEDOUT-AT-CAP-2' "$triage" \
  || fail "scenario17: missing ETIMEDOUT-AT-CAP-2 LOUD line"
grep -q 'issue create' "$gh_log" \
  || fail "scenario17: must file lower-cap-to-1 finding"
ok "scenario17: cli_timeout at cap 2 files lower-cap-to-1 finding"
rm -f "$PI_SEAT_HEALTH_LEDGER_DIR/cursor__cursor-grok-4.6-high.json"

# --- 18. ETIMEDOUT watch: cli_timeout at cap 1 -> no file (cap already 1) ---
: >"$gh_log"; : >"$triage"
base_entitled
write_caps <<'JSON'
{ "prepaid_providers_in_order": ["cursor"],
  "providers": { "cursor": { "cap": 1, "class": "prepaid-quota", "models": { "cursor-grok-4.6-high": 1 } } } }
JSON
export FLEET_PREPAID_UTIL_NOW="2026-09-07T12:00:00Z"
export FLEET_PREPAID_UTIL_WORK=0
printf '%s\n' '{"provider":"cursor","model":"cursor-grok-4.6-high","health_class":"transient_fault","failure_mode":"cli_timeout","observed_at":"2026-09-07T10:00:00Z","consecutive_failure_count":1}' \
  >"$PI_SEAT_HEALTH_LEDGER_DIR/cursor__cursor-grok-4.6-high.json"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario18: expected rc=0, got $env_rc ($env_out)"
! grep -q 'PREPAID-UTIL-CURSOR-ETIMEDOUT-AT-CAP-2' "$triage" \
  || fail "scenario18: cap 1 must not trip the cap-2 watch"
! grep -q 'issue create' "$gh_log" \
  || fail "scenario18: cap 1 must not file a lower-cap finding"
ok "scenario18: cli_timeout at cap 1 is quiet (watch is cap>=2 only)"
rm -f "$PI_SEAT_HEALTH_LEDGER_DIR/cursor__cursor-grok-4.6-high.json"

# --- 19. ETIMEDOUT watch: stale cli_timeout (>24h) -> no file --------------
: >"$gh_log"; : >"$triage"
base_entitled
write_caps <<'JSON'
{ "prepaid_providers_in_order": ["cursor"],
  "providers": { "cursor": { "cap": 2, "class": "prepaid-quota", "models": { "cursor-grok-4.6-high": 2 } } } }
JSON
export FLEET_PREPAID_UTIL_NOW="2026-09-07T12:00:00Z"
export FLEET_PREPAID_UTIL_WORK=0
printf '%s\n' '{"provider":"cursor","model":"cursor-grok-4.6-high","health_class":"healthy","failure_mode":"cli_timeout","observed_at":"2026-09-05T10:00:00Z","consecutive_failure_count":0}' \
  >"$PI_SEAT_HEALTH_LEDGER_DIR/cursor__cursor-grok-4.6-high.json"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario19: expected rc=0, got $env_rc ($env_out)"
! grep -q 'PREPAID-UTIL-CURSOR-ETIMEDOUT-AT-CAP-2' "$triage" \
  || fail "scenario19: stale cli_timeout (>24h) must not trip"
! grep -q 'issue create' "$gh_log" \
  || fail "scenario19: stale cli_timeout must not file"
ok "scenario19: stale cli_timeout (>24h horizon) is quiet"
rm -f "$PI_SEAT_HEALTH_LEDGER_DIR/cursor__cursor-grok-4.6-high.json"
unset FLEET_PREPAID_UTIL_FILE
unset CURSOR_USAGE_URL FLEET_PREPAID_SPEND_DIR FLEET_PREPAID_PROM_PATH

# --- 20. fleet-ops#5022: opencode-go usage reader -> fleet_prepaid_usage_pct
# The subscription's own endpoint carries the 5h/weekly/monthly percentages the
# fleet was blind to (the 2026-09-10 incident: 80.1% of the weekly pool gone
# with 3.3 days left while the cap sat at 10). Fixture-shaped like the cursor
# reader; resets are computed from the real clock because the paced cap is
# measured against "now".
: >"$gh_log"; : >"$triage"
base_entitled
write_caps <<'JSON'
{ "prepaid_providers_in_order": ["opencode-go"],
  "providers": { "opencode-go": { "cap": 2, "class": "prepaid-quota", "quota_window": "weekly",
                                  "models": { "deepseek-flash": 2 } } } }
JSON
export FLEET_PREPAID_UTIL_NOW="$MIDWEEK"
export FLEET_PREPAID_UTIL_WORK=0
export FLEET_PREPAID_UTIL_FILE=0
og_now_s=$(date -u +%s)
og_reset_5h=$((og_now_s + 3600))
og_reset_week=$((og_now_s + 50 * 3600))
og_reset_month=$((og_now_s + 30 * 86400))
printf '%s\n' '{"week":"2026-W35","count":82,"usd_today":"0.000000","billing_lane":"keep-me"}' \
  >"$PI_PACKET_STATE/prepaid-usage/opencode-go.json"
python3 - "$scratch/og-usage.json" "$og_reset_5h" "$og_reset_week" "$og_reset_month" <<'PY'
import json, sys
from datetime import datetime, timezone
path, r5, rw, rm = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
def iso(s):
    return datetime.fromtimestamp(s, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
out = {"usage": {"rolling": {"status": "ok", "percent": 15, "resetsAt": iso(r5)},
                 "weekly": {"status": "ok", "percent": 90, "resetsAt": iso(rw)},
                 "monthly": {"status": "ok", "percent": 43, "resetsAt": iso(rm)}}}
open(path, "w").write(json.dumps(out))
PY
og_prom="$scratch/prepaid-usage.prom"
rm -f "$og_prom"
set +e
og_out=$(
  OPENCODE_GO_USAGE_URL="$scratch/og-usage.json" \
  FLEET_PREPAID_USAGE_PROM_PATH="$og_prom" \
  OPENCODE_GO_PACE_K=12.5 \
  FLEET_ENTITLED_SEATS_JSON="$scratch/entitled-seats.json" \
  SEAT_CAPS_JSON="$scratch/seat-caps.json" \
  FLEET_OPS_REPO="$scratch" \
  "$bin" 2>&1
)
og_rc=$?
set -e
[[ "$og_rc" == "0" ]] || fail "scenario20: expected rc=0, got $og_rc ($og_out)"
[[ -f "$og_prom" ]] || fail "scenario20: prepaid-usage.prom not written"
grep -q '^fleet_prepaid_usage_pct{provider="opencode-go",window="5h"} 15$' "$og_prom" \
  || fail "scenario20: 5h usage pct must be 15, got: $(cat "$og_prom")"
grep -q '^fleet_prepaid_usage_pct{provider="opencode-go",window="weekly"} 90$' "$og_prom" \
  || fail "scenario20: weekly usage pct must be 90"
grep -q '^fleet_prepaid_usage_pct{provider="opencode-go",window="monthly"} 43$' "$og_prom" \
  || fail "scenario20: monthly usage pct must be 43"
grep -q "^fleet_prepaid_window_reset_timestamp{provider=\"opencode-go\",window=\"weekly\"} $og_reset_week$" "$og_prom" \
  || fail "scenario20: weekly reset timestamp must be $og_reset_week"
# Paced cap: remaining 10% over 50h at K=12.5 -> floor(10/50*12.5) = 2, the declared cap.
grep -q '^fleet_prepaid_paced_cap{provider="opencode-go"} 2$' "$og_prom" \
  || fail "scenario20: paced cap must be 2 (10% left over 50h at K=12.5), got: $(grep paced_cap "$og_prom")"
grep -q '^fleet_prepaid_declared_cap{provider="opencode-go"} 2$' "$og_prom" \
  || fail "scenario20: declared cap must be 2"
# State overlay: same numbers in the state file, pick count and unknown
# fields preserved (this is a usage overlay, not a pick).
og_state="$PI_PACKET_STATE/prepaid-usage/opencode-go.json"
[[ "$(jq -r '.count' "$og_state")" == "82" ]] \
  || fail "scenario20: pick count 82 must survive the overlay, got $(jq -r '.count' "$og_state")"
[[ "$(jq -r '.week' "$og_state")" == "2026-W35" ]] \
  || fail "scenario20: week must survive the overlay"
[[ "$(jq -r '.billing_lane' "$og_state")" == "keep-me" ]] \
  || fail "scenario20: unknown state fields must survive the overlay"
[[ "$(jq -r '.usage.weekly.percent' "$og_state")" == "90" ]] \
  || fail "scenario20: state must carry the weekly percent"
[[ "$(jq -r '.usage.weekly.reset_epoch' "$og_state")" == "$og_reset_week" ]] \
  || fail "scenario20: state must carry the weekly reset epoch"
[[ "$(jq -r '.usage_source' "$og_state")" == "opencode-zen-go-usage-api" ]] \
  || fail "scenario20: state must name the vendor endpoint"
ok "scenario20: opencode-go reader emits fleet_prepaid_usage_pct + resets + paced cap and overlays the state"

# --- 21. fleet-ops#5022: the paced cap MOVES with the read (the cap change)
# Same declared cap 2, weekly 95% used with 48h to reset -> remaining 5% over
# 48h is floor(5/48*12.5) = 1, so the pace says the declared cap is one too
# high. FleetOpenCodeGoPaceExceeded (declared > paced) is the alert that files
# the repair packet carrying this number.
: >"$gh_log"; : >"$triage"
og_reset_week2=$((og_now_s + 48 * 3600))
python3 - "$scratch/og-usage-tight.json" "$og_reset_5h" "$og_reset_week2" "$og_reset_month" <<'PY'
import json, sys
from datetime import datetime, timezone
path, r5, rw, rm = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
def iso(s):
    return datetime.fromtimestamp(s, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
out = {"usage": {"rolling": {"status": "ok", "percent": 15, "resetsAt": iso(r5)},
                 "weekly": {"status": "ok", "percent": 95, "resetsAt": iso(rw)},
                 "monthly": {"status": "ok", "percent": 43, "resetsAt": iso(rm)}}}
open(path, "w").write(json.dumps(out))
PY
rm -f "$og_prom"
set +e
tight_out=$(
  OPENCODE_GO_USAGE_URL="$scratch/og-usage-tight.json" \
  FLEET_PREPAID_USAGE_PROM_PATH="$og_prom" \
  FLEET_ENTITLED_SEATS_JSON="$scratch/entitled-seats.json" \
  SEAT_CAPS_JSON="$scratch/seat-caps.json" \
  FLEET_OPS_REPO="$scratch" \
  "$bin" 2>&1
)
tight_rc=$?
set -e
[[ "$tight_rc" == "0" ]] || fail "scenario21: expected rc=0, got $tight_rc ($tight_out)"
grep -q '^fleet_prepaid_paced_cap{provider="opencode-go"} 1$' "$og_prom" \
  || fail "scenario21: paced cap must drop to 1 (5% left over 48h), got: $(grep paced_cap "$og_prom")"
grep -q '^fleet_prepaid_declared_cap{provider="opencode-go"} 2$' "$og_prom" \
  || fail "scenario21: declared cap stays 2 while the pace says 1"
# floor 1: a nearly-spent pool is never paced to 0 (the seat must stay usable
# until a real wall benches it).
og_reset_week3=$((og_now_s + 72 * 3600))
python3 - "$scratch/og-usage-empty.json" "$og_reset_5h" "$og_reset_week3" "$og_reset_month" <<'PY'
import json, sys
from datetime import datetime, timezone
path, r5, rw, rm = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
def iso(s):
    return datetime.fromtimestamp(s, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
out = {"usage": {"rolling": {"status": "ok", "percent": 0, "resetsAt": iso(r5)},
                 "weekly": {"status": "ok", "percent": 99, "resetsAt": iso(rw)},
                 "monthly": {"status": "ok", "percent": 43, "resetsAt": iso(rm)}}}
open(path, "w").write(json.dumps(out))
PY
rm -f "$og_prom"
set +e
empty_out=$(
  OPENCODE_GO_USAGE_URL="$scratch/og-usage-empty.json" \
  FLEET_PREPAID_USAGE_PROM_PATH="$og_prom" \
  FLEET_ENTITLED_SEATS_JSON="$scratch/entitled-seats.json" \
  SEAT_CAPS_JSON="$scratch/seat-caps.json" \
  FLEET_OPS_REPO="$scratch" \
  "$bin" 2>&1
)
empty_rc=$?
set -e
[[ "$empty_rc" == "0" ]] || fail "scenario21: expected rc=0, got $empty_rc ($empty_out)"
grep -q '^fleet_prepaid_paced_cap{provider="opencode-go"} 1$' "$og_prom" \
  || fail "scenario21: a spent pool must floor the paced cap at 1, never 0"
ok "scenario21: paced cap follows the live read down (2 -> 1) and floors at 1"

# --- 22. fleet-ops#5022: dead reader -> no metric, and the 5h wall is loud --
: >"$gh_log"; : >"$triage"
rm -f "$og_prom"
set +e
dead_out=$(
  OPENCODE_GO_USAGE_URL="$scratch/nonexistent-og.json" \
  FLEET_PREPAID_USAGE_PROM_PATH="$og_prom" \
  FLEET_ENTITLED_SEATS_JSON="$scratch/entitled-seats.json" \
  SEAT_CAPS_JSON="$scratch/seat-caps.json" \
  FLEET_OPS_REPO="$scratch" \
  "$bin" 2>&1
)
dead_rc=$?
set -e
[[ "$dead_rc" == "0" ]] || fail "scenario22: expected rc=0 (non-fatal), got $dead_rc"
[[ ! -f "$og_prom" ]] || fail "scenario22: .prom must NOT be written on a dead reader"
grep -q 'opencode-go usage reader: no data' <<<"$dead_out" \
  || fail "scenario22: missing 'no data' log line"
# 5h window at/above the wall threshold is named explicitly so a bench is
# explained by the live figure rather than the flat default.
python3 - "$scratch/og-usage-wall.json" "$og_reset_5h" "$og_reset_week" "$og_reset_month" <<'PY'
import json, sys
from datetime import datetime, timezone
path, r5, rw, rm = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
def iso(s):
    return datetime.fromtimestamp(s, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
out = {"usage": {"rolling": {"status": "ok", "percent": 100.2, "resetsAt": iso(r5)},
                 "weekly": {"status": "ok", "percent": 90, "resetsAt": iso(rw)},
                 "monthly": {"status": "ok", "percent": 43, "resetsAt": iso(rm)}}}
open(path, "w").write(json.dumps(out))
PY
: >"$triage"
wall_out=$(
  OPENCODE_GO_USAGE_URL="$scratch/og-usage-wall.json" \
  FLEET_PREPAID_USAGE_PROM_PATH="$og_prom" \
  FLEET_ENTITLED_SEATS_JSON="$scratch/entitled-seats.json" \
  SEAT_CAPS_JSON="$scratch/seat-caps.json" \
  FLEET_OPS_REPO="$scratch" \
  "$bin" 2>&1
)
grep -q 'PREPAID-UTIL-OPENCODE-GO-5H-WALL' "$triage" \
  || fail "scenario22: a 5h window at 100.2% must raise the wall line"
grep -q '^fleet_prepaid_usage_pct{provider="opencode-go",window="5h"} 100.2$' "$og_prom" \
  || fail "scenario22: a fractional 5h percentage must survive the reader"
ok "scenario22: dead reader omits the metric; a walled 5h window is named loud"
unset OPENCODE_GO_USAGE_URL

ok "fleet-prepaid-util-canary: ladder, expiry-waste, bench skip, dedup, cap, prod clean, cursor spend reader, ETIMEDOUT watch, opencode-go usage reader"
