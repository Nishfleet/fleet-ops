#!/usr/bin/env bash
# tests/quality-ratchet.test.sh
#
# Proves fleet-ops#1222 / ledger 2026-08-27 | Quality ratchet (Nish):
#   (a) matrix row is enforced with a real mechanism/proof
#   (b) live quality-routing cuts match committed ratchet floors
#   (c) loosening a cut is rejected
#   (d) tighten-one-notch record is accepted; two-notch and raise are not
#   (e) hold with evidence is accepted; empty/n/a evidence is not
#   (f) nish-waiver without a ledger pointer is rejected
#   (g) WFR last-actions without last-ratchet.json fails the canary
#   (h) WFR prompt + role-gate lock the weekly ratchet contract
#   (i) heartbeat-tier1 wires the canary fail-loud; MANIFEST installs it
# Nested from tests/rule-enforcement.test.sh so CI cannot skip it without
# a workflow edit this token cannot push.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
py="$repo_root/lib/quality-ratchet.py"
ratchet="$repo_root/config/quality-ratchet.json"
qr="$repo_root/config/quality-routing.json"
prompt="$repo_root/prompts/weekly-fleet-review.md"
role_gates_lib="$repo_root/lib/role-quality-gates.py"
matrix="$repo_root/config/rule-enforcement.json"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
manifest="$repo_root/MANIFEST"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$py" ]] || fail "missing $py"
[[ -x "$py" ]] || fail "not executable: $py"
[[ -f "$ratchet" ]] || fail "missing $ratchet"
[[ -f "$qr" ]] || fail "missing $qr"
[[ -f "$prompt" ]] || fail "missing $prompt"
[[ -f "$role_gates_lib" ]] || fail "missing $role_gates_lib"
[[ -f "$matrix" ]] || fail "missing $matrix"
[[ -f "$tier1" ]] || fail "missing $tier1"
[[ -f "$manifest" ]] || fail "missing $manifest"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

# (a) matrix
jq -e '.rules[] | select(.id == "led-2026-08-27-quality-ratchet-nish" and .status == "enforced")' \
  "$matrix" >/dev/null || fail "led-2026-08-27-quality-ratchet-nish must be status=enforced"
mech=$(jq -r '.rules[] | select(.id == "led-2026-08-27-quality-ratchet-nish") | .mechanism' "$matrix")
printf '%s\n' "$mech" | grep -q 'quality-ratchet' \
  || fail "mechanism must name quality-ratchet (got: $mech)"
printf '%s\n' "$mech" | grep -q 'one notch' \
  || fail "mechanism must lock one notch per week (got: $mech)"
proof=$(jq -r '.rules[] | select(.id == "led-2026-08-27-quality-ratchet-nish") | .proof' "$matrix")
printf '%s\n' "$proof" | grep -q 'lib/quality-ratchet.py' \
  || fail "proof must name lib/quality-ratchet.py (got: $proof)"
printf '%s\n' "$proof" | grep -q 'tests/quality-ratchet.test.sh' \
  || fail "proof must name this test (got: $proof)"
printf '%s\n' "$proof" | grep -q 'prompts/weekly-fleet-review.md' \
  || fail "proof must name the WFR prompt (got: $proof)"
ok "(a) led-2026-08-27-quality-ratchet-nish is enforced with mechanism+proof"

