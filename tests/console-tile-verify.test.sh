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
#  13. Product outcome tile (fleet-ops#5003): the REAL run_outcome_prom
#      verifies all four numbers against their own PromQL re-query, an
#      injected lie on any one of them DISPUTES, and shell.html carries
#      the section with its four labels + the UNMEASURED funnel line.
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
m.RUNNERS["alerts_prom"] = lambda t: 0
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

# --- shipped_24h spot tolerance is tight (fleet-ops#3984) ---
# The product-slo spot check used to be 20%, which hid a 12% miss (57 vs
# 65). It must be tight (2% or abs<=2) so that class is caught, while a
# small cache lag (delta<=2) still passes.
sh_spec = m.SPECS["shipped_24h"]
assert sh_spec["spot"]["tolerance"] == {"mode": "percent", "pct": 2}, \
    sh_spec["spot"]["tolerance"]
assert m._within(57, 65, {"mode": "percent", "pct": 2}) is False  # 12% miss caught
assert m._within(47, 47, {"mode": "percent", "pct": 2}) is True   # exact
assert m._within(47, 48, {"mode": "percent", "pct": 2}) is True   # abs<=2 floor
print("OK: shipped_24h spot tolerance tightened to 2% or abs<=2")

# --- attach_specs covers every tile ---
empty = {"tiles": {k: {} for k in m.SPECS}}
m.attach_specs(empty)
for name, spec in m.SPECS.items():
    v = empty["tiles"][name]["verify"]
    assert v["cmd"] == spec["cmd"], name
    assert v["field"] == spec["field"], name
print("OK: every tile spec has a verify.cmd")

# --- firing_alerts ground truth mirrors the tile writer's Prometheus query ---
# fleet-ops#3637: the verifier must re-read the SAME Prometheus /api/v1/alerts
# the writer claims to mirror (state=firing, Watchdog excluded), NOT
# Alertmanager /api/v2/alerts, which is a deduplicated view and disagrees
# with Prometheus by design. Lock the spec so it can't drift back to AM.
fa_spec = m.SPECS["firing_alerts"]
assert fa_spec["runner"] == "alerts_prom", fa_spec["runner"]
assert "api/v1/alerts" in fa_spec["cmd"], fa_spec["cmd"]
assert "api/v2/alerts" not in fa_spec["cmd"], fa_spec["cmd"]
# Parity: run_alerts_prom counts firing (non-Watchdog) entries exactly like
# the writer's collect_firing_alerts, given the same Prometheus payload.
fa_payload = {"status": "success", "data": {"alerts": [
    {"state": "firing", "labels": {"alertname": "A"}},
    {"state": "firing", "labels": {"alertname": "A"}},       # duplicate instance = 2
    {"state": "pending", "labels": {"alertname": "B"}},      # pending not counted
    {"state": "inactive", "labels": {"alertname": "C"}},
    {"state": "firing", "labels": {"alertname": "Watchdog"}},  # excluded
]}}
calls = []
_orig_http = m._http_json
def fake_prom(url, timeout=m.VERIFY_TIMEOUT):
    calls.append(url)
    assert "/api/v1/alerts" in url and "9093" not in url, url
    return fa_payload
m._http_json = fake_prom
assert m.run_alerts_prom({"count": 99}) == 2, "must count 2 firing non-Watchdog"
assert calls, "run_alerts_prom must query Prometheus"
assert all("api/v2/alerts" not in u for u in calls), "must not query Alertmanager"
m._http_json = _orig_http
print("OK: firing_alerts verifier mirrors writer's Prometheus /api/v1/alerts")

# --- fleet-ops#3674: running_pi churn race is SKIP, not DISPUTE ---
# The tile snapshots the running-pi unit set at generate time; the verifier
# re-scans the SAME live systemd source ~2s later. When a worker starts or
# stops in that window, the two counts legitimately differ — a timing
# artifact, not a lying tile. The verifier must skip (match=None, no
# DISPUTE) when the live set has moved, exactly like shipped_24h's race
# gate (#2690). A tile that disagrees with its OWN recorded unit set
# (a genuine lie) still DISPUTES.
calls_rp = []
def fake_running_pi_units():
    calls_rp.append(1)
    return ["pi-issue@a.service", "pi-issue@b.service", "pi-issue@c.service"]  # live now (3)
