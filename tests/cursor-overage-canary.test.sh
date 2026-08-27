#!/usr/bin/env bash
# tests/cursor-overage-canary.test.sh
#
# fleet-ops#1179 (led-2026-08-27-cursor-400-sequencing-model-nish).
#
# Proves the Cursor $400 extra-usage sequencing + overage-model canary:
#   1. Clean meter (included remaining, overage closed) → PASS.
#   2. overage_open while included remains → REJECT SEQUENCING.
#   3. overage spend while included remains → REJECT SEQUENCING.
#   4. included exhausted + composer worker → REJECT OVERAGE-MODEL.
#   5. included exhausted + grok-4.6 worker → PASS.
#   6. Missing meter → REJECT METER-MISSING.
#   7. Stale meter → REJECT METER-STALE.
#   8. Wrong policy overage_model → REJECT OVERAGE-MODEL-POLICY.
#   9. Production seat-caps allowlists cursor-grok-4.6-high cap>=1.
#  10. Heartbeat-tier1 block 33 wiring + require_manifest_helper.
#  11. Matrix row is enforced with mechanism + proof.
#  12. MANIFEST ships binary + lib + policy.
#  13. Nested from escalation-coverage-canary.test.sh (CI host).
#  14. --ledger-line smoke.
#
# Offline. No Cursor dashboard calls.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/cursor-overage-canary.py"
bin="$repo_root/bin/fleet-cursor-overage-canary"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
matrix="$repo_root/config/rule-enforcement.json"
manifest="$repo_root/MANIFEST"
host="$here/escalation-coverage-canary.test.sh"
policy="$repo_root/config/cursor-overage-policy.json"
caps="$repo_root/config/seat-caps.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
[[ -x "$bin" ]] || fail "not executable: $bin"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t cursor-overage-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

write_fixture() {
  local dir="$1"
  mkdir -p "$dir/active-seats"
  cp "$policy" "$dir/policy.json"
  cat >"$dir/seat-caps.json" <<'JSON'
{
  "providers": {
    "cursor": {
      "cap": 1,
      "class": "prepaid-quota",
      "models": { "composer-2.5": 1, "cursor-grok-4.6-high": 1 }
    }
  }
}
JSON
}

NOW="2026-08-27T17:00:00Z"

# --- 1. clean meter → PASS -------------------------------------------------
write_fixture "$scratch/clean"
cat >"$scratch/clean/meter.json" <<'JSON'
{
  "included_exhausted": false,
  "overage_open": false,
  "overage_spend_usd_today": 0,
  "observed_at": "2026-08-27T16:50:00Z"
}
JSON
set +e
out="$("$bin" --from-fixtures "$scratch/clean" --now "$NOW" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "clean meter must exit 0, got $rc: $out"
grep -q 'PASS' <<<"$out" || fail "must print PASS: $out"
ok "included remaining + overage closed → PASS"

# --- 2. overage_open while included remains → REJECT -----------------------
write_fixture "$scratch/seq-open"
cat >"$scratch/seq-open/meter.json" <<'JSON'
{
  "included_exhausted": false,
  "overage_open": true,
  "overage_spend_usd_today": 0,
  "observed_at": "2026-08-27T16:50:00Z"
}
JSON
set +e
out="$("$bin" --from-fixtures "$scratch/seq-open" --now "$NOW" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "sequencing open must exit 1, got $rc: $out"
grep -q 'SEQUENCING' <<<"$out" || fail "must tag SEQUENCING: $out"
ok "overage_open while included remains → REJECT SEQUENCING"

# --- 3. overage spend while included remains → REJECT ----------------------
write_fixture "$scratch/seq-spend"
cat >"$scratch/seq-spend/meter.json" <<'JSON'
{
  "included_exhausted": false,
  "overage_open": false,
  "overage_spend_usd_today": 4.5,
  "observed_at": "2026-08-27T16:50:00Z"
}
JSON
set +e
out="$("$bin" --from-fixtures "$scratch/seq-spend" --now "$NOW" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "sequencing spend must exit 1, got $rc: $out"
grep -q 'SEQUENCING' <<<"$out" || fail "must tag SEQUENCING: $out"
ok "overage spend while included remains → REJECT SEQUENCING"

