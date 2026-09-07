#!/usr/bin/env bash
# tests/fleet-duty-officer-recording.test.sh
#
# fleet-ops#4394: the hourly judge prompt cites three PromQL names from
# recording group fleet_duty_officer_recording. Two of those series went
# silently null because count() of an empty vector is absent, not 0.
#
# Proves, offline:
#   1. Every backtick-cited fleet_* name in the recording-group comments
#      (the in-repo judge-prompt contract) resolves to a record: rule in
#      config/fleet_rules.yml or a # HELP line in the exporter.
#   2. Each duty-officer recording expr uses `or vector(0)` so a zero count
#      is an explicit 0, never absent.
#   3. fleet_failed_units is sourced from node_systemd_unit_state{state="failed"}.
#   4. promtool check rules on the real file.
#   5. promtool unit test: no failed units -> 0; one failed unit -> 1.
#
# Hosted from tests/ci-standards-audit.test.sh (already in ci.yml) because
# the worker App cannot push .github/workflows/**.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

rules="$repo_root/config/fleet_rules.yml"
exporter="$repo_root/libexec/fleet-metrics-export.py"
[[ -f "$rules" ]] || fail "missing $rules"
[[ -f "$exporter" ]] || fail "missing $exporter"

scratch="$(mktemp -d -t duty-rec.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

python3 - "$rules" "$exporter" "$scratch" <<'PY' || fail "citation/expr pin failed"
import re, sys, pathlib, yaml

rules_path, exporter_path, scratch = sys.argv[1], sys.argv[2], sys.argv[3]
text = pathlib.Path(rules_path).read_text()
data = yaml.safe_load(text)
groups = {g["name"]: g for g in data["groups"]}
if "fleet_duty_officer_recording" not in groups:
    print("FAIL: missing group fleet_duty_officer_recording", file=sys.stderr)
    sys.exit(1)
group = groups["fleet_duty_officer_recording"]
records = {}
for rule in group["rules"]:
    name = rule.get("record")
    if not name:
        print(f"FAIL: non-recording rule in duty-officer group: {rule}", file=sys.stderr)
        sys.exit(1)
    expr = " ".join(str(rule.get("expr", "")).split())
    records[name] = expr

# In-repo judge-prompt contract: backtick fleet_* names in this group's
# comment block (the fable-check.md §1c citations). Slice from the group
# header to the next top-level group so a rename in the prompt comments
# fails here instead of going silently null.
idx = text.find("  - name: fleet_duty_officer_recording")
if idx < 0:
    print("FAIL: could not slice duty-officer group text", file=sys.stderr)
    sys.exit(1)
rest = text[idx + 1 :]
nxt = re.search(r"\n  - name: ", rest)
block = rest[: nxt.start()] if nxt else rest
cited = re.findall(r"`(fleet_[a-z0-9_]+)`", block)
if not cited:
    print("FAIL: no backtick fleet_* citations in duty-officer group comments", file=sys.stderr)
    sys.exit(1)

help_names = set(re.findall(r"# HELP (fleet_[a-z0-9_]+) ", pathlib.Path(exporter_path).read_text()))
unresolved = []
for name in cited:
    if name in records:
        continue
    if name in help_names:
        continue
    unresolved.append(name)
if unresolved:
    print(
        "FAIL: judge-cited metrics with no recording rule and no exporter HELP: "
        + ", ".join(unresolved),
        file=sys.stderr,
    )
    sys.exit(1)

required = (
    "fleet_failed_units",
    "fleet_seat_unhealthy_count",
    "fleet_workers_active",
)
for name in required:
    if name not in cited:
        print(f"FAIL: judge citation missing {name}", file=sys.stderr)
        sys.exit(1)
    if name not in records:
        print(f"FAIL: recording rule missing {name}", file=sys.stderr)
        sys.exit(1)
    if "or vector(0)" not in records[name]:
        print(f"FAIL: {name} expr must use `or vector(0)` so zero is never absent: {records[name]}", file=sys.stderr)
        sys.exit(1)

failed_expr = records["fleet_failed_units"]
if 'node_systemd_unit_state{state="failed"}' not in failed_expr:
    print(f"FAIL: fleet_failed_units must count node_systemd_unit_state failed==1: {failed_expr}", file=sys.stderr)
    sys.exit(1)

workers_expr = records["fleet_workers_active"]
if not workers_expr.startswith("sum(fleet_pi_workers_active"):
    print(
        "FAIL: fleet_workers_active must sum() before `or vector(0)` so a live series "
        f"does not dual-emit with unlabeled 0: {workers_expr}",
        file=sys.stderr,
    )
    sys.exit(1)

pathlib.Path(scratch, "failed_expr.txt").write_text(failed_expr + "\n")
print("cited=" + ",".join(cited))
print("records=" + ",".join(records))
print("OK: citations resolve; or vector(0) on all three")
PY
ok "judge-cited metrics resolve to recording rules or exporter HELP"

grep -Fq 'or vector(0)' "$rules" \
  || fail "fleet_rules.yml has no or vector(0) (python pin should have failed first)"

if command -v promtool >/dev/null 2>&1; then
  promtool check rules "$rules" >/dev/null \
    || fail "promtool check rules failed on config/fleet_rules.yml"
  ok "promtool check rules: fleet_rules.yml valid"

  failed_expr="$(tr -d '\n' <"$scratch/failed_expr.txt")"
  cat >"$scratch/duty.yml" <<EOF
groups:
  - name: fleet_duty_officer_recording
    rules:
      - record: fleet_failed_units
        expr: ${failed_expr}
EOF
  cat >"$scratch/zero.test.yml" <<EOF
rule_files:
  - $scratch/duty.yml
evaluation_interval: 1m
tests:
  - interval: 1m
    input_series: []
    promql_expr_test:
      - expr: count(node_systemd_unit_state{state="failed"} == 1) or vector(0)
        eval_time: 1m
        exp_samples:
          - labels: '{}'
            value: 0
EOF
  out0="$(promtool test rules "$scratch/zero.test.yml" 2>&1)" || {
    echo "$out0" >&2
    fail "promtool: zero failed units must evaluate to 0, not absent"
  }
  ok "promtool: zero failed units -> 0"

  cat >"$scratch/one.test.yml" <<EOF
rule_files:
  - $scratch/duty.yml
evaluation_interval: 1m
tests:
  - interval: 1m
    input_series:
      - series: 'node_systemd_unit_state{state="failed",name="x.service"}'
        values: '1 1'
    promql_expr_test:
      - expr: count(node_systemd_unit_state{state="failed"} == 1) or vector(0)
        eval_time: 1m
        exp_samples:
          - labels: '{}'
            value: 1
EOF
  out1="$(promtool test rules "$scratch/one.test.yml" 2>&1)" || {
    echo "$out1" >&2
    fail "promtool: one failed unit must evaluate to 1"
  }
  ok "promtool: one failed unit -> 1"
else
  echo "SKIP: promtool not installed; skipped check rules + unit tests"
fi

echo "OK: fleet-duty-officer-recording: judge citations resolve; zero is 0"
