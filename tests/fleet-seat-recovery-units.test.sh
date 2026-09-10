#!/usr/bin/env bash
# tests/fleet-seat-recovery-units.test.sh
#
# fleet-ops#622: fleet-seat-recovery.path fails to start (unit-start-limit-hit).
# The seats ledger is written every few seconds (every seat-health extension
# update), so fleet-seat-recovery.path fires fleet-seat-recovery.service
# ~30x/min. The DEFAULT StartLimitBurst=5 / StartLimitIntervalSec=10s is blown
# through in well under a minute of normal fleet traffic, which wedges BOTH
# the service AND the .path unit with unit-start-limit-hit (proven live
# 2026-08-27: the path unit went inactive/failed 12min after start). The bin's
# own FLEET_SEAT_RECOVERY_COOLDOWN (default 120s) is the real rate-limiter for
# the side effect (the intake fire); the systemd start limit only needs to
# tolerate the no-op trigger storm, not gate the fire.
#
# This test is split from tests/fleet-seat-recovery.test.sh (which exercises
# the bin's transition/cooldown logic) so the unit-shape + live wedge-recovery
# assertions run independently of the bin test. It is invoked from the listed
# tests/fleet-seat-recovery.test.sh (p14-test-listing-gate: transitively
# invoked from a listed test).
#
# What we prove:
#   1. fleet-seat-recovery.service disables systemd start rate limiting
#      (StartLimitIntervalSec=0 in [Unit]) and carries NO bounded
#      StartLimitBurst, so a trigger storm cannot wedge the fast path.
#      fleet-ops#5024 in-bin debounce cuts CPU on last=usable; PathChanged
#      still starts the oneshot on every seats/ write, so the activation rate
#      tracks an unbounded write rate and no fixed burst can be sized above it.
#   2. StartLimit* does NOT leak into [Service] (systemd rejects it there).
#   3. systemd-analyze verify accepts both unit files (syntax + directives).
#   4. Live wedge-recovery drill: 120 .path triggers leaves the .path unit
#      active(waiting), not failed — and a bounded-burst control unit driven
#      by the SAME storm DOES wedge, so the drill cannot pass vacuously.
#      Skipped outside a user-systemd session (CI hosted runners).
#
# Runs read-only against the repo except for the live drill, which installs
# throwaway *-drill unit files into the user systemd scope and removes them.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

svc_unit="$repo_root/systemd/fleet-seat-recovery.service"
path_unit="$repo_root/systemd/fleet-seat-recovery.path"
[[ -f "$svc_unit" ]] || fail "missing: $svc_unit"
[[ -f "$path_unit" ]] || fail "missing: $path_unit"

# --- 1. start rate limiting disabled in [Unit] -------------------------------
# StartLimit* must live in [Unit] (systemd rejects them in [Service]).
#
# fleet-ops#622 sized a burst ceiling (StartLimitBurst=2000/1h) from a ~1800/h
# estimate; fleet-ops#5024 asked for it to come down to 200. Both are
# unusable: measured live 2026-09-11 the unit runs 2471-2536 activations/h
# (one per seat-ledger write, i.e. one per provider round-trip), which is over
# the 2000 ceiling — the ceiling was blown and wedged BOTH the service and its
# .path watcher (unit-start-limit-hit), silently killing the seat-recovery
# fast path. Any fixed burst under an unbounded write rate is a wedge waiting
# to happen, and the wedge is worse than the churn it guards against (the unit
# is a ~30ms idempotent oneshot that always exits 0). Start limiting is
# therefore DISABLED, not tuned. Churn stays visible via the unit-churn line
# in bin/measure.sh (any unit >200 starts/h is reported every judge run).
unit_section=$(awk '/^\[Unit\]/{f=1} /^\[/{if(f&&$0!~/^\[Unit\]/)f=0} f' "$svc_unit")
[[ -n "$unit_section" ]] || fail "no [Unit] section in $svc_unit"
echo "$unit_section" | grep -qx 'StartLimitIntervalSec=0' \
  || fail "StartLimitIntervalSec=0 missing from [Unit] in $svc_unit (start rate limiting must be disabled)"