# --- 4. included exhausted + composer worker → REJECT ----------------------
write_fixture "$scratch/wrong-model"
cat >"$scratch/wrong-model/meter.json" <<'JSON'
{
  "included_exhausted": true,
  "overage_open": true,
  "overage_spend_usd_today": 1,
  "observed_at": "2026-08-27T16:50:00Z"
}
JSON
cat >"$scratch/wrong-model/active-seats/w.json" <<'JSON'
{"provider":"cursor","model":"composer-2.5","unit":"pi-issue-x","started_at":"2026-08-27T16:55:00Z"}
JSON
set +e
out="$("$bin" --from-fixtures "$scratch/wrong-model" --now "$NOW" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "wrong overage model must exit 1, got $rc: $out"
grep -q 'OVERAGE-MODEL' <<<"$out" || fail "must tag OVERAGE-MODEL: $out"
ok "included exhausted + composer worker → REJECT OVERAGE-MODEL"

# --- 5. included exhausted + grok-4.6 worker → PASS ------------------------
write_fixture "$scratch/right-model"
cat >"$scratch/right-model/meter.json" <<'JSON'
{
  "included_exhausted": true,
  "overage_open": true,
  "overage_spend_usd_today": 1,
  "observed_at": "2026-08-27T16:50:00Z"
}
JSON
cat >"$scratch/right-model/active-seats/w.json" <<'JSON'
{"provider":"cursor","model":"cursor-grok-4.6-high","unit":"pi-issue-x","started_at":"2026-08-27T16:55:00Z"}
JSON
set +e
out="$("$bin" --from-fixtures "$scratch/right-model" --now "$NOW" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "grok-4.6 on overage must exit 0, got $rc: $out"
grep -q 'PASS' <<<"$out" || fail "must print PASS: $out"
ok "included exhausted + grok-4.6 worker → PASS"

# --- 6. missing meter → REJECT --------------------------------------------
write_fixture "$scratch/nometer"
rm -f "$scratch/nometer/meter.json"
set +e
out="$("$bin" --from-fixtures "$scratch/nometer" --now "$NOW" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "missing meter must exit 1, got $rc: $out"
grep -q 'METER-MISSING' <<<"$out" || fail "must tag METER-MISSING: $out"
ok "missing meter → REJECT METER-MISSING"

# --- 7. stale meter → REJECT ----------------------------------------------
write_fixture "$scratch/stale"
cat >"$scratch/stale/meter.json" <<'JSON'
{
  "included_exhausted": false,
  "overage_open": false,
  "overage_spend_usd_today": 0,
  "observed_at": "2026-08-26T10:00:00Z"
}
JSON
set +e
out="$("$bin" --from-fixtures "$scratch/stale" --now "$NOW" --stale-minutes 1440 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "stale meter must exit 1, got $rc: $out"
grep -q 'METER-STALE' <<<"$out" || fail "must tag METER-STALE: $out"
ok "stale meter → REJECT METER-STALE"

# --- 8. wrong policy overage_model → REJECT --------------------------------
write_fixture "$scratch/badpolicy"
jq '.overage_model="composer-2.5"' "$scratch/badpolicy/policy.json" \
  >"$scratch/badpolicy/policy.tmp" && mv "$scratch/badpolicy/policy.tmp" \
  "$scratch/badpolicy/policy.json"
cat >"$scratch/badpolicy/meter.json" <<'JSON'
{
  "included_exhausted": false,
  "overage_open": false,
  "overage_spend_usd_today": 0,
  "observed_at": "2026-08-27T16:50:00Z"
}
JSON
set +e
out="$("$bin" --from-fixtures "$scratch/badpolicy" --now "$NOW" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "wrong policy model must exit 1, got $rc: $out"
grep -q 'OVERAGE-MODEL-POLICY' <<<"$out" || fail "must tag OVERAGE-MODEL-POLICY: $out"
ok "policy.overage_model != grok-4.6 → REJECT OVERAGE-MODEL-POLICY"

