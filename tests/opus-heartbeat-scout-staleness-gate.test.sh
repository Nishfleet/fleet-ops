#!/usr/bin/env bash
# tests/opus-heartbeat-scout-staleness-gate.test.sh
#
# fleet-ops#3189: the pi-scout@ timers fire on a deliberate 4h cadence
# (systemd/pi-scout@.timer: OnCalendar=*-*-* 00/4:00:00 +
# RandomizedDelaySec=300; the gap between two consecutive timer triggers is
# ~4h +/- 5m, max idle 14700s). The opus-heartbeat-gather scout staleness
# gate assumed a 2h window (stale_scouts_2h, age > 7200), which matches NO
# live cadence: every healthy 4h cycle looked "drifting" and the 2026-09-04
# heartbeat filed #3189 at age 11452s (inside the cadence), rising 10554 ->
# 11452 because the age only resets every 4h.
#
# Fix: the gate now uses SCOUT_STALE_S = 15000 (parity with
# fleet-work-supply-canary's FLEET_WORK_SUPPLY_MAX_IDLE_S default,
# fleet-ops#1144: "must exceed the scout timer's normal max idle of
# OnCalendar 4h + RandomizedDelaySec 5m = 14700s, so a healthy cadence
# never false-positives"). The count key is stale_scouts, and the scout
# snapshot block exports stale_after_s so consumers compare oldest_age_s
# against the real cadence bound, not the snapshot window.
#
# This test drives the gather's hermetic `--check-scout-staleness-gate
# <fixture>` self-check (no live systemctl, no live timers) over the
# 4h-healthy and past-bound scenarios, plus a source-pin scenario that greps
# the installed gather for the fleet-ops#3189 citation, the SCOUT_STALE_S
# constant, and the stale_after_s export, so a refactor cannot silently drop
# the corrected bound without failing here.
#
# Live/VPS-only (per the existing opus-heartbeat-* test convention): the
# gather script at /home/nish/.local/libexec/opus-heartbeat-gather is absent
# on hosted CI runners. The live snapshot is read read-only to prove the
# gather still produces a parseable snapshot fresh.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

GATHER="${OPUS_HB_GATHER:-/home/nish/.local/libexec/opus-heartbeat-gather}"
SNAP_LIVE="${OPUS_HB_SNAPSHOT_LIVE:-/home/nish/.local/state/opus-heartbeat/snapshot.json}"
TMP_DIR="$(mktemp -d -t opus-3189-gate.XXXXXX)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$GATHER" ]] || fail "gather missing: $GATHER"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"

cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
  # typo-guard: also remove the real dir path below
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

write_fixture() {
  local outpath="$1" name="$2" expect="$3" ages="$4"
  python3 - "$outpath" "$name" "$ages" "$expect" <<'PY'
import json, sys
outpath, name, ages, expect = (
    sys.argv[1], sys.argv[2], json.loads(sys.argv[3]), json.loads(sys.argv[4]),
)
rows = [{"timer": t, "age_s": a} for t, a in ages]
with open(outpath, "w", encoding="utf-8") as f:
    json.dump({"name": name, "rows": rows, "expect_stale": expect}, f)
PY
}

run_gate() {
  local fixture="$1"
  "$GATHER" --check-scout-staleness-gate "$fixture" >"$TMP_DIR/gate.out" 2>"$TMP_DIR/gate.err"
}

echo "== scenario 1: healthy 4h cadence — ages inside the 4h+5m bound are NOT stale (the #3189 live case: 11452, plus one near the cadence max: 14700)"
write_fixture "$TMP_DIR/f1.json" "healthy-4h-cadence-3189-live-case" \
  '[]' '[["pi-scout@0509.timer",11452],["pi-scout@fleet-ops.timer",11452],["pi-scout@0509.timer",14700]]'
