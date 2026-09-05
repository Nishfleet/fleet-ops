#!/usr/bin/env bash
# tests/seat-caps-citation.test.sh
#
# sr-never-vibes (fleet-ops#538, Nish 2026-08-26): every behaviour-driving
# number in config/seat-caps.json must come from a measurement that names
# a date, a sample size (n=, p95), a probe output, or an observed provider
# signal (429 / rate-limit / timeout).
#
# The sr-never-vibes canary auto-files fleet-ops tickets when a constant
# is missing that citation. This test is the LOCAL offline gate for the
# specific case the canary filed (fleet-ops#703 — orcarouter
# cap-no-measurement): it pins the orcarouter citation so a future revert
# is caught before push, instead of waiting for the next heartbeat tick
# to re-file.
#
# Fleet-wide enforcement stays with the canary. This test is narrow and
# owns the orcarouter fix.
#
# What we prove:
#   1. orcarouter has cap=0 and a non-empty .reason (entitled-wired
#      already covers the "cap=0 with reason" contract; this scenario
#      exists to pin the audit trail and pre-flight a JSON edit before
#      the canary re-files).
#   2. The orcarouter .reason names: 2026-08-27 (date), n=3 (sample
#      size), HTTP 402 (observed provider signal), at least one request
#      id (probe-output marker), and the seat-health ledger path (the
#      mechanical source the citation is grounded in).
#   3. orcarouter is NOT in free_providers_in_order while cap=0
#      (a cap=0 free-class provider in the order would still be probed
#      and log 'skipped (provider cap=0)'; the convention is to remove
#      it so the seat stays out of pick_seat's look-ahead).
#   4. The seat-caps JSON parses cleanly. A future edit that breaks
#      JSON would break pick_seat globally, so the parse is the cheap
#      local smoke before the canary's wider sweep.
#   5. The fleet-wide cap=0 reasons ALL carry a dated measurement
#      marker (the cross-provider invariant entitled-wired owns for
#      dates; this test owns the measurement marker on top of the date
#      so a vibes line in a cap=0 reason is also caught here, before
#      push).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
caps="$repo_root/config/seat-caps.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$caps" ]] || fail "seat-caps.json not found: $caps"
command -v jq >/dev/null || fail "jq required"

# 4. JSON parses
echo "--- scenario 4: seat-caps.json parses ---"
jq . "$caps" >/dev/null || fail "seat-caps.json does not parse"
ok "seat-caps.json parses"

# A citation must mention a YYYY-MM-DD date AND at least one measurement
# marker. Pure date without a measurement is a vibes line.
date_pat='(20[0-9]{2}-[0-9]{2}-[0-9]{2})'
meas_pat='(n=[0-9]+|p95|p99|HTTP ?[1-5][0-9][0-9]|request ?id|observed_at|usable_at|quota_exhausted|free_quota_exhausted|credentials_bad|ETIMEDOUT|rate.?limit|timeout|spawnSync|spawn|returned|PONG|404|403|429|402|500|503|\$[0-9]|meter|cost=null)'

# 1. orcarouter: cap=0 + reason present
echo "--- scenario 1: orcarouter cap=0 with non-empty reason ---"
orcarouter_cap=$(jq -r '.providers.orcarouter.cap // empty' "$caps")
[[ "$orcarouter_cap" == "0" ]] || fail "orcarouter cap must be 0 (current observed state: HTTP 402 quota_exhausted). Got: $orcarouter_cap"
orcarouter_reason=$(jq -r '.providers.orcarouter.reason // ""' "$caps")
[[ -n "$orcarouter_reason" ]] || fail "orcarouter reason missing — entitled-wired would scream and the canary would re-file"
ok "orcarouter: cap=0 with reason present"

# 2. orcarouter .reason: date + sample size + HTTP code + request id + ledger path
echo "--- scenario 2: orcarouter reason names the measurement trail ---"
grep -qE "$date_pat" <<<"$orcarouter_reason" || fail "orcarouter reason must name a YYYY-MM-DD date"
grep -qE "n=3" <<<"$orcarouter_reason" || fail "orcarouter reason must name n=3 (sample size of the live probe)"
grep -qE "HTTP ?402" <<<"$orcarouter_reason" || fail "orcarouter reason must name HTTP 402 (observed provider signal)"
grep -qE "request ?id" <<<"$orcarouter_reason" || fail "orcarouter reason must name at least one request id"
grep -qE "seats/orcarouter__orcarouter_free.json" <<<"$orcarouter_reason" || fail "orcarouter reason must name the seat-health ledger path"
ok "orcarouter: 2026-08-27, n=3, HTTP 402, request id, ledger path all present"

