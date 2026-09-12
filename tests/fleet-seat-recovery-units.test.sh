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
# directory.
#
# fleet-ops#5096: the ledger rewrite rate itself is fixed too (the seat-health
# extension no longer rewrites an unchanged routing record), which is what made
# a small BOUNDED StartLimit correct rather than an accommodation. With an
# edge-only sentinel trigger AND a write-suppressed ledger, activations are ~0
# in normal operation, so StartLimitBurst=200 is never reached by traffic and
# can only fire on a churn regression — loudly.
#
# This test is split from tests/fleet-seat-recovery.test.sh (which exercises
# the bin's transition/cooldown logic) so the unit-shape + live trigger
# assertions run independently of the bin test. It is invoked from the listed
# tests/fleet-seat-recovery.test.sh (p14-test-listing-gate: transitively
# invoked from a listed test).
#
# What we prove:
#   1. fleet-seat-recovery.service carries a BOUNDED StartLimit guard in [Unit]
#      (StartLimitIntervalSec=1h, StartLimitBurst=200 — the ceiling
#      fleet-ops#5024 asked for, made safe by fleet-ops#5096's trigger fix).
#   2. StartLimit* does NOT leak into [Service] (systemd rejects it there).
#   3. systemd-analyze verify accepts both unit files (syntax + directives).
#   4. The trigger is the sentinel file only: no seats/ directory watch, no
#      TriggerLimit* (the #5106 wedge trap).
#   4b. The live sentinel drill (100 seat-json writes -> 0 starts; one touch
#      -> exactly 1; second write -> 1 more; watcher active/success) runs as
#      the seat_sentinel plane of bin/fleet-resilience-drill on the daily
#      05:47 timer (fleet-ops#5106) — NOT here, on every test-suite run. A
#      worker re-running this suite in an inner loop put the drill stub at
#      247 starts/h (2026-09-11), the box's top unit. This test only gates
#      that the plane exists, so the assurance cannot be silently dropped.
#   4c. NEGATIVE CONTROL, same plane: the seat_sentinel drill also drives the
#      same sentinel storm against a burst=5 stub and asserts it DOES wedge
#      the watcher — the shipped guard is armed, not decorative
#      (fleet-ops#5096). Pinned here the same way as 4b.
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

# --- 1. Bounded StartLimit guard in [Unit] -----------------------------------
# StartLimit* must live in [Unit] (systemd rejects them in [Service]).
# Extract the [Unit] section and assert the ceiling is present and BOUNDED.
unit_section=$(awk '/^\[Unit\]/{f=1} /^\[/{if(f&&$0!~/^\[Unit\]/)f=0} f' "$svc_unit")
[[ -n "$unit_section" ]] || fail "no [Unit] section in $svc_unit"
echo "$unit_section" | grep -qE '^StartLimitIntervalSec=1h$' \
  || fail "StartLimitIntervalSec=1h missing from [Unit] in $svc_unit"
echo "$unit_section" | grep -qE '^StartLimitBurst=[0-9]+$' \
  || fail "StartLimitBurst missing from [Unit] in $svc_unit"
burst=$(echo "$unit_section" | sed -nE 's/^StartLimitBurst=([0-9]+)$/\1/p')
[[ -n "$burst" ]] || fail "could not parse StartLimitBurst"
# Exactly 200: the ceiling fleet-ops#5024 asked for, made safe by the two
# trigger fixes (fleet-ops#5093's edge-only sentinel, fleet-ops#5096's
# no-op-write suppression). Asserted EXACTLY (not just bounded) because the
# whole point is that this number is meaningless without those fixes and must
# not silently drift back above the storm it is supposed to catch. The old
# #622 accommodation (StartLimitBurst=2000) was sized from a ~1800/h ESTIMATE
# of a write rate nothing bounded; live 2026-09-11 it was 2471-2536/h and blew
# the burst, wedging the fast path. A ceiling must sit ABOVE steady state and
# BELOW the storm — it cannot do both against an unbounded trigger rate.
[[ "$burst" == "200" ]] \
  || fail "StartLimitBurst=$burst, expected 200 (fleet-ops#5024's ceiling, safe because the trigger rate is bounded by #5093 + #5096)"
ok "fleet-seat-recovery.service carries a bounded StartLimit guard in [Unit] (interval=1h burst=$burst)"

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

