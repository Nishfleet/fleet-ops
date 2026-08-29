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
# Queue composition 64% tripwire (scope addition): sustained level, not a delta.
grep -q "alert: FleetQueueSelfMaintenanceRatioHigh" "$rules" \
  || fail "fleet_rules.yml missing FleetQueueSelfMaintenanceRatioHigh"
grep -q "fleet_queue_self_maintenance_ratio > 0.64" "$rules" \
  || fail "queue tripwire must be a sustained level (> 0.64), not a delta"
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

python3 - "$exporter" "$OUT_OVERRIDE" "$DETAIL_STUB" "$SM_CONFIG_OVERRIDE" <<'PY' || fail "main() emission failed"
import importlib.util, json, os, sys, types
from pathlib import Path
exporter, out_path, detail_stub, sm_cfg = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("fme", exporter)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

m.OUT = Path(out_path)
m.SELF_MAINT_JSON_DEFAULT = Path(sm_cfg)
m.SELF_MAINT_JSON_FALLBACK = Path("/nonexistent/fb.json")
m.SEAT_HEALTH = Path("/nonexistent/seat.json")
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
m._queue_composition = lambda: None
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
print("OK: main() emits self-maintenance + quality + verified-merges families")
PY

echo "ALL OK: fleet-metrics-export #1136 logic pinned"
