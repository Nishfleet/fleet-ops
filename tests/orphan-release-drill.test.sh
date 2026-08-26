#!/usr/bin/env bash
# tests/orphan-release-drill.test.sh
#
# fleet-ops#222 / #180 detector drill. Locks the shape of bin/orphan-release-drill
# and proves it releases ALL THREE orphan shapes in one tick (count matches),
# the way the gap-closure loop (#180) requires one fault-injection proof per
# detector touched.
#
# The drill runs the EXACT production release function (lib/orphan-release.sh,
# sourced by fleet-heartbeat-tier1 §3) against stub units + a fake gh, so this
# test is the end-to-end "today's four-issue scenario reproduced with stubs ->
# all released in one tick, orphan_released count matches" acceptance gate.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

drill="$repo_root/bin/orphan-release-drill"
worker_lib="$repo_root/lib/worker-live.sh"
orphan_lib="$repo_root/lib/orphan-release.sh"
manifest="$repo_root/MANIFEST"
[[ -x "$drill" ]] || fail "not executable: $drill"
[[ -f "$worker_lib" ]] || fail "missing lib/worker-live.sh"
[[ -f "$orphan_lib" ]] || fail "missing lib/orphan-release.sh"
bash -n "$drill" || fail "orphan-release-drill: bash syntax error"
bash -n "$orphan_lib" || fail "orphan-release.sh: bash syntax error"

# 1. The drill sources the PRODUCTION libs (not a re-implementation).
grep -F 'lib/worker-live.sh' "$drill" >/dev/null \
  || fail "drill must source lib/worker-live.sh (the production live-check)"
grep -F 'lib/orphan-release.sh' "$drill" >/dev/null \
  || fail "drill must source lib/orphan-release.sh (the production release fn)"
grep -F 'orphan_release_for_issue' "$drill" >/dev/null \
  || fail "drill must call orphan_release_for_issue (the production release fn)"
ok "drill runs the production release path (no re-implementation)"

# 2. The drill manufactures all three shapes.
grep -F 'shape (a)' "$drill" >/dev/null || fail "drill must name shape (a)"
grep -F 'shape (b)' "$drill" >/dev/null || fail "drill must name shape (b)"
grep -F 'shape (c)' "$drill" >/dev/null || fail "drill must name shape (c)"
grep -F 'auto-restart' "$drill" >/dev/null || fail "drill must manufacture an auto-restart shape"
ok "drill manufactures all three orphan shapes (a/b/c)"

# 3. --check succeeds (libs + jq present).
out="$("$drill" --check 2>&1)" || fail "--check should succeed, got: $out"
printf '%s\n' "$out" | grep -q 'prerequisites ok' || fail "--check must log prerequisites ok: $out"
ok "--check passes"

# 4. The drill releases all three in one tick (the acceptance gate).
out="$("$drill" 2>&1)" || fail "drill should exit 0, got: $out"
printf '%s\n' "$out" | grep -q 'released: 3 / 3' \
  || fail "drill must report released: 3 / 3, got: $out"
printf '%s\n' "$out" | grep -q 'shape (a) #146: branch deleted, label flipped -> OK' \
  || fail "drill must prove shape (a) released: $out"
printf '%s\n' "$out" | grep -q 'shape (b) #152: no branch (already reaped), label flipped -> OK' \
  || fail "drill must prove shape (b) released: $out"
printf '%s\n' "$out" | grep -q 'shape (c) #157: unit stopped, branch deleted, label flipped -> OK' \
  || fail "drill must prove shape (c) released (unit stopped): $out"
printf '%s\n' "$out" | grep -q 'label flips recorded: 3 (matches released count)' \
  || fail "drill must prove the released count matches the label-flip count: $out"
# Shape (c) must STOP the unit (so intake's pi-issue-start can re-dispatch).
printf '%s\n' "$out" | grep -q 'stopped auto-restarting unit' \
  || fail "drill must stop the auto-restarting unit (fleet-ops#222): $out"
ok "drill releases 3/3 orphan shapes in one tick; count matches; shape (c) unit stopped"

# 5. MANIFEST installs the drill + libs.
grep -Fxq "bin/orphan-release-drill /home/nish/.local/bin/orphan-release-drill" "$manifest" \
  || fail "MANIFEST missing bin/orphan-release-drill"
grep -Fxq "lib/worker-live.sh /home/nish/.local/lib/pi-packet/worker-live.sh" "$manifest" \
  || fail "MANIFEST missing lib/worker-live.sh"
grep -Fxq "lib/orphan-release.sh /home/nish/.local/lib/pi-packet/orphan-release.sh" "$manifest" \
  || fail "MANIFEST missing lib/orphan-release.sh"
ok "MANIFEST installs drill + shared libs"

# 6. Bad flag refused.
set +e; err="$("$drill" --bogus 2>&1)"; rc=$?; set -e
[[ "$rc" -eq 1 ]] || fail "bad flag must exit 1, got $rc ($err)"
ok "unknown flag refused"

echo "OK: orphan-release-drill shape + 3-shape release proof locked"
