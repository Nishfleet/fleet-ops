#!/usr/bin/env bash
# tests/blocked-reconcile-large-issue-json.test.sh
#
# Proves the agent-blocked reconciler survives a hot issue (fleet-ops#4572).
#
# `latest_live_blocked_on_ts` used to hand the whole `gh issue view` JSON —
# body plus EVERY comment — to python3 as argv[1]. Linux caps a single argv
# string at MAX_ARG_STRLEN (131072 bytes) no matter how large ARG_MAX is, so
# any issue whose JSON crossed 128 KiB killed the sweep with
# "Argument list too long". The sweep aborts, so NO dependent gets released.
#
# Observed 2026-09-08: Nishfleet/0509#1384 carried an 846,655-byte JSON. It
# sat agent-blocked behind #1383 for hours after #1383 had already CLOSED,
# starving the claimable pool to zero workers.
#
# The regression: a >128 KiB issue JSON must still yield its blocked-on
# timestamp instead of crashing.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/blocked-reconcile"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$bin" ]] || fail "missing: $bin"

# Load just the function under test, without running the sweep.
start="$(grep -n '^latest_live_blocked_on_ts() {' "$bin" | head -1 | cut -d: -f1)"
[[ -n "$start" ]] || fail "latest_live_blocked_on_ts not found in $bin"
end="$(awk -v s="$start" 'NR>s && /^}$/ {print NR; exit}' "$bin")"
[[ -n "$end" ]] || fail "could not find end of latest_live_blocked_on_ts"
# shellcheck disable=SC1090
source <(sed -n "${start},${end}p" "$bin")

# A comment padded past MAX_ARG_STRLEN, mirroring an issue the audit panel
# re-commented on hundreds of times.
view_json="$(python3 - <<'PY'
import json
pad = "padding line to grow the JSON. " * 6000
issue = {
    "number": 1384,
    "createdAt": "2026-09-01T00:00:00Z",
    "body": "blocked-on: infra\nsome body text\n",
    "comments": [
        {"createdAt": "2026-09-02T00:00:00Z", "body": pad},
        {"createdAt": "2026-09-03T00:00:00Z", "body": "blocked-on: infra\n" + pad},
    ],
}
print(json.dumps(issue))
PY
)"

size="$(printf '%s' "$view_json" | wc -c)"
(( size > 131072 )) || fail "fixture too small ($size bytes); must exceed MAX_ARG_STRLEN 131072"
ok "fixture is $size bytes (> 131072 MAX_ARG_STRLEN)"

set +e
got="$(latest_live_blocked_on_ts "$view_json" "infra" 2>&1)"
rc=$?
set -e

case "$got" in
    *"Argument list too long"*)
        fail "argv overflow returned: $got — the sweep dies and releases nothing"
        ;;
esac
(( rc == 0 )) || fail "non-zero exit ($rc) on a large issue JSON: $got"
[[ "$got" == "2026-09-03T00:00:00Z" ]] \
    || fail "expected latest live blocked-on ts 2026-09-03T00:00:00Z, got '$got'"
ok "large issue JSON yields the latest live blocked-on timestamp"

# A struck-through marker on a large issue must still be ignored.
view_struck="$(python3 - <<'PY'
import json
pad = "padding line to grow the JSON. " * 6000
issue = {
    "number": 1385,
    "createdAt": "2026-09-01T00:00:00Z",
    "body": "~~blocked-on: infra~~\n" + pad,
    "comments": [{"createdAt": "2026-09-02T00:00:00Z", "body": pad}],
}
print(json.dumps(issue))
PY
)"
(( $(printf '%s' "$view_struck" | wc -c) > 131072 )) || fail "struck fixture too small"
got_struck="$(latest_live_blocked_on_ts "$view_struck" "infra" 2>&1)"
[[ -z "$got_struck" ]] || fail "struck-through blocked-on must yield empty, got '$got_struck'"
ok "struck-through blocked-on still ignored on a large issue JSON"

# No temp files left behind.
leaked="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'blocked-reconcile-view.*' 2>/dev/null | wc -l)"
(( leaked == 0 )) || fail "leaked $leaked temp view file(s)"
ok "no temp view files leaked"

echo "PASS: blocked-reconcile-large-issue-json"
