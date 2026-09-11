#!/usr/bin/env bash
# tests/fleet-work-slice-tasksmax.test.sh
#
# fleet-ops#3280: raise fleet-work.slice TasksMax to 8000 and the spawn-guard
# soft/hard pair to 7500/8000. The measured reason is 11 threads per idle pi
# (2026-09-04 07:50Z). RAM governor (MemAvailable, ram_gb_per_worker) stays the
# admission authority — this lock proves the ceiling moved and admission did
# not.
#
# Battle-tested tool: systemd TasksMax= (man systemd.resource-control). The
# drop-in already existed live at ~/.config/systemd/user/fleet-work.slice.d/
# 10-tasksmax.conf; this PR repo-izes it and the spawn-guard constants so
# deploy cannot drift them apart.
#
# Invariants:
#   1. Drop-in exists, [Slice], TasksMax=8000, no CPUQuota.
#   2. Comment names 11 threads per pi and that RAM remains admission.
#   3. spawn-guard-core.ts FLEET_SLICE_TASKS_MAX=8000,
#      FLEET_SPAWN_SOFT_CEILING=7500; bash-spawn-hook interpolates those
#      constants (no hardcoded 2800/3000).
#   4. MANIFEST installs drop-in + both extension files.
#   5. seat-caps.json ram_gb_per_worker is the interim admission charge (1.5;
#      fleet-ops#4896 after #4893 dropped in-worker coverage/tsc; remeasure-4891
#      replaces this with measured p95 on 2026-09-11).
#
# Lock-and-leave. Offline. Hosted from tests/system-dropins-shape.test.sh
# so P14 runs it without a workflow-file edit.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

dropin="$repo_root/systemd/fleet-work.slice.d/10-tasksmax.conf"
core="$repo_root/template/extensions/spawn-guard-core.ts"
hook="$repo_root/template/extensions/bash-spawn-hook.ts"
manifest="$repo_root/MANIFEST"
caps="$repo_root/config/seat-caps.json"

[[ -f "$dropin" ]] || fail "missing drop-in: $dropin"
[[ -f "$core" ]] || fail "missing spawn-guard-core.ts: $core"
[[ -f "$hook" ]] || fail "missing bash-spawn-hook.ts: $hook"
[[ -f "$manifest" ]] || fail "missing MANIFEST"
[[ -f "$caps" ]] || fail "missing seat-caps.json"

# --- 1. drop-in shape -------------------------------------------------------
grep -q '^\[Slice\]$' "$dropin" || fail "10-tasksmax.conf: missing [Slice]"
grep -q '^TasksMax=8000$' "$dropin" \
  || fail "10-tasksmax.conf: TasksMax=8000 must be set"
if grep -q '^CPUQuota=' "$dropin"; then
  fail "10-tasksmax.conf must not set CPUQuota (CPU stays on weights)"
fi
if grep -q '^TasksMax=3000$' "$dropin"; then
  fail "10-tasksmax.conf reintroduced TasksMax=3000"
fi
ok "drop-in: [Slice] TasksMax=8000, no CPUQuota"

# --- 2. measured 11-threads-per-pi reason + RAM stays admission --------------
grep -q '11 thread' "$dropin" \
  || fail "10-tasksmax.conf comment must name the measured 11-threads-per-pi reason"
grep -qi 'ram_gb_per_worker' "$dropin" \
  || fail "10-tasksmax.conf comment must name ram_gb_per_worker as admission authority"
grep -qi 'MemAvailable' "$dropin" \
  || fail "10-tasksmax.conf comment must name MemAvailable as admission authority"
ok "drop-in comment: 11 threads/pi; RAM remains admission"

# --- 3. spawn-guard constants + EXTLOAD interpolates them -------------------
grep -q '^export const FLEET_SLICE_TASKS_MAX = 8000;$' "$core" \
  || fail "spawn-guard-core.ts: FLEET_SLICE_TASKS_MAX must be 8000"
grep -q '^export const FLEET_SPAWN_SOFT_CEILING = 7500;$' "$core" \
  || fail "spawn-guard-core.ts: FLEET_SPAWN_SOFT_CEILING must be 7500"
if grep -qE 'FLEET_SLICE_TASKS_MAX = 3000' "$core"; then
  fail "spawn-guard-core.ts reintroduced FLEET_SLICE_TASKS_MAX = 3000"
fi
if grep -qE 'FLEET_SPAWN_SOFT_CEILING = 2800' "$core"; then
  fail "spawn-guard-core.ts reintroduced FLEET_SPAWN_SOFT_CEILING = 2800"
fi
grep -q 'FLEET_SPAWN_SOFT_CEILING' "$hook" \
  || fail "bash-spawn-hook.ts must interpolate FLEET_SPAWN_SOFT_CEILING"
grep -q 'FLEET_SLICE_TASKS_MAX' "$hook" \
  || fail "bash-spawn-hook.ts must interpolate FLEET_SLICE_TASKS_MAX"
if grep -q 'ceiling=2800/3000' "$hook"; then
  fail "bash-spawn-hook.ts still hardcodes ceiling=2800/3000"
fi
ok "spawn-guard: 8000/7500; EXTLOAD interpolates constants"

# --- 4. MANIFEST exact dests -----------------------------------------------
drop_line="systemd/fleet-work.slice.d/10-tasksmax.conf /home/nish/.config/systemd/user/fleet-work.slice.d/10-tasksmax.conf"
core_line="template/extensions/spawn-guard-core.ts /home/nish/.pi/agent/extensions/spawn-guard-core.ts"
hook_line="template/extensions/bash-spawn-hook.ts /home/nish/.pi/agent/extensions/bash-spawn-hook.ts"
grep -Fxq "$drop_line" "$manifest" || fail "MANIFEST missing: $drop_line"
grep -Fxq "$core_line" "$manifest" || fail "MANIFEST missing: $core_line"
grep -Fxq "$hook_line" "$manifest" || fail "MANIFEST missing: $hook_line"
ok "MANIFEST installs drop-in + spawn-guard-core + bash-spawn-hook"

# --- 5. RAM governor unchanged ----------------------------------------------
ram=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ram_gb_per_worker"])' "$caps")
# 1.5 = the interim charge (fleet-ops#4896, 2026-09-10): the 2.0 p50 was
# measured on workers running vitest --coverage forks + tsc -b locally;
# fleet-ops#4893 forbids both in-worker and 0509#2534 makes npm test
# coverage-free, so the old p50 no longer describes new workers. The
# remeasure-4891 timer (2026-09-11 14:05Z) replaces 1.5 with the measured
# p95 either way. Moving this pin needs a new measurement in the same PR.
[[ "$ram" == "1.0" ]] || fail "ram_gb_per_worker must be 1.0 (admission authority: Nish 2026-09-11 "DO IT NOW", fleet-ops#5495; was the #4896 interim 1.5); got '$ram'"
ok "seat-caps.json ram_gb_per_worker is 1.0 (Nish 2026-09-11)"

echo "OK: fleet-work.slice TasksMax=8000; spawn-guard 7500/8000; RAM admission unchanged"
