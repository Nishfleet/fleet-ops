#!/usr/bin/env bash
# tests/fleet-seat-recovery.test.sh
# fleet-ops#4263 P3b: listed in ci.yml. Ledger walk / seat_usable retired.
# Unit-shape checks stay; bin-transition drills need the deleted router.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

bash "$here/fleet-seat-recovery-units.test.sh" \
  || fail "fleet-seat-recovery-units tests failed"
ok "recovery unit-shape checks still run"

grep -q 'litellm_ready' "$repo_root/bin/fleet-seat-recovery" \
  || fail "fleet-seat-recovery must use litellm_ready"
if grep -qE 'seat_usable "' "$repo_root/bin/fleet-seat-recovery"; then
  fail "fleet-seat-recovery still calls seat_usable"
fi
ok "seat recovery uses proxy health, not seat_usable"
