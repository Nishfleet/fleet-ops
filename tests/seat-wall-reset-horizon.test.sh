#!/usr/bin/env bash
# tests/seat-wall-reset-horizon.test.sh
# fleet-ops#4263 P3b: listed in ci.yml. quota_bench wall ceiling lived in
# the deleted routing library. Proxy cooldown owns walls now.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

if grep -q 'pick_seat()' "$repo_root/lib/seat-lib.sh" 2>/dev/null; then
  fail "forwarder must not define pick_seat"
fi
ok "quota_bench wall ceiling retired with pick_seat (proxy cooldown owns walls)"
