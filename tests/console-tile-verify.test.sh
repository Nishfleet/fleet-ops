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
#  14. The console-truth pytest suite runs on this gate (fleet-ops#5072).
#      test_console_truth.py was invoked by nothing automatic before, so a
#      console-truth regression could land green; an injected #4996 argv
#      regression in a scratch copy now turns the wrapper red.
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

# --- open_prs spot is bounded by the tile's own cache window (fleet-ops#5155) ---
# The tile's count is measured at tile.observed_at (the exporter's cache
# timestamp), so a live gh recount can only be judged through a window: the
# PRs opened since then may be legitimately absent, the PRs closed since may
# still be present. The 2026-09-10 firing was exactly this: a faithful tile
# (11) against a live count (15), 4 PRs opened in the 9 minutes since the
# snapshot — outside the old ±2/15% band, inside the window.
op_spec = m.SPECS["open_prs"]["spot"]
assert op_spec["tolerance"]["mode"] == "window", op_spec["tolerance"]
lag = {"mode": "window", "down": 4 + m.SEARCH_INDEX_FLOOR,
       "up": 0 + m.SEARCH_INDEX_FLOOR}
assert m._within(11, 15, lag) is True, "window's own churn is a lag, not a lie"
# The old fixed band is what called it one (the false DISPUTE being repaired).
assert m._within(11, 15, {"mode": "percent", "pct": 15}) is False
# A gap the window cannot explain is still a DISPUTE.
assert m._within(5, 15, lag) is False, "unexplained undercount must dispute"
assert m._within(30, 15, lag) is False, "unexplained overcount must dispute"
# A closed PR still in the tile is the mirror case and is also not a lie.
assert m._within(11, 9, {"mode": "window", "down": 2, "up": 4}) is True
# An exact live match stays green.
assert m._within(15, 15, lag) is True

# --- the runner builds that window from the TILE's observed_at ---
class _FakeGhResult:
    def __init__(self, out):
        self.returncode, self.stdout, self.stderr = 0, out, ""

seen_queries = []

def _fake_gh_run(argv, **kw):
    q = next(a for a in argv if a.startswith("q="))
    seen_queries.append(q)
    if "created:>=" in q:
        return _FakeGhResult("4\n")
    if "closed:>=" in q:
        return _FakeGhResult("0\n")
    return _FakeGhResult("15\n")

_orig_run, _orig_skip = m.subprocess.run, m.SKIP_GH
m.subprocess.run = _fake_gh_run
m.SKIP_GH = False
try:
    live, displayed, repo, tol = m.run_open_prs_gh_spot(
        {"observed_at": 1789076703.0,
         "items": [{"repo": "Nishfleet/fleet-ops", "count": 11}]})
finally:
    m.subprocess.run, m.SKIP_GH = _orig_run, _orig_skip
assert (live, displayed, repo) == (15, 11, "Nishfleet/fleet-ops"), (live, displayed)
assert tol["mode"] == "window" and tol["down"] == 4 + m.SEARCH_INDEX_FLOOR
assert tol["up"] == 0 + m.SEARCH_INDEX_FLOOR, tol
assert m._within(displayed, live, tol) is True, "the 21:54Z firing must pass"
assert all(
    "2026-09-10T21:45:03+00:00" in q for q in seen_queries[1:]
), seen_queries
assert "created:>=" in seen_queries[1] and "closed:>=" in seen_queries[2], \
    seen_queries
print("OK: open_prs spot windowed on the tile's own cache timestamp")

# --- fleet-ops#5148: the filing's own N+3 case, end-to-end through verify_tile ---
# The filing: per-repo displayed 8 (the exporter's cached org snapshot) vs
# live gh 11 — 3 PRs opened inside the 30-min cache window, a 37% miss
# against the old fixed band. A faithful tile must stay green through the
# REAL verify_tile path (primary Prom re-query agrees; the spot window
# explains the +3), and a Prom gauge disagreeing with its OWN re-query
# must still DISPUTE — the window must not have weakened the exact
# primary check.
op_tile = {"source": "test", "stale_after_s": 900, "ok": True,
           "observed_at": now,
           "count": 8, "items": [{"repo": "Nishfleet/fleet-ops", "count": 8}]}
m.RUNNERS["open_prs_prom"] = lambda t: t["count"]  # primary re-query agrees
_orig_run_5148, _orig_skip_5148 = m.subprocess.run, m.SKIP_GH

