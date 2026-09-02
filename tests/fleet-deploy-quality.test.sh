#!/usr/bin/env bash
# tests/fleet-deploy-quality.test.sh
#
# fleet-ops#2758: deployment quality SLOs. Pins, deterministically offline
# (no gh, no systemd, no prometheus) the four computations in
# lib/fleet-deploy-quality.py -- (a) deployment latency, (b) rollback rate,
# (c) time-to-detect, (d) success rate -- plus the blocked-duration metric,
# the exporter wiring (_emit_deploy_quality), the rules, and the MANIFEST.
#
# Fixture math (FLEET_DQ_NOW = 2026-09-02T18:00:00Z):
#   merged A=-700s -> green -600s => latency 100s | alert at -450s => ttd 250s
#   merged B=-500s -> green -400s => latency 100s | alert at -450s => ttd 50s
#   merged C=-300s (no green yet, its cycle is the blocked tail) => no latency
#   merged D=-200s (same)                                             => no latency
#   success: A,B have a critical alert in-window (1h); C,D do not => 2/4 = 0.5
#   ttd p95 of [250, 50] = 250; latency p95 of [100, 100] = 100
#   reverts fixture: 1 auto-revert PR => rollback_rate = 1/4 = 0.25
#   journal blocked tail LOUDs at -199 and -99 => blocked_duration = 199s
#   (the episode starts at the first LOUD, moved+1s — real-world shape)

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
module="$repo_root/lib/fleet-deploy-quality.py"
exporter="$repo_root/libexec/fleet-metrics-export.py"
rules="$repo_root/config/fleet_rules.yml"
manifest="$repo_root/MANIFEST"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$module" ]] || fail "module not found: $module"
[[ -f "$exporter" ]] || fail "exporter not found: $exporter"
[[ -f "$rules" ]] || fail "fleet_rules.yml not found: $rules"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

scratch="$(mktemp -d -t fdq-test.XXXXXX)"
trap 'rm -r -- "$scratch"' EXIT INT TERM

FIX_NOW=1788372000   # 2026-09-02T18:00:00Z

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
[2026-09-02T17:52:30Z] DISPATCH alertname=FleetMainRed unit=x packet=y rc=0
[2026-09-02T17:54:10Z] DISPATCH alertname=FleetTestAlert unit=z packet=w rc=0
ALOG

cat >"$scratch/green-then-blocked.log" <<'JRNL'
[2026-09-02T17:40:00Z] [fleet-deploy-check] origin/main moved aaa -> bbb — invoking sanctioned deploy
[2026-09-02T17:42:00Z] [fleet-deploy-check] origin/main moved bbb -> ccc — invoking sanctioned deploy
[2026-09-02T17:42:01Z] [fleet-ops-deploy] LOUD [DEPLOY-BLOCKED] merge-to-live blocked at /x
[2026-09-02T17:50:00Z] [fleet-deploy-check] origin/main moved ccc -> ddd — invoking sanctioned deploy
JRNL

cat >"$scratch/old-blocked.log" <<'JRNL'
[2026-09-02T09:00:00Z] [fleet-deploy-check] origin/main moved aaa -> bbb — invoking sanctioned deploy
[2026-09-02T09:00:01Z] [fleet-ops-deploy] LOUD [DEPLOY-BLOCKED] merge-to-live blocked at /x
[2026-09-02T11:00:00Z] [fleet-deploy-check] origin/main moved bbb -> ccc — invoking sanctioned deploy
[2026-09-02T11:00:01Z] [fleet-ops-deploy] LOUD [DEPLOY-BLOCKED] merge-to-live blocked at /x
[2026-09-02T13:00:00Z] [fleet-deploy-check] origin/main moved ccc -> ddd — invoking sanctioned deploy
JRNL