run_gate "$TMP_DIR/f1.json" || fail "scenario 1: healthy 4h cadence flagged stale — the gate did not adopt the 4h bound"
grep -q '"stale_scouts":0' "$TMP_DIR/gate.out" || fail "scenario 1: stale count not 0 for healthy cadence"
ok "scenario 1: 4h-cadence ages (<=14700s) pass the gate, no stale scouts"

echo "== scenario 2: past the 4h+5m bound IS stale (a missed cycle, >15000s)"
write_fixture "$TMP_DIR/f2.json" "missed-cycle-past-bound" \
  '["pi-scout@toybox.timer"]' '[["pi-scout@toybox.timer",17000],["pi-scout@0509.timer",12000]]'
run_gate "$TMP_DIR/f2.json" || fail "scenario 2: gate rejected a genuinely stale scout"
grep -q '"stale_scouts":1' "$TMP_DIR/gate.out" || fail "scenario 2: stale count not 1"
ok "scenario 2: age past 15000s IS stale (two missed triggers)"

echo "== scenario 3: unknown/missing last trigger is NOT stale (age null — no false alarm on an unparseable stamp)"
write_fixture "$TMP_DIR/f3.json" "missing-last-trigger" \
  '[]' '[["pi-scout@0509.timer",null],["pi-scout@fleet-ops.timer",8000]]'
run_gate "$TMP_DIR/f3.json" || fail "scenario 3: unknown trigger flagged stale"
grep -q '"stale_scouts":0' "$TMP_DIR/gate.out" || fail "scenario 3: stale count not 0"
ok "scenario 3: age null is not counted stale (unchanged behavior for unparseable stamps)"

echo "== scenario 4: boundary semantics — age ==15000 passes (not >15000), past it trips"
write_fixture "$TMP_DIR/f4.json" "boundary-semantics" \
  '["pi-scout@fleet-ops.timer"]' '[["pi-scout@fleet-ops.timer",15001],["pi-scout@0509.timer",14700],["pi-scout@0509.timer",15000]]'
run_gate "$TMP_DIR/f4.json" || fail "scenario 4: boundary semantics broken"
ok "scenario 4: strict greater-than bound: 15000 not stale, 15001 stale"

echo "== scenario 5: source-pin — the installed gather MUST cite #3189, define SCOUT_STALE_S, and export stale_after_s"
grep -Fq "fleet-ops#3189" "$GATHER" || fail "scenario 5: gather lost the fleet-ops#3189 citation — gate bound removed?"
grep -Fq "SCOUT_STALE_S =" "$GATHER" || fail "scenario 5: gather lost SCOUT_STALE_S constant — 4h bound removed?"
grep -Fq '"stale_after_s"' "$GATHER" || fail "scenario 5: gather lost the stale_after_s export — consumers cannot see the cadence bound?"
grep -Fq '"stale_scouts"' "$GATHER" || fail "scenario 5: gather lost the stale_scouts key — 2h-misnamed key removed?"
ok "scenario 5: gather source pins fleet-ops#3189 bound (citation + constant + stale_after_s + stale_scouts)"

echo "== scenario 6: live snapshot stays parseable with the corrected scout block"
if [[ -f "$SNAP_LIVE" ]]; then
  python3 - "$SNAP_LIVE" <<'PY' || fail "scenario 6: live snapshot no longer parseable"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
sc = d.get("scout") or {}
assert "stale_after_s" in sc, "scout block lost stale_after_s"
assert sc.get("stale_after_s") == 15000, "stale_after_s must be 15000 (4h cadence + margin)"
ag = [r["age_s"] for r in sc.get("timers", []) if r.get("age_s") is not None]
if ag:
    assert max(ag) <= sc.get("stale_after_s"), "a scouted age exceeds the corrected cadence bound — gate would miss a real idle"
print("live snapshot scout block:", json.dumps(sc))
PY
  ok "scenario 6: live snapshot parseable, scout block carries stale_after_s=15000"
else
  echo "SKIP: no live snapshot at $SNAP_LIVE (heartbeat not run yet) — regression fixtures still cover the gate"
fi

echo "ALL PASS"