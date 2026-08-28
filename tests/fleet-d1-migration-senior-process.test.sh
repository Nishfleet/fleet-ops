#!/usr/bin/env bash
# tests/fleet-d1-migration-senior-process.test.sh
#
# Proves the D1 prod migration senior process enforcer (fleet-ops#906):
#   1. prompts/worker.md carries the senior process rule and voids the
#      2026-08-27 "do it right now" D1 prod migration decision.
#   2. prompts/scout.md carries the senior process in the D1 schema gate.
#   3. config/rule-enforcement.json marks the correction row as enforced
#      and names the prompt files + this test.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
worker="$repo_root/prompts/worker.md"
scout="$repo_root/prompts/scout.md"
matrix="$repo_root/config/rule-enforcement.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$worker" ]] || fail "missing $worker"
[[ -f "$scout" ]] || fail "missing $scout"
[[ -f "$matrix" ]] || fail "missing $matrix"
command -v jq >/dev/null 2>&1 || fail "jq missing"
command -v grep >/dev/null 2>&1 || fail "grep missing"

# Worker prompt must void the earlier decision and require the senior process.
grep -q 'D1 prod migration senior process rule' "$worker" \
  || fail "worker.md must name the D1 prod migration senior process rule"
grep -q 'VOID' "$worker" \
  || fail "worker.md must void the 2026-08-27 'do it right now' decision"
grep -q 'independent senior blind-review' "$worker" \
  || fail "worker.md must require independent senior blind-review"
grep -q 'verified backup' "$worker" \
  || fail "worker.md must require verified backup"
grep -q 'concrete rollback' "$worker" \
  || fail "worker.md must require concrete rollback"
grep -q 'live verification' "$worker" \
  || fail "worker.md must require live verification"
grep -q 'text Nish' "$worker" \
  || fail "worker.md must require text Nish"
ok "worker.md carries the D1 prod migration senior process rule"

# Scout prompt must require the senior process in the D1 schema gate.
grep -q 'D1 prod migration senior process' "$scout" \
  || fail "scout.md must name the D1 prod migration senior process"
grep -q 'independent senior blind-review' "$scout" \
  || fail "scout.md must require independent senior blind-review"
grep -q 'verified backup' "$scout" \
  || fail "scout.md must require verified backup"
grep -q 'concrete rollback' "$scout" \
  || fail "scout.md must require concrete rollback"
grep -q 'text Nish' "$scout" \
  || fail "scout.md must require text Nish"
ok "scout.md carries the D1 prod migration senior process rule"

# Matrix row for the correction must be enforced and name the prompt gate.
jq -e '.rules[] | select(.id == "led-2026-08-27-d1-prod-migrations-correction" and .status == "enforced")' "$matrix" >/dev/null \
  || fail "matrix row led-2026-08-27-d1-prod-migrations-correction must be status=enforced"
mech=$(jq -r '.rules[] | select(.id == "led-2026-08-27-d1-prod-migrations-correction") | .mechanism' "$matrix")
printf '%s\n' "$mech" | grep -q 'prompt' \
  || fail "matrix mechanism must name the prompt gate (got: $mech)"
proof=$(jq -r '.rules[] | select(.id == "led-2026-08-27-d1-prod-migrations-correction") | .proof' "$matrix")
printf '%s\n' "$proof" | grep -q 'prompts/worker.md' \
  || fail "matrix proof must name prompts/worker.md (got: $proof)"
printf '%s\n' "$proof" | grep -q 'tests/fleet-d1-migration-senior-process.test.sh' \
  || fail "matrix proof must name this test (got: $proof)"
ok "matrix row is enforced with prompt gate and proof"

ok "d1-migration-senior-process: prompt gate locked, matrix enforced"
