#!/usr/bin/env bash
# tests/fleet-token-economy.test.sh
#
# CI drill for the 2026-08-27 token economy rebalance
# (fleet-ops#1176) as amended by fleet-ops#3125 (2026-09-04,
# Nish: measured yield supersedes the volume prefix). Locks the seat-cap
# configuration that implements the economy from live meters:
#   - product picks (PI_PICK_ROLE=product, pi-issue-run/pi-packet-run)
#     route by product_order:value — rolling yield / rolling cost per
#     session; light packets order by value, heavy/keystone yield-first
#     (fleet-ops#3323, superseding the #3125 pure-yield order)
#   - xai-oauth (SuperGrok) provider cap 2, grok-4.6 cap 2, grok-4.5 cap 0
#   - cursor is capped at 1, keystone/senior-review only (not a free lane)
#   - scout/canary/audit picks keep leftover free lanes
#     (commandcode/hetzner/opencode) before prepaid; metered
#     (minimax/straitly/...) last
#   - devin provider floor 4, probe ceilings pinned == caps until #3258 (fleet-ops#3443); glm-5-2 floor 3 / ceiling 3,
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

# Rule helpers (fleet-ops#3504): assert the RULE, never the number.
# A cap change with a dated reason passes; without a reason it fails.
date_pat='(20[0-9]{2}-[0-9]{2}-[0-9]{2})'
meas_pat='(n=[0-9]+|p95|p99|HTTP ?[1-5][0-9][0-9]|request ?id|observed_at|usable_at|quota_exhausted|free_quota_exhausted|credentials_bad|ETIMEDOUT|rate.?limit|timeout|spawnSync|spawn|returned|PONG|404|403|429|402|500|503|\$[0-9]|meter|cost=null|sessions|yield|pr_count|pass@1|error.?class|insufficient.?credit|resource_exhausted)'

# entry_has_dated_reason <jq-entry-filter> — 0 if the entry has a .reason
# or a dated _ field carrying a date + measurement marker; 1 otherwise.
# Scalar entries (a bare number cap) carry no reason of their own — the
# caller is expected to fall back to the parent provider's reason.
entry_has_dated_reason() {
    local entry_filter="$1" reason dated_field entry_type
    entry_type=$(jq -r "$entry_filter | type" "$caps" 2>/dev/null)
    [[ "$entry_type" == "object" ]] || return 1
    reason=$(jq -r "$entry_filter.reason // empty" "$caps" 2>/dev/null)
    if [[ -n "$reason" ]] && grep -qE "$date_pat" <<<"$reason" && grep -qiE "$meas_pat" <<<"$reason"; then
        return 0
    fi
    while IFS= read -r dated_field; do
        [[ -n "$dated_field" ]] || continue
        grep -qiE "$meas_pat" <<<"$dated_field" && return 0
    done < <(jq -r "$entry_filter | to_entries[] | select(.key|startswith(\"_\")) | select(.value|tostring|test(\"20[0-9]{2}-[0-9]{2}-[0-9]{2}\")) | .value|tostring" "$caps" 2>/dev/null)
    return 1
}

# cap_zero_is_intentional <jq-entry-filter> — 0 if the entry has cap=0,
# intentional_cap_zero present, and a dated reason citing an error class.
cap_zero_is_intentional() {
    local entry_filter="$1" icz reason
    icz=$(jq -r "$entry_filter.intentional_cap_zero // empty" "$caps")
    [[ -n "$icz" ]] || return 1
    entry_has_dated_reason "$entry_filter" || return 1
    return 0
}

# --- product order + devin AIMD (fleet-ops#3125/#3323) -------------------
product_order=$(jq -r '.product_order // empty' "$caps")
[[ "$product_order" == "value" ]] \
  || fail "product_order must be 'value' (fleet-ops#3323), got: $product_order"

if jq -e '.volume_providers_in_order' "$caps" >/dev/null 2>&1; then
  fail "volume_providers_in_order must be retired (fleet-ops#3125)"
