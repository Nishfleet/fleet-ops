#!/usr/bin/env bash
# tests/canary-effectiveness.test.sh
#
# fleet-ops#2757: canary effectiveness metric family. Offline (no live
# prometheus, no live gh). Hosted by tests/ci-standards-audit.test.sh so
# P14 runs it without a workflow-file edit.
#
# Proves:
#   1. Helpers: correlate caught vs missed under the 24h prior-failure rule.
#   2. Different organ failure signatures (gauge vs unit journal fixture)
#      attribute to the right organ and do not cross-contaminate.
#   3. Empty window still emits fleet_canary_effectiveness_last_run_seconds
#      (organ heartbeat) + per-organ zeros including effectiveness_ratio.
#   4. Fixture with canary failure → GH bug within 24h = caught; incident
#      without prior failure = missed; ratio = caught/(caught+missed).
#   5. MANIFEST installs the helper + the exporter drop-in (no new timer).
#   6. fleet_rules.yml ships FleetCanaryEffectivenessAbsent +
#      CanaryEffectivenessLow + CanarySilentTooLong.
#   7. config/fleet-organs.json registers the organ with the absent alert.
#   8. promtool check rules (if present).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
helper="$repo_root/lib/canary-effectiveness.py"
rules="$repo_root/config/fleet_rules.yml"
manifest="$repo_root/MANIFEST"
dropin="$repo_root/systemd/fleet-metrics-export.service.d/canary-effectiveness.conf"
organs="$repo_root/config/fleet-organs.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$helper" ]] || fail "missing $helper"
[[ -f "$rules" ]] || fail "missing $rules"
[[ -f "$dropin" ]] || fail "missing $dropin"
[[ -f "$organs" ]] || fail "missing $organs"
command -v python3 >/dev/null 2>&1 || fail "python3 required"
command -v jq >/dev/null 2>&1 || fail "jq required"

scratch="$(mktemp -d -t canary-eff-test.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# =========================================================================
# 1. Correlate helpers (caught vs missed)
# =========================================================================
python3 - "$helper" <<'PY' || fail "correlate helpers failed"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ce", sys.argv[1])
m = importlib.util.module_from_spec(spec)
# Register before exec_module so dataclass frozen classes resolve
# cls.__module__ in sys.modules (same pattern as slo_budget load).
sys.modules["ce"] = m
spec.loader.exec_module(m)

# t0=1000 failure; incident at 1000+3600 (1h later) = caught
# incident at 1000+90000 (>24h) = missed
# incident with no prior failure = missed
fails = [m.Event(organ="0509-surface-probe", ts=1000.0, kind="failure")]
incs = [
    m.Incident(repo="Nishfleet/0509", ts=1000.0 + 3600, number=1),
    m.Incident(repo="Nishfleet/0509", ts=1000.0 + 90000, number=2),
    m.Incident(repo="Nishfleet/0509", ts=500.0, number=3),  # before any failure
]
caught, missed = m.correlate(fails, incs, catch_hours=24)
assert [i.number for i in caught] == [1], caught
assert sorted(i.number for i in missed) == [2, 3], missed

# Cross-organ: failures for organ A must not catch incidents when the
# caller pre-filters — stats_for_organ enforces that.
events = [
    m.Event(organ="0509-surface-probe", ts=1000.0, kind="run"),
    m.Event(organ="0509-surface-probe", ts=1000.0, kind="failure"),
    m.Event(organ="siterep-live-canary", ts=1000.0, kind="run"),
    # siterep never failed
]
incidents = [
    m.Incident(repo="Nishfleet/0509", ts=1000.0 + 1800, number=10),
    m.Incident(repo="Nishfleet/siterep-public", ts=1000.0 + 1800, number=11),
]
by = {s.organ: s for s in m.compute_all(events, incidents)}
assert by["0509-surface-probe"].caught == 1
assert by["0509-surface-probe"].missed == 0
assert by["siterep-live-canary"].caught == 0
assert by["siterep-live-canary"].missed == 1
assert abs(by["0509-surface-probe"].effectiveness_ratio - 1.0) < 1e-9
assert by["siterep-live-canary"].effectiveness_ratio == 0.0
print("OK: correlate")
PY
ok "helpers: correlate caught vs missed; organs do not cross-contaminate"

# =========================================================================
# 2. Empty window still emits the heartbeat + per-organ zeros
# =========================================================================
export FLEET_CANARY_EFF_NOW="2026-09-02T12:00:00Z"
export FLEET_CANARY_EFF_EVENTS="$scratch/empty.json"
export FLEET_CANARY_EFF_OUT="$scratch/empty.prom"
printf '%s\n' '{"events":[],"incidents":[]}' >"$FLEET_CANARY_EFF_EVENTS"
python3 "$helper" --stdout >"$scratch/empty.stdout" \
  || fail "empty export rc nonzero"
