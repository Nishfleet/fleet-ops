#!/usr/bin/env bash
# tests/fleet-metrics-export.test.sh
#
# fleet-ops#1136: pin the self-maintenance ratio, upgrade/repair/churn
# classification, queue composition, and verified-merges numerator logic in
# libexec/fleet-metrics-export.py.
#
# Proves, offline (no gh, no prometheus, no systemd):
#   1. The exporter module imports and the new helpers exist.
#   2. _classify_title maps feat->upgrade, fix/test->repair, chore->churn,
#      unclassified/bare->churn (the issue's "to start" heuristic).
#   3. _self_maintenance_and_quality splits self vs product by the config
#      repo set, computes the ratio, and the quality counts + shares.
#   4. total=0 -> ratio and shares are None (omitted), counts are 0 (the
#      kind="total" heartbeat gauge still emits so absent() does not false-fire
#      on a no-merge day).
#   5. config/self-maintenance-repos.json is valid JSON with a non-empty
#      repos array, and the exporter's default fallback is {"Nishfleet/fleet-ops"}
#      when the config is missing.
#   6. _has_delivery_evidence matches lib/exec-review-receipt.py:has_receipt
#      on a corpus of bodies (lock-step with the closure-evidence detector).
#   7. _verified_merges counts verified (non-null diff AND delivery evidence),
#      unverified, total, and the ratio; total=0 -> ratio None.
#   8. config/fleet_rules.yml parses with promtool (if present) and contains
#      the FleetSelfMaintenanceAbsent + regression-trend rules, the
#      FleetVerifiedMergeRegression trend rule, and the
#      FleetQueueSelfMaintenanceRatioHigh 64% tripwire.
#   9. MANIFEST declares the exporter, its timer/service, the self-maintenance
#      config, and the rules file.
#  10. The exporter emits the new metric lines for a canned detail list
#      (end-to-end main() shape check via a stubbed detail fetch), including
#      the verified-merges and queue-composition families.
#  11. fleet-ops#1844/#1855: when BOTH queues emit (agent-ready AND
#      ready-work), main() must write exactly one # HELP and one # TYPE per
#      metric name. The pre-#1855 exporter emitted them inside the per-queue
#      loop, duplicating them; node_exporter's textfile collector REJECTS the
#      whole fleet.prom, so every fleet metric (ready_work, self-maintenance,
#      keystone heartbeat) went absent at once — the 2026-08-29T03:05Z
#      incident that filed #1844. Pin it so the class cannot silently regress.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
exporter="$repo_root/libexec/fleet-metrics-export.py"
receipt="$repo_root/lib/exec-review-receipt.py"
sm_config="$repo_root/config/self-maintenance-repos.json"
rules="$repo_root/config/fleet_rules.yml"
manifest="$repo_root/MANIFEST"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$exporter" ]] || fail "exporter not found: $exporter"
[[ -f "$receipt" ]] || fail "exec-review-receipt not found: $receipt"
[[ -f "$sm_config" ]] || fail "self-maintenance config not found: $sm_config"
[[ -f "$rules" ]] || fail "fleet_rules.yml not found: $rules"
command -v python3 >/dev/null 2>&1 || fail "python3 required"
command -v jq >/dev/null 2>&1 || fail "jq required"

scratch="$(mktemp -d -t fme-test.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# =========================================================================
# 1-5. Classifier + self-maintenance/quality derivation (pure python)
# =========================================================================
SM_CONFIG_OVERRIDE="$scratch/sm.json"
cat >"$SM_CONFIG_OVERRIDE" <<'JSON'
{ "repos": ["fleet-ops", "fleet-ops-deploy"] }
JSON

