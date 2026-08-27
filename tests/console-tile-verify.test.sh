#!/usr/bin/env bash
# tests/console-tile-verify.test.sh
#
# fleet-ops#1157: lock the self-auditing console. Offline (no Prom, no gh,
# no live systemd). Hosted by tests/ci-standards-audit.test.sh so it runs
# in P14 without a workflow-file edit.
#
# Proves:
#   1. Every tile spec has a verify.cmd; generate stamps it.
#   2. Exact mismatch -> disputed=true and mismatch{tile}=1.
#   3. Exact match -> disputed=false and mismatch=0.
#   4. Unknown/stale tile is NOT a lie (mismatch=0, no DISPUTED).
#   5. Percent tolerance: 10 vs 11 inside 15% is a match; 10 vs 20 is not.
#   6. shell.html renders DISPUTED and cites verify.cmd.
#   7. push.sh runs verify.py after generate.py (no new timer).
#   8. fleet-console-pi.service ExecStart is the vendored push.sh via
#      /bin/bash -c (P14-safe), still the existing unit, no new timer.
#   9. MANIFEST declares console files + fleet_rules.yml + the drill.
#  10. fleet_rules.yml: ConsoleLying (warning, 30m) + absent() heartbeat.
#  11. promtool check rules (if present).
#  12. The tile-truth drill --check is green.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

gen="$repo_root/libexec/fleet-console-pi/generate.py"
ver="$repo_root/libexec/fleet-console-pi/verify.py"
push="$repo_root/libexec/fleet-console-pi/push.sh"
shell="$repo_root/libexec/fleet-console-pi/shell.html"
svc="$repo_root/systemd/fleet-console-pi.service"
tmr="$repo_root/systemd/fleet-console-pi.timer"
rules="$repo_root/config/fleet_rules.yml"
manifest="$repo_root/MANIFEST"
drill="$repo_root/bin/fleet-console-tile-truth-drill"

[[ -f "$gen" ]] || fail "missing $gen"
[[ -f "$ver" ]] || fail "missing $ver"
[[ -x "$push" || -f "$push" ]] || fail "missing $push"
[[ -f "$shell" ]] || fail "missing $shell"
[[ -f "$svc" ]] || fail "missing $svc"
[[ -f "$tmr" ]] || fail "missing $tmr"
[[ -f "$rules" ]] || fail "missing $rules"
[[ -f "$drill" ]] || fail "missing $drill"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

scratch="$(mktemp -d -t ctv-test.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# =========================================================================
# 1-5. verify.py match / mismatch / unknown / percent
# =========================================================================
python3 - "$ver" "$scratch" <<'PY' || fail "verify.py logic failed"
import importlib.util, json, os, sys, time
from pathlib import Path