grep -q '^fleet_canary_effectiveness_last_run_seconds 1788350400$' "$FLEET_CANARY_EFF_OUT" \
  || fail "heartbeat epoch wrong: $(grep fleet_canary_effectiveness_last_run_seconds "$FLEET_CANARY_EFF_OUT" || echo missing)"
grep -q 'fleet_canary_effectiveness_ratio{organ="0509-surface-probe"} 0.000000' "$FLEET_CANARY_EFF_OUT" \
  || fail "empty window must emit ratio 0 for 0509-surface-probe"
grep -q 'fleet_canary_runs_total{organ="fleet-completion-canary"} 0' "$FLEET_CANARY_EFF_OUT" \
  || fail "empty window must emit runs=0 for completion-canary"
grep -q 'fleet_canary_runs_total{organ="siterep-live-canary"} 0' "$FLEET_CANARY_EFF_OUT" \
  || fail "empty window must emit runs=0 for siterep-live-canary"
grep -q 'fleet_canary_runs_total{organ="fleet-resilience-drill"} 0' "$FLEET_CANARY_EFF_OUT" \
  || fail "empty window must emit runs=0 for resilience-drill"
ok "empty window emits heartbeat + per-organ zeros"

# =========================================================================
# 3. Fixture: caught + missed + different failure signatures
# =========================================================================
# Window ends 2026-09-02T12:00:00Z. Place events inside 30d.
# 0509-surface-probe: failure at T-2h, bug issue 1h later → caught
# fleet-completion-canary: run+failure at T-3h, no incident → failures=1, caught=0
# siterep-live-canary: run only, bug with no prior failure → missed
# fleet-resilience-drill: run+failure, bug 2h later → caught
python3 - <<'PY' >"$scratch/fixture.json"
import json
end = 1788350400  # 2026-09-02T12:00:00Z
events = [
    {"organ": "0509-surface-probe", "ts": end - 7200, "kind": "run"},
    {"organ": "0509-surface-probe", "ts": end - 7200, "kind": "failure",
     "detail": "fleet_probe_success=0"},
    {"organ": "fleet-completion-canary", "ts": end - 10800, "kind": "run"},
    {"organ": "fleet-completion-canary", "ts": end - 10800, "kind": "failure",
     "detail": "Failed with result 'exit-code'."},
    {"organ": "siterep-live-canary", "ts": end - 3600, "kind": "run"},
    {"organ": "fleet-resilience-drill", "ts": end - 14400, "kind": "run"},
    {"organ": "fleet-resilience-drill", "ts": end - 14400, "kind": "failure",
     "detail": "fleet_resilience_drill_all_pass=0"},
]
incidents = [
    {"repo": "Nishfleet/0509", "ts": end - 3600, "number": 101,
     "labels": ["bug"], "title": "auth matrix 500"},
    {"repo": "Nishfleet/siterep-public", "ts": end - 1800, "number": 202,
     "labels": ["regression"], "title": "layout smoke broke"},
    {"repo": "Nishfleet/fleet-ops", "ts": end - 7200, "number": 303,
     "labels": ["bug"], "title": "resilience plane red in prod"},
]
print(json.dumps({"events": events, "incidents": incidents}))
PY
export FLEET_CANARY_EFF_EVENTS="$scratch/fixture.json"
export FLEET_CANARY_EFF_OUT="$scratch/fixture.prom"
python3 "$helper" --stdout >"$scratch/fixture.stdout" \
  || fail "fixture export rc nonzero"

grep -q 'fleet_canary_caught_regressions_total{organ="0509-surface-probe"} 1' "$FLEET_CANARY_EFF_OUT" \
  || fail "0509 should catch 1: $(grep 0509-surface "$FLEET_CANARY_EFF_OUT")"
grep -q 'fleet_canary_missed_regressions_total{organ="0509-surface-probe"} 0' "$FLEET_CANARY_EFF_OUT" \
  || fail "0509 missed should be 0"
grep -q 'fleet_canary_effectiveness_ratio{organ="0509-surface-probe"} 1.000000' "$FLEET_CANARY_EFF_OUT" \
  || fail "0509 ratio should be 1.0"

grep -q 'fleet_canary_failures_total{organ="fleet-completion-canary"} 1' "$FLEET_CANARY_EFF_OUT" \
  || fail "completion-canary failures=1"