# =========================================================================
# 1. compute(): exact values for the fixture (a)-(d) + blocked duration
# =========================================================================
python3 - "$module" "$scratch" "$FIX_NOW" <<'PY' || fail "compute() off"
import importlib.util, sys
path, scratch, now = sys.argv[1], sys.argv[2], float(sys.argv[3])
env = {
    "FLEET_DQ_NOW": str(now),
    "FLEET_DQ_MERGED": f"{scratch}/merged.json",
    "FLEET_DQ_REVERTS": f"{scratch}/reverts.json",
    "FLEET_DQ_JOURNAL": f"{scratch}/journal.log",
    "FLEET_DQ_ACTIONS_LOG": f"{scratch}/actions.log",
    "FLEET_DQ_CACHE_DIR": f"{scratch}/cache",
}
spec = importlib.util.spec_from_file_location("fdq", path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

p = m.compute(env)

def near(a, b, tol=1e-6):
    assert abs(a - b) <= tol, f"{a} != {b}"

print("payload:", {k: p[k] for k in
    ("latency_p95", "rollback_rate", "time_to_detect_p95", "success_rate",
     "blocked_duration", "total", "revert_total", "up")})
near(p["latency_p95"], 100.0)
near(p["rollback_rate"], 0.25)
near(p["time_to_detect_p95"], 250.0)
near(p["success_rate"], 0.5)
near(p["blocked_duration"], 199.0)
near(p["total"], 4)
near(p["revert_total"], 1)
assert p["up"] == 1
print("OK: compute() (a) latency p95=100, (b) rollback=0.25, (c) ttd p95=250, (d) success=0.5, blocked=199")

# 2. blocked_duration -> 0 when the newest cycle is GREEN (episode ended)
env2 = dict(env)
env2["FLEET_DQ_JOURNAL"] = f"{scratch}/green-then-blocked.log"
p2 = m.compute(env2)
near(p2["blocked_duration"], 0.0, 1e-4)
print("OK: blocked_duration is 0 when the newest cycle is green")

# 3. blocked_duration -> 0 when the blocked episode is OLD (a later green
#    cycle ended the run; only the CURRENT episode counts)
env3 = dict(env)
env3["FLEET_DQ_JOURNAL"] = f"{scratch}/old-blocked.log"
p3 = m.compute(env3)
near(p3["blocked_duration"], 0.0, 1e-4)
print("OK: only the CURRENT blocked episode counts (old episode -> 0)")

# 4. a merge with no green yet (incomplete deployment) is EXCLUDED from
#    latency — p95 must not read 0 for it. Move B to -250s (no green
#    >= -250); the latency list stays [100, 100] -> p95 = 100.
import json, pathlib
merged = json.loads(pathlib.Path(f"{scratch}/merged.json").read_text())
merged[1]["mergedAt"] = "2026-09-02T17:55:50Z"  # B=-250
pathlib.Path(f"{scratch}/merged4.json").write_text(json.dumps(merged))
env4 = dict(env)
env4["FLEET_DQ_MERGED"] = f"{scratch}/merged4.json"
p4 = m.compute(env4)
near(p4["latency_p95"], 100.0)
print("OK: incomplete deployment excluded from latency (not counted as 0)")
PY
ok "compute() deterministic fixture math"

# =========================================================================
# 5. prom_lines(): named gauges present, one HELP/TYPE each, up=1
# =========================================================================
python3 - "$module" "$scratch" "$FIX_NOW" <<'PY' || fail "prom_lines off"
import importlib.util, sys
path, scratch, now = sys.argv[1], sys.argv[2], float(sys.argv[3])
env = {
    "FLEET_DQ_NOW": str(now),
    "FLEET_DQ_MERGED": f"{scratch}/merged.json",
    "FLEET_DQ_REVERTS": f"{scratch}/reverts.json",
    "FLEET_DQ_JOURNAL": f"{scratch}/journal.log",
    "FLEET_DQ_ACTIONS_LOG": f"{scratch}/actions.log",
    "FLEET_DQ_CACHE_DIR": f"{scratch}/cache",
}
spec = importlib.util.spec_from_file_location("fdq", path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

lines = m.prom_lines(env)
text = "\n".join(lines)
expected = {
    'fleet_deployment_latency_seconds{repo="fleet-ops"}': 100,
    'fleet_deployment_rollback_rate{repo="fleet-ops"}': 0.25,
    'fleet_deployment_time_to_detect_seconds{repo="fleet-ops"}': 250,
    'fleet_deployment_success_rate{repo="fleet-ops"}': 0.5,
    'fleet_deploy_blocked_duration_seconds{repo="fleet-ops"}': 199,
    'fleet_deployment_quality_up{repo="fleet-ops"}': 1,
}
for name, exp in expected.items():
    for line in lines:
        if line.startswith(name + " "):
            got = float(line.split()[-1])
            assert abs(got - exp) <= 1e-3, f"{name}={got} expected {exp}"
            break
    else:
        assert False, f"missing gauge {name}"
# one HELP and one TYPE per metric (node_exporter dedup discipline)
for name in ("fleet_deployment_latency_seconds", "fleet_deployment_rollback_rate"):
    assert text.count(f"# HELP {name} ") == 1, name
    assert text.count(f"# TYPE {name} gauge") == 1, name
print("OK: prom_lines emits all six gauges with exact values, dedup HELP/TYPE")
PY
ok "prom_lines() family shape"

# =========================================================================
# 6. exporter wiring: _emit_deploy_quality success + failure paths
# =========================================================================
python3 - "$exporter" "$module" "$scratch" "$FIX_NOW" <<'PY' || fail "exporter wiring off"
import importlib.util, os, sys
exporter, module_path, scratch, now = sys.argv[1:5]
os.environ["FLEET_DQ_NOW"] = str(now)
os.environ["FLEET_DQ_MERGED"] = f"{scratch}/merged.json"
os.environ["FLEET_DQ_REVERTS"] = f"{scratch}/reverts.json"
os.environ["FLEET_DQ_JOURNAL"] = f"{scratch}/journal.log"
os.environ["FLEET_DQ_ACTIONS_LOG"] = f"{scratch}/actions.log"
os.environ["FLEET_DQ_CACHE_DIR"] = f"{scratch}/cache"

spec = importlib.util.spec_from_file_location("fme", exporter)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

lines = []
m._emit_deploy_quality(lines)
text = "\n".join(lines)
assert 'fleet_deployment_quality_up{repo="fleet-ops"} 1' in text
assert 'fleet_deployment_latency_seconds{repo="fleet-ops"} 100' in text
assert 'fleet_deployment_success_rate{repo="fleet-ops"} 0.5' in text
print("OK: exporter _emit_deploy_quality emits the family with up=1")

# failure path: bad merged fixture + broken gh -> NaN gauges + up 0
os.environ["FLEET_DQ_MERGED"] = "/nonexistent/merged.json"
os.environ["FLEET_DQ_REVERTS"] = "/nonexistent/reverts.json"
os.environ["FLEET_DQ_GH"] = "/nonexistent/gh"
lines2 = []
m._emit_deploy_quality(lines2)
text2 = "\n".join(lines2)
assert 'fleet_deployment_quality_up{repo="fleet-ops"} 0' in text2
for g in ("fleet_deployment_latency_seconds", "fleet_deploy_blocked_duration_seconds"):
    assert any(l.startswith(g + '{repo="fleet-ops"} NaN') for l in lines2), g
print("OK: exporter failure path emits NaN gauges + up 0")
PY
ok "exporter wiring"

# =========================================================================
# 7. rules: promtool check + fire/no-fire behavior
# =========================================================================
if command -v promtool >/dev/null 2>&1; then
  promtool check rules "$rules" >/dev/null \
    || fail "promtool check rules failed on fleet_rules.yml"
  ok "promtool check rules: fleet_rules.yml valid"

  cat >"$scratch/fdq.test.yml" <<YOAML
rule_files:
  - $rules
evaluation_interval: 1m
tests:
  - interval: 1m
    name: DeployBlockedStuck fires when blocked > 900s for 3m
    input_series:
      - series: 'fleet_deploy_blocked_duration_seconds{repo="fleet-ops"}'
        values: '0x1 901x40'
    alert_rule_test:
      - eval_time: 8m
        alertname: DeployBlockedStuck
        exp_alerts:
          - exp_labels:
              alertname: DeployBlockedStuck
              repo: fleet-ops
              severity: critical
              service: fleet
            exp_annotations:
              summary: "fleet-ops deploy blocked for 15+ minutes (fleet-ops#2725 pattern)"
              description: "fleet_deploy_blocked_duration_seconds{repo=\"fleet-ops\"} exceeded 900s (15 min): the fleet-ops deploy clone is stuck DEPLOY-BLOCKED. 2026-09-02 live case: >1h blocked on dirty tracked files with zero mechanized alert (fleet-ops#2725). Merge-to-live is halted; clear the dirty state on /home/nish/workspaces/tooling/fleet-ops-deploy-clone or root-cause the block. Check journalctl --user -u fleet-deploy-check.service."
  - interval: 1m
    name: rollback-rate-high-fires
    input_series:
      - series: 'fleet_deployment_rollback_rate{repo="fleet-ops"}'
        values: '0.2x40'
    alert_rule_test:
      - eval_time: 12m
        alertname: DeploymentRollbackRateHigh
        exp_alerts:
          - exp_labels:
              alertname: DeploymentRollbackRateHigh
              repo: fleet-ops
              severity: critical
              service: fleet
            exp_annotations:
              summary: "fleet-ops auto-revert rate above 10% of deployments (30d)"
              description: "More than 10% of fleet-ops deployments in the trailing 30 days were rolled back by the auto-revert machinery (revert: auto-restore green main PRs / merged deployments). The fleet is shipping breakage to main faster than the red-on-main pipeline catches it. fleet-ops#2758."
  - interval: 1m
    name: rollback-rate-low-silent
    input_series:
      - series: 'fleet_deployment_rollback_rate{repo="fleet-ops"}'
        values: '0.05x40'
    alert_rule_test:
      - eval_time: 12m
        alertname: DeploymentRollbackRateHigh
        exp_alerts: []
  - interval: 1m
    name: quality-stale-fires-on-up0
    input_series:
      - series: 'fleet_deployment_quality_up{repo="fleet-ops"}'
        values: '0x40'
    alert_rule_test:
      - eval_time: 16m
        alertname: DeploymentQualityStale
        exp_alerts:
          - exp_labels:
              alertname: DeploymentQualityStale
              repo: fleet-ops
              severity: warning
              service: fleet
            exp_annotations:
              summary: "deployment-quality metrics computation failed or vanished"
              description: "fleet_deployment_quality_up is absent or 0 for 15+ minutes — lib/fleet-deploy-quality.py failed (the gauges are NaN so threshold rules are silent; THIS alert is the only loud signal). The exporter logs 'deploy-quality: ...' to stderr; check journalctl --user -u fleet-metrics-export.service and /home/nish/.local/lib/pi-packet/fleet-deploy-quality.py. fleet-ops#2758."
YOAML
  if ! out="$(promtool test rules "$scratch/fdq.test.yml" 2>&1)"; then
    fail "promtool test rules exited non-zero: $out"
  fi
  grep -q "SUCCESS" <<<"$out" \
    || fail "promtool test rules did not succeed: $out"
  ok "promtool test rules: deploy-quality rules fire/silent correctly"
else
  echo "OK: promtool not installed -- skipping rules behavior test"
fi

# =========================================================================
# 8. MANIFEST + exporter hook presence
# =========================================================================
grep -Fqx "lib/fleet-deploy-quality.py /home/nish/.local/lib/pi-packet/fleet-deploy-quality.py" "$manifest" \
  || fail "MANIFEST missing lib/fleet-deploy-quality.py"
grep -q "_emit_deploy_quality" "$exporter" || fail "exporter missing _emit_deploy_quality"
grep -q "fleet-deploy-quality.py" "$exporter" || fail "exporter missing module reference"
ok "MANIFEST entry + exporter hook present"

echo
echo "all fleet-deploy-quality tests passed"