# 3. orcarouter not in free_providers_in_order
echo "--- scenario 3: orcarouter is not in free_providers_in_order while cap=0 ---"
if jq -e '.free_providers_in_order | index("orcarouter")' "$caps" >/dev/null; then
    fail "orcarouter is in free_providers_in_order but cap=0 — remove it from the order"
fi
ok "orcarouter removed from free_providers_in_order"

# 5. Cross-fleet check: every cap=0 reason across the fleet carries a
#    date (the entitled-wired date contract). The measurement-marker
#    check is enforced in scenario 6 below; this scenario only pins the
#    date-presence invariant as a local pre-push sanity check.
echo "--- scenario 5: every cap=0 reason across the fleet is dated ---"
bad=0
while IFS=$'\t' read -r prov reason; do
    [[ -n "$prov" && -n "$reason" ]] || continue
    if ! grep -qE "$date_pat" <<<"$reason"; then
        echo "  $prov: cap=0 reason missing date" >&2
        bad=$((bad + 1))
        continue
    fi
    ok "$prov: cap=0 reason has a date"
done < <(jq -r '.providers | to_entries[] | select((.value.cap // 0) == 0) | [.key, (.value.reason // "")] | @tsv' "$caps")
[[ "$bad" == "0" ]] || fail "scenario5: $bad cap=0 reason(s) missing date — entitled-wired owns this; copy the test signal into a follow-up issue"

# 6. HARD check: every cap=0 reason carries a measurement marker (probe
#    output, observed provider signal, sample size), either in .reason
#    itself or in a top-level _comment_<prov> field (fleet-ops#878). The
#    cross-fleet audit from #703 exposed inferx (date only, no marker),
#    opencode-anthropic (money-decision, no measurement), and grok (evidence
#    was in _comment_grok, not .reason). This test owns the fix: each
#    cap=0 provider must carry date + marker in .reason OR have a
#    _comment_<prov> top-level field with date + marker.
echo "--- scenario 6: every cap=0 reason has a date + measurement marker ---"
hard_bad=0
while IFS=$'\t' read -r prov reason; do
    [[ -n "$prov" && -n "$reason" ]] || continue
    # Must have a date (enforced by scenario 5 above; re-check for
    # self-containment).
    if ! grep -qE "$date_pat" <<<"$reason"; then
        echo "  $prov: cap=0 reason missing date" >&2
        hard_bad=$((hard_bad + 1))
        continue
    fi
    # Check marker in .reason itself.
    if grep -qiE "$meas_pat" <<<"$reason"; then
        ok "$prov: cap=0 reason has date + measurement marker"
        continue
    fi
    # .reason has no marker — check a top-level _comment_<prov> field.
    comment_field="_comment_${prov}"
    prov_comment=$(jq -r --arg f "$comment_field" '.[$f] // empty' "$caps")
    if [[ -n "$prov_comment" ]] && grep -qE "$date_pat" <<<"$prov_comment" && grep -qiE "$meas_pat" <<<"$prov_comment"; then
        ok "$prov: cap=0 reason cites _comment_${prov} top-level field with date + measurement marker"
        continue
    fi
    echo "  $prov: cap=0 reason has a date but no measurement marker (not in .reason or _comment_${prov})" >&2
    hard_bad=$((hard_bad + 1))
done < <(jq -r '.providers | to_entries[] | select((.value.cap // 0) == 0) | [.key, (.value.reason // "")] | @tsv' "$caps")
[[ "$hard_bad" == "0" ]] || fail "scenario6: $hard_bad cap=0 reason(s) still lack a measurement marker after fleet-ops#878 — sr-never-vibes requires date + marker in .reason or _comment_<prov>"

