#!/usr/bin/env bash
# tests/issue-file-gh-rate-limit-gate.test.sh
#
# fleet-ops#1350 canon (sibling of tests/pi-intake-gh-rate-limit.test.sh):
# pin the GitHub rate-limit filing gate in lib/issue-file.py.
#
# Proves, offline:
#   1. When the exporter side-car says low=1 and is FRESH, `file` defers
#      (exit 3) with a loud stderr line and makes NO gh call.
#   2. When the side-car is STALE (> 360s), the gate fails open: `file`
#      proceeds to the normal path (which fails on the stub gh) and never
#      prints the defer line.
#   3. When low=0 (or the side-car is missing), `file` proceeds normally.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
issue_file="$repo_root/lib/issue-file.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$issue_file" ]] || fail "issue-file.py missing: $issue_file"
python3 - "$issue_file" <<'PY' || fail "issue-file.py does not parse"
import sys, py_compile
py_compile.compile(sys.argv[1], doraise=True)
PY

scratch="$(mktemp -d -t ifgrl-gate.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

now=$(python3 -c 'import time; print(time.time())')

# --- case 1: fresh low=1 -> defer (rc=3), loud stderr, no gh call ----------
sidecar="$scratch/low-fresh.json"
python3 - "$sidecar" "$now" <<'PY'
import json, sys
path, now = sys.argv[1], float(sys.argv[2])
json.dump({"low": 1, "remaining": 0, "limit": 5000, "reset": now + 900,
           "fetched_at": now - 30}, open(path, "w"))
PY
out=$(FLEET_ISSUE_FILE_GH_RATE_LIMIT_STATE="$sidecar" GH="$scratch/no-gh" \
    python3 "$issue_file" file -R Nishfleet/fleet-ops \
    --title "gate test" --body "body" 2>&1) && rc=0 || rc=$?
[[ "$rc" == "3" ]] || fail "fresh low=1 must exit 3, got rc=$rc out=$out"
grep -q "gh rate-limit low" <<<"$out" || fail "defer must log the gate line, out=$out"
[[ "$out" != *"no-gh"* ]] || fail "gate must fire before any gh call"
ok "case 1: fresh low=1 defers with rc=3 and no gh call"

# --- case 2: stale low=1 -> fail open (no defer line, normal failure) ------
sidecar="$scratch/low-stale.json"
python3 - "$sidecar" "$now" <<'PY'
import json, sys
path, now = sys.argv[1], float(sys.argv[2])
json.dump({"low": 1, "remaining": 0, "limit": 5000, "reset": now + 900,
           "fetched_at": now - 400}, open(path, "w"))
PY
stub_gh="$scratch/gh-stub"
printf '#!/usr/bin/env bash\nexit 1\n' >"$stub_gh"
chmod +x "$stub_gh"
out=$(FLEET_ISSUE_FILE_GH_RATE_LIMIT_STATE="$sidecar" GH="$stub_gh" \
    python3 "$issue_file" file -R Nishfleet/fleet-ops \
    --title "gate test" --body "body" 2>&1) && rc=0 || rc=$?
[[ "$rc" != "3" ]] || fail "stale side-car must fail open, not defer"
grep -q "gh rate-limit low" <<<"$out" && fail "stale side-car must not log the defer line: $out"
ok "case 2: stale low=1 fails open (rc=$rc, no defer line)"

# --- case 3: low=0 fresh -> proceed -----------------------------------------
sidecar="$scratch/high.json"
python3 - "$sidecar" "$now" <<'PY'
import json, sys
path, now = sys.argv[1], float(sys.argv[2])
json.dump({"low": 0, "remaining": 4914, "limit": 5000, "reset": now + 1800,
           "fetched_at": now - 30}, open(path, "w"))
PY
out=$(FLEET_ISSUE_FILE_GH_RATE_LIMIT_STATE="$sidecar" GH="$stub_gh" \
    python3 "$issue_file" file -R Nishfleet/fleet-ops \
    --title "gate test" --body "body" 2>&1) && rc=0 || rc=$?
[[ "$rc" != "3" ]] || fail "low=0 must not defer"
ok "case 3: low=0 proceeds (rc=$rc)"

# --- case 4: missing side-car -> proceed ------------------------------------
out=$(FLEET_ISSUE_FILE_GH_RATE_LIMIT_STATE="$scratch/absent.json" GH="$stub_gh" \
    python3 "$issue_file" file -R Nishfleet/fleet-ops \
    --title "gate test" --body "body" 2>&1) && rc=0 || rc=$?
[[ "$rc" != "3" ]] || fail "missing side-car must fail open"
ok "case 4: missing side-car proceeds (rc=$rc)"

echo "all issue-file gh-rate-limit gate cases passed"