m._running_pi_units = fake_running_pi_units

# Live count differs from tile count AND live set moved since the tile's
# snapshot (tile saw a,b; live now has a,b,c — a worker just started)
# -> churn race -> SKIP.
rp_race = tile(count=2, units=["pi-issue@a.service", "pi-issue@b.service"])
try:
    m.run_running_pi_execstart(rp_race)
    raise AssertionError("expected VerifyError race on churn")
except m.VerifyError as e:
    assert "race" in str(e).lower(), str(e)
print("OK: running_pi churn race -> VerifyError (SKIP, not DISPUTE)")

# Live set matches the tile's snapshot and count -> exact match.
def fake_running_pi_units_match():
    return ["pi-issue@a.service", "pi-issue@b.service"]
m._running_pi_units = fake_running_pi_units_match
rp_ok = tile(count=2, units=["pi-issue@a.service", "pi-issue@b.service"])
assert m.run_running_pi_execstart(rp_ok) == 2
print("OK: running_pi stable set -> exact count")

# Tile with NO recorded unit snapshot (e.g. injection) is not race-gated;
# the verifier reports the live count and the caller compares against the
# tile's displayed value.
def fake_running_pi_units_3():
    return ["pi-issue@a.service", "pi-issue@b.service", "pi-issue@d.service"]
m._running_pi_units = fake_running_pi_units_3
assert m.run_running_pi_execstart(tile(count=2)) == 3
print("OK: running_pi no-snapshot tile -> live count returned (lie detection intact)")

# End-to-end: inject a lie into a snapshot-matching tile -> DISPUTED.
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

# --- fleet-ops#5003: the outcome tile is a FOUR-number funnel -----------
# The SPEC's own `field` covers only the headline (signups_24h), so this
# exercises the REAL run_outcome_prom (never a stub): all four numbers are
# re-queried and compared, and a lie on any one of them must DISPUTE. The
# two Prom-facing helpers are stubbed instead, which is where the numbers
# come from.
_orig_promql_sum_present = m._promql_sum_present
_orig_prom_mtime = m._prom_textfile_mtime

OC_VALUES = {
    "sum(fleet_product_signups_24h)": 3.0,
    "sum(fleet_signups_7d)": 11.0,
    "sum(fleet_product_activated_24h)": 2.0,
    "sum(fleet_product_paying_customers_total)": 6.0,
}
OC_FUNNEL = ("top of funnel UNMEASURED (no visit/page-view gauge exists; "
             "Nishfleet/0509#2120)")


def outcome_doc():
    """A fresh doc: the outcome tile under test, every other SPEC name an
    unknown (skipped) tile so nothing else can pollute the result."""
    d = {"tiles": {name: tile(ok=False, reason="not under test")
                   for name in m.SPECS}}
    d["tiles"]["outcome"] = tile(
        source="test", stale_after_s=900, ok=True, observed_at=now,
        signups_24h=3, signups_7d=11, activated_24h=2, paying_customers=6,
        funnel=OC_FUNNEL)
    return d


m._promql_sum_present = lambda expr: OC_VALUES[expr]
# Older than the tile anchor (so _race_against_tile does NOT fire) but well
# inside the 15-minute freshness window.
m._prom_textfile_mtime = lambda: now - 60

# (a) tile present with all four numbers -> exact match, mismatch=0.
docA = outcome_doc()
dataA = scratch / "outcome-match.json"
promA = scratch / "outcome-match.prom"
dataA.write_text(json.dumps(docA))
m.PROM_OUT = promA
results = m.run(data_path=dataA)
assert results["outcome"] == 0, results
out = json.loads(dataA.read_text())
oc = out["tiles"]["outcome"]
assert oc["disputed"] is False, oc
assert oc["verify"]["match"] is True, oc["verify"]
for field, want in (("signups_24h", 3), ("signups_7d", 11),
                    ("activated_24h", 2), ("paying_customers", 6)):
    assert oc[field] == want and isinstance(oc[field], int), (field, oc)