scratch=$(mktemp -d -t quality-ratchet.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM
NOW="2026-08-27T18:00:00Z"

# (b) live cuts match floors; no WFR dir yet is a skip, not a fail
set +e
live_out=$(python3 "$py" canary --ratchet "$ratchet" --quality-routing "$qr" \
  --wfr-dir "$scratch/missing-wfr" --now "$NOW" 2>&1)
live_rc=$?
set -e
[[ "$live_rc" == "0" ]] || fail "live canary must pass (rc=$live_rc out=$live_out)"
grep -q 'QUALITY-RATCHET-OK' <<<"$live_out" \
  || fail "live canary must print OK (out=$live_out)"
grep -q 'WFR has not run' <<<"$live_out" \
  || fail "live canary must skip weekly record when WFR has not run (out=$live_out)"
ok "(b) live cuts match committed floors; weekly record skipped pre-WFR"

# (c) loosening a cut is rejected
jq '.revert_rate_cut = 0.05' "$qr" >"$scratch/qr-loose.json"
set +e
loose_out=$(python3 "$py" canary --ratchet "$ratchet" --quality-routing "$scratch/qr-loose.json" \
  --wfr-dir "$scratch/missing-wfr" --now "$NOW" 2>&1)
loose_rc=$?
set -e
[[ "$loose_rc" == "1" ]] || fail "loosened revert_rate_cut must fail (rc=$loose_rc out=$loose_out)"
grep -q 'loosened past committed cut' <<<"$loose_out" \
  || fail "loosen output must name the committed cut (out=$loose_out)"
ok "(c) loosening revert_rate_cut is rejected"

# (d) one-notch tighten accepted; two-notch and raise rejected
cat >"$scratch/tighten-ok.json" <<'JSON'
{
  "date": "2026-08-27",
  "action": "tighten",
  "knob": "revert_rate_cut",
  "from": 0.04,
  "to": 0.035,
  "evidence": "all lanes revert_rate <= 0.03 on the 4-week scoreboard ending 2026-08-27"
}
JSON
set +e
tight_out=$(python3 "$py" evaluate-record --ratchet "$ratchet" \
  --record "$scratch/tighten-ok.json" --now "$NOW" 2>&1)
tight_rc=$?
set -e
[[ "$tight_rc" == "0" ]] || fail "one-notch tighten must pass (rc=$tight_rc out=$tight_out)"
ok "(d1) one-notch tighten record is accepted"

cat >"$scratch/tighten-two.json" <<'JSON'
{
  "date": "2026-08-27",
  "action": "tighten",
  "knob": "revert_rate_cut",
  "from": 0.04,
  "to": 0.03,
  "evidence": "all lanes revert_rate <= 0.03 on the 4-week scoreboard ending 2026-08-27"
}
JSON
set +e
two_out=$(python3 "$py" evaluate-record --ratchet "$ratchet" \
  --record "$scratch/tighten-two.json" --now "$NOW" 2>&1)
two_rc=$?
set -e
[[ "$two_rc" == "1" ]] || fail "two-notch tighten must fail (rc=$two_rc out=$two_out)"
grep -q 'not one notch' <<<"$two_out" \
  || fail "two-notch output must say not one notch (out=$two_out)"
ok "(d2) two-notch tighten is rejected"

cat >"$scratch/tighten-raise.json" <<'JSON'
{
  "date": "2026-08-27",
  "action": "tighten",
  "knob": "revert_rate_cut",
  "from": 0.04,
  "to": 0.05,
  "evidence": "all lanes revert_rate <= 0.03 on the 4-week scoreboard ending 2026-08-27"
}
JSON
set +e
raise_out=$(python3 "$py" evaluate-record --ratchet "$ratchet" \
  --record "$scratch/tighten-raise.json" --now "$NOW" 2>&1)
raise_rc=$?
set -e
[[ "$raise_rc" == "1" ]] || fail "raise-as-tighten must fail (rc=$raise_rc out=$raise_out)"
ok "(d3) raising a cut as tighten is rejected"

# (e) hold with evidence; empty/n/a rejected
cat >"$scratch/hold-ok.json" <<'JSON'
{
  "date": "2026-08-27",
  "action": "hold",
  "evidence": "no SLO was inside its cut for 4 weeks; closest revert_rate 0.038 vs 0.04 (1 week)"
}
JSON
set +e
hold_out=$(python3 "$py" evaluate-record --ratchet "$ratchet" \
  --record "$scratch/hold-ok.json" --now "$NOW" 2>&1)
hold_rc=$?
set -e
[[ "$hold_rc" == "0" ]] || fail "evidence-backed hold must pass (rc=$hold_rc out=$hold_out)"
ok "(e1) evidence-backed hold is accepted"

cat >"$scratch/hold-na.json" <<'JSON'
{"date": "2026-08-27", "action": "hold", "evidence": "n/a"}
JSON
set +e
na_out=$(python3 "$py" evaluate-record --ratchet "$ratchet" \
  --record "$scratch/hold-na.json" --now "$NOW" 2>&1)
na_rc=$?
set -e
[[ "$na_rc" == "1" ]] || fail "n/a hold must fail (rc=$na_rc out=$na_out)"
ok "(e2) n/a hold evidence is rejected"

# (f) nish-waiver needs a ledger pointer
cat >"$scratch/waiver-bad.json" <<'JSON'
{
  "date": "2026-08-27",
  "action": "nish-waiver",
  "knob": "defect_rate_cut",
  "from": 0.40,
  "to": 0.45,
  "evidence": "please loosen the defect cut this week because volume dipped"
}
JSON
set +e
wbad_out=$(python3 "$py" evaluate-record --ratchet "$ratchet" \
  --record "$scratch/waiver-bad.json" --now "$NOW" 2>&1)
wbad_rc=$?
set -e
[[ "$wbad_rc" == "1" ]] || fail "waiver without ledger must fail (rc=$wbad_rc out=$wbad_out)"
grep -q 'waiver_source' <<<"$wbad_out" \
  || fail "waiver output must name waiver_source (out=$wbad_out)"

cat >"$scratch/waiver-ok.json" <<'JSON'
{
  "date": "2026-08-27",
  "action": "nish-waiver",
  "knob": "defect_rate_cut",
  "from": 0.40,
  "to": 0.45,
  "evidence": "Nish waived the defect cut this week after the 2026-08-27 volume dip",
  "waiver_source": "decisions-ledger.md: 2026-08-27 | loosen defect cut"
}
JSON
set +e
wok_out=$(python3 "$py" evaluate-record --ratchet "$ratchet" \
  --record "$scratch/waiver-ok.json" --now "$NOW" 2>&1)
wok_rc=$?
set -e
[[ "$wok_rc" == "0" ]] || fail "ledger-backed waiver must pass (rc=$wok_rc out=$wok_out)"
ok "(f) nish-waiver requires a decisions-ledger pointer"

# (g) last-actions without last-ratchet fails canary
mkdir -p "$scratch/wfr"
printf '%s\n' '{"date":"2026-08-27","filed":[],"discards":[]}' >"$scratch/wfr/last-actions.json"
set +e
miss_out=$(python3 "$py" canary --ratchet "$ratchet" --quality-routing "$qr" \
  --wfr-dir "$scratch/wfr" --now "$NOW" 2>&1)
miss_rc=$?
set -e
[[ "$miss_rc" == "1" ]] || fail "missing last-ratchet.json must fail (rc=$miss_rc out=$miss_out)"
grep -q 'last-ratchet.json is missing' <<<"$miss_out" \
  || fail "missing-record output must name last-ratchet.json (out=$miss_out)"
cp "$scratch/hold-ok.json" "$scratch/wfr/last-ratchet.json"
set +e
have_out=$(python3 "$py" canary --ratchet "$ratchet" --quality-routing "$qr" \
  --wfr-dir "$scratch/wfr" --now "$NOW" 2>&1)
have_rc=$?
set -e
[[ "$have_rc" == "0" ]] || fail "valid weekly record must pass canary (rc=$have_rc out=$have_out)"
ok "(g) WFR run without last-ratchet.json fails; hold record passes"

# (h) WFR prompt + role-gate
grep -q 'Quality ratchet' "$prompt" \
  || fail "WFR prompt must name the Quality ratchet phase"
grep -q 'one notch' "$prompt" \
  || fail "WFR prompt must lock one notch per week"
grep -q 'last-ratchet.json' "$prompt" \
  || fail "WFR prompt must require last-ratchet.json"
grep -qi 'never loosen' "$prompt" \
  || fail "WFR prompt must say never loosen without Nish"
grep -q 'quality_ratchet_contract' "$role_gates_lib" \
  || fail "role-quality-gates.py must name quality_ratchet_contract"
grep -q 'def check_quality_ratchet_contract' "$role_gates_lib" \
  || fail "role-quality-gates.py must define check_quality_ratchet_contract"
ok "(h) WFR prompt and role-gate lock the ratchet contract"

# (i) heartbeat + MANIFEST
grep -F 'quality-ratchet.py' "$tier1" >/dev/null \
  || fail "tier1 must invoke quality-ratchet.py"
grep -F 'quality_ratchet_canary_rc' "$tier1" >/dev/null \
  || fail "tier1 must capture quality_ratchet_canary_rc"
grep -F -- 'exit "$quality_ratchet_canary_rc"' "$tier1" >/dev/null \
  || fail "tier1 must exit non-zero when the quality-ratchet gate fails loud"
grep -q 'lib/quality-ratchet.py' "$manifest" \
  || fail "MANIFEST must install lib/quality-ratchet.py"
grep -q 'config/quality-ratchet.json' "$manifest" \
  || fail "MANIFEST must install config/quality-ratchet.json"
ok "(i) heartbeat-tier1 wires the canary, fail-loud, MANIFEST installs it"

grep -Fq 'bash "$here/quality-ratchet.test.sh"' "$here/rule-enforcement.test.sh" \
  || fail "rule-enforcement.test.sh must nest this file"
ok "contracts: nested CI host"

ok "quality-ratchet: matrix, live floors, loosen, one-notch, hold, waiver, WFR record, prompt, heartbeat"