def _gh_n3(argv, **kw):
    q = next(a for a in argv if a.startswith("q="))
    if "created:>=" in q:
        return _FakeGhResult("3\n")   # 3 PRs opened since observed_at
    if "closed:>=" in q:
        return _FakeGhResult("0\n")
    return _FakeGhResult("11\n")      # live count is N+3

m.subprocess.run = _gh_n3
m.SKIP_GH = False
try:
    op_mismatch = m.verify_tile("open_prs", op_tile)
finally:
    m.subprocess.run, m.SKIP_GH = _orig_run_5148, _orig_skip_5148
assert op_mismatch == 0, op_mismatch
assert op_tile["disputed"] is False, op_tile["verify"]
assert op_tile["verify"]["match"] is True, op_tile["verify"]
assert op_tile["verify"]["spot_match"] is True, op_tile["verify"]
assert op_tile["verify"]["spot_observed"] == 11, op_tile["verify"]
print("OK: #5148 — 8 vs 11 (+3 inside the window) is a lag, not a DISPUTE")

# --- fleet-ops#5148: a Prom gauge disagreeing with its OWN re-query ---
# The window tolerance repairs the gh spot only. The primary check (tile
# count vs sum(fleet_open_prs) re-queried, exact) must still DISPUTE when
# the gauge disagrees with its own re-query — a wrong family is still a
# wrong family even with the spot green.
bad_tile = {"source": "test", "stale_after_s": 900, "ok": True,
            "observed_at": now,
            "count": 8, "items": [{"repo": "Nishfleet/fleet-ops", "count": 8}]}
m.RUNNERS["open_prs_prom"] = lambda t: 91  # own re-query disagrees
m.SKIP_GH = True  # isolate: the DISPUTE must come from the primary check
try:
    bad_mismatch = m.verify_tile("open_prs", bad_tile)
finally:
    m.SKIP_GH = True
assert bad_mismatch == 1, bad_mismatch
assert bad_tile["disputed"] is True, bad_tile["verify"]
assert bad_tile["verify"]["match"] is False, bad_tile["verify"]
print("OK: #5148 — gauge vs own re-query disagreement still DISPUTEs")

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
# 5b. fleet-ops#5155: the console stamps a cached family with the CACHE's
# measurement time, and the exporter publishes it.
# =========================================================================
# The tile's open_prs count is a cached org GraphQL snapshot (exporter
# PR_CACHE_TTL = 30 min). Before this, generate.py stamped the EXPORT time,
# so a 30-min-old count read as seconds-fresh on the page and the verify's
# live gh spot check called the (faithful) tile a lie every cache window.
# Lock both halves: the exporter's measurement-time gauge, and the tile's use
# of it as observed_at (with the cache window as the freshness gate).
_exporter="$repo_root/libexec/fleet-metrics-export.py"
python3 - "$_exporter" "$gen" "$scratch" <<'PY' || fail "5155: cache measurement time not published/stamped"
import importlib.util, json, sys, time
from pathlib import Path

exporter_path, gen_path, scratch = sys.argv[1], sys.argv[2], Path(sys.argv[3])
spec = importlib.util.spec_from_file_location("fme5155", exporter_path)
fme = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fme)

# --- exporter: a served cache reports the CACHE's write time, not now ---
cache = scratch / "repo-snapshot-cache.json"
measured = time.time() - 600.0
cache.write_text(json.dumps({"ts": measured, "data": {"open_prs": {"R": 11}}}))
fme._CACHE_TS_SERVED.clear()
spec_obj = importlib.util.spec_from_file_location("g5155", gen_path)
g = importlib.util.module_from_spec(spec_obj)
spec_obj.loader.exec_module(g)
served = fme._cached_json(cache, lambda: {"open_prs": {"R": 99}},
                          "repo_snapshot")
assert served == {"open_prs": {"R": 11}}, served
stamp = fme._CACHE_TS_SERVED["repo_snapshot"]
assert abs(stamp - measured) <= 2, (stamp, measured)
assert abs(stamp - time.time()) > 60, "must be the cache time, not the run time"
# A fresh fetch reports NOW.
fme._CACHE_TS_SERVED.clear()
fme.PR_CACHE_TTL = -1  # force the fetch path
fetched = fme._cached_json(cache, lambda: {"open_prs": {"R": 15}},
                           "repo_snapshot")
