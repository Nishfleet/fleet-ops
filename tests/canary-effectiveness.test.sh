#!/usr/bin/env bash
# tests/canary-effectiveness.test.sh
#
# fleet-ops#2757: canary effectiveness metric family. Offline (no live
# prometheus, no live gh). Hosted by tests/ci-standards-audit.test.sh so
# P14 runs it without a workflow-file edit.
#
# Proves:
#   1. Helpers: correlate caught vs missed under the 24h prior-failure rule.
#      Incidents before the organ's first observed run/failure are not
#      missed (the canary was not yet watching).
#   2. Different organ failure signatures (gauge vs unit journal fixture)
#      attribute to the right organ and do not cross-contaminate.
#   3. Empty window still emits fleet_canary_effectiveness_last_run_seconds
#      (organ heartbeat) + per-organ zeros including effectiveness_ratio.
#   3b. --self-test drill injects a fault and proves the full pipeline
#      detects it (caught=1, ratio=1.0) — fleet-ops#3047.
#   3c. Two-tick retention drill: attribution survives retention loss via
#      the durable event store — fleet-ops#3052.
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

# Pre-observe incidents must not count as missed. Live 2026-09-04
# CanaryEffectivenessLow was 0/0 caught vs 2+1+1 missed because
# 0509#1132 (2026-08-26), 0509#1411 (2026-08-28) and fleet-ops#1466
# (2026-08-28 04:58Z) all predate the organs' first observed run
# (probe 2026-08-29T02:30Z, completion-canary 2026-08-28T21:52Z,
# resilience-drill 2026-08-29T00:25Z). A canary cannot miss a
# regression it was not yet watching. Post-observe misses still count.
first_probe = 1_000.0
pre_inc = m.Incident(repo="Nishfleet/0509", ts=first_probe - 86_400, number=1132)
post_miss = m.Incident(repo="Nishfleet/0509", ts=first_probe + 3_600, number=1419)
post_catch = m.Incident(repo="Nishfleet/0509", ts=first_probe + 8_000, number=1500)
events_obs = [
    m.Event(organ="0509-surface-probe", ts=first_probe, kind="run"),
    m.Event(organ="0509-surface-probe", ts=first_probe + 7_200, kind="run"),
    m.Event(organ="0509-surface-probe", ts=first_probe + 7_200, kind="failure"),
]
by_obs = {s.organ: s for s in m.compute_all(events_obs, [pre_inc, post_miss, post_catch])}
assert by_obs["0509-surface-probe"].caught == 1, by_obs["0509-surface-probe"]
assert by_obs["0509-surface-probe"].missed == 1, by_obs["0509-surface-probe"]
# Pre-observe 1132 dropped; 1419 (no prior failure) missed; 1500 caught.
# Organs with zero observed events must not inherit another organ's
# product-repo incidents as misses (fleet-ops#1466 vs resilience-drill).
by_none = {s.organ: s for s in m.compute_all(
    [m.Event(organ="fleet-completion-canary", ts=first_probe, kind="run")],
    [m.Incident(repo="Nishfleet/fleet-ops", ts=first_probe - 100, number=1466)],
)}
assert by_none["fleet-completion-canary"].missed == 0, by_none["fleet-completion-canary"]
assert by_none["fleet-resilience-drill"].missed == 0, by_none["fleet-resilience-drill"]
assert by_none["fleet-completion-canary"].caught == 0
print("OK: pre-observe")
PY
ok "helpers: correlate caught vs missed; organs do not cross-contaminate"
ok "helpers: pre-observe incidents are not missed"

# =========================================================================
# 2. Empty window still emits the heartbeat + per-organ zeros
# =========================================================================
export FLEET_CANARY_EFF_NOW="2026-09-02T12:00:00Z"
export FLEET_CANARY_EFF_EVENTS="$scratch/empty.json"
export FLEET_CANARY_EFF_OUT="$scratch/empty.prom"
export FLEET_CANARY_EFF_STORE="$scratch/empty-store.jsonl"
rm -f "$FLEET_CANARY_EFF_STORE"
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
export FLEET_CANARY_EFF_STORE="$scratch/fixture-store.jsonl"
rm -f "$FLEET_CANARY_EFF_STORE"
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
# 3b. Self-test drill: inject a fault and prove the emitter detects it
# (fleet-ops#3047). The live exporter showed caught=0 across all organs
# because the 30d incident window exceeds the ~7d retention of
# Prometheus/journald, so every real incident predates the earliest
# observable canary failure and is honestly unclassifiable. The self-test
# injects a classifiable fault (failure at T0, bug 1h later in the same
# product repo) and proves the full compute_all -> export_prom pipeline
# classifies it as caught. This is the drill that proves the guard fires.
# =========================================================================
selftest_out="$scratch/selftest.stdout"
selftest_err="$scratch/selftest.stderr"
python3 "$helper" --self-test >"$selftest_out" 2>"$selftest_err" \
  || fail "self-test exited nonzero: $(cat "$selftest_err")"
