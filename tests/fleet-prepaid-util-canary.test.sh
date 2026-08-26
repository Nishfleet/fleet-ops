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
grep -q 'missing-from-prepaid-order' "$gh_log" || grep -q 'issue create' "$gh_log" \
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

ok "fleet-prepaid-util-canary: ladder, expiry-waste, bench skip, dedup, cap, prod clean"