fi
if jq -e '._comment_volume_order' "$caps" >/dev/null 2>&1; then
  fail "_comment_volume_order must be retired (fleet-ops#3125)"
fi

devin_hard=$(jq -r '.providers.devin.hard_ceiling // false' "$caps")
[[ "$devin_hard" == "false" ]] || fail "devin hard_ceiling must be false/absent (fleet-ops#3125), got: $devin_hard"

# fleet-ops#3443 (2026-09-05): probe ceilings 6/8 put 8 devin sessions in
# flight and Devin answered resource_exhausted on every new one, so until
# fleet-ops#3258 lifts the pin with evidence every devin probe ceiling equals
# its declared cap (provider and model). hard_ceiling stays absent (#3125).
devin_probe=$(jq -r '.providers.devin.max_probe_ceiling // empty' "$caps")
[[ "$devin_probe" == "$(jq -r '.providers.devin.cap' "$caps")" ]] \
  || fail "devin max_probe_ceiling must equal its cap while pinned (fleet-ops#3443, lift via #3258), got: $devin_probe"

glm52=$(jq -r '.providers.devin.models["glm-5-2"]' "$caps")
# Rule 1 (fleet-ops#3504): the cap value is justified by a dated reason, not
# pinned by the test. A cap change with a dated reason passes; without one it
# fails here without a test edit.
entry_has_dated_reason '.providers.devin.models["glm-5-2"]' \
  || entry_has_dated_reason '.providers.devin' \
  || fail "glm-5-2 cap must carry a dated reason with a measurement (rule 1, fleet-ops#3504)"
[[ "$(jq -r '.max_probe_ceiling' <<<"$glm52")" == "$(jq -r '.cap' <<<"$glm52")" ]] \
  || fail "glm-5-2 max_probe_ceiling must equal its cap while pinned (fleet-ops#3443)"
swe17=$(jq -r '.providers.devin.models["swe-1-7"]' "$caps")
# Rule 1: swe-1-7 cap is justified by a dated reason (infra deaths were not
# yield — #3250/#3310; the reason cites the correction, not a number).
entry_has_dated_reason '.providers.devin.models["swe-1-7"]' \
  || entry_has_dated_reason '.providers.devin' \
  || fail "swe-1-7 cap must carry a dated reason with a measurement (rule 1, fleet-ops#3504)"
[[ "$(jq -r '.max_probe_ceiling' <<<"$swe17")" == "$(jq -r '.cap' <<<"$swe17")" ]] || fail "swe-1-7 max_probe_ceiling must equal its cap while pinned (fleet-ops#3443; seat restored 2026-09-05)"

ok "product_order=value, volume order retired, devin AIMD not hard_ceiling with probe ceilings pinned == caps; devin/glm-5-2 + swe-1-7 caps carry dated reasons (rule 1, fleet-ops#3504)"

# --- prepaid order, then leftover prepaid after (fleet-ops#1178/#3125) ----
prepaid_order=$(jq -r '.prepaid_providers_in_order | join(" ")' "$caps")
[[ "$prepaid_order" == "ollama devin cline cursor xai-oauth" ]] \
  || fail "prepaid order must be 'ollama devin cline cursor xai-oauth', got: $prepaid_order"

devin_cap=$(jq -r '.providers.devin.cap // empty' "$caps")
[[ -n "$devin_cap" ]] || fail "devin cap must be present, got: empty"
# Rule 1 (fleet-ops#3504): the cap value is justified by a dated reason.
entry_has_dated_reason '.providers.devin' \
  || fail "devin cap must carry a dated reason with a measurement (rule 1, fleet-ops#3504)"

devin_class=$(jq -r '.providers.devin.class // empty' "$caps")
[[ "$devin_class" == "prepaid-quota" ]] || fail "devin class must be prepaid-quota, got: $devin_class"

ok "prepaid order ollama devin cline cursor xai-oauth; devin cap carries a dated reason, class prepaid-quota"

