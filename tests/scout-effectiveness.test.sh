#!/usr/bin/env bash
# tests/scout-effectiveness.test.sh
#
# fleet-ops#2756: scout effectiveness metric family. Offline (no live
# prometheus, no live gh). Hosted by tests/ci-standards-audit.test.sh so
# P14 runs it without a workflow-file edit.
#
# Proves:
#   1. compute_stats: filed -> survive_intake -> agent_ready -> claimed ->
#      merged_14d pipeline attribution is correct, including
#      dupe-closed-within-1h exclusion from survive_intake and the
#      agent-in-progress claimed gate (fleet-ops#3123).
#   2. effectiveness_ratio = merged_14d / runs (0 when no runs).
#   3. Empty window still emits fleet_scout_effectiveness_last_run_seconds
#      (organ heartbeat) + per-repo zeros including effectiveness_ratio.
#   4. Fixture with a productive scout (3 runs, 2 merged) -> ratio 0.6667;
#      a futile scout (3 runs, 0 merged) -> ratio 0.0.
#   5. main() end-to-end (env seams only) writes a promtool-valid textfile
#      carrying the issue's exact metric names + labels, HELP/TYPE once each.
#   6. MANIFEST installs the helper + the exporter drop-in (no new timer).
#   7. fleet_rules.yml ships FleetScoutEffectivenessAbsent +
#      ScoutEffectivenessLow.
#   8. config/fleet-organs.json registers the organ with the absent alert.
#   9. promtool check rules (if present).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
helper="$repo_root/lib/scout-effectiveness.py"
rules="$repo_root/config/fleet_rules.yml"
manifest="$repo_root/MANIFEST"
dropin="$repo_root/systemd/fleet-metrics-export.service.d/scout-effectiveness.conf"
organs="$repo_root/config/fleet-organs.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$helper" ]] || fail "missing $helper"
[[ -f "$rules" ]] || fail "missing $rules"
[[ -f "$dropin" ]] || fail "missing $dropin"
[[ -f "$organs" ]] || fail "missing $organs"
command -v python3 >/dev/null 2>&1 || fail "python3 required"
command -v jq >/dev/null 2>&1 || fail "jq required"

scratch="$(mktemp -d -t scout-eff-test.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Window: 2026-09-02T12:00:00Z, 14d back.
END_TS=1788350400       # 2026-09-02T12:00:00Z
START_TS=$((END_TS - 14 * 86400))

