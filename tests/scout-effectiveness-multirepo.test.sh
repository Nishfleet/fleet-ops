#!/usr/bin/env bash
# tests/scout-effectiveness-multirepo.test.sh
#
# fleet-ops#3152: scout-effectiveness.py must measure the fleet-ops
# control-plane scout yield, not just 0509. The exporter was hardcoded to
# repo=0509 (FLEET_SCOUT_EFF_REPO default), so the fleet-ops scout's filed
# issues (labelled agent-ready, not scout-candidate) were invisible to the
# whole effectiveness pipeline — no runs metric, no merge-rate metric, no
# ScoutEffectivenessLow alert. This test pins the multi-repo behaviour.
#
# Proves:
#   1. FLEET_SCOUT_EFF_REPOS (comma-separated) wins; default falls back to
#      the enrolled scout repos from config/intake-repos.json (0509 +
#      fleet-ops), so a newly-scouted repo is covered without editing the
#      exporter.
#   2. The exporter emits the full metric family for BOTH 0509 and
#      fleet-ops, attributing each repo's issues by its filed label
#      (0509 -> scout-candidate, fleet-ops -> agent-ready).
#   3. An enrolled scout repo with no metric emits a LOUD alert
#      (fleet_scout_effectiveness_uncovered_repo{repo=...} 1 + stderr
#      warning) instead of silent absence.
#   4. config/fleet_rules.yml ScoutEffectivenessLow covers fleet-ops (no
#      repo label, so it fires for any enrolled scout repo).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
helper="$repo_root/lib/scout-effectiveness.py"
rules="$repo_root/config/fleet_rules.yml"
intake="$repo_root/config/intake-repos.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$helper" ]] || fail "missing $helper"
[[ -f "$rules" ]] || fail "missing $rules"
[[ -f "$intake" ]] || fail "missing $intake"
command -v python3 >/dev/null 2>&1 || fail "python3 required"
command -v jq >/dev/null 2>&1 || fail "jq required"

