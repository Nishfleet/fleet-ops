#!/usr/bin/env bash
# tests/seat-inventory-drift.test.sh
#
# fleet-ops#217: fail-loud seat-inventory canary.
#
# Invariants:
#   1. Every provider in the live models.json has a row in config/seat-caps.json
#      (models.json is a subset of the cap map).
#   2. Every provider in config/seat-caps.json with cap=0 carries a non-empty,
#      dated reason (YYYY-MM-DD). A cap=0 seat without a dated reason is a
#      forgotten seat and must fail loud.
#   3. Metered providers never have a max_probe_ceiling above their declared
#      cap (money-adjacent seats do not probe above declared unless a ledger
#      line explicitly overrides).
#
# The models.json check is live-config only: on CI the file may not be present,
# in which case the subset invariant is skipped with a message. The cap-map
# shape invariants always run.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
caps="$repo_root/config/seat-caps.json"
models="${PI_MODELS_JSON:-$HOME/.pi/agent/models.json}"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$caps" ]] || fail "seat-caps.json not found: $caps"
jq -e . "$caps" >/dev/null || fail "seat-caps.json is not valid JSON: $caps"

# --- invariant 1: models.json providers are a subset of the cap map ----------
if [[ -f "$models" ]]; then
    jq -e . "$models" >/dev/null || fail "models.json is not valid JSON: $models"
    missing=""
    while IFS= read -r p; do
        if ! jq -e --arg p "$p" '.providers | has($p)' "$caps" >/dev/null; then
            missing="${missing}${missing:+, }$p"
        fi
    done < <(jq -r '.providers | keys[]' "$models")
    [[ -z "$missing" ]] || fail "models.json providers not in seat-caps.json: $missing"
    ok_subset="OK: every models.json provider has a seat-caps.json row"
else
    ok_subset="SKIP: models.json not present ($models); subset check skipped"
fi

# --- invariant 2: cap=0 rows carry a non-empty, dated reason -----------------
cap0_missing=""
cap0_undated=""
while IFS= read -r p; do
    reason="$(jq -r --arg p "$p" '.providers[$p].reason // ""' "$caps")"
    if [[ -z "$reason" ]]; then
        cap0_missing="${cap0_missing}${cap0_missing:+, }$p"
    elif [[ ! "$reason" =~ [0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
        cap0_undated="${cap0_undated}${cap0_undated:+, }$p"
    fi
done < <(jq -r '.providers | to_entries[] | select(.value.cap == 0) | .key' "$caps")

[[ -z "$cap0_missing" ]] || fail "cap=0 providers missing a reason: $cap0_missing"
[[ -z "$cap0_undated" ]] || fail "cap=0 providers have an undated reason (no YYYY-MM-DD): $cap0_undated"

# --- invariant 3: metered max_probe_ceiling never exceeds declared cap -------
metered_bad=""
while IFS= read -r p; do
    cap="$(jq -r --arg p "$p" '.providers[$p].cap // 0' "$caps")"
    ceiling="$(jq -r --arg p "$p" --argjson cap "$cap" '.providers[$p].max_probe_ceiling // $cap' "$caps")"
    if [[ "$ceiling" -gt "$cap" ]]; then
        metered_bad="${metered_bad}${metered_bad:+, }$p"
    fi
done < <(jq -r '.providers | to_entries[] | select(.value.class == "metered") | .key' "$caps")

[[ -z "$metered_bad" ]] || fail "metered providers with max_probe_ceiling > cap: $metered_bad"

echo "$ok_subset"
echo "OK: cap=0 providers carry a dated reason"
echo "OK: metered providers never probe above declared cap"
