#!/usr/bin/env bash
# tests/slo-budget.test.sh
#
# fleet-ops#1291: pin the SLO error-budget system end-to-end:
#   1. lib/slo_budget.py self-test passes (budget math canon).
#   2. config/slo-definitions.json is valid JSON with 5-7 SLOs, each
#      carrying id/name/target/window_seconds/direction/metric_source/
#      instrumented/ratchet/severity. No fast_burn severity is "page"
#      (fleet-ops#1534 phone-chokepoint: severity=page is reserved for
#      RepairDispatchDown only).
#   3. The exporter (_emit_slo_metrics) emits the fleet_slo_* family
#      offline: instrumented SLOs get compliance + budget gauges +
#      instrumented=1; uninstrumented SLOs get instrumented=0 only.
#      Exactly one # HELP and one # TYPE per metric name (node_exporter
#      textfile collector rejects the whole file on duplicate HELP/TYPE).
#   4. config/fleet_rules.yml parses (yaml) and contains the fleet_slo_burn
#      group with FleetSloMetricsAbsent + fast/slow burn alerts. No new
#      severity=page alert (phone-chokepoint preserved). Burn alerts are
#      gated on fleet_slo_instrumented == 1.
#   5. prompts/weekly-fleet-review.md mentions the L7 SLO lens, L8
#      alert-quality lens, and the SLO ratchet.
#   6. MANIFEST declares lib/slo_budget.py and config/slo-definitions.json.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
slo_lib="$repo_root/lib/slo_budget.py"
slo_defs="$repo_root/config/slo-definitions.json"
exporter="$repo_root/libexec/fleet-metrics-export.py"
rules="$repo_root/config/fleet_rules.yml"
wfr="$repo_root/prompts/weekly-fleet-review.md"
manifest="$repo_root/MANIFEST"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$slo_lib" ]]   || fail "lib/slo_budget.py not found"
[[ -f "$slo_defs" ]]  || fail "config/slo-definitions.json not found"
[[ -f "$exporter" ]]  || fail "exporter not found"
[[ -f "$rules" ]]     || fail "fleet_rules.yml not found"
[[ -f "$wfr" ]]       || fail "weekly-fleet-review.md not found"
[[ -f "$manifest" ]]  || fail "MANIFEST not found"
command -v python3 >/dev/null 2>&1 || fail "python3 required"
command -v jq >/dev/null 2>&1 || fail "jq required"

scratch="$(mktemp -d -t slo-test.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# =========================================================================
# 1. lib/slo_budget.py self-test
# =========================================================================
python3 "$slo_lib" >/dev/null || fail "lib/slo_budget.py self-test failed"
ok "lib/slo_budget.py self-test passes"

# =========================================================================
# 2. config/slo-definitions.json shape
# =========================================================================
n_slos=$(jq '.slos | length' "$slo_defs")
[[ "$n_slos" -ge 5 && "$n_slos" -le 7 ]] || fail "expected 5-7 SLOs, got $n_slos"
ok "slo-definitions.json has $n_slos SLOs (5-7 range)"

# Every SLO has the required fields.
python3 - "$slo_defs" <<'PY' || fail "SLO field check failed"
import sys, json
d = json.load(open(sys.argv[1]))
req = ("id","name","target","window_seconds","direction","metric_source",
       "instrumented","ratchet","severity")
for s in d["slos"]:
    for f in req:
        assert f in s, f"SLO {s.get('id','?')} missing field {f}"
    assert s["direction"] in ("above","below"), f"{s['id']} bad direction"
    assert s["severity"]["fast_burn"] != "page", \
        f"{s['id']} fast_burn=page violates phone-chokepoint (fleet-ops#1534)"
    assert s["severity"]["slow_burn"] != "page", \
        f"{s['id']} slow_burn=page violates phone-chokepoint"
    # ratchet has either notch/stop_at (ratio) or notch_seconds/stop_at_seconds (latency)
    has_ratio = "notch" in s["ratchet"] and "stop_at" in s["ratchet"]
    has_seconds = "notch_seconds" in s["ratchet"] and "stop_at_seconds" in s["ratchet"]
    assert has_ratio or has_seconds, f"{s['id']} ratchet missing notch/stop_at pair"
    assert "min_weeks_unspent" in s["ratchet"], f"{s['id']} ratchet missing min_weeks_unspent"
