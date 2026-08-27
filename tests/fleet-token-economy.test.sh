#!/usr/bin/env bash
# tests/fleet-token-economy.test.sh
#
# CI drill for the 2026-08-27 token economy rebalance
# (fleet-ops#1176). Locks the seat-cap configuration that implements the
# rebalance from live meters:
#   - volume prefix is first (ollama -> devin -> commandcode -> cline)
#     then leftover prepaid (xai-oauth; cursor is keystone-only, fleet-ops#1167)
#   - xai-oauth (SuperGrok) is the last prepaid weekly seat, cap 1,
#     alternating grok-4.6 and grok-4.5
#   - cursor is capped at 1, keystone/senior-review only (not a free lane, not volume)
#   - leftover free lanes (commandcode/hetzner/opencode) sit after the
#     volume prefix; metered (minimax/straitly/...) last
#   - grok (the legacy grok.com/CLI slug) is cap=0 with a dated reason
#   - opencode-anthropic (Claude) is cap=0 (Nish-only)
#
# If this test breaks, the token economy encoded in config/seat-caps.json
# has drifted from the 2026-08-27 decision.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
caps="$repo_root/config/seat-caps.json"
lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$caps" ]] || fail "seat-caps.json not found: $caps"
[[ -f "$lib" ]] || fail "seat-lib.sh not found: $lib"
command -v jq >/dev/null || fail "jq required"

jq -e . "$caps" >/dev/null || fail "seat-caps.json does not parse"

# --- volume prefix first, leftover prepaid after (fleet-ops#1178) ---------
prepaid_order=$(jq -r '.prepaid_providers_in_order | join(" ")' "$caps")
[[ "$prepaid_order" == "ollama devin cline cursor xai-oauth" ]] \
  || fail "prepaid order must be 'ollama devin cline cursor xai-oauth', got: $prepaid_order"

devin_cap=$(jq -r '.providers.devin.cap // empty' "$caps")
[[ "$devin_cap" == "4" ]] || fail "devin cap must be 4, got: $devin_cap"

devin_class=$(jq -r '.providers.devin.class // empty' "$caps")
[[ "$devin_class" == "prepaid-quota" ]] || fail "devin class must be prepaid-quota, got: $devin_class"

ok "prepaid order is volume prefix then leftover (ollama devin cline cursor xai-oauth); devin cap 4, class prepaid-quota"

# --- xai-oauth (SuperGrok): last prepaid, cap 1, weekly, alternates -------
xai_cap=$(jq -r '.providers["xai-oauth"].cap // empty' "$caps")
[[ "$xai_cap" == "1" ]] || fail "xai-oauth cap must be 1, got: $xai_cap"

xai_class=$(jq -r '.providers["xai-oauth"].class // empty' "$caps")
[[ "$xai_class" == "prepaid-quota" ]] || fail "xai-oauth class must be prepaid-quota, got: $xai_class"

xai_quota=$(jq -r '.providers["xai-oauth"].quota_window // empty' "$caps")
[[ "$xai_quota" == "weekly" ]] || fail "xai-oauth quota_window must be weekly, got: $xai_quota"

xai_models=$(jq -r '.providers["xai-oauth"].models | keys | sort | join(" ")' "$caps")
[[ "$xai_models" == "grok-4.5 grok-4.6" ]] \
  || fail "xai-oauth models must be grok-4.5 grok-4.6, got: $xai_models"

ok "xai-oauth last in prepaid order, cap 1, weekly, models grok-4.5/4.6"

# --- cursor: cap 1, keystone-only, leftover prepaid is xai-oauth ----------
cursor_cap=$(jq -r '.providers.cursor.cap // empty' "$caps")
[[ "$cursor_cap" == "1" ]] || fail "cursor cap must be 1, got: $cursor_cap"

if jq -e '.free_providers_in_order | index("cursor")' "$caps" >/dev/null; then
  fail "cursor must not be in free_providers_in_order"
fi
if jq -e '.volume_providers_in_order | index("cursor")' "$caps" >/dev/null; then
  fail "cursor must not be in volume_providers_in_order"
fi
if ! jq -e '.keystone_only_providers | index("cursor")' "$caps" >/dev/null; then
  fail "cursor must be in keystone_only_providers (fleet-ops#1167)"
fi

overage_model=$(jq -r '.cursor_overage.overage_model // empty' "$caps")
[[ "$overage_model" == "cursor-grok-4.6-high" ]] \
  || fail "cursor overage model must be cursor-grok-4.6-high, got: $overage_model"
included=$(jq -r '.cursor_overage.included_exhausted' "$caps")
[[ "$included" == "false" ]] \
  || fail "cursor included_exhausted must be false until a meter check flips it, got: $included"
