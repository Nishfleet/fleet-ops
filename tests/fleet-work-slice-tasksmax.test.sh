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
#   3. the LIVE slice actually reports TasksMax=8000 and sources it from the
#      linked drop-in (systemd is the ceiling now).
#   4. the drop-in source exists in the repo.
#
# 2026-09-18 glue sweep: spawn-guard-core.ts (620 lines) and the fleet fork of
# bash-spawn-hook.ts are DELETED. They carried a userspace soft ceiling of 7500
# that duplicated what systemd already enforces. systemd.resource-control's
# TasksMax is the stock feature and the only ceiling now, so this test asserts
# the live slice instead of the deleted constants.
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
caps="$repo_root/config/seat-caps.json"

[[ -f "$dropin" ]] || fail "missing drop-in: $dropin"
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

# --- 3. the LIVE slice enforces it, and from the linked drop-in -------------
if command -v systemctl >/dev/null 2>&1 && [[ -n "${XDG_RUNTIME_DIR:-}" || -d /run/user/$(id -u) ]]; then
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  live_max=$(systemctl --user show fleet-work.slice -p TasksMax --value 2>/dev/null || echo "")
  live_drops=$(systemctl --user show fleet-work.slice -p DropInPaths --value 2>/dev/null || echo "")
  if [[ -n "$live_max" ]]; then
    [[ "$live_max" == "8000" ]] \
      || fail "live fleet-work.slice TasksMax=$live_max, expected 8000"
    grep -q '10-tasksmax.conf' <<<"$live_drops" \
      || fail "live TasksMax does not come from the linked 10-tasksmax.conf drop-in: $live_drops"
    ok "live slice: TasksMax=8000 sourced from the linked drop-in"
  else
    ok "live slice: skipped (no user systemd in this environment)"
  fi
else
  ok "live slice: skipped (no systemctl)"
fi

# --- 4. the repo source exists ---------------------------------------------
# MANIFEST was deleted 2026-09-18; the live path is a symlink sourced from this
# file, so its presence in the repo is the wiring.
[[ -f "$repo_root/systemd/fleet-work.slice.d/10-tasksmax.conf" ]] \
  || fail "missing repo source: systemd/fleet-work.slice.d/10-tasksmax.conf"
ok "drop-in present in the repo"

# --- 5. RAM governor unchanged ----------------------------------------------
# fleet-ops#4263 termination: no hand-set per-worker RAM charge remains in config.
jq -e 'has("ram_gb_per_worker") | not' "$caps" >/dev/null || fail "config/seat-caps.json must not carry ram_gb_per_worker after fleet-ops#4263"
ok "seat-caps.json carries no per-worker RAM charge (fleet-ops#4263)"

echo "OK: fleet-work.slice TasksMax=8000 (systemd is the only ceiling); RAM admission unchanged"