# fleet-ops is product_repos for BOTH completion-canary and resilience-drill.
# Incident 303 at end-7200: resilience failed at end-14400 (within 24h) AND
# completion failed at end-10800 (also within 24h). Both organs catch it —
# each organ independently asks "did *I* fail before this incident?".
grep -q 'fleet_canary_caught_regressions_total{organ="fleet-resilience-drill"} 1' "$FLEET_CANARY_EFF_OUT" \
  || fail "resilience should catch 1"
grep -q 'fleet_canary_caught_regressions_total{organ="fleet-completion-canary"} 1' "$FLEET_CANARY_EFF_OUT" \
  || fail "completion-canary also catches the shared fleet-ops incident"

grep -q 'fleet_canary_missed_regressions_total{organ="siterep-live-canary"} 1' "$FLEET_CANARY_EFF_OUT" \
  || fail "siterep should miss 1"
grep -q 'fleet_canary_caught_regressions_total{organ="siterep-live-canary"} 0' "$FLEET_CANARY_EFF_OUT" \
  || fail "siterep caught should be 0"
grep -q 'fleet_canary_effectiveness_ratio{organ="siterep-live-canary"} 0.000000' "$FLEET_CANARY_EFF_OUT" \
  || fail "siterep ratio should be 0"

# last_failure_seconds non-zero for organs that failed
grep -q 'fleet_canary_last_failure_seconds{organ="0509-surface-probe"} 1788343200' "$FLEET_CANARY_EFF_OUT" \
  || fail "0509 last_failure wrong: $(grep 'last_failure.*0509' "$FLEET_CANARY_EFF_OUT" || echo missing)"
ok "fixture: caught/missed attribution across gauge + unit signatures"

# =========================================================================
# 4. MANIFEST + drop-in + no new timer
# =========================================================================
grep -Fxq "lib/canary-effectiveness.py /home/nish/.local/lib/pi-packet/canary-effectiveness.py" "$manifest" \
  || fail "MANIFEST missing lib/canary-effectiveness.py dest"
grep -Fxq "systemd/fleet-metrics-export.service.d/canary-effectiveness.conf /home/nish/.config/systemd/user/fleet-metrics-export.service.d/canary-effectiveness.conf" "$manifest" \
  || fail "MANIFEST missing canary-effectiveness drop-in"
grep -q "ExecStart=-/bin/bash -c 'exec /usr/bin/python3 /home/nish/.local/lib/pi-packet/canary-effectiveness.py'" "$dropin" \
  || fail "drop-in must ExecStart=- the helper under ~/.local/lib/pi-packet/"
# No new timer unit introduced by this change.
[[ ! -f "$repo_root/systemd/canary-effectiveness.timer" ]] \
  || fail "must not add a new timer; piggyback fleet-metrics-export"
[[ ! -f "$repo_root/systemd/canary-effectiveness.service" ]] \
  || fail "must not add a new service; piggyback fleet-metrics-export"
ok "MANIFEST + drop-in wiring; no new timer"

# =========================================================================
# 5. Rules + organ registry
# =========================================================================
grep -q 'alert: FleetCanaryEffectivenessAbsent' "$rules" \
  || fail "rules missing FleetCanaryEffectivenessAbsent"
grep -q 'absent(fleet_canary_effectiveness_last_run_seconds)' "$rules" \
  || fail "Absent rule must watch fleet_canary_effectiveness_last_run_seconds"
grep -q 'alert: CanaryEffectivenessLow' "$rules" \
  || fail "rules missing CanaryEffectivenessLow"
grep -q 'fleet_canary_effectiveness_ratio < 0.02' "$rules" \
  || fail "CanaryEffectivenessLow must gate on ratio < 0.02"
grep -q 'alert: CanarySilentTooLong' "$rules" \
  || fail "rules missing CanarySilentTooLong"

jq -e '.organs[] | select(.name=="canary-effectiveness")
  | select(.heartbeat_metric=="fleet_canary_effectiveness_last_run_seconds")
  | select(.absent_alert=="FleetCanaryEffectivenessAbsent")' "$organs" >/dev/null \
  || fail "fleet-organs.json missing canary-effectiveness organ"
ok "rules + organ registry"

# =========================================================================
# 6. promtool (optional)
# =========================================================================
if command -v promtool >/dev/null 2>&1; then
  promtool check rules "$rules" >/dev/null \
    || fail "promtool check rules failed"
  ok "promtool check rules"
else
  echo "SKIP: promtool not on PATH"
fi

echo "OK: canary-effectiveness: correlate, empty heartbeat, fixture attribution, MANIFEST, rules, organ registry"
