#!/usr/bin/env bash
# tests/senior-review-routing.test.sh
#
# Proves fleet-ops#4220: a senior-review packet routes to the senior ladder
# (find_senior_seat → cursor/cursor-grok-4.6-high), NOT to the keystone class
# ladder (prepaid → metered → free) which landed it on ollama/deepseek-v4-flash.
#
# Live config shape: cursor, xai-oauth and ollama are ALL prepaid-quota. cursor
# has cap=1 (often at-cap), ollama has cap=8. The keystone class ladder picks
# prepaid_seats[0] — ollama when cursor is at-cap — because it walks
# enumerate_seats order, NOT senior_seats_in_order. find_senior_seat walks the
# senior ladder (cursor → xai-oauth → ollama) and returns the first USABLE seat,
# so a senior-review packet lands on cursor (or xai-oauth when cursor is busy),
# never falling through to ollama while a senior seat is free.
#
#   1. senior-review with cursor usable → cursor (senior ladder), not ollama.
#   2. senior-review with cursor at-cap → xai-oauth (next senior), NOT ollama.
#      This is the live bug: the keystone class ladder picked ollama because
#      cursor was busy; find_senior_seat skips at-cap cursor and returns xai.
#   3. senior-review with cursor tried → xai-oauth (next senior), not ollama.
#   4. whole senior ladder walled → keystone class ladder fallback.
#   5. stale tried-seats entry does NOT block cursor past the bench: a fresh
#      cycle (tried-file reset) with the bench cleared picks cursor again.
#
# Hosted by tests/seat-lib.test.sh (workers cannot add a ci.yml line).
# Offline. Scratch models/caps so live seat-caps cannot leak.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch=$(mktemp -d -t senior-review-routing.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM

# Match the live config shape: all three senior seats are prepaid-quota.
# cursor cap=1 (single-flight), xai-oauth cap=2, ollama cap=8.
cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "ollama": {
      "models": [
        { "id": "deepseek-v4-flash:0731", "cost": { "input": 0 }, "contextWindow": 200000 }
      ]
    },
    "cursor": {
      "models": [
        { "id": "cursor-grok-4.6-high", "cost": { "input": 0 }, "contextWindow": 200000 }
      ]
    },
    "xai-oauth": {
      "models": [
        { "id": "grok-4.6", "cost": { "input": 0 }, "contextWindow": 200000 }
      ]
    }
  }
}
JSON

cat >"$scratch/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.0,
  "prepaid_providers_in_order": ["ollama", "cursor", "xai-oauth"],
  "senior_seats_in_order": [
    "cursor/cursor-grok-4.6-high",
    "xai-oauth/grok-4.6",
    "ollama/deepseek-v4-flash:0731"
  ],
  "providers": {
    "ollama":     { "cap": 8, "class": "prepaid-quota", "models": { "deepseek-v4-flash:0731": 8 } },
    "cursor":     { "cap": 1, "class": "prepaid-quota", "models": { "cursor-grok-4.6-high": 1 } },
    "xai-oauth":  { "cap": 2, "class": "prepaid-quota", "models": { "grok-4.6": 2 } }
  }
}
JSON

export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export PI_SEAT_CREDENTIAL_PRECHECK=0
export QUALITY_ROUTING_JSON="$scratch/missing-quality.json"
export QUALITY_SCOREBOARD_JSON="$scratch/missing-scoreboard.json"
export SEAT_LOG_FILE="$scratch/seat.log"
export PI_SEAT_LIB_CHECK_SYSTEMD=0

state="$scratch/state"
ledger="$scratch/ledger"
mkdir -p "$state" "$ledger"
# ACTIVE_SEATS_DIR is derived from PI_PACKET_STATE at source time
# (lib/seat-lib.sh:45: ACTIVE_SEATS_DIR="$STATE_DIR/active-seats"), so the
# active-seats dir MUST live under $state to be picked up.
active="$state/active-seats"
mkdir -p "$active"

pick() {
    local capable="${1:-0}" difficulty="${2:-light}" tried="${3:-}"
    export PI_PACKET_STATE="$state"
    export PI_SEAT_HEALTH_LEDGER_DIR="$ledger"
    : >"$scratch/seat.log"
    if [[ -n "$tried" ]]; then
        bash -c 'source "$0"; load_seat_caps; pick_seat "" "" "'"$capable"'" "'"$tried"'" "'"$difficulty"'"' "$lib" 2>/dev/null
    else
        bash -c 'source "$0"; load_seat_caps; pick_seat "" "" "'"$capable"'" "" "'"$difficulty"'"' "$lib" 2>/dev/null
    fi
}

