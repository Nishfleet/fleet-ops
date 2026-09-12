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
#      it so the seat stays out of pick-seat's look-ahead).
#   4. The seat-caps JSON parses cleanly. A future edit that breaks
#      JSON would break pick-seat globally, so the parse is the cheap
#      local smoke before the canary's wider sweep.
#   5. The fleet-wide cap=0 reasons ALL carry a dated measurement
#      marker (the cross-provider invariant entitled-wired owns for
#      dates; this test owns the measurement marker on top of the date
#      so a vibes line in a cap=0 reason is also caught here, before
#      push).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
# SEAT_CAPS_JSON override (the repo-wide convention, lib/litellm-seat.sh:71) lets a
# replay drill point this test at a fixture reproducing a past bad hunk
# (fleet-ops#3864: the #3848 ollama cap=0 corpse retirement). Default is the
# live config.
caps="${SEAT_CAPS_JSON:-$repo_root/config/seat-caps.json}"

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
meas_pat='(n=[0-9]+|p95|p99|HTTP ?[1-5][0-9][0-9]|request ?id|observed_at|usable_at|quota_exhausted|free_quota_exhausted|credentials_bad|ETIMEDOUT|rate.?limit|timeout|spawnSync|spawn|returned|PONG|404|403|429|402|500|503|\$[0-9]|meter|cost=null|sessions?|yield|pr_count|pass@1|error.?class|insufficient.?credit|resource_exhausted|budget|requests|used|spend|concurrency|tolerance|probe)'

# 1. orcarouter: cap=0 + intentional_cap_zero + reason present (rule 3)
echo "--- scenario 1: orcarouter cap=0 intentional with non-empty reason ---"
orcarouter_cap=$(jq -r '.providers.orcarouter.cap // empty' "$caps")
[[ "$orcarouter_cap" == "0" ]] || fail "orcarouter cap is not zero (rule 3 precondition). Got: $orcarouter_cap"
orcarouter_icz=$(jq -r '.providers.orcarouter.intentional_cap_zero // empty' "$caps")
[[ -n "$orcarouter_icz" ]] || fail "orcarouter intentional_cap_zero missing (rule 3, fleet-ops#3504)"
orcarouter_reason=$(jq -r '.providers.orcarouter.reason // ""' "$caps")
[[ -n "$orcarouter_reason" ]] || fail "orcarouter reason missing — entitled-wired would scream and the canary would re-file"
ok "orcarouter: cap=0 intentional with reason present"

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

