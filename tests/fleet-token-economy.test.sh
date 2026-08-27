#!/usr/bin/env bash
# tests/fleet-token-economy.test.sh
#
# CI drill for the 2026-08-27 token economy rebalance
# (fleet-ops#1176). Locks the seat-cap configuration that implements the
# rebalance from live meters:
#   - devin is first in the prepaid alternation and capped at 4
#   - xai-oauth (SuperGrok) is the last prepaid weekly seat, cap 1,
#     alternating grok-4.6 and grok-4.5
#   - cursor is capped at 1, after devin, and is not a free lane
#   - free lanes (commandcode/hetzner/opencode) are tried before prepaid,
#     metered (minimax/straitly/...) last
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

# --- devin: first in prepaid order, cap 4, class prepaid-quota ------------
prepaid_order=$(jq -r '.prepaid_providers_in_order | join(" ")' "$caps")
[[ "$prepaid_order" == "devin cursor cline ollama xai-oauth" ]] \
  || fail "prepaid order must be 'devin cursor cline ollama xai-oauth', got: $prepaid_order"

devin_cap=$(jq -r '.providers.devin.cap // empty' "$caps")
[[ "$devin_cap" == "4" ]] || fail "devin cap must be 4, got: $devin_cap"

devin_class=$(jq -r '.providers.devin.class // empty' "$caps")
[[ "$devin_class" == "prepaid-quota" ]] || fail "devin class must be prepaid-quota, got: $devin_class"

ok "devin first in prepaid order, cap 4, class prepaid-quota"

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

# --- cursor: cap 1, after devin, not a free lane --------------------------
cursor_cap=$(jq -r '.providers.cursor.cap // empty' "$caps")
[[ "$cursor_cap" == "1" ]] || fail "cursor cap must be 1, got: $cursor_cap"

if jq -e '.free_providers_in_order | index("cursor")' "$caps" >/dev/null; then
  fail "cursor must not be in free_providers_in_order"
fi

ok "cursor cap 1, after devin, not a free lane"

# --- free lanes are the commandcode/hetzner/opencode allowlist ------------
free_order=$(jq -r '.free_providers_in_order | join(" ")' "$caps")
[[ "$free_order" == "commandcode hetzner opencode" ]] \
  || fail "free order must be 'commandcode hetzner opencode', got: $free_order"

# prepaid and metered providers must not appear as free lanes
for p in devin cursor cline ollama xai-oauth grok minimax straitly zenmux openrouter; do
  if jq -e --arg p "$p" '.free_providers_in_order | index($p)' "$caps" >/dev/null; then
    fail "$p must not be in free_providers_in_order"
  fi
done

ok "free lanes are commandcode, hetzner, opencode; paid lanes are not free"

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

# --- lib/seat-lib.sh enforces the order and cap map -----------------------
grep -q 'Free first, then prepaid (alternate), then metered' "$lib" \
  || fail "lib/seat-lib.sh must document the free -> prepaid -> metered order"
grep -q 'prepaid_providers_in_order' "$lib" \
  || fail "lib/seat-lib.sh must read prepaid_providers_in_order"
grep -q 'free_providers_in_order' "$lib" \
  || fail "lib/seat-lib.sh must read free_providers_in_order"

ok "lib/seat-lib.sh enforces free -> prepaid -> metered and reads provider orders"

ok "token economy: devin-first, xai-oauth last prepaid, cursor cap 1, free-before-metered, grok/Claude cap 0"
