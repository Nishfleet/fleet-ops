#!/usr/bin/env bash
# tests/north-star-quality.test.sh
#
# Proves fleet-ops#459 NORTH STAR quality guard:
#   (a) the live config passes: quality-routing names the three primary
#       SLO cuts and role-gates keep reviewer/senior/researcher on the
#       quality scoreboard.
#   (b) a config that weakens a cut above the NORTH STAR ceiling is rejected.
#   (c) a config that drops a primary SLO cut is rejected.
#   (d) a role-gates catalog that detaches a scoreboard role is rejected.
#   contracts: rule-enforcement matrix row is enforced + nested CI host.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
py="$repo_root/lib/north-star-quality.py"
qr="$repo_root/config/quality-routing.json"
rg="$repo_root/config/role-quality-gates.json"
matrix="$repo_root/config/rule-enforcement.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$py" ]] || fail "missing $py"
[[ -f "$qr" ]] || fail "missing $qr"
[[ -f "$rg" ]] || fail "missing $rg"
[[ -f "$matrix" ]] || fail "missing $matrix"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

# (a) live config passes
set +e
live_out=$(python3 "$py" verify --quality-routing "$qr" --role-gates "$rg" 2>&1)
live_rc=$?
set -e
[[ "$live_rc" == "0" ]] || fail "live config must pass NORTH STAR guard (rc=$live_rc out=$live_out)"
ok "(a) live config passes NORTH STAR guard"

# Matrix row is enforced in the same PR.
jq -e '.rules[] | select(.id == "led-north-star-quality" and .status == "enforced")' \
  "$matrix" >/dev/null || fail "led-north-star-quality must be status=enforced in the matrix"
ok "(a) led-north-star-quality is enforced in the rule matrix"

scratch=$(mktemp -d -t north-star-quality.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM

weakened="$scratch/quality-routing-weakened.json"
missing="$scratch/quality-routing-missing.json"
bad_gates="$scratch/role-gates-bad.json"

cp "$qr" "$weakened"
cp "$qr" "$missing"
cp "$rg" "$bad_gates"

# (b) weakened cut above the NORTH STAR ceiling is rejected
jq '.revert_rate_cut = 0.05' "$weakened" >"$scratch/qr-weakened.json" && mv "$scratch/qr-weakened.json" "$weakened"
set +e
weakened_out=$(python3 "$py" verify --quality-routing "$weakened" --role-gates "$rg" 2>&1)
weakened_rc=$?
set -e
[[ "$weakened_rc" == "1" ]] || fail "weakened revert_rate_cut must be rejected (rc=$weakened_rc out=$weakened_out)"
grep -q 'weakens the NORTH STAR ceiling' <<<"$weakened_out" \
  || fail "weakened output must name the NORTH STAR ceiling (out=$weakened_out)"
ok "(b) weakened revert_rate_cut above ceiling is rejected"

# (c) missing primary SLO cut is rejected
jq 'del(.overturn_rate_cut)' "$missing" >"$scratch/qr-missing.json" && mv "$scratch/qr-missing.json" "$missing"
set +e
missing_out=$(python3 "$py" verify --quality-routing "$missing" --role-gates "$rg" 2>&1)
missing_rc=$?
set -e
[[ "$missing_rc" == "1" ]] || fail "missing overturn_rate_cut must be rejected (rc=$missing_rc out=$missing_out)"
grep -q 'missing primary SLO cut' <<<"$missing_out" \
  || fail "missing output must name the primary SLO cut (out=$missing_out)"
ok "(c) missing overturn_rate_cut is rejected"

# (d) role detached from the quality scoreboard is rejected
jq '(.roles[] | select(.id == "reviewer")).gate = "senior admission panel only"' \
  "$bad_gates" >"$scratch/rg-bad.json" && mv "$scratch/rg-bad.json" "$bad_gates"
set +e
bad_out=$(python3 "$py" verify --quality-routing "$qr" --role-gates "$bad_gates" 2>&1)
bad_rc=$?
set -e
[[ "$bad_rc" == "1" ]] || fail "detached reviewer gate must be rejected (rc=$bad_rc out=$bad_out)"
grep -q 'must reference the quality scoreboard' <<<"$bad_out" \
  || fail "bad-gate output must name the scoreboard (out=$bad_out)"
ok "(d) reviewer gate detached from scoreboard is rejected"

# Contracts
grep -Fq 'bash "$here/north-star-quality.test.sh"' "$here/rule-enforcement.test.sh" \
  || fail "rule-enforcement.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "contracts: matrix enforced, nested CI host"

ok "north-star-quality: live config, weakened cut, missing SLO, detached gate"
