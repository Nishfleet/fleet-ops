#!/usr/bin/env bash
# tests/fleet-seat-recovery-units.test.sh
#
# fleet-ops#622: fleet-seat-recovery.path fails to start (unit-start-limit-hit).
# The seats ledger is written every few seconds (every seat-health extension
# update), so fleet-seat-recovery.path fires fleet-seat-recovery.service
# ~30x/min. The bin's own FLEET_SEAT_RECOVERY_COOLDOWN (default 120s) is the
# real rate-limiter for the side effect (the intake fire).
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
#   4. The drill's throwaway units cannot summon a senior auditor.
#   5. Live wedge-recovery drill: 120 .path triggers leaves the .path unit
#      active(waiting), not failed — and a bounded-burst control unit driven
#      by the SAME storm DOES wedge, so the drill cannot pass vacuously.
#      Skipped outside a user-systemd session (CI hosted runners).
#
# Runs read-only against the repo except for the live drill, which installs
# throwaway drill stub units into the user systemd scope and removes them.

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

# --- 4. the drill's throwaway units must not summon a senior auditor ---------
# The phase-5 drill deliberately wedges a bounded-burst CONTROL unit, and the
# global path.d/10-escalate.conf drop-in catches ANY user unit failure via
# OnFailure=unit-escalation@%n.service. So without a guard EVERY run of this
# test writes a STOP-REASON and summons a SENIOR AUDITOR for a throwaway probe
# it removes seconds later. Observed live the first time the control drill ran:
# STOP-REASON 2026-09-10T20:28:25Z for fleet-seat-recovery-drill-ctl.path.
# Same class as the fleet-orphan-reset-probe@* / probe-*.service carve-outs
# (fleet-ops#3926).
#
# The guard is therefore a NAME: the drill units carry the already-excluded
# `resilience-drill-stub` prefix (see bin/unit-escalation-write). A per-unit
# `OnFailure=` reset drop-in does NOT work here and was tried: on systemd 255
# the generic service.d/10-escalate.conf beats a unit-specific drop-in
# regardless of filename order (probed three ways — concrete unit,
# truncated-prefix dir, template instance — all still carried the generic
# OnFailure=), so a drop-in would look like a guard while still escalating.
# Verified live below, and end-to-end by asserting the drill leaves the live
# STOP-REASON untouched.
#
# The prefixes the drill MUST stay inside (any of these is skipped by the
# writer): resilience-drill-stub*, fleet-orphan-reset-probe@*, probe-*.service
# (note: .service only, so it cannot cover a .path watcher), live-dummy*.
writer="$repo_root/bin/unit-escalation-write"
if [[ -x "$writer" ]]; then
  excl_scratch="$(mktemp -d -t sr-excl.XXXXXX)"
  printf '{"reason":"should-not-change"}\n' > "$excl_scratch/STOP-REASON.json"
  for du in resilience-drill-stub-seat-recovery.path \
            resilience-drill-stub-seat-recovery.service \
            resilience-drill-stub-seat-recovery-ctl.path \
            resilience-drill-stub-seat-recovery-ctl.service; do
    out=$(UNIT_ESCALATION_AGENT_STATE="$excl_scratch" "$writer" "$du" 2>&1) || true
    grep -q 'skipping excluded unit' <<<"$out" \
      || fail "$du is NOT escalation-excluded — every run of this test would write a STOP-REASON and summon a senior auditor (got: $out)"
  done
  ! grep -q '"unit-failure"' "$excl_scratch/STOP-REASON.json" \
    || fail "drill stub units wrote STOP-REASON despite the name carve-out: $(cat "$excl_scratch/STOP-REASON.json")"
  rm -f "$excl_scratch/STOP-REASON.json"
  rmdir "$excl_scratch" 2>/dev/null || true
  ok "drill stub units are escalation-excluded by name (a deliberately-wedged probe cannot summon an auditor)"
else
  echo "SKIP: bin/unit-escalation-write not executable (drill carve-out lock)"
fi

