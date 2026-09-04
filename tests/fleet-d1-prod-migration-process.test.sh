#!/usr/bin/env bash
# tests/fleet-d1-prod-migration-process.test.sh
#
# Proves the D1 prod migration execution rule (process amendment,
# decisions-ledger 2026-08-27; fleet-ops#908) is enforced:
#   1. prompts/worker.md keeps the D1 prod migration execution rule needles
#      (senior process gate, never single-agent apply, independent senior
#      blind-review).
#   2. A worker.md missing any needle is rejected.
#   3. config/rule-enforcement.json has the 2026-08-27 process amendment as
#      enforced, with a mechanism that names the senior process gate and a
#      proof that names this drill, the worker prompt, and the issue.
#
# Nested from tests/rule-enforcement.test.sh so CI cannot skip it without a
# workflow edit this token cannot push.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
worker="$repo_root/prompts/worker-0509-migrations.md"
matrix="$repo_root/config/rule-enforcement.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$worker" ]] || fail "missing $worker"
[[ -f "$matrix" ]] || fail "missing $matrix"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t d1-process.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Needles from the worker.md D1 prod migration execution rule.
# Removing any of these would let an agent bypass the senior process gate
# for prod D1 migrations without CI failing loud.
needles=(
  "D1 prod migration execution rule (process amendment, decisions-ledger 2026-08-27)"
  "Never single-agent apply."
  "Senior process gate:"
  "INDEPENDENT senior agent blind-reviews and must approve"
  "blocked-on: senior-conference"
)

check_worker() {
  local path="$1"
  for needle in "${needles[@]}"; do
    grep -Fq "$needle" "$path" || return 1
  done
  return 0
}

# --- 1. production worker.md passes ------------------------------------------
check_worker "$worker" || fail "worker.md missing one or more D1 prod migration execution needles"
ok "scenario1: worker.md contains the D1 prod migration execution rule needles"

# --- 2. dropping any needle is rejected --------------------------------------
for drop in "${needles[@]}"; do
  grep -vF "$drop" "$worker" >"$scratch/worker-drop.md" || true
  set +e
  check_worker "$scratch/worker-drop.md"
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || fail "scenario2: worker.md missing '$drop' should be rejected, got rc=$rc"
  ok "scenario2: dropping '$drop' is rejected"
done

# --- 3. matrix row is enforced with mechanism and proof ----------------------
jq -e '.rules[] | select(.id == "led-2026-08-27-d1-prod-migrations-process-amendment" and .status == "enforced")' \
  "$matrix" >/dev/null || fail "led-2026-08-27 process amendment must be status=enforced"

mech=$(jq -r '.rules[] | select(.id == "led-2026-08-27-d1-prod-migrations-process-amendment") | .mechanism' "$matrix")
printf '%s\n' "$mech" | grep -q 'senior process gate' \
  || fail "mechanism must name the senior process gate (got: $mech)"
printf '%s\n' "$mech" | grep -q 'worker.md' \
  || fail "mechanism must name worker.md (got: $mech)"
printf '%s\n' "$mech" | grep -q 'senior-conference' \
  || fail "mechanism must name the senior-conference gate (got: $mech)"

proof=$(jq -r '.rules[] | select(.id == "led-2026-08-27-d1-prod-migrations-process-amendment") | .proof' "$matrix")
printf '%s\n' "$proof" | grep -q 'tests/fleet-d1-prod-migration-process.test.sh' \
  || fail "proof must name this test (got: $proof)"
printf '%s\n' "$proof" | grep -q 'prompts/worker.md' \
  || fail "proof must name the worker prompt (got: $proof)"
printf '%s\n' "$proof" | grep -q 'fleet-ops#908' \
  || fail "proof must cite fleet-ops#908 (got: $proof)"

ok "scenario3: matrix row is enforced with mechanism+proof"

ok "d1-prod-migration-process: worker needles, matrix enforced, proof locked"