# =========================================================================
# 1. compute_stats pipeline attribution
# =========================================================================
python3 - "$helper" <<'PY' || fail "compute_stats pipeline failed"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("se", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.modules["se"] = m
spec.loader.exec_module(m)

START = 1788350400 - 14 * 86400
END = 1788350400

# 3 runs inside the window.
runs = [START + 100, START + 200, START + 300]

issues = [
    # filed, not dupe, agent-ready, claimed, merged within 14d -> merged_14d=1
    m.ScoutIssue(number=1, repo="0509", created_ts=START + 150,
                 labels=("scout-candidate", "agent-ready", "agent-in-progress"),
                 state="closed", state_reason="completed",
                 closed_ts=START + 5000, merged_ts=START + 8000),
    # filed, closed as duplicate within 1h -> NOT survive_intake
    m.ScoutIssue(number=2, repo="0509", created_ts=START + 250,
                 labels=("scout-candidate",),
                 state="closed", state_reason="duplicate",
                 closed_ts=START + 250 + 1800),  # 30min < 1h
    # filed, closed as duplicate AFTER 1h -> still survive_intake
    m.ScoutIssue(number=3, repo="0509", created_ts=START + 350,
                 labels=("scout-candidate",),
                 state="closed", state_reason="duplicate",
                 closed_ts=START + 350 + 7200),  # 2h > 1h
    # filed, agent-ready, never merged -> agent_ready but not merged_14d
    m.ScoutIssue(number=4, repo="0509", created_ts=START + 450,
                 labels=("scout-candidate", "agent-ready"),
                 state="open", state_reason=""),
    # filed outside the window -> excluded from filed
    m.ScoutIssue(number=5, repo="0509", created_ts=START - 100,
                 labels=("scout-candidate", "agent-ready"),
                 state="open", state_reason=""),
    # merged AFTER 14d window of creation -> not merged_14d
    m.ScoutIssue(number=6, repo="0509", created_ts=START + 600,
                 labels=("scout-candidate",),
                 state="closed", state_reason="completed",
                 closed_ts=START + 600 + 15 * 86400,
                 merged_ts=START + 600 + 15 * 86400),
]

s = m.compute_stats("0509", runs, issues,
                    start_ts=START, end_ts=END,
                    dupe_hours=1, merge_days=14)
assert s.runs == 3, s.runs
# Inside window = 1,2,3,4,6 (5 is outside) => 5 filed
assert s.filed == 5, f"filed={s.filed}"
assert s.survive_intake == 4, f"survive={s.survive_intake}"  # all except #2 (dupe <1h)
assert s.agent_ready == 2, f"agent_ready={s.agent_ready}"  # #1, #4 (5 excluded)
assert s.claimed == 1, f"claimed={s.claimed}"  # only #1 carries agent-in-progress
assert s.merged_14d == 1, f"merged_14d={s.merged_14d}"  # only #1 (#6 merged >14d)
assert abs(s.effectiveness_ratio - 1 / 3) < 1e-9, s.effectiveness_ratio
print("OK: compute_stats pipeline attribution")
PY
ok "compute_stats: filed -> survive_intake -> agent_ready -> merged_14d pipeline"

# =========================================================================
# 1b. count_finished_runs: systemd Finished only (fleet-ops#3170)
#     ExecStartPre begin / Failed to start / no-seat must NOT count.
#     Live: 220 last_run changes vs 50 Finished / 155 Failed to start.
# =========================================================================
python3 - "$helper" <<'PY' || fail "count_finished_runs failed"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("se", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.modules["se"] = m
spec.loader.exec_module(m)

journal = """\
Sep 04 12:23:07 systemd[1038]: Failed to start pi-scout@0509.service - Pi fleet product scout
Sep 04 12:23:06 bash[1]: pi-scout-run: 0509/scout no healthy seat available
Sep 04 14:01:05 systemd[1038]: Finished pi-scout@0509.service - Pi fleet product scout
Sep 04 16:00:00 systemd[1038]: Finished pi-scout@fleet-ops.service - Pi fleet product scout
Sep 04 18:00:00 systemd[1038]: Finished pi-scout@0509.service - another success
Sep 04 18:00:01 systemd[1038]: Starting pi-scout@0509.service - must not count
"""
n = m.count_finished_runs(journal, "0509")
assert n == 2, n  # two Finished @0509; fleet-ops Finished + Failed + no-seat + Starting excluded
assert m.count_finished_runs(journal, "fleet-ops") == 1
assert m.count_finished_runs("", "0509") == 0
print("OK: count_finished_runs ignores Failed/no-seat/other-repo")
PY
ok "count_finished_runs: Finished only, not begins or no-seat failures"

# =========================================================================
# 1c. merge_issues: promoted issues that dropped scout-candidate still count
#     (pi-audit-tally removes scout-candidate when adding agent-ready).
# =========================================================================
python3 - "$helper" <<'PY' || fail "merge_issues failed"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("se", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.modules["se"] = m
spec.loader.exec_module(m)

START = 1788350400 - 14 * 86400
still_candidate = m.ScoutIssue(
    number=10, repo="0509", created_ts=START + 100,
    labels=("scout-candidate",), state="open")
promoted = m.ScoutIssue(
    number=11, repo="0509", created_ts=START + 200,
    labels=("agent-ready",), state="open")  # scout-candidate already dropped
claimed = m.ScoutIssue(
    number=12, repo="0509", created_ts=START + 300,
    labels=("agent-in-progress",), state="closed",
    merged_ts=START + 4000)
# same number from two label lists -> union labels, not double-count
dual_a = m.ScoutIssue(
    number=13, repo="0509", created_ts=START + 400,
    labels=("scout-candidate",), state="open")
dual_b = m.ScoutIssue(
    number=13, repo="0509", created_ts=START + 400,
    labels=("agent-ready", "scout-candidate"), state="open")

merged = m.merge_issues([
    [still_candidate, dual_a],
    [promoted, dual_b],
    [claimed],
])
nums = sorted(i.number for i in merged)
assert nums == [10, 11, 12, 13], nums
by = {i.number: i for i in merged}
assert "agent-ready" in by[13].labels and "scout-candidate" in by[13].labels
assert by[11].labels == ("agent-ready",)
print("OK: merge_issues unions labels and dedupes by number")
PY
ok "merge_issues: promoted-without-scout-candidate still in the cohort"

# =========================================================================
# 2. effectiveness_ratio = 0 when no runs
# =========================================================================
python3 - "$helper" <<'PY' || fail "zero-runs ratio failed"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("se", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.modules["se"] = m
spec.loader.exec_module(m)
START = 1788350400 - 14 * 86400
END = 1788350400
s = m.compute_stats("0509", [], [], start_ts=START, end_ts=END)
assert s.runs == 0
assert s.effectiveness_ratio == 0.0
print("OK: zero runs -> ratio 0")
PY
ok "effectiveness_ratio = 0 when no runs"

# =========================================================================
# 3. Empty window end-to-end: heartbeat + per-repo zeros
# =========================================================================
export FLEET_SCOUT_EFF_NOW="2026-09-02T12:00:00Z"
export FLEET_SCOUT_EFF_FIXTURE="$scratch/empty.json"
export FLEET_SCOUT_EFF_OUT="$scratch/empty.prom"
printf '%s\n' '{"runs":[],"issues":[]}' >"$FLEET_SCOUT_EFF_FIXTURE"
python3 "$helper" --stdout >"$scratch/empty.stdout" \
  || fail "empty export rc nonzero"
grep -q '^fleet_scout_effectiveness_last_run_seconds 1788350400$' "$FLEET_SCOUT_EFF_OUT" \
  || fail "heartbeat epoch wrong: $(grep fleet_scout_effectiveness_last_run_seconds "$FLEET_SCOUT_EFF_OUT" || echo missing)"
grep -q 'fleet_scout_effectiveness_ratio{repo="0509"} 0.000000' "$FLEET_SCOUT_EFF_OUT" \
  || fail "empty window must emit ratio 0 for 0509"
grep -q 'fleet_scout_runs_total{repo="0509"} 0' "$FLEET_SCOUT_EFF_OUT" \
  || fail "empty window must emit runs=0"
grep -q 'fleet_scout_issues_filed{repo="0509"} 0' "$FLEET_SCOUT_EFF_OUT" \
  || fail "empty window must emit filed=0"
grep -q 'fleet_scout_issues_survive_intake{repo="0509"} 0' "$FLEET_SCOUT_EFF_OUT" \
  || fail "empty window must emit survive_intake=0"
grep -q 'fleet_scout_issues_agent_ready{repo="0509"} 0' "$FLEET_SCOUT_EFF_OUT" \
  || fail "empty window must emit agent_ready=0"
grep -q 'fleet_scout_issues_claimed{repo="0509"} 0' "$FLEET_SCOUT_EFF_OUT" \
  || fail "empty window must emit claimed=0"
grep -q 'fleet_scout_issues_merged_14d{repo="0509"} 0' "$FLEET_SCOUT_EFF_OUT" \
  || fail "empty window must emit merged_14d=0"
ok "empty window emits heartbeat + per-repo zeros"

# =========================================================================
# 4. Productive vs futile fixture
# =========================================================================
python3 - <<'PY' >"$scratch/fixture.json"
import json
START = 1788350400 - 14 * 86400
END = 1788350400
runs = [START + 100, START + 200, START + 300]
issues = [
    # productive: 2 of 3 filed issues merged within 14d
    {"number": 1, "repo": "0509", "created_ts": START + 150,
     "labels": ["scout-candidate", "agent-ready"], "state": "closed",
     "state_reason": "completed", "closed_ts": START + 5000,
     "merged_ts": START + 8000},
    {"number": 2, "repo": "0509", "created_ts": START + 250,
     "labels": ["scout-candidate", "agent-ready"], "state": "closed",
     "state_reason": "completed", "closed_ts": START + 6000,
     "merged_ts": START + 9000},
    {"number": 3, "repo": "0509", "created_ts": START + 350,
     "labels": ["scout-candidate"], "state": "open", "state_reason": ""},
]
print(json.dumps({"runs": runs, "issues": issues}))
PY
export FLEET_SCOUT_EFF_FIXTURE="$scratch/fixture.json"
export FLEET_SCOUT_EFF_OUT="$scratch/fixture.prom"
python3 "$helper" --stdout >"$scratch/fixture.stdout" \
  || fail "fixture export rc nonzero"
grep -q 'fleet_scout_runs_total{repo="0509"} 3' "$FLEET_SCOUT_EFF_OUT" \
  || fail "runs should be 3"
grep -q 'fleet_scout_issues_filed{repo="0509"} 3' "$FLEET_SCOUT_EFF_OUT" \
  || fail "filed should be 3"
grep -q 'fleet_scout_issues_merged_14d{repo="0509"} 2' "$FLEET_SCOUT_EFF_OUT" \
  || fail "merged_14d should be 2"
grep -q 'fleet_scout_effectiveness_ratio{repo="0509"} 0.666667' "$FLEET_SCOUT_EFF_OUT" \
  || fail "ratio should be 0.666667: $(grep effectiveness_ratio "$FLEET_SCOUT_EFF_OUT")"
ok "productive fixture: 3 runs, 2 merged -> ratio 0.6667"

# futile: 3 runs, 0 merged
python3 - <<'PY' >"$scratch/futile.json"
import json
START = 1788350400 - 14 * 86400
runs = [START + 100, START + 200, START + 300]
issues = [
    {"number": 10, "repo": "0509", "created_ts": START + 150,
     "labels": ["scout-candidate"], "state": "open", "state_reason": ""},
    {"number": 11, "repo": "0509", "created_ts": START + 250,
     "labels": ["scout-candidate"], "state": "closed",
     "state_reason": "duplicate", "closed_ts": START + 250 + 600},
]
print(json.dumps({"runs": runs, "issues": issues}))
PY
export FLEET_SCOUT_EFF_FIXTURE="$scratch/futile.json"
export FLEET_SCOUT_EFF_OUT="$scratch/futile.prom"
python3 "$helper" --stdout >"$scratch/futile.stdout" \
  || fail "futile export rc nonzero"
grep -q 'fleet_scout_runs_total{repo="0509"} 3' "$FLEET_SCOUT_EFF_OUT" \
  || fail "futile runs should be 3"
grep -q 'fleet_scout_issues_merged_14d{repo="0509"} 0' "$FLEET_SCOUT_EFF_OUT" \
  || fail "futile merged_14d should be 0"
grep -q 'fleet_scout_effectiveness_ratio{repo="0509"} 0.000000' "$FLEET_SCOUT_EFF_OUT" \
  || fail "futile ratio should be 0"
grep -q 'fleet_scout_issues_survive_intake{repo="0509"} 1' "$FLEET_SCOUT_EFF_OUT" \
  || fail "futile survive_intake should be 1 (#10 survives, #11 duped <1h)"
ok "futile fixture: 3 runs, 0 merged, 1 duped -> ratio 0.0"

# =========================================================================
# 5. promtool-valid textfile + HELP/TYPE once each
# =========================================================================
export FLEET_SCOUT_EFF_FIXTURE="$scratch/fixture.json"
export FLEET_SCOUT_EFF_OUT="$scratch/prom.prom"
python3 "$helper" --stdout >"$scratch/prom.stdout" || fail "export rc nonzero"
# Every metric has exactly one HELP and one TYPE.
for metric in fleet_scout_runs_total fleet_scout_issues_filed \
              fleet_scout_issues_survive_intake fleet_scout_issues_agent_ready \
              fleet_scout_issues_claimed fleet_scout_issues_merged_14d \
              fleet_scout_effectiveness_ratio \
              fleet_scout_effectiveness_last_run_seconds; do
  help_count=$(grep -c "^# HELP $metric " "$FLEET_SCOUT_EFF_OUT" || true)
  type_count=$(grep -c "^# TYPE $metric " "$FLEET_SCOUT_EFF_OUT" || true)
  [[ "$help_count" -eq 1 ]] || fail "$metric HELP count=$help_count"
  [[ "$type_count" -eq 1 ]] || fail "$metric TYPE count=$type_count"
done
ok "textfile: HELP/TYPE once each for every metric"

# =========================================================================
# 6. MANIFEST + drop-in + no new timer
# =========================================================================
grep -Fxq "lib/scout-effectiveness.py /home/nish/.local/lib/pi-packet/scout-effectiveness.py" "$manifest" \
  || fail "MANIFEST missing lib/scout-effectiveness.py dest"
grep -Fxq "systemd/fleet-metrics-export.service.d/scout-effectiveness.conf /home/nish/.config/systemd/user/fleet-metrics-export.service.d/scout-effectiveness.conf" "$manifest" \
  || fail "MANIFEST missing scout-effectiveness drop-in"
grep -q "ExecStart=-/bin/bash -c 'exec /usr/bin/python3 /home/nish/.local/lib/pi-packet/scout-effectiveness.py'" "$dropin" \
  || fail "drop-in must ExecStart=- the helper under ~/.local/lib/pi-packet/"
[[ ! -f "$repo_root/systemd/scout-effectiveness.timer" ]] \
  || fail "must not add a new timer; piggyback fleet-metrics-export"
[[ ! -f "$repo_root/systemd/scout-effectiveness.service" ]] \
  || fail "must not add a new service; piggyback fleet-metrics-export"
ok "MANIFEST + drop-in wiring; no new timer"

# =========================================================================
# 7. Rules + organ registry
# =========================================================================
grep -q 'alert: FleetScoutEffectivenessAbsent' "$rules" \
  || fail "rules missing FleetScoutEffectivenessAbsent"
grep -q 'absent(fleet_scout_effectiveness_last_run_seconds)' "$rules" \
  || fail "Absent rule must watch fleet_scout_effectiveness_last_run_seconds"
grep -q 'alert: ScoutEffectivenessLow' "$rules" \
  || fail "rules missing ScoutEffectivenessLow"
grep -q 'fleet_scout_effectiveness_ratio < 0.1 and fleet_scout_runs_total > 0' "$rules" \
  || fail "ScoutEffectivenessLow must gate on ratio < 0.1 (no repo label, covers 0509 + fleet-ops)"

jq -e '.organs[] | select(.name=="scout-effectiveness")
  | select(.heartbeat_metric=="fleet_scout_effectiveness_last_run_seconds")
  | select(.absent_alert=="FleetScoutEffectivenessAbsent")' "$organs" >/dev/null \
  || fail "fleet-organs.json missing scout-effectiveness organ"
ok "rules + organ registry"

# =========================================================================
# 8. promtool (optional)
# =========================================================================
if command -v promtool >/dev/null 2>&1; then
  promtool check rules "$rules" >/dev/null \
    || fail "promtool check rules failed"
  ok "promtool check rules"
else
  echo "SKIP: promtool not on PATH"
fi

echo "OK: scout-effectiveness: pipeline attribution, empty heartbeat, productive/futile fixtures, MANIFEST, rules, organ registry"