print("OK: all SLOs have required fields + no severity=page")
PY

# =========================================================================
# 3. Exporter SLO emission (offline, stubbed)
# =========================================================================
python3 - "$exporter" "$slo_defs" "$repo_root/config/seat-caps.json" "$scratch" <<'PY' || fail "exporter SLO emission failed"
import importlib.util, sys, json, tempfile
from pathlib import Path
exporter, slo_defs, seat_caps, scratch = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("fme", exporter)
m = importlib.util.module_from_spec(spec)
sys.modules["fme"] = m
spec.loader.exec_module(m)
m.SLO_DEFS_DEFAULT = Path(slo_defs)
m.SLO_DEFS_FALLBACK = Path(slo_defs)
m.SEAT_CAPS_DEFAULT = Path(seat_caps)
m.SEAT_CAPS_FALLBACK = Path(seat_caps)
# Stub the per-seat health ledger so seat_availability compliance is emitted
# hermetically. Without this the exporter reads the real SEAT_LEDGER
# (/home/nish/...), which exists on the VPS but not in CI, so the SLO reports
# instrumented=0 and the "instrumented SLOs emit compliance" loop fails
# (fleet-ops#2377 red-on-main 2026-08-30). Two healthy enrolled providers of
# 13 -> compliance is emitted (the exact value is not asserted here; section
# 3b pins the rollup math).
seat_dir = Path(scratch) / "seats"
seat_dir.mkdir(exist_ok=True)
for prov in ("devin", "cursor"):
    (seat_dir / f"{prov}__m1.json").write_text(json.dumps({
        "provider": prov, "model": "m1",
        "health_class": "healthy", "seat_dead": False}))
m.SEAT_LEDGER = seat_dir
# Stub waste prom
wp = Path(scratch) / "fleet-waste.prom"
wp.write_text("# HELP fleet_waste_ratio ...\n# TYPE fleet_waste_ratio gauge\nfleet_waste_ratio 0.08\n")
m.WASTE_PROM = wp
# Stub actions.log (empty) so per-alertname parser returns {}
m.ACTIONS_LOG = Path(scratch) / "actions.log"
m.ACTIONS_LOG.write_text("")

lines = []
main_ci = {"fleet-ops": 1, "0509": 1, "siterep-public": 0}
rl = {"core": {"remaining": 4000, "limit": 5000, "reset": 0, "low": 0},
      "search": {"remaining": 30, "limit": 30, "reset": 0, "low": 0},
      "graphql": {"remaining": 4800, "limit": 5000, "reset": 0, "low": 0}}
m._emit_slo_metrics(lines, main_ci, 1, rl)
text = "\n".join(lines)

# HELP/TYPE appear exactly once per metric name.
import re
helps = re.findall(r'^# HELP (\S+)', text, re.M)
types = re.findall(r'^# TYPE (\S+)', text, re.M)
from collections import Counter
dup_h = [n for n,c in Counter(helps).items() if c > 1]
dup_t = [n for n,c in Counter(types).items() if c > 1]
assert not dup_h, f"duplicate # HELP: {dup_h}"
assert not dup_t, f"duplicate # TYPE: {dup_t}"
print("OK: exactly one # HELP and # TYPE per SLO metric name")

# Instrumented SLOs emit compliance + instrumented=1.
defs = json.loads(Path(slo_defs).read_text())
inst = [s["id"] for s in defs["slos"] if s.get("instrumented")]
uninst = [s["id"] for s in defs["slos"] if not s.get("instrumented")]
for sid in inst:
    assert f'fleet_slo_compliance{{slo="{sid}"}}' in text, f"{sid} missing compliance"
    assert f'fleet_slo_instrumented{{slo="{sid}"}} 1' in text, f"{sid} not instrumented=1"
