#!/usr/bin/env bash
# tests/quality-slo-staleness.test.sh
#
# fleet-ops#2444: the quality-SLO scoreboard snapshot was stale 4 days while
# FleetQueueSelfMaintenanceRatioHigh fired on it, because nothing recomputed
# it on a schedule and nothing failed loud when it went stale. This test
# proves the two mechanical fixes — recompute on the existing heartbeat tick
# event, and staleness >24h fails loud:
#
#   1. lib/quality-slo.py stale returns rc=1 for a >24h-old snapshot and
#      rc=0 for a fresh one (the "fail loud" primitive, at a 24h ceiling).
#   2. bin/fleet-quality-slo with a pre-existing STALE snapshot LOUDs
#      QUALITY-SLO-STALE to stderr+triage, recomputes a fresh snapshot, and
#      writes fleet_quality_slo_last_computed_seconds (the gauge the
#      FleetQualitySloStale absent()/>86400 alert rides on).
#   3. bin/fleet-quality-slo with a FRESH pre-existing snapshot does NOT loud
#      STALE (steady state is silent), still recomputes, still writes the gauge.
#   4. The recompute runs on the existing event: bin/fleet-heartbeat-tier1
#      block 19 wires the generator (no new timer/unit), config/fleet_rules.yml
#      ships the FleetQualitySloStale rule, and config/fleet-organs.json
#      registers the organ with absent_alert FleetQualitySloStale.
#
# Offline: scratch AGENT_STATE; EVENTS points at a fixture; FILE_ISSUES=0 so
# no gh writes; PROM/TRIAGE paths point into scratch. The live host snapshot
# and journal are never mutated.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/quality-slo.py"
bin="$repo_root/bin/fleet-quality-slo"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
rules="$repo_root/config/fleet_rules.yml"
organs="$repo_root/config/fleet-organs.json"
fixtures="$here/fixtures/quality-slo"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]]   || fail "missing $lib"
[[ -x "$bin" ]]   || fail "not executable: $bin"
[[ -f "$tier1" ]] || fail "missing $tier1"
[[ -f "$rules" ]] || fail "missing $rules"
[[ -f "$organs" ]]|| fail "missing $organs"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"
python3 -m py_compile "$lib" || fail "quality-slo.py failed py_compile"
bash -n "$bin" || fail "fleet-quality-slo failed bash -n"
bash -n "$tier1" || fail "fleet-heartbeat-tier1 failed bash -n"

scratch="$(mktemp -d -t quality-slo-stale.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
mkdir -p "$scratch/quality-slo"

# --- 1. stale primitive: >24h rc=1, fresh rc=0 ----------------------------
python3 "$lib" compute --events "$fixtures/clean.json" \
  --now 2026-08-30T00:00:00Z > "$scratch/fresh.json"
cp "$scratch/fresh.json" "$scratch/quality-slo/snapshot.json"
# simulate a 4-day-old snapshot by rewriting computed_at
python3 - "$scratch/quality-slo/snapshot.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["computed_at"] = "2026-08-26T00:00:00Z"
json.dump(d, open(p, "w"), indent=2)
PY
set +e
python3 "$lib" stale --snapshot "$scratch/quality-slo/snapshot.json" \
  --now 2026-08-30T12:00:00Z --max-age-seconds 86400 >/dev/null 2>&1
stale_rc=$?
set -e
[[ "$stale_rc" -eq 1 ]] || fail "test 1: stale (4-day-old) snapshot must exit 1, got $stale_rc"
set +e
python3 "$lib" stale --snapshot "$scratch/fresh.json" \
  --now 2026-08-30T12:00:00Z --max-age-seconds 86400 >/dev/null 2>&1
fresh_rc=$?
set -e
[[ "$fresh_rc" -eq 0 ]] || fail "test 1: fresh snapshot must exit 0, got $fresh_rc"
ok "test 1: stale >24h snapshot -> rc=1 (loud), fresh -> rc=0"

