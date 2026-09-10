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
# fleet-ops#5093: the storm is gone — the .path watches ONE sentinel file that
# bin/pi-issue-run writes only on a seat verdict EDGE, instead of the seats/
# directory. The StartLimit guard below is kept (and must not be lowered) as
# the loud tripwire if a future edit reintroduces a directory-wide trigger.
#
# This test is split from tests/fleet-seat-recovery.test.sh (which exercises
# the bin's transition/cooldown logic) so the unit-shape + live trigger
# assertions run independently of the bin test. It is invoked from the listed
# tests/fleet-seat-recovery.test.sh (p14-test-listing-gate: transitively
# invoked from a listed test).
#
# What we prove:
#   1. fleet-seat-recovery.service carries a storm-tolerant StartLimit guard
#      in [Unit] (StartLimitIntervalSec=1h, StartLimitBurst>1800). fleet-ops#5093
#      moved the trigger to the sentinel, so this guard is a tripwire now, not
#      an accommodation — lowering it re-creates the #617 wedge.
#   2. StartLimit* does NOT leak into [Service] (systemd rejects it there).
#   3. systemd-analyze verify accepts both unit files (syntax + directives).
#   4. The trigger is the sentinel file only: no seats/ directory watch, no
#      TriggerLimit* (the #5106 wedge trap).
#   4b. Live sentinel drill: 100 seat-json writes -> 0 starts; one sentinel
#      touch -> exactly 1 start; a second write -> 1 more; watcher stays
#      active/success. Skipped outside a user-systemd session (hosted CI).
#   5. bin/pi-issue-run writes the sentinel on both verdict edges (no-usable,
#      usable) and writes NOTHING when the verdict is unchanged — driven
#      end-to-end against a scratch ledger/cap map (offline).

set -euo pipefail
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

# --- 1. StartLimit guard in [Unit] -------------------------------------------
# StartLimit* must live in [Unit] (systemd rejects them in [Service]).
# Extract the [Unit] section and assert both directives are present and high
# enough to survive a sustained ledger-write storm.
unit_section=$(awk '/^\[Unit\]/{f=1} /^\[/{if(f&&$0!~/^\[Unit\]/)f=0} f' "$svc_unit")
[[ -n "$unit_section" ]] || fail "no [Unit] section in $svc_unit"
echo "$unit_section" | grep -qE '^StartLimitIntervalSec=1h$' \
  || fail "StartLimitIntervalSec=1h missing from [Unit] in $svc_unit"
echo "$unit_section" | grep -qE '^StartLimitBurst=[0-9]+$' \
  || fail "StartLimitBurst missing from [Unit] in $svc_unit"
burst=$(echo "$unit_section" | sed -nE 's/^StartLimitBurst=([0-9]+)$/\1/p')
[[ -n "$burst" ]] || fail "could not parse StartLimitBurst"
# 30 triggers/min * 60min = 1800/hr worst case for a DIRECTORY trigger; the
# guard must clear that with headroom so a healthy fleet cannot wedge its own
# fast path. fleet-ops#5093 moved the trigger to the sentinel, so this is a
# tripwire against a directory-watch regression now. Burst=200 would re-wedge
# the path unit (#617).
(( burst > 1800 )) \
  || fail "StartLimitBurst=$burst too low for ~1800/hr trigger storm (need >1800)"
ok "fleet-seat-recovery.service carries a storm-tolerant StartLimit guard in [Unit] (burst=$burst)"

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

# --- 4. the trigger is ONE sentinel file, not the seats directory -----------
# fleet-ops#5093: PathChanged on the seats/ DIRECTORY started this oneshot on
# every seat-health ledger write — 2478 starts/h measured live 2026-09-10,
# which blew StartLimitBurst=2000 and took down BOTH the oneshot
# (start-limit-hit) and this watcher (unit-start-limit-hit). The fast path
# then could not fire on a real NO-USABLE-SEAT -> usable transition at all.
# The watcher must watch exactly one low-churn sentinel file instead.
path_section=$(awk '/^\[Path\]/{f=1} /^\[/{if(f&&$0!~/^\[Path\]/)f=0} f' "$path_unit")
[[ -n "$path_section" ]] || fail "no [Path] section in $path_unit"
echo "$path_section" | grep -qE '^PathChanged=.*/\.no-usable-seat$' \
  || fail "$path_unit must watch the .no-usable-seat sentinel (fleet-ops#5093)"