for sid in uninst:
    assert f'fleet_slo_instrumented{{slo="{sid}"}} 0' in text, f"{sid} not instrumented=0"
    assert f'fleet_slo_compliance{{slo="{sid}"}}' not in text, f"{sid} should not emit compliance"
print(f"OK: {len(inst)} instrumented + {len(uninst)} uninstrumented SLOs emitted correctly")

# main_green compliance = 2/3 (two green repos of three).
assert "fleet_slo_compliance{slo=\"main_green\"} 0.666667" in text, "main_green compliance wrong"
print("OK: main_green compliance = 0.666667 (2/3 green)")

# waste_ratio compliance = 0.08/0.10 = 0.8 (within budget, "below" gauge).
assert "fleet_slo_compliance{slo=\"waste_ratio\"} 0.800000" in text, "waste_ratio compliance wrong"
print("OK: waste_ratio compliance = 0.800000 (0.08/0.10)")
PY

# =========================================================================
# 3b. seat_availability = healthy-enrolled rollup, NOT single-seat 0/1 / 13
# =========================================================================
python3 - "$exporter" "$slo_defs" "$scratch" <<'PY' || fail "seat_availability rollup check failed"
import importlib.util, sys, json
from pathlib import Path
exporter, slo_defs, scratch = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("fme", exporter)
m = importlib.util.module_from_spec(spec)
sys.modules["fme"] = m
spec.loader.exec_module(m)
defs = json.loads(Path(slo_defs).read_text())
slo = next(s for s in defs["slos"] if s["id"] == "seat_availability")

# Hermetic fixture: 3 enrolled providers (cap>0), per-seat ledgers:
#   a__m1 healthy, a__m2 dead-cred (seat_dead) -> a healthy (one live model)
#   b__m1 healthy                               -> b healthy
#   c__m1 quota_exhausted, c__m2 transient_fault -> c NOT healthy
# Expected compliance = 2/3. The pre-fix bug pinned this at 0/3 (or 1/3)
# by dividing the single pi-seat-health 0/1 gauge by the provider count.
seat_dir = Path(scratch) / "seats"
seat_dir.mkdir(exist_ok=True)
fixtures = {
    "a__m1.json": {"provider": "a", "model": "m1",
                    "health_class": "healthy", "seat_dead": False},
    "a__m2.json": {"provider": "a", "model": "m2",
                    "health_class": "credentials_bad", "seat_dead": True},
    "b__m1.json": {"provider": "b", "model": "m1",
                    "health_class": "healthy", "seat_dead": False},
    "c__m1.json": {"provider": "c", "model": "m1",
                    "health_class": "quota_exhausted", "seat_dead": False},
    "c__m2.json": {"provider": "c", "model": "m2",
                    "health_class": "transient_fault", "seat_dead": False},
}
for name, data in fixtures.items():
    (seat_dir / name).write_text(json.dumps(data))
m.SEAT_LEDGER = seat_dir
caps = Path(scratch) / "seat-caps.json"
caps.write_text(json.dumps({"providers": {
    "a": {"cap": 1}, "b": {"cap": 1}, "c": {"cap": 1}}}))
m.SEAT_CAPS_DEFAULT = caps
m.SEAT_CAPS_FALLBACK = caps

comp, inst = m._slo_compliance(slo, {}, 0, {}, None, 3)
assert inst, "seat_availability should be instrumented with a readable ledger"
assert abs(comp - 2 / 3) < 1e-9, f"expected 2/3 rollup, got {comp}"
print("OK: seat_availability compliance = 0.666667 (2/3 healthy-enrolled rollup)")

# A provider with no ledger at all is not proven healthy (fail-safe).
caps2 = Path(scratch) / "seat-caps2.json"
caps2.write_text(json.dumps({"providers": {
    "a": {"cap": 1}, "b": {"cap": 1}, "d": {"cap": 1}}}))
