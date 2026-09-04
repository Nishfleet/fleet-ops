#!/usr/bin/env bash
# tests/fleet-token-economy.test.sh
#
# CI drill for the 2026-08-27 token economy rebalance
# (fleet-ops#1176) as amended by fleet-ops#3125 (2026-09-04,
# Nish: measured yield supersedes the volume prefix). Locks the seat-cap
# configuration that implements the economy from live meters:
#   - product picks (PI_PICK_ROLE=product, pi-issue-run/pi-packet-run)
#     route by product_order:yield — rolling PR-yield ledger, ties broken
#     by class prepaid -> metered -> free (fleet-ops#3125)
#   - xai-oauth (SuperGrok) provider cap 2, grok-4.6 cap 2, grok-4.5 cap 0
#   - cursor is capped at 1, keystone/senior-review only (not a free lane)
#   - scout/canary/audit picks keep leftover free lanes
#     (commandcode/hetzner/opencode) before prepaid; metered
#     (minimax/straitly/...) last
#   - devin provider floor 4 probes to 8 (AIMD); glm-5-2 floor 3 / ceiling 6,
#     swe-1-7 floor 4 / ceiling 8
#   - grok (the legacy grok.com/CLI slug) is cap=0 with a dated reason
#   - opencode-anthropic (Claude) is cap=0 (Nish-only)
#
# If this test breaks, the token economy encoded in config/seat-caps.json
# has drifted from the 2026-08-27 decision as amended 2026-09-04.

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

# --- product order + devin AIMD (fleet-ops#3125) -------------------------
product_order=$(jq -r '.product_order // empty' "$caps")
[[ "$product_order" == "yield" ]] \
  || fail "product_order must be 'yield' (fleet-ops#3125), got: $product_order"

if jq -e '.volume_providers_in_order' "$caps" >/dev/null 2>&1; then
  fail "volume_providers_in_order must be retired (fleet-ops#3125)"
fi
if jq -e '._comment_volume_order' "$caps" >/dev/null 2>&1; then
  fail "_comment_volume_order must be retired (fleet-ops#3125)"
fi

devin_hard=$(jq -r '.providers.devin.hard_ceiling // false' "$caps")
[[ "$devin_hard" == "false" ]] || fail "devin hard_ceiling must be false/absent (fleet-ops#3125), got: $devin_hard"

devin_probe=$(jq -r '.providers.devin.max_probe_ceiling // empty' "$caps")
[[ "$devin_probe" == "8" ]] || fail "devin max_probe_ceiling must be 8 (fleet-ops#3125), got: $devin_probe"

glm52=$(jq -r '.providers.devin.models["glm-5-2"]' "$caps")
[[ "$(jq -r '.cap' <<<"$glm52")" == "3" ]] || fail "glm-5-2 declared cap must be 3"
[[ "$(jq -r '.max_probe_ceiling' <<<"$glm52")" == "6" ]] || fail "glm-5-2 max_probe_ceiling must be 6 (probe to 6)"
swe17=$(jq -r '.providers.devin.models["swe-1-7"]' "$caps")
[[ "$(jq -r '.cap' <<<"$swe17")" == "4" ]] || fail "swe-1-7 declared cap must be 4"
[[ "$(jq -r '.max_probe_ceiling' <<<"$swe17")" == "8" ]] || fail "swe-1-7 max_probe_ceiling must be 8 (probe to 8)"

ok "product_order=yield, volume order retired, devin AIMD (provider 8 / glm-5-2 6 / swe-1-7 8)"

# --- prepaid order, then leftover prepaid after (fleet-ops#1178/#3125) ----
prepaid_order=$(jq -r '.prepaid_providers_in_order | join(" ")' "$caps")
[[ "$prepaid_order" == "ollama devin cline cursor xai-oauth" ]] \
  || fail "prepaid order must be 'ollama devin cline cursor xai-oauth', got: $prepaid_order"

devin_cap=$(jq -r '.providers.devin.cap // empty' "$caps")
[[ "$devin_cap" == "4" ]] || fail "devin cap must be 4, got: $devin_cap"

