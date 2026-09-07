#!/usr/bin/env bash
# tests/fleet-prepaid-util-canary.test.sh
# fleet-ops#4263 P3b: hosted by escalation-coverage-canary.test.sh.
# Prepaid pick counters are gone; the canary is a no-op exit 0.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-prepaid-util-canary"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
set +e
"$bin" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "retired prepaid-util canary must exit 0, got $rc"
grep -F 'fleet-prepaid-util-canary' "$tier1" >/dev/null \
  || fail "tier1 must still invoke fleet-prepaid-util-canary"
ok "prepaid-util canary retired (exit 0); heartbeat still invokes it"