assert oc["funnel"] == OC_FUNNEL, oc
assert 'fleet_console_tile_mismatch{tile="outcome"} 0' in promA.read_text()
oc_cmd = m.SPECS["outcome"]["cmd"]
for gauge in ("fleet_product_signups_24h", "fleet_signups_7d",
              "fleet_product_activated_24h",
              "fleet_product_paying_customers_total"):
    assert gauge in oc_cmd, (gauge, oc_cmd)
print("OK: outcome tile -- four numbers verified by the real runner, mismatch=0")

# (b) one injected lie (signups_7d) -> DISPUTE, even though the SPEC field
#     (signups_24h) still matches the tile's own headline.
docB = outcome_doc()
dataB = scratch / "outcome-lie.json"
promB = scratch / "outcome-lie.prom"
dataB.write_text(json.dumps(docB))
m.PROM_OUT = promB
results = m.run(data_path=dataB, inject=["outcome.signups_7d=999"])
assert results["outcome"] == 1, results
out = json.loads(dataB.read_text())
oc = out["tiles"]["outcome"]
assert oc["disputed"] is True, oc
assert "signups_7d" in oc["verify"].get("reason", ""), oc["verify"]
assert 'fleet_console_tile_mismatch{tile="outcome"} 1' in promB.read_text()
print("OK: outcome tile -- injected signups_7d lie -> DISPUTED")

# (c) an ABSENT gauge is not a zero. _promql_sum_present must reject the
#     empty result vector that _promql_sum silently sums to 0.0 — otherwise
#     a tile displaying "0 signups" would verify as truthful against a
#     family that is not even exported. Uses the SAVED real helper (a/b
#     replaced the module attribute with their value table).
_orig_http = m._http_json
m._http_json = lambda url, timeout=m.VERIFY_TIMEOUT: {
    "status": "success", "data": {"result": []}}
try:
    _orig_promql_sum_present("sum(fleet_signups_7d)")
    raise AssertionError("absent gauge must NOT verify as 0")
except m.VerifyError as e:
    assert "no samples" in str(e) and "fleet_signups_7d" in str(e), str(e)
# ...while the count(...) runners keep empty->0 (unchanged).
assert m._promql_sum("count(fleet_main_ci_green == 0)") == 0.0
m._http_json = _orig_http
print("OK: outcome verifier rejects an absent gauge (no silent 0)")

# (d) a fabricated ZERO cannot pass: the tile displays signups_7d=0 while the
#     real gauge reads 11 -> DISPUTE. Stubs _promql_sum_present (the real
#     runner's query path), never m.RUNNERS["outcome_prom"] (fleet-ops#5003).
m._promql_sum_present = lambda expr: OC_VALUES[expr]
docD = outcome_doc()
dataD = scratch / "outcome-fake-zero.json"
promD = scratch / "outcome-fake-zero.prom"
dataD.write_text(json.dumps(docD))
m.PROM_OUT = promD
results = m.run(data_path=dataD, inject=["outcome.signups_7d=0"])
assert results["outcome"] == 1, results
out = json.loads(dataD.read_text())
oc = out["tiles"]["outcome"]
assert oc["signups_7d"] == 0 and isinstance(oc["signups_7d"], int), oc
assert oc["disputed"] is True, oc
assert "signups_7d" in oc["verify"].get("reason", ""), oc["verify"]
assert "displayed 0" in oc["verify"]["reason"], oc["verify"]
assert "verify 11" in oc["verify"]["reason"], oc["verify"]
print("OK: outcome tile -- fabricated signups_7d=0 vs real 11 -> DISPUTED")

# (e) one non-finite sample must DISPUTE this tile, not abort the pass.
#     int(nan) is a ValueError that verify_tile does not catch, so before
#     the fix it escaped run(), data.json kept no verify results and
#     fleet_console_tile_verify_timestamp_seconds went stale (a false
#     ConsoleTileVerifyAbsent alarm).
def _nan_sum(expr):
    if expr == "sum(fleet_product_activated_24h)":
        return float("nan")
    return OC_VALUES[expr]

