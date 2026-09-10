#!/usr/bin/env bash
# tests/timer-manifest-drift-canary.test.sh
#
# Proves the live timer-manifest drift canary (fleet-ops#4647) offline, with a
# stubbed `systemctl --user`:
#   1. Clean tick (all live timers in manifest) -> exit 0, no LOUD.
#   2. Missing persistent (Transient=no) timer -> exit 1, LOUD with
#      `signal: timer-manifest/<unit>` (the reconciler auto-files + dedupes).
#   3. Missing Transient=yes timer -> exit 0, NO LOUD (one-off systemd-run
#      creations are not roster drift — acceptance 3).
#   4. System/runner-image timer missing -> exit 0 (excluded).
#   5. Deliberately-unmanaged timer missing -> exit 0 (excluded, #4400).
#   6. Template match (pi-intake@0509.timer -> pi-intake@.timer) -> exit 0.
#   7. Crash: unparseable manifest -> exit 2.
#   8. CI mode (systemctl unavailable) -> exit 0 (clean skip).
#   9. Heartbeat-tier1 wires the canary (block 47) and propagates rc>=2 only.
#  10. The detector->queue reconciler (fleet-ops#362) derives the
#      `timer-manifest/<unit>` signal from the LOUD line (auto-file path).
#
# Hosted by tests/timer-manifest.test.sh (the worker App token cannot push
# .github/workflows/**, so new suites ride an existing ci.yml entry).
#
# Run: bash tests/timer-manifest-drift-canary.test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-timer-manifest-drift-canary"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
manifest="$repo_root/systemd/timer-manifest.json"
reconciler="$repo_root/lib/detector-queue-reconciler.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$tier1" ]] || fail "missing: $tier1"
[[ -f "$manifest" ]] || fail "missing: $manifest"
[[ -f "$reconciler" ]] || fail "missing: $reconciler"
command -v jq >/dev/null 2>&1 || fail "jq missing"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"

scratch="$(mktemp -d -t timer-manifest-drift.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
triage="$scratch/triage.md"
: >"$triage"

# --- fake systemctl --user stub ----------------------------------------------
# Handles: list-timers --no-pager (availability), list-unit-files '*.timer'
# (enumerate), show <unit> -p Transient --value (per-timer). The live timer
# list is read from $LIVE_TIMERS_FILE (one unit per line); transient units
# are listed in $TRANSIENT_FILE (one unit per line).
fake_systemctl="$scratch/systemctl"
cat >"$fake_systemctl" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    list-timers)
        # availability probe — succeed
        exit 0
        ;;
    list-unit-files)
        cat "$LIVE_TIMERS_FILE"
        exit 0
        ;;
    show)
        unit="$2"
        if grep -qxF "$unit" "$TRANSIENT_FILE" 2>/dev/null; then
            echo yes
        else
            echo no
        fi
        exit 0
        ;;
    *)
        echo "fake-systemctl: unknown: $*" >&2
        exit 1
        ;;
esac
STUB
chmod +x "$fake_systemctl"

# A minimal manifest with a known timer + a template entry.
make_manifest() {
    local path="$1"
    cat >"$path" <<'JSON'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "description": "test manifest",
  "timers": {
    "fleet-heartbeat-tier1.timer": {
      "reason": "test entry",
      "classification": "scheduled",
      "cadence": "every-15m",
      "source": "repo"
    },
    "pi-intake@.timer": {
      "reason": "template entry",
      "classification": "template",
      "cadence": "on-demand",
      "source": "repo"
    },
    "0509-demo-brand-timeline-canary.timer": {
      "reason": "user-config canary (acceptance 4: ADOPT, not exempt)",
      "classification": "scheduled",
      "cadence": "daily",
      "source": "user-config"
    }
  }
}
JSON
}

run_canary() {
    # $1 = live-timers file, $2 = transient file, $3 = manifest, $4 = triage
    LIVE_TIMERS_FILE="$1" TRANSIENT_FILE="$2" \
    FLEET_TIMER_MANIFEST="$3" FLEET_HEARTBEAT_TRIAGE="$4" \
    FLEET_TIMER_MANIFEST_SYSTEMCTL="$fake_systemctl" \
    FLEET_TIMER_MANIFEST_SKIP_ORIGIN=1 \
    "$bin"
}

LOUD_LINES() { grep -c 'TIMER-MANIFEST-DRIFT' "$1" 2>/dev/null || true; }