# --- xai-oauth (SuperGrok): cap justified by dated reason, grok-4.5 cap=0 intentional ---
xai_cap=$(jq -r '.providers["xai-oauth"].cap // empty' "$caps")
[[ -n "$xai_cap" ]] || fail "xai-oauth cap must be present, got: empty"
# Rule 1 (fleet-ops#3504): the cap value is justified by a dated reason.
entry_has_dated_reason '.providers["xai-oauth"]' \
  || fail "xai-oauth cap must carry a dated reason with a measurement (rule 1, fleet-ops#3504)"

xai_class=$(jq -r '.providers["xai-oauth"].class // empty' "$caps")
[[ "$xai_class" == "prepaid-quota" ]] || fail "xai-oauth class must be prepaid-quota, got: $xai_class"

xai_quota=$(jq -r '.providers["xai-oauth"].quota_window // empty' "$caps")
[[ "$xai_quota" == "weekly" ]] || fail "xai-oauth quota_window must be weekly, got: $xai_quota"

# grok-4.6: cap justified by a dated reason (rule 1).
entry_has_dated_reason '.providers["xai-oauth"].models["grok-4.6"]' \
  || entry_has_dated_reason '.providers["xai-oauth"]' \
  || fail "grok-4.6 cap must carry a dated reason with a measurement (rule 1, fleet-ops#3504)"
# grok-4.5: cap=0 must be intentional with a dated reason citing the error class (rule 3).
xai_45_cap=$(jq -r '.providers["xai-oauth"].models["grok-4.5"] | if type=="object" then (.cap // 0) else . end' "$caps")
[[ "$xai_45_cap" == "0" ]] || fail "grok-4.5 model cap is not zero (rule 3 precondition), got: $xai_45_cap"
cap_zero_is_intentional '.providers["xai-oauth"].models["grok-4.5"]' \
  || fail "grok-4.5 cap=0 must carry intentional_cap_zero + a dated reason citing the error class (rule 3, fleet-ops#3504)"

ok "xai-oauth cap carries a dated reason, weekly, grok-4.6 cap justified, grok-4.5 cap=0 intentional with dated reason"

# --- cursor: cap justified by dated reason, keystone-only ----------------
cursor_cap=$(jq -r '.providers.cursor.cap // empty' "$caps")
[[ -n "$cursor_cap" ]] || fail "cursor cap must be present, got: empty"
# Rule 1 (fleet-ops#3504): the cap value is justified by a dated reason.
entry_has_dated_reason '.providers.cursor' \
  || fail "cursor cap must carry a dated reason with a measurement (rule 1, fleet-ops#3504)"

if jq -e '.free_providers_in_order | index("cursor")' "$caps" >/dev/null; then
  fail "cursor must not be in free_providers_in_order"
fi
if ! jq -e '.senior_seats_in_order[0] == "cursor/cursor-grok-4.6-high"' "$caps" >/dev/null; then
  fail "senior_seats_in_order must start with cursor/cursor-grok-4.6-high (fleet-ops#3121)"
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
[[ "$daily" =~ ^[0-9]+$ && "$daily" -gt 0 ]] \
  || fail "cursor daily spend target must be a positive integer, got: $daily"

ok "cursor cap carries a dated reason, keystone-only, overage model cursor-grok-4.6-high, opens_after_included_exhausted true, included still open, positive daily target"

# --- walled_comeback table (fleet-ops#1167) --------------------------------
for k in min_probe_interval_s rate_limit_s daily_quota_s monthly_quota_s free_balance_exhausted_s credentials_bad_s; do
  v=$(jq -r --arg k "$k" '.walled_comeback[$k] // empty' "$caps")
  [[ "$v" =~ ^[0-9]+$ ]] || fail "walled_comeback.$k must be a positive integer, got: $v"
done
# The comeback clock values are operational, not caps — the positive-integer
# loop above is the rule. The specific values are justified by the _comment
# field on the walled_comeback table (dated, names the devin lesson).
wc_comment=$(jq -r '.walled_comeback._comment // empty' "$caps")
[[ -n "$wc_comment" ]] || fail "walled_comeback must carry a _comment explaining the clock values"

