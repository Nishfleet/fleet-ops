#!/usr/bin/env bash
# tests/fleet-production-stale-alert.test.sh
#
# fleet-ops#5785 accept criteria 2+3: FleetProductionStale is a CRITICAL
# alert that fires when a product repo's last green production deploy is
# older than two hours while main carries merges production never shipped —
# and it dispatches through repair-dispatch on a FLAGSHIP seat (label
# repair_seat=flagship -> senior_seats_in_order, tested separately in
# tests/alert-repair-flagship-seat.test.sh).
#
# The live class: 0509 production sat on the 2026-09-09T17:03Z build for
# ~2.5 days, every release run failing Gate C, while >100 AUTO-REVERT HALT
# issues piled up and nobody dispatched a flagship repair. A human had to
# notice stale production by hand — the blind spot this alert kills.
#
# Proven here:
#   1. Rule shape: critical severity, service=fleet, repair_seat=flagship,
#      expr keys on fleet_product_production_stale_hours > 2 AND
#      fleet_product_undeployed_merges == 1, for=15m, evidence annotation
#      carries the red run + failing job/step.
#   2. promtool: FIRES for the 2026-09-12 stale state (54.3h stale, merge
#      newer than last green).
#   3. promtool: SILENT right after a green run (stale ~0).
#   4. promtool: SILENT when production is old but main has NOTHING new
#      undeployed (stale>2h, undeployed_merges=0) — staleness alone is not
#      the fault; a newer merge is.
#   5. promtool: FleetDeployFaultClosedWithoutGreen fires on a nonzero
#      tripwire gauge and stays silent at zero.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
rules="$repo_root/config/fleet_rules.yml"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

command -v promtool >/dev/null 2>&1 || fail "promtool required"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# --- 1. Rule shape ----------------------------------------------------------
python3 - "$rules" <<'PY'
import sys, yaml
rules = yaml.safe_load(open(sys.argv[1]))
alerts = {
    r["alert"]: r
    for g in rules["groups"] for r in g["rules"] if "alert" in r
}
a = alerts.get("FleetProductionStale") or sys.exit(
    "FAIL: FleetProductionStale missing from fleet_rules.yml")
assert a["labels"]["severity"] == "critical", a["labels"]
assert a["labels"]["service"] == "fleet", a["labels"]
assert a["labels"]["repair_seat"] == "flagship", a["labels"]
assert a.get("for") == "15m", a.get("for")
expr = a["expr"]
assert "fleet_product_production_stale_hours" in expr, expr
assert "> 2" in expr, expr
assert "fleet_product_undeployed_merges" in expr, expr
ann = a["annotations"]
assert "evidence" in ann, "evidence annotation required for the repair packet"
assert "failing_step" in ann["evidence"], ann["evidence"]
assert "last_red_run" in ann["evidence"], ann["evidence"]
assert "fleet-ops#5785" in ann["description"], "rule must cite its issue"

t = alerts.get("FleetDeployFaultClosedWithoutGreen") or sys.exit(
    "FAIL: FleetDeployFaultClosedWithoutGreen missing")
assert "fleet_deploy_fault_closed_without_green > 0" in t["expr"], t["expr"]
assert "repair_seat" not in t["labels"], \
    "the tripwire must NOT spawn a repair worker — the sweep already reopened"
print("OK: rule shape — critical/flagship, 2h stale + undeployed merges, "
      "evidence annotation, tripwire has no repair_seat")
PY

# --- 2/3/4. promtool test rules: fire + silence ------------------------------
cat >"$scratch/stale.test.yml" <<YQ
rule_files:
  - $rules