m.SEAT_CAPS_DEFAULT = caps2
m.SEAT_CAPS_FALLBACK = caps2
comp2, inst2 = m._slo_compliance(slo, {}, 0, {}, None, 3)
assert inst2 and abs(comp2 - 2 / 3) < 1e-9, f"expected 2/3 with unproven provider d, got {comp2}"
print("OK: unledgered enrolled provider counts unhealthy (fail-safe rollup)")

# Missing ledger dir -> source unavailable (instrumented=0), not 1/13.
m.SEAT_LEDGER = Path(scratch) / "no-such-seats-dir"
comp3, inst3 = m._slo_compliance(slo, {}, 0, {}, None, 3)
assert not inst3, "seat_availability must be uninstrumented when ledger unreadable"
assert comp3 is None, f"expected None compliance on missing ledger, got {comp3}"
print("OK: missing seat ledger -> instrumented=0 (no false 1/13 pin)")
PY

# =========================================================================
# 4. fleet_rules.yml: SLO group + phone-chokepoint preserved
# =========================================================================
python3 - "$rules" <<'PY' || fail "rules check failed"
import sys, yaml
with open(sys.argv[1]) as f: cfg = yaml.safe_load(f)
groups = {g["name"]: g for g in cfg["groups"]}
assert "fleet_slo_burn" in groups, "missing fleet_slo_burn group"
slo_rules = {r["alert"]: r for r in groups["fleet_slo_burn"]["rules"]}
assert "FleetSloMetricsAbsent" in slo_rules, "missing FleetSloMetricsAbsent"
assert "FleetSloMainGreenFastBurn" in slo_rules, "missing fast-burn alert"
assert "FleetSloMainGreenSlowBurn" in slo_rules, "missing slow-burn alert"
# Fast burn = critical, slow burn = warning (never page).
assert slo_rules["FleetSloMainGreenFastBurn"]["labels"]["severity"] == "critical"
assert slo_rules["FleetSloMainGreenSlowBurn"]["labels"]["severity"] == "warning"
# Phone-chokepoint: still exactly one severity=page (RepairDispatchDown).
page = [(g["name"], r["alert"]) for g in cfg["groups"] for r in g["rules"]
        if r.get("labels",{}).get("severity") == "page"]
assert len(page) == 1 and page[0][1] == "RepairDispatchDown", \
    f"phone-chokepoint violated: {page}"
# Burn alerts gated on instrumented=1.
for name, r in slo_rules.items():
    if name == "FleetSloMetricsAbsent": continue
    assert "fleet_slo_instrumented" in r["expr"], \
        f"{name} not gated on fleet_slo_instrumented"
print("OK: fleet_slo_burn group present, phone-chokepoint preserved, burn alerts gated on instrumented=1")
PY

# =========================================================================
# 5. WFR mentions L7 SLO + L8 alert-quality + SLO ratchet
# =========================================================================
grep -q "L7 SLO error budgets" "$wfr" || fail "WFR missing L7 SLO lens"
grep -q "L8 alert-quality" "$wfr" || fail "WFR missing L8 alert-quality lens"
grep -q "SLO ratchet" "$wfr" || fail "WFR missing SLO ratchet"
grep -q "8-lens" "$wfr" || fail "WFR not updated to 8-lens"
ok "WFR has L7 SLO lens + L8 alert-quality lens + SLO ratchet + 8-lens count"

# =========================================================================
# 6. MANIFEST declares the new files
# =========================================================================
grep -q "lib/slo_budget.py" "$manifest" || fail "MANIFEST missing lib/slo_budget.py"
grep -q "config/slo-definitions.json" "$manifest" || fail "MANIFEST missing config/slo-definitions.json"
ok "MANIFEST declares lib/slo_budget.py + config/slo-definitions.json"

echo
echo "slo-budget: all invariants pass (fleet-ops#1291)"