m._promql_sum_present = _nan_sum
docE = outcome_doc()
dataE = scratch / "outcome-nan.json"
promE = scratch / "outcome-nan.prom"
dataE.write_text(json.dumps(docE))
m.PROM_OUT = promE
results = m.run(data_path=dataE)
assert results["outcome"] == 1, results
# The pass COMPLETED: every other tile still has a result, data.json kept a
# full mismatch map, and the heartbeat gauge was rewritten (not stale).
assert set(results) == set(m.SPECS), sorted(results)
assert results["main_ci"] == 0 and results["repairs_inflight"] == 0, results
out = json.loads(dataE.read_text())
assert out["tile_mismatches"]["main_ci"] == 0, out.get("tile_mismatches")
oc = out["tiles"]["outcome"]
assert oc["disputed"] is True, oc
assert "non-finite sample" in oc["verify"].get("reason", ""), oc["verify"]
assert "activated_24h" in oc["verify"]["reason"], oc["verify"]
assert 'fleet_console_tile_mismatch{tile="outcome"} 1' in promE.read_text()
assert "fleet_console_tile_verify_timestamp_seconds" in promE.read_text()
print("OK: outcome tile -- nan sample -> DISPUTED, pass not aborted")

# Scope the stubs to these scenarios: restore the originals.
m._promql_sum_present = _orig_promql_sum_present
m._prom_textfile_mtime = _orig_prom_mtime
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
# fleet-ops#5003: the Product outcome section exists, labels all four
# numbers, and states plainly that the top of funnel is UNMEASURED.
grep -q 'id="section-outcome"' "$shell" \
  || fail "shell.html missing the Product outcome section"
for lbl in 'signups · 24h' 'signups · 7d' 'activated · 24h' 'paying customers'; do
  grep -qF "$lbl" "$shell" || fail "shell.html outcome section missing label: $lbl"
done
grep -qF 'top of funnel UNMEASURED' "$shell" \
  || fail "shell.html must name the top of funnel UNMEASURED"
ok "shell.html shows the Product outcome section (four labels + UNMEASURED funnel)"

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

# fleet-ops#5003: the outcome tile's freshness anchor is the product-slo
# textfile mtime — the value verify.py:_race_against_tile compares against —
# NOT min(fleet.prom, product-slo). With min(), whenever fleet.prom is the
# older of the two the verifier SKIPs on that tick and a lying tile escapes
# instead of DISPUTING. Both sources stay gated: a stale fleet.prom still
# returns an unknown tile.
now = time.time()
g._textfile_mtime = lambda: now - 60          # fleet.prom: fresh but older
g._product_slo_mtime = lambda: now            # the anchor verify.py reads
g._prom_query = lambda expr, timeout=5: [{"metric": {}, "value": 3}]
oc_tile = g.collect_outcome()
assert oc_tile["ok"] is True, oc_tile
assert oc_tile["observed_at"] == now, oc_tile
assert oc_tile["observed_at"] != now - 60, oc_tile
# ...and the stale fleet.prom leg still fails closed.
g._textfile_mtime = lambda: now - 99999
assert g.collect_outcome()["ok"] is False
print("OK: outcome tile anchors on the product-slo mtime, not min(sources)")
PY
ok "generate stamps verify.cmd"

# =========================================================================
# 12b. fleet-ops#3563: a held spawn-bench marker renders the seat tile as
#      spawn_bench, not healthy — a benched seat is never reported healthy
# =========================================================================
_3563_LEDGER="$scratch/ledger-3563"
_3563_HEALTH="$scratch/seat-health-3563.json"
mkdir -p "$_3563_LEDGER"
_3563_LEDGER="$_3563_LEDGER" _3563_HEALTH="$_3563_HEALTH" \
python3 - "$gen" <<'PY' || fail "3563: console seat-bench overlay failed"
import importlib.util, json, os, sys, time
from pathlib import Path

spec = importlib.util.spec_from_file_location("g", sys.argv[1])
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)

g.SEAT_LEDGER = Path(os.environ["_3563_LEDGER"])
g.SEAT_HEALTH = Path(os.environ["_3563_HEALTH"])
g._running_units = lambda: []
g._pi_argv_count = lambda: 0

future = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() + 3600)) + "Z"
past = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() - 60)) + "Z"
now = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + ".000Z"