grep -q "SELF-TEST OK: injected fault detected (caught=1, ratio=1.0)" "$selftest_out" \
  || fail "self-test did not report OK: $(cat "$selftest_out") $(cat "$selftest_err")"
# The self-test must NOT touch the real node-exporter path.
if [[ -f /var/lib/prometheus/node-exporter/fleet-canary-effectiveness.prom ]]; then
  # Confirm it wrote to a temp dir, not the real path (mtime unchanged
  # is not assertable here; instead verify the self-test stdout has no
  # "wrote /var/lib" line).
  ! grep -q "wrote /var/lib/prometheus" "$selftest_err" \
    || fail "self-test must not write the real node-exporter path"
fi
ok "self-test: injected fault detected end-to-end (caught=1, ratio=1.0)"

# =========================================================================
# 3c. Two-tick retention drill (fleet-ops#3052). The exporter's 30d window
# outlives the ~7d retention of Prometheus/journald, so a real incident
# older than retention is unclassifiable and effectiveness can never be
# demonstrated (the escalated CanaryEffectivenessLow/CanarySilentTooLong
# chains). The durable event store keeps every observed event for the
# window; this drill proves attribution survives retention loss between
# ticks: tick 1 observes a failure + bug, tick 2's live source no longer
# returns the events, and the incident must STILL be caught=1. Without the
# store, tick 2 would emit caught=0 — the exact silent regression this
# issue escalated on.
# =========================================================================
export FLEET_CANARY_EFF_NOW="2026-09-02T12:00:00Z"
export FLEET_CANARY_EFF_STORE="$scratch/twotick-store.jsonl"
rm -f "$FLEET_CANARY_EFF_STORE"
python3 - <<'PY' >"$scratch/twotick-1.json"
import json
end = 1788350400  # 2026-09-02T12:00:00Z
fail_ts = end - 7200
inc_ts = end - 3600
print(json.dumps({
    "events": [
        {"organ": "0509-surface-probe", "ts": fail_ts, "kind": "run",
         "detail": "run"},
        {"organ": "0509-surface-probe", "ts": fail_ts, "kind": "failure",
         "detail": "probe=0"},
    ],
    "incidents": [
        {"repo": "Nishfleet/0509", "ts": inc_ts, "number": 999901,
         "labels": ["bug"], "title": "tick1 regression"},
    ],
}))
PY
python3 - <<'PY' >"$scratch/twotick-2.json"
import json
end = 1788350400  # 2026-09-02T12:00:00Z
inc_ts = end - 3600
print(json.dumps({
    "events": [],  # retention loss: live source no longer returns it
    "incidents": [
        {"repo": "Nishfleet/0509", "ts": inc_ts, "number": 999901,
         "labels": ["bug"], "title": "tick1 regression"},
    ],
}))
PY
export FLEET_CANARY_EFF_EVENTS="$scratch/twotick-1.json"
export FLEET_CANARY_EFF_OUT="$scratch/twotick-1.prom"
python3 "$helper" --stdout >"$scratch/twotick-1.stdout" 2>"$scratch/twotick-1.stderr" \
  || fail "tick 1 export rc nonzero: $(cat "$scratch/twotick-1.stderr")"
grep -q 'fleet_canary_caught_regressions_total{organ="0509-surface-probe"} 1' "$FLEET_CANARY_EFF_OUT" \
  || fail "tick 1 must catch the injected regression"
export FLEET_CANARY_EFF_EVENTS="$scratch/twotick-2.json"
export FLEET_CANARY_EFF_OUT="$scratch/twotick-2.prom"
python3 "$helper" --stdout >"$scratch/twotick-2.stdout" 2>"$scratch/twotick-2.stderr" \
  || fail "tick 2 export rc nonzero: $(cat "$scratch/twotick-2.stderr")"
grep -q 'fleet_canary_caught_regressions_total{organ="0509-surface-probe"} 1' "$FLEET_CANARY_EFF_OUT" \
  || fail "tick 2 lost attribution: the durable store must survive retention loss"
grep -q 'fleet_canary_effectiveness_ratio{organ="0509-surface-probe"} 1.000000' "$FLEET_CANARY_EFF_OUT" \
  || fail "tick 2 ratio must stay 1.0"
