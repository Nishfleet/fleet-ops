#!/usr/bin/env bash
# tests/fleet-seat-recovery-units.test.sh
#
# fleet-ops#5106: the seats ledger is written every ~2s (every seat-health
# extension update), and fleet-seat-recovery.path's PathChanged on the
# DIRECTORY fired fleet-seat-recovery.service on every write — measured
# 2419 service starts in one hour (2026-09-10 judge run), which was the
# top line of the unit-churn report while the box idled at sy=16%.
#
# The fix is an ACTIVATION HOLD, not a trigger limit. fleet-seat-recovery
# .service carries ExecStartPost=/bin/sleep <hold>: after the bin exits the
# unit lingers in start-post, so PathChanged events inside the window
# enqueue start jobs that merge into the in-flight job instead of spawning
# new activations (proven live 2026-09-11: 16 trigger writes over 8s ->
# 2 starts, .path stays active/success). Max rate ~3600/hold per hour; the
# triggering write's own transition is still processed immediately because
# the bin runs BEFORE the hold.
#
# What this test proves:
#   1. fleet-seat-recovery.service carries the activation hold
#      (ExecStartPost=/bin/sleep N, 20<=N<=30 — N>=20 keeps the storm under
#      the 200/h acceptance; N<=30 keeps a mid-hold transition inside the
#      issue's 30s recovery bound given the ~2s ledger cadence).
#   2. fleet-seat-recovery.path carries NO TriggerLimit*: on systemd 255 a
#      hit places the .path unit into "trigger-limit-hit" failure and it
#      stops watching until restarted — the #617 watcher-dead wedge, not a
#      debounce (proven live: second write inside the window -> failed).
#   3. No StartLimit* anywhere in the service: the hold makes the stock
#      5-per-10s structurally unreachable, so the #617 (disabled) and #622
#      (1h/2000) accommodations are undone. If the hold regresses, the
#      default limit wedges the oneshot -> propagates to the .path ->
#      OnFailure -> senior auditor. Loud, by design.
#   4. systemd-analyze verify accepts both unit files (syntax+directives).
#
# The LIVE wedge/coalescing drill moved to bin/fleet-resilience-drill
# (plane seat_recovery_coalesce) so the throwaway units fire at the daily
# fleet-resilience-drill.timer cadence only — a repo test run no longer
# installs user-systemd units (fleet-ops#5106 do#3; the 451/h
# fleet-seat-recovery-drill churn was test runs). This file is read-only
# against the repo and the box.
#
# Invoked from tests/fleet-seat-recovery.test.sh (p14-test-listing-gate:
# transitively invoked from a listed test).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

svc_unit="$repo_root/systemd/fleet-seat-recovery.service"
path_unit="$repo_root/systemd/fleet-seat-recovery.path"
[[ -f "$svc_unit" ]] || fail "missing: $svc_unit"
[[ -f "$path_unit" ]] || fail "missing: $path_unit"

# --- 1. activation hold in [Service] -----------------------------------------
# The hold is the whole fix: without an ExecStartPost sleep the oneshot is
# dead ~29ms after each trigger and every seats/ write spawns a real
# activation. With it, writes inside the window merge into the in-flight job.
svc_section=$(awk '/^\[Service\]/{f=1} /^\[/{if(f&&$0!~/^\[Service\]/)f=0} f' "$svc_unit")
[[ -n "$svc_section" ]] || fail "no [Service] section in $svc_unit"
hold=$(echo "$svc_section" | sed -nE 's/^ExecStartPost=\/bin\/sleep ([0-9]+)$/\1/p')
[[ -n "$hold" ]] \
  || fail "ExecStartPost=/bin/sleep <N> missing from [Service] in $svc_unit (activation hold is the #5106 coalescing mechanism)"
(( hold >= 20 && hold <= 30 )) \
  || fail "ExecStartPost hold=${hold}s out of range: >=20 keeps storm <200/h, <=30 keeps mid-hold transitions inside the 30s recovery bound"
ok "fleet-seat-recovery.service carries ExecStartPost=/bin/sleep ${hold} activation hold (<= ~$((3600 / hold)) starts/h under a write storm)"