g.SEAT_HEALTH.write_text(json.dumps({
    "provider": "ollama", "model": "deepseek-v4-flash:0731",
    "http_status": 200, "health_class": "healthy",
    "observed_at": now,
}), encoding="utf-8")
marker = g.SEAT_LEDGER / "ollama__deepseek-v4-flash_0731.spawn-bench.json"
marker.write_text(json.dumps({
    "provider": "ollama", "model": "deepseek-v4-flash:0731",
    "usable_at": future, "failure_mode": "empty_run",
    "consecutive_failure_count": 3}), encoding="utf-8")

tile = g.collect_running_pi()
assert tile["health_class"] == "spawn_bench", tile
assert "spawn_bench" in tile.get("note", ""), tile
print("OK: held spawn-bench renders the seat tile as spawn_bench, not healthy")

# Expired marker -> fail-open, the healthy observation renders normally.
marker.write_text(json.dumps({
    "provider": "ollama", "model": "deepseek-v4-flash:0731",
    "usable_at": past, "failure_mode": "empty_run"}), encoding="utf-8")
tile = g.collect_running_pi()
assert tile["health_class"] == "healthy", tile
print("OK: expired spawn-bench leaves the healthy reading alone")

# fleet-ops#3795: an EXPIRED-but-FRESH marker still gates the seat
# (the #3737 probe-gate hold). seat_usable refuses to route agentic work
# to a seat whose marker is fresh and still the latest evidence, even
# after usable_at passes — the comeback organ probes before re-admission.
# The tile must agree: a clobbered-healthy sidecar with NO ledger
# observation newer than the marker's written_at must render spawn_bench,
# not healthy, or the census says "seat healthy" while the router holds
# the seat and the empty-run churn the issue names continues unseen.
written = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() - 1200)) + "Z"
usable_expired = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() - 300)) + "Z"
obs_older = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() - 1500)) + ".000Z"
g.SEAT_HEALTH.write_text(json.dumps({
    "provider": "ollama", "model": "deepseek-v4-flash:0731",
    "http_status": 200, "health_class": "healthy",
    "observed_at": obs_older,
}), encoding="utf-8")
(g.SEAT_LEDGER / "ollama__deepseek-v4-flash_0731.json").write_text(json.dumps({
    "provider": "ollama", "model": "deepseek-v4-flash:0731",
    "http_status": 200, "health_class": "healthy",
    "observed_at": obs_older, "consecutive_failure_count": 0,
}), encoding="utf-8")
marker.write_text(json.dumps({
    "provider": "ollama", "model": "deepseek-v4-flash:0731",
    "usable_at": usable_expired, "written_at": written,
    "failure_mode": "empty_run", "consecutive_failure_count": 4,
}), encoding="utf-8")
tile = g.collect_running_pi()
assert tile["health_class"] == "spawn_bench", (
    f"expired-but-fresh marker with no newer ledger obs must render "
    f"spawn_bench (probe-gate hold), got {tile.get('health_class')}: {tile}")
print("OK: expired-but-fresh spawn-bench renders spawn_bench, not healthy (fleet-ops#3795)")

# A ledger observation NEWER than the marker's written_at is post-bench
# evidence (a run that produced output) -> case (b) releases, healthy stands.
obs_newer = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() - 60)) + ".000Z"
(g.SEAT_LEDGER / "ollama__deepseek-v4-flash_0731.json").write_text(json.dumps({
    "provider": "ollama", "model": "deepseek-v4-flash:0731",
    "http_status": 200, "health_class": "healthy",
    "observed_at": obs_newer, "consecutive_failure_count": 0,
}), encoding="utf-8")
tile = g.collect_running_pi()
assert tile["health_class"] == "healthy", (
    f"newer ledger obs must release the expired-but-fresh hold, "
    f"got {tile.get('health_class')}: {tile}")
print("OK: newer ledger observation releases the expired-but-fresh hold (fleet-ops#3795)")

# A stale marker (written > 24h ago) is archaeology -> fail-open.
stale_written = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() - 100000)) + "Z"
marker.write_text(json.dumps({
    "provider": "ollama", "model": "deepseek-v4-flash:0731",
    "usable_at": usable_expired, "written_at": stale_written,
    "failure_mode": "empty_run", "consecutive_failure_count": 4,
}), encoding="utf-8")
tile = g.collect_running_pi()
assert tile["health_class"] == "healthy", (
    f"stale marker (>24h) must fail-open, got {tile.get('health_class')}: {tile}")
