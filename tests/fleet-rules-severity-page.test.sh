#!/usr/bin/env bash
# tests/fleet-rules-severity-page.test.sh
#
# fleet-ops#1534: locks that RepairDispatchDown is the ONLY severity=page
# alert in config/fleet_rules.yml. severity=page is the ONLY alertmanager
# route that reaches the phone (config/alertmanager.yml -> telegram). Every
# other alert is severity=critical/warning/none -> repair-dispatch (no phone).
#
# This test prevents a later overwrite from silently adding a second
# severity=page alert (which would page Nish for a non-meta-alert). The
# contract: exactly one page alert, and it is RepairDispatchDown (the
# meta-alert that means the repair path itself is down).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
rules="$repo_root/config/fleet_rules.yml"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$rules" ]] || fail "missing: $rules"

python3 - "$rules" <<'PY'
import sys, yaml
path = sys.argv[1]
with open(path) as f:
    cfg = yaml.safe_load(f)

def fail(msg): print(f"FAIL: {msg}", file=sys.stderr); sys.exit(1)
def ok(msg): print(f"OK: {msg}")

page_alerts = []
for g in cfg.get("groups", []):
    for r in g.get("rules", []):
        sev = r.get("labels", {}).get("severity")
        if sev == "page":
            page_alerts.append((g["name"], r["alert"]))

assert len(page_alerts) == 1, \
    fail(f"exactly one severity=page alert expected, got {len(page_alerts)}: {page_alerts}")
group, alert = page_alerts[0]
assert alert == "RepairDispatchDown", \
    fail(f"the one severity=page alert must be RepairDispatchDown, got {alert}")
ok(f"exactly one severity=page alert: {alert} (in group {group})")

# Verify RepairDispatchDown fires on up{job="am-executor"} == 0
rdd = None
for g in cfg.get("groups", []):
    for r in g.get("rules", []):
        if r.get("alert") == "RepairDispatchDown":
            rdd = r
assert rdd is not None, fail("RepairDispatchDown rule not found")
assert 'up{job="am-executor"}' in rdd["expr"], \
    fail(f"RepairDispatchDown expr must key on up{{job=\"am-executor\"}}, got: {rdd['expr']}")
assert rdd.get("labels", {}).get("service") == "fleet", \
    fail("RepairDispatchDown must have service=fleet label")
ok('RepairDispatchDown fires on up{job="am-executor"} == 0, service=fleet')

# Verify the am-executor scrape job exists in config/prometheus.yml
import os
prom = os.path.join(os.path.dirname(path), "prometheus.yml")
with open(prom) as f:
    pcfg = yaml.safe_load(f)
jobs = [j["job_name"] for j in pcfg.get("scrape_configs", [])]
assert "am-executor" in jobs, \
    fail(f"prometheus.yml must have an am-executor scrape job, got jobs: {jobs}")
am_job = [j for j in pcfg["scrape_configs"] if j["job_name"] == "am-executor"][0]
targets = []
for sc in am_job.get("static_configs", []):
    targets.extend(sc.get("targets", []))
assert "127.0.0.1:9095" in targets, \
    fail(f"am-executor scrape job must target 127.0.0.1:9095, got {targets}")
ok("prometheus.yml has am-executor scrape job -> 127.0.0.1:9095")

print()
print("fleet-rules-severity-page: all invariants pass (fleet-ops#1534)")
PY