# --- 5. live wedge-recovery drill --------------------------------------------
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
  # Names are load-bearing: the `resilience-drill-stub` prefix is what keeps
  # these throwaways out of the escalation chain (phase 4). Do not rename them
  # to anything seat-recovery-specific without adding that carve-out first.
  drill_unit="resilience-drill-stub-seat-recovery"
  ctl_unit="resilience-drill-stub-seat-recovery-ctl"
  drill_svc="$HOME/.config/systemd/user/${drill_unit}.service"
  drill_path="$HOME/.config/systemd/user/${drill_unit}.path"
  ctl_svc="$HOME/.config/systemd/user/${ctl_unit}.service"
  ctl_path="$HOME/.config/systemd/user/${ctl_unit}.path"
  trigger="$(mktemp -t sr-drill-trigger.XXXXXX)"
  ctl_trigger="$(mktemp -t sr-drill-ctl.XXXXXX)"
  # Snapshot the escalation state so we can prove the drill added nothing.
  # Same path resolution the writer uses (UNIT_ESCALATION_STOP_REASON ->
  # UNIT_ESCALATION_AGENT_STATE/STOP-REASON.json).
  stop_reason_file="${UNIT_ESCALATION_STOP_REASON:-${UNIT_ESCALATION_AGENT_STATE:-/home/nish/workspaces/agent-state}/STOP-REASON.json}"
  sr_before="$(cat "$stop_reason_file" 2>/dev/null || true)"
  cleanup_drill() {
    systemctl --user stop "${drill_unit}.service" "${drill_unit}.path" \
                       "${ctl_unit}.service" "${ctl_unit}.path" 2>/dev/null || true
    systemctl --user reset-failed "${drill_unit}.service" "${drill_unit}.path" \
                       "${ctl_unit}.service" "${ctl_unit}.path" 2>/dev/null || true
    rm -f "$drill_svc" "$drill_path" "$ctl_svc" "$ctl_path" "$trigger" "$ctl_trigger"
    systemctl --user daemon-reload 2>/dev/null || true
  }
  trap cleanup_drill EXIT INT TERM
  # Copy the SHIPPED unit files with the unit name swapped in, so the drill
  # exercises the real start-limit behaviour, not a hand-written stand-in.
  sed "s/fleet-seat-recovery/${drill_unit}/g" "$svc_unit" > "$drill_svc"
  sed "s|/home/nish/workspaces/agent-state/lanes/seats|${trigger}|g; s/fleet-seat-recovery/${drill_unit}/g" "$path_unit" > "$drill_path"
  # Control: the SAME shipped unit but with a bounded burst re-injected, which
  # MUST wedge. Without it the drill could pass vacuously (e.g. if the trigger
  # never fired at all).
  sed "s/fleet-seat-recovery/${ctl_unit}/g; s/^StartLimitIntervalSec=0$/StartLimitIntervalSec=1h\nStartLimitBurst=20/" \
    "$svc_unit" > "$ctl_svc"
  sed "s|/home/nish/workspaces/agent-state/lanes/seats|${ctl_trigger}|g; s/fleet-seat-recovery/${ctl_unit}/g" \
    "$path_unit" > "$ctl_path"
  # The shipped ExecStart points at a VPS bin; point it at /bin/true so the
  # drill only exercises the trigger/rate-limit path, not the real bin.
  sed -i 's|^ExecStart=.*|ExecStart=/bin/true|' "$drill_svc" "$ctl_svc"
  systemctl --user daemon-reload
  for u in "${drill_unit}.service" "${drill_unit}.path" "${ctl_unit}.service" "${ctl_unit}.path"; do
    systemctl --user reset-failed "$u" 2>/dev/null || true
    systemctl --user stop "$u" 2>/dev/null || true
  done
  systemctl --user start "${drill_unit}.path" 2>/dev/null || fail "could not start drill .path"
  systemctl --user start "${ctl_unit}.path" 2>/dev/null || fail "could not start control .path"
  # Drive both watchers past the OLD default limit (5/10s) AND past the
  # fleet-ops#622 ceiling class. Paced to stay under the .path units' own
  # TriggerLimit (default 200/2s) so this drill exercises the SERVICE start
  # limit only — hitting TriggerLimit would fail a watcher for a different
  # reason and mask the result.
  for _ in $(seq 1 120); do
    : > "$trigger"
    : > "$ctl_trigger"
    sleep 0.02
  done
  sleep 1
  st=$(systemctl --user show -p ActiveState -p Result "${drill_unit}.path" 2>/dev/null)
  echo "$st" | grep -q 'ActiveState=active' \
    || fail "drill .path wedged under trigger storm: $st (start rate limiting not effective)"
  echo "$st" | grep -q 'Result=success' \
    || fail "drill .path Result not success: $st"
  ok "live drill: 120 triggers does not wedge fleet-seat-recovery.path ($st)"
  ctl_st=$(systemctl --user show -p ActiveState -p Result "${ctl_unit}.path" 2>/dev/null)
  echo "$ctl_st" | grep -q 'Result=unit-start-limit-hit' \
    || fail "control unit with StartLimitBurst=20 did NOT wedge under the same storm: $ctl_st (drill is vacuous — the trigger never fired)"
  ok "live drill control: a bounded-burst unit DOES wedge under the same storm ($ctl_st)"
  # Prove the drill summoned nobody: the live escalation chain is untouched.
  sr_after="$(cat "$stop_reason_file" 2>/dev/null || true)"
  if [[ "$sr_after" != "$sr_before" ]] && grep -qE 'resilience-drill-stub-seat-recovery' <<<"$sr_after"; then
    fail "drill summoned a senior auditor: STOP-REASON now names a drill unit -> $sr_after"
  fi
  ok "drill left the escalation chain untouched (no STOP-REASON naming a drill unit)"
  cleanup_drill
  trap - EXIT INT TERM
else
  echo "SKIP: live wedge-recovery drill (no user systemd session)"
fi

echo "OK: fleet-seat-recovery-units: StartLimit disabled + verify + drill + carve-out"
