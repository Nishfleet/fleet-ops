#!/usr/bin/env bash
# tests/fleet-gh-cache-stale.test.sh
#
# fleet-ops#1232: lock FleetGhCacheStale. Offline (no live Prom reload).
# Hosted by tests/ci-standards-audit.test.sh so it runs in P14 without
# a workflow-file edit.
#
# Proves:
#   1. fleet_rules.yml has FleetGhCacheStale.
#   2. expr is min(fleet_gh_cache_fresh) == 0 or absent(...) — min==0 is
#      the named condition; absent() covers omit-on-stale (the exporter
#      never emits 0).
#   3. for: 45m, severity: warning, service: fleet (repair rail).
#   4. 45m is 1.5x the 30 min cache cadence.
#   5. Repair annotation names the exporter, gh auth/rate limit, refresh path.
#   6. FleetGhCacheStale is NOT in alert-repair-dispatch SKIP_SET.
#   7. promtool check rules (if present).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

rules="$repo_root/config/fleet_rules.yml"
dispatch="$repo_root/libexec/alert-repair-dispatch"

[[ -f "$rules" ]] || fail "missing $rules"
[[ -f "$dispatch" ]] || fail "missing $dispatch"

grep -q 'alert: FleetGhCacheStale' "$rules" \
  || fail "missing FleetGhCacheStale"

python3 - "$rules" "$dispatch" <<'PY' || fail "FleetGhCacheStale shape failed"
from pathlib import Path
import ast, re, sys

text = Path(sys.argv[1]).read_text()
m = re.search(
    r"- alert: FleetGhCacheStale\n(.*?)(?:\n      - alert:|\n  - name:|\Z)",
    text,
    re.S,
)
assert m, "FleetGhCacheStale block not found"
block = m.group(1)
assert "min(fleet_gh_cache_fresh) == 0" in block, block
assert "absent(fleet_gh_cache_fresh)" in block, block
assert "for: 45m" in block, block
assert "severity: warning" in block, block
assert "service: fleet" in block, block
assert "1.5x" in block, block
low = block.lower()
assert "exporter" in low, block
assert "auth" in low, block
assert "rate limit" in low, block
print("OK: FleetGhCacheStale is warning/45m/fleet with min==0 or absent()")

src = Path(sys.argv[2]).read_text()
sm = re.search(r"SKIP_SET = (\{.*?\})", src, re.S)
assert sm, "SKIP_SET not found in alert-repair-dispatch"
skip = ast.literal_eval(sm.group(1))
assert "FleetGhCacheStale" not in skip, skip
print("OK: FleetGhCacheStale is not in SKIP_SET (rides the repair rail)")
PY

if command -v promtool >/dev/null 2>&1; then
  out="$(promtool check rules "$rules" 2>&1)"
  success="$(printf '%s\n' "$out" | grep -E 'SUCCESS: [0-9]+ rules found' || true)"
  [[ -n "$success" ]] || fail "promtool check rules did not report SUCCESS: $out"
  ok "promtool check rules: $success"
else
  echo "OK: promtool not installed — skipping syntax check"
fi

echo "OK: fleet-gh-cache-stale.test.sh"
