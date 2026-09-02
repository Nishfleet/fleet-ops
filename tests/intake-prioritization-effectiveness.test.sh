#!/usr/bin/env bash
# tests/intake-prioritization-effectiveness.test.sh
#
# fleet-ops#2759: intake prioritization effectiveness metric (precedence-band
# product-first hold -> product merge lift). Hosted by
# tests/ci-standards-audit.test.sh so P14 runs it without a workflow-file
# edit (the worker App cannot push .github/workflows/**).
#
# Proves, offline (no gh, no prometheus, no live systemd):
#   1. Hold periods are identified from journal evidence (pi-intake@fleet-ops
#      `held-in-buffer:` = hold, `claimed+spawned` = released, fleet-heartbeat
#      `36.5. product-ratio cache STALE|MISSING` = fails open) and float
#      forward-filled into exact segments.
#   2. Merge rates are computed correctly: merges/day during hold vs baseline.
#   3. The effectiveness lift ratio (hold_rate - baseline_rate)/baseline_rate
#      is correct, and the control-plane (fleet-ops) week rate is correct.
#   4. Edge cases: no hold periods, no merges, gh-unavailable merges (None),
#      stale hold sample (hold_active -> 0), pre-window seed (a hold that
#      started before the window still counts inside it).
#   5. main() end-to-end (env seams only) writes a promtool-valid textfile
#      carrying the issue's exact metric names + labels, HELP/TYPE once each.
#   6. config/fleet_rules.yml ships IntakePrioritizationIneffective +
#      IntakeHoldStarvesFleet + the organ-heartbeat FleetIntakeEffectivenessAbsent;
#      promtool check rules passes (if promtool present).
#   7. MANIFEST installs the helper + the drop-in, fleet-organs.json registers
#      the intake-effectiveness organ, and ci-standards-audit hosts this test.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
helper="$repo_root/lib/intake-prioritization-effectiveness.py"
rules="$repo_root/config/fleet_rules.yml"
manifest="$repo_root/MANIFEST"
organs="$repo_root/config/fleet-organs.json"
dropin="$repo_root/systemd/fleet-metrics-export.service.d/intake-effectiveness.conf"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$helper" ]] || fail "missing helper: $helper"
[[ -f "$rules" ]] || fail "missing rules: $rules"
[[ -f "$manifest" ]] || fail "missing MANIFEST"
[[ -f "$organs" ]] || fail "missing fleet-organs.json"
[[ -f "$dropin" ]] || fail "missing drop-in: $dropin"
command -v python3 >/dev/null 2>&1 || fail "python3 required"
command -v jq >/dev/null 2>&1 || fail "jq required"