python3 - "$exporter" "$SM_CONFIG_OVERRIDE" <<'PY' || fail "helper logic failed"
import importlib.util, json, os, sys, types
path, sm_cfg = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("fme", path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

from pathlib import Path
m.SELF_MAINT_JSON_DEFAULT = Path(sm_cfg)
m.SELF_MAINT_JSON_FALLBACK = Path("/nonexistent/sm-fallback.json")

cases = [
    ("feat: add ratio", "upgrade"),
    ("feat(metrics): add ratio", "upgrade"),
    ("feat!: break API", "upgrade"),
    ("Feat: title case", "upgrade"),
    ("fix: seat crash", "repair"),
    ("fix(seats): null deref", "repair"),
    ("test: cover ratio", "repair"),
    ("chore: bump deps", "churn"),
    ("refactor: rename", "churn"),
    ("docs: readme", "churn"),
    ("ci: workflow", "churn"),
    ("Update foo.py", "churn"),
    ("", "churn"),
    ("no prefix here", "churn"),
]
for title, exp in cases:
    got = m._classify_title(title)
    assert got == exp, f"classify {title!r} -> {got}, expected {exp}"
print("OK: classifier feat/fix/test/chore/unclassified")

repos = m._self_maintenance_repos()
assert repos == {"Nishfleet/fleet-ops", "Nishfleet/fleet-ops-deploy"}, repos
print("OK: self-maintenance repo set from config")

detail = [
    {"repo": "Nishfleet/fleet-ops", "title": "feat: add self-maintenance ratio"},
    {"repo": "Nishfleet/fleet-ops", "title": "fix: seat crash"},
    {"repo": "Nishfleet/fleet-ops-deploy", "title": "chore: bump"},
    {"repo": "Nishfleet/0509", "title": "feat: new landing"},
    {"repo": "Nishfleet/0509", "title": "test: cover x"},
    {"repo": "Nishfleet/tinystudio-in", "title": "random title"},
]
sm = m._self_maintenance_and_quality(detail)
assert sm["self"] == 3, sm
assert sm["product"] == 3, sm
assert sm["total"] == 6, sm
assert abs(sm["ratio"] - 0.5) < 1e-9, sm["ratio"]
assert sm["quality"] == {"upgrade": 2, "repair": 2, "churn": 2}, sm["quality"]
assert abs(sm["share"]["upgrade"] - 2/6) < 1e-9, sm["share"]
assert abs(sm["share"]["churn"] - 2/6) < 1e-9, sm["share"]
print("OK: self-maintenance+quality counts, ratio, shares")

sm0 = m._self_maintenance_and_quality([])
assert sm0["total"] == 0 and sm0["self"] == 0 and sm0["product"] == 0, sm0
assert sm0["ratio"] is None, sm0
assert sm0["share"]["upgrade"] is None and sm0["share"]["churn"] is None, sm0
assert sm0["quality"] == {"upgrade": 0, "repair": 0, "churn": 0}, sm0
print("OK: no-merge day -> ratio/share omitted, heartbeat counts 0")

m.SELF_MAINT_JSON_DEFAULT = Path("/nonexistent/sm-1.json")
m.SELF_MAINT_JSON_FALLBACK = Path("/nonexistent/sm-2.json")
repos = m._self_maintenance_repos()
assert repos == {"Nishfleet/fleet-ops"}, repos
print("OK: missing config -> default {Nishfleet/fleet-ops}")
PY

# =========================================================================
# 5. config/self-maintenance-repos.json shape
# =========================================================================
jq -e '.repos | type == "array" and length > 0' "$sm_config" >/dev/null \
  || fail "self-maintenance-repos.json repos must be a non-empty array"
jq -e '.repos | index("fleet-ops")' "$sm_config" >/dev/null \
  || fail "self-maintenance-repos.json must include fleet-ops"
ok "self-maintenance-repos.json valid, includes fleet-ops"

# =========================================================================
# 6. _has_delivery_evidence lock-step with lib/exec-review-receipt.py
# =========================================================================
python3 - "$exporter" "$receipt" <<'PY' || fail "delivery-evidence lock-step failed"
import importlib.util, sys
def load(p, name):
    spec = importlib.util.spec_from_file_location(name, p)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m
fme = load(sys.argv[1], "fme")
receipt = load(sys.argv[2], "receipt")
bodies = [
    "run-proof: journal|service x\n",
    "## Verification\njournalctl --user -u x\n",
    "## Verification\nhttps://example.com/run/1\n",
    "## Verification\nexit 0\n",
    "## Verification\n```\nok: 5\n```\n",
    "## Verification\nnothing useful\n",
    "no evidence here at all",
    "",
    "**Verification**\n$ npm test\n",
    "## Verification:\nrc=0\n",
    "Random body with systemctl in it but no Verification section",
    "## Verification\nALL PHASES PASSED\n",
    "run-proof:https://example.com/x\n",
    "## Verification\n  systemctl --user status x\n",
]
mismatch = 0
for b in bodies:
    a = fme._has_delivery_evidence(b)
    c = receipt.has_receipt(b)
    if a != c:
        mismatch += 1
        print(f"MISMATCH body={b!r}: fme={a} receipt={c}")
assert mismatch == 0, f"{mismatch} delivery-evidence mismatches vs exec-review-receipt"
print("OK: _has_delivery_evidence lock-step with exec-review-receipt:has_receipt")
PY

# =========================================================================
# 7. _verified_merges counts + ratio
# =========================================================================
python3 - "$exporter" "$SM_CONFIG_OVERRIDE" <<'PY' || fail "verified-merges logic failed"
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("fme", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
detail = [
    {"repo":"Nishfleet/fleet-ops","title":"feat: x","body":"run-proof: url http://x","additions":10,"deletions":2,"changed_files":1},
    {"repo":"Nishfleet/0509","title":"fix: y","body":"no evidence","additions":5,"deletions":0,"changed_files":1},
    {"repo":"Nishfleet/0509","title":"chore: z","body":"## Verification\njournalctl --user -u q\n","additions":0,"deletions":0,"changed_files":0},
    {"repo":"Nishfleet/0509","title":"feat: w","body":"## Verification\nexit 0\n","additions":3,"deletions":1,"changed_files":2},
]
vm = m._verified_merges(detail)
assert vm["verified"] == 2, vm
assert vm["unverified"] == 2, vm
assert vm["total"] == 4, vm
assert abs(vm["ratio"] - 0.5) < 1e-9, vm
print("OK: _verified_merges counts + ratio (non-null diff AND delivery evidence)")
vm0 = m._verified_merges([])
assert vm0["total"] == 0 and vm0["ratio"] is None, vm0
print("OK: no-merge day -> verified ratio omitted, counts 0")
PY

# =========================================================================
# 8. fleet_rules.yml: promtool (if available) + rule presence
# =========================================================================
if command -v promtool >/dev/null 2>&1; then
  promtool check rules "$rules" >/dev/null \
    || fail "promtool check rules failed on fleet_rules.yml"
  ok "promtool check rules: fleet_rules.yml valid"
else
  echo "OK: promtool not installed locally — skipping syntax check (CI box has it)"
fi
grep -q "alert: FleetSelfMaintenanceAbsent" "$rules" \
  || fail "fleet_rules.yml missing FleetSelfMaintenanceAbsent"
grep -q 'absent(fleet_self_maintenance_merges{kind="total"})' "$rules" \
  || fail "absent rule must key on kind=\"total\" (always-emitted heartbeat)"
grep -q "alert: FleetSelfMaintenanceRegression" "$rules" \
  || fail "fleet_rules.yml missing FleetSelfMaintenanceRegression"
grep -q "offset 24h" "$rules" \
  || fail "regression rule must be a 24h-offset TREND, not a level threshold"
grep -q "alert: FleetQualityChurnRegression" "$rules" \
  || fail "fleet_rules.yml missing FleetQualityChurnRegression"
grep -q "fleet_self_maintenance_ratio - fleet_self_maintenance_ratio offset 24h" "$rules" \
  || fail "regression rule must be ratio - ratio offset 24h (trend delta)"
# Verified-merges regression trend rule (objective decision).
grep -q "alert: FleetVerifiedMergeRegression" "$rules" \
  || fail "fleet_rules.yml missing FleetVerifiedMergeRegression"
grep -q "fleet_verified_merge_ratio - fleet_verified_merge_ratio offset 24h" "$rules" \
  || fail "verified-merge regression must be ratio - ratio offset 24h (trend delta)"
# Queue composition 64% tripwire (fleet-ops#2171): a LEVEL held above 0.64
# (not a delta), but smoothed over the trailing 7d so a momentary dip or
# export gap cannot reset a raw for: and keep the alert pending forever.
grep -q "alert: FleetQueueSelfMaintenanceRatioHigh" "$rules" \
  || fail "fleet_rules.yml missing FleetQueueSelfMaintenanceRatioHigh"
grep -q "avg_over_time(fleet_queue_self_maintenance_ratio\[7d\]) > 0.64" "$rules" \
  || fail "queue tripwire must be the 7d-smoothed level (> 0.64) — an instant value with a long for: never fires (fleet-ops#2171)"
# The same tripwire must reach FIRING within its for: on a realistic series
# (high ratio with recurring dips), not sit pending forever — proved with
# promtool test rules (the live 2026-08-30 shape: ratio > 0.64 100% of the
# time but the 1w for: never completed, fleet-ops#2171).
grep -q "alert: FleetSeatComebackOverdue" "$rules" \
  || fail "fleet_rules.yml missing FleetSeatComebackOverdue (fleet-ops#2407)"
grep -q "fleet_seat_comeback_overdue_total > 0" "$rules" \
  || fail "comeback-overdue rule must trip on fleet_seat_comeback_overdue_total > 0"
if command -v promtool >/dev/null 2>&1; then
  unit_yml="$scratch/fleet-queue-ratio.test.yml"
  cat >"$unit_yml" <<YOAML
rule_files:
  - $rules
evaluation_interval: 6h
tests:
  - interval: 6h
    input_series:
      - series: 'fleet_queue_self_maintenance_ratio{queue="agent-ready"}'
        # 32 steps cover the 7d window; recurring 0.50 dips would reset a raw
        # instant + 1w for: rule but not the 7d average (real fleet-ops#2171 shape).
        values: '0.85 0.85 0.50 0.85 0.85 0.50 0.85 0.85 0.50 0.85 0.85 0.50 0.85 0.85 0.50 0.85 0.85 0.50 0.85 0.85 0.50 0.85 0.85 0.50 0.85 0.85 0.50 0.85 0.85 0.50 0.85 0.85'
    alert_rule_test:
      - eval_time: 12h
        alertname: FleetQueueSelfMaintenanceRatioHigh
        exp_alerts:
          - exp_labels:
              alertname: FleetQueueSelfMaintenanceRatioHigh
              queue: agent-ready
              service: fleet
              severity: warning
            exp_annotations:
              summary: 'queue agent-ready 7-day self-maintenance ratio stayed above 64% (fleet2 death-number) for 6 hours'
              description: 'avg_over_time(fleet_queue_self_maintenance_ratio{queue="agent-ready"}[7d]) has been above 0.64 (the fleet2 death-number) for 6+ hours. fleet2 died at 64% self-maintenance; a sustained high ratio in the intake queue means the fleet is queueing machinery work faster than product work. The 7d window absorbs the momentary dips and export gaps that reset the old 1w for: and kept this alert pending forever (fleet-ops#2171). The ratio is exported only when total>0. Feeds Weekly Review scoring and the precedence-sunset question. Inspect fleet_queue_total and fleet_queue_self_maintenance_total for the queue.'
YOAML
  # promtool test rules exits 1 on a failed case AND prints FAILED to
  # stdout, so gate on both: exit code (loud) and output text (catches
  # the exit-0-print-FAILED quirk on other builds).
  if ! out="$(promtool test rules "$unit_yml" 2>&1)"; then
    fail "promtool test rules exited non-zero on the queue-tripwire unit test: $out"
  fi
  grep -q "SUCCESS" <<<"$out" \
    || fail "promtool test rules: queue tripwire must transition pending->firing within for: 6h on the smoothed 7d window ($out)"
  ok "promtool test rules: queue tripwire fires despite momentary dips (fleet-ops#2171)"
fi
ok "fleet_rules.yml: absent heartbeat + 3 regression-trend rules + queue tripwire"

# =========================================================================
# 9. MANIFEST declares the exporter, units, config, and rules
# =========================================================================
grep -Fxq "libexec/fleet-metrics-export.py /home/nish/.local/libexec/fleet-metrics-export.py" "$manifest" \
  || fail "MANIFEST missing libexec/fleet-metrics-export.py"
grep -Fxq "systemd/fleet-metrics-export.service /home/nish/.config/systemd/user/fleet-metrics-export.service" "$manifest" \
  || fail "MANIFEST missing fleet-metrics-export.service"
grep -Fxq "systemd/fleet-metrics-export.timer /home/nish/.config/systemd/user/fleet-metrics-export.timer" "$manifest" \
  || fail "MANIFEST missing fleet-metrics-export.timer"
grep -Fxq "config/self-maintenance-repos.json /home/nish/workspaces/tooling/fleet-ops/config/self-maintenance-repos.json" "$manifest" \
  || fail "MANIFEST missing config/self-maintenance-repos.json"
grep -Fxq "config/fleet_rules.yml /etc/prometheus/fleet_rules.yml" "$manifest" \
  || fail "MANIFEST missing config/fleet_rules.yml (system scope)"
ok "MANIFEST declares exporter + units + self-maintenance config + rules"

# =========================================================================
# 10. End-to-end: main() emits the new metric lines for a canned detail list
# =========================================================================
OUT_OVERRIDE="$scratch/out.prom"
DETAIL_STUB="$scratch/detail.json"
cat >"$DETAIL_STUB" <<'JSON'
[
  {"repo": "Nishfleet/fleet-ops", "title": "feat: add ratio", "body": "run-proof: journal|service x\n", "additions": 93, "deletions": 3, "changed_files": 3},
  {"repo": "Nishfleet/0509", "title": "fix: landing bug", "body": "## Verification\njournalctl --user -u x\n", "additions": 5, "deletions": 1, "changed_files": 1},
  {"repo": "Nishfleet/0509", "title": "chore: deps", "body": "no evidence", "additions": 2, "deletions": 0, "changed_files": 1}
]
JSON

# fleet-ops#1445: seed a per-seat health ledger with one dead-credential seat
# (seat_dead=true + credentials_bad, needs re-auth) and one healthy seat. The
# real _read_dead_credentials() scans it and main() must emit the distinct
# dead-credential signal (total gauge + per-seat series) for exactly the dead
# seat.
SEAT_LEDGER_OVERRIDE="$scratch/seed-dead"
mkdir -p "$SEAT_LEDGER_OVERRIDE"
cat >"$SEAT_LEDGER_OVERRIDE/xai-oauth__grok-4.5.json" <<'JSON'
{"provider":"xai-oauth","model":"grok-4.5","http_status":401,"health_class":"credentials_bad","seat_dead":true,"observed_at":"2026-08-29T06:30:53Z","source":"cli_spawn","failure_mode":"credentials_bad","usable_at":null,"retryable":false,"seat_dead":true}
JSON
cat >"$SEAT_LEDGER_OVERRIDE/devin__glm-5-2.json" <<'JSON'
{"provider":"devin","model":"glm-5-2","health_class":"healthy","seat_dead":false,"observed_at":"2026-08-29T06:30:53Z"}
JSON

python3 - "$exporter" "$OUT_OVERRIDE" "$DETAIL_STUB" "$SM_CONFIG_OVERRIDE" "$SEAT_LEDGER_OVERRIDE" <<'PY' || fail "main() emission failed"
import importlib.util, json, os, sys, types
from pathlib import Path
exporter, out_path, detail_stub, sm_cfg, seat_ledger = sys.argv[1:6]
spec = importlib.util.spec_from_file_location("fme", exporter)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

m.OUT = Path(out_path)
m.SELF_MAINT_JSON_DEFAULT = Path(sm_cfg)
m.SELF_MAINT_JSON_FALLBACK = Path("/nonexistent/fb.json")
m.SEAT_HEALTH = Path("/nonexistent/seat.json")
m.SEAT_LEDGER = Path(seat_ledger)
m.HC_URL_FILE = Path("/nonexistent/hc.url")
m.ACTIONS_LOG = Path("/nonexistent/actions.log")
m.MAINTENANCE_FLAG = Path("/nonexistent/maint.json")
m.INTAKE_JSON_DEFAULT = Path("/nonexistent/intake.json")
m.INTAKE_JSON_FALLBACK = Path("/nonexistent/intake2.json")
m.KEYSTONE_LEDGER = Path("/nonexistent/keystone.jsonl")
m.STALENESS_CACHE = Path("/nonexistent/stale.json")
m.PR_CACHE_DIR = Path(os.path.dirname(out_path))
m.DETAIL_CACHE = Path(os.path.dirname(out_path)) / "detail.cache.json"

def _stub_timers():
    return [{"unit": "fleet-metrics-export.timer", "last_usec": 0}]
m._list_timers = _stub_timers
m._timer_active = lambda unit: 1
m._read_seat = lambda: (1, 0)
m._merged_prs_detail = lambda: json.loads(Path(detail_stub).read_text())
m._repo_snapshot = lambda: None
m._queue_composition = lambda: {
    "ready-work": {"total": 5, "self": 1},
    "agent-ready": {"total": 6, "self": 2},
}
m._escalations_24h = lambda: {}
m._repair_log_counts_24h = lambda: (0, 0)
m._worker_units = lambda: []
m._standalone_pi_print_count = lambda u: 0
m._maintenance_quiescing = lambda: 0
m._keystone_routing_counts = lambda: (0, 0, None)
m._ping_healthcheck = lambda: None
m._GH_FETCHED_THIS_RUN = False

rc = m.main()
assert rc == 0, f"main rc={rc}"
body = Path(out_path).read_text()
# Heartbeat gauges always present.
assert 'fleet_self_maintenance_merges{kind="self"} 1' in body, body
assert 'fleet_self_maintenance_merges{kind="product"} 2' in body, body
assert 'fleet_self_maintenance_merges{kind="total"} 3' in body, body
assert "fleet_self_maintenance_ratio 0.333333" in body, body
# Quality counts: feat->upgrade(1), fix->repair(1), chore->churn(1).
assert 'fleet_pr_quality_24h{class="upgrade"} 1' in body, body
assert 'fleet_pr_quality_24h{class="repair"} 1' in body, body
assert 'fleet_pr_quality_24h{class="churn"} 1' in body, body
assert 'fleet_pr_quality_share{class="upgrade"} 0.333333' in body, body
# Verified-merges: PR1 (diff+evidence) + PR2 (diff+evidence) verified; PR3
# (diff but no evidence) unverified. verified=2, unverified=1, total=3.
assert 'fleet_verified_merges_24h{kind="verified"} 2' in body, body
assert 'fleet_verified_merges_24h{kind="unverified"} 1' in body, body
assert 'fleet_verified_merges_24h{kind="total"} 3' in body, body
assert "fleet_verified_merge_ratio 0.666667" in body, body
assert "# HELP fleet_verified_merges_24h" in body, body
assert "# TYPE fleet_verified_merge_ratio gauge" in body, body
# fleet-ops#1445: dead-credential signal — total gauge + per-seat series for
# exactly the one seed dead seat; the healthy seat is not counted.
assert "fleet_pi_seat_dead_credential_total 1" in body, body
assert '# HELP fleet_pi_seat_dead_credential_total' in body, body
assert '# TYPE fleet_pi_seat_dead_credential_total gauge' in body, body
assert '# HELP fleet_pi_seat_dead_credential ' in body, body
assert 'fleet_pi_seat_dead_credential{seat="xai-oauth__grok-4.5",http_status="401"} 1' in body, body
assert "devin__glm-5-2" not in body, "healthy seat must not appear in dead-credential series: " + body
print("OK: main() emits self-maintenance + quality + verified-merges families")
PY

echo "ALL OK: fleet-metrics-export #1136 logic pinned"

# =========================================================================
# 11. fleet-ops#1844/#1855: exactly one HELP + TYPE per metric family.
# =========================================================================
# When BOTH queues emit, the pre-#1855 exporter wrote # HELP/# TYPE for
# fleet_queue_total, fleet_queue_self_maintenance_total and
# fleet_queue_self_maintenance_ratio inside the per-queue loop, duplicating
# them. node_exporter's textfile collector rejects the whole file, so every
# fleet metric (ready_work, self-maintenance, keystone heartbeat, workers)
# went absent at once — the 2026-08-29T03:05Z incident that filed #1844.
# #1855 moved HELP/TYPE out of the loop but added no regression test; pin the
# single-HELP/TYPE invariant so a future edit cannot silently blind the fleet.
QUEUE_OUT="$scratch/queue.prom"
python3 - "$exporter" "$QUEUE_OUT" <<'PY' || fail "queue-family emission failed"
import importlib.util, sys
from pathlib import Path
from collections import Counter
exporter, out_path = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("fme", exporter)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# Mirror block 10's offline path overrides so the run never touches real state.
m.OUT = Path(out_path)
m.PR_CACHE_DIR = Path(out_path).parent
m.SELF_MAINT_JSON_DEFAULT = Path("/nonexistent/sm.json")
m.SELF_MAINT_JSON_FALLBACK = Path("/nonexistent/fb.json")
m.SEAT_HEALTH = Path("/nonexistent/seat.json")
m.SEAT_LEDGER = Path("/nonexistent/seatdb")
m.HC_URL_FILE = Path("/nonexistent/hc.url")
m.ACTIONS_LOG = Path("/nonexistent/actions.log")
m.MAINTENANCE_FLAG = Path("/nonexistent/maint.json")
m.INTAKE_JSON_DEFAULT = Path("/nonexistent/intake.json")
m.INTAKE_JSON_FALLBACK = Path("/nonexistent/intake2.json")
m.KEYSTONE_LEDGER = Path("/nonexistent/keystone.jsonl")
m.STALENESS_CACHE = Path("/nonexistent/stale.json")
m.DETAIL_CACHE = Path(out_path).parent / "detail.cache.json"

# gh-derived families are stubbed absent except queue composition, which is
# the family that used to duplicate its HELP/TYPE and must prove single-emit.
m._list_timers = lambda: [{"unit": "fleet-metrics-export.timer", "last_usec": 0}]
m._timer_active = lambda unit: 1
m._read_seat = lambda: (1, 0)
m._merged_prs_detail = lambda: None
m._repo_snapshot = lambda: None
m._queue_composition = lambda: {
    "ready-work": {"total": 5, "self": 4},
    "agent-ready": {"total": 6, "self": 4},
}
m._escalations_24h = lambda: {}
m._repair_log_counts_24h = lambda: (0, 0)
m._worker_units = lambda: []
m._standalone_pi_print_count = lambda u: 0
m._maintenance_quiescing = lambda: 0
m._keystone_routing_counts = lambda: (0, 0, None)
m._gh_rate_limit = lambda: None
m._read_dead_credentials = lambda: (0, [])
m._ping_healthcheck = lambda: None
m._GH_FETCHED_THIS_RUN = False

rc = m.main()
assert rc == 0, f"main rc={rc}"
body = Path(out_path).read_text()

# The family that used to dup must actually emit BOTH queues.
assert 'fleet_queue_total{queue="agent-ready"} 6' in body, body
assert 'fleet_queue_total{queue="ready-work"} 5' in body, body
assert 'fleet_queue_self_maintenance_total{queue="ready-work"} 4' in body, body

# THE regression guard (fleet-ops#1844/#1855): each metric name has exactly
# one # HELP and one # TYPE. A duplicate makes the textfile unparseable and
# node_exporter silently drops the whole fleet.prom.
help_counts = Counter()
type_counts = Counter()
for line in body.splitlines():
    if line.startswith("# HELP "):
        help_counts[line.split()[2]] += 1
    elif line.startswith("# TYPE "):
        type_counts[line.split()[2]] += 1
dups = [n for n, c in help_counts.items() if c > 1] + [
    n for n, c in type_counts.items() if c > 1
]
assert not dups, "duplicate HELP/TYPE lines for: %s\n%s" % (dups, body)

# Every queue-family metric must carry exactly one TYPE (a sample with a
# missing TYPE is also rejected by the textfile collector).
for fam in (
    "fleet_queue_total",
    "fleet_queue_self_maintenance_total",
    "fleet_queue_self_maintenance_ratio",
):
    assert type_counts[fam] == 1, f"{fam} TYPE count {type_counts[fam]}"

print("OK: queue family emits both queues with exactly one HELP/TYPE per metric")
PY

# =========================================================================
# 12. fleet-ops#1772: null ready_work must fail loud, not write a partial file
# =========================================================================
FAIL_OUT="$scratch/fail.prom"
python3 - "$exporter" "$FAIL_OUT" <<'PY' || fail "null-ready_work fail-loud test failed"
import importlib.util, os, sys
from pathlib import Path
exporter, out_path = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("fme", exporter)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

m.OUT = Path(out_path)
m.PR_CACHE_DIR = Path(os.path.dirname(out_path))
m.SELF_MAINT_JSON_DEFAULT = Path("/nonexistent/sm.json")
m.SELF_MAINT_JSON_FALLBACK = Path("/nonexistent/fb.json")
m.SEAT_HEALTH = Path("/nonexistent/seat.json")
m.SEAT_LEDGER = Path("/nonexistent/seatdb")
m.HC_URL_FILE = Path("/nonexistent/hc.url")
m.ACTIONS_LOG = Path("/nonexistent/actions.log")
m.MAINTENANCE_FLAG = Path("/nonexistent/maint.json")
m.INTAKE_JSON_DEFAULT = Path("/nonexistent/intake.json")
m.INTAKE_JSON_FALLBACK = Path("/nonexistent/intake2.json")
m.KEYSTONE_LEDGER = Path("/nonexistent/keystone.jsonl")
m.STALENESS_CACHE = Path("/nonexistent/stale.json")
m.DETAIL_CACHE = Path(os.path.dirname(out_path)) / "detail.cache.json"
m.GH_RATE_LIMIT_CACHE = Path(os.path.dirname(out_path)) / "rl.cache.json"
m.GH_RATE_LIMIT_STATE = Path(os.path.dirname(out_path)) / "rl.state.json"

m._list_timers = lambda: [{"unit": "fleet-metrics-export.timer", "last_usec": 0}]
m._timer_active = lambda unit: 1
m._read_seat = lambda: (1, 0)
m._merged_prs_detail = lambda: None
m._repo_snapshot = lambda: None
m._queue_composition = lambda: None  # null ready_work source
m._escalations_24h = lambda: {}
m._repair_log_counts_24h = lambda: (0, 0)
m._worker_units = lambda: []
m._standalone_pi_print_count = lambda u: 0
m._maintenance_quiescing = lambda: 0
m._keystone_routing_counts = lambda: (0, 0, None)
m._gh_rate_limit = lambda: None
m._read_dead_credentials = lambda: (0, [])
m._ping_healthcheck = lambda: None
m._GH_FETCHED_THIS_RUN = False

rc = m.main()
assert rc == 1, f"main() must fail loud on null ready_work, got rc={rc}"
assert not Path(out_path).exists(), f"main() wrote a partial file on null ready_work: {out_path}"
print("OK: null ready_work fails loud and no fleet.prom is written")
PY

# =========================================================================
# 13. fleet-ops#2273: legacy fleet-staleness.prom cleanup in the exporter
# =========================================================================
# The exporter is the single writer of staleness gauges (it reads the JSON
# cache). When it (re)writes fleet.prom it must also unlink the legacy
# fleet-staleness.prom textfile so node_exporter does not read a stale duplicate.
LEGACY_OUT="$scratch/legacy"
mkdir -p "$LEGACY_OUT/textfile"
echo "fleet_truth_staleness_last_run_seconds 1000000000" \
  > "$LEGACY_OUT/textfile/fleet-staleness.prom"
python3 - "$exporter" "$LEGACY_OUT/out.prom" "$LEGACY_OUT/textfile/fleet-staleness.prom" <<'PY' || fail "legacy cleanup in exporter failed"
import importlib.util, sys, os
from pathlib import Path
exporter, out_path, legacy = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("fme", exporter)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

m.OUT = Path(out_path)
m.LEGACY_STALENESS_PROM = Path(legacy)
m.PR_CACHE_DIR = Path(os.path.dirname(out_path))
m.SELF_MAINT_JSON_DEFAULT = Path("/nonexistent/sm.json")
m.SELF_MAINT_JSON_FALLBACK = Path("/nonexistent/fb.json")
m.SEAT_HEALTH = Path("/nonexistent/seat.json")
m.SEAT_LEDGER = Path("/nonexistent/seatdb")
m.HC_URL_FILE = Path("/nonexistent/hc.url")
m.ACTIONS_LOG = Path("/nonexistent/actions.log")
m.MAINTENANCE_FLAG = Path("/nonexistent/maint.json")
m.INTAKE_JSON_DEFAULT = Path("/nonexistent/intake.json")
m.INTAKE_JSON_FALLBACK = Path("/nonexistent/intake2.json")
m.KEYSTONE_LEDGER = Path("/nonexistent/keystone.jsonl")
m.STALENESS_CACHE = Path("/nonexistent/stale.json")
m.DETAIL_CACHE = Path(os.path.dirname(out_path)) / "detail.cache.json"
m.GH_RATE_LIMIT_CACHE = Path(os.path.dirname(out_path)) / "rl.cache.json"
m.GH_RATE_LIMIT_STATE = Path(os.path.dirname(out_path)) / "rl.state.json"

m._list_timers = lambda: [{"unit": "fleet-metrics-export.timer", "last_usec": 0}]
m._timer_active = lambda unit: 1
m._read_seat = lambda: (1, 0)
m._merged_prs_detail = lambda: None
m._repo_snapshot = lambda: None
m._queue_composition = lambda: None
m._escalations_24h = lambda: {}
m._repair_log_counts_24h = lambda: (0, 0)
m._worker_units = lambda: []
m._standalone_pi_print_count = lambda u: 0
m._maintenance_quiescing = lambda: 0
m._keystone_routing_counts = lambda: (0, 0, None)
m._gh_rate_limit = lambda: None
m._read_dead_credentials = lambda: (0, [])
m._ping_healthcheck = lambda: None
m._GH_FETCHED_THIS_RUN = False

rc = m.main()
assert rc == 1, f"main() must fail loud on null ready_work (rc={rc})"
assert not Path(out_path).exists(), "no fleet.prom on fail-loud"
assert not Path(legacy).exists(), "legacy fleet-staleness.prom must be cleaned up"
print("OK: legacy fleet-staleness.prom removed on fail-loud export")

rc = m.main()
assert rc == 1
assert not Path(legacy).exists()
print("OK: second run is a no-op when legacy file is absent")
PY

# =========================================================================
# 14. fleet-ops#2407: seat release-at-usable_at + comeback-overdue metric
# =========================================================================
# A walled seat whose usable_at/bench_until has passed is RELEASED by the
# router (lib/seat-lib.sh seat_usable fail-opens it) but stays classed
# non-healthy in the ledger until the next observation reclassifies it.
# The availability rollup must count released seats (so a past-wall seat
# does not silently depress seat_availability), the comeback-overdue gauge
# must fail loud when such seats linger unobserved, and fleet_rules.yml must
# carry the alert. Fixtures are wall-clock-relative so the test is stable
# at any run time.
CB_SEATS="$scratch/cb-seats"
mkdir -p "$CB_SEATS"
python3 - "$exporter" "$repo_root/config/seat-caps.json" "$CB_SEATS" <<'PY' || fail "seat release-at-expiry test failed"
import importlib.util, json, sys, time
from datetime import datetime, timezone
from pathlib import Path

exporter, seat_caps, seat_dir = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("fme", exporter)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

now = time.time()

def iso(offset_s):
    return datetime.fromtimestamp(now + offset_s, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

PAST = iso(-3600)   # wall clock expired 1h ago
FUT  = iso(3600)    # wall clock held for another 1h

# Fixtures: wall-clock-relative so no test depends on the real date.
fixtures = {
    # 1. overload_bench with EXPIRED wall -> RELEASED (router fail-opens).
    "commandcode__minimax_minimax-m3-free.json": {
        "provider": "commandcode", "model": "minimax/minimax-m3-free",
        "http_status": 503, "health_class": "overload_bench", "seat_dead": False,
        "usable_at": PAST, "bench_until": PAST,
    },
    # 2. overload_bench with FUTURE wall -> still HELD (walled).
    "commandcode__poolside_laguna-s-2.1-free.json": {
        "provider": "commandcode", "model": "poolside/laguna-s-2.1-free",
        "http_status": 503, "health_class": "overload_bench", "seat_dead": False,
        "usable_at": FUT, "bench_until": FUT,
    },
    # 3. quota_exhausted with EXPIRED wall -> NOT released (held
    #    unconditionally until a healthy observation) but comeback-overdue.
    "minimax__MiniMax-M3.json": {
        "provider": "minimax", "model": "MiniMax-M3",
        "http_status": 402, "health_class": "quota_exhausted", "seat_dead": False,
        "usable_at": PAST, "bench_until": None,
    },
    # 4. rate_limited with EXPIRED wall -> RELEASED.
    "opencode__mimo-v2.5-free.json": {
        "provider": "opencode", "model": "mimo-v2.5-free",
        "http_status": 429, "health_class": "rate_limited", "seat_dead": False,
        "usable_at": PAST, "bench_until": None,
    },
    # 5. corpse (seat_dead) with EXPIRED wall -> never released, never
    #    comeback-overdue (FleetDeadCredentialSeats owns corpses).
    "opencode__muse-spark-1.2-contributor-free.json": {
        "provider": "opencode", "model": "muse-spark-1.2-contributor-free",
        "http_status": 500, "health_class": "corpse", "seat_dead": True,
        "usable_at": PAST, "bench_until": None,
    },
    # 6. test__ fixture -> excluded from comeback-overdue.
    "test__test.json": {
        "provider": "test", "model": "test",
        "http_status": 429, "health_class": "rate_limited", "seat_dead": False,
        "usable_at": PAST, "bench_until": None,
    },
    # 7. .spawn-bench marker -> excluded from comeback-overdue.
    "xai-oauth__grok-4.5.spawn-bench.json": {
        "provider": "xai-oauth", "model": "grok-4.5", "usable_at": PAST,
        "reason": "no_block:rc=0", "backoff_s": 300,
    },
}
for name, body in fixtures.items():
    (Path(seat_dir) / name).write_text(json.dumps(body))

# --- pure helper semantics ---
def ld(name):
    return json.loads((Path(seat_dir) / name).read_text())

assert m._seat_is_released(ld("commandcode__minimax_minimax-m3-free.json")) is True, \
    "expired overload_bench wall must release"
assert m._seat_is_released(ld("commandcode__poolside_laguna-s-2.1-free.json")) is False, \
    "future overload_bench wall must stay held"
assert m._seat_is_released(ld("minimax__MiniMax-M3.json")) is False, \
    "quota_exhausted is never release-at-expiry"
assert m._seat_is_released(ld("opencode__mimo-v2.5-free.json")) is True, \
    "expired rate_limited wall must release"
assert m._seat_is_released(ld("opencode__muse-spark-1.2-contributor-free.json")) is False, \
    "corpse (seat_dead) never releases"
print("OK: _seat_is_released mirrors seat_usable fail-open (fleet-ops#2407)")

# --- _read_comeback_overdue over the scratch ledger ---
m.SEAT_LEDGER = Path(seat_dir)
cb_n, cb = m._read_comeback_overdue()
ids = {f"{s['provider']}__{s['model']}" for s in cb}
# Past-wall non-dead non-excluded seats: commandcode minimax (overload past),
# minimax MiniMax-M3 (quota past), opencode mimo (rate_limited past) = 3.
assert cb_n == 3, f"comeback_overdue_n must be 3, got {cb_n}"
assert {"commandcode__minimax/minimax-m3-free", "minimax__MiniMax-M3", "opencode__mimo-v2.5-free"} <= ids, ids
assert not any("grok-4.5" in i for i in ids), "spawn-bench leaked into comeback"
assert not any(i.startswith("test__") for i in ids), "test__ leaked into comeback"
assert not any("muse-spark" in i for i in ids), "corpse leaked into comeback"
print("OK: _read_comeback_overdue counts past-wall seats, excludes bench/test/corpse")

# --- availability rollup: released seats count healthy ---
# Seed every enrolled provider (cap>0) with a healthy fixture ledger, then
# overwrite commandcode's two ledgers with the past-wall overload_bench pair
# (RELEASED -> commandcode still counts) and minimax's with quota_exhausted
# past-wall (NOT released -> minimax drops out).
caps = json.loads(Path(seat_caps).read_text())
enrolled = [p for p, cfg in caps.get("providers", {}).items()
            if isinstance(cfg, dict) and isinstance(cfg.get("cap"), (int, float))
            and cfg.get("cap") > 0]
assert "commandcode" in enrolled and "minimax" in enrolled, "fixture providers must be enrolled"
for prov in enrolled:
    (Path(seat_dir) / f"{prov}__fixture.json").write_text(json.dumps({
        "provider": prov, "model": "fixture", "health_class": "healthy",
        "seat_dead": False, "usable_at": None, "bench_until": None,
    }))
m.SEAT_CAPS_DEFAULT = Path(seat_caps)
m.SEAT_CAPS_FALLBACK = Path(seat_caps)
base = m._healthy_enrolled_seat_count()
assert base == len(enrolled), f"all-enrolled healthy base must be {len(enrolled)}, got {base}"
# Replace the commandcode healthy fixture with the two overload_bench ledgers
# (one past-wall). Released counts healthy -> commandcode stays in the rollup.
(Path(seat_dir) / "commandcode__fixture.json").unlink(missing_ok=True)
rel = m._healthy_enrolled_seat_count()
assert rel == len(enrolled), \
    f"released commandcode must still count healthy ({len(enrolled)}), got {rel}"
print(f"OK: released seats count toward availability (commandcode stays {rel}/{len(enrolled)})")
# Quarantine minimax: quota_exhausted past-wall is NOT released -> the
# provider drops out of the rollup until re-observed.
(Path(seat_dir) / "minimax__fixture.json").write_text(json.dumps({
    "provider": "minimax", "model": "fixture", "health_class": "quota_exhausted",
    "seat_dead": False, "usable_at": PAST, "bench_until": None,
}))
quota = m._healthy_enrolled_seat_count()
assert quota == len(enrolled) - 1, \
    f"quota_exhausted past-wall must NOT count healthy ({len(enrolled)-1}), got {quota}"
print("OK: quota_exhausted never release-counts (availability honest)")
PY


# fleet-ops#1350: GitHub API rate-limit metrics + pi-intake sidecar.
bash "$here/fleet-gh-rate-limit.test.sh" || fail "fleet-gh-rate-limit tests failed"

# =========================================================================
# 15. fleet-ops#2493: held wrapper spawn-bench outranks a later healthy
#     observation. The seat-health extension's after_provider_response
#     re-writes the ledger as health_class=healthy on a 200 OK, but the
#     wrapper's spawn-bench marker (written for an empty run / no-op /
#     spawn-fail) persists in the same directory. The census said
#     "healthy" while pick_seat said "no usable seat" — fleet-ops#2493
#     closed that gap. The seat MUST drop out of the availability rollup
#     while the bench is in the future, and return when the bench expires.
# =========================================================================
SB_SEATS="$scratch/sb-seats"
mkdir -p "$SB_SEATS"
python3 - "$exporter" "$repo_root/config/seat-caps.json" "$SB_SEATS" <<'PY' || fail "spawn-bench vs healthy ledger test failed"
import importlib.util, json, sys, time
from datetime import datetime, timezone
from pathlib import Path

exporter, seat_caps, seat_dir = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("fme", exporter)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

now = time.time()
def iso(offset_s):
    return datetime.fromtimestamp(now + offset_s, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
FUT = iso(3600)   # bench 1h in the future
PAST = iso(-3600) # bench 1h in the past (expired)

caps = json.loads(Path(seat_caps).read_text())
enrolled = [p for p, cfg in caps.get("providers", {}).items()
            if isinstance(cfg, dict) and isinstance(cfg.get("cap"), (int, float))
            and cfg.get("cap") > 0]
assert "opencode" in enrolled, "fixture provider opencode must be enrolled"

# Seed every enrolled provider with a healthy fixture -> baseline = len(enrolled).
for prov in enrolled:
    (Path(seat_dir) / f"{prov}__fixture.json").write_text(json.dumps({
        "provider": prov, "model": "fixture", "health_class": "healthy",
        "seat_dead": False, "usable_at": None, "bench_until": None,
    }))
m.SEAT_LEDGER = Path(seat_dir)
m.SEAT_CAPS_DEFAULT = Path(seat_caps)
m.SEAT_CAPS_FALLBACK = Path(seat_caps)
base = m._healthy_enrolled_seat_count()
assert base == len(enrolled), f"baseline must be {len(enrolled)}, got {base}"

# Scenario A: a healthy opencode ledger + a HELD spawn-bench sibling.
# Pre-#2493 the census counted opencode as healthy (the ledger says so).
# Post-#2493 the bench wins: opencode must drop out of the rollup.
(Path(seat_dir) / "opencode__fixture.json").write_text(json.dumps({
    "provider": "opencode", "model": "fixture", "health_class": "healthy",
    "seat_dead": False, "usable_at": None, "bench_until": None,
}))
(Path(seat_dir) / "opencode__fixture.spawn-bench.json").write_text(json.dumps({
    "provider": "opencode", "model": "fixture", "usable_at": FUT,
    "reason": "no_block:rc=0", "backoff_s": 900,
}))
held = m._healthy_enrolled_seat_count()
assert held == len(enrolled) - 1, \
    f"opencode with held spawn-bench must drop out ({len(enrolled)-1}), got {held}"
print(f"OK: held wrapper spawn-bench outranks healthy ledger (opencode dropped, {held}/{len(enrolled)})")

# Scenario B: same fixture, but the bench is EXPIRED (1h in the past).
# The bench is no longer authoritative — the healthy ledger wins, opencode
# returns to the rollup. The bench file is best-effort metadata: when it
# expires the seat_usable fail-opens the seat, and the census mirrors that.
(Path(seat_dir) / "opencode__fixture.spawn-bench.json").write_text(json.dumps({
    "provider": "opencode", "model": "fixture", "usable_at": PAST,
    "reason": "no_block:rc=0", "backoff_s": 900,
}))
expired = m._healthy_enrolled_seat_count()
assert expired == len(enrolled), \
    f"expired bench must not gate the rollup ({len(enrolled)}), got {expired}"
print("OK: expired bench does not gate the rollup (mirrors seat_usable fail-open)")

# Scenario C: missing ledger file. The fixture's ledger file is removed;
# the bench becomes the only signal. The bench alone is NOT enough to
# count the seat as healthy (no ledger file -> not proven healthy,
# fail-safe). The census still excludes opencode.
(Path(seat_dir) / "opencode__fixture.json").unlink()
missing_ledger = m._healthy_enrolled_seat_count()
assert missing_ledger == len(enrolled) - 1, \
    f"missing ledger with active bench must not count healthy ({len(enrolled)-1}), got {missing_ledger}"
print("OK: missing ledger + active bench -> not proven healthy (fail-safe)")

# Restore the fixture for any later scenarios.
(Path(seat_dir) / "opencode__fixture.json").write_text(json.dumps({
    "provider": "opencode", "model": "fixture", "health_class": "healthy",
    "seat_dead": False, "usable_at": None, "bench_until": None,
}))
(Path(seat_dir) / "opencode__fixture.spawn-bench.json").unlink()

# Scenario D: malformed / future-dated bench. Garbage in the spawn-bench
# file must not crash the exporter or pin a seat healthy; _spawn_bench_active
# returns False on bad data and the healthy ledger wins.
(Path(seat_dir) / "opencode__fixture.spawn-bench.json").write_text("not-json")
bad = m._healthy_enrolled_seat_count()
assert bad == len(enrolled), \
    f"malformed bench must not gate ({len(enrolled)}), got {bad}"
(Path(seat_dir) / "opencode__fixture.spawn-bench.json").write_text(json.dumps({
    "provider": "opencode", "model": "fixture", "usable_at": "garbage",
}))
bad2 = m._healthy_enrolled_seat_count()
assert bad2 == len(enrolled), \
    f"garbage usable_at must not gate ({len(enrolled)}), got {bad2}"
(Path(seat_dir) / "opencode__fixture.spawn-bench.json").unlink()
print("OK: malformed / garbage spawn-bench does not gate the rollup")
PY
ok "fleet-ops#2493: held wrapper spawn-bench outranks a later healthy observation (census honest)"

# =========================================================================
# 14. fleet-ops#2524: per-seat unhealthy rollup closes the FleetPiSeatUnhealthy gap
# =========================================================================
# The single-seat fleet_pi_seat_healthy gauge reads only pi-seat-health.json;
# FleetDeadCredentialSeats only watches credentials_bad seats; FleetSeatComebackOverdue
# excludes seat_dead=true seats. A manually-overridden seat_dead=true + health_class=unhealthy
# seat (the live 2026-08-31 poolside/laguna-s-2.1-free case) sat invisible to every
# alert. The fleet_pi_seat_unhealthy_total rollup closes the gap. Pin:
#   A. Per-seat ledger with one healthy + one unhealthy enrolled seat — the
#      exporter emits total=1 and exactly the unhealthy seat in the per-seat
#      series.
#   B. Healthy-only ledger — total=0, no per-seat series (mirror of accept
#      criteria "healthy seat clears it").
#   C. Unhealthy seat whose (provider, model) cap is 0 in seat-caps.json —
#      total=0; retirement is the fix surface, no manual ledger move needed.
#   D. fleet_rules.yml FleetPiSeatUnhealthy expr must trip on either the
#      per-seat total OR the single-seat gauge (the union closes the gap).
UN_OUT="$scratch/un-out.prom"
UN_SEAT_LEDGER="$scratch/un-seat-ledger"
UN_SEAT_CAPS="$scratch/un-seat-caps.json"
mkdir -p "$UN_SEAT_LEDGER"

cat >"$UN_SEAT_CAPS" <<'JSON'
{
  "providers": {
    "opencode": {"cap": 1, "models": {"healthy-lane-free": 1, "retired-lane-free": 0}},
    "commandcode": {"cap": 1, "models": {"poolside/laguna-s-2.1-free": 1}}
  }
}
JSON

# Scenario A: one healthy enrolled seat, one unhealthy enrolled seat, plus
# one retired seat (cap=0), one unhealthy seat with NO seat-caps.json entry
# (the "model not in roster" case), and one synthetic fixture — only the
# unhealthy enrolled seat must appear in the per-seat series.
cat >"$UN_SEAT_LEDGER/opencode__healthy-lane-free.json" <<'JSON'
{"provider":"opencode","model":"healthy-lane-free","http_status":200,"health_class":"healthy","seat_dead":false,"observed_at":"2026-08-31T12:00:00Z","source":"after_provider_response"}
JSON
cat >"$UN_SEAT_LEDGER/commandcode__poolside_laguna-s-2.1-free.json" <<'JSON'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":503,"health_class":"unhealthy","seat_dead":true,"observed_at":"2026-08-31T06:50:00Z","source":"manual_override_after_repeated_503","failure_mode":"overloaded_error","consecutive_failure_count":4}
JSON
cat >"$UN_SEAT_LEDGER/opencode__retired-lane-free.json" <<'JSON'
{"provider":"opencode","model":"retired-lane-free","http_status":503,"health_class":"unhealthy","seat_dead":false,"observed_at":"2026-08-31T09:00:00Z","source":"provider_fetch"}
JSON
cat >"$UN_SEAT_LEDGER/opencode__unknown-lane-free.json" <<'JSON'
{"provider":"opencode","model":"unknown-lane-free","http_status":503,"health_class":"transient_fault","seat_dead":false,"observed_at":"2026-08-31T11:14:40Z","source":"provider_fetch"}
JSON
cat >"$UN_SEAT_LEDGER/test__fixture.json" <<'JSON'
{"provider":"test","model":"fixture","http_status":500,"health_class":"unhealthy","seat_dead":false,"observed_at":"2026-08-31T09:00:00Z","source":"test"}
JSON
cat >"$UN_SEAT_LEDGER/commandcode__poolside_laguna-s-2.1-free.spawn-bench.json" <<'JSON'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","usable_at":"2026-09-01T00:00:00Z","reason":"no_block:rc=0"}
JSON

python3 - "$exporter" "$UN_OUT" "$UN_SEAT_LEDGER" "$UN_SEAT_CAPS" <<'PY' || fail "scenario A (mixed ledger) failed"
import importlib.util, os, sys
from pathlib import Path
exporter, out_path, seat_ledger, seat_caps = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("fme", exporter)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

m.OUT = Path(out_path)
m.PR_CACHE_DIR = Path(os.path.dirname(out_path))
m.SEAT_HEALTH = Path("/nonexistent/seat.json")
m.SEAT_LEDGER = Path(seat_ledger)
m.SEAT_CAPS_DEFAULT = Path(seat_caps)
m.SEAT_CAPS_FALLBACK = Path("/nonexistent/caps-fallback.json")
m.HC_URL_FILE = Path("/nonexistent/hc.url")
m.ACTIONS_LOG = Path("/nonexistent/actions.log")
m.MAINTENANCE_FLAG = Path("/nonexistent/maint.json")
m.INTAKE_JSON_DEFAULT = Path("/nonexistent/intake.json")
m.INTAKE_JSON_FALLBACK = Path("/nonexistent/intake2.json")
m.KEYSTONE_LEDGER = Path("/nonexistent/keystone.jsonl")
m.STALENESS_CACHE = Path("/nonexistent/stale.json")
m.DETAIL_CACHE = Path(os.path.dirname(out_path)) / "detail.cache.json"
m.GH_RATE_LIMIT_CACHE = Path(os.path.dirname(out_path)) / "rl.cache.json"
m.GH_RATE_LIMIT_STATE = Path(os.path.dirname(out_path)) / "rl.state.json"
m.SELF_MAINT_JSON_DEFAULT = Path("/nonexistent/sm.json")
m.SELF_MAINT_JSON_FALLBACK = Path("/nonexistent/fb.json")

m._list_timers = lambda: [{"unit": "fleet-metrics-export.timer", "last_usec": 0}]
m._timer_active = lambda unit: 1
m._read_seat = lambda: (1, 0)
m._merged_prs_detail = lambda: None
m._repo_snapshot = lambda: None
m._queue_composition = lambda: {
    "ready-work": {"total": 1, "self": 0},
    "agent-ready": {"total": 1, "self": 0},
}
m._escalations_24h = lambda: {}
m._repair_log_counts_24h = lambda: (0, 0)
m._worker_units = lambda: []
m._standalone_pi_print_count = lambda u: 0
m._maintenance_quiescing = lambda: 0
m._keystone_routing_counts = lambda: (0, 0, None)
m._gh_rate_limit = lambda: None
m._ping_healthcheck = lambda: None
m._GH_FETCHED_THIS_RUN = False

rc = m.main()
assert rc == 0, f"main rc={rc}"
body = Path(out_path).read_text()

# Help + Type emitted exactly once (the #1844/#1855 family-dup rule applies
# to the new family too — a future edit cannot silently blind the alert).
help_count = sum(1 for ln in body.splitlines() if ln.startswith("# HELP fleet_pi_seat_unhealthy_total"))
type_count = sum(1 for ln in body.splitlines() if ln.startswith("# TYPE fleet_pi_seat_unhealthy_total"))
assert help_count == 1, f"fleet_pi_seat_unhealthy_total HELP count {help_count}\n{body}"
assert type_count == 1, f"fleet_pi_seat_unhealthy_total TYPE count {type_count}\n{body}"
help_per = sum(1 for ln in body.splitlines() if ln.startswith("# HELP fleet_pi_seat_unhealthy ") or ln.startswith("# HELP fleet_pi_seat_unhealthy{"))
type_per = sum(1 for ln in body.splitlines() if ln.startswith("# TYPE fleet_pi_seat_unhealthy ") or ln.startswith("# TYPE fleet_pi_seat_unhealthy{"))
assert help_per == 1, f"fleet_pi_seat_unhealthy HELP count {help_per}\n{body}"
assert type_per == 1, f"fleet_pi_seat_unhealthy TYPE count {type_per}\n{body}"

# The unhealthy enrolled seat (commandcode/poolside/laguna-s-2.1-free) MUST
# appear; the healthy enrolled seat MUST NOT; the retired seat (cap=0) and
# the synthetic test__ fixture MUST NOT — those are excluded by the
# (provider, model) enrollment filter and the .spawn-bench / test provider
# filter respectively.
assert "fleet_pi_seat_unhealthy_total 1" in body, body
assert 'fleet_pi_seat_unhealthy{seat="commandcode__poolside_laguna-s-2.1-free",health_class="unhealthy"} 1' in body, body
assert "healthy-lane-free" not in body, f"healthy enrolled seat must not appear: {body}"
assert "retired-lane-free" not in body, f"retired (cap=0) seat must not appear: {body}"
assert "test__fixture" not in body, f"synthetic test provider must not appear: {body}"
assert ".spawn-bench" not in body, f".spawn-bench marker must not appear: {body}"
print("OK A: scenario A — mixed ledger emits the unhealthy enrolled seat only")
PY

# Scenario B: healthy-only ledger -> total=0, no per-seat series.
HEALTHY_ONLY_LEDGER="$scratch/healthy-only-ledger"
mkdir -p "$HEALTHY_ONLY_LEDGER"
cat >"$HEALTHY_ONLY_LEDGER/opencode__healthy-lane-free.json" <<'JSON'
{"provider":"opencode","model":"healthy-lane-free","http_status":200,"health_class":"healthy","seat_dead":false,"observed_at":"2026-08-31T12:00:00Z","source":"after_provider_response"}
JSON
python3 - "$exporter" "$scratch/healthy-out.prom" "$HEALTHY_ONLY_LEDGER" "$UN_SEAT_CAPS" <<'PY' || fail "scenario B (healthy-only) failed"
import importlib.util, os, sys
from pathlib import Path
exporter, out_path, seat_ledger, seat_caps = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("fme", exporter)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.OUT = Path(out_path)
m.PR_CACHE_DIR = Path(os.path.dirname(out_path))
m.SEAT_HEALTH = Path("/nonexistent/seat.json")
m.SEAT_LEDGER = Path(seat_ledger)
m.SEAT_CAPS_DEFAULT = Path(seat_caps)
m.SEAT_CAPS_FALLBACK = Path("/nonexistent/caps-fallback.json")
m.HC_URL_FILE = Path("/nonexistent/hc.url")
m.ACTIONS_LOG = Path("/nonexistent/actions.log")
m.MAINTENANCE_FLAG = Path("/nonexistent/maint.json")
m.INTAKE_JSON_DEFAULT = Path("/nonexistent/intake.json")
m.INTAKE_JSON_FALLBACK = Path("/nonexistent/intake2.json")
m.KEYSTONE_LEDGER = Path("/nonexistent/keystone.jsonl")
m.STALENESS_CACHE = Path("/nonexistent/stale.json")
m.DETAIL_CACHE = Path(os.path.dirname(out_path)) / "detail.cache.json"
m.GH_RATE_LIMIT_CACHE = Path(os.path.dirname(out_path)) / "rl.cache.json"
m.GH_RATE_LIMIT_STATE = Path(os.path.dirname(out_path)) / "rl.state.json"
m.SELF_MAINT_JSON_DEFAULT = Path("/nonexistent/sm.json")
m.SELF_MAINT_JSON_FALLBACK = Path("/nonexistent/fb.json")
m._list_timers = lambda: [{"unit": "fleet-metrics-export.timer", "last_usec": 0}]
m._timer_active = lambda unit: 1
m._read_seat = lambda: (1, 0)
m._merged_prs_detail = lambda: None
m._repo_snapshot = lambda: None
m._queue_composition = lambda: None
m._escalations_24h = lambda: {}
m._repair_log_counts_24h = lambda: (0, 0)
m._worker_units = lambda: []
m._standalone_pi_print_count = lambda u: 0
m._maintenance_quiescing = lambda: 0
m._keystone_routing_counts = lambda: (0, 0, None)
m._gh_rate_limit = lambda: None
m._ping_healthcheck = lambda: None
m._GH_FETCHED_THIS_RUN = False
rc = m.main()
assert rc == 0, f"main rc={rc}"
body = Path(out_path).read_text()
assert "fleet_pi_seat_unhealthy_total 0" in body, body
# Healthy-only ledger: no per-seat series — the per-seat family emits a
# zero-count total only.
assert "fleet_pi_seat_unhealthy{" not in body, body
print("OK B: scenario B — healthy-only ledger emits total=0 and no per-seat series")
PY

# Scenario C: retired-only seat (cap=0) -> total=0 (the alert-clearing path
# for fleet-ops#2524's own fix: setting cap=0 for poolside/laguna-s-2.1-free
# must drop the metric on the next exporter tick, no manual ledger move).
RETIRED_LEDGER="$scratch/retired-ledger"
mkdir -p "$RETIRED_LEDGER"
cat >"$RETIRED_LEDGER/opencode__retired-lane-free.json" <<'JSON'
{"provider":"opencode","model":"retired-lane-free","http_status":503,"health_class":"unhealthy","seat_dead":false,"observed_at":"2026-08-31T09:00:00Z","source":"provider_fetch"}
JSON
python3 - "$exporter" "$scratch/retired-out.prom" "$RETIRED_LEDGER" "$UN_SEAT_CAPS" <<'PY' || fail "scenario C (retired cap=0) failed"
import importlib.util, os, sys
from pathlib import Path
exporter, out_path, seat_ledger, seat_caps = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("fme", exporter)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.OUT = Path(out_path)
m.PR_CACHE_DIR = Path(os.path.dirname(out_path))
m.SEAT_HEALTH = Path("/nonexistent/seat.json")
m.SEAT_LEDGER = Path(seat_ledger)
m.SEAT_CAPS_DEFAULT = Path(seat_caps)
m.SEAT_CAPS_FALLBACK = Path("/nonexistent/caps-fallback.json")
m.HC_URL_FILE = Path("/nonexistent/hc.url")
m.ACTIONS_LOG = Path("/nonexistent/actions.log")
m.MAINTENANCE_FLAG = Path("/nonexistent/maint.json")
m.INTAKE_JSON_DEFAULT = Path("/nonexistent/intake.json")
m.INTAKE_JSON_FALLBACK = Path("/nonexistent/intake2.json")
m.KEYSTONE_LEDGER = Path("/nonexistent/keystone.jsonl")
m.STALENESS_CACHE = Path("/nonexistent/stale.json")
m.DETAIL_CACHE = Path(os.path.dirname(out_path)) / "detail.cache.json"
m.GH_RATE_LIMIT_CACHE = Path(os.path.dirname(out_path)) / "rl.cache.json"
m.GH_RATE_LIMIT_STATE = Path(os.path.dirname(out_path)) / "rl.state.json"
m.SELF_MAINT_JSON_DEFAULT = Path("/nonexistent/sm.json")
m.SELF_MAINT_JSON_FALLBACK = Path("/nonexistent/fb.json")
m._list_timers = lambda: [{"unit": "fleet-metrics-export.timer", "last_usec": 0}]
m._timer_active = lambda unit: 1
m._read_seat = lambda: (1, 0)
m._merged_prs_detail = lambda: None
m._repo_snapshot = lambda: None
m._queue_composition = lambda: None
m._escalations_24h = lambda: {}
m._repair_log_counts_24h = lambda: (0, 0)
m._worker_units = lambda: []
m._standalone_pi_print_count = lambda u: 0
m._maintenance_quiescing = lambda: 0
m._keystone_routing_counts = lambda: (0, 0, None)
m._gh_rate_limit = lambda: None
m._ping_healthcheck = lambda: None
m._GH_FETCHED_THIS_RUN = False
rc = m.main()
assert rc == 0, f"main rc={rc}"
body = Path(out_path).read_text()
assert "fleet_pi_seat_unhealthy_total 0" in body, body
assert "retired-lane-free" not in body, f"cap=0 seat must not appear: {body}"
print("OK C: scenario C — cap=0 retired seat does not count")
PY

# Scenario D: fleet_rules.yml FleetPiSeatUnhealthy expr must trip on either
# branch. Verify by parsing the rule and asserting the union is present.
# promtool proves the rule fires on the per-seat total in fleet_pi_seat_unhealthy_total.
grep -q "alert: FleetPiSeatUnhealthy" "$rules" \
  || fail "fleet_rules.yml missing FleetPiSeatUnhealthy"
grep -q "fleet_pi_seat_unhealthy_total > 0" "$rules" \
  || fail "FleetPiSeatUnhealthy must trip on fleet_pi_seat_unhealthy_total > 0 (fleet-ops#2524)"
grep -q "fleet_pi_seat_healthy == 0" "$rules" \
  || fail "FleetPiSeatUnhealthy must keep the single-seat gauge branch (legacy pi-seat-health.json coverage)"
grep -q "fleet_pi_seat_unhealthy" "$rules" \
  || fail "FleetPiSeatUnhealthy description must reference fleet_pi_seat_unhealthy (fleet-ops#2524)"

if command -v promtool >/dev/null 2>&1; then
  un_yml="$scratch/fleet-pi-seat-unhealthy.test.yml"
  cat >"$un_yml" <<YOAML
rule_files:
  - $rules
evaluation_interval: 6h
tests:
  - interval: 6h
    input_series:
      - series: 'fleet_pi_seat_unhealthy_total'
        # 30 minutes of total=1 with a brief gap to catch any reset
        # behaviour. Alert fires after `for: 30m` so the eval at 6h must
        # show exp_alerts with the warning severity.
        values: '0+0x30m 1+0x30m'
    alert_rule_test:
      - eval_time: 6h
        alertname: FleetPiSeatUnhealthy
        exp_alerts:
          - exp_labels:
              alertname: FleetPiSeatUnhealthy
              severity: warning
              service: fleet
            exp_annotations:
              summary: 'Pi seat unhealthy for 30+ minutes'
              description: 'Either the single-seat pi-seat-health.json is non-healthy OR at least one enrolled per-seat ledger entry has health_class set and != healthy (fleet_pi_seat_unhealthy_total > 0).'
YOAML
  if ! out="$(promtool test rules "$un_yml" 2>&1)"; then
    fail "promtool test rules exited non-zero on FleetPiSeatUnhealthy unit test: $out"
  fi
  grep -q "SUCCESS" <<<"$out" \
    || fail "promtool test rules: FleetPiSeatUnhealthy must fire on fleet_pi_seat_unhealthy_total > 0 ($out)"
  ok "promtool: FleetPiSeatUnhealthy fires on fleet_pi_seat_unhealthy_total > 0 (fleet-ops#2524)"
fi

ok "fleet-ops#2524: per-seat unhealthy rollup + alert tripwire + retirement path"
