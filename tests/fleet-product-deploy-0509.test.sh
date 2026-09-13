#!/usr/bin/env bash
# tests/fleet-product-deploy-0509.test.sh
#
# fleet-ops#5140: the deploy-quality family is multi-repo — every
# `product: true` repo in intake-repos.json gets its own series. This pins,
# deterministically offline (no gh, no prometheus, no network), the 0509
# product path in lib/fleet-deploy-quality.py:
#
#   - three consecutive failed `Deploy production` runs (the live 2026-09-10
#     stall class) -> fleet_deploy_blocked_duration_seconds{repo="0509",
#     workflow="Deploy production"} > 0
#   - fleet-ops rows come BEFORE any product row for the same metric name
#     (existing tests first-match on `name{repo="fleet-ops"}`)
#   - newest run green -> blocked 0 and fleet_product_deploy_green 1
#   - a declared product repo with an unreadable runs source emits NaN
#     gauges + fleet_deployment_quality_up{repo="<r>"} 0 while the fleet-ops
#     numbers stay pinned
#   - exactly one # HELP / # TYPE per metric name across the whole output
#
# Fleet-ops fixture math is identical to tests/fleet-deploy-quality.test.sh
# (FLEET_DQ_NOW = 2026-09-02T18:00:00Z): latency p95=100, rollback=0.25,
# ttd p95=50 (TTD_MIN_SAMPLES lowered to 1), success=0.5, blocked=199s,
# total=4, revert_total=1, up=1. FLEET_DQ_GH=/nonexistent/gh is belt and
# braces — every source is a file seam, so no gh/network is ever reached.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
module="$repo_root/lib/fleet-deploy-quality.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$module" ]] || fail "module not found: $module"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

scratch="$(mktemp -d -t fpd0509-test.XXXXXX)"
trap 'rm -r -- "$scratch"' EXIT INT TERM

FIX_NOW=1788372000   # 2026-09-02T18:00:00Z

# --- fleet-ops fixtures (identical to fleet-deploy-quality.test.sh) -------
cat >"$scratch/merged.json" <<'JSON'
[
  {"number": 1, "mergedAt": "2026-09-02T17:48:20Z"},
  {"number": 2, "mergedAt": "2026-09-02T17:51:40Z"},
  {"number": 3, "mergedAt": "2026-09-02T17:55:00Z"},
  {"number": 4, "mergedAt": "2026-09-02T17:56:40Z"}
]
JSON
echo '[{"number": 700}]' > "$scratch/reverts.json"

cat >"$scratch/journal.log" <<'JRNL'
Sep 02 17:47:00 host fleet-deploy-check[0]: [2026-09-02T17:47:00Z] [fleet-deploy-check] origin/main unchanged (HEAD=zzz) — nothing to do
Sep 02 17:50:00 host fleet-deploy-check[1]: [2026-09-02T17:50:00Z] [fleet-deploy-check] origin/main moved aaa1 -> bbbb2 — invoking sanctioned deploy
Sep 02 17:50:01 host systemd[1038]: Finished fleet-deploy-check.service.
Sep 02 17:53:20 host fleet-deploy-check[2]: [2026-09-02T17:53:20Z] [fleet-deploy-check] origin/main moved bbbb2 -> cccc3 — invoking sanctioned deploy
Sep 02 17:53:21 host systemd[1038]: Finished fleet-deploy-check.service.
Sep 02 17:56:40 host fleet-deploy-check[3]: [2026-09-02T17:56:40Z] [fleet-deploy-check] origin/main moved cccc3 -> dddd4 — invoking sanctioned deploy
Sep 02 17:56:41 host fleet-ops-deploy[4]: [2026-09-02T17:56:41Z] [fleet-ops-deploy] LOUD [DEPLOY-BLOCKED] merge-to-live blocked at /x: dirty tracked files
Sep 02 17:56:41 host fleet-deploy-check[3]: [2026-09-02T17:56:41Z] [fleet-deploy-check] LOUD DEPLOY-CHECK-FAILED fleet-ops-deploy exited rc=1
Sep 02 17:58:20 host fleet-deploy-check[5]: [2026-09-02T17:58:20Z] [fleet-deploy-check] origin/main moved dddd4 -> eeee5 — invoking sanctioned deploy
Sep 02 17:58:21 host fleet-ops-deploy[6]: [2026-09-02T17:58:21Z] [fleet-ops-deploy] LOUD [DEPLOY-BLOCKED] merge-to-live blocked at /x: dirty tracked files
Sep 02 17:58:21 host fleet-deploy-check[5]: [2026-09-02T17:58:21Z] [fleet-deploy-check] LOUD DEPLOY-CHECK-FAILED fleet-ops-deploy exited rc=1
JRNL