assert fetched == {"open_prs": {"R": 15}}, fetched
assert abs(fme._CACHE_TS_SERVED["repo_snapshot"] - time.time()) <= 2
# The family is emitted (constants + the emission site).
assert "fleet_gh_cache_timestamp_seconds" in fme.HELP_CTS
assert "fleet_gh_cache_timestamp_seconds" in fme.TYPE_CTS
src = Path(exporter_path).read_text(encoding="utf-8")
assert 'fleet_gh_cache_timestamp_seconds{{kind=' in src, "metric never emitted"
assert "_CACHE_TS_SERVED" in src, "measurement time never recorded"

# --- generate.py: observed_at is that stamp, gate is the cache window ---
TS = 1789076703.0


def fake_prom(expr, timeout=5):
    if "fleet_gh_cache_timestamp_seconds" in expr:
        return [{"metric": {"kind": "repo_snapshot"}, "value": TS}]
    if "fleet_gh_cache_fresh" in expr:
        return [{"metric": {"kind": "repo_snapshot"}, "value": 1.0}]
    if "fleet_open_prs" in expr:
        return [{"metric": {"repo": "Nishfleet/fleet-ops"}, "value": 11.0}]
    return []


g._prom_query = fake_prom
NOW = time.time()
g._textfile_mtime = lambda: NOW  # exporter run time (separate from the cache)

tile = g.collect_open_prs()
assert tile["ok"] is True, tile
assert tile["observed_at"] == TS, tile["observed_at"]
assert TS != NOW, "fixture must separate cache time from export time"
assert tile["stale_after_s"] == g.GH_CACHE_WINDOW_S == 1800, tile["stale_after_s"]
assert tile["count"] == 11, tile["count"]
# Fail open: no gauge (older exporter) -> the export time, as before.
def no_gauge(expr, timeout=5):
    if "fleet_gh_cache_timestamp_seconds" in expr:
        return []  # older exporter: gauge absent -> fall back to the export time
    if "fleet_open_prs" in expr:
        return [{"metric": {"repo": "R"}, "value": 3.0}]
    return [{"metric": {"kind": "repo_snapshot"}, "value": 1.0}]


g._prom_query = no_gauge
tile = g.collect_open_prs()
assert tile["observed_at"] == NOW, tile["observed_at"]
print("OK: exporter publishes the gh cache measurement time + tile stamps it")
PY
ok "fleet-ops#5155: console stamps cached gh families with the cache's measurement time"

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
# 12e. fleet-ops#5070: the questions verifier counts the SAME population
#      the tile displays (aged `answered` questions excluded), so a
#      faithful tile never false-DISPUTEs.
#
# The tile (generate.py collect_questions) drops an `answered` question
# once its `decision-resolved:` comment passes ANSWERED_KEEP_S (24h).
# run_questions_gh used to count every open `question` issue org-wide, so
# the moment an answered question aged out the tile (2) and the verifier
# (3) disagreed and DISPUTE landed on a truthful tile — latent while the
# tile was dark, reachable once fleet-ops#4996 lit it. Hermetic: the gh
# runner is faked, no network, no live org.
# =========================================================================
python3 - "$gen" "$ver" "$scratch" <<'PY' || fail "5070: questions cross-check failed"
import importlib.util, json, sys, time
from datetime import datetime, timedelta, timezone
from pathlib import Path

gen_path, ver_path, scratch = sys.argv[1], sys.argv[2], Path(sys.argv[3])

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

G = load("console_generate_5070", gen_path)
V = load("console_verify_5070", ver_path)

now = time.time()
def iso(seconds_ago):
    return (datetime.now(timezone.utc) - timedelta(seconds=seconds_ago)).strftime(
        "%Y-%m-%dT%H:%M:%S+00:00")

# --- the two sides must agree on the window (drift guard) ---------------
assert V.ANSWERED_KEEP_S == G.ANSWERED_KEEP_S == 24 * 60 * 60, (
    f"verifier window {V.ANSWERED_KEEP_S} != tile window {G.ANSWERED_KEEP_S}")

# ...and on the answer-epoch rule itself, including junk comments.
for comments in (
    [],
    [{"body": "just chatter", "createdAt": iso(60)}],
    [{"body": "decision-resolved: a", "createdAt": iso(90000)},
     {"body": "decision-resolved: b", "createdAt": iso(120)}],  # newest wins
    [{"body": "decision-resolved: no date"}],                  # missing createdAt
    [{"body": "decision-resolved: junk", "createdAt": "not-a-date"}],
):
    assert V._question_answer_epoch(comments) == G._answer_epoch(comments), comments
print("OK: 5070 — verifier window + answer-epoch rule match generate.py")