# --- 9. production seat-caps allowlists the overage model ------------------
jq -e '.providers.cursor.models["cursor-grok-4.6-high"] >= 1' "$caps" >/dev/null \
  || fail "production seat-caps must allowlist cursor-grok-4.6-high cap>=1"
jq -e '.overage_model == "cursor-grok-4.6-high" and .included_exhaust_first == true' \
  "$policy" >/dev/null \
  || fail "production policy must lock grok-4.6 + included_exhaust_first"
ok "production seat-caps + policy lock cursor-grok-4.6-high"

# --- 10. tier1 block 33 wiring --------------------------------------------
grep -q 'CURSOR_OVERAGE_CANARY_BIN' "$tier1" \
  || fail "tier1 must reference CURSOR_OVERAGE_CANARY_BIN"
grep -q 'cursor_overage_canary_rc' "$tier1" \
  || fail "tier1 must propagate cursor_overage_canary_rc"
grep -q '33. cursor overage canary' "$tier1" \
  || fail "tier1 must name block 33 as cursor overage canary"
grep -q 'require_manifest_helper.*CURSOR_OVERAGE_CANARY' "$tier1" \
  || fail "tier1 block 33 must call require_manifest_helper"
grep -q 'HELPER-MISSING.*cursor overage' "$tier1" \
  || fail "tier1 block 33 must loud HELPER-MISSING"
ok "tier1 block 33 wires cursor-overage-canary with require_manifest_helper"

# --- 11. matrix row is enforced with mechanism + proof ---------------------
src='decisions-ledger.md: 2026-08-27 | Cursor $400 sequencing + model (Nish)'
jq -e --arg src "$src" \
  '.rules[] | select(.source == $src and .id == "led-2026-08-27-cursor-400-sequencing-model-nish" and .status == "enforced")' \
  "$matrix" >/dev/null \
  || fail "matrix must mark led-2026-08-27-cursor-400-sequencing-model-nish as enforced"
jq -e '.rules[] | select(.id == "led-2026-08-27-cursor-400-sequencing-model-nish") | .mechanism | test("fleet-cursor-overage-canary")' \
  "$matrix" >/dev/null \
  || fail "matrix mechanism must reference fleet-cursor-overage-canary"
jq -e '.rules[] | select(.id == "led-2026-08-27-cursor-400-sequencing-model-nish") | .proof | test("cursor-overage-canary\\.test\\.sh")' \
  "$matrix" >/dev/null \
  || fail "matrix proof must reference cursor-overage-canary.test.sh"
ok "matrix row led-2026-08-27-cursor-400-sequencing-model-nish is enforced"

# --- 12. MANIFEST installs the canary + lib + policy -----------------------
grep -q 'bin/fleet-cursor-overage-canary' "$manifest" \
  || fail "MANIFEST must install bin/fleet-cursor-overage-canary"
grep -q 'lib/cursor-overage-canary.py' "$manifest" \
  || fail "MANIFEST must install lib/cursor-overage-canary.py"
grep -q 'config/cursor-overage-policy.json' "$manifest" \
  || fail "MANIFEST must install config/cursor-overage-policy.json"
ok "MANIFEST ships the canary binary + lib + policy"

# --- 13. CI host lock ------------------------------------------------------
grep -Fq 'bash "$here/cursor-overage-canary.test.sh"' "$host" \
  || fail "escalation-coverage-canary.test.sh must invoke this file (CI host, no workflow edit)"
ok "nested from escalation-coverage-canary.test.sh"

# --- 14. ledger-line smoke -------------------------------------------------
set +e
out="$("$bin" --ledger-line 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "--ledger-line must exit 0, got $rc: $out"
grep -q 'Cursor \$400 sequencing + model' <<<"$out" \
  || fail "--ledger-line must name the ledger title: $out"
ok "--ledger-line names the ledger title"

echo "OK: cursor-overage-canary (fleet-ops#1179)"
