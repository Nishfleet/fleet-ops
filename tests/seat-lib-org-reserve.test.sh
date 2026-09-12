#!/usr/bin/env bash
# tests/seatlib-org-reserve.test.sh
# fleet-ops#4263 P3b: listed in ci.yml. org-reserve AIMD path deleted with
# the routing library. This file proves the delete landed.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

if [[ -f "$repo_root/lib/litellm-seat.sh" ]] && grep -q 'litellm_seat()' "$repo_root/lib/litellm-seat.sh"; then
  fail "routing library still defines pick-seat"
fi
ok "org-reserve routing path retired with pick-seat"