# --- 2. generator with a pre-existing STALE snapshot -----------------------
# reseed a stale snapshot in the generator's state dir
python3 - "$scratch/quality-slo/snapshot.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["computed_at"] = "2026-08-26T00:00:00Z"
json.dump(d, open(p, "w"), indent=2)
PY
set +e
env AGENT_STATE="$scratch" \
  FLEET_QUALITY_SLO_FILE=0 \
  FLEET_QUALITY_SLO_EVENTS="$fixtures/clean.json" \
  FLEET_QUALITY_SLO_LIB="$lib" \
  FLEET_QUALITY_SLO_STALE_MAX_AGE=86400 \
  FLEET_QUALITY_SLO_PROM="$scratch/fleet-quality-slo.prom" \
  FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >"$scratch/gen.out" 2>"$scratch/gen.err"
gen_rc=$?
set -e
[[ "$gen_rc" -eq 0 ]] || fail "test 2: generator must exit 0 on a stale->fresh recompute, got $gen_rc"
grep -q "QUALITY-SLO-STALE" "$scratch/gen.err" \
  || fail "test 2: generator did not LOUD QUALITY-SLO-STALE on a stale pre-run snapshot"
grep -q "QUALITY-SLO-STALE" "$scratch/triage.md" \
  || fail "test 2: triage did not carry the QUALITY-SLO-STALE loud line"
grep -q '^fleet_quality_slo_last_computed_seconds ' "$scratch/fleet-quality-slo.prom" \
  || fail "test 2: prom gauge not written"
ok "test 2: stale pre-run snapshot -> loud + recomputed + gauge written"

# --- 3. generator with a FRESH pre-existing snapshot (steady state) --------
set +e
env AGENT_STATE="$scratch" \
  FLEET_QUALITY_SLO_FILE=0 \
  FLEET_QUALITY_SLO_EVENTS="$fixtures/clean.json" \
  FLEET_QUALITY_SLO_LIB="$lib" \
  FLEET_QUALITY_SLO_STALE_MAX_AGE=86400 \
  FLEET_QUALITY_SLO_PROM="$scratch/fleet-quality-slo2.prom" \
  FLEET_HEARTBEAT_TRIAGE="$scratch/triage2.md" \
  "$bin" >"$scratch/gen2.out" 2>"$scratch/gen2.err"
gen2_rc=$?
set -e
[[ "$gen2_rc" -eq 0 ]] || fail "test 3: steady-state generator must exit 0, got $gen2_rc"
if grep -q "QUALITY-SLO-STALE" "$scratch/gen2.err"; then
  fail "test 3: steady-state run must NOT loud QUALITY-SLO-STALE"
fi
grep -q '^fleet_quality_slo_last_computed_seconds ' "$scratch/fleet-quality-slo2.prom" \
  || fail "test 3: steady-state prom gauge not written"
ok "test 3: fresh pre-run snapshot -> no STALE loud, gauge written (steady state)"

# --- 4. wiring on the existing event + guard rules -------------------------
grep -q "19. QUALITY SLO SCOREBOARD" "$tier1" \
  || fail "test 4: heartbeat-tier1 missing the quality-slo scoreboard block"
grep -q '/home/nish/.local/bin/fleet-quality-slo' "$tier1" \
  || fail "test 4: heartbeat-tier1 does not reference bin/fleet-quality-slo"
grep -q 'alert: FleetQualitySloStale' "$rules" \
  || fail "test 4: fleet_rules.yml missing FleetQualitySloStale"
grep -q 'absent(fleet_quality_slo_last_computed_seconds) or (time() - fleet_quality_slo_last_computed_seconds) > 86400' "$rules" \
  || fail "test 4: FleetQualitySloStale expr missing the >86400 delta"
grep -q '"name": "quality-slo-scoreboard"' "$organs" \
  || fail "test 4: fleet-organs.json missing quality-slo-scoreboard registry entry"
grep -q '"absent_alert": "FleetQualitySloStale"' "$organs" \
  || fail "test 4: fleet-organs.json absent_alert missing"
ok "test 4: recompute wired into heartbeat-tier1 block 19 + absent()/>24h rule + organ registry"

echo "ALL OK: quality-SLO recompute-on-tick + >24h staleness fails loud (fleet-ops#2444)"