cat >"$scratch/actions.log" <<'ALOG'
[2026-09-02T17:52:30Z] DISPATCH alertname=FleetHeartbeatStale unit=x packet=y rc=0
[2026-09-02T17:54:10Z] DISPATCH alertname=FleetTestAlert unit=z packet=w rc=0
ALOG

# --- product fixtures (fleet-ops#5140) ------------------------------------
# intake-repos.json shape: fleet-ops is non-product (measured by compute()),
# 0509 is the real product repo, 0999 is a declared product repo whose runs
# source is unreadable (no entry in FLEET_DQ_DEPLOY_RUNS) -> NaN + up 0.
cat >"$scratch/intake.json" <<'JSON'
{"repos": [
  {"name": "fleet-ops", "product": false},
  {"name": "0509", "product": true},
  {"name": "0999", "product": true}
]}
JSON

# 0999 is absent from PRODUCT_DEPLOY_WORKFLOWS in the lib; declare its
# production-deploy workflow through the seam so its failure is genuinely
# the runs source, not a missing table entry.
cat >"$scratch/deploy-workflows.json" <<'JSON'
{"0999": "Deploy production"}
JSON

# Red streak: the last three Deploy production runs failed-failed-failed
# (the live 2026-09-10 shape). An older success run bounds the streak so
# blocked_duration = now - oldest non-green createdAt = 18:00 - 14:00 = 4h.
cat >"$scratch/deploy-runs-red.json" <<'JSON'
{"0509": [
  {"databaseId": 4, "status": "completed", "conclusion": "failure",
   "createdAt": "2026-09-02T16:00:00Z", "updatedAt": "2026-09-02T16:10:00Z",
   "url": "https://github.com/Nishfleet/0509/actions/runs/4"},
  {"databaseId": 3, "status": "completed", "conclusion": "failure",
   "createdAt": "2026-09-02T15:00:00Z", "updatedAt": "2026-09-02T15:10:00Z",
   "url": "https://github.com/Nishfleet/0509/actions/runs/3"},
  {"databaseId": 2, "status": "completed", "conclusion": "failure",
   "createdAt": "2026-09-02T14:00:00Z", "updatedAt": "2026-09-02T14:10:00Z",
   "url": "https://github.com/Nishfleet/0509/actions/runs/2"},
  {"databaseId": 1, "status": "completed", "conclusion": "success",
   "createdAt": "2026-09-02T12:00:00Z", "updatedAt": "2026-09-02T12:10:00Z",
   "url": "https://github.com/Nishfleet/0509/actions/runs/1"}
]}
JSON

# Green newest run: the stall is over -> blocked 0, green 1, no red-run row.
cat >"$scratch/deploy-runs-green.json" <<'JSON'
{"0509": [
  {"databaseId": 5, "status": "completed", "conclusion": "success",
   "createdAt": "2026-09-02T17:30:00Z", "updatedAt": "2026-09-02T17:40:00Z",
   "url": "https://github.com/Nishfleet/0509/actions/runs/5"},
  {"databaseId": 4, "status": "completed", "conclusion": "failure",
   "createdAt": "2026-09-02T16:00:00Z", "updatedAt": "2026-09-02T16:10:00Z",
   "url": "https://github.com/Nishfleet/0509/actions/runs/4"}
]}
JSON

# Merges source per repo (skips gh). 0509 gets one merge inside run coverage
# (17:00 merge -> 17:40 green completion in the green fixture); 0999 gets an
# empty list — it fails on the runs source before merges are read anyway.
cat >"$scratch/product-merged.json" <<'JSON'
{"0509": [{"number": 9, "mergedAt": "2026-09-02T17:00:00Z"}], "0999": []}
JSON