scratch="$(mktemp -d -t ipe-test.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# =========================================================================
# 1-4. Pure helpers: journal parsing, hold segments, rates, lift, edges
# =========================================================================
python3 - "$helper" <<'PY' || fail "helper logic failed"
import importlib.util, json, sys, time
spec = importlib.util.spec_from_file_location("ipe", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

START, NOW = 0, 14 * 86400          # 14-day window: epoch 0 .. day 14
EIGHT_DAYS = 8 * 86400

# --- (a) hold periods from journal evidence --------------------------------
journal = "\n".join([
    json.dumps({"__REALTIME_TIMESTAMP": str((-3600) * 1_000_000),
                "MESSAGE": "held-in-buffer: (fleet-ops is self-maintenance, self-maintenance ratio 0.80 > 0.5) — product-first precedence, product repos only"}),
    json.dumps({"__REALTIME_TIMESTAMP": str(100 * 1_000_000),
                "MESSAGE": "held-in-buffer: (fleet-ops is self-maintenance, self-maintenance ratio 0.80 > 0.5) — product-first precedence, product repos only"}),
    # floor-lane issue line must NOT become a hold sample (summary only)
    json.dumps({"__REALTIME_TIMESTAMP": str(100 * 1_000_000),
                "MESSAGE": "issue 42 (x): held-in-buffer floor lane (allow-band-surge-legit) — one claim, queue not hard-stalled"}),
    json.dumps({"__REALTIME_TIMESTAMP": str(EIGHT_DAYS * 1_000_000),
                "MESSAGE": "issue 43 (y): claimed+spawned"}),
    json.dumps({"__REALTIME_TIMESTAMP": str(900000 * 1_000_000),
                "MESSAGE": "issue 44 (z): claimed+spawned"}),
    # heartbeat cache-death evidence is a non-hold sample
    json.dumps({"__REALTIME_TIMESTAMP": str(950000 * 1_000_000),
                "MESSAGE": "36.5. product-ratio cache STALE age=9999s threshold=1800s"}),
    # heartbeat 'fresh' is neutral evidence, must not be sampled
    json.dumps({"__REALTIME_TIMESTAMP": str(960000 * 1_000_000),
                "MESSAGE": "36.5. product-ratio cache fresh (age=10s threshold=1800s)"}),
    "this is not json at all",
])
samples = m.parse_journal_samples(journal, 0)
expected = {(-3600, True), (100, True), (EIGHT_DAYS, False), (900000, False), (950000, False)}
assert set(samples) == expected, (set(samples), expected)
assert samples.count((100, True)) == 1, "floor-lane issue line leaked as a sample"
assert (960000, False) not in samples, "heartbeat 'fresh' is neutral, not sampled"

segs = m.hold_segments(samples, START, NOW)
# [0,8d) hold (pre-window seed True at -3600 carries into the window),
# [8d,950000) released, [950000,NOW) released -> hold = first 8 days.
hold_s = sum(e - s for s, e, h in segs if h)
assert abs(hold_s - EIGHT_DAYS) < 1e-6, hold_s
st_mid = m.compute(samples, [], 100, 200)   # fresh True sample -> active
assert st_mid["hold_active"] == 1

# stale hold sample: last evidence older than HOLD_ACTIVE_MAX_AGE_S -> 0
stale = m.compute([(-3600, True), (100, True)], [], START, NOW)
assert stale["hold_active"] == 0, stale["hold_active"]

# --- (b)+(c) merge rates and lift ratio -----------------------------------
merges = [
    {"repo": "Nishfleet/0509", "epoch": 1000},        # hold
    {"repo": "Nishfleet/0509", "epoch": 50000},       # hold
    {"repo": "Nishfleet/0509", "epoch": 200000},      # hold
    {"repo": "Nishfleet/0509", "epoch": 600000},      # hold  -> 4 in 8 days
    {"repo": "Nishfleet/0509", "epoch": 800000},      # baseline
    {"repo": "Nishfleet/fleet-ops", "epoch": 1000},   # hold
    {"repo": "Nishfleet/fleet-ops", "epoch": 100000}, # hold
    {"repo": "Nishfleet/fleet-ops", "epoch": 300000}, # hold  -> 3 in 8 days
    {"repo": "Nishfleet/fleet-ops", "epoch": 900000}, # baseline
    {"repo": "Nishfleet/fleet-ops", "epoch": 1000000},# baseline -> 2 in 6 days
    {"repo": "Nishfleet/other", "epoch": 500},        # ignored repo
    {"repo": "Nishfleet/0509", "epoch": START - 1},   # outside window, ignored
]
st = m.compute(samples, merges, START, NOW)
assert abs(st["hold_fraction"] - 8 / 14) < 1e-9, st["hold_fraction"]
assert abs(st["product_rate_hold"] - 0.5) < 1e-9, st["product_rate_hold"]      # 4/8 d
assert abs(st["product_rate_baseline"] - (1 / 6)) < 1e-9, st["product_rate_baseline"]  # 1/6 d
assert abs(st["control_rate_hold"] - (3 / 8)) < 1e-9, st["control_rate_hold"]
assert abs(st["control_rate_baseline"] - (2 / 6)) < 1e-9, st["control_rate_baseline"]
assert abs(st["effectiveness"] - 2.0) < 1e-6, st["effectiveness"]              # (0.5-1/6)/(1/6)
assert abs(st["control_rate_week"] - (5 / 14) * 7) < 1e-9, st["control_rate_week"]

# --- (d) edge cases --------------------------------------------------------
no_hold = m.compute([], merges, START, NOW)
assert no_hold["hold_fraction"] == 0.0 and no_hold["hold_active"] == 0
assert no_hold["product_rate_hold"] is None and no_hold["effectiveness"] is None
assert abs(no_hold["product_rate_baseline"] - (5 / 14)) < 1e-9   # all merges baseline

no_merges = m.compute(samples, [], START, NOW)
assert no_merges["product_rate_hold"] == 0.0
assert no_merges["product_rate_baseline"] == 0.0
assert no_merges["effectiveness"] is None    # baseline rate 0 -> omitted
assert no_merges["control_rate_week"] == 0.0

gh_down = m.compute(samples, None, START, NOW)
assert gh_down["product_rate_hold"] is None and gh_down["effectiveness"] is None
assert gh_down["hold_fraction"] == 8 / 14    # hold gauges still present

print("HELPER-CHECKS DONE")
PY
ok "helpers: journal -> segments -> rates -> lift -> edges"

# =========================================================================
# 5. main() end-to-end prom export (env seams only)
# =========================================================================
mkdir -p "$scratch"
cat > "$scratch/hold-journal.jsonl" <<'JOURNAL'
{"__REALTIME_TIMESTAMP": "-3600000000", "MESSAGE": "held-in-buffer: (fleet-ops is self-maintenance, self-maintenance ratio 0.80 > 0.5) — product-first precedence"}
{"__REALTIME_TIMESTAMP": "100000000", "MESSAGE": "held-in-buffer: (fleet-ops is self-maintenance, self-maintenance ratio 0.80 > 0.5) — product-first precedence"}
{"__REALTIME_TIMESTAMP": "691200000000", "MESSAGE": "issue 43 (y): claimed+spawned"}
{"__REALTIME_TIMESTAMP": "900000000000", "MESSAGE": "36.5. product-ratio cache MISSING path=/var/lib/prometheus/node-exporter/fleet-queue-product-ratio.prom"}
JOURNAL
python3 - "$scratch" <<'PY' || fail "fixture build failed"
import json, sys, time
out = json.dumps({"ts": time.time(), "data": [
    {"repo": "Nishfleet/0509", "epoch": 1000},
    {"repo": "Nishfleet/0509", "epoch": 50000},
    {"repo": "Nishfleet/0509", "epoch": 200000},
    {"repo": "Nishfleet/0509", "epoch": 600000},
    {"repo": "Nishfleet/0509", "epoch": 800000},
    {"repo": "Nishfleet/fleet-ops", "epoch": 1000},
    {"repo": "Nishfleet/fleet-ops", "epoch": 100000},
    {"repo": "Nishfleet/fleet-ops", "epoch": 300000},
    {"repo": "Nishfleet/fleet-ops", "epoch": 900000},
    {"repo": "Nishfleet/fleet-ops", "epoch": 1000000},
]})
open(sys.argv[1] + "/merges-cache.json", "w").write(out)
PY
OUT="$scratch/fleet-intake-effectiveness.prom" \
INTAKE_OUT="$scratch/fleet-intake-effectiveness.prom" \
INTAKE_HOLD_JOURNAL="$scratch/hold-journal.jsonl" \
INTAKE_MERGES_CACHE="$scratch/merges-cache.json" \
INTAKE_NOW="1970-01-15T00:00:00Z" \
python3 "$helper" --export || fail "main() --export failed"

python3 - "$scratch/fleet-intake-effectiveness.prom" <<'PY' || fail "prom shape failed"
import re, sys
prom = open(sys.argv[1]).read()
fams = {}
for mline in re.finditer(r'^(fleet_intake_[a-z0-9_]+)(\{.*\}) ([0-9.eE+-]+)$', prom, re.M):
    fam, labels, val = mline.groups()
    fams.setdefault(fam, {})[labels] = val
issue_fams = {
    "fleet_intake_hold_active": {r'{repo="fleet-ops"}': "0"},
    "fleet_intake_product_merge_rate_during_hold": {r'{repo="0509"}': "0.500000"},
    "fleet_intake_product_merge_rate_baseline": {r'{repo="0509"}': "0.166667"},
    "fleet_intake_control_merge_rate_during_hold": {r'{repo="fleet-ops"}': "0.375000"},
    "fleet_intake_prioritization_effectiveness": {r'{repo="0509"}': "2.000000"},
}
for fam, want in issue_fams.items():
    assert fam in fams and want == {k: v for k, v in fams[fam].items() if k in want}, (fam, fams.get(fam))
for fam in list(issue_fams) + ["fleet_intake_hold_fraction_14d",
                               "fleet_intake_control_merge_rate_baseline",
                               "fleet_intake_control_merge_rate_week"]:
    assert prom.count(f"# HELP {fam} ") == 1, f"HELP dup/missing for {fam}"
    assert prom.count(f"# TYPE {fam} ") == 1, f"TYPE dup/missing for {fam}"
assert re.search(r'^fleet_intake_effectiveness_last_run_seconds [0-9.]+$', prom, re.M)
# hold gauges + heartbeat must survive when merge data is absent
assert "fleet_intake_hold_fraction_14d" in prom
print("PROM-SHAPE DONE")
PY
if command -v promtool >/dev/null 2>&1; then
  promtool check metrics < "$scratch/fleet-intake-effectiveness.prom" >/dev/null \
    || fail "promtool rejected the exported textfile"
  ok "promtool: exported textfile parses"
fi
ok "main(): prom export carries all issue metric names + labels, HELP/TYPE once"

# =========================================================================
# 6-7. Rules, MANIFEST, organ registry, test host
# =========================================================================
grep -q "FleetIntakeEffectivenessAbsent" "$rules" || fail "rules missing FleetIntakeEffectivenessAbsent"
grep -q "IntakePrioritizationIneffective" "$rules" || fail "rules missing IntakePrioritizationIneffective"
grep -q "IntakeHoldStarvesFleet" "$rules" || fail "rules missing IntakeHoldStarvesFleet"
grep -q 'absent(fleet_intake_effectiveness_last_run_seconds)' "$rules" \
  || fail "FleetIntakeEffectivenessAbsent expr must absent() the heartbeat gauge"
grep -q 'fleet_intake_prioritization_effectiveness{repo="0509"} < 0.1' "$rules" \
  || fail "IntakePrioritizationIneffective must key on the 0509 effectiveness gauge"
grep -q 'fleet_intake_hold_active{repo="fleet-ops"}\[14d\]' "$rules" \
  || fail "hold rules must use the 14d hold window"
ok "rules: three #2759 alerts present with the issue's threshold shapes"

if command -v promtool >/dev/null 2>&1; then
  promtool check rules "$rules" >/dev/null || fail "promtool rejected fleet_rules.yml"
  ok "promtool: fleet_rules.yml parses"
fi

grep -q 'lib/intake-prioritization-effectiveness.py /home/nish/.local/lib/pi-packet/intake-prioritization-effectiveness.py' "$manifest" \
  || fail "MANIFEST missing the helper install"
grep -q 'systemd/fleet-metrics-export.service.d/intake-effectiveness.conf' "$manifest" \
  || fail "MANIFEST missing the drop-in install"
jq -e '.organs[] | select(.name == "intake-effectiveness")' "$organs" >/dev/null \
  || fail "fleet-organs.json missing the intake-effectiveness organ"
jq -e '.organs[] | select(.name == "intake-effectiveness") | .heartbeat_metric == "fleet_intake_effectiveness_last_run_seconds"' "$organs" >/dev/null \
  || fail "organ heartbeat metric mismatch"
grep -q 'bash "$here/intake-prioritization-effectiveness.test.sh"' \
  "$repo_root/tests/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh does not host this test (P14 must run it)"
ok "MANIFEST + organ registry + ci-standards-audit host"

echo "ALL PHASES PASSED"