daily=$(jq -r '.cursor_overage.daily_spend_target_usd // empty' "$caps")
[[ "$daily" == "16" ]] || fail "cursor daily spend target must be 16, got: $daily"

ok "cursor cap 1, keystone-only, overage model cursor-grok-4.6-high, included still open, \$16/day target"

# --- walled_comeback table (fleet-ops#1167) --------------------------------
for k in min_probe_interval_s rate_limit_s daily_quota_s monthly_quota_s free_balance_exhausted_s credentials_bad_s; do
  v=$(jq -r --arg k "$k" '.walled_comeback[$k] // empty' "$caps")
  [[ "$v" =~ ^[0-9]+$ ]] || fail "walled_comeback.$k must be a positive integer, got: $v"
done
rl=$(jq -r '.walled_comeback.rate_limit_s' "$caps")
[[ "$rl" == "900" ]] || fail "walled_comeback.rate_limit_s must be 900 (15min, the devin lesson), got: $rl"
probe=$(jq -r '.walled_comeback.min_probe_interval_s' "$caps")
[[ "$probe" == "900" ]] || fail "walled_comeback.min_probe_interval_s must be 900 (never hammer), got: $probe"

ok "walled_comeback table is present with 15min rate-limit and 15min probe floor"

# --- free lanes are the commandcode/hetzner/opencode allowlist ------------
# leftover free after the volume prefix (b.ai wired 2026-08-27, fleet-ops#1272)
free_order=$(jq -r '.free_providers_in_order | join(" ")' "$caps")
[[ "$free_order" == "bai commandcode hetzner opencode" ]] \
  || fail "free order must be 'bai commandcode hetzner opencode', got: $free_order"

# prepaid and metered providers must not appear as free lanes
for p in devin cursor cline ollama xai-oauth grok minimax straitly zenmux openrouter; do
  if jq -e --arg p "$p" '.free_providers_in_order | index($p)' "$caps" >/dev/null; then
    fail "$p must not be in free_providers_in_order"
  fi
done

ok "free lanes are bai, commandcode, hetzner, opencode; paid lanes are not free"

# --- grok (legacy grok.com/CLI slug) stays cap=0 and dated ----------------
grok_cap=$(jq -r '.providers.grok.cap // empty' "$caps")
[[ "$grok_cap" == "0" ]] || fail "grok cap must be 0, got: $grok_cap"

grok_reason=$(jq -r '.providers.grok.reason // ""' "$caps")
[[ -n "$grok_reason" ]] || fail "grok cap=0 must have a reason"
[[ "$grok_reason" =~ 20[0-9]{2}-[0-9]{2}-[0-9]{2} ]] || fail "grok reason must include a YYYY-MM-DD date"

ok "grok is cap=0 with a dated reason (xai-oauth is the wired SuperGrok seat)"

# --- opencode-anthropic (Claude) is cap=0 / Nish-only ---------------------
claude_cap=$(jq -r '.providers["opencode-anthropic"].cap // empty' "$caps")
[[ "$claude_cap" == "0" ]] || fail "opencode-anthropic (Claude) cap must be 0, got: $claude_cap"

ok "opencode-anthropic (Claude) is cap=0"

# --- metered providers are the last bucket --------------------------------
for p in minimax straitly; do
  class=$(jq -r --arg p "$p" '.providers[$p].class // empty' "$caps")
  [[ "$class" == "metered" ]] || fail "$p class must be metered, got: $class"
done

ok "minimax and straitly are metered (last bucket)"

# --- lib/seat-lib.sh enforces volume-first then leftover prepaid ----------
grep -q 'volume front-of-ladder' "$lib" \
  || fail "lib/seat-lib.sh must document volume front-of-ladder (#1178)"
grep -q 'leftover prepaid' "$lib" \
  || fail "lib/seat-lib.sh must document leftover prepaid after the volume prefix"
grep -q 'prepaid_providers_in_order' "$lib" \
  || fail "lib/seat-lib.sh must read prepaid_providers_in_order"
grep -q 'free_providers_in_order' "$lib" \
  || fail "lib/seat-lib.sh must read free_providers_in_order"

grep -q 'keystone/senior-review only' "$lib" \
  || fail "lib/seat-lib.sh must skip cursor for non-keystone packets (fleet-ops#1167)"
grep -q 'record_seat_selection' "$lib" \
  || fail "lib/seat-lib.sh must record every pick for fleet_seat_selection_24h"
grep -q 'fleet_seat_selection_24h' "$lib" \
  || fail "lib/seat-lib.sh must export fleet_seat_selection_24h"

ok "lib/seat-lib.sh enforces volume-first then leftover prepaid, cursor keystone-only, and seat-selection export"

ok "token economy: volume prefix first, xai-oauth last prepaid, cursor keystone-only, leftover-free before metered, grok/Claude cap 0"