if echo "$path_section" | grep -qE '^PathChanged=.*lanes/seats$'; then
  fail "$path_unit still watches the seats/ directory (fleet-ops#5093)"
fi
# TriggerLimit* on a .path is the #5106 wedge trap: systemd 255 fails the
# watcher (trigger-limit-hit) and it stops watching, i.e. silent fast-path
# death with a different knob.
if echo "$path_section" | grep -qE '^TriggerLimit'; then
  fail "TriggerLimit* in [Path] wedges the watcher (fleet-ops#5106) — must not be used"
fi
# The sentinel basename must be the one bin/pi-issue-run writes, or the
# watcher would simply never fire.
grep -qF '.no-usable-seat' "$repo_root/bin/pi-issue-run" \
  || fail "bin/pi-issue-run must write the .no-usable-seat sentinel (fleet-ops#5093)"
ok "trigger: .path watches <seats>/.no-usable-seat only (no directory watch, no TriggerLimit*)"

# --- 4b. live sentinel drill -------------------------------------------------
# Prove the acceptance end-to-end against real systemd: install the SHIPPED
# unit files (name-swapped, escalation-excluded stub name) into the user
# systemd scope, write 100 seat-jsons next to the sentinel, and assert ZERO
# service starts; then touch the sentinel once and assert EXACTLY ONE start.
# Skipped outside the VPS (no user systemd session) so CI hosted runners don't
# false-positive.
#
# fleet-ops#622: the original gate only checked for an XDG_RUNTIME_DIR socket
# and a systemctl binary. GitHub-hosted runners (Ubuntu 24.04 image) provide
# BOTH, and HOME has no `~/.config/systemd/user/` directory by default — so
# the test's `sed > "$drill_svc"` opened a non-existent path and red'd P14 on
# a runner that has no user-systemd-managed services to actually exercise.
# Gate on the existence of the per-user unit dir (the VPS has it; CI does
# not) so the drill only runs where it can actually exercise the real
# path-watcher trigger.
if [[ -n "${XDG_RUNTIME_DIR:-}" ]] && [[ -S "${XDG_RUNTIME_DIR}/systemd/private" ]] \
   && [[ -d "$HOME/.config/systemd/user" ]] \
   && command -v systemctl >/dev/null 2>&1; then
  # resilience-drill-stub* is on unit-escalation-write's exclusion list, so a
  # throwaway drill failure cannot write a STOP-REASON for the stub.
  drill_unit="resilience-drill-stub-seat-sentinel"
  drill_svc="$HOME/.config/systemd/user/${drill_unit}.service"
  drill_path="$HOME/.config/systemd/user/${drill_unit}.path"
  drill_root="$(mktemp -d -t sr-sentinel-drill.XXXXXX)"
  drill_log="$drill_root/starts.log"
  drill_start="$drill_root/log-start.sh"
  printf '#!/usr/bin/env bash\necho start >>"%s"\n' "$drill_log" > "$drill_start"
  chmod +x "$drill_start"
  # Copy the SHIPPED unit files with the unit name swapped in and the seats
  # dir redirected to the scratch root, so the drill exercises the real
  # watched path, not a hand-written stand-in.
  sed "s/fleet-seat-recovery/${drill_unit}/g" "$svc_unit" > "$drill_svc"
  sed "s|/home/nish/workspaces/agent-state/lanes/seats|${drill_root}|g; s/fleet-seat-recovery/${drill_unit}/g" "$path_unit" > "$drill_path"
  # The shipped ExecStart points at the real bin; count starts instead.
  sed -i "s|^ExecStart=.*|ExecStart=${drill_start}|" "$drill_svc"
  cleanup_drill() {
    systemctl --user stop "${drill_unit}.service" "${drill_unit}.path" 2>/dev/null || true
    systemctl --user reset-failed "${drill_unit}.service" "${drill_unit}.path" 2>/dev/null || true
    rm -f "$drill_svc" "$drill_path"
    rm -rf "$drill_root"
    systemctl --user daemon-reload 2>/dev/null || true
  }
  count_starts() {
    [[ -f "$drill_log" ]] || { echo 0; return 0; }
    wc -l < "$drill_log"
  }
  trap cleanup_drill EXIT INT TERM
  systemctl --user daemon-reload
  systemctl --user reset-failed "${drill_unit}.service" "${drill_unit}.path" 2>/dev/null || true
  systemctl --user stop "${drill_unit}.service" "${drill_unit}.path" 2>/dev/null || true
  systemctl --user start "${drill_unit}.path" 2>/dev/null || fail "could not start drill .path"
  # Sanity: the copy is watching the scratch sentinel, not the live ledger.
  grep -qF "PathChanged=${drill_root}/.no-usable-seat" "$drill_path" \
    || fail "drill .path did not pick up the scratch sentinel path"
  # 100 ordinary seat-json writes in the SAME directory as the sentinel.
  for i in $(seq 1 100); do
    printf '{"seat":%s}\n' "$i" > "$drill_root/seat-${i}.json"
  done
  sleep 1.5
  n1=$(count_starts)
  [[ "$n1" == "0" ]] \
    || fail "100 seat-json writes must start the oneshot 0 times, got $n1 (directory still watched?)"
  ok "live drill: 100 seat-json writes -> 0 fleet-seat-recovery starts"
  # One sentinel touch -> exactly one start.
  : > "$drill_root/.no-usable-seat"
  sleep 1.5
  n2=$(count_starts)
  [[ "$n2" == "1" ]] \
    || fail "one sentinel touch must start the oneshot exactly once, got $n2"
  ok "live drill: 1 sentinel touch -> exactly 1 fleet-seat-recovery start"
  # A second verdict-edge write fires again (the sentinel is a wake-up, not a
  # one-shot), and the watcher stays healthy.
  printf 'no-usable\n' > "$drill_root/.no-usable-seat"
  sleep 1.5
  n3=$(count_starts)
  [[ "$n3" == "2" ]] \
    || fail "a second sentinel write must start the oneshot once more, got $n3"
  st=$(systemctl --user show -p ActiveState -p Result "${drill_unit}.path" 2>/dev/null)
  echo "$st" | grep -q 'ActiveState=active' \
    || fail "drill .path not active after the sentinel drill: $st"
  echo "$st" | grep -q 'Result=success' \
    || fail "drill .path Result not success: $st"
  ok "live drill: second sentinel write -> 1 more start, watcher stays active/success"
  cleanup_drill
  trap - EXIT INT TERM
