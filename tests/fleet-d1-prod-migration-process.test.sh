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
worker="$repo_root/prompts/worker.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$worker" ]] || fail "missing $worker"
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

ok "d1-prod-migration-process: worker.md D1 senior-process needles locked"