evaluation_interval: 1m
tests:
  - interval: 1m
    name: 2026-09-12 0509 stale state — 54.3h since last green, merge pending
    input_series:
      - series: 'fleet_product_production_stale_hours{repo="0509", workflow="Deploy production"}'
        values: '54.3x40'
      - series: 'fleet_product_undeployed_merges{repo="0509"}'
        values: '1x40'
      - series: 'fleet_product_deploy_last_red_run_info{repo="0509", workflow="Deploy production", url="https://github.com/Nishfleet/0509/actions/runs/34514527796"}'
        values: '1x40'
      - series: 'fleet_product_deploy_last_red_step_info{repo="0509", workflow="Deploy production", job="deploy", step="Deploy"}'
        values: '1x40'
      - series: 'fleet_product_main_last_merge_seconds{repo="0509"}'
        values: '1789149600x40'
      - series: 'fleet_deploy_fault_closed_without_green'
        values: '0x40'
    alert_rule_test:
      - eval_time: 20m
        alertname: FleetProductionStale
        exp_alerts:
          - exp_labels:
              severity: critical
              service: fleet
              repair_seat: flagship
              repo: "0509"
              workflow: Deploy production
            exp_annotations:
              summary: '0509 production stale: last green Deploy production deploy 54.3h ago while main has undeployed merges'
              description: '0509''s production deploy workflow Deploy production last ran GREEN 54.3h ago AND main carries a merge newer than that green run — customers are running code merges superseded. Evidence: newest red run https://github.com/Nishfleet/0509/actions/runs/34514527796; failing step deploy/Deploy; newest main merge 2026-09-11 18:00:00 +0000 UTC. Repair (flagship seat): open the newest red run, read the failing step, land the fix, then confirm a GREEN Deploy production run whose SHA contains the fix before the deploy-fault issue may close (the deploy-fault gate reopens it otherwise, fleet-ops#5785). fleet-ops#5785: 0509 production sat stale ~2.5 days on the 2026-09-09T17:03Z build while halts piled up.'
              evidence: '{"repo":"0509","workflow":"Deploy production","stale_hours":54.3,"last_red_run":"https://github.com/Nishfleet/0509/actions/runs/34514527796","failing_job":"deploy","failing_step":"Deploy"}'

  - interval: 1m
    name: green run just landed — alert silent
    input_series:
      - series: 'fleet_product_production_stale_hours{repo="0509", workflow="Deploy production"}'
        values: '0.2x40'
      - series: 'fleet_product_undeployed_merges{repo="0509"}'
        values: '0x40'
    alert_rule_test:
      - eval_time: 20m
        alertname: FleetProductionStale
        exp_alerts: []

  - interval: 1m
    name: old production but nothing new on main — staleness alone is not the fault
    input_series:
      - series: 'fleet_product_production_stale_hours{repo="0509", workflow="Deploy production"}'
        values: '30x40'
      - series: 'fleet_product_undeployed_merges{repo="0509"}'
        values: '0x40'
    alert_rule_test:
      - eval_time: 20m
        alertname: FleetProductionStale
        exp_alerts: []

  - interval: 1m
    name: deploy-fault tripwire — fires on nonzero, silent at zero
    input_series:
      - series: 'fleet_product_production_stale_hours{repo="0509", workflow="Deploy production"}'
        values: '0.1x40'
      - series: 'fleet_product_undeployed_merges{repo="0509"}'
        values: '0x40'
      - series: 'fleet_deploy_fault_closed_without_green'
        values: '0x20 1x19'
    alert_rule_test:
      - eval_time: 39m
        alertname: FleetDeployFaultClosedWithoutGreen
        exp_alerts:
          - exp_labels:
              severity: warning
              service: fleet
            exp_annotations:
              summary: 'a deploy-fault issue was closed without a green Deploy production run (fleet-ops#5785)'
              description: 'fleet_deploy_fault_closed_without_green is 1: the lifecycle-label-sweep reopen pass found deploy-fault issue(s) closed while no green production-deploy run''s SHA contains the fix, and reopened them. The repair already happened (reopen + deploy-fault-gate comment). Investigate WHO closed them — the legal close paths are a closing comment citing the green run URL, or a green run containing the delivery merge. Check /home/nish/.local/state/fleet-heartbeat/lifecycle-label-sweep.json and the sweep''s tick log. Must stay 0.'
YQ

out="$(promtool test rules "$scratch/stale.test.yml" 2>&1)" \
    || fail "promtool test rules failed: $out"
grep -q "SUCCESS" <<<"$out" \
    || fail "promtool test rules did not succeed: $out"
ok "promtool: FleetProductionStale fires on the 0509 stale state, silent on green and on merge-free staleness; tripwire fires on nonzero"

echo
echo "all fleet-production-stale-alert tests passed"
