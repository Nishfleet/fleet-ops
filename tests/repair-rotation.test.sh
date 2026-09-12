#!/usr/bin/env bash
# tests/repair-rotation.test.sh
# fleet-ops#4263 P3b: listed in ci.yml. pick-seat rotation is gone;
# LiteLLM groups replace it. Filename stays so CI still invokes it.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

if grep -qE '\$\(pick-seat' "$repo_root/bin/pi-intake-repair-run"; then
  fail "pi-intake-repair-run still calls pick-seat"
fi
grep -q 'litellm_seat' "$repo_root/bin/pi-intake-repair-run" \
  || fail "pi-intake-repair-run must call litellm_seat"
ok "intake-repair rotation uses LiteLLM groups, not pick-seat"