if echo "$unit_section" | grep -qE '^StartLimitBurst='; then
  fail "StartLimitBurst must not be set in $svc_unit: a fixed burst under an unbounded ledger-write rate is the fleet-ops#622 wedge (re-wedged live 2026-09-11 at 2536 starts/h vs a 2000/h ceiling)"
fi
# A duplicate/second StartLimitIntervalSec is how the previous contradiction got
# in (interval 0 near the top, interval 1h further down, last-wins). Assert one.
[[ $(echo "$unit_section" | grep -cE '^StartLimitIntervalSec=') -eq 1 ]] \
  || fail "expected exactly one StartLimitIntervalSec in [Unit] of $svc_unit (duplicate directives are last-wins and hid the contradiction)"
ok "fleet-seat-recovery.service disables start rate limiting in [Unit] (interval=0, no bounded burst)"

# --- 2. StartLimit* must not leak into [Service] -----------------------------
svc_section=$(awk '/^\[Service\]/{f=1} /^\[/{if(f&&$0!~/^\[Service\]/)f=0} f' "$svc_unit")
if echo "$svc_section" | grep -qE '^StartLimit'; then
  fail "StartLimit* must not appear in [Service] (systemd rejects it there)"
fi
ok "StartLimit* confined to [Unit] (not in [Service])"

# --- 3. systemd-analyze verify accepts both unit files -----------------------
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

