#!/usr/bin/env bash
# tests/fleet-rules-escalation-storm.test.sh
#
# fleet-ops#3368: the FleetEscalationStorm alert must name its dominant
# producer so a recurrence is actionable without a manual journal dig.
#
# Proves, offline:
#   1. config/fleet_rules.yml's FleetEscalationStorm rule ANDs the
#      total-greater-than-threshold gate with topk(1, fleet_escalations_24h)
#      so the firing vector carries the dominant producer's `unit` label.
#   2. The summary/description reference {{ $labels.unit }} to name it.
#   3. When promtool is available, a rule-unit test asserts the alert fires
#      with the top producer's unit label (and its count as $value), and
#      does NOT fire when total < 300 even if a single unit is large.
#
# promtool is not on every host; when it is absent the text-level assertions
# (1, 2) still run and the promtool sections skip cleanly.
#
# Robustness note: this file greps the config directly (grep -Fq <file>).
# `echo "$bigvar" | grep -q` under `set -o pipefail` fails with SIGPIPE (141)
# because -q closes the pipe on first match, so it is avoided here.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

rules="$repo_root/config/fleet_rules.yml"
[[ -f "$rules" ]] || fail "missing $rules"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# --- 1. rule present; expr ANDs the total gate with topk(1,...) ---
grep -Fq 'alert: FleetEscalationStorm' "$rules" \
  || fail "FleetEscalationStorm rule not found"
grep -Fq 'expr: topk(1, fleet_escalations_24h) and on() (sum(fleet_escalations_24h) > 300)' "$rules" \
  || fail "expr must gate on the total (sum > 300) AND carry the dominant producer (topk(1))"

# --- 2. annotations name the producer ---
grep -Fq 'dominant producer {{ $labels.unit }}' "$rules" \
  || fail "summary must name {{ $labels.unit }}"
grep -Fq 'top producer {{ $labels.unit }}={{$value}}' "$rules" \
  || fail "description must name {{ $labels.unit }} and {{ $value }}"
ok "rule text: expr + annotations name the dominant producer"

# --- 3. promtool rule-unit test (skip cleanly when promtool absent) ---
if ! command -v promtool >/dev/null 2>&1; then
  echo "SKIP: promtool not installed; skipped rule-unit semantic test"
else
  rule_file="$scratch/fleet_rules_esc.yml"
  cat > "$rule_file" <<'RULE'
groups:
  - name: fleet_self_observation
    rules:
      - alert: FleetEscalationStorm
        expr: topk(1, fleet_escalations_24h) and on() (sum(fleet_escalations_24h) > 300)
        for: 0m
        labels:
          severity: warning
          service: fleet
        annotations:
          summary: "escalation volume abnormal; dominant producer {{ $labels.unit }}"
          description: "sum(fleet_escalations_24h) > 300 for 30m; top producer {{ $labels.unit }}={{$value}}."
RULE

  # Positive: total > 300 fires and names the top producer.
  cat > "$scratch/pos.test.yml" <<EOF
rule_files:
  - $rule_file
evaluation_interval: 1m
tests:
  - interval: 1m
    input_series:
      - series: 'fleet_escalations_24h{unit="pi-issue@fleet-ops-123"}'
        values: '0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 900'
      - series: 'fleet_escalations_24h{unit="fleet-heartbeat"}'
        values: '0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 100'
      - series: 'fleet_escalations_24h{unit="pi-intake@0509"}'
        values: '0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 50'
      - series: 'fleet_escalations_24h{unit="low-producer"}'
        values: '0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 20'
    alert_rule_test:
      - eval_time: 32m
        alertname: FleetEscalationStorm
        exp_alerts:
          - exp_labels:
              severity: warning
              service: fleet
              unit: pi-issue@fleet-ops-123
            exp_annotations:
              summary: "escalation volume abnormal; dominant producer pi-issue@fleet-ops-123"
              description: "sum(fleet_escalations_24h) > 300 for 30m; top producer pi-issue@fleet-ops-123=900."
EOF
  promtool test rules "$scratch/pos.test.yml" >/dev/null 2>&1 \
    || fail "promtool positive: alert must fire naming top producer unit"

  # Negative: total <= 300 must not fire even with one large unit.
  cat > "$scratch/neg.test.yml" <<EOF
rule_files:
  - $rule_file
evaluation_interval: 1m
tests:
  - interval: 1m
    input_series:
      - series: 'fleet_escalations_24h{unit="pi-issue@fleet-ops-123"}'
        values: '0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 250'
      - series: 'fleet_escalations_24h{unit="fleet-heartbeat"}'
        values: '0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 30'
    alert_rule_test:
      - eval_time: 32m
        alertname: FleetEscalationStorm
        exp_alerts: []
EOF
  promtool test rules "$scratch/neg.test.yml" >/dev/null 2>&1 \
    || fail "promtool negative: total <= 300 must not fire"
  ok "promtool: dominant-producer naming + total-gate semantics"
fi

echo "OK: fleet-rules-escalation-storm: rule names dominant producer"
