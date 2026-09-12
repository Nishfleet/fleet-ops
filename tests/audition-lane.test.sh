#!/usr/bin/env bash
# tests/audition-lane.test.sh
# fleet-ops#4263 P3b: listed in ci.yml. Audition injection/retirement lived
# in pick-seat. Proxy model groups replace per-seat audition.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

if grep -q 'litellm_seat()' "$repo_root/lib/litellm-seat.sh" 2>/dev/null; then
  fail "forwarder must not define pick-seat"
fi
ok "audition lane retired with pick-seat"