# --- 4. live wedge-recovery drill --------------------------------------------
# Prove the fix end-to-end: install the SHIPPED unit files (name-swapped) into
# a throwaway user systemd scope, drive the .path trigger well past the OLD
# default limit (5/10s), and assert the path unit stays active (waiting) —
# i.e. the storm no longer wedges it. Skipped outside the VPS (no user systemd
# session) so CI hosted runners don't false-positive.
#
# fleet-ops#622: the original gate only checked for an XDG_RUNTIME_DIR socket
# and a systemctl binary. GitHub-hosted runners (Ubuntu 24.04 image) provide
# BOTH, and HOME has no `~/.config/systemd/user/` directory by default — so
# the test's `sed > "$drill_svc"` opened a non-existent path and red'd P14 on
# a runner that has no user-systemd-managed services to actually wedge.
# Gate on the existence of the per-user unit dir (the VPS has it; CI does
# not) so the drill only runs where it can actually exercise the real
# path-watcher storm.
if [[ -n "${XDG_RUNTIME_DIR:-}" ]] && [[ -S "${XDG_RUNTIME_DIR}/systemd/private" ]] \
   && [[ -d "$HOME/.config/systemd/user" ]] \
   && command -v systemctl >/dev/null 2>&1; then
  drill_unit="fleet-seat-recovery-drill"
  drill_svc="$HOME/.config/systemd/user/${drill_unit}.service"
  drill_path="$HOME/.config/systemd/user/${drill_unit}.path"
  trigger="$(mktemp -t sr-drill-trigger.XXXXXX)"
  # Copy the SHIPPED unit files with the unit name swapped in, so the drill
  # exercises the real StartLimit guard, not a hand-written stand-in.
  sed "s/fleet-seat-recovery/${drill_unit}/g" "$svc_unit" > "$drill_svc"
  sed "s|/home/nish/workspaces/agent-state/lanes/seats|${trigger}|g; s/fleet-seat-recovery/${drill_unit}/g" "$path_unit" > "$drill_path"
  # The shipped ExecStart points at a VPS bin; point it at /bin/true so the
  # drill only exercises the trigger/rate-limit path, not the real bin.
  sed -i 's|^ExecStart=.*|ExecStart=/bin/true|' "$drill_svc"
  cleanup_drill() {
    systemctl --user stop "${drill_unit}.service" "${drill_unit}.path" 2>/dev/null || true
    systemctl --user reset-failed "${drill_unit}.service" "${drill_unit}.path" 2>/dev/null || true
    rm -f "$drill_svc" "$drill_path" "$trigger"
    systemctl --user daemon-reload 2>/dev/null || true
  }
  trap cleanup_drill EXIT INT TERM
  systemctl --user daemon-reload
  systemctl --user reset-failed "${drill_unit}.service" "${drill_unit}.path" 2>/dev/null || true
  systemctl --user stop "${drill_unit}.service" "${drill_unit}.path" 2>/dev/null || true
  systemctl --user start "${drill_unit}.path" 2>/dev/null || fail "could not start drill .path"
  # Drive the trigger past the OLD default limit (5/10s) AND past the
  # fleet-ops#622 ceiling class. Paced to stay under the .path unit's own
  # TriggerLimit (default 200/2s) so this drill exercises the SERVICE start
  # limit only — hitting TriggerLimit would fail the watcher for a different
  # reason and mask the result.
  for _ in $(seq 1 120); do : > "$trigger"; sleep 0.02; done
  sleep 1
  st=$(systemctl --user show -p ActiveState -p Result "${drill_unit}.path" 2>/dev/null)
  echo "$st" | grep -q 'ActiveState=active' \
    || fail "drill .path wedged under trigger storm: $st (start rate limiting not effective)"
  echo "$st" | grep -q 'Result=success' \
    || fail "drill .path Result not success: $st"
  ok "live drill: 120 triggers does not wedge fleet-seat-recovery.path ($st)"
  # --- control: the SAME storm MUST wedge a bounded-burst unit --------------
  # Without this the drill can pass vacuously (e.g. if the trigger never fired
  # at all). Inject a small burst into the copy and require the wedge the live
  # fleet actually suffered on 2026-09-11.
  ctl_unit="fleet-seat-recovery-drill-ctl"
  ctl_svc="$HOME/.config/systemd/user/${ctl_unit}.service"
  ctl_path="$HOME/.config/systemd/user/${ctl_unit}.path"
  ctl_trigger="$(mktemp -t sr-drill-ctl.XXXXXX)"
  sed "s/fleet-seat-recovery/${ctl_unit}/g; s/^StartLimitIntervalSec=0$/StartLimitIntervalSec=1h\nStartLimitBurst=20/" \
    "$svc_unit" > "$ctl_svc"
  sed "s|/home/nish/workspaces/agent-state/lanes/seats|${ctl_trigger}|g; s/fleet-seat-recovery/${ctl_unit}/g" \
    "$path_unit" > "$ctl_path"
  sed -i 's|^ExecStart=.*|ExecStart=/bin/true|' "$ctl_svc"
  cleanup_ctl() {
    systemctl --user stop "${ctl_unit}.service" "${ctl_unit}.path" 2>/dev/null || true
    systemctl --user reset-failed "${ctl_unit}.service" "${ctl_unit}.path" 2>/dev/null || true
    rm -f "$ctl_svc" "$ctl_path" "$ctl_trigger"
    systemctl --user daemon-reload 2>/dev/null || true
  }
  trap 'cleanup_drill; cleanup_ctl' EXIT INT TERM
  systemctl --user daemon-reload
  systemctl --user start "${ctl_unit}.path" 2>/dev/null || fail "could not start control .path"
  for _ in $(seq 1 120); do : > "$ctl_trigger"; sleep 0.02; done
  sleep 1
  ctl_st=$(systemctl --user show -p ActiveState -p Result "${ctl_unit}.path" 2>/dev/null)
  echo "$ctl_st" | grep -q 'Result=unit-start-limit-hit' \
    || fail "control unit with StartLimitBurst=20 did NOT wedge under the same storm: $ctl_st (drill is vacuous — the trigger never fired)"
  ok "live drill control: a bounded-burst unit DOES wedge under the same storm ($ctl_st)"
  cleanup_ctl
  cleanup_drill
  trap - EXIT INT TERM
else
  echo "SKIP: live wedge-recovery drill (no user systemd session)"
fi

echo "OK: fleet-seat-recovery-units: StartLimit guard + verify + wedge drill"
