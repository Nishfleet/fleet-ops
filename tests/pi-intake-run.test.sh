#!/usr/bin/env bash
# tests/pi-intake-run.test.sh
#
# Proves overlapping intake ticks no-op instead of racing.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/pi-intake-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

lockdir="$(mktemp -d)"
marker="$(mktemp)"
trap 'rm -rf "$lockdir"; rm -f "$marker"' EXIT

export PI_INTAKE_LOCKDIR="$lockdir"
# First tick holds the lock for ~2s and writes a marker.
export PI_INTAKE_CMD="echo first >>'$marker'; sleep 2"

"$bin" tesrepo >/tmp/pi-intake-run-first.out 2>&1 &
first_pid=$!
sleep 0.3

# Second tick must no-op while the first holds the lock.
set +e
export PI_INTAKE_CMD="echo second >>'$marker'"
out="$("$bin" tesrepo 2>&1)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "overlap must exit 0, got $rc ($out)"
printf '%s\n' "$out" | grep -q 'no-op' || fail "overlap must print no-op, got: $out"

wait "$first_pid" || fail "first tick failed"

# Marker must contain only the first tick's write.
got="$(cat "$marker")"
[[ "$got" == "first" ]] || fail "second tick must not run the body, marker='$got'"
ok "overlapping intake tick is a no-op"

# After the lock is released, a later tick must run.
export PI_INTAKE_CMD="echo third >>'$marker'"
"$bin" tesrepo >/dev/null
got="$(cat "$marker")"
[[ "$got" == $'first\nthird' ]] || fail "later tick should run after lock release, marker='$got'"
ok "later tick runs after lock release"