# 7. Cross-fleet check: every MODEL cap=0 entry has a dated _* reason
#    field on its provider (fleet-ops#1456). #1506 re-audited all 8
#    cap=0 entries and persisted dated reasons in _<sanitised>
#    documentation fields, but scenario 5 only walks provider-level
#    .cap — model-level cap=0 reasons (opencode/deepseek-v4-flash-free,
#    x-preview-f-free, muse-spark-1.2-contributor-free) were unpinned
#    here. The fleet-free-roster canary pins two of the three by exact
#    field name (scenarios 14/17); this scenario enforces the contract
#    for EVERY model cap=0 entry so a future addition or a silent
#    reason-field deletion is caught before push, not on the next
#    auditor re-probe. The reason field naming is _<sanitised-model>
#    with inconsistent version handling (muse-spark-1.2 dropped the
#    "1.2"), so the match is by distinctive token (model split on
#    [-._], tokens of length >= 4, longest first) against _* field
#    names whose value carries a YYYY-MM-DD date.
echo "--- scenario 7: every model cap=0 entry has a dated _* reason field ---"
mbad=0
while IFS=$'\t' read -r prov model; do
    [[ -n "$prov" && -n "$model" ]] || continue
    # Distinctive tokens of the model name, longest first (most
    # distinctive first reduces false matches on generic tokens like
    # "free"). Tokens shorter than 4 chars (v4, 1, 2, f, x) are dropped.
    tokens=$(printf '%s' "$model" \
        | awk -F'[-._]' '{for(i=1;i<=NF;i++) if(length($i)>=4) print length($i)"\t"$i}' \
        | sort -rn | cut -f2)
    # Fallback for short-hyphenated slugs whose every [-._] part is < 4 chars
    # (e.g. swe-1-7 -> swe,1,7 all dropped): use the sanitised full slug
    # ([-._] stripped) as a single token when it is itself >= 4 chars. The
    # sanitised slug is the MOST distinctive token possible, so this does not
    # weaken the contract — it closes the gap for slugs the part-splitter
    # could not tokenise (fleet-ops#2102).
    if [[ -z "$tokens" ]]; then
        slug=$(printf '%s' "$model" | tr -d -- '-._')
        if [[ ${#slug} -ge 4 ]]; then
            tokens="$slug"
        else
            echo "  $prov/$model: no >=4-char token to match a reason field" >&2
            mbad=$((mbad+1)); continue
        fi
    fi
    # Dated _* reason field names on this provider. Reason fields are
    # _<sanitised-model> (NOT _comment_* — those are general provider
    # notes), and must carry a YYYY-MM-DD date.
    dated_fields=$(jq -r --arg p "$prov" '
        .providers[$p] | to_entries[]
        | select(.key|startswith("_"))
        | select(.key|startswith("_comment")|not)
        | select(.value|tostring|test("20[0-9]{2}-[0-9]{2}-[0-9]{2}"))
        | .key
    ' "$caps")
    # A token is "distinctive" iff it matches exactly ONE dated reason
    # field. Generic tokens like "free" match several reason fields and
    # cannot uniquely identify a model's audit trail, so they do NOT
    # satisfy the contract. Require at least one distinctive token.
    found=0
    while IFS= read -r tok; do
        [[ -n "$tok" ]] || continue
        matches=0
        while IFS= read -r fname; do
            [[ -n "$fname" ]] || continue
            case "$fname" in
                *"$tok"*) matches=$((matches+1)) ;;
            esac
        done <<<"$dated_fields"
        (( matches == 1 )) && { found=1; break; }
    done <<<"$tokens"
    if (( found == 0 )); then
        echo "  $prov/$model: cap=0 but no dated _* reason field uniquely identified by a model token (audit trail would be lost on re-edit — fleet-ops#1456)" >&2
        mbad=$((mbad+1))
    else
        ok "$prov/$model: model cap=0 has a dated _* reason field"
    fi
done < <(jq -r '
    .providers | to_entries[] | .key as $p
    | (.value.models // {}) | to_entries[]
    | select(.value == 0) | [$p, .key] | @tsv
' "$caps")
[[ "$mbad" == "0" ]] || fail "scenario7: $mbad model cap=0 entry(ies) missing a dated _* reason field — audit durability gap (fleet-ops#1456)"

ok "seat-caps-citation: orcarouter citation pinned, order clean, JSON parses, cap=0 reasons across the fleet are dated + measured, model cap=0 reasons pinned"

# 8. OpenRouter paid flash lane (fleet-ops#384): the cheapest+best of
#    Qwen 3.8 flash / GLM 5.3 flash / DeepSeek V4 flash is wired as a
#    metered model row with a dated, measured citation. Pins the lane so a
#    future revert (dropping the models map back to empty) is caught before
#    push, not on the next heartbeat tick. The #384 canary header claims the
#    lane is wired; this test is the local proof that the config actually
#    carries the row (the prior 2026-08-26 attempt wrote the canary claim but
#    never landed the seat-caps models map — fleet-ops#436).
echo "--- scenario 8: OpenRouter paid flash lane wired with dated measured citation ---"
or_models=$(jq -r '.providers.openrouter.models | length' "$caps")
[[ "$or_models" -ge 1 ]] || fail "openrouter must have a non-empty models map (the #384 paid flash lane). Got: $or_models"
or_dsv4f=$(jq -r '.providers.openrouter.models["deepseek/deepseek-v4-flash-0731"] // empty' "$caps")
[[ -n "$or_dsv4f" ]] || fail "openrouter must allowlist deepseek/deepseek-v4-flash-0731 (the #384 cheapest+best paid flash lane)"
[[ "$or_dsv4f" != "0" ]] || fail "openrouter deepseek/deepseek-v4-flash-0731 cap must be >0 (wired, not parked)"
or_class=$(jq -r '.providers.openrouter.class // empty' "$caps")
[[ "$or_class" == "metered" ]] || fail "openrouter class must be metered (paid lane — spend after free+prepaid). Got: $or_class"
or_cite=$(jq -r '.providers.openrouter._comment_384 // ""' "$caps")
[[ -n "$or_cite" ]] || fail "openrouter must carry a _comment_384 citation for the paid flash lane"
grep -qE "$date_pat" <<<"$or_cite" || fail "openrouter _comment_384 must name a YYYY-MM-DD date"
# measurement marker: a live price figure ($0.x) and a pi --list-models / catalog probe reference
grep -qE '\$0\.[0-9]' <<<"$or_cite" || fail "openrouter _comment_384 must name a live price figure (\$0.x/M)"
grep -qiE 'pi --list-models|/models|catalog' <<<"$or_cite" || fail "openrouter _comment_384 must name the probe source (pi --list-models or /models catalog)"
# cheapest+best evidence: the citation must name DeepSeek V4 flash as cheapest vs the two alternatives
grep -qiE 'cheapest' <<<"$or_cite" || fail "openrouter _comment_384 must state cheapest+best verdict"
ok "openrouter: deepseek/deepseek-v4-flash-0731 wired (metered, cap=$or_dsv4f) with dated measured _comment_384 citation"

# 8. fable-check 2026-09-05: zero-yield seats retired (fleet-ops#3389 for the
#    laguna incident). Both seats ran n=20 sessions with pr_count=0 in
#    seat-yield.json and died 57 times in the 3h window; cap=0 stale so the
#    14d TTL re-audition (fleet-ops#3111) re-probes them with a real packet.
# 2026-09-05 correction (orchestrator, Nish): devin/swe-1-7 is NOT retired. Its
# n=20 / pr_count=0 was infrastructure: every run died at 1801s to the
# devin-provider 30-min timeout and to resource_exhausted collisions the
# detectors could not see (fixed 09-05, #3443/#3475). Measured before that:
# 80% sessions-to-PR. Infra deaths never count as seat yield (#3310); the
# AIMD suite pins swe-1-7 at cap 4 / probe 8. Only laguna stays retired here.
echo "--- scenario 8: laguna is cap=0 stale with a dated n=20 yield-0 reason ---"
for pm in "commandcode|poolside/laguna-s-2.1-free|_laguna_20260905"; do
    IFS='|' read -r prov model field <<<"$pm"
    mcap=$(jq -r --arg p "$prov" --arg m "$model" '.providers[$p].models[$m] | if type=="object" then (.cap // 0) else . end' "$caps")
    [[ "$mcap" == "0" ]] || fail "$prov/$model cap must be 0 (n=20 sessions, pr_count=0 in seat-yield.json on 2026-09-05). Got: $mcap"
    micz=$(jq -r --arg p "$prov" --arg m "$model" '.providers[$p].models[$m] | if type=="object" then (.intentional_cap_zero // "") else "" end' "$caps")
    [[ "$micz" == "stale" ]] || fail "$prov/$model intentional_cap_zero must be 'stale' (14d TTL re-audition). Got: '$micz'"
    mreason=$(jq -r --arg p "$prov" --arg f "$field" '.providers[$p][$f] // ""' "$caps")
    grep -qE "$date_pat" <<<"$mreason" || fail "$prov.$field must carry a YYYY-MM-DD date"
    grep -qE 'n=20' <<<"$mreason" || fail "$prov.$field must name the sample size n=20"
    grep -qE 'yield=0\.0' <<<"$mreason" || fail "$prov.$field must name yield=0.0"
    ok "$prov/$model: cap=0 stale with dated n=20 yield=0.0 reason in $field"
done
