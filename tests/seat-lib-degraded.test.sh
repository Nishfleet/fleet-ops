#!/usr/bin/env bash
# tests/seatlib-degraded.test.sh
# fleet-ops#4263 P3b: listed in ci.yml. Routing library is gone; this file
# only proves the delete landed and ci.yml still invokes this filename.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ ! -f "$repo_root/lib/litellm-seat.sh" ]] \
  || { grep -q 'litellm_seat()' "$repo_root/lib/litellm-seat.sh" && fail "routing library still defines pick-seat"; true; }
ok "routing library no longer defines pick-seat"

ci_yml="$repo_root/.github/workflows/ci.yml"
grep -Fq 'bash tests/seatlib-degraded.test.sh' "$ci_yml" \
  || fail "ci.yml verify-command must still run tests/seatlib-degraded.test.sh"
ok "ci.yml still invokes this filename"