scratch="$(mktemp -d -t scout-eff-multi.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# =========================================================================
# 1. resolve_repos: FLEET_SCOUT_EFF_REPOS wins; default = enrolled repos
# =========================================================================
python3 - "$helper" <<'PY' || fail "resolve_repos failed"
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("se", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.modules["se"] = m
spec.loader.exec_module(m)

# Default: enrolled scout repos from config/intake-repos.json.
os.environ.pop("FLEET_SCOUT_EFF_REPOS", None)
default = m.resolve_repos()
assert "0509" in default, f"default must include 0509: {default}"
assert "fleet-ops" in default, f"default must include fleet-ops: {default}"

# Explicit comma-separated list wins.
os.environ["FLEET_SCOUT_EFF_REPOS"] = "0509,fleet-ops"
assert m.resolve_repos() == ["0509", "fleet-ops"], m.resolve_repos()
os.environ["FLEET_SCOUT_EFF_REPOS"] = "fleet-ops"
assert m.resolve_repos() == ["fleet-ops"], m.resolve_repos()

# Per-repo filed labels: 0509 by scout-candidate, fleet-ops by agent-ready.
assert m.FILED_LABELS["0509"] == "scout-candidate"
assert m.FILED_LABELS["fleet-ops"] == "agent-ready"
print("OK: resolve_repos default + override; filed labels")
PY
ok "resolve_repos: FLEET_SCOUT_EFF_REPOS wins, default = enrolled repos"

# =========================================================================
# 2. Offline fixture: both repos computed, attributed by filed label
# =========================================================================
python3 - <<'PY' >"$scratch/both.json"
import json
END = 1788350400       # 2026-09-02T12:00:00Z
START = END - 14 * 86400
runs = [START + 100, START + 200, START + 300]
issues = [
    # 0509: filed by scout-candidate, merged within 14d
    {"number": 1, "repo": "0509", "created_ts": START + 150,
     "labels": ["scout-candidate", "agent-ready"], "state": "closed",
     "state_reason": "completed", "closed_ts": START + 5000,
     "merged_ts": START + 8000},
    # 0509: filed by scout-candidate, never merged
    {"number": 2, "repo": "0509", "created_ts": START + 250,
     "labels": ["scout-candidate"], "state": "open", "state_reason": ""},
    # fleet-ops: filed by agent-ready (control-plane scout), merged within 14d
    {"number": 10, "repo": "fleet-ops", "created_ts": START + 300,
     "labels": ["agent-ready", "agent-in-progress"], "state": "closed",
     "state_reason": "completed", "closed_ts": START + 6000,
     "merged_ts": START + 9000},
    # fleet-ops: filed by agent-ready, never merged
    {"number": 11, "repo": "fleet-ops", "created_ts": START + 400,
     "labels": ["agent-ready"], "state": "open", "state_reason": ""},
]
print(json.dumps({"runs": runs, "issues": issues}))
PY
export FLEET_SCOUT_EFF_NOW="2026-09-02T12:00:00Z"
export FLEET_SCOUT_EFF_FIXTURE="$scratch/both.json"
export FLEET_SCOUT_EFF_OUT="$scratch/both.prom"
export FLEET_SCOUT_EFF_REPOS="0509,fleet-ops"
python3 "$helper" --stdout >"$scratch/both.stdout" \
  || fail "both-repo export rc nonzero"

# 0509: 3 runs, 2 filed, 1 merged -> ratio 0.333333
grep -q 'fleet_scout_runs_total{repo="0509"} 3' "$FLEET_SCOUT_EFF_OUT" \
  || fail "0509 runs should be 3"
grep -q 'fleet_scout_issues_filed{repo="0509"} 2' "$FLEET_SCOUT_EFF_OUT" \
  || fail "0509 filed should be 2"
grep -q 'fleet_scout_issues_merged_14d{repo="0509"} 1' "$FLEET_SCOUT_EFF_OUT" \
  || fail "0509 merged_14d should be 1"
grep -q 'fleet_scout_effectiveness_ratio{repo="0509"} 0.333333' "$FLEET_SCOUT_EFF_OUT" \
  || fail "0509 ratio should be 0.333333"

# fleet-ops: 3 runs, 2 filed, 1 merged -> ratio 0.333333
grep -q 'fleet_scout_runs_total{repo="fleet-ops"} 3' "$FLEET_SCOUT_EFF_OUT" \
  || fail "fleet-ops runs should be 3"
grep -q 'fleet_scout_issues_filed{repo="fleet-ops"} 2' "$FLEET_SCOUT_EFF_OUT" \
  || fail "fleet-ops filed should be 2"
grep -q 'fleet_scout_issues_agent_ready{repo="fleet-ops"} 2' "$FLEET_SCOUT_EFF_OUT" \
  || fail "fleet-ops agent_ready should be 2"
grep -q 'fleet_scout_issues_merged_14d{repo="fleet-ops"} 1' "$FLEET_SCOUT_EFF_OUT" \
  || fail "fleet-ops merged_14d should be 1"
grep -q 'fleet_scout_effectiveness_ratio{repo="fleet-ops"} 0.333333' "$FLEET_SCOUT_EFF_OUT" \
  || fail "fleet-ops ratio should be 0.333333"

# No uncovered alert when both enrolled repos are covered.
grep -q 'fleet_scout_effectiveness_uncovered_repo' "$FLEET_SCOUT_EFF_OUT" \
  && fail "no uncovered alert expected when both repos covered"
ok "both repos computed + attributed by filed label; no false uncovered alert"

# =========================================================================
# 3. Uncovered-repo loud alert: an enrolled repo with no metric is loud
# =========================================================================
# Fixture intake-repos.json with an extra enrolled repo (newrepo) that the
# export does NOT cover (FLEET_SCOUT_EFF_REPOS omits it).
cat >"$scratch/intake.json" <<'JSON'
{
  "repos": [
    {"name": "0509"},
    {"name": "fleet-ops"},
    {"name": "newrepo"}
  ]
}
JSON
export FLEET_SCOUT_EFF_INTAKE="$scratch/intake.json"
export FLEET_SCOUT_EFF_REPOS="0509,fleet-ops"
export FLEET_SCOUT_EFF_OUT="$scratch/uncovered.prom"
python3 "$helper" --stdout >"$scratch/uncovered.stdout" 2>"$scratch/uncovered.err" \
  || fail "uncovered export rc nonzero"

grep -q 'fleet_scout_effectiveness_uncovered_repo{repo="newrepo"} 1' "$FLEET_SCOUT_EFF_OUT" \
  || fail "uncovered metric missing for newrepo"
grep -qi 'LOUD ALERT' "$scratch/uncovered.err" \
  || fail "stderr must carry a LOUD ALERT for the uncovered repo"
grep -q 'newrepo' "$scratch/uncovered.err" \
  || fail "stderr LOUD ALERT must name the uncovered repo"
# The covered repos still emit their metrics.
grep -q 'fleet_scout_runs_total{repo="0509"}' "$FLEET_SCOUT_EFF_OUT" \
  || fail "0509 metric missing in uncovered export"
grep -q 'fleet_scout_runs_total{repo="fleet-ops"}' "$FLEET_SCOUT_EFF_OUT" \
  || fail "fleet-ops metric missing in uncovered export"
ok "enrolled repo without a metric emits a loud alert, not silent absence"

# =========================================================================
# 4. fleet_rules.yml ScoutEffectivenessLow covers fleet-ops (no repo label)
# =========================================================================
grep -q 'alert: ScoutEffectivenessLow' "$rules" \
  || fail "rules missing ScoutEffectivenessLow"
grep -q 'fleet_scout_effectiveness_ratio < 0.1 and fleet_scout_runs_total > 0' "$rules" \
  || fail "ScoutEffectivenessLow must gate on ratio < 0.1 with no repo label"
# The rule must NOT be hardcoded to repo=0509 (that would leave fleet-ops
# unprotected).
grep -q 'fleet_scout_effectiveness_ratio{repo="0509"} < 0.1' "$rules" \
  && fail "ScoutEffectivenessLow must not be hardcoded to repo=0509"
ok "fleet_rules.yml ScoutEffectivenessLow covers fleet-ops"

# =========================================================================
# 5. promtool (optional)
# =========================================================================
if command -v promtool >/dev/null 2>&1; then
  promtool check rules "$rules" >/dev/null \
    || fail "promtool check rules failed"
  ok "promtool check rules"
else
  echo "SKIP: promtool not on PATH"
fi

echo "OK: scout-effectiveness-multirepo: both repos computed, filed-label attribution, uncovered-repo loud alert, fleet-ops rule"