else
  echo "SKIP: live sentinel drill (no user systemd session)"
fi

# --- 5. the sentinel latch is written by bin/pi-issue-run, edge-only ---------
# fleet-ops#5093: nothing else in the repo observes BOTH seat verdicts, so
# bin/pi-issue-run writes the sentinel: `no-usable` when pick_seat returns
# nothing, `usable` when a pick succeeds while the sentinel said no-usable
# (the recovery edge the fast path exists to fire on). An unchanged verdict
# writes NOTHING — that is what takes the fast path from ~2500 starts/h to
# zero while the fleet is healthy. Driven end-to-end with a scratch ledger +
# cap map (offline, no pi/gh/network), so a future edit that drops either edge
# (or writes on every run) fails here instead of silently killing the fast
# path.
(
  set -euo pipefail
  scratch="$(mktemp -d -t sr-latch.XXXXXX)"
  trap 'rm -rf "$scratch"' EXIT INT TERM
  export HOME="$scratch/home"
  mkdir -p "$HOME/.config/fleet-worker"
  : > "$HOME/.config/fleet-worker/nishfleet-worker.env"
  chmod 600 "$HOME/.config/fleet-worker/nishfleet-worker.env"
  export PI_PACKET_STATE="$scratch/state"
  mkdir -p "$PI_PACKET_STATE/attempts" "$PI_PACKET_STATE/active-seats"
  export PI_ISSUES_DIR="$scratch/issues"
  mkdir -p "$PI_ISSUES_DIR"
  export PI_SEAT_HEALTH_LEDGER_DIR="$scratch/ledger"
  mkdir -p "$PI_SEAT_HEALTH_LEDGER_DIR"
  export PI_SEAT_HEALTH_SIDECAR="$scratch/pi-seat-health.json"
  export PI_MODELS_JSON="$scratch/models.json"
  export SEAT_CAPS_JSON="$scratch/seat-caps.json"
  export XDG_RUNTIME_DIR="$scratch/xdg"
  mkdir -p "$XDG_RUNTIME_DIR"
  export PI_SEAT_LIB_CHECK_SYSTEMD=0
  export PI_PACKET_SEAT_LIB="$repo_root/lib/seat-lib.sh"
  export PI_SEAT_NOUSABLE_COOLDOWN_S=0
  export EMPTY_RUN_RETRY_MAX=0
  export FLEET_DEBUG_PLAYBOOK_GATE=0
  stub_bin="$scratch/stub-bin"
  mkdir -p "$stub_bin"
  printf '#!/usr/bin/env bash\nprintf "stub output stub output stub output stub output stub output\\n"\nexit 0\n' > "$stub_bin/pi"
  printf '#!/usr/bin/env bash\nif [[ "$*" == *"--jq"* ]]; then printf "open\\n"; fi\nprintf "[]\\n"\nexit 0\n' > "$stub_bin/gh"
  printf '#!/usr/bin/env bash\nprintf "export GH_TOKEN=fake-test-token-cccccccccccccccc\\n"\nexit 0\n' > "$stub_bin/worker-token"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$stub_bin/systemctl"
  chmod +x "$stub_bin"/*
  export PATH="$stub_bin:/usr/local/bin:/usr/bin:/bin"
  export PI_BIN="$stub_bin/pi"
  export WORKER_TOKEN_BIN="$stub_bin/worker-token"
  cat > "$PI_MODELS_JSON" <<'JSON'
{ "providers": { "devin": { "models": [ { "id": "glm-5-2", "cost": { "input": 0 } } ] } } }
JSON
  cat > "$SEAT_CAPS_JSON" <<'JSON'
{ "ram_gb_per_worker": 1.5, "free_providers_in_order": [],
  "providers": { "devin": { "cap": 2, "class": "subscription", "models": { "glm-5-2": 2 } } } }
JSON
  inst="fleet-ops-5093"
  printf 'Implement one GitHub issue: fleet-ops#5093.\nTARGET: repo Nishfleet/fleet-ops issue 5093 unit pi-issue-%s\n' "$inst" > "$PI_ISSUES_DIR/${inst}.in"
  sentinel="$PI_SEAT_HEALTH_LEDGER_DIR/.no-usable-seat"
  run_issue_run() {
    set +e
    bash "$repo_root/bin/pi-issue-run" "$inst" > "$scratch/run.out" 2> "$scratch/run.err"
    set -e
  }
  reset_tried() { rm -f "$PI_PACKET_STATE/attempts/pi-issue-${inst}.tried-seats"; }
  [[ ! -e "$sentinel" ]] || fail "scratch sentinel must not exist at start"
  # (a) every seat walled -> no-usable edge
  cat > "$SEAT_CAPS_JSON" <<'JSON'
{ "ram_gb_per_worker": 1.5, "free_providers_in_order": [], "providers": {} }
JSON
  run_issue_run
  got=$(cat "$sentinel" 2>/dev/null || true)
  [[ "$got" == "no-usable" ]] \
    || fail "no-seat pick must write the sentinel no-usable (got '${got:-ABSENT}')"
  # (b) a seat exists again -> recovery edge rewrites it
  cat > "$SEAT_CAPS_JSON" <<'JSON'
{ "ram_gb_per_worker": 1.5, "free_providers_in_order": [],
  "providers": { "devin": { "cap": 2, "class": "subscription", "models": { "glm-5-2": 2 } } } }
JSON
  reset_tried
  mtime_before=$(stat -c '%Y.%i' "$sentinel")
  sleep 1.1
  run_issue_run
  got=$(cat "$sentinel" 2>/dev/null || true)
  [[ "$got" == "usable" ]] \
    || fail "a successful pick must rewrite the sentinel usable (got '${got:-ABSENT}')"
  # (c) unchanged verdict -> NO write (edge-only; this is the churn fix)
  reset_tried
  mtime_after=$(stat -c '%Y.%i' "$sentinel")
  sleep 1.1
  run_issue_run
  mtime_same=$(stat -c '%Y.%i' "$sentinel")
  [[ "$mtime_after" == "$mtime_same" && "$mtime_after" != "$mtime_before" ]] \
    || fail "an unchanged verdict must not rewrite the sentinel (before=$mtime_before edge=$mtime_after again=$mtime_same)"
  # (d) walled again -> no-usable edge fires once more
  cat > "$SEAT_CAPS_JSON" <<'JSON'
{ "ram_gb_per_worker": 1.5, "free_providers_in_order": [], "providers": {} }
JSON
  reset_tried
  run_issue_run
  got=$(cat "$sentinel" 2>/dev/null || true)
  [[ "$got" == "no-usable" ]] \
    || fail "a second walled pick must rewrite the sentinel no-usable (got '${got:-ABSENT}')"
) || fail "sentinel latch end-to-end run failed (see above)"
ok "sentinel latch: no-usable + usable edges written, unchanged verdict writes nothing"

echo "OK: fleet-seat-recovery-units: StartLimit guard + verify + sentinel trigger + latch"