devin_class=$(jq -r '.providers.devin.class // empty' "$caps")
[[ "$devin_class" == "prepaid-quota" ]] || fail "devin class must be prepaid-quota, got: $devin_class"

ok "prepaid order ollama devin cline cursor xai-oauth; devin cap 4 floor, class prepaid-quota"

# --- xai-oauth (SuperGrok): cap 2, grok-4.6=2 / grok-4.5=0 ------------
xai_cap=$(jq -r '.providers["xai-oauth"].cap // empty' "$caps")
[[ "$xai_cap" == "2" ]] || fail "xai-oauth cap must be 2 (fleet-ops#3125), got: $xai_cap"

xai_class=$(jq -r '.providers["xai-oauth"].class // empty' "$caps")
[[ "$xai_class" == "prepaid-quota" ]] || fail "xai-oauth class must be prepaid-quota, got: $xai_class"

xai_quota=$(jq -r '.providers["xai-oauth"].quota_window // empty' "$caps")
[[ "$xai_quota" == "weekly" ]] || fail "xai-oauth quota_window must be weekly, got: $xai_quota"

xai_46=$(jq -r '.providers["xai-oauth"].models["grok-4.6"] // empty' "$caps")
[[ "$xai_46" == "2" ]] || fail "grok-4.6 model cap must be 2 (fleet-ops#3125), got: $xai_46"
xai_45=$(jq -r '.providers["xai-oauth"].models["grok-4.5"] // empty' "$caps")
[[ "$xai_45" == "0" ]] || fail "grok-4.5 model cap must stay 0 (accepted assumption), got: $xai_45"

ok "xai-oauth cap 2, weekly, grok-4.6 cap 2 / grok-4.5 cap 0"

# --- cursor: cap 1, keystone-only --------------------------------------
cursor_cap=$(jq -r '.providers.cursor.cap // empty' "$caps")
[[ "$cursor_cap" == "1" ]] || fail "cursor cap must be 1, got: $cursor_cap"

if jq -e '.free_providers_in_order | index("cursor")' "$caps" >/dev/null; then
  fail "cursor must not be in free_providers_in_order"
fi
if ! jq -e '.keystone_only_providers | index("cursor")' "$caps" >/dev/null; then
  fail "cursor must be in keystone_only_providers (fleet-ops#1167)"
fi

overage_model=$(jq -r '.cursor_overage.overage_model // empty' "$caps")
[[ "$overage_model" == "cursor-grok-4.6-high" ]] \
  || fail "cursor overage model must be cursor-grok-4.6-high, got: $overage_model"

if ! jq -e '.cursor_overage.opens_after_included_exhausted == true' "$caps" >/dev/null; then
  fail "cursor_overage.opens_after_included_exhausted must be true (fleet-ops#1179)"
fi

included=$(jq -r '.cursor_overage.included_exhausted' "$caps")
[[ "$included" == "false" ]] \
  || fail "cursor included_exhausted must be false until a meter check flips it, got: $included"
daily=$(jq -r '.cursor_overage.daily_spend_target_usd // empty' "$caps")
[[ "$daily" == "16" ]] || fail "cursor daily spend target must be 16, got: $daily"

ok "cursor cap 1, keystone-only, overage model cursor-grok-4.6-high, opens_after_included_exhausted true, included still open, \$16/day target"

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

# --- lib/seat-lib.sh enforces product yield-order + class ladder ---------
grep -q 'yield-order (product)' "$lib" \
  || fail "lib/seat-lib.sh must log the computed yield order per product pick (fleet-ops#3125)"
grep -q 'SEAT_PRODUCT_ORDER' "$lib" \
  || fail "lib/seat-lib.sh must read product_order (fleet-ops#3125)"
grep -q 'seat_yield_for' "$lib" \
  || fail "lib/seat-lib.sh must read the per-seat PR-yield ledger (fleet-ops#3250/#3125)"
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

ok "lib/seat-lib.sh enforces product yield-order + class ladder, cursor keystone-only, and seat-selection export"

ok "token economy: product_order=yield, xai-oauth cap 2, cursor keystone-only, devin AIMD floors/ceilings, leftover-free before metered, grok/Claude cap 0"
