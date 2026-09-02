#!/usr/bin/env bash
# tests/opus-heartbeat-failed-units-gate.test.sh
#
# fleet-ops#2751: the opus-heartbeat snapshot's failed_units detector can
# report failed_system=0 while the SystemUnitFailed alert fires critical.
# Live case 2026-09-02T01:30:13Z: systemd-networkd-wait-online.service was
# failed per node_exporter (node_systemd_unit_state{state="failed"}==1,
# the exact series the alert reads) from before 01:00Z through 01:47:45Z,
# but the snapshot's single instant `systemctl --failed` call returned
# empty (rc=0) and the snapshot published failed_system=0 — a false green
# while the alert plane (truth) said a system unit was failed. The unit
# was FLAPPING (failed -> activating -> failed, netplan retrying
# networkd-wait-online), so one instant query can catch the transient
# non-failed phase and no detector held the failure visible.
#
# Fix: opus-heartbeat-gather's failed_units() now cross-checks the system
# scope against the SAME node_exporter series the alert reads
# (node_systemd_unit_state{state="failed"} == 1) via promql, and merges
# any Prometheus-seen failed unit into names/count so a transient failure
# stays held visible. User scope is unchanged (node_exporter's systemd
# collector is system-scope only — no prom series exists for user units).
#
# This test drives the gather's hermetic `--check-failed-units-gate
# <fixture>` self-check subcommand (no live systemctl, no live Prometheus)
# over four scenarios, plus a source-pin scenario that greps the installed
# gather for the fleet-ops#2751 citation and the merge call site, so a
# refactor cannot silently delete the cross-check without failing here.
#
# Live/VPS-only (per the existing opus-heartbeat-* test convention): the
# gather script at /home/nish/.local/libexec/opus-heartbeat-gather is
# absent on hosted CI runners. The live snapshot is read read-only to
# prove the gather still produces a parseable snapshot fresh.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

GATHER="${OPUS_HB_GATHER:-/home/nish/.local/libexec/opus-heartbeat-gather}"
SNAP_LIVE="${OPUS_HB_SNAPSHOT_LIVE:-/home/nish/.local/state/opus-heartbeat/snapshot.json}"
TMP_DIR="$(mktemp -d -t opus-2751-gate.XXXXXX)"

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
  local outpath="$1" name="$2" sysctl_rc="$3" sysctl_out="$4" prom_rows="$5" expect="$6"
  python3 - "$outpath" "$name" "$sysctl_rc" "$sysctl_out" "$prom_rows" "$expect" <<'PY'
import json, sys
outpath, name, sysctl_rc, sysctl_out, prom_rows, expect = (
    sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4],
    json.loads(sys.argv[5]) if sys.argv[5] != "NONE" else None,
    json.loads(sys.argv[6]),
)
fixture = {"name": name, "systemctl": {"rc": sysctl_rc, "out": sysctl_out},
           "expect": expect}
if prom_rows is not None:
    fixture["prom_rows"] = prom_rows
with open(outpath, "w", encoding="utf-8") as f:
    json.dump(fixture, f)
PY
}

run_gate() {
  local fixture="$1"
  "$GATHER" --check-failed-units-gate "$fixture" >"$TMP_DIR/gate.out" 2>"$TMP_DIR/gate.err"
}

echo "== scenario 1: the live #2751 flap-dodge case (systemctl empty, alert plane failed)"
write_fixture "$TMP_DIR/f1.json" "flap-dodge-2751-live-case" 0 "" \
  '[{"metric":{"name":"systemd-networkd-wait-online.service","state":"failed"},"value":[0,"1"]}]' \
  '{"names":["systemd-networkd-wait-online.service"],"count":1,"prom_merged":["systemd-networkd-wait-online.service"]}'
run_gate "$TMP_DIR/f1.json" || fail "scenario 1: gate rejected the live flap-dodge case"
ok "scenario 1: flapping unit held visible via cross-check (names+count+prom_merged match)"

echo "== scenario 2: normal agreement — systemctl and prom see the same unit, no merge"
write_fixture "$TMP_DIR/f2.json" "normal-agreement" 0 "a.service loaded failed failed desc\n" \
  '[{"metric":{"name":"a.service","state":"failed"},"value":[0,"1"]}]' \
  '{"names":["a.service"],"count":1}'
run_gate "$TMP_DIR/f2.json" || fail "scenario 2: gate rejected normal agreement"
ok "scenario 2: no spurious merge when both sources agree"

echo "== scenario 3: dedupe + value==1 filter (value-0 rows never merge)"
write_fixture "$TMP_DIR/f3.json" "dedupe-and-value0-filter" 0 \
  $'a.service loaded failed failed desc\nb.service loaded failed failed desc\n' \
  '[{"metric":{"name":"a.service","state":"failed"},"value":[0,"1"]},'\
'{"metric":{"name":"b.service","state":"failed"},"value":[0,"0"]},'\
'{"metric":{"name":"c.service","state":"failed"},"value":[0,"1"]}]' \
  '{"names":["a.service","b.service","c.service"],"count":3,"prom_merged":["c.service"]}'
run_gate "$TMP_DIR/f3.json" || fail "scenario 3: dedupe/value-0 filter broken"
ok "scenario 3: dedupe ok, value==1 filter ok, prom-only unit merged"

echo "== scenario 4: Prometheus down — systemctl result preserved, crosscheck marks unavailable"
write_fixture "$TMP_DIR/f4.json" "prom-down" 0 "a.service loaded failed failed desc\n" "NONE" \
  '{"names":["a.service"],"count":1}'
run_gate "$TMP_DIR/f4.json" || fail "scenario 4: prom-down path broken"
grep -q '"status":"prom_unavailable"' "$TMP_DIR/gate.out" || fail "scenario 4: crosscheck did not mark prom_unavailable"
ok "scenario 4: prom-down degrades to systemctl truth, snapshot still builds"

echo "== scenario 5: source-pin — the installed gather MUST cite #2751 and call the merge"
grep -Fq "fleet-ops#2751" "$GATHER" || fail "scenario 5: gather lost the fleet-ops#2751 citation — cross-check removed?"
grep -Fq "merge_prom_failed" "$GATHER" || fail "scenario 5: gather lost merge_prom_failed — cross-check removed?"
grep -Fq 'node_systemd_unit_state{state="failed"}' "$GATHER" || fail "scenario 5: gather lost the alert-series promql — cross-check removed?"
ok "scenario 5: gather source pins fleet-ops#2751 cross-check (citation + merge + promql)"

echo "== scenario 6: live snapshot stays parseable with the new failed_units shape"
if [[ -f "$SNAP_LIVE" ]]; then
  python3 - "$SNAP_LIVE" <<'PY' || fail "scenario 6: live snapshot no longer parseable"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
fu = d.get("failed_units") or {}
assert "user" in fu and "system" in fu, "failed_units shape changed"
assert set(fu["system"].keys()) >= {"scope", "rc", "names", "count"}, "system block lost keys"
print("live snapshot failed_units.system:", json.dumps(fu["system"]))
PY
  ok "scenario 6: live snapshot parseable, failed_units carries the system block"
else
  echo "SKIP: no live snapshot at $SNAP_LIVE (heartbeat not run yet) — regression fixtures still cover the gate"
fi

echo "ALL PASS"