print("OK: stale (>24h) expired marker fails open (fleet-ops#3795)")

# --- fleet-ops#3828: corpse + ceiling fences (mirror of #3889/#3826) -------
# A chronic spawn_fail corpse (marker seat_dead=true, count=47) or a
# ceiling-parked seat (count >= 20 for spawn_fail) must render spawn_bench
# even when the sibling ledger carries a NEWER healthy 200 observation
# (after_provider_response carries status+headers only, never the rc — an
# rc=1 spawn failure reads as a healthy 200). Only a recovery probe
# (source=comeback_release on the ledger) re-proves the seat.
written = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() - 60)) + "Z"
usable_expired = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() - 300)) + "Z"
obs_newer = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() - 30)) + ".000Z"
ldg = g.SEAT_LEDGER / "ollama__deepseek-v4-flash_0731.json"
# Scenario G — corpse fence: marker seat_dead=true + expired usable_at +
# a NEWER healthy ledger. The corpse must win (TERMINAL until recovery).
g.SEAT_HEALTH.write_text(json.dumps({
    "provider": "ollama", "model": "deepseek-v4-flash:0731",
    "http_status": 200, "health_class": "healthy",
    "observed_at": obs_newer,
}), encoding="utf-8")
ldg.write_text(json.dumps({
    "provider": "ollama", "model": "deepseek-v4-flash:0731",
    "http_status": 200, "health_class": "healthy",
    "observed_at": obs_newer, "consecutive_failure_count": 0,
}), encoding="utf-8")
marker.write_text(json.dumps({
    "provider": "ollama", "model": "deepseek-v4-flash:0731",
    "usable_at": usable_expired, "written_at": written,
    "failure_mode": "spawn_fail", "consecutive_failure_count": 47,
    "seat_dead": True,
}), encoding="utf-8")
tile = g.collect_running_pi()
assert tile["health_class"] == "spawn_bench", (
    f"corpse marker must render spawn_bench despite newer healthy ledger, "
    f"got {tile.get('health_class')}: {tile}")
print("OK: corpse marker renders spawn_bench despite newer healthy ledger (fleet-ops#3828)")
# A recovery probe (source=comeback_release) re-proves the corpse.
ldg.write_text(json.dumps({
    "provider": "ollama", "model": "deepseek-v4-flash:0731",
    "http_status": 200, "health_class": "healthy",
    "observed_at": obs_newer, "consecutive_failure_count": 0,
    "source": "comeback_release",
}), encoding="utf-8")
tile = g.collect_running_pi()
assert tile["health_class"] == "healthy", (
    f"comeback_release must release a corpse marker, "
    f"got {tile.get('health_class')}: {tile}")
print("OK: comeback_release recovery releases a corpse marker (fleet-ops#3828)")

# Scenario H — ceiling fence: non-corpse marker whose count crossed the
# failure ceiling, usable_at expired, ledger has a NEWER healthy write.
# The ceiling must hold despite the newer observation.
ldg.write_text(json.dumps({
    "provider": "ollama", "model": "deepseek-v4-flash:0731",
    "http_status": 200, "health_class": "healthy",
    "observed_at": obs_newer, "consecutive_failure_count": 0,
}), encoding="utf-8")
marker.write_text(json.dumps({
    "provider": "ollama", "model": "deepseek-v4-flash:0731",
    "usable_at": usable_expired, "written_at": written,
    "failure_mode": "spawn_fail", "consecutive_failure_count": 47,
    "seat_dead": False,
}), encoding="utf-8")
tile = g.collect_running_pi()
assert tile["health_class"] == "spawn_bench", (
    f"ceiling marker must render spawn_bench despite newer healthy ledger, "
    f"got {tile.get('health_class')}: {tile}")
print("OK: ceiling marker renders spawn_bench despite newer healthy ledger (fleet-ops#3828)")
# Below the ceiling the healthy (later) observation wins again (released).
marker.write_text(json.dumps({
    "provider": "ollama", "model": "deepseek-v4-flash:0731",
    "usable_at": usable_expired, "written_at": written,
    "failure_mode": "spawn_fail", "consecutive_failure_count": 3,
    "seat_dead": False,
}), encoding="utf-8")
tile = g.collect_running_pi()
assert tile["health_class"] == "healthy", (
    f"sub-ceiling marker count must release the seat, "
    f"got {tile.get('health_class')}: {tile}")