ok "walled_comeback table is present with positive-integer clocks and a dated comment"

# --- free lanes: bai/commandcode/hetzner/opencode + xkiro (free-tier audition, 2026-09-05) ---
# leftover free after the volume prefix (b.ai wired 2026-08-27, fleet-ops#1272)
free_order=$(jq -r '.free_providers_in_order | join(" ")' "$caps")
[[ "$free_order" == "bai commandcode hetzner opencode xkiro" ]] \
  || fail "free order must be 'bai commandcode hetzner opencode xkiro', got: $free_order"

# prepaid and metered providers must not appear as free lanes
for p in devin cursor cline ollama xai-oauth grok minimax straitly zenmux openrouter; do
  if jq -e --arg p "$p" '.free_providers_in_order | index($p)' "$caps" >/dev/null; then
    fail "$p must not be in free_providers_in_order"
  fi
done

ok "free lanes are bai, commandcode, hetzner, opencode; paid lanes are not free"

# --- grok (legacy grok.com/CLI slug) cap=0 intentional with dated reason ---
grok_cap=$(jq -r '.providers.grok.cap // empty' "$caps")
[[ "$grok_cap" == "0" ]] || fail "grok cap is not zero (rule 3 precondition), got: $grok_cap"
# Rule 3 (fleet-ops#3504): cap=0 carries intentional_cap_zero + a dated
# reason citing the error class. The reason already names the 403 + the
# dead-decoy class — this asserts the contract, not the number.
cap_zero_is_intentional '.providers.grok' \
  || fail "grok cap=0 must carry intentional_cap_zero + a dated reason citing the error class (rule 3, fleet-ops#3504)"

ok "grok is cap=0 intentional with a dated reason (xai-oauth is the wired SuperGrok seat)"

# --- opencode-anthropic (Claude) cap=0 intentional -------------------------
claude_cap=$(jq -r '.providers["opencode-anthropic"].cap // empty' "$caps")
[[ "$claude_cap" == "0" ]] || fail "opencode-anthropic (Claude) cap is not zero (rule 3 precondition), got: $claude_cap"
cap_zero_is_intentional '.providers["opencode-anthropic"]' \
  || fail "opencode-anthropic cap=0 must carry intentional_cap_zero + a dated reason (rule 3, fleet-ops#3504)"

ok "opencode-anthropic (Claude) is cap=0 intentional with a dated reason"

# --- metered providers are the last bucket --------------------------------
for p in minimax straitly; do
  class=$(jq -r --arg p "$p" '.providers[$p].class // empty' "$caps")
  [[ "$class" == "metered" ]] || fail "$p class must be metered, got: $class"
done

ok "minimax and straitly are metered (last bucket)"

# --- lib/seat-lib.sh enforces product value-order + class ladder ---------
grep -q 'yield-order (product)' "$lib" \
  || fail "lib/seat-lib.sh must log the computed yield order per product pick (fleet-ops#3125)"
grep -q 'value-order (product' "$lib" \
  || fail "lib/seat-lib.sh must log the computed value order per product pick (fleet-ops#3323)"
grep -q 'SEAT_PRODUCT_ORDER' "$lib" \
  || fail "lib/seat-lib.sh must read product_order (fleet-ops#3125)"
grep -q 'seat_yield_for' "$lib" \
  || fail "lib/seat-lib.sh must read the per-seat PR-yield ledger (fleet-ops#3250/#3125)"
grep -q 'seat_cost_for' "$lib" \
  || fail "lib/seat-lib.sh must read the per-seat cost ledger (fleet-ops#3323)"
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

ok "lib/seat-lib.sh enforces product value-order + class ladder, cursor keystone-only, and seat-selection export"

ok "token economy: product_order=value, caps carry dated reasons (rule 1), cap=0 entries intentional (rule 3), devin AIMD floors/ceilings, leftover-free before metered (fleet-ops#3504)"