# --- 1. CLEAN tick: all live timers in manifest -> exit 0, no LOUD -----------
m="$scratch/manifest.json"; make_manifest "$m"
live="$scratch/live.txt"; printf '%s\n' \
    'fleet-heartbeat-tier1.timer' \
    'pi-intake@0509.timer' \
    '0509-demo-brand-timeline-canary.timer' >"$live"
trans="$scratch/transient.txt"; : >"$trans"
set +e; run_canary "$live" "$trans" "$m" "$triage"; rc=$?; set -e
[[ "$rc" -eq 0 ]] || fail "1. clean tick must exit 0, got $rc"
[[ "$(LOUD_LINES "$triage")" -eq 0 ]] || fail "1. clean tick must not LOUD"
ok "1. CLEAN tick: all live timers in manifest -> exit 0, no LOUD"

# --- 2. MISSING persistent timer -> exit 1, LOUD signal: timer-manifest/<u> --
: >"$triage"
printf '%s\n' \
    'fleet-heartbeat-tier1.timer' \
    '0509-sneaker-resale-recall-canary.timer' >"$live"
: >"$trans"
set +e; run_canary "$live" "$trans" "$m" "$triage"; rc=$?; set -e
[[ "$rc" -eq 1 ]] || fail "2. missing persistent timer must exit 1, got $rc"
grep -q 'signal: timer-manifest/0509-sneaker-resale-recall-canary.timer' "$triage" \
    || fail "2. LOUD must carry signal: timer-manifest/<unit>"
ok "2. MISSING persistent timer -> exit 1, LOUD signal: timer-manifest/<unit>"

# --- 3. MISSING Transient=yes timer -> exit 0, NO LOUD (acceptance 3) --------
: >"$triage"
printf '%s\n' \
    'fleet-heartbeat-tier1.timer' \
    '0509-backfill-tail-1919.timer' >"$live"
printf '%s\n' '0509-backfill-tail-1919.timer' >"$trans"
set +e; run_canary "$live" "$trans" "$m" "$triage"; rc=$?; set -e
[[ "$rc" -eq 0 ]] || fail "3. missing Transient=yes timer must exit 0, got $rc"
[[ "$(LOUD_LINES "$triage")" -eq 0 ]] || fail "3. Transient=yes must not LOUD"
ok "3. MISSING Transient=yes timer -> exit 0, NO LOUD (acceptance 3)"

# --- 4. SYSTEM/runner-image timer missing -> exit 0 (excluded) --------------
: >"$triage"
printf '%s\n' \
    'fleet-heartbeat-tier1.timer' \
    'apt-daily.timer' >"$live"
: >"$trans"
set +e; run_canary "$live" "$trans" "$m" "$triage"; rc=$?; set -e
[[ "$rc" -eq 0 ]] || fail "4. system timer missing must exit 0, got $rc"
[[ "$(LOUD_LINES "$triage")" -eq 0 ]] || fail "4. system timer must not LOUD"
ok "4. SYSTEM timer missing -> exit 0 (excluded)"

# --- 5. UNMANAGED timer missing -> exit 0 (excluded, #4400) -----------------
: >"$triage"
allow="$scratch/unmanaged.json"
cat >"$allow" <<'JSON'
{ "_doc": "test allowlist", "unmanaged": [ { "unit": "manual-probe-xyz.timer", "reason": "2026-09-09 test" } ] }
JSON
printf '%s\n' \
    'fleet-heartbeat-tier1.timer' \
    'manual-probe-xyz.timer' >"$live"
: >"$trans"
set +e
LIVE_TIMERS_FILE="$live" TRANSIENT_FILE="$trans" \
FLEET_TIMER_MANIFEST="$m" FLEET_HEARTBEAT_TRIAGE="$triage" \
FLEET_TIMER_MANIFEST_SYSTEMCTL="$fake_systemctl" \
FLEET_TIMER_MANIFEST_UNMANAGED="$allow" \
FLEET_TIMER_MANIFEST_SKIP_ORIGIN=1 \
"$bin"; rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "5. unmanaged timer missing must exit 0, got $rc"
[[ "$(LOUD_LINES "$triage")" -eq 0 ]] || fail "5. unmanaged timer must not LOUD"
ok "5. UNMANAGED timer missing -> exit 0 (excluded, #4400)"

# --- 6. TEMPLATE match (pi-intake@0509.timer -> pi-intake@.timer) -> exit 0 --
: >"$triage"
printf '%s\n' \
    'fleet-heartbeat-tier1.timer' \
    'pi-intake@0509.timer' >"$live"