# Store dedup: exactly the 2 tick-1 events, no re-observation copy from
# tick 2, and nothing pruned out of the window.
[[ $(wc -l < "$FLEET_CANARY_EFF_STORE") -eq 2 ]] \
  || fail "store dedup broken: $(wc -l < "$FLEET_CANARY_EFF_STORE") lines, want 2"
unset FLEET_CANARY_EFF_STORE FLEET_CANARY_EFF_EVENTS FLEET_CANARY_EFF_OUT FLEET_CANARY_EFF_NOW 2>/dev/null || true
ok "two-tick retention drill: attribution survives retention loss via durable store"

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
grep -q 'fleet_canary_missed_regressions_total > 0' "$rules" \
  || fail "CanarySilentTooLong must gate on missed_regressions_total > 0"

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

  # fleet-ops#3030: CanarySilentTooLong must not fire on a quiet product
  # (runs>0, caught=0, missed=0) and must fire when the canary is missing
  # real user-facing regressions (missed>0). CanaryEffectivenessLow stays
  # quiet when caught+missed=0.
  cat >"$scratch/canary-silent.test.yml" <<YQ
rule_files:
  - $rules
evaluation_interval: 10m
tests:
  - interval: 10m
    name: CanarySilentTooLong fires only while the organ is missing user regressions
    input_series:
      - series: 'fleet_canary_runs_total{organ="resilience-drill"}'
        values: '10x1087'
      - series: 'fleet_canary_caught_regressions_total{organ="resilience-drill"}'
        values: '0x1087'
      - series: 'fleet_canary_missed_regressions_total{organ="resilience-drill"}'
        values: '3x1087'
      - series: 'fleet_canary_effectiveness_ratio{organ="resilience-drill"}'
        values: '0x1087'
      - series: 'fleet_canary_last_failure_seconds{organ="resilience-drill"}'
        values: '0x1087'
    alert_rule_test:
      - eval_time: 7d13h
        alertname: CanarySilentTooLong
        exp_alerts:
          - exp_labels:
              alertname: CanarySilentTooLong
              organ: resilience-drill
              severity: warning
              service: fleet
            exp_annotations:
              summary: 'canary organ resilience-drill silent 7+ days with no caught regression while misses exist'
              description: 'fleet_canary_last_failure_seconds{organ="resilience-drill"} is 0 or older than 7d, caught_regressions_total is 0 AND missed_regressions_total is >0 while the organ is still running (fleet-ops#2757 / fleet-ops#3030). A silent canary may be testing the wrong surface. Confirm the organ''s failure signature still matches the product path users hit.'
      - eval_time: 7d13h
        alertname: CanaryEffectivenessLow
        exp_alerts:
          - exp_labels:
              alertname: CanaryEffectivenessLow
              organ: resilience-drill
              severity: warning
              service: fleet
            exp_annotations:
              summary: 'canary organ resilience-drill effectiveness_ratio < 0.02 over trailing 30d'
              description: 'fleet_canary_effectiveness_ratio{organ="resilience-drill"} is below 0.02 while at least one user-facing incident landed in the window (fleet-ops#2757). The canary is running but not catching regressions before users. Inspect fleet_canary_caught_regressions_total / fleet_canary_missed_regressions_total and the organ''s failure signature.'
  - interval: 10m
    name: CanarySilentTooLong stays quiet on a product with no user incidents
    input_series:
      - series: 'fleet_canary_runs_total{organ="resilience-drill"}'
        values: '9x1087'
      - series: 'fleet_canary_caught_regressions_total{organ="resilience-drill"}'
        values: '0x1087'
      - series: 'fleet_canary_missed_regressions_total{organ="resilience-drill"}'
        values: '0x1087'
      - series: 'fleet_canary_effectiveness_ratio{organ="resilience-drill"}'
        values: '0x1087'
      - series: 'fleet_canary_last_failure_seconds{organ="resilience-drill"}'
        values: '0x1087'
    alert_rule_test:
      - eval_time: 7d13h
        alertname: CanarySilentTooLong
        exp_alerts: []
      - eval_time: 7d13h
        alertname: CanaryEffectivenessLow
        exp_alerts: []
YQ
  if ! out="$(promtool test rules "$scratch/canary-silent.test.yml" 2>&1)"; then
    fail "promtool test rules failed: $out"
  fi
  grep -q "SUCCESS" <<<"$out" \
    || fail "promtool test rules did not succeed: $out"
  ok "promtool test rules: CanarySilentTooLong/CanaryEffectivenessLow fire/silent correctly"
else
  echo "SKIP: promtool not on PATH"
fi

echo "OK: canary-effectiveness: correlate, empty heartbeat, fixture attribution, MANIFEST, rules, organ registry"
