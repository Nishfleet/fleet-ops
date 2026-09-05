#!/usr/bin/env bash
# The console parses UTC observed_at strings; on an IST host time.mktime() read every fresh seat observation as 19800s old
# and rendered PI WORK as UNKNOWN forever (2026-09-05). Pin: no mktime-on-strptime in the console; timegm only.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; repo_root="$(cd "$here/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }; ok() { echo "OK: $*"; }
g="$repo_root/libexec/fleet-console-pi/generate.py"
! grep -q 'time.mktime(time.strptime(' "$g" || fail "generate.py must not parse UTC strings with time.mktime (local-time bug); use calendar.timegm"
grep -q 'calendar.timegm(time.strptime(' "$g" || fail "generate.py must parse observed_at with calendar.timegm"
TZ=Asia/Kolkata python3 - "$g" <<'PY' || fail "UTC parse must be timezone-independent"
import sys, time, calendar
raw = "2026-09-05T07:49:16.055Z"
t = time.strptime(raw.replace("Z", "+00:00")[:19], "%Y-%m-%dT%H:%M:%S")
assert calendar.timegm(t) == 1788594556, calendar.timegm(t)
PY
ok "console parses UTC observed_at with timegm (no IST offset)"
echo "PASS: fleet-console-pi-utc"