ver_path, scratch = sys.argv[1], Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("console_verify", ver_path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

now = time.time()

def tile(ok=True, **kw):
    t = {"source": "test", "stale_after_s": 900, "ok": ok,
         "observed_at": now if ok else None}
    t.update(kw)
    return t

# --- exact match ---
doc = {"tiles": {
    "repairs_inflight": tile(count=2),
    "fleet_state": tile(paused=False),
    "open_prs": tile(count=0, items=[]),
    "shipped_24h": tile(count=0, items=[]),
    "main_ci": tile(red_count=0, items=[]),
    "firing_alerts": tile(count=0, items=[]),
    "running_pi": tile(count=0),
}}
m.RUNNERS["repairs_units"] = lambda t: 2
m.RUNNERS["fleet_paused"] = lambda t: 0
m.RUNNERS["open_prs_prom"] = lambda t: 0
m.RUNNERS["shipped_prom"] = lambda t: 0
m.RUNNERS["main_ci_prom"] = lambda t: 0
m.RUNNERS["alerts_am"] = lambda t: 0
m.RUNNERS["running_pi_execstart"] = lambda t: 0
m.SKIP_GH = True

data = scratch / "match.json"
prom = scratch / "match.prom"
data.write_text(json.dumps(doc))
m.PROM_OUT = prom
m.SKIP_GH = True
results = m.run(data_path=data, inject=None)
assert results["repairs_inflight"] == 0, results
out = json.loads(data.read_text())
assert out["tiles"]["repairs_inflight"]["disputed"] is False
assert out["tiles"]["repairs_inflight"]["verify"]["cmd"]
assert out["tiles"]["repairs_inflight"]["verify"]["match"] is True
assert 'fleet_console_tile_mismatch{tile="repairs_inflight"} 0' in prom.read_text()
print("OK: exact match -> disputed=false, mismatch=0, verify.cmd stamped")

# --- exact mismatch ---
doc2 = json.loads(json.dumps(doc))
doc2["tiles"]["repairs_inflight"]["count"] = 99
data2 = scratch / "mismatch.json"
prom2 = scratch / "mismatch.prom"
data2.write_text(json.dumps(doc2))
m.PROM_OUT = prom2
results = m.run(data_path=data2)
assert results["repairs_inflight"] == 1, results
out = json.loads(data2.read_text())
assert out["tiles"]["repairs_inflight"]["disputed"] is True
assert "99" in str(out["tiles"]["repairs_inflight"]["verify"].get("reason", ""))
assert 'fleet_console_tile_mismatch{tile="repairs_inflight"} 1' in prom2.read_text()
assert "fleet_console_tile_verify_timestamp_seconds" in prom2.read_text()
print("OK: exact mismatch -> DISPUTED + mismatch=1")

# --- unknown tile is not a lie ---
doc3 = json.loads(json.dumps(doc))
doc3["tiles"]["repairs_inflight"] = tile(ok=False, reason="source unreadable")
data3 = scratch / "unknown.json"
prom3 = scratch / "unknown.prom"
data3.write_text(json.dumps(doc3))
m.PROM_OUT = prom3
results = m.run(data_path=data3)
assert results["repairs_inflight"] == 0, results
out = json.loads(data3.read_text())
assert out["tiles"]["repairs_inflight"]["disputed"] is False
assert "skipped" in out["tiles"]["repairs_inflight"]["verify"]
assert 'fleet_console_tile_mismatch{tile="repairs_inflight"} 0' in prom3.read_text()
print("OK: unknown tile is not a lie")

# --- percent tolerance ---
assert m._within(10, 11, {"mode": "percent", "pct": 15}) is True
assert m._within(10, 20, {"mode": "percent", "pct": 15}) is False
assert m._within(2, 3, {"mode": "percent", "pct": 15}) is True  # abs floor
assert m._within(10, 10, {"mode": "exact"}) is True
assert m._within(10, 11, {"mode": "exact"}) is False
assert m._within(0, 0, {"mode": "percent", "pct": 15}) is True
print("OK: percent vs exact tolerance")

# --- attach_specs covers every tile ---
empty = {"tiles": {k: {} for k in m.SPECS}}
m.attach_specs(empty)
for name, spec in m.SPECS.items():
    v = empty["tiles"][name]["verify"]
    assert v["cmd"] == spec["cmd"], name
    assert v["field"] == spec["field"], name
print("OK: every tile spec has a verify.cmd")

# --- inject overlay ---
doc4 = json.loads(json.dumps(doc))
data4 = scratch / "inject.json"
prom4 = scratch / "inject.prom"
data4.write_text(json.dumps(doc4))
m.PROM_OUT = prom4
m.RUNNERS["running_pi_execstart"] = lambda t: 4
results = m.run(data_path=data4, inject=["running_pi.count=999"])
assert results["running_pi"] == 1, results
out = json.loads(data4.read_text())
assert out["tiles"]["running_pi"]["count"] == 999
assert out["tiles"]["running_pi"]["disputed"] is True
print("OK: --inject lie -> DISPUTED")
PY
ok "verify.py match/mismatch/unknown/percent/inject"

# =========================================================================
# 6. shell.html DISPUTED + verify.cmd citation
# =========================================================================
grep -q 'DISPUTED' "$shell" || fail "shell.html missing DISPUTED marker"
grep -q 'disputed-mark' "$shell" || fail "shell.html missing .disputed-mark"
grep -q 'v.cmd' "$shell" || fail "shell.html what-is-this must cite tile.verify.cmd"
grep -q 'cellCls' "$shell" || fail "shell.html must mark disputed cells"
ok "shell.html renders DISPUTED and cites verify.cmd"

# =========================================================================
# 7. push.sh piggybacks verify; no new timer
# =========================================================================
grep -q 'python3 "$DIR/generate.py"' "$push" || fail "push.sh must run generate.py"
grep -q 'python3 "$DIR/verify.py"' "$push" || fail "push.sh must run verify.py"
# verify after generate: generate line number < verify line number
gen_ln=$(grep -n 'python3 "$DIR/generate.py"' "$push" | head -1 | cut -d: -f1)
ver_ln=$(grep -n 'python3 "$DIR/verify.py"' "$push" | head -1 | cut -d: -f1)
[[ "$ver_ln" -gt "$gen_ln" ]] || fail "verify.py must run AFTER generate.py"
ok "push.sh: generate then verify (existing cycle)"

# =========================================================================
# 8. existing unit, bash -c ExecStart, no new timer
# =========================================================================
grep -q "^ExecStart=/bin/bash -c 'exec /home/nish/.local/libexec/fleet-console-pi/push.sh'\$" "$svc" \
  || fail "service ExecStart must exec vendored push.sh via /bin/bash -c"
grep -q '^Type=oneshot$' "$svc" || fail "service: Type=oneshot"
grep -q '^OnCalendar=\*:0/12:00$' "$tmr" || fail "timer must stay *:0/12:00 (no new timer)"
# No second console timer file.
extra=$(find "$repo_root/systemd" -name '*console*' -name '*.timer' | wc -l)
[[ "$extra" -eq 1 ]] || fail "exactly one console timer, found $extra"
ok "existing fleet-console-pi.timer is the only schedule"

# =========================================================================
# 9. MANIFEST
# =========================================================================
grep -Fxq "libexec/fleet-console-pi/generate.py /home/nish/.local/libexec/fleet-console-pi/generate.py" "$manifest" \
  || fail "MANIFEST missing generate.py"
grep -Fxq "libexec/fleet-console-pi/verify.py /home/nish/.local/libexec/fleet-console-pi/verify.py" "$manifest" \
  || fail "MANIFEST missing verify.py"
grep -Fxq "libexec/fleet-console-pi/push.sh /home/nish/.local/libexec/fleet-console-pi/push.sh" "$manifest" \
  || fail "MANIFEST missing push.sh"
grep -Fxq "libexec/fleet-console-pi/shell.html /home/nish/.local/libexec/fleet-console-pi/shell.html" "$manifest" \
  || fail "MANIFEST missing shell.html"
grep -Fxq "bin/fleet-console-tile-truth-drill /home/nish/.local/bin/fleet-console-tile-truth-drill" "$manifest" \
  || fail "MANIFEST missing tile-truth drill"
grep -Fxq "config/fleet_rules.yml /etc/prometheus/fleet_rules.yml" "$manifest" \
  || fail "MANIFEST missing config/fleet_rules.yml (system scope)"
ok "MANIFEST declares console + rules + drill"

# =========================================================================
# 10-11. fleet_rules.yml
# =========================================================================
grep -q 'alert: ConsoleLying' "$rules" || fail "missing ConsoleLying"
grep -q 'fleet_console_tile_mismatch > 0' "$rules" \
  || fail "ConsoleLying expr must be fleet_console_tile_mismatch > 0 (keeps tile= label)"
grep -q 'alert: ConsoleTileVerifyAbsent' "$rules" || fail "missing ConsoleTileVerifyAbsent"
grep -q 'absent(fleet_console_tile_verify_timestamp_seconds)' "$rules" \
  || fail "absent heartbeat must key on fleet_console_tile_verify_timestamp_seconds"
# warning + 30m appear in the ConsoleLying block (not only elsewhere).
python3 - "$rules" <<'PY' || fail "ConsoleLying labels/for failed"
from pathlib import Path
import sys, re
text = Path(sys.argv[1]).read_text()
m = re.search(r"- alert: ConsoleLying\n(.*?)(?:\n      - alert:|\n  - name:|\Z)", text, re.S)
assert m, "ConsoleLying block not found"
block = m.group(1)
assert "for: 30m" in block, block
assert "severity: warning" in block, block
assert "service: fleet" in block, block
print("OK: ConsoleLying is warning/30m/fleet")
PY
if command -v promtool >/dev/null 2>&1; then
  promtool check rules "$rules" >/dev/null \
    || fail "promtool check rules failed"
  ok "promtool check rules: fleet_rules.yml valid"
else
  echo "OK: promtool not installed — skipping syntax check"
fi

# =========================================================================
# 12. generate stamps verify.cmd even without a live Prom (unknown tiles)
# =========================================================================
python3 - "$gen" "$scratch" <<'PY' || fail "generate attach_specs failed"
import importlib.util, json, os, sys, time
from pathlib import Path
gen_path, scratch = sys.argv[1], Path(sys.argv[2])
os.environ["CONSOLE_DATA_JSON"] = str(scratch / "gen.json")
spec = importlib.util.spec_from_file_location("g", gen_path)
g = importlib.util.module_from_spec(spec)

class Boom(Exception):
    pass

# Load, then stub Prom so generate() does not need a live 9090.
spec.loader.exec_module(g)

def unknown(*a, **k):
    raise g.PromError("offline")

g._prom_query = unknown
g._prom_alerts = unknown
g._textfile_mtime = lambda: None
g._running_units = lambda: []
g.SEAT_HEALTH = Path("/nonexistent/pi-seat-health.json")
g.FLEET_PAUSED_MARKER = Path("/nonexistent/FLEET-PAUSED")

doc = g.generate()
for name in ("open_prs", "shipped_24h", "main_ci", "firing_alerts",
             "repairs_inflight", "running_pi", "fleet_state"):
    tile = doc["tiles"][name]
    assert "verify" in tile, name
    assert tile["verify"].get("cmd"), name
print("OK: generate() stamps verify.cmd on every tile")
PY
ok "generate stamps verify.cmd"

# =========================================================================
# 13. drill --check
# =========================================================================
bash -n "$drill" || fail "drill: bash syntax error"
bash -n "$push" || fail "push.sh: bash syntax error"
FLEET_OPS_REPO="$repo_root" "$drill" --check >/dev/null \
  || fail "drill --check failed"
ok "drill --check"

# =========================================================================
# 14. drill inject path (uses real /proc; 999 cannot match)
# =========================================================================
FLEET_OPS_REPO="$repo_root" "$drill" >/dev/null \
  || fail "tile-truth drill failed"
ok "tile-truth drill: inject lie -> DISPUTED"

echo "OK: console-tile-verify.test.sh"