print("OK: sub-ceiling marker count releases the seat (fail-open)")
# Empty-run seats use the lower _EMPTY_RUN_FAILURE_CEILING (5).
marker.write_text(json.dumps({
    "provider": "ollama", "model": "deepseek-v4-flash:0731",
    "usable_at": usable_expired, "written_at": written,
    "failure_mode": "empty_run", "consecutive_failure_count": 5,
    "seat_dead": False,
}), encoding="utf-8")
tile = g.collect_running_pi()
assert tile["health_class"] == "spawn_bench", (
    f"empty_run count=5 at its ceiling must render spawn_bench, "
    f"got {tile.get('health_class')}: {tile}")
print("OK: empty_run ceiling (5) holds at its lower threshold (fleet-ops#3828)")
# comeback_release releases a ceiling-parked seat too.
ldg.write_text(json.dumps({
    "provider": "ollama", "model": "deepseek-v4-flash:0731",
    "http_status": 200, "health_class": "healthy",
    "observed_at": obs_newer, "consecutive_failure_count": 0,
    "source": "comeback_release",
}), encoding="utf-8")
marker.write_text(json.dumps({
    "provider": "ollama", "model": "deepseek-v4-flash:0731",
    "usable_at": usable_expired, "written_at": written,
    "failure_mode": "spawn_fail", "consecutive_failure_count": 47,
    "seat_dead": False,
}), encoding="utf-8")
tile = g.collect_running_pi()
assert tile["health_class"] == "healthy", (
    f"comeback_release must release a ceiling-parked seat, "
    f"got {tile.get('health_class')}: {tile}")
print("OK: comeback_release re-proves a ceiling-parked seat (fleet-ops#3828)")
PY
ok "fleet-ops#3563/#3795: console tile overlays the spawn-bench marker — a benched seat never shows healthy"
ok "fleet-ops#3828: console tile corpse + ceiling fences — N spawn_fail demotes the ledger read"

# =========================================================================
# 12c. fleet-ops#4217: PI WORK tile shows quota remaining % for the seat
# =========================================================================
# fleet-ops#4980: block 12c must NOT read the live SEAT_LEDGER. The "no
# quota data" sub-case below injects a healthy minimax/MiniMax-M3 sidecar,
# and the live host carries a real minimax__MiniMax-M3.spawn-bench.json
# marker, so _seat_bench_held() flips it to spawn_bench and the assertion
# reds on main whenever any seed seat is benched. Scope the ledger to an
# empty scratch dir (mirroring block 12b's _3563_LEDGER) so the 4217
# sub-test cannot see live /agent-state/lanes/seats bench markers. The
# live-read in _seat_bench_held is correct product behaviour; the fixture
# is what had to be scoped.
_4217_HEALTH="$scratch/seat-health-4217.json"
_4217_LEDGER="$scratch/ledger-4217"
mkdir -p "$_4217_LEDGER"
_4217_HEALTH="$_4217_HEALTH" _4217_LEDGER="$_4217_LEDGER" \
python3 - "$gen" <<'PY' || fail "4217: console quota display failed"
import importlib.util, json, os, sys, time
from pathlib import Path

spec = importlib.util.spec_from_file_location("g", sys.argv[1])
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)

g.SEAT_LEDGER = Path(os.environ["_4217_LEDGER"])
g.SEAT_HEALTH = Path(os.environ["_4217_HEALTH"])
g._running_units = lambda: []
g._pi_argv_count = lambda: 0

now = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + ".000Z"
g.SEAT_HEALTH.write_text(json.dumps({
    "provider": "claude", "model": "opus-4",
    "http_status": 200, "health_class": "healthy",
    "observed_at": now,
}), encoding="utf-8")