# 7. Cross-fleet check: every MODEL cap=0 entry has a dated reason and
#    intentional_cap_zero (rule 3, fleet-ops#3504). Model cap=0 entries
#    may be scalar (0) or object ({cap:0, intentional_cap_zero, reason}).
#    Object entries carry their own reason; scalar entries fall back to a
#    dated _* field on the provider (the historical convention).
echo "--- scenario 7: every model cap=0 entry is intentional with a dated reason ---"
mbad=0
while IFS=$'\t' read -r prov model mtype; do
    [[ -n "$prov" && -n "$model" ]] || continue
    if [[ "$mtype" == "object" ]]; then
        # Object entry: check intentional_cap_zero + dated reason on the object
        micz=$(jq -r --arg p "$prov" --arg m "$model" '.providers[$p].models[$m].intentional_cap_zero // empty' "$caps")
        [[ -n "$micz" ]] || { echo "  $prov/$model: cap=0 object missing intentional_cap_zero (rule 3)" >&2; mbad=$((mbad+1)); continue; }
        mreason=$(jq -r --arg p "$prov" --arg m "$model" '.providers[$p].models[$m].reason // empty' "$caps")
        if [[ -n "$mreason" ]] && grep -qE "$date_pat" <<<"$mreason" && grep -qiE "$meas_pat" <<<"$mreason"; then
            ok "$prov/$model: cap=0 object with intentional_cap_zero + dated reason"
            continue
        fi
        # Fall back to dated _* field on the provider
        dated_fields=$(jq -r --arg p "$prov" '.providers[$p] | to_entries[] | select(.key|startswith("_")) | select(.key|startswith("_comment")|not) | select(.value|tostring|test("20[0-9]{2}-[0-9]{2}-[0-9]{2}")) | .key' "$caps")
        if [[ -n "$dated_fields" ]]; then
            ok "$prov/$model: cap=0 object with intentional_cap_zero, dated _* field on provider"
            continue
        fi
        echo "  $prov/$model: cap=0 object missing dated reason (rule 3)" >&2
        mbad=$((mbad+1))
    else
        # Scalar entry (0): check for a dated _* reason field on the provider
        tokens=$(printf '%s' "$model" \
            | awk -F'[-._]' '{for(i=1;i<=NF;i++) if(length($i)>=4) print length($i)"\t"$i}' \
            | sort -rn | cut -f2)
        if [[ -z "$tokens" ]]; then
            slug=$(printf '%s' "$model" | tr -d -- '-._')
            if [[ ${#slug} -ge 4 ]]; then
                tokens="$slug"
            else
                echo "  $prov/$model: no >=4-char token to match a reason field" >&2
                mbad=$((mbad+1)); continue
            fi
        fi
        dated_fields=$(jq -r --arg p "$prov" '
            .providers[$p] | to_entries[]
            | select(.key|startswith("_"))
            | select(.key|startswith("_comment")|not)
            | select(.value|tostring|test("20[0-9]{2}-[0-9]{2}-[0-9]{2}"))
            | .key
        ' "$caps")
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
            echo "  $prov/$model: cap=0 scalar but no dated _* reason field uniquely identified (fleet-ops#1456)" >&2
            mbad=$((mbad+1))
        else
            ok "$prov/$model: cap=0 scalar with dated _* reason field"
        fi
    fi
done < <(jq -r '
    .providers | to_entries[] | .key as $p
    | (.value.models // {}) | to_entries[]
    | .value as $v | .key as $m
    | ($v | if type == "object" then (.cap // 1) else . end) as $cap
    | select($cap == 0)
    | [$p, $m, ($v | type)] | @tsv
' "$caps")
[[ "$mbad" == "0" ]] || fail "scenario7: $mbad model cap=0 entry(ies) missing intentional_cap_zero or a dated reason (rule 3, fleet-ops#3504)"

ok "seat-caps-citation: orcarouter citation pinned, order clean, JSON parses, cap=0 reasons across the fleet are dated + measured, model cap=0 entries intentional with dated reasons"

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
or_dsv4f=$(jq -r '.providers.openrouter.models["deepseek/deepseek-v4.1-flash"] | if type=="object" then (.cap // "none") else . end' "$caps")
[[ -n "$or_dsv4f" && "$or_dsv4f" != "null" ]] \
  || fail "openrouter must allowlist deepseek/deepseek-v4.1-flash (the #384 cheapest+best paid flash lane)"
# Rule 1 (fleet-ops#3504): the cap value is justified by a dated reason, not
# pinned by the test. The lane is wired (entry present); the cap may be 0
# (balance exhausted) with a dated reason citing the error class.
or_dsv4f_reason=$(jq -r '.providers.openrouter.models["deepseek/deepseek-v4.1-flash"] | if type=="object" then (.reason // "") else "" end' "$caps")
if [[ -n "$or_dsv4f_reason" ]]; then
    grep -qE "$date_pat" <<<"$or_dsv4f_reason" \
      || fail "openrouter deepseek/deepseek-v4.1-flash reason must name a YYYY-MM-DD date (rule 1)"
    grep -qiE "$meas_pat" <<<"$or_dsv4f_reason" \
      || fail "openrouter deepseek/deepseek-v4.1-flash reason must name a measurement (rule 1)"
fi
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
ok "openrouter: deepseek/deepseek-v4.1-flash wired (metered) with dated measured _comment_384 citation (rule 1, fleet-ops#3504)"

# 9. Rule 4 (fleet-ops#3504): infrastructure death classes are NOT accepted
#    as yield reasons for cap=0. If a cap=0 reason cites "yield" as a
#    measurement, the reason must NOT cite infra death classes (rc=124,
#    rc=143, provider timeout, resource_exhausted, 429, 503) as the cause
#    of the zero yield. The swe-1-7 correction (#3473) and the laguna
#    correction (this PR) are the precedents: infra deaths never count as
#    yield (#3250/#3310).
echo "--- scenario 9: infra death classes not accepted as yield reasons (rule 4) ---"
infra_pat='(rc=124|rc=143|provider timeout|resource_exhausted|HTTP ?429|HTTP ?503|overload_bench)'
rule4_bad=0
while IFS=$'\t' read -r prov entry_filter reason; do
    [[ -n "$prov" && -n "$reason" ]] || continue
    # Only check reasons that cite "yield" as a measurement
    if ! grep -qiE 'yield|pr_count' <<<"$reason"; then
        continue
    fi
    # The reason cites yield — check it does NOT cite infra death classes
    if grep -qiE "$infra_pat" <<<"$reason"; then
        echo "  $prov: cap=0 reason cites yield AND an infra death class — infra deaths never count as yield (rule 4, #3250/#3310)" >&2
        rule4_bad=$((rule4_bad+1))
    fi
done < <(jq -r '
    .providers | to_entries[] | .key as $p
    | (.value.cap // 1) as $pcap
    | (select($pcap == 0) | [$p, ".providers[\($p)]", (.value.reason // "")])
    , (.value.models // {}) | to_entries[] | .value as $v | .key as $m
    | ($v | if type == "object" then (.cap // 1) else . end) as $mc
    | select($mc == 0) | [$p, ".providers[\($p)].models[\($m)]", ($v | if type == "object" then (.reason // "") else "" end)]
' "$caps" 2>/dev/null)
[[ "$rule4_bad" == "0" ]] || fail "scenario9: $rule4_bad cap=0 reason(s) cite infra death classes as yield — infra deaths never count as yield (rule 4, fleet-ops#3504)"
ok "no cap=0 entry cites infra death classes as yield reasons (rule 4, fleet-ops#3504)"

# 10. Rule 1 (fleet-ops#3504): every provider cap entry carries a dated
#     reason with a measurement (sessions, yield, price, or error class).
#     A cap change with a valid dated reason passes; without a reason it
#     fails here without a test edit.
echo "--- scenario 10: every provider cap carries a dated reason (rule 1) ---"
r1_bad=0
while IFS=$'\t' read -r prov reason; do
    [[ -n "$prov" ]] || continue
    has_date=0
    has_meas=0
    # Check .reason on the provider
    if [[ -n "$reason" ]] && grep -qE "$date_pat" <<<"$reason" && grep -qiE "$meas_pat" <<<"$reason"; then
        has_date=1; has_meas=1
    fi
    # Fall back to any dated _ field on the provider with a measurement
    if (( has_date == 0 )); then
        dated_field=$(jq -r --arg p "$prov" 'first(.providers[$p] | to_entries[] | select(.key|startswith("_")) | select(.value|tostring|test("20[0-9]{2}-[0-9]{2}-[0-9]{2}")) | .value|tostring)' "$caps" 2>/dev/null || true)
        if [[ -n "$dated_field" ]] && grep -qiE "$meas_pat" <<<"$dated_field"; then
            has_date=1; has_meas=1
        fi
    fi
    if (( has_date == 0 )); then
        echo "  $prov: cap entry missing a dated reason (rule 1)" >&2
        r1_bad=$((r1_bad+1))
    elif (( has_meas == 0 )); then
        echo "  $prov: cap entry reason has a date but no measurement marker (rule 1)" >&2
        r1_bad=$((r1_bad+1))
    else
        ok "$prov: cap carries a dated reason with a measurement (rule 1)"
    fi
done < <(jq -r '.providers | to_entries[] | [.key, (.value.reason // "")] | @tsv' "$caps")
[[ "$r1_bad" == "0" ]] || fail "scenario10: $r1_bad provider cap(s) missing a dated reason with a measurement (rule 1, fleet-ops#3504)"

# 11. Rule 5 (fleet-ops#3504): provider class is one of free, prepaid-quota,
#     metered (subscription is accepted as an alias for prepaid-quota).
echo "--- scenario 11: provider class is free, prepaid-quota, or metered (rule 5) ---"
r5_bad=0
while IFS=$'\t' read -r prov pclass; do
    [[ -n "$prov" ]] || continue
    case "$pclass" in
        free|prepaid-quota|metered|subscription) ;;
        *) echo "  $prov: class '$pclass' is not free, prepaid-quota, or metered (rule 5)" >&2; r5_bad=$((r5_bad+1)) ;;
    esac
done < <(jq -r '.providers | to_entries[] | [.key, (.value.class // "free")] | @tsv' "$caps")
[[ "$r5_bad" == "0" ]] || fail "scenario11: $r5_bad provider(s) with an invalid class (rule 5, fleet-ops#3504)"
ok "all provider classes are free, prepaid-quota, or metered (rule 5, fleet-ops#3504)"

# 12. Rule 6 (fleet-ops#3864): a cap=0 entry retired for yield
#     (intentional_cap_zero in {corpse, yield, stale-yield}) on a prepaid-quota
#     or metered provider must cite the seat-retirement rule's three pieces of
#     evidence (2026-09-05, after #3389/#3473): the retirement error class
#     (model-working / tools>0 — the model was working, never an infrastructure
#     death class like rc=124, rc=143, 429, 503, resource_exhausted,
#     no-seat-available), a session count of at least 20, and a PR rate under
#     10% (or pr_count 0). A worker cannot land what #3848 landed
#     (the retired ollama V4 flash seat retired at measured yield 0.30 with only
#     rc=124 hang-watchdog infra deaths; reverted by orchestrator PR #3863).
#     The three config-pinning suites all passed on #3848 because the citation
#     rules checked for a dated reason, not the retirement rule's evidence —
#     this scenario closes that gap. Free-class providers are out of scope: a
#     free lane has no spend to protect, so the retirement rule's evidence
#     threshold does not apply.
echo "--- scenario 12: cap=0 yield retirement on a paid provider cites the retirement rule (rule 6) ---"
r6_errclass_pat='(model-working|tools[[:space:]]*>[[:space:]]*0)'
r6_infra_pat='(rc=124|rc=143|HTTP[[:space:]]?429|HTTP[[:space:]]?503|resource_exhausted|no-seat-available)'
# session count >= 20: n=20, n=25, n=120, "20 sessions", "sessions 20", "sessions=20"
r6_session_pat='(n=[2-9][0-9]|n=[1-9][0-9]{2,}|[2-9][0-9][[:space:]]*sessions?|sessions?[[:space:]]*[=: ]?[[:space:]]*[2-9][0-9]|[1-9][0-9]{2,}[[:space:]]*sessions?)'
# PR rate under 10% or pr_count 0: "pr_count 0", "pr_count=0", "<10%", "under 10%",
# "yield 0.05" (<0.10), "yield 0" (exactly 0). "yield 0.30" and "pr_count 6" do NOT match.
r6_prrate_pat='(pr_count[[:space:]]*[=: ]?[[:space:]]*0([^0-9.]|$)|<[[:space:]]*10%|under[[:space:]]+10%|PR[[:space:]]+rate[[:space:]]+<[[:space:]]*10%|yield[[:space:]]*0\.0[0-9]|yield[[:space:]]*0([^0-9.]|$))'
r6_bad=0
r6_checked=0
# Provider-level cap=0 entries on a paid provider.
while IFS=$'\t' read -r prov pclass reason; do
    [[ -n "$prov" ]] || continue
    [[ "$pclass" == "prepaid-quota" || "$pclass" == "metered" ]] || continue
    r6_checked=$((r6_checked+1))
    if [[ -z "$reason" ]]; then
        echo "  $prov: cap=0 yield-class retirement on $pclass provider but reason is empty (rule 6)" >&2
        r6_bad=$((r6_bad+1)); continue
    fi
    if ! grep -qiE "$r6_errclass_pat" <<<"$reason"; then
        echo "  $prov: cap=0 yield retirement on $pclass provider — reason must cite the retirement error class (model-working / tools>0), not just a date (rule 6, fleet-ops#3864)" >&2
        r6_bad=$((r6_bad+1)); continue
    fi
    if grep -qiE "$r6_infra_pat" <<<"$reason"; then
        echo "  $prov: cap=0 yield retirement on $pclass provider — reason cites an infra death class (rc=124/143, 429, 503, resource_exhausted, no-seat-available); infra deaths never count as yield (rule 6, fleet-ops#3864)" >&2
        r6_bad=$((r6_bad+1)); continue
    fi
    if ! grep -qiE "$r6_session_pat" <<<"$reason"; then
        echo "  $prov: cap=0 yield retirement on $pclass provider — reason must cite a session count of at least 20 (rule 6, fleet-ops#3864)" >&2
        r6_bad=$((r6_bad+1)); continue
    fi
    if ! grep -qiE "$r6_prrate_pat" <<<"$reason"; then
        echo "  $prov: cap=0 yield retirement on $pclass provider — reason must cite a PR rate under 10% or pr_count 0 (rule 6, fleet-ops#3864)" >&2
        r6_bad=$((r6_bad+1)); continue
    fi
    ok "$prov: cap=0 yield retirement on $pclass provider cites error class + >=20 sessions + PR rate <10% (rule 6)"
done < <(jq -r '
    .providers | to_entries[] | .key as $p
    | (.value.cap // 1) as $cap
    | select($cap == 0)
    | (.value.intentional_cap_zero // "") as $icz
    | select($icz | IN("corpse","yield","stale-yield"))
    | (.value.class // "free") as $cls
    | [$p, $cls, (.value.reason // "")] | @tsv
' "$caps")
# Model-level cap=0 entries on a paid provider. fleet-ops#4271: a model with
# a class:free override on a metered/prepaid provider is a FREE seat (costs
# nothing — the cline/z-ai/glm-5.3-flash, openrouter :free, zenmux/z-ai/
# glm-4.7-flash-free precedent). The retirement rule's evidence threshold
# protects spend, so it does not apply to a free model; the jq below skips
# model entries whose own class is "free" (same as a free-class provider).
while IFS=$'\t' read -r prov model pclass reason; do
    [[ -n "$prov" ]] || continue
    [[ "$pclass" == "prepaid-quota" || "$pclass" == "metered" ]] || continue
    r6_checked=$((r6_checked+1))
    if [[ -z "$reason" ]]; then
        echo "  $prov/$model: cap=0 yield-class retirement on $pclass provider but reason is empty (rule 6)" >&2
        r6_bad=$((r6_bad+1)); continue
    fi
    if ! grep -qiE "$r6_errclass_pat" <<<"$reason"; then
        echo "  $prov/$model: cap=0 yield retirement on $pclass provider — reason must cite the retirement error class (model-working / tools>0), not just a date (rule 6, fleet-ops#3864)" >&2
        r6_bad=$((r6_bad+1)); continue
    fi
    if grep -qiE "$r6_infra_pat" <<<"$reason"; then
        echo "  $prov/$model: cap=0 yield retirement on $pclass provider — reason cites an infra death class (rc=124/143, 429, 503, resource_exhausted, no-seat-available); infra deaths never count as yield (rule 6, fleet-ops#3864)" >&2
        r6_bad=$((r6_bad+1)); continue
    fi
    if ! grep -qiE "$r6_session_pat" <<<"$reason"; then
        echo "  $prov/$model: cap=0 yield retirement on $pclass provider — reason must cite a session count of at least 20 (rule 6, fleet-ops#3864)" >&2
        r6_bad=$((r6_bad+1)); continue
    fi
    if ! grep -qiE "$r6_prrate_pat" <<<"$reason"; then
        echo "  $prov/$model: cap=0 yield retirement on $pclass provider — reason must cite a PR rate under 10% or pr_count 0 (rule 6, fleet-ops#3864)" >&2
        r6_bad=$((r6_bad+1)); continue
    fi
    ok "$prov/$model: cap=0 yield retirement on $pclass provider cites error class + >=20 sessions + PR rate <10% (rule 6)"
done < <(jq -r '
    .providers | to_entries[] | .key as $p
    | (.value.class // "free") as $cls
    | (.value.models // {}) | to_entries[] | .value as $v | .key as $m
    | ($v | if type == "object" then (.cap // 1) else . end) as $mc
    | select($mc == 0)
    | ($v | if type == "object" then (.intentional_cap_zero // "") else "" end) as $icz
    | select($icz | IN("corpse","yield","stale-yield"))
    | select($cls | IN("prepaid-quota","metered"))
    | select(($v | if type == "object" then (.class // "") else "" end) != "free")
    | [$p, $m, $cls, ($v | if type == "object" then (.reason // "") else "" end)] | @tsv
' "$caps")
if (( r6_bad > 0 )); then
    fail "scenario12: $r6_bad cap=0 yield retirement(s) on a paid provider missing the retirement rule's evidence (rule 6, fleet-ops#3864)"
fi
if (( r6_checked == 0 )); then
    ok "no cap=0 yield-class retirement on a paid provider — rule 6 vacuously satisfied (fleet-ops#3864)"
else
    ok "every cap=0 yield-class retirement on a paid provider cites the retirement rule's evidence (rule 6, fleet-ops#3864)"
fi

ok "seat-caps-citation: rules 1-6 enforced, orcarouter citation pinned, order clean, JSON parses (fleet-ops#3504, fleet-ops#3864)"

# 13. fleet-ops#3930: worker_memory shape + citation. The pressure-kill fault
#     was caused by the MemoryHigh throttle band: oomd turned one worker's
#     thrash into a kill of a random sibling (6 pi-issue@* kills in 1h on a
#     15 GB box; pi-issue@0509-1752 killed at a 94.3M peak — victim was not
#     the offender). The fix drops MemoryHigh for fleet-ops + 0509 and keeps
#     MemoryMax=4G. Pin the shape AND the citation (the _comment_worker_memory
#     field carries a dated reason with measurement markers — sr-never-vibes,
#     rule 1) so a revert is caught here, not on the next oomd kill burst.
echo "--- scenario 13: worker_memory shape + citation (fleet-ops#3930) ---"
fo_max=$(jq -r '.worker_memory["fleet-ops"].MemoryMax // empty' "$caps")
fo_high=$(jq -r '.worker_memory["fleet-ops"].MemoryHigh // empty' "$caps")
o5_max=$(jq -r '.worker_memory["0509"].MemoryMax // empty' "$caps")
o5_high=$(jq -r '.worker_memory["0509"].MemoryHigh // empty' "$caps")
[[ "$fo_max" == "4G" ]] || fail "scenario13: fleet-ops worker_memory MemoryMax must be 4G (fleet-ops#3930), got '$fo_max'"
[[ -z "$fo_high" ]] || fail "scenario13: fleet-ops worker_memory MemoryHigh must be ABSENT (fleet-ops#3930 dropped the throttle band so oomd has no throttle-to-kill path), got '$fo_high'"
[[ "$o5_max" == "4G" ]] || fail "scenario13: 0509 worker_memory MemoryMax must be 4G (fleet-ops#3930), got '$o5_max'"
[[ -z "$o5_high" ]] || fail "scenario13: 0509 worker_memory MemoryHigh must be ABSENT (fleet-ops#3930 dropped the throttle band), got '$o5_high'"
hvy_max=$(jq -r '.worker_memory.heavy.MemoryMax // empty' "$caps")
hvy_high=$(jq -r '.worker_memory.heavy.MemoryHigh // empty' "$caps")
[[ "$hvy_max" == "3G" && "$hvy_high" == "2G" ]] \
  || fail "scenario13: heavy worker_memory must stay 3G/2G (manager workers, fleet-ops#3281; not part of fleet-ops#3930), got max='$hvy_max' high='$hvy_high'"
# Citation (rule 1): the _comment_worker_memory field (or the worker_memory
# _note) must carry a date + a measurement marker naming the oomd kill
# evidence (kill count, peak, or pressure) so the shape is grounded in the
# live fault, not a vibes number.
wm_cite=$(jq -r '.worker_memory._comment // .worker_memory._note // ""' "$caps")
[[ -n "$wm_cite" ]] || fail "scenario13: worker_memory must carry a _comment or _note citation (fleet-ops#3930)"
grep -qE "$date_pat" <<<"$wm_cite" \
  || fail "scenario13: worker_memory citation must name a YYYY-MM-DD date (rule 1, fleet-ops#3930)"
grep -qiE '(oomd|kill|pressure|MemoryHigh|throttle|94\.3M|peak|sibling)' <<<"$wm_cite" \
  || fail "scenario13: worker_memory citation must name the oomd pressure-kill evidence (rule 1, fleet-ops#3930)"
ok "scenario13: worker_memory fleet-ops + 0509 MemoryMax=4G no MemoryHigh, heavy 3G/2G, citation dated + measured (fleet-ops#3930)"

# 14. fleet-ops#4425: providers.litellm block shape + provenance marker.
#     The orchestrator-relabelled scope for the led-2026-09-08-litellm-p3b
#     rule-coverage ticket (#4425) is "land a litellm provider block in
#     config/seat-caps.json, pinned by the config-pinning suites like every
#     other provider" (judge fable-5.1-xhigh 2026-09-08; #4458 MERGED).
#     This pins the block against future reverts so a worker who deletes it
#     (intentionally or accidentally) fails locally before push, not on the
#     next heartbeat tick. P3b (#4422 / programme #4263) flips parked caps
#     to operational ones at the litellm cutover, and that flip relies on
#     the block being present and shaped correctly on disk.
echo "--- scenario 14: providers.litellm P3b prereq shape + marker (fleet-ops#4425) ---"
lit_prov=$(jq -r '.providers.litellm // empty' "$caps")
[[ -n "$lit_prov" ]] || fail "scenario14: providers.litellm block missing — fleet-ops#4425 orchestrator scope (PR #4458); #4422 P3b cutover requires this block"
lit_cap=$(jq -r '.providers.litellm.cap // empty' "$caps")
[[ "$lit_cap" == "0" ]] || fail "scenario14: providers.litellm.cap must be 0 (parked until #4422 P3b enables PI_SEAT_SOURCE=litellm). Got: '$lit_cap'"
lit_class=$(jq -r '.providers.litellm.class // empty' "$caps")
[[ -n "$lit_class" ]] || fail "scenario14: providers.litellm.class must be set (rule 5, fleet-ops#3504)"
lit_icz=$(jq -r '.providers.litellm.intentional_cap_zero // empty' "$caps")
[[ "$lit_icz" == "p3b_pending" ]] || fail "scenario14: providers.litellm.intentional_cap_zero must be 'p3b_pending' (fleet-ops#4425 orchestrator scope). Got: '$lit_icz'"
lit_reason=$(jq -r '.providers.litellm.reason // ""' "$caps")
[[ -n "$lit_reason" ]] || fail "scenario14: providers.litellm.reason must be a non-empty dated reason (rule 1, fleet-ops#3504)"
grep -qE "$date_pat" <<<"$lit_reason" || fail "scenario14: providers.litellm.reason must name a YYYY-MM-DD date (rule 1)"
grep -qiE "$meas_pat" <<<"$lit_reason" || fail "scenario14: providers.litellm.reason must name a measurement (probe output, seats=0, etc., rule 1)"
# Top-level provenance marker — the convention other parked-cap providers
# use (e.g. _comment_<key> on openrouter, _note/<date_field> on others).
# The litellm block uses _litellm_p3b_<YYYY-MM-DD>. A future rename must
# keep the date suffix so this test can match it; PR #4458 ships the field.
lit_marker_keys=$(jq -r '.providers.litellm | keys[] | select(test("^_litellm_p3b_"))' "$caps" 2>/dev/null || true)
[[ -n "$lit_marker_keys" ]] || fail "scenario14: providers.litellm must carry a _litellm_p3b_<YYYY-MM-DD> top-level provenance marker (fleet-ops#4425 / #4458); no marker key found"
lit_marker=$(jq -r '.providers.litellm | to_entries[] | select(.key|test("^_litellm_p3b_")) | .value' "$caps" | head -1)
grep -qE "$date_pat" <<<"$lit_marker" || fail "scenario14: _litellm_p3b_<date> marker must name a YYYY-MM-DD date (rule 1)"
grep -qiE "$meas_pat" <<<"$lit_marker" || fail "scenario14: _litellm_p3b_<date> marker must name a measurement (rule 1)"
ok "scenario14: providers.litellm parked shape (cap=0, class=$lit_class, intentional_cap_zero=p3b_pending, dated+measured reason) + _litellm_p3b_<date> marker"
# Five model groups mirror config/pi-models.json providers.litellm.models.
# Hardcoded list keeps this test local — if pi-models.json litellm gains or
# renames a group, update both this list AND config/pi-models.json in the
# same commit (and the matrix-row proof in config/rule-enforcement.json).
lit_groups=(judge worker-cheap worker-capable senior worker-private)
bad_group=0
for grp in "${lit_groups[@]}"; do
    gval=$(jq -r --arg g "$grp" '.providers.litellm.models[$g] // empty' "$caps" 2>/dev/null)
    if [[ -z "$gval" ]]; then
        echo "  litellm/$grp: missing model group (must mirror config/pi-models.json providers.litellm.models keys)" >&2
        bad_group=$((bad_group+1)); continue
    fi
    gcap=$(jq -r --arg g "$grp" '.providers.litellm.models[$g].cap // empty' "$caps")
    gicz=$(jq -r --arg g "$grp" '.providers.litellm.models[$g].intentional_cap_zero // empty' "$caps")
    greason=$(jq -r --arg g "$grp" '.providers.litellm.models[$g].reason // ""' "$caps")
    if [[ "$gcap" != "0" || "$gicz" != "p3b_pending" || -z "$greason" ]]; then
        echo "  litellm/$grp: cap=$gcap intentional_cap_zero='$gicz' reason_empty=$([[ -z "$greason" ]] && echo yes || echo no) — must be cap=0, intentional_cap_zero=p3b_pending, with a non-empty dated reason (fleet-ops#4425)" >&2
        bad_group=$((bad_group+1)); continue
    fi
    if ! grep -qE "$date_pat" <<<"$greason"; then
        echo "  litellm/$grp: reason missing YYYY-MM-DD date (rule 1, fleet-ops#3504)" >&2
        bad_group=$((bad_group+1)); continue
    fi
    if ! grep -qiE "$meas_pat" <<<"$greason"; then
        echo "  litellm/$grp: reason missing measurement marker (rule 1, fleet-ops#3504)" >&2
        bad_group=$((bad_group+1)); continue
    fi
    ok "litellm/$grp: cap=0 intentional_cap_zero=p3b_pending dated+measured reason"
done
[[ "$bad_group" == "0" ]] || fail "scenario14: $bad_group litellm model group(s) fail shape or citation (rules 1 + 3, fleet-ops#3504); see messages above"
ok "scenario14: providers.litellm parked shape + _litellm_p3b_<date> marker + all five model groups cap=0 intentional_cap_zero=p3b_pending dated+measured (fleet-ops#4425, PR #4458, programme #4263)"
