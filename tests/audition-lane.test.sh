#!/usr/bin/env bash
# tests/audition-lane.test.sh
# fleet-ops#4263 P3b: listed in ci.yml. Audition injection/retirement lived
# in pick_seat. Proxy model groups replace per-seat audition.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

if grep -q 'pick_seat()' "$repo_root/lib/seat-lib.sh" 2>/dev/null; then
  fail "forwarder must not define pick_seat"
fi
ok "audition lane retired with pick_seat"