# Stub _prom_query to return quota data for claude
def fake_prom(expr, timeout=5):
    if "remaining_pct" in expr and "claude" in expr:
        return [
            {"metric": {"provider": "claude", "window": "session", "source": "api"}, "value": 92.0},
            {"metric": {"provider": "claude", "window": "weekly", "source": "api"}, "value": 46.0},
        ]
    if "reset_seconds" in expr and "claude" in expr:
        return [
            {"metric": {"provider": "claude", "window": "session"}, "value": 12000.0},
            {"metric": {"provider": "claude", "window": "weekly"}, "value": 580000.0},
        ]
    return []

g._prom_query = fake_prom

tile = g.collect_running_pi()
assert tile["health_class"] == "healthy", tile
assert "quota" in tile.get("note", ""), f"note missing quota: {tile}"
assert "session=92.0%" in tile["note"], f"note missing session pct: {tile}"
assert "weekly=46.0%" in tile["note"], f"note missing weekly pct: {tile}"
assert tile.get("quota_source") == "api", tile
assert len(tile.get("quota_rows", [])) == 2, tile
print("OK: PI WORK tile shows quota remaining % for the seat (fleet-ops#4217)")

# No quota data (provider not in fleet.prom) -> tile still works, no quota in note
g.SEAT_HEALTH.write_text(json.dumps({
    "provider": "minimax", "model": "MiniMax-M3",
    "http_status": 200, "health_class": "healthy",
    "observed_at": now,
}), encoding="utf-8")

def fake_prom_no_quota(expr, timeout=5):
    return []

g._prom_query = fake_prom_no_quota
tile = g.collect_running_pi()
assert tile["health_class"] == "healthy", tile
assert "quota" not in tile.get("note", ""), f"note should not have quota: {tile}"
assert tile.get("quota_source") is None, tile
print("OK: PI WORK tile works without quota data (fleet-ops#4217)")

# Prometheus down -> tile still works
def fake_prom_down(expr, timeout=5):
    raise g.PromError("offline")

g._prom_query = fake_prom_down
g.SEAT_HEALTH.write_text(json.dumps({
    "provider": "claude", "model": "opus-4",
    "http_status": 200, "health_class": "healthy",
    "observed_at": now,
}), encoding="utf-8")
tile = g.collect_running_pi()
assert tile["health_class"] == "healthy", tile
assert "quota" not in tile.get("note", ""), f"prom down: note should not have quota: {tile}"
print("OK: PI WORK tile works when Prometheus is down (fleet-ops#4217)")

# fleet-ops#4980 regression guard: the SEED seat, not the live host, must
# decide the tile. The 4217 fixture must not read live
# /agent-state/lanes/seats — a benched seed seat on the host must not flip
# an injected-healthy sidecar in this hermetic block. Two cases, both
# must pass: (1) the scratch ledger DOES carry a held
# minimax__MiniMax-M3.spawn-bench.json marker -> the overlay fires and the
# healthy sidecar renders spawn_bench (the overlay itself works); (2) the
# scratch ledger is empty -> the same healthy sidecar renders healthy
# (the fixture is hermetic, no live marker leaks in).
g._prom_query = fake_prom_no_quota
g.SEAT_HEALTH.write_text(json.dumps({
    "provider": "minimax", "model": "MiniMax-M3",
    "http_status": 200, "health_class": "healthy",
    "observed_at": now,
}), encoding="utf-8")
future = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() + 3600)) + "Z"
marker = g.SEAT_LEDGER / "minimax__MiniMax-M3.spawn-bench.json"
marker.write_text(json.dumps({
    "provider": "minimax", "model": "MiniMax-M3",
    "usable_at": future, "failure_mode": "empty_run",
    "consecutive_failure_count": 3,
}), encoding="utf-8")
tile = g.collect_running_pi()
assert tile["health_class"] == "spawn_bench", (
    f"seed marker present must render spawn_bench (overlay works), "
    f"got {tile.get('health_class')}: {tile}")
print("OK: 4217 hermetic — seed marker present renders spawn_bench (fleet-ops#4980)")
marker.unlink()
tile = g.collect_running_pi()
assert tile["health_class"] == "healthy", (
    f"empty seed ledger must render healthy (hermetic, no live leak), "
    f"got {tile.get('health_class')}: {tile}")
print("OK: 4217 hermetic — empty seed ledger renders healthy (fleet-ops#4980)")
PY
ok "fleet-ops#4217: PI WORK tile shows quota remaining % for the current seat"

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