: >"$trans"
set +e; run_canary "$live" "$trans" "$m" "$triage"; rc=$?; set -e
[[ "$rc" -eq 0 ]] || fail "6. template match must exit 0, got $rc"
[[ "$(LOUD_LINES "$triage")" -eq 0 ]] || fail "6. template match must not LOUD"
ok "6. TEMPLATE match (pi-intake@0509.timer -> pi-intake@.timer) -> exit 0"

# --- 7. CRASH: unparseable manifest -> exit 2 -------------------------------
bad="$scratch/bad.json"; printf '{ not json\n' >"$bad"
set +e
LIVE_TIMERS_FILE="$live" TRANSIENT_FILE="$trans" \
FLEET_TIMER_MANIFEST="$bad" FLEET_HEARTBEAT_TRIAGE="$triage" \
FLEET_TIMER_MANIFEST_SYSTEMCTL="$fake_systemctl" \
FLEET_TIMER_MANIFEST_SKIP_ORIGIN=1 \
"$bin" >/dev/null 2>&1; rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "7. unparseable manifest must exit 2, got $rc"
ok "7. CRASH: unparseable manifest -> exit 2"

# --- 8. CI MODE: systemctl unavailable -> exit 0 (clean skip) --------------
ci_systemctl="$scratch/systemctl-ci"
cat >"$ci_systemctl" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    list-timers) exit 1 ;;  # unavailable
    *) exit 1 ;;
esac
STUB
chmod +x "$ci_systemctl"
set +e
FLEET_TIMER_MANIFEST="$m" FLEET_HEARTBEAT_TRIAGE="$triage" \
FLEET_TIMER_MANIFEST_SYSTEMCTL="$ci_systemctl" \
FLEET_TIMER_MANIFEST_SKIP_ORIGIN=1 \
"$bin" >/dev/null 2>&1; rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "8. CI mode (no systemctl) must exit 0, got $rc"
ok "8. CI MODE: systemctl unavailable -> exit 0 (clean skip)"

# --- 9. HEARTBEAT wires the canary (block 47) + rc>=2 propagation only ------
grep -q '47. timer-manifest drift canary' "$tier1" \
    || fail "9. heartbeat missing block 47 invocation"
grep -q 'fleet-timer-manifest-drift-canary' "$repo_root/MANIFEST" \
    || fail "9. MANIFEST missing the canary symlink entry"
# rc>=2 propagation guard present
grep -q 'timer_manifest_drift_rc' "$tier1" \
    || fail "9. heartbeat missing timer_manifest_drift_rc propagation"
ok "9. HEARTBEAT wires block 47 + MANIFEST entry + rc>=2 propagation"

# --- 10. RECONCILER derives the signal from the LOUD line (auto-file path) --
: >"$triage"
printf '%s\n' \
    'fleet-heartbeat-tier1.timer' \
    '0509-sneaker-resale-recall-canary.timer' >"$live"
: >"$trans"
set +e; run_canary "$live" "$trans" "$m" "$triage"; rc=$?; set -e
[[ "$rc" -eq 1 ]] || fail "10. setup: drift must exit 1"
sig=$(python3 - "$reconciler" "$triage" <<'PY'
import importlib.util, re, sys
spec = importlib.util.spec_from_file_location('dqr', sys.argv[1])
dqr = importlib.util.module_from_spec(spec); spec.loader.exec_module(dqr)
TRIAGE_RE = re.compile(r'^\[(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)\] \[([A-Z][A-Z0-9_-]*)\] (.*)$')
sigs = set()
for line in open(sys.argv[2]):
    m = TRIAGE_RE.match(line.rstrip('\n'))
    if m:
        for s in dqr.derive_signals(m.group(2), m.group(3)):
            sigs.add(s)
print(sorted(sigs)[0] if sigs else '')
PY
)
[[ "$sig" == "timer-manifest/0509-sneaker-resale-recall-canary.timer" ]] \
    || fail "10. reconciler must derive signal, got '$sig'"
labels=$(python3 - "$reconciler" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location('dqr', sys.argv[1])
dqr = importlib.util.module_from_spec(spec); spec.loader.exec_module(dqr)
print(','.join(dqr.routing_labels('TIMER-MANIFEST-DRIFT')))
PY
)
[[ "$labels" == "agent-ready" ]] \
    || fail "10. routing labels must be agent-ready, got '$labels'"
ok "10. RECONCILER derives signal: timer-manifest/<unit> -> agent-ready (auto-file)"

echo "timer-manifest drift canary drills passed — fleet-ops#4647 prevention verified"