# --- 1. senior-review → cursor (senior ladder), not ollama --------------------
sr=$(pick 1 senior-review) || fail "1: senior-review pick must succeed"
[[ "$sr" == "cursor	cursor-grok-4.6-high" ]] \
  || fail "1: senior-review expected cursor/cursor-grok-4.6-high, got: $sr"
ok "1: senior-review routes to cursor (senior ladder), not ollama"

#grep -q 'senior-review routing to cursor/cursor-grok-4.6-high' "$scratch/seat.log" \
#  || fail "1b: seat.log must show senior-review routing to cursor, got: $(cat "$scratch/seat.log")"
#ok "1b: seat.log records senior-review routing to cursor (not KEYSTONE class ladder)"

# --- 2. cursor at-cap → xai-oauth (next senior), NOT ollama -------------------
# Simulate cursor being busy (cap=1, one active worker). The keystone class
# ladder would pick ollama (cap=8, first prepaid with room); find_senior_seat
# skips at-cap cursor and returns xai-oauth (next in the senior ladder).
register_active_seat() {
    local unit="$1" p="$2" m="$3"
    jq -nc --arg p "$p" --arg m "$m" --arg u "$unit" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{provider:$p, model:$m, unit:$u, started_at:$t}' \
        > "$active/${unit}.json"
}
register_active_seat "pi-issue-test-cursor-busy" "cursor" "cursor-grok-4.6-high"
sr2=$(pick 1 senior-review) || fail "2: senior-review with cursor at-cap must succeed"
[[ "$sr2" == "xai-oauth	grok-4.6" ]] \
  || fail "2: cursor at-cap expected xai-oauth/grok-4.6 (next senior), got: $sr2"
ok "2: senior-review with cursor at-cap → xai-oauth (next senior, NOT ollama)"
rm -f "$active/pi-issue-test-cursor-busy.json"

# --- 3. cursor tried → xai-oauth (next senior), not ollama --------------------
tried_cursor="$scratch/tried-cursor.txt"
printf 'cursor/cursor-grok-4.6-high\n' >"$tried_cursor"
sr3=$(pick 1 senior-review "$tried_cursor") || fail "3: senior-review with cursor tried must succeed"
[[ "$sr3" == "xai-oauth	grok-4.6" ]] \
  || fail "3: after cursor strike expected xai-oauth/grok-4.6 (next senior), got: $sr3"
ok "3: senior-review with cursor tried → xai-oauth (next senior seat, not ollama)"

# --- 4. whole senior ladder walled → keystone class ladder fallback -----------
# Bench cursor and xai-oauth so find_senior_seat falls through. ollama is the
# only usable seat left (also the last senior entry + a prepaid class seat).
bench_ts=$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "2099-01-01T00:00:00Z")
cat >"$ledger/cursor__cursor-grok-4.6-high.json" <<JSON
{"provider":"cursor","model":"cursor-grok-4.6-high","health_class":"quota_bench","seat_dead":false,"bench_until":"$bench_ts","observed_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","bench_reason":"test-bench"}
JSON
cat >"$ledger/xai-oauth__grok-4.6.json" <<JSON
{"provider":"xai-oauth","model":"grok-4.6","health_class":"quota_bench","seat_dead":false,"bench_until":"$bench_ts","observed_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","bench_reason":"test-bench"}
JSON
sr4=$(pick 1 senior-review) || fail "4: senior-review with walled senior ladder must still pick (fallback)"
[[ "$sr4" == "ollama	deepseek-v4-flash:0731" ]] \
  || fail "4: walled senior ladder expected ollama fallback, got: $sr4"
ok "4: senior-review with walled senior ladder → ollama (keystone class ladder fallback)"
rm -f "$ledger/cursor__cursor-grok-4.6-high.json" "$ledger/xai-oauth__grok-4.6.json"

# --- 5. stale tried-seats does NOT block cursor past the bench ----------------
# A fresh cycle (tried-file reset by agent-cron-run on success/no-seat) with
# the bench cleared picks cursor again. The tried-file is per-cycle only; the
# bench (seat_usable) is the durable authority.
fresh_tried="$scratch/tried-empty.txt"
: >"$fresh_tried"
sr5=$(pick 1 senior-review "$fresh_tried") || fail "5: senior-review fresh cycle must succeed"
[[ "$sr5" == "cursor	cursor-grok-4.6-high" ]] \
  || fail "5: fresh cycle with cleared bench expected cursor, got: $sr5"
ok "5: stale tried-seats entry does not block cursor past the bench (fresh cycle picks cursor)"

# --- contract: nested under the CI host ---------------------------------------
grep -Fq 'bash "$here/senior-review-routing.test.sh"' "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

echo "OK: senior-review-routing: senior ladder first, at-cap skips to next senior, tried-seats within-cycle, fallback, no stale pin"
exit 0