# --- fixture: one aged answer, one young answer, one unanswered ---------
AGED, YOUNG = 48 * 3600, 2 * 3600
rows = [
    {"number": 11, "title": "aged", "url": "u/11", "createdAt": iso(AGED),
     "repository": {"nameWithOwner": "Nishfleet/0509"},
     "labels": [{"name": "question"}], "body": "question: aged?"},
    {"number": 12, "title": "young", "url": "u/12", "createdAt": iso(YOUNG),
     "repository": {"nameWithOwner": "Nishfleet/fleet-ops"},
     "labels": [{"name": "question"}], "body": "question: young?"},
    {"number": 13, "title": "open", "url": "u/13", "createdAt": iso(YOUNG),
     "repository": {"nameWithOwner": "Nishfleet/0509"},
     "labels": [{"name": "question"}], "body": "question: open?"},
]
comments = {
    11: [{"body": "decision-resolved: yes", "createdAt": iso(AGED)}],
    12: [{"body": "decision-resolved: yes", "createdAt": iso(YOUNG)}],
    13: [],
}

VALUE_FLAGS = {"-R", "--repo", "--json", "--jq", "--owner", "--state",
               "--label", "--limit"}

def positionals(tokens):
    pos, i = [], 0
    while i < len(tokens):
        if tokens[i].startswith("-"):
            i += 2 if tokens[i] in VALUE_FLAGS else 1
        else:
            pos.append(tokens[i])
            i += 1
    return pos


class FakeGh:
    """Stand-in for subprocess: records argv, answers from the fixture."""

    def __init__(self, rows, comments, search_rc=0, view_rc=0,
                 search_stdout=None, view_stdout=None):
        self.rows, self.comments = rows, comments
        self.search_rc, self.view_rc = search_rc, view_rc
        self.search_stdout, self.view_stdout = search_stdout, view_stdout
        self.calls = []

    def run(self, argv, **kwargs):
        argv = list(argv)
        self.calls.append(argv)
        if argv[1:3] == ["search", "issues"]:
            out = (json.dumps(self.rows) if self.search_stdout is None
                   else self.search_stdout)
            return subprocess.CompletedProcess(argv, self.search_rc,
                                              out if self.search_rc == 0 else "",
                                              "search boom")
        number = next((int(t) for t in argv[3:] if t.isdigit()), None)
        out = (json.dumps(self.comments.get(number, []))
               if self.view_stdout is None else self.view_stdout)
        return subprocess.CompletedProcess(argv, self.view_rc,
                                          out if self.view_rc == 0 else "",
                                          "view boom")


import subprocess  # noqa: E402  (the fake builds CompletedProcess)

fake_v = FakeGh(rows, comments)
V.subprocess = fake_v
V.SKIP_GH = False

counted = V.run_questions_gh({"count": 2})
assert counted == 2, f"aged answered question must be excluded, got {counted}"
# The pre-fix metric: the raw search total. It differs by exactly the aged
# answer, and that gap is what the DISPUTE was made of.
raw = len(rows)
assert raw == 3 and not V._within(2, raw, {"mode": "exact"})
print("OK: 5070 — aged answered question excluded (2 counted, raw search 3)")

# --- the tile's own collector agrees on the same fixture (drift lock) ---
G.subprocess = FakeGh(rows, comments)
G_ITEMS, G_CAPPED = G._gh_questions()
assert len(G_ITEMS) == counted == 2, (
    f"wheel drift: tile renders {len(G_ITEMS)}, verifier counts {counted}")
assert G_CAPPED is False, "3 rows cannot fill the search window"
print("OK: 5070 — tile collector and verifier count the same 2 on one fixture")

# --- the verifier's own gh argv obeys the #4996 arity contract ----------
views = [a for a in fake_v.calls if a[1:3] == ["issue", "view"]]
searches = [a for a in fake_v.calls if a[1:3] == ["search", "issues"]]
assert len(searches) == 1, f"expected one search, got {len(searches)}"
assert len(views) == len(rows), (
    f"one view per search row expected ({len(rows)}), got {len(views)}")
for view, row in zip(views, rows):
    rest = view[3:]
    assert "-R" in rest and rest[rest.index("-R") + 1] == \
        row["repository"]["nameWithOwner"], view
    assert positionals(rest) == [str(row["number"])], view
print("OK: 5070 — verifier gh argv: one positional (the number), repo via -R")