# =========================================================================
# 1. Red streak: 0509 blocked > 0, up=1, info series present, fleet-ops rows
#    first, 0999 degraded to NaN + up 0, fleet-ops numbers pinned.
# =========================================================================
python3 - "$module" "$scratch" "$FIX_NOW" <<'PY' || fail "red-streak scrape off"
import importlib.util, sys
from collections import Counter
path, scratch, now = sys.argv[1], sys.argv[2], float(sys.argv[3])
env = {
    "FLEET_DQ_NOW": str(now),
    "FLEET_DQ_MERGED": f"{scratch}/merged.json",
    "FLEET_DQ_REVERTS": f"{scratch}/reverts.json",
    "FLEET_DQ_JOURNAL": f"{scratch}/journal.log",
    "FLEET_DQ_ACTIONS_LOG": f"{scratch}/actions.log",
    "FLEET_DQ_CACHE_DIR": f"{scratch}/cache-red",
    "FLEET_DQ_REPOS_JSON": f"{scratch}/intake.json",
    "FLEET_DQ_DEPLOY_WORKFLOWS": f"{scratch}/deploy-workflows.json",
    "FLEET_DQ_DEPLOY_RUNS": f"{scratch}/deploy-runs-red.json",
    "FLEET_DQ_PRODUCT_MERGED": f"{scratch}/product-merged.json",
    "FLEET_DQ_GH": "/nonexistent/gh",
    "FLEET_DQ_TTD_MIN_SAMPLES": "1",
}
spec = importlib.util.spec_from_file_location("fdq", path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.TTD_MIN_SAMPLES = 1  # fixture has 1 episode sample (same as the fleet-ops test)

lines = [l for l in m.prom_lines(env) if l]
text = "\n".join(lines)

def value(series_prefix):
    """First-match read of `series_prefix value` (fleet-ops row is first)."""
    for line in lines:
        if line.startswith(series_prefix + " "):
            return line.split()[-1]
    raise AssertionError(f"missing series {series_prefix}")

def near(a, b, tol=1e-3):
    assert abs(float(a) - b) <= tol, f"{a} != {b}"

# --- 0509 red streak: last three Deploy production runs failed ------------
# blocked = now - oldest non-green createdAt = 18:00 - 14:00 = 14400s > 0.
blocked_0509 = value('fleet_deploy_blocked_duration_seconds{repo="0509",workflow="Deploy production"}')
assert float(blocked_0509) > 0, blocked_0509
near(blocked_0509, 14400.0)
assert value('fleet_product_deploy_green{repo="0509"}') == "0"
# The info series the ProductDeployStalled annotation reads the url from.
assert 'fleet_product_deploy_last_red_run_info{repo="0509",workflow="Deploy production",url="https://github.com/Nishfleet/0509/actions/runs/4"} 1' in lines
print("OK: 0509 red streak -> blocked 14400s > 0, green 0, last-red-run info row present")

# --- fleet-ops#5785 stale-production gauges -------------------------------
# Last green = run 1 completion (updatedAt 12:10) -> stale = 18:00 - 12:10
# = 5.833h. The 17:00 merge is newer than that green -> undeployed_merges 1.
near(value('fleet_product_production_stale_hours{repo="0509",workflow="Deploy production"}'), 5.833)
near(value('fleet_product_deploy_last_green_seconds{repo="0509",workflow="Deploy production"}'), 1788351000)
near(value('fleet_product_main_last_merge_seconds{repo="0509"}'), 1788368400)
assert value('fleet_product_undeployed_merges{repo="0509"}') == "1"
# 0999 unmeasurable -> NaN on the new gauges too.
assert value('fleet_product_production_stale_hours{repo="0999",workflow="Deploy production"}') == "NaN"
assert value('fleet_product_undeployed_merges{repo="0999"}') == "NaN"
print("OK: stale-hours 5.833 + last-green/merge epochs + undeployed_merges 1 (0509), NaN (0999)")

# --- fleet-ops rows come BEFORE any 0509 row for the same metric name -----
for name in ("fleet_deployment_latency_seconds",
             "fleet_deploy_blocked_duration_seconds",
             "fleet_deployment_quality_up"):
    rows = [l for l in lines if l.startswith(name + "{")]
    assert rows, name
    assert rows[0].startswith(name + '{repo="fleet-ops"}'), (name, rows)
    assert any('{repo="0509"' in r for r in rows), (name, rows)
print("OK: fleet-ops series precede the 0509 series for every shared metric")

# --- fleet-ops series still equal their existing pinned numbers -----------
expected_fleet = {
    'fleet_deployment_latency_seconds{repo="fleet-ops"}': 100,
    'fleet_deployment_rollback_rate{repo="fleet-ops"}': 0.25,
    'fleet_deployment_time_to_detect_seconds{repo="fleet-ops"}': 50,
    'fleet_deployment_success_rate{repo="fleet-ops"}': 0.5,
    'fleet_deploy_blocked_duration_seconds{repo="fleet-ops"}': 199,
    'fleet_deployment_quality_up{repo="fleet-ops"}': 1,
}
for series, exp in expected_fleet.items():
    near(value(series), exp)
print("OK: fleet-ops payload byte-pinned while product repos are measured")

# --- 0999: declared product repo, unreadable runs source ------------------
# NaN gauges + up 0 for THIS repo only; no last-red-run info row.
assert value('fleet_deployment_quality_up{repo="0999"}') == "0"
assert value('fleet_deploy_blocked_duration_seconds{repo="0999",workflow="Deploy production"}') == "NaN"
assert value('fleet_deployment_latency_seconds{repo="0999"}') == "NaN"
assert value('fleet_product_deploy_green{repo="0999"}') == "NaN"
assert not any(l.startswith('fleet_product_deploy_last_red_run_info{repo="0999"') for l in lines)
print("OK: unreadable 0999 -> NaN gauges + fleet_deployment_quality_up 0, fleet-ops unaffected")

# --- exactly one # HELP and one # TYPE per metric name --------------------
help_names = [l.split()[2] for l in lines if l.startswith("# HELP ")]
type_names = [l.split()[2] for l in lines if l.startswith("# TYPE ")]
data_names = {l.split("{")[0].split()[0] for l in lines if not l.startswith("#")}
hc, tc = Counter(help_names), Counter(type_names)
assert all(v == 1 for v in hc.values()), f"dup HELP: {hc}"
assert all(v == 1 for v in tc.values()), f"dup TYPE: {tc}"
assert set(hc) == data_names, (set(hc), data_names)
assert set(tc) == data_names, (set(tc), data_names)
print("OK: exactly one # HELP and one # TYPE per metric name "
      f"({len(data_names)} metrics)")
PY
ok "red-streak scrape: 0509 blocked, ordering, 0999 NaN+up0, HELP/TYPE dedup"

# =========================================================================
# 2. Green newest run: blocked 0, green 1, no red-run info row for 0509.
# =========================================================================
python3 - "$module" "$scratch" "$FIX_NOW" <<'PY' || fail "green scrape off"
import importlib.util, sys
path, scratch, now = sys.argv[1], sys.argv[2], float(sys.argv[3])
env = {
    "FLEET_DQ_NOW": str(now),
    "FLEET_DQ_MERGED": f"{scratch}/merged.json",
    "FLEET_DQ_REVERTS": f"{scratch}/reverts.json",
    "FLEET_DQ_JOURNAL": f"{scratch}/journal.log",
    "FLEET_DQ_ACTIONS_LOG": f"{scratch}/actions.log",
    "FLEET_DQ_CACHE_DIR": f"{scratch}/cache-green",
    "FLEET_DQ_REPOS_JSON": f"{scratch}/intake.json",
    "FLEET_DQ_DEPLOY_WORKFLOWS": f"{scratch}/deploy-workflows.json",
    "FLEET_DQ_DEPLOY_RUNS": f"{scratch}/deploy-runs-green.json",
    "FLEET_DQ_PRODUCT_MERGED": f"{scratch}/product-merged.json",
    "FLEET_DQ_GH": "/nonexistent/gh",
    "FLEET_DQ_TTD_MIN_SAMPLES": "1",
}
spec = importlib.util.spec_from_file_location("fdq", path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.TTD_MIN_SAMPLES = 1

lines = [l for l in m.prom_lines(env) if l]

def value(series_prefix):
    for line in lines:
        if line.startswith(series_prefix + " "):
            return line.split()[-1]
    raise AssertionError(f"missing series {series_prefix}")

# Newest run green -> blocked 0 and deploy green 1 (fleet-ops#5140).
assert value('fleet_deploy_blocked_duration_seconds{repo="0509",workflow="Deploy production"}') == "0.0" or \
       float(value('fleet_deploy_blocked_duration_seconds{repo="0509",workflow="Deploy production"}')) == 0.0
assert value('fleet_product_deploy_green{repo="0509"}') == "1"
assert not any(l.startswith('fleet_product_deploy_last_red_run_info{repo="0509"') for l in lines), \
    "red-run info row must be absent when the newest run is green"
# merge 17:00 -> first green completion 17:40 = 2400s latency sample.
assert float(value('fleet_deployment_latency_seconds{repo="0509"}')) == 2400.0
# fleet-ops#5785: green completion 17:40 -> stale 20m (0.333h); the 17:00
# merge is OLDER than the green run -> undeployed_merges 0 (alert silent).
assert abs(float(value('fleet_product_production_stale_hours{repo="0509",workflow="Deploy production"}')) - 0.333) < 1e-3
assert abs(float(value('fleet_product_deploy_last_green_seconds{repo="0509",workflow="Deploy production"}')) - 1788370800) < 1e-3
assert value('fleet_product_undeployed_merges{repo="0509"}') == "0"
# fleet-ops payload still pinned.
assert float(value('fleet_deployment_latency_seconds{repo="fleet-ops"}')) == 100.0
assert float(value('fleet_deployment_quality_up{repo="fleet-ops"}')) == 1.0
print("OK: newest run green -> 0509 blocked 0, deploy green 1, "
      "no red-run info row, fleet-ops pinned")
PY
ok "green scrape: 0509 blocked 0, green 1, info row absent"

echo
echo "all fleet-product-deploy-0509 tests passed"
