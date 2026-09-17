#!/usr/bin/env bash
# Network fixtures are contract tests, never ranking evidence.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tick="$root/lib/pi-intake-tick.sh"
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
grep -q '^jev_acquisition_log() {' "$tick" || fail 'acquisition logger missing'
eval "$(awk '/^jev_acquisition_log\(\) \{/,/^}/' "$tick")"
export CAPTURE="$scratch/request" MODE=valid
jev-eval() {
    tee "$CAPTURE" | jq --arg mode "$MODE" '
      {answers: (.questions | with_entries(.value =
        {choice: (if .key == "issue_7416" then "3" else "1" end),
         probabilities: {"0":0.05,"1":0.8,"2":0.05,"3":0.1}}))}
      | if $mode == "invalid" then .answers.issue_7416.probabilities["3"] = 2
        elif $mode == "missing" then del(.answers.issue_7416)
        else . end'
    [[ "$MODE" != failure ]] || return 3
}
export -f jev-eval
FULL=Nishfleet/fleet-ops CRITICAL_PATH_LABEL=critical-path
issues='[{"number":7416,"title":"acquisition rank","body":"accept: advisory only","labels":[]},{"number":7371,"title":"shared evaluator","body":"accept: reuse SDK","labels":[{"name":"critical-path"}]}]'
PI_INTAKE_JEV_ACQUISITION=1
out=$(jev_acquisition_log "$issues")
[[ "$out" == *'Nishfleet/fleet-ops#7416 current=2 advisory=1 acquisition_value=3 p=0.1'* ]] || fail 'missing rank and selected probability'
[[ "$out" == *'Nishfleet/fleet-ops#7371 current=1 advisory=2 acquisition_value=1 p=0.8'* ]] || fail 'current critical-path order lost'
jq -e '.state.baseline.users == 15 and .state.baseline.signups_since_june == 0 and .state.baseline.reported_at == "2026-09-17" and .state.baseline.live == false and (.state.issues[0].body | length > 0) and (.questions | keys) == ["issue_7371","issue_7416"] and (.state.rules.activation | contains("30"))' "$CAPTURE" >/dev/null || fail 'incomplete context'
for MODE in invalid missing failure; do
    export MODE
    out=$(jev_acquisition_log "$issues" 2>"$scratch/error")
    [[ -z "$out" ]] || fail "$MODE emitted ranking"
    grep -q 'failed' "$scratch/error" || fail "$MODE not flagged"
done
export MODE=valid
rm "$CAPTURE"
out=$(PI_INTAKE_JEV_ACQUISITION=0 jev_acquisition_log "$issues")
[[ -z "$out" && ! -e "$CAPTURE" ]] || fail 'rollback still calls helper'
out=$(GITHUB_ACTIONS=true PI_INTAKE_JEV_ACQUISITION= jev_acquisition_log "$issues")
[[ -z "$out" && ! -e "$CAPTURE" ]] || fail 'CI calls helper'
out=$(jev_acquisition_log '[]')
[[ -z "$out" && ! -e "$CAPTURE" ]] || fail 'empty queue calls helper'
# Advice must never abort dispatch under set -e, including payload assembly.
jq() { if [[ "${1:-}" == -cs ]]; then return 9; fi; command jq "$@"; }
out=$(jev_acquisition_log "$issues" 2>"$scratch/error")
[[ -z "$out" ]] || fail 'failed payload produced rank'
grep -q 'payload construction failed' "$scratch/error" || fail 'payload failure not isolated'
unset -f jq
# The corpus can exceed the per-argument OS limit. Full bodies use stdin.
large=$(command jq -cn '[{number:7416,title:"large",body:("x" * 200000),labels:[]}]')
out=$(jev_acquisition_log "$large")
[[ "$out" == *'acquisition_value=3'* ]] || fail 'large full-context body rejected'
jq -e '.state.issues[0].body | length == 200000' "$CAPTURE" >/dev/null
out=$(PI_INTAKE_JEV_ACQUISITION= jev_acquisition_log "$issues")
[[ -z "$out" ]] || fail 'default activation is not held'
python3 - "$tick" <<'PY'
import sys
s=open(sys.argv[1]).read()
assert s.index('jev_acquisition_log "$issues_json"') < s.index('# Step 2: capacity')
assert '--json number,title,body,labels' in s
assert 'mapfile -t numbers < <(jq -r --arg cp "$CRITICAL_PATH_LABEL" "$_claim_order | .[].number" <<<"$issues_json")' in s
PY
echo 'PASS: acquisition ranking, context, current order, rollback, invalid/missing/failure isolation'
