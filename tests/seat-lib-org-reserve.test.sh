#!/usr/bin/env bash
# tests/seat-lib-org-reserve.test.sh
# fleet-ops#4263 P3b: listed in ci.yml. org-reserve AIMD path deleted with
# the routing library. This file proves the delete landed.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

if [[ -f "$repo_root/lib/seat-lib.sh" ]] && grep -q 'pick_seat()' "$repo_root/lib/seat-lib.sh"; then
  fail "routing library still defines pick_seat"
fi
ok "org-reserve routing path retired with pick_seat"