# --- 2. no TriggerLimit* in the .path (the wedge trap) ------------------------
# systemd.path(5) on 255: "If the limit is hit, the unit is placed into a
# failure mode, and will not watch the paths anymore until restarted."
# TriggerLimitBurst=1/30s on a dir written every ~2s wedges the watcher in
# seconds (proven live 2026-09-11: Result=trigger-limit-hit, OnFailure
# fired). This is a failure-mode lock, not a style preference.
path_section=$(awk '/^\[Path\]/{f=1} /^\[/{if(f&&$0!~/^\[Path\]/)f=0} f' "$path_unit")
[[ -n "$path_section" ]] || fail "no [Path] section in $path_unit"
if echo "$path_section" | grep -qE '^TriggerLimit'; then
  fail "TriggerLimit* in [Path] of $path_unit wedges the watcher on systemd 255 (trigger-limit-hit) — coalescing belongs in the service's activation hold"
fi
echo "$path_section" | grep -qE '^PathChanged=/home/nish/workspaces/agent-state/lanes/seats$' \
  || fail "PathChanged= seats dir missing from [Path] in $path_unit (must stay event-driven, fleet-ops#5106 must-not)"
echo "$path_section" | grep -qE '^Unit=fleet-seat-recovery.service$' \
  || fail "Unit=fleet-seat-recovery.service missing from [Path] in $path_unit"
ok "fleet-seat-recovery.path: no TriggerLimit* (wedge trap locked out), still event-driven on seats/"

# --- 3. no StartLimit* accommodation left in the service ----------------------
# With the hold, every activation occupies >=20s, so even the stock 5-per-10s
# default can never be reached by the seats/ write storm — or by anything
# else; the path unit is the only activator. The #617 (StartLimitIntervalSec=0)
# and #622 (1h/2000) accommodations are therefore REMOVED: a hold regression
# must trip the default and page an auditor, not storm silently.
if grep -qE '^StartLimit' "$svc_unit"; then
  fail "StartLimit* present in $svc_unit — the #5106 hold makes it unreachable; the accommodation is undone, not raised"
fi
ok "no StartLimit* accommodation in fleet-seat-recovery.service (stock 5/10s is structurally unreachable at >=20s activation spacing)"

# --- 4. systemd-analyze verify accepts both unit files -----------------------
# Same convention as tests/escalation-units-shape.test.sh. The CI unit-verify
# job already verifies systemd/*.service, but it does NOT verify .path files
# directly — this does. The service ExecStart points at a VPS-only bin
# (/home/nish/.local/bin/fleet-seat-recovery) that does not exist on hosted
# CI runners (only the separate systemd-analyze job stubs it). Plain
# systemd-analyze verify needs that bin present, and --root verify needs a
# full systemd target tree that a unit test should not build. So: run the
# plain verify when the bin exists (VPS), else SKIP with a named reason —
# the dedicated unit-verify CI job is the syntax gate on hosted runners
# (fleet-ops#154 / #867 / #884).
#
# fleet-ops#884: this SKIP block is the fix for the P14 hosted-CI failure
#   FAIL: systemd-analyze verify failed for fleet-seat-recovery.service:
#   fleet-seat-recovery.service: Command /home/nish/.local/bin/fleet-seat-recovery
#   is not executable: No such file or directory
# reported against CI run 33037937469 on main. Regression-locked by
# tests/p14-unstubbed-unit-verify.test.sh step 4c (the SKIP block must
# emit the named reason; a future edit that strips the SKIP and re-runs
# verify unconditionally red-fails this lock, not hosted CI).
if command -v systemd-analyze >/dev/null 2>&1; then
  if [[ -x /home/nish/.local/bin/fleet-seat-recovery ]]; then
    for f in "$svc_unit" "$path_unit"; do
      if ! out=$(systemd-analyze verify --man=no "$f" 2>&1); then
        fail "systemd-analyze verify failed for $(basename "$f"): $out"
      fi
    done
    ok "systemd-analyze verify accepts fleet-seat-recovery.{service,path}"
  else
    echo "SKIP: fleet-seat-recovery bin absent (hosted CI) — unit-verify CI job is the syntax gate"
  fi
else
  echo "SKIP: systemd-analyze not on PATH (unit verify)"
fi

echo "OK: fleet-seat-recovery-units: activation hold + no trigger-limit + no start-limit accommodation + verify"