# --- end to end: faithful tile DISPUTEs nothing, a raw-count tile does --
base = {"tiles": {name: {"source": "test", "stale_after_s": 900,
                         "ok": False, "observed_at": None,
                         "reason": "not under test"}
                   for name in V.SPECS}}


def run_doc(path, count):
    doc = json.loads(json.dumps(base))
    doc["tiles"]["questions"] = {"source": "test", "stale_after_s": 900,
                                 "ok": True, "observed_at": now,
                                 "count": count, "items": []}
    p = scratch / f"questions-{path}.json"
    p.write_text(json.dumps(doc))
    V.PROM_OUT = scratch / f"questions-{path}.prom"
    results = V.run(data_path=p)
    return results, json.loads(p.read_text())["tiles"]["questions"]


results_faithful, tile = run_doc("faithful", 2)
assert results_faithful["questions"] == 0, results_faithful
assert tile["disputed"] is False, tile
print("OK: 5070 — faithful tile (count=2) verifies clean, no DISPUTE")

results_raw, tile = run_doc("raw", 3)
assert results_raw["questions"] == 1, results_raw
assert tile["disputed"] is True, tile
print("OK: 5070 — tile showing the raw 3 still DISPUTEs (lie detection intact)")

# The stamp names the method, so the shell's "what is this" tells the truth.
cmd = V.SPECS["questions"]["cmd"]
assert "ANSWERED_KEEP_S" in cmd and "24h" in cmd, cmd

# --- fail closed: a gh blip is a SKIP, never a DISPUTE -----------------
for kwargs in ({"search_rc": 1}, {"view_rc": 1},
               {"search_stdout": "not json"}, {"view_stdout": "not json"}):
    V.subprocess = FakeGh(rows, comments, **kwargs)
    try:
        V.run_questions_gh({"count": 2})
        raise AssertionError(f"expected VerifyError for {kwargs}")
    except V.VerifyError:
        pass
print("OK: 5070 — gh search/view failure and non-JSON still SKIP (VerifyError)")
PY
ok "fleet-ops#5070: questions verifier counts the tile's population (aged answered excluded)"

# =========================================================================
# 12f. fleet-ops#5133: both sides ask for the FULL open-question window.
#
# `gh search issues` takes `--limit` defaulting to 30 and reports NOTHING
# when it truncates. Both the tile's search and the verifier's search left
# the flag off, so past 30 open `question` issues the tile's count/items
# were a silent 30-row window and the verifier fetched its OWN 30 rows
# seconds later from GitHub's relevance ordering — a boundary population
# then false-DISPUTEs a faithful tile, the #5070 class one qualifier over.
#
# The fixture reproduces gh's truncation: a fake gh that returns the first
# 30 rows unless the caller passes `--limit`. 31 unfiltered-of-answers
# questions must reach the tile AND the verifier.
# =========================================================================
python3 - "$gen" "$ver" <<'PY' || fail "5133: questions window failed"
import importlib.util, json, subprocess, sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

gen_path, ver_path = sys.argv[1], sys.argv[2]

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

G = load("console_generate_5133", gen_path)
V = load("console_verify_5133", ver_path)

GH_DEFAULT_LIMIT = 30          # `gh search issues --help`, gh 2.93.0

def iso(seconds_ago):
    return (datetime.now(timezone.utc) - timedelta(seconds=seconds_ago)).strftime(
        "%Y-%m-%dT%H:%M:%S+00:00")

# --- the two sides must declare the SAME window (drift guard) -----------
assert V.QUESTION_SEARCH_LIMIT == G.QUESTION_SEARCH_LIMIT, (
    f"tile window {G.QUESTION_SEARCH_LIMIT} != verifier window "
    f"{V.QUESTION_SEARCH_LIMIT}")
assert G.QUESTION_SEARCH_LIMIT > GH_DEFAULT_LIMIT, (
    "the window must clear gh's silent default, not restate it")

# 31 open, unanswered questions — one row past gh's silent default cap.
N = 31
rows = [
    {"number": 6000 + i, "title": f"q{i}", "url": f"u/{i}",
     "createdAt": iso(3600 * (i + 1)),
     "repository": {"nameWithOwner": "Nishfleet/fleet-ops"},
     "labels": [{"name": "question"}], "body": f"question: pick {i}?"}
    for i in range(N)
]