# --- 4b. the live sentinel drill lives in the resilience drill --------------
# fleet-ops#5106: the live proof (install a name-swapped stub pair, 100
# seat-json writes -> 0 starts, one sentinel touch -> 1 start, second write
# -> 1 more, watcher stays active/success) moved to the seat_sentinel plane
# of bin/fleet-resilience-drill. A drill is a periodic assurance check: it
# runs on the drill's daily timer, not once per test-suite run (the inner-
# loop churn that made this change: 247 stub starts/h on 2026-09-11).
# This gate keeps the move honest: a regression that drops the plane (or its
# offline skip) red-fails HERE instead of silently retiring the assurance.
drill_bin="$repo_root/bin/fleet-resilience-drill"
[[ -f "$drill_bin" ]] || fail "missing: $drill_bin"
grep -q '^plane_seat_sentinel()' "$drill_bin" \
  || fail "bin/fleet-resilience-drill must carry the seat_sentinel plane (the live sentinel proof, fleet-ops#5106)"
grep -q 'plane_seat_sentinel || rc=1' "$drill_bin" \
  || fail "run_drill must invoke plane_seat_sentinel (fleet-ops#5106)"
grep -q 'resilience-drill-stub-seat-sentinel' "$drill_bin" \
  || fail "seat_sentinel plane must drive the resilience-drill-stub-seat-sentinel stub (fleet-ops#5106)"
ok "live sentinel drill: seat_sentinel plane present in bin/fleet-resilience-drill (daily timer cadence, fleet-ops#5106)"

# --- 4c. the same plane carries the negative control ----------------------
# fleet-ops#5096: the armed-not-decorative proof moved with the drill — the
# seat_sentinel plane also runs the same sentinel storm against a burst=5
# stub (resilience-drill-stub-seat-sentinel-tiny) and asserts it wedges the
# watcher. Pin it here so the control cannot be silently dropped.
grep -q 'resilience-drill-stub-seat-sentinel-tiny' "$drill_bin" \
  || fail "seat_sentinel plane must carry the burst=5 negative-control stub (fleet-ops#5096)"
grep -q 'StartLimitBurst=5' "$drill_bin" \
  || fail "seat_sentinel plane must drive the negative-control stub at StartLimitBurst=5 (fleet-ops#5096)"
ok "negative control: seat_sentinel plane wedges a burst=5 stub on the same storm (fleet-ops#5096)"

# --- 5. the sentinel latch is written by bin/pi-issue-run, edge-only ---------
# fleet-ops#5093: nothing else in the repo observes BOTH seat verdicts, so
# bin/pi-issue-run writes the sentinel: `no-usable` when pick-seat returns
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
  export PI_PACKET_SEAT_LIB="$repo_root/lib/litellm-seat.sh"
  export PI_SEAT_NOUSABLE_COOLDOWN_S=0
  export EMPTY_RUN_RETRY_MAX=0
  export FLEET_DEBUG_PLAYBOOK_GATE=0
  stub_bin="$scratch/stub-bin"
  mkdir -p "$stub_bin"
  printf '#!/usr/bin/env bash\nprintf "stub output stub output stub output stub output stub output\\n"\nexit 0\n' > "$stub_bin/pi"
  printf '#!/usr/bin/env bash\nif [[ "$*" == *"--jq"* ]]; then printf "open\\n"; fi\nprintf "[]\\n"\nexit 0\n' > "$stub_bin/gh"
  printf '#!/usr/bin/env bash\nprintf "export GH_TOKEN=fake-test-token-cccccccccccccccc\\n"\nexit 0\n' > "$stub_bin/worker-token"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$stub_bin/systemctl"
  # fleet-ops#4263: the walled/recovered edge is the proxy readiness probe now.
  cat > "$stub_bin/curl" <<CURL
#!/usr/bin/env bash
[[ -f "$scratch/proxy-up" ]] && { printf '{"status":"healthy"}'; exit 0; }
exit 7
CURL
  chmod +x "$stub_bin"/*
  export PATH="$stub_bin:/usr/local/bin:/usr/bin:/bin"
  export PI_BIN="$stub_bin/pi"
  export WORKER_TOKEN_BIN="$stub_bin/worker-token"
  export LITELLM_REQUIRE_LIVE=1 LITELLM_HEALTH_URL="http://127.0.0.1:9/health/readiness"
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
  rm -f "$scratch/proxy-up"
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
  touch "$scratch/proxy-up"
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
  rm -f "$scratch/proxy-up"
  run_issue_run
  got=$(cat "$sentinel" 2>/dev/null || true)
  [[ "$got" == "no-usable" ]] \
    || fail "a second walled pick must rewrite the sentinel no-usable (got '${got:-ABSENT}')"
) || fail "sentinel latch end-to-end run failed (see above)"
ok "sentinel latch: no-usable + usable edges written, unchanged verdict writes nothing"

echo "OK: fleet-seat-recovery-units: bounded StartLimit guard (armed, proven by a negative control) + verify + sentinel trigger + latch"