class WindowGh:
    """Fake gh that honours gh's OWN truncation rule.

    A search with no --limit returns the first 30 rows (the real default),
    so a collector that forgets the flag loses row 31 here exactly as it
    does against GitHub.
    """

    def __init__(self, rows):
        self.rows = rows
        self.calls = []

    @staticmethod
    def asked_limit(argv):
        if "--limit" in argv:
            i = argv.index("--limit")
            if i + 1 < len(argv):
                return int(argv[i + 1])
        return GH_DEFAULT_LIMIT

    def run(self, argv, **kwargs):
        argv = list(argv)
        self.calls.append(argv)
        if argv[1:3] == ["search", "issues"]:
            out = json.dumps(self.rows[:self.asked_limit(argv)])
            return subprocess.CompletedProcess(argv, 0, out, "")
        return subprocess.CompletedProcess(argv, 0, "[]", "")


def searches(calls):
    return [a for a in calls if a[1:3] == ["search", "issues"]]


def assert_limit_carried(calls, want, side):
    found = searches(calls)
    assert len(found) == 1, f"{side}: expected one search, got {len(found)}"
    argv = found[0]
    assert "--limit" in argv, f"{side} search carries no --limit: {argv}"
    i = argv.index("--limit")
    assert i + 1 < len(argv) and argv[i + 1] == str(want), \
        f"{side} --limit drifted: {argv}"


# --- the fixture really does reproduce the 30-row truncation ------------
# The argv the two sides shipped before this fix (no --limit). If this
# returns 31, the fixture is not a regression test and the test is void.
old_argv = ["gh", "search", "issues", "--owner", "Nishfleet",
            "--state", "open", "--label", "question"]
window = WindowGh(rows).run(old_argv)
assert len(json.loads(window.stdout)) == GH_DEFAULT_LIMIT == 30, (
    "fixture must truncate at gh's default for the regression to mean anything")

# --- the tile renders all 31 --------------------------------------------
tile_gh = WindowGh(rows)
G.subprocess = tile_gh
items, capped = G._gh_questions()
assert len(items) == N, f"tile rendered {len(items)} of {N} open questions"
assert capped is False, "31 rows cannot fill a 1000-row window"
assert_limit_carried(tile_gh.calls, G.QUESTION_SEARCH_LIMIT, "tile")
tile = G.collect_questions()
assert tile["ok"] is True and tile["count"] == N, tile
assert tile["capped"] is False, tile
assert tile["search_limit"] == G.QUESTION_SEARCH_LIMIT, tile

# --- the verifier counts the same 31 ------------------------------------
ver_gh = WindowGh(rows)
V.subprocess = ver_gh
V.SKIP_GH = False
counted = V.run_questions_gh({"count": N})
assert counted == N, f"verifier counted {counted} of {N} open questions"
assert_limit_carried(ver_gh.calls, V.QUESTION_SEARCH_LIMIT, "verifier")
print(f"OK: 5133 — tile renders {N} and verifier counts {counted} on one fixture")

# --- a window that FILLS is loud, never silent --------------------------
# Shrink the ceiling to gh's default: 31 rows now saturate the window, the
# tile must say so, and the shell must render that flag where Nish reads
# the list. A capped population that renders as "no more questions" is the
# hidden-decision failure the issue names.
saved = G.QUESTION_SEARCH_LIMIT
try:
    G.QUESTION_SEARCH_LIMIT = GH_DEFAULT_LIMIT
    G.subprocess = WindowGh(rows)
    filled_items, filled_capped = G._gh_questions()
    filled_tile = G.collect_questions()
finally:
    G.QUESTION_SEARCH_LIMIT = saved
assert len(filled_items) == GH_DEFAULT_LIMIT and filled_capped is True, (
    len(filled_items), filled_capped)
assert filled_tile["capped"] is True, filled_tile
assert filled_tile["search_limit"] == GH_DEFAULT_LIMIT, filled_tile
shell = (Path(gen_path).parent / "shell.html").read_text()
for needle in ("q-cap", "q.capped", "capped at"):
    assert needle in shell, f"shell.html does not disclose a capped window: {needle}"
print("OK: 5133 — a saturated window is disclosed (tile capped=true, shell says so)")
PY
ok "fleet-ops#5133: all 31 open questions reach the tile and its verifier"

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

# =========================================================================
# 15. console-truth pytest suite (fleet-ops#5072)
# =========================================================================
# test_console_truth.py ran on no gate — a console-truth regression could
# land green because nothing invoked it. Host the pytest wrapper here so a
# red suite fails a PR (the worker App cannot push .github/workflows/**).
bash "$here/console-truth-pytest.test.sh"

echo "OK: console-tile-verify.test.sh"
