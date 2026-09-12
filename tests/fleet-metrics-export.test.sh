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

# fleet-ops#5140: prom_lines() resolves product repos from intake-repos.json,
# which would let the m.main() heredocs below spend real gh calls and write
# deploy-quality-*-<product>.json into the production cache dir. Pin the
# fleet-ops-only set for the whole file.
cat >"$scratch/intake-fleet-ops-only.json" <<'JSON'
{ "repos": [{ "name": "fleet-ops" }] }
JSON
export FLEET_DQ_REPOS_JSON="$scratch/intake-fleet-ops-only.json"

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
# 7b. _read_seat parse is TZ-independent (fleet-ops#3329)
# =========================================================================
_TEST_SEAT_HEALTH="$scratch/seat-health.json" python3 - "$exporter" <<'PY' || fail "_read_seat UTC parse is TZ-dependent"
# Reproduce fleet-ops#3329: the exporter used time.mktime (process-local TZ)
# to parse a UTC observed_at, so under a +5:30 host localtime a fresh feed
# read ~5.5h stale and fired FleetPiSeatHealthStale (value ~19800s).
# Fix: calendar.timegm. This test runs in Asia/Kolkata and asserts a fresh
# observed_at still yields a small age.
import importlib.util, json, os, sys, time
from pathlib import Path

# Force the bug's failure mode: a non-UTC process localtime.
os.environ["TZ"] = "Asia/Kolkata"
time.tzset()

spec = importlib.util.spec_from_file_location("fme", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

seat = Path(os.environ["_TEST_SEAT_HEALTH"])
ow = int(time.time())
seat.write_text(json.dumps({
    "health_class": "healthy",
    "observed_at": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(ow)) + ".000Z",
}), encoding="utf-8")
m.SEAT_HEALTH = seat

healthy, epoch = m._read_seat()
age = ow - epoch
assert healthy == 1, healthy
# Correct UTC parse: age within a few hundred seconds. The pre-fix mktime
# path under +5:30 gave ~19800s and fired the stale alert.
assert age < 600, f"fresh observed_at parsed {age}s stale (expected < 600); TZ-dependent mktime bug"
print(f"OK: _read_seat epoch fresh under TZ=Asia/Kolkata (age={age}s)")
PY

# =========================================================================
# 7c. _read_seat: a held wrapper spawn-bench outranks a healthy sidecar
#     (fleet-ops#3563)
# =========================================================================
# A benched seat must not report healthy. The bench writers co-write
# pi-seat-health.json at bench time, but a later healthy observation from
# the seat-health extension (in-flight run completing after the bench, or
# a comeback probe) rewrites it while the spawn-bench marker still holds —
# live 2026-09-05: devin/glm-5-2 ledger healthy at 23:19Z with the marker
# held until 23:55Z. The gauge must read 0 while the marker holds and
# fail-open to 1 once it expires.
_3563_LEDGER="$scratch/ledger-3563"
_3563_HEALTH="$scratch/seat-health-3563.json"
mkdir -p "$_3563_LEDGER"
_3563_LEDGER="$_3563_LEDGER" _3563_HEALTH="$_3563_HEALTH" \
python3 - "$exporter" <<'PY' || fail "3563: spawn-bench overlay failed"
import importlib.util, json, os, sys, time
from pathlib import Path

spec = importlib.util.spec_from_file_location("fme", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

ledger = Path(os.environ["_3563_LEDGER"])
m.SEAT_LEDGER = ledger
seat = Path(os.environ["_3563_HEALTH"])
m.SEAT_HEALTH = seat

future = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() + 3600)) + "Z"
past = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() - 60)) + "Z"
now = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + ".000Z"

# The model id carries a ':' so the test also pins the seat_spawn_bench_path
# sanitisation (deepseek-v4-flash:0731 -> deepseek-v4-flash_0731).
seat.write_text(json.dumps({
    "provider": "ollama", "model": "deepseek-v4-flash:0731",
    "http_status": 200, "health_class": "healthy",
    "observed_at": now,
}), encoding="utf-8")
(ledger / "ollama__deepseek-v4-flash_0731.spawn-bench.json").write_text(
    json.dumps({"provider": "ollama", "model": "deepseek-v4-flash:0731",
                "usable_at": future, "failure_mode": "empty_run",
                "consecutive_failure_count": 3}), encoding="utf-8")

healthy, _ = m._read_seat()
assert healthy == 0, f"held spawn-bench must outrank a healthy sidecar (healthy={healthy})"
print("OK: _read_seat reports 0 for a spawn-bench-held seat with a healthy sidecar")

# Expired marker -> fail-open, the healthy observation stands.
(ledger / "ollama__deepseek-v4-flash_0731.spawn-bench.json").write_text(
    json.dumps({"provider": "ollama", "model": "deepseek-v4-flash:0731",
                "usable_at": past, "failure_mode": "empty_run"}), encoding="utf-8")
healthy, _ = m._read_seat()
assert healthy == 1, f"expired spawn-bench must not suppress healthy (healthy={healthy})"
print("OK: _read_seat reports 1 once the spawn-bench marker expires")

# A held marker on a DIFFERENT seat must not touch this seat's reading.
(ledger / "ollama__deepseek-v4-flash_0731.spawn-bench.json").unlink()
(ledger / "devin__glm-5-2.spawn-bench.json").write_text(
    json.dumps({"provider": "devin", "model": "glm-5-2",
                "usable_at": future, "failure_mode": "spawn_fail"}), encoding="utf-8")
healthy, _ = m._read_seat()
assert healthy == 1, f"another seat's bench must not suppress healthy (healthy={healthy})"
print("OK: _read_seat ignores a held marker for a different seat")
PY
ok "fleet-ops#3563: _read_seat overlays the spawn-bench marker — a benched seat never reads healthy"

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
# fleet-ops#2712: provider-level quota exhaustion alert — one billing wall,
# many seats. Pin that the rule name + expr are present in fleet_rules.yml.
grep -q "alert: FleetProviderQuotaExhausted" "$rules" \
  || fail "fleet_rules.yml missing FleetProviderQuotaExhausted (fleet-ops#2712)"
grep -q "fleet_provider_quota_exhausted_total > 0" "$rules" \
  || fail "provider-quota-exhausted rule must trip on fleet_provider_quota_exhausted_total > 0"
# fleet-ops#3284 (child of #3150): the money-boundary rule — current-UTC-day
# spend over USD 5 OR vendor credits remaining under USD 5, per provider.
# severity=warning routes to repair-dispatch; the description is the contract
# that carries the alert to nish-boundary-notify (MONEY-BOUNDARY write to
# NISH-ESCALATIONS.md) and benches the provider via the existing quota_bench
# path until Nish clears it. Pin the alert name, the expr, the severity, and
# the four load-bearing strings in the description so a later edit cannot
# silently drop the Nish route or the bench.
grep -q "alert: FleetProviderSpendBoundary" "$rules" \
  || fail "fleet_rules.yml missing FleetProviderSpendBoundary (fleet-ops#3284)"
grep -q "fleet_seat_spend_today_usd > 5 or fleet_seat_credits_remaining_usd < 5" "$rules" \
  || fail "spend-boundary rule must trip on fleet_seat_spend_today_usd > 5 OR fleet_seat_credits_remaining_usd < 5"
spend_block="$(awk '/- alert: FleetProviderSpendBoundary/,/- alert: FleetKeystoneRoutingAbsent/' "$rules")"
[[ -n "$spend_block" ]] || fail "could not extract FleetProviderSpendBoundary block"
grep -q "severity: warning" <<<"$spend_block" \
  || fail "FleetProviderSpendBoundary must be severity=warning (repair-dispatch route, not phone page)"
grep -q "MONEY-BOUNDARY" <<<"$spend_block" \
  || fail "FleetProviderSpendBoundary description must instruct a MONEY-BOUNDARY write"
grep -q "NISH-ESCALATIONS.md" <<<"$spend_block" \
  || fail "FleetProviderSpendBoundary description must name NISH-ESCALATIONS.md (the nish-boundary-notify path)"
grep -q "nish-boundary-notify" <<<"$spend_block" \
  || fail "FleetProviderSpendBoundary description must name nish-boundary-notify"
grep -q "quota_bench" <<<"$spend_block" \
  || fail "FleetProviderSpendBoundary description must route the provider bench through the quota_bench path"
grep -q "lanes/seats" <<<"$spend_block" \
  || fail "FleetProviderSpendBoundary description must name the seat ledger dir"
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

  # fleet-ops#2712: provider-level quota exhaustion alert. Pin that
  # (a) total=1 fires the alert within its for: 30m window, and
  # (b) total=0 stays silent (the natural state — no provider is account-
  # level quota exhausted). Two cases, one shape, mirror the queue-tripwire
  # test above.
  pqe_yml="$scratch/fleet-provider-quota-exhausted.test.yml"
  cat >"$pqe_yml" <<YOAML
rule_files:
  - $rules
evaluation_interval: 1m
tests:
  - interval: 1m
    name: provider-quota-exhausted fires when total>=1 (>=2 seats per provider)
    input_series:
      - series: 'fleet_provider_quota_exhausted_total'
        values: '1x40'
    alert_rule_test:
      - eval_time: 32m
        alertname: FleetProviderQuotaExhausted
        exp_alerts:
          - exp_labels:
              alertname: FleetProviderQuotaExhausted
              severity: warning
              service: fleet
            exp_annotations:
              summary: "provider-level quota exhaustion — one billing wall, multiple seats 402"
              description: "fleet-ops#2712: a provider has >=2 seats reporting HTTP 402/health_class=quota_exhausted within the last 1h. The per-provider fleet_provider_quota_exhausted{provider=\"...\"} series names the affected provider and its seat count; the seat-health ledger at /home/nish/workspaces/agent-state/lanes/seats lists each seat. This is ONE account-level billing wall, not N independent seat faults — triage the provider's quota/billing, not each seat separately. Until the billing wall clears the seat_availability SLO burn is expected (quota_exhausted seats are held unconditionally; see _SEAT_RELEASE_AT_EXPIRY_CLASSES in libexec/fleet-metrics-export.py)."
  - interval: 1m
    name: provider-quota-exhausted stays silent when total=0
    input_series:
      - series: 'fleet_provider_quota_exhausted_total'
        values: '0x40'
    alert_rule_test:
      - eval_time: 32m
        alertname: FleetProviderQuotaExhausted
        exp_alerts: []
YOAML
  if ! out="$(promtool test rules "$pqe_yml" 2>&1)"; then
    fail "promtool test rules exited non-zero on the provider-quota-exhausted test: $out"
  fi
  grep -q "SUCCESS" <<<"$out" \
    || fail "promtool test rules: provider-quota-exhausted must fire on total>=1 and stay silent on total=0 ($out)"
  ok "promtool test rules: provider-quota-exhausted fires on real burn (fleet-ops#2712)"

  # fleet-ops#3284: the money-boundary drill. Three cases:
  #   (a) spend leg — fleet_seat_spend_today_usd > 5 fires for that provider;
  #   (b) credits leg — fleet_seat_credits_remaining_usd < 5 fires;
  #   (c) quiet — spend 4 / credits 9 plus a stale day-labelled
  #       fleet_seat_spend_usd row at 99 (a >$5 day in the trailing window)
  #       must NOT fire: the rule must key on the day-less today copy, never
  #       on a day that aged out of "today".
# fleet-ops#4611: derive the expected annotations from the rule file itself.
# Hardcoding them meant any annotation edit (fleet-ops#4477 rewrote the
# spend-boundary repair text to point at bin/money-boundary-raise) left this
# fixture pinning the OLD wording, turning the suite red on main and blocking
# every PR that runs it. Deriving makes that drift class impossible.
sb_annotations() {
  PROVIDER="$1" RULES="$rules" python3 - <<'PYEOF'
import json, os, yaml
provider = os.environ["PROVIDER"]
doc = yaml.safe_load(open(os.environ["RULES"]))
for group in doc.get("groups", []):
    for rule in group.get("rules", []):
        if rule.get("alert") == "FleetProviderSpendBoundary":
            ann = rule.get("annotations", {})
            for key in ("summary", "description"):
                text = ann[key].replace("{{ $labels.provider }}", provider)
                print("              %s: %s" % (key, json.dumps(text)))
            raise SystemExit(0)
raise SystemExit("FleetProviderSpendBoundary alert not found in %s" % os.environ["RULES"])
PYEOF
}

  sb_yml="$scratch/fleet-spend-boundary.test.yml"
  cat >"$sb_yml" <<YOAML
rule_files:
  - $rules
evaluation_interval: 1m
tests:
  - interval: 1m
    name: spend boundary fires when a provider's today spend is over USD 5
    input_series:
      - series: 'fleet_seat_spend_today_usd{provider="openrouter"}'
        values: '6x10'
      - series: 'fleet_seat_credits_remaining_usd{provider="openrouter"}'
        values: '9x10'
    alert_rule_test:
      - eval_time: 8m
        alertname: FleetProviderSpendBoundary
        exp_alerts:
          - exp_labels:
              alertname: FleetProviderSpendBoundary
              provider: openrouter
              severity: warning
              service: fleet
            exp_annotations:
$(sb_annotations openrouter)
  - interval: 1m
    name: spend boundary fires when a provider's credits remaining is under USD 5
    input_series:
      - series: 'fleet_seat_spend_today_usd{provider="minimax"}'
        values: '1x10'
      - series: 'fleet_seat_credits_remaining_usd{provider="minimax"}'
        values: '4x10'
    alert_rule_test:
      - eval_time: 8m
        alertname: FleetProviderSpendBoundary
        exp_alerts:
          - exp_labels:
              alertname: FleetProviderSpendBoundary
              provider: minimax
              severity: warning
              service: fleet
            exp_annotations:
$(sb_annotations minimax)
  - interval: 1m
    name: spend boundary stays silent under both thresholds and on stale day rows
    input_series:
      - series: 'fleet_seat_spend_today_usd{provider="quietprov"}'
        values: '4x10'
      - series: 'fleet_seat_credits_remaining_usd{provider="quietprov"}'
        values: '9x10'
      - series: 'fleet_seat_spend_usd{provider="oldprov",day="2020-01-01"}'
        values: '99x10'
    alert_rule_test:
      - eval_time: 8m
        alertname: FleetProviderSpendBoundary
        exp_alerts: []
YOAML
  if ! out="$(promtool test rules "$sb_yml" 2>&1)"; then
    fail "promtool test rules exited non-zero on the spend-boundary test: $out"
  fi
  grep -q "SUCCESS" <<<"$out" \
    || fail "promtool test rules: spend-boundary must fire on each leg and stay silent under both ($out)"
  ok "promtool test rules: spend-boundary fires on each leg, silent under both, immune to stale day rows (fleet-ops#3284)"
fi
ok "fleet_rules.yml: absent heartbeat + 3 regression-trend rules + queue tripwire + provider quota"

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
# 9b. fleet-ops#3111: seat-health age is UTC-parsed, host-TZ independent.
# =========================================================================
# Regression gate (fleet-ops#3564): the exporter must never parse a UTC
# timestamp with time.mktime. On the +05:30 live host that local-time parse
# read every fresh observation exactly 19800s stale and re-armed
# FleetPiSeatHealthStale each tick after #3520 fixed only the console. A
# single `time.mktime(time.strptime(` reintroduction must fail CI loudly
# rather than silently re-arming the alert. Mirror of
# tests/fleet-console-pi-utc.test.sh.
! grep -q 'time.mktime(time.strptime(' "$exporter" \
  || fail "fleet-metrics-export.py must not parse UTC timestamps with time.mktime (local-time bug class #3520/#3562); use calendar.timegm"
grep -q 'calendar.timegm(time.strptime(' "$exporter" \
  || fail "fleet-metrics-export.py must parse UTC timestamps with calendar.timegm"
ok "fleet-ops#3564: exporter contains no time.mktime-on-strptime local-time parse"
# The 2026-09-03 transport incident left the console 'seat healthy' tile green
# on a 2-day-old pi-seat-health.json. The fix: exporter emits
# fleet_pi_seat_health_age_seconds (absent/unparseable -> -1) and the
# FleetPiSeatHealthStale rule fires >1800 (30 min) or == -1.
#
# The exporter's _read_seat must parse observed_at as UTC with
# calendar.timegm. time.mktime applies the HOST's local timezone: on this IST
# (+0530) host it reads every fresh UTC observation ~19800s (5.5h) stale and
# FleetPiSeatHealthStale false-fires on a healthy seat — the same mktime-on-UTC
# bug class #3520 fixed in the console but left here. Proved under TZ=Asia/Kolkata
# so the parse is pinned timezone-independent (mirrors tests/fleet-console-pi-utc.test.sh).
SEAT_HEALTH_OVERRIDE="$scratch/seat-health-age.json"
TZ=Asia/Kolkata python3 - "$exporter" "$SEAT_HEALTH_OVERRIDE" "$rules" <<'PY' || fail "seat-health age UTC parse failed"
import importlib.util, json, os, sys, tempfile, time, calendar
from pathlib import Path
exporter, seat_path, rules = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("fme", exporter)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# (a) Fresh healthy observation, 60s old, written in UTC. On an IST host the
#     old time.mktime read this as ~19800s stale; it must read as ~60s old.
fresh_ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 60))
json.dump({"health_class": "healthy", "provider": "devin",
           "model": "glm-5-2", "observed_at": fresh_ts},
          open(seat_path, "w"))
m.SEAT_HEALTH = Path(seat_path)
# fleet-ops#3563: _read_seat now overlays the wrapper spawn-bench marker —
# point SEAT_LEDGER at an empty dir so this TZ-parse test stays hermetic
# (the live ledger can hold a marker for the fixture seat, e.g.
# devin/glm-5-2 was spawn-bench-held on 2026-09-05 and this test failed
# until the override landed).
_empty_ledger = Path(tempfile.mkdtemp(prefix="seat-ledger-empty-"))
m.SEAT_LEDGER = _empty_ledger
true_epoch = calendar.timegm(time.strptime(
    fresh_ts.replace("Z", "+00:00")[:19], "%Y-%m-%dT%H:%M:%S"))
healthy, epoch = m._read_seat()
assert healthy == 1, f"health_class=healthy must read healthy=1, got {healthy}"
assert epoch == true_epoch, (
    f"_read_seat must parse observed_at as UTC epoch {true_epoch}, got {epoch}; "
    "time.mktime on an IST host reads a fresh observation ~19800s stale and "
    "false-fires FleetPiSeatHealthStale (fleet-ops#3111, #3520 console class)")
age = int(time.time()) - epoch
assert 0 <= age < 1800, (
    f"fresh observation age must be under the 1800s stale bound, got {age}; "
    "the mktime local-TZ bug reads this as ~19800")

# (b) Absent/unparseable file -> (0, None); the exporter emits age -1 (UNKNOWN).
m.SEAT_HEALTH = Path("/nonexistent/seat.json")
healthy, epoch = m._read_seat()
assert healthy == 0 and epoch is None, \
    f"absent file must read (0, None), got {(healthy, epoch)}"
assert "fleet-ops#3111" in m.HELP_AGE, \
    "seat-health AGE help text must cite fleet-ops#3111"

# (c) The alert rule firing >1800 / == -1 must be declared (accept criterion).
rules_txt = Path(rules).read_text()
assert "alert: FleetPiSeatHealthStale" in rules_txt, \
    "fleet_rules.yml missing alert: FleetPiSeatHealthStale"
assert "fleet_pi_seat_health_age_seconds == -1 or fleet_pi_seat_health_age_seconds > 1800" in rules_txt, \
    "fleet_rules.yml FleetPiSeatHealthStale must fire on age == -1 or > 1800"
os.unlink(seat_path)
print("OK: _read_seat parses observed_at as UTC (host-TZ independent); stale/absent -> UNKNOWN; >1800 rule present")
PY

# =========================================================================
# 9c. fleet-ops#3564: cap-stale reason-date age is TZ-independent too.
# =========================================================================
# #3520/#3562 converted every observed_at parse to calendar.timegm. The last
# remaining local-time parse in the exporter was the cap=0 stale reason date
# (_age_from_reason): on the +05:30 host time.mktime read a dated reason ~19800s
# older than it is on a UTC host, the same 19800s IST offset this issue names.
# Pin: the cap0-stale age must be identical under Asia/Kolkata and UTC.
CAPS_3564="$scratch/caps-3564.json"
python3 - "$exporter" "$CAPS_3564" <<'PY' || fail "cap-stale reason-date age is TZ-dependent (fleet-ops#3564)"
import importlib.util, json, os, sys, time
from pathlib import Path
# Generate the fixture in Python so the nested seat-caps structure is exact.
Path(sys.argv[2]).write_text(json.dumps({"providers": {"groq": {
    "cap": 0, "intentional_cap_zero": "stale",
    "reason": "2026-09-01 re-audition: endpoint 404",
    "models": {"groq-x": {
        "cap": 0, "intentional_cap_zero": "stale",
        "reason": "2026-09-01 re-audition: not probed"}}}}}), encoding="utf-8")
spec = importlib.util.spec_from_file_location("fme", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
caps = Path(sys.argv[2])
m.SEAT_CAPS_DEFAULT = caps
m.SEAT_CAPS_FALLBACK = Path("/nonexistent/caps.json")
m.SEAT_CAPS_LIVE = Path("/nonexistent/live-caps.json")  # hermetic: repo-checkouts path list only

def stale_age():
    n, seats = m._read_cap0_stale()
    assert n == 2 and len(seats) == 2, (n, seats)
    return [s["age_seconds"] for s in seats]

os.environ["TZ"] = "Asia/Kolkata"; time.tzset()
ist_ages = stale_age()
os.environ["TZ"] = "UTC"; time.tzset()
utc_ages = stale_age()
# time.mktime under +05:30 read the date ~19800s older than UTC; timegm is
# flat. Ages may differ by at most 1s (the int(time.time()) clock between the
# two calls), never 19800.
for a, b in zip(ist_ages, utc_ages):
    assert abs(a - b) <= 1, f"cap0 stale age is TZ-dependent: IST {a}s vs UTC {b}s (time.mktime offset ~19800s)"
print(f"OK: cap0 stale reason-date age TZ-independent (IST={ist_ages[0]}s UTC={utc_ages[0]}s)")
PY

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
#
# fleet-ops#2667 REGRESSION GUARD: the ledger also gets a CORPSE seat. Since
# fleet-ops#2327 the corpse escalation rewrites health_class to the terminal
# "corpse" while leaving failure_mode="credentials_bad", so a health_class-only
# match went blind on exactly the seats that had most earned the alert. Live
# 2026-09-02: commandcode/minimax-m3-free (403) and opencode/hy3-free (401)
# both sat seat_dead=true + failure_mode=credentials_bad + health_class=corpse
# while fleet_pi_seat_dead_credential_total read 0 and PiSeatDeadCredential
# could not fire. Four seats piled up unseen. The corpse fixture below fails
# against a health_class-only match and passes once EITHER field is read.
SEAT_LEDGER_OVERRIDE="$scratch/seed-dead"
mkdir -p "$SEAT_LEDGER_OVERRIDE"
cat >"$SEAT_LEDGER_OVERRIDE/xai-oauth__grok-4.5.json" <<'JSON'
{"provider":"xai-oauth","model":"grok-4.5","http_status":401,"health_class":"credentials_bad","seat_dead":true,"observed_at":"2026-08-29T06:30:53Z","source":"cli_spawn","failure_mode":"credentials_bad","usable_at":null,"retryable":false,"seat_dead":true}
JSON
# fleet-ops#2667: the terminal corpse shape, copied verbatim from the live
# ledger file opencode__hy3-free.json.
cat >"$SEAT_LEDGER_OVERRIDE/opencode__hy3-free.json" <<'JSON'
{"provider":"opencode","model":"hy3-free","http_status":401,"retry_after":null,"health_class":"corpse","retryable":false,"seat_dead":true,"poison_ladder":false,"observed_at":"2026-09-01T22:35:48.022Z","source":"provider_fetch","failure_mode":"credentials_bad","usable_at":null,"consecutive_failure_count":1}
JSON
# fleet-ops#2667: a corpse that is NOT a credential fault must stay OUT of the
# count. muse-spark died on repeated HTTP 500s (failure_mode=transient_http),
# so matching "seat_dead=true AND health_class==corpse" would over-count. The
# match must key on the credentials_bad signal, not on deadness alone.
cat >"$SEAT_LEDGER_OVERRIDE/opencode__muse-spark-1.2-contributor-free.json" <<'JSON'
{"provider":"opencode","model":"muse-spark-1.2-contributor-free","http_status":500,"health_class":"corpse","retryable":false,"seat_dead":true,"observed_at":"2026-08-30T09:02:18.000Z","source":"provider_fetch","failure_mode":"transient_http","usable_at":null,"consecutive_failure_count":150}
JSON
cat >"$SEAT_LEDGER_OVERRIDE/devin__glm-5-2.json" <<'JSON'
{"provider":"devin","model":"glm-5-2","health_class":"healthy","seat_dead":false,"observed_at":"2026-08-29T06:30:53Z"}
JSON
# fleet-ops#2667: a LIVE seat carrying a stale credentials_bad failure_mode but
# seat_dead=false must stay out of the count — seat_dead is still the gate.
cat >"$SEAT_LEDGER_OVERRIDE/bai__deepseek-v4-flash.json" <<'JSON'
{"provider":"bai","model":"deepseek-v4-flash","http_status":200,"health_class":"healthy","seat_dead":false,"observed_at":"2026-09-02T01:00:00.000Z","failure_mode":"credentials_bad","consecutive_failure_count":0}
JSON
# Hermetic seat-caps so _read_dead_credentials enrollment is deterministic
# (live config has hy3-free and grok-4.5 at cap=0; this fixture enrolls them
# so the #2667 corpse still counts). fleet-ops#3301 pins the cap=0 exclusion
# separately.
SEAT_CAPS_OVERRIDE="$scratch/seat-caps-deadcred.json"
cat >"$SEAT_CAPS_OVERRIDE" <<'JSON'
{"providers":{"xai-oauth":{"cap":1,"models":{"grok-4.5":1}},"opencode":{"cap":3,"models":{"hy3-free":1,"muse-spark-1.2-contributor-free":1}},"devin":{"cap":1,"models":{"glm-5-2":0}},"bai":{"cap":1,"models":{"deepseek-v4-flash":1}}}}
JSON

python3 - "$exporter" "$OUT_OVERRIDE" "$DETAIL_STUB" "$SM_CONFIG_OVERRIDE" "$SEAT_LEDGER_OVERRIDE" "$SEAT_CAPS_OVERRIDE" <<'PY' || fail "main() emission failed"
import importlib.util, json, os, sys, types
from pathlib import Path
exporter, out_path, detail_stub, sm_cfg, seat_ledger, seat_caps = sys.argv[1:7]
spec = importlib.util.spec_from_file_location("fme", exporter)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

m.OUT = Path(out_path)
m.SELF_MAINT_JSON_DEFAULT = Path(sm_cfg)
m.SELF_MAINT_JSON_FALLBACK = Path("/nonexistent/fb.json")
m.SEAT_HEALTH = Path("/nonexistent/seat.json")
m.SEAT_LEDGER = Path(seat_ledger)
m.SEAT_CAPS_DEFAULT = Path(seat_caps)
m.SEAT_CAPS_FALLBACK = Path("/nonexistent/seat-caps.json")
m.SEAT_CAPS_LIVE = Path("/nonexistent/live-caps.json")  # hermetic: repo-checkouts path list only
m.HC_URL_FILE = Path("/nonexistent/hc.url")
m.ACTIONS_LOG = Path("/nonexistent/actions.log")
m.MAINTENANCE_FLAG = Path("/nonexistent/maint.json")
m.INTAKE_JSON_DEFAULT = Path("/nonexistent/intake.json")
m.INTAKE_JSON_FALLBACK = Path("/nonexistent/intake2.json")
m.KEYSTONE_LEDGER = Path("/nonexistent/keystone.jsonl")
m.WORKTREE_REAPER_SUMMARY = Path("/nonexistent/reaper.json")
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
m._oomd_kills_6h = lambda: {}
m._repair_log_counts_24h = lambda: (0, 0)
m._worker_units = lambda: []
m._standalone_pi_print_count = lambda u: 0
m._maintenance_quiescing = lambda: 0
m._keystone_routing_counts = lambda: (0, 0, None)
m._ping_healthcheck = lambda: None
m._fetch_openrouter_credits = lambda: None
m._fetch_xkiro_usage = lambda: None
m._fetch_openrouter_key = lambda: None
m._fetch_claude_usage = lambda: None
m._fetch_codex_usage = lambda: None
m._fetch_cursor_usage = lambda: None
m._fetch_devin_usage = lambda: None
m._fetch_xkiro_quota = lambda: None
m._GH_FETCHED_THIS_RUN = False

m._fetch_signups_7d = lambda: None
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
assert "fleet_pi_seat_dead_credential_total 2" in body, body
assert '# HELP fleet_pi_seat_dead_credential_total' in body, body
assert '# TYPE fleet_pi_seat_dead_credential_total gauge' in body, body
assert '# HELP fleet_pi_seat_dead_credential ' in body, body
assert 'fleet_pi_seat_dead_credential{seat="xai-oauth__grok-4.5",http_status="401",health_class="credentials_bad"} 1' in body, body
# fleet-ops#2667: the corpse seat is counted, and its health_class label says
# "corpse" so the reader knows re-auth cannot help and the row must be retired.
assert 'fleet_pi_seat_dead_credential{seat="opencode__hy3-free",http_status="401",health_class="corpse"} 1' in body, body
# fleet-ops#2667: neither the non-credential corpse nor the live seat with a
# stale failure_mode may be counted. Pin the dead-credential SERIES, not the
# whole body — fleet_seat_yield also names muse-spark (live sessions).
assert 'fleet_pi_seat_dead_credential{seat="opencode__muse-spark-1.2-contributor-free"' not in body, body
assert 'fleet_pi_seat_dead_credential{seat="bai__deepseek-v4-flash"' not in body, body
# fleet-ops#2738: the healthy devin/glm-5-2 seed ledger legitimately appears
# in the new fleet_seat_healthy_cap0 series (it is healthy + cap 0 in the
# real repo config). The dead-credential intent is that it does not appear
# in the dead-credential SERIES — pin that series specifically, not the
# whole body, so the healthy_cap0 metric can surface the parked seat.
assert 'fleet_pi_seat_dead_credential{seat="devin__glm-5-2"' not in body, "healthy seat must not appear in dead-credential series: " + body
print("OK: main() emits self-maintenance + quality + verified-merges families")
PY

# 10b. fleet-ops#4643: main() emits fleet_prompt_cache_hit_ratio from session
# jsonl usage (cacheRead vs uncached input), per provider x packet_type, with
# the issue's metered/free class label. A synthetic sessions dir carries one
# pi-issue worker session (cached) and one scout session (uncached) so the
# emitter produces two rows with the right ratio and class.
echo "=== 10b. fleet-ops#4643 cache-hit ratio emission ==="
CACHE_SESSIONS="$scratch/cache-sessions"
mkdir -p "$CACHE_SESSIONS/pi-issue-fleet-ops-1" "$CACHE_SESSIONS/pi-scout-foo"
# Worker session: provider=paretoinference (metered in seat-caps), 100 uncached
# input + 900 cacheRead -> ratio 0.9. Pi session jsonl shape: a model_change
# line sets the provider, then message lines carry usage.
cat >"$CACHE_SESSIONS/pi-issue-fleet-ops-1/sess.jsonl" <<'JSON'
{"type":"model_change","provider":"paretoinference"}
{"type":"message","message":{"provider":"paretoinference","usage":{"input":100,"cacheRead":900,"output":5}}}
{"type":"message","message":{"provider":"paretoinference","usage":{"input":0,"cacheRead":0,"output":0}}}
JSON
# Scout session: provider=cline (metered), 1000 uncached + 0 cacheRead -> 0.0.
cat >"$CACHE_SESSIONS/pi-scout-foo/sess.jsonl" <<'JSON'
{"type":"model_change","provider":"cline"}
{"type":"message","message":{"provider":"cline","usage":{"input":1000,"cacheRead":0,"output":10}}}
JSON
CACHE_OUT="$scratch/cache-out.prom"
# Use the REAL repo seat-caps so the metered/free class resolves for
# paretoinference and cline (the dead-credential fixture above does not
# enroll them). The cache-hit emitter reads class from seat-caps.
REAL_SEAT_CAPS="$repo_root/config/seat-caps.json"
[[ -f "$REAL_SEAT_CAPS" ]] || fail "real seat-caps not found: $REAL_SEAT_CAPS"
python3 - "$exporter" "$CACHE_OUT" "$CACHE_SESSIONS" "$REAL_SEAT_CAPS" <<'PY' || fail "cache-hit emission failed"
import importlib.util, os, sys
from pathlib import Path
exporter, out_path, sessions, seat_caps = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("fme2", exporter)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.OUT = Path(out_path)
m.SESSIONS_DIR = Path(sessions)
m.SEAT_CAPS_DEFAULT = Path(seat_caps)
m.SEAT_CAPS_FALLBACK = Path("/nonexistent/fb.json")
m.SEAT_CAPS_LIVE = Path("/nonexistent/live.json")
m.SELF_MAINT_JSON_DEFAULT = Path("/nonexistent/sm.json")
m.SELF_MAINT_JSON_FALLBACK = Path("/nonexistent/sm2.json")
m.SEAT_HEALTH = Path("/nonexistent/seat.json")
m.SEAT_LEDGER = Path("/nonexistent/ledger")
m.HC_URL_FILE = Path("/nonexistent/hc.url")
m.ACTIONS_LOG = Path("/nonexistent/actions.log")
m.MAINTENANCE_FLAG = Path("/nonexistent/maint.json")
m.INTAKE_JSON_DEFAULT = Path("/nonexistent/intake.json")
m.INTAKE_JSON_FALLBACK = Path("/nonexistent/intake2.json")
m.KEYSTONE_LEDGER = Path("/nonexistent/keystone.jsonl")
m.WORKTREE_REAPER_SUMMARY = Path("/nonexistent/reaper.json")
m.STALENESS_CACHE = Path("/nonexistent/stale.json")
m.PR_CACHE_DIR = Path(os.path.dirname(out_path))
m.DETAIL_CACHE = Path(os.path.dirname(out_path)) / "detail.cache.json"
m._list_timers = lambda: [{"unit": "fleet-metrics-export.timer", "last_usec": 0}]
m._timer_active = lambda unit: 1
m._read_seat = lambda: (1, 0)
m._merged_prs_detail = lambda: []
m._repo_snapshot = lambda: None
m._queue_composition = lambda: {"ready-work": {"total": 0, "self": 0}, "agent-ready": {"total": 0, "self": 0}}
m._escalations_24h = lambda: {}
m._oomd_kills_6h = lambda: {}
m._repair_log_counts_24h = lambda: (0, 0)
m._worker_units = lambda: []
m._standalone_pi_print_count = lambda u: 0
m._maintenance_quiescing = lambda: 0
m._keystone_routing_counts = lambda: (0, 0, None)
m._ping_healthcheck = lambda: None
m._fetch_openrouter_credits = lambda: None
m._fetch_xkiro_usage = lambda: None
m._fetch_openrouter_key = lambda: None
m._fetch_claude_usage = lambda: None
m._fetch_codex_usage = lambda: None
m._fetch_cursor_usage = lambda: None
m._fetch_devin_usage = lambda: None
m._fetch_xkiro_quota = lambda: None
m._fetch_signups_7d = lambda: None
m._GH_FETCHED_THIS_RUN = False
rc = m.main()
assert rc == 0, f"main rc={rc}"
body = Path(out_path).read_text()
assert "# HELP fleet_prompt_cache_hit_ratio" in body, "missing HELP for cache-hit ratio:\n" + body
assert "# TYPE fleet_prompt_cache_hit_ratio gauge" in body, "missing TYPE for cache-hit ratio:\n" + body
# Worker row: 900/(100+900) = 0.9, class metered (paretoinference is metered).
assert 'fleet_prompt_cache_hit_ratio{provider="paretoinference",packet_type="worker",class="metered"} 0.900000' in body, body
# Scout row: 0/(1000+0) = 0.0, class metered (cline is metered).
assert 'fleet_prompt_cache_hit_ratio{provider="cline",packet_type="scout",class="metered"} 0.000000' in body, body
print("OK: main() emits fleet_prompt_cache_hit_ratio{provider,packet_type,class}")
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
m.WORKTREE_REAPER_SUMMARY = Path("/nonexistent/reaper.json")
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
m._oomd_kills_6h = lambda: {}
m._repair_log_counts_24h = lambda: (0, 0)
m._worker_units = lambda: []
m._standalone_pi_print_count = lambda u: 0
m._maintenance_quiescing = lambda: 0
m._keystone_routing_counts = lambda: (0, 0, None)
m._gh_rate_limit = lambda: None
m._read_dead_credentials = lambda: (0, [])
m._ping_healthcheck = lambda: None
m._fetch_openrouter_credits = lambda: None
m._fetch_xkiro_usage = lambda: None
m._fetch_openrouter_key = lambda: None
m._fetch_claude_usage = lambda: None
m._fetch_codex_usage = lambda: None
m._fetch_cursor_usage = lambda: None
m._fetch_xkiro_quota = lambda: None
m._GH_FETCHED_THIS_RUN = False

m._fetch_signups_7d = lambda: None
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
m.WORKTREE_REAPER_SUMMARY = Path("/nonexistent/reaper.json")
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
m._oomd_kills_6h = lambda: {}
m._repair_log_counts_24h = lambda: (0, 0)
m._worker_units = lambda: []
m._standalone_pi_print_count = lambda u: 0
m._maintenance_quiescing = lambda: 0
m._keystone_routing_counts = lambda: (0, 0, None)
m._gh_rate_limit = lambda: None
m._read_dead_credentials = lambda: (0, [])
m._ping_healthcheck = lambda: None
m._fetch_openrouter_credits = lambda: None
m._fetch_xkiro_usage = lambda: None
m._fetch_openrouter_key = lambda: None
m._fetch_claude_usage = lambda: None
m._fetch_codex_usage = lambda: None
m._fetch_cursor_usage = lambda: None
m._fetch_xkiro_quota = lambda: None
m._GH_FETCHED_THIS_RUN = False

m._fetch_signups_7d = lambda: None
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
m.WORKTREE_REAPER_SUMMARY = Path("/nonexistent/reaper.json")
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
m._oomd_kills_6h = lambda: {}
m._repair_log_counts_24h = lambda: (0, 0)
m._worker_units = lambda: []
m._standalone_pi_print_count = lambda u: 0
m._maintenance_quiescing = lambda: 0
m._keystone_routing_counts = lambda: (0, 0, None)
m._gh_rate_limit = lambda: None
m._read_dead_credentials = lambda: (0, [])
m._ping_healthcheck = lambda: None
m._fetch_openrouter_credits = lambda: None
m._fetch_xkiro_usage = lambda: None
m._fetch_openrouter_key = lambda: None
m._fetch_claude_usage = lambda: None
m._fetch_codex_usage = lambda: None
m._fetch_cursor_usage = lambda: None
m._fetch_xkiro_quota = lambda: None
m._GH_FETCHED_THIS_RUN = False

m._fetch_signups_7d = lambda: None
rc = m.main()
assert rc == 1, f"main() must fail loud on null ready_work (rc={rc})"
assert not Path(out_path).exists(), "no fleet.prom on fail-loud"
assert not Path(legacy).exists(), "legacy fleet-staleness.prom must be cleaned up"
print("OK: legacy fleet-staleness.prom removed on fail-loud export")

m._fetch_signups_7d = lambda: None
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
    # 4. rate_limited with EXPIRED wall -> RELEASED. Carries cfc=15 (in the
    #    [10, 25) never-released window) so the phantom-key test below proves a
    #    real engaged seat still counts while the phantom is excluded.
    "opencode__mimo-v2.5-free.json": {
        "provider": "opencode", "model": "mimo-v2.5-free",
        "http_status": 429, "health_class": "rate_limited", "seat_dead": False,
        "usable_at": PAST, "bench_until": None, "consecutive_failure_count": 15,
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
    # 8. fleet-ops#2806: a wall passed only 300s ago (inside the one-probe-
    #    interval grace, COMEBACK_OVERDUE_GRACE_S=900) is MID-CYCLE — the
    #    releaser re-probes it on the next 15-min tick (re-anchor or
    #    unwall), so it must NOT count as comeback-overdue. Only a wall
    #    past by more than one probe interval is overdue.
    "opencode__nemotron-3-ultra-free.json": {
        "provider": "opencode", "model": "nemotron-3-ultra-free",
        "http_status": 429, "health_class": "rate_limited", "seat_dead": False,
        "usable_at": iso(-300), "bench_until": None,
    },
    # 9. fleet-ops#3661: a PHANTOM seat key (provider/model NOT an
    #    allowlisted seat-caps.json models key) past its wall clock, with a
    #    high consecutive_failure_count. Comeback-release skips it with the
    #    SEAT-KEY-INVALID guard, so it can never be unwalled by the organ and
    #    must NOT count as overdue or never-released — otherwise the
    #    seat-comeback alerts fire indefinitely until a worker manually
    #    retires the phantom (the lived openrouter/deepseek-v4-pro-0813 case,
    #    retired 2026-09-06 via alert-repair).
    "opencode__phantom-gone-free.json": {
        "provider": "opencode", "model": "phantom-gone-free",
        "http_status": 429, "health_class": "rate_limited", "seat_dead": False,
        "usable_at": PAST, "bench_until": None, "consecutive_failure_count": 15,
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
# Wire seat-caps BEFORE the comeback collectors so the fleet-ops#3661
# phantom-key guard reads the scratch config deterministically — CI has no
# /home/nish/... paths, and fail-open on a missing config would leak the
# phantom into the counts (catching the real default path only locally).
m.SEAT_CAPS_DEFAULT = Path(seat_caps)
m.SEAT_CAPS_FALLBACK = Path(seat_caps)
m.SEAT_CAPS_LIVE = Path("/nonexistent/live-caps.json")  # hermetic: repo-checkouts path list only
cb_n, cb = m._read_comeback_overdue()
ids = {f"{s['provider']}__{s['model']}" for s in cb}
# Past-wall non-dead non-excluded seats: commandcode minimax (overload past
# 1h), minimax MiniMax-M3 (quota past 1h), opencode mimo (rate_limited past
# 1h) = 3. opencode nemotron (past only 300s) is inside the one-interval
# grace (fleet-ops#2806) and must NOT count as overdue.
assert cb_n == 3, f"comeback_overdue_n must be 3, got {cb_n} (ids={ids})"
assert {"commandcode__minimax/minimax-m3-free", "minimax__MiniMax-M3", "opencode__mimo-v2.5-free"} <= ids, ids
assert not any(i.startswith("opencode__nemotron") for i in ids), (
    f"mid-cycle seat (past by 300s < grace 900s) must NOT be overdue: {ids}"
)
assert not any("grok-4.5" in i for i in ids), "spawn-bench leaked into comeback"
assert not any(i.startswith("test__") for i in ids), "test__ leaked into comeback"
assert not any("muse-spark" in i for i in ids), "corpse leaked into comeback"
# A phantom seat key (not in seat-caps.json models) must be excluded even when
# its wall is expired (fleet-ops#3661 SEAT-KEY-INVALID consistency).
assert not any("phantom-gone-free" in i for i in ids), \
    "phantom seat key leaked into comeback-overdue"
print("OK: _read_comeback_overdue counts past-wall seats, excludes bench/test/corpse/mid-cycle + phantom keys")

# --- _read_never_released over the scratch ledger ---
# The phantom fixture has cfc=15 (inside the [10, 25) never-released window) as
# a non-corpse non-healthy seat past its wall. With the fleet-ops#3661
# consistency guard it must be excluded even though every window condition
# (fc count, wall passed, non-corpse) would otherwise count it — comeback-_
# release can never unwind a phantom, so it is not a live comeback signal.
nr_n, nr = m._read_never_released()
nr_ids = {f"{s['provider']}__{s['model']}" for s in nr}
# opencode/mimo-v2.5-free (cfc=15, past wall, valid caps key) must still count;
# the phantom (cfc=15, past wall, NOT a valid caps key) must be excluded even
# though every window condition would otherwise count it — comeback-release can
# never unwind a phantom, so it is not a live comeback signal.
assert nr_n == 1, f"never_released_n must be 1 (mimo only), got {nr_n}: {nr_ids}"
assert {"opencode__mimo-v2.5-free"} <= nr_ids, nr_ids
assert not any("phantom-gone-free" in i for i in nr_ids), \
    f"phantom seat key leaked into never-released (got {nr_ids})"
print("OK: _read_never_released excludes phantom seat keys, keeps real engaged seats (SEAT-KEY-INVALID consistency)")

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
m.SEAT_CAPS_LIVE = Path("/nonexistent/live-caps.json")  # hermetic: repo-checkouts path list only
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


# =========================================================================
# 16. fleet-ops#2738: healthy-but-parked seat visibility metric.
#     A seat whose ledger is healthy (health_class=healthy, seat_dead=false)
#     but whose model cap in seat-caps.json is 0 is silently costing
#     throughput — pick_seat skips it every tick while the seat-availability
#     SLO burns. The devin/glm-5-2 restore lapsed this way (ledger healthy,
#     cap 0 for 3+ days, no metric surfaced it). _read_healthy_cap0 must
#     count exactly those seats: a healthy ledger + cap-0 config -> 1;
#     a cap-restored config -> 0. Hermetic: scratch seat-caps + scratch
#     ledger, no live state.
# =========================================================================
HC0_SEATS="$scratch/hc0-seats"
mkdir -p "$HC0_SEATS"
HC0_CAPS_CAP0="$scratch/hc0-caps-cap0.json"
HC0_CAPS_CAP3="$scratch/hc0-caps-cap3.json"
cat >"$HC0_CAPS_CAP0" <<'JSON'
{
  "providers": {
    "devin": { "cap": 4, "class": "prepaid-quota", "models": { "glm-5-2": 0, "swe-1-7": 0 } },
    "ollama": { "cap": 2, "class": "free", "models": { "deepseek-v4-flash:0731": 2 } }
  }
}
JSON
cat >"$HC0_CAPS_CAP3" <<'JSON'
{
  "providers": {
    "devin": { "cap": 4, "class": "prepaid-quota", "models": { "glm-5-2": 3, "swe-1-7": 0 } },
    "ollama": { "cap": 2, "class": "free", "models": { "deepseek-v4-flash:0731": 2 } }
  }
}
JSON
# Healthy devin/glm-5-2 ledger (the restored seat) + a healthy cap>0 ollama
# seat (must NOT count) + a seat_dead=true devin/swe-1-7 (must NOT count) +
# a non-healthy commandcode seat (must NOT count) + a test__ fixture (must
# NOT count) + a .spawn-bench marker (must NOT count).
cat >"$HC0_SEATS/devin__glm-5-2.json" <<'JSON'
{"provider":"devin","model":"glm-5-2","health_class":"healthy","seat_dead":false,"http_status":200,"observed_at":"2026-09-02T17:00:58Z"}
JSON
cat >"$HC0_SEATS/ollama__deepseek-v4-flash_0731.json" <<'JSON'
{"provider":"ollama","model":"deepseek-v4-flash:0731","health_class":"healthy","seat_dead":false,"http_status":200,"observed_at":"2026-09-02T17:00:58Z"}
JSON
cat >"$HC0_SEATS/devin__swe-1-7.json" <<'JSON'
{"provider":"devin","model":"swe-1-7","health_class":"corpse","seat_dead":true,"http_status":403,"observed_at":"2026-08-30T03:05:36Z"}
JSON
cat >"$HC0_SEATS/commandcode__deepseek_deepseek-v4-flash.json" <<'JSON'
{"provider":"commandcode","model":"deepseek/deepseek-v4-flash","health_class":"overload_bench","seat_dead":false,"http_status":503,"observed_at":"2026-09-02T17:00:58Z"}
JSON
cat >"$HC0_SEATS/test__synthetic.json" <<'JSON'
{"provider":"test","model":"synthetic","health_class":"healthy","seat_dead":false,"http_status":200,"observed_at":"2026-09-02T17:00:58Z"}
JSON
cat >"$HC0_SEATS/opencode__mimo-v2.5-free.spawn-bench.json" <<'JSON'
{"provider":"opencode","model":"mimo-v2.5-free","usable_at":"2099-01-01T00:00:00Z","reason":"no_block:rc=0"}
JSON

python3 - "$exporter" "$HC0_CAPS_CAP0" "$HC0_CAPS_CAP3" "$HC0_SEATS" <<'PY' || fail "healthy-cap0 metric test failed"
import importlib.util, json, sys
from pathlib import Path

exporter, caps_cap0, caps_cap3, seat_dir = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("fme", exporter)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# --- cap-0 config: the healthy devin/glm-5-2 ledger is parked -> count 1 ---
m.SEAT_CAPS_DEFAULT = Path(caps_cap0)
m.SEAT_CAPS_FALLBACK = Path(caps_cap0)
m.SEAT_CAPS_LIVE = Path("/nonexistent/live-caps.json")  # hermetic: repo-checkouts path list only
m.SEAT_LEDGER = Path(seat_dir)
n0, seats0 = m._read_healthy_cap0()
ids0 = {f"{s['provider']}__{s['model']}" for s in seats0}
assert n0 == 1, f"cap0 config: healthy-cap0 must be 1 (only devin/glm-5-2), got {n0}: {ids0}"
assert "devin__glm-5-2" in ids0, f"devin/glm-5-2 must be the parked seat, got {ids0}"
# The cap>0 ollama seat must NOT count.
assert not any("ollama" in i for i in ids0), "cap>0 ollama must not count as parked"
# The corpse / non-healthy / test / spawn-bench seats must NOT count.
assert not any("swe-1-7" in i for i in ids0), "seat_dead corpse must not count"
assert not any("commandcode" in i for i in ids0), "non-healthy seat must not count"
assert not any(i.startswith("test__") for i in ids0), "test__ fixture must not count"
assert not any("spawn-bench" in i for i in ids0), "spawn-bench marker must not count"
print("OK: cap0 config -> healthy-cap0_total 1 (devin/glm-5-2 parked)")

# --- cap-restored config: glm-5-2 cap 3 -> count 0 (no healthy-parked) ---
m.SEAT_CAPS_DEFAULT = Path(caps_cap3)
m.SEAT_CAPS_FALLBACK = Path(caps_cap3)
m.SEAT_CAPS_LIVE = Path("/nonexistent/live-caps.json")  # hermetic: repo-checkouts path list only
n3, seats3 = m._read_healthy_cap0()
assert n3 == 0, f"cap3 config: healthy-cap0 must be 0 (glm-5-2 restored), got {n3}: {seats3}"
print("OK: cap-restored config -> healthy-cap0_total 0 (restore cleared the alarm)")

# --- missing config -> fail safe to 0 (no false alarm from a missing file) ---
m.SEAT_CAPS_DEFAULT = Path("/nonexistent/hc0-caps.json")
m.SEAT_CAPS_FALLBACK = Path("/nonexistent/hc0-caps-fallback.json")
m.SEAT_CAPS_LIVE = Path("/nonexistent/live-caps.json")  # hermetic: repo-checkouts path list only
n_miss, _ = m._read_healthy_cap0()
assert n_miss == 0, f"missing config must fail safe to 0, got {n_miss}"
print("OK: missing config -> healthy-cap0_total 0 (fail safe)")

# --- model-cap map parses both bare-int and {cap,class} object values ---
m.SEAT_CAPS_DEFAULT = Path(caps_cap0)
m.SEAT_CAPS_FALLBACK = Path(caps_cap0)
m.SEAT_CAPS_LIVE = Path("/nonexistent/live-caps.json")  # hermetic: repo-checkouts path list only
caps = m._seat_caps_model_cap_map()
assert caps["devin/glm-5-2"] == 0, caps
assert caps["devin/swe-1-7"] == 0, caps
assert caps["ollama/deepseek-v4-flash:0731"] == 2, caps
# Unlisted model defaults to 0 (mirrors seat-lib model_cap).
assert caps.get("devin/unlisted-model", 0) == 0, caps
print("OK: _seat_caps_model_cap_map parses int + object + unlisted->0")
PY

# =========================================================================
# 16b. fleet-ops#2738: main() emits the healthy-cap0 family (HELP/TYPE once,
#      total gauge, per-seat series) end-to-end. Reuses the cap-0 fixture
#      so the per-seat series names devin/glm-5-2.
# =========================================================================
OUT_OVERRIDE="$scratch/hc0-out.prom"
DETAIL_STUB="$scratch/hc0-detail-stub.json"
echo '{"items":[]}' >"$DETAIL_STUB"
python3 - "$exporter" "$OUT_OVERRIDE" "$DETAIL_STUB" "$SM_CONFIG_OVERRIDE" "$HC0_CAPS_CAP0" "$HC0_SEATS" <<'PY' || fail "main() healthy-cap0 emission failed"
import importlib.util, json, sys
from pathlib import Path

exporter, out, detail, sm_cfg, caps_cap0, seat_dir = sys.argv[1:7]
spec = importlib.util.spec_from_file_location("fme", exporter)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

m.OUT = Path(out)
m.SELF_MAINT_JSON_DEFAULT = Path(sm_cfg)
m.SELF_MAINT_JSON_FALLBACK = Path("/nonexistent/sm-fallback.json")
m.SEAT_CAPS_DEFAULT = Path(caps_cap0)
m.SEAT_CAPS_FALLBACK = Path(caps_cap0)
m.SEAT_CAPS_LIVE = Path("/nonexistent/live-caps.json")  # hermetic: repo-checkouts path list only
m.SEAT_LEDGER = Path(seat_dir)
m.PR_CACHE_DIR = Path(out).parent
m.DETAIL_CACHE = Path(out).parent / "detail.cache.json"
m.SEAT_HEALTH = Path("/nonexistent/seat.json")
m.HC_URL_FILE = Path("/nonexistent/hc.url")
m.ACTIONS_LOG = Path("/nonexistent/actions.log")
m.MAINTENANCE_FLAG = Path("/nonexistent/maint.json")
m.INTAKE_JSON_DEFAULT = Path("/nonexistent/intake.json")
m.INTAKE_JSON_FALLBACK = Path("/nonexistent/intake2.json")
m.KEYSTONE_LEDGER = Path("/nonexistent/keystone.jsonl")
m.WORKTREE_REAPER_SUMMARY = Path("/nonexistent/reaper.json")
m.STALENESS_CACHE = Path("/nonexistent/stale.json")
# Stub network/gh/systemctl-dependent paths so main() runs offline.
# fleet-ops#2797: _queue_composition MUST be assigned. main() fail-louds
# (rc=1, no file) when gh cannot determine ready_work. GitHub Actions has
# no GH_TOKEN, so an unstubbed call never writes hc0-out.prom
# (run 33662529423: FileNotFoundError). Swallowing SystemExit hid the rc=1.
m._list_timers = lambda: [{"unit": "fleet-metrics-export.timer", "last_usec": 0}]
m._timer_active = lambda unit: 1
m._read_seat = lambda: (1, 0)
m._merged_prs_detail = lambda: None
m._repo_snapshot = lambda: None
m._queue_composition = lambda: {
    "ready-work": {"total": 5, "self": 1},
    "agent-ready": {"total": 6, "self": 2},
}
m._escalations_24h = lambda: {}
m._oomd_kills_6h = lambda: {}
m._repair_log_counts_24h = lambda: (0, 0)
m._worker_units = lambda: []
m._standalone_pi_print_count = lambda u: 0
m._maintenance_quiescing = lambda: 0
m._keystone_routing_counts = lambda: (0, 0, None)
m._gh_rate_limit = lambda: None
m._read_dead_credentials = lambda: (0, [])
m._healthy_enrolled_seat_count = lambda: 0
m._enrolled_seat_total = lambda: 0
m._read_comeback_overdue = lambda: (0, [])
m._read_never_released = lambda: (0, [])
m._read_provider_quota_exhausted = lambda: (0, [])
m._ping_healthcheck = lambda: None
m._fetch_openrouter_credits = lambda: None
m._fetch_xkiro_usage = lambda: None
m._fetch_openrouter_key = lambda: None
m._fetch_claude_usage = lambda: None
m._fetch_codex_usage = lambda: None
m._fetch_cursor_usage = lambda: None
m._fetch_xkiro_quota = lambda: None
m._GH_FETCHED_THIS_RUN = False
m._fetch_signups_7d = lambda: None
rc = m.main()
assert rc == 0, f"main rc={rc}"
body = Path(out).read_text()
assert "# HELP fleet_seat_healthy_cap0_total " in body, body
assert "# TYPE fleet_seat_healthy_cap0_total gauge" in body, body
assert "fleet_seat_healthy_cap0_total 1" in body, body
assert "# HELP fleet_seat_healthy_cap0 " in body, body
assert "# TYPE fleet_seat_healthy_cap0 gauge" in body, body
assert 'fleet_seat_healthy_cap0{seat="devin__glm-5-2"} 1' in body, body
# HELP/TYPE appear exactly once per metric name (fleet-ops#1844/#1855 class).
assert body.count("# HELP fleet_seat_healthy_cap0_total ") == 1, body
assert body.count("# TYPE fleet_seat_healthy_cap0_total gauge") == 1, body
assert body.count("# HELP fleet_seat_healthy_cap0 ") == 1, body
print("OK: main() emits healthy-cap0 family (total 1 + per-seat devin__glm-5-2, HELP/TYPE once)")
PY

# =========================================================================
# 16c. fleet-ops#2797: every python heredoc that calls exporter main() must
#      assign _queue_composition. main() refuse-writes fleet.prom when
#      ready_work is null (fleet-ops#1772). GitHub Actions has no GH_TOKEN,
#      so an unstubbed call is FileNotFoundError on the output path — live
#      red on main since 16b landed in #2870 (run 33662529423). Scan the
#      tests tree so a sibling cannot regress the class. Needles are split
#      so this heredoc is not itself a match.
# =========================================================================
python3 - "$here" <<'PY' || fail "main() _queue_composition stub scan failed"
import pathlib, sys

main_call = "m" + ".main("
stub = "_queue" + "_composition"
root = pathlib.Path(sys.argv[1])


def python_heredocs(path):
    lines = path.read_text().splitlines()
    blocks = []
    i = 0
    n = len(lines)
    while i < n:
        if "<<'PY'" in lines[i] or '<<"PY"' in lines[i]:
            body = []
            i += 1
            while i < n and lines[i] != "PY":
                body.append(lines[i])
                i += 1
            blocks.append((path, i, "\n".join(body)))
        i += 1
    return blocks

fail = 0
seen = 0
for path in sorted(root.glob("*.sh")):
    for _path, end_line, block in python_heredocs(path):
        if main_call not in block:
            continue
        seen += 1
        if stub not in block:
            print(
                f"FAIL: {path.name} python-heredoc ending L{end_line} calls "
                f"exporter main() without assigning _queue_composition "
                f"(fleet-ops#2797 / run 33662529423)",
                file=sys.stderr,
            )
            fail = 1
        else:
            print(f"OK: {path.name} python-heredoc ending L{end_line} stubs _queue_composition")
assert seen >= 1, "scanner must see at least one exporter main() heredoc"
sys.exit(fail)
PY
ok "every exporter main() python-heredoc stubs _queue_composition (fleet-ops#2797)"


# fleet-ops#1350: GitHub API rate-limit metrics + pi-intake sidecar.
bash "$here/fleet-gh-rate-limit.test.sh" || fail "fleet-gh-rate-limit tests failed"

# fleet-ops#2690: console tile shipped_24h disputed. Locks the two-source
# fix (exporter GraphQL query pushes merged:>={cutoff} sort:merged-desc into
# the search itself; verify.py skips the Prom re-query when the textfile
# mtime advanced past tile.observed_at). Hosted here because
# fleet-metrics-export.test.sh is directly listed in ci.yml (P14 runs it
# without a workflow-file edit; the worker App cannot push
# .github/workflows/**).
bash "$here/console-shipped-24h-race.test.sh" || fail "console-shipped-24h-race tests failed"

# fleet-ops#4459: rate-card USD spend rail (measure.sh usd_24h line, the shared
# lib/fleet_usd.py math, and the fleet_usd_24h / fleet_usd_per_merged_pr prom
# family the exporter emits). Hosted here because fleet-metrics-export.test.sh
# is directly listed in ci.yml and the worker App cannot push
# .github/workflows/** (P14 hosting rule, fleet-ops#4459).
bash "$here/fleet-usd-spend.test.sh" || fail "fleet-usd-spend tests failed"
# fleet-ops#4476 (part 3): the measure.sh `questions:` line (for-nish /
# oldest / in-conference / unfiled) + the unfiled detector that auto-files a
# `question` issue for an out-of-store "Nish, should we…?" line. Hosted here
# for the same P14 reason as fleet-usd-spend above (no workflow-scope edit).
bash "$here/fleet-questions-line.test.sh" || fail "fleet-questions-line tests failed"
# fleet-ops#4566: measure.sh usd_24h cursor_today traceable to Cursor's own
# GetCurrentPeriodUsage api-bucket figure (via prepaid-spend/cursor.json), never
# a fabricated 0.000000. Hosted here for the same P14 reason as fleet-usd-spend
# above (no workflow-scope edit; the worker App cannot push .github/workflows/**).
bash "$here/measure-cursor-today.test.sh" || fail "measure-cursor-today tests failed"

# fleet-ops#5514 (0509#2975 item 4): the `deploy:` freshness line measure.sh
# prints verbatim from 0509's scripts/deploy-age.mjs, plus the LOUD
# deploy-stale line when merges_since>0 and last_success_age_h>=6. Hosted
# here for the same P14 reason as fleet-usd-spend above (no workflow-scope
# edit; fake detectors via FLEET_DEPLOY_AGE_SCRIPT).
bash "$here/measure-deploy-age.test.sh" || fail "measure-deploy-age tests failed"

# fleet-ops#4562: the stale-question detector (question+priority with no
# decision-resolved after 24h fails loud and auto-files once, deduped).
# Hosted here so P14 runs it without a workflow-file edit. Hermetic (fake gh).
bash "$here/fleet-questions-stale.test.sh" || fail "fleet-questions-stale tests failed"

# fleet-ops#5417: the outside-in `visitor:` probe (https redirect, edge
# cache, manifest, duplicate routes, public-repo leaks) the judges read
# right after product:. Hosted here for the same P14 reason as
# fleet-usd-spend above (no workflow-scope edit; stubbed curl/gh).
bash "$here/fleet-visitor-probe.test.sh" || fail "fleet-visitor-probe tests failed"

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
m.SEAT_CAPS_LIVE = Path("/nonexistent/live-caps.json")  # hermetic: repo-checkouts path list only
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

# --- fleet-ops#3828: N consecutive spawn_fail must demote the LEDGER entry ---
# Pre-fix the census/availability read ONLY the ledger health_class + the
# bench clock, so a chronic spawn_fail seat whose marker reached the corpse
# (seat_dead=true, #3889) or failure-ceiling (#3826) count was reported
# healthy the moment the seat-health extension wrote a NEWER false-healthy
# 200 to the ledger (after_provider_response carries status+headers only,
# never the rc — an rc=1 spawn failure reads as a healthy 200). The bench
# overlay held it out of pick_seat, but the ledger "re-offered" it on the
# count/availability side. Both fences now demote the effective ledger class.
#
# Scenario E — corpse fence: marker seat_dead=true (chronic spawn_fail,
# count=47) + an EXPIRED usable_at + a fresh healthy ledger. The corpse must
# win over the healthy ledger (TERMINAL until a recovery probe).
W = iso(-60)      # marker written 1 min ago (fresh within 24 h)
LDG = Path(seat_dir) / "opencode__fixture.json"
MKF = Path(seat_dir) / "opencode__fixture.spawn-bench.json"
(Path(seat_dir) / "opencode__fixture.json").write_text(json.dumps({
    "provider": "opencode", "model": "fixture", "health_class": "healthy",
    "seat_dead": False, "usable_at": None, "bench_until": None,
    "observed_at": iso(0),  # NEWER than written_at (the false-healthy clobber)
}))
(MKF).write_text(json.dumps({
    "provider": "opencode", "model": "fixture", "usable_at": PAST,
    "written_at": W, "backoff_s": 100000, "failure_mode": "spawn_fail",
    "consecutive_failure_count": 47, "seat_dead": True,
}))
corpse = m._healthy_enrolled_seat_count()
assert corpse == len(enrolled) - 1, \
    f"marker corpse must demote the healthy ledger ({len(enrolled)-1}), got {corpse}"
# The healthy sidecar path must agree (fleet_pi_seat_healthy).
assert m._spawn_bench_marker_held(MKF) is True, \
    "corpse fence must hold the marker directly"
print(f"OK: corpse fence demotes the ledger + holds marker (opencode dropped, {corpse}/{len(enrolled)})")
# Recovery probe (source=comeback_release on the ledger) re-proves the seat.
(LDG).write_text(json.dumps({
    "provider": "opencode", "model": "fixture", "health_class": "healthy",
    "seat_dead": False, "http_status": 200, "source": "comeback_release",
    "observed_at": iso(0),
}))
corpse_rec = m._healthy_enrolled_seat_count()
assert corpse_rec == len(enrolled), \
    f"comeback_release must release an expired corpse marker ({len(enrolled)}), got {corpse_rec}"
print("OK: comeback_release recovery re-proves an expired-corpus marker")

# Scenario F — ceiling fence (#3826): non-corpse marker whose count crossed
# the failure ceiling, usable_at expired, ledger has a NEWER healthy write.
# The ceiling must hold despite the newer observation.
(LDG).write_text(json.dumps({
    "provider": "opencode", "model": "fixture", "health_class": "healthy",
    "seat_dead": False, "http_status": 200, "observed_at": iso(0),  # newer
}))
(MKF).write_text(json.dumps({
    "provider": "opencode", "model": "fixture", "usable_at": PAST,
    "written_at": W, "backoff_s": 900, "failure_mode": "spawn_fail",
    "consecutive_failure_count": 47, "seat_dead": False,
}))
ceil_held = m._healthy_enrolled_seat_count()
assert ceil_held == len(enrolled) - 1, \
    f"ceiling fence must hold a ceiling-parked seat ({len(enrolled)-1}), got {ceil_held}"
print(f"OK: ceiling fence holds count>=ceiling seat despite newer healthy observation ({ceil_held}/{len(enrolled)})")
# Below the ceiling the healthy (later) observation wins again.
(MKF).write_text(json.dumps({
    "provider": "opencode", "model": "fixture", "usable_at": PAST,
    "written_at": W, "backoff_s": 900, "failure_mode": "spawn_fail",
    "consecutive_failure_count": 3, "seat_dead": False,
}))
below = m._healthy_enrolled_seat_count()
assert below == len(enrolled), \
    f"sub-ceiling count with fresh later observation must be released ({len(enrolled)}), got {below}"
print("OK: sub-ceiling marker count does not gate the rollup")
# Empty-run seats use the lower EMPTY_RUN_FAILURE_CEILING (5).
(MKF).write_text(json.dumps({
    "provider": "opencode", "model": "fixture", "usable_at": PAST,
    "written_at": W, "failure_mode": "empty_run",
    "consecutive_failure_count": 5, "seat_dead": False,
}))
emt_held = m._healthy_enrolled_seat_count()
assert emt_held == len(enrolled) - 1, \
    f"empty_run count=5 at its ceiling must hold ({len(enrolled)-1}), got {emt_held}"
print("OK: empty_run ceiling (5) holds at its lower threshold")
# comeback_release releases a ceiling-parked seat too.
(LDG).write_text(json.dumps({
    "provider": "opencode", "model": "fixture", "health_class": "healthy",
    "seat_dead": False, "http_status": 200, "source": "comeback_release",
    "observed_at": iso(0),
}))
ceil_rec = m._healthy_enrolled_seat_count()
assert ceil_rec == len(enrolled), \
    f"comeback_release must release a ceiling-parked seat ({len(enrolled)}), got {ceil_rec}"
(MKF).unlink()
(LDG).write_text(json.dumps({
    "provider": "opencode", "model": "fixture", "health_class": "healthy",
    "seat_dead": False, "usable_at": None, "bench_until": None,
}))
print("OK: comeback_release re-proves a ceiling-parked seat")
PY
ok "fleet-ops#2493: held wrapper spawn-bench outranks a later healthy observation (census honest)"
ok "fleet-ops#3828: N consecutive spawn_fail demotes the ledger class (corpse + ceiling fences)"

# =========================================================================
# 16. fleet-ops#2712: provider-level (account-level) quota exhaustion.
# A provider with >=2 quota_exhausted seats (HTTP 402 + health_class=
# quota_exhausted) observed within the last 1h is one billing wall, not
# N independent seat faults. The per-seat health_class=quota_exhausted
# signal alone collapsed three failures into one root cause (e.g. the
# straitly/deepseek-v4-pro + gpt-5.6-sol + qwen3.8-max 2026-09-02 burn)
# and depressed the seat_availability SLO without distinguishing them.
# Pin the helper: counting, time-window, threshold, exclusions.
# =========================================================================
PQE_SEATS="$scratch/pqe-seats"
mkdir -p "$PQE_SEATS"
python3 - "$exporter" "$PQE_SEATS" <<'PY' || fail "provider-quota-exhausted test failed"
import importlib.util, json, sys, time
from datetime import datetime, timezone
from pathlib import Path

exporter, seat_dir = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("fme", exporter)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

now = time.time()
def iso(offset_s):
    return datetime.fromtimestamp(now + offset_s, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

# Wall-clock-relative fixtures; the helper's time window is 3600s.
RECENT = iso(-300)    # 5 min ago
PAST   = iso(-7200)   # 2 h ago (outside the 1h window)

# Scenario A: the live burn shape — three straitly seats all 402 inside
# 1h. The per-seat health_class=quota_exhausted signal alone produced
# three independent seat faults; the new helper collapses them into ONE
# provider-level signal (straitly, seats=3).
fixtures = {
    # straitly x3 quota_exhausted inside 1h (the live burn shape).
    "straitly__deepseek_deepseek-v4-pro.json": {
        "provider": "straitly", "model": "deepseek/deepseek-v4-pro",
        "http_status": 402, "health_class": "quota_exhausted",
        "failure_mode": "quota_exhausted", "seat_dead": False,
        "observed_at": RECENT, "consecutive_failure_count": 34,
    },
    "straitly__gpt-5.6-sol.json": {
        "provider": "straitly", "model": "gpt-5.6-sol",
        "http_status": 402, "health_class": "quota_exhausted",
        "failure_mode": "quota_exhausted", "seat_dead": False,
        "observed_at": RECENT, "consecutive_failure_count": 25,
    },
    "straitly__qwen_qwen3.8-max.json": {
        "provider": "straitly", "model": "qwen/qwen3.8-max",
        "http_status": 402, "health_class": "quota_exhausted",
        "failure_mode": "quota_exhausted", "seat_dead": False,
        "observed_at": RECENT, "consecutive_failure_count": 23,
    },
    # cline/cline-pass/minimax-m3 — one quota_exhausted seat on cline.
    # Below the >=2 threshold -> must NOT appear (isolated hold, not
    # account-level).
    "cline__cline-pass_minimax-m3.json": {
        "provider": "cline", "model": "cline-pass/minimax-m3",
        "http_status": 402, "health_class": "quota_exhausted",
        "failure_mode": "quota_exhausted", "seat_dead": False,
        "observed_at": RECENT, "consecutive_failure_count": 14,
    },
    # straitly x1 quota_exhausted BUT observed 2h ago (outside window).
    # A stale 402 must NOT count — the window is "now-3600s", not
    # "any observed_at ever".
    "straitly__stale-402.json": {
        "provider": "straitly", "model": "stale-402",
        "http_status": 402, "health_class": "quota_exhausted",
        "failure_mode": "quota_exhausted", "seat_dead": False,
        "observed_at": PAST, "consecutive_failure_count": 5,
    },
    # 402 status but health_class is healthy (impossible in practice, but
    # the helper must key on BOTH fields, not just http_status). Must be
    # excluded.
    "openrouter__deepseek_deepseek-v4-flash.json": {
        "provider": "openrouter", "model": "deepseek/deepseek-v4-flash",
        "http_status": 402, "health_class": "healthy",
        "failure_mode": "none", "seat_dead": False,
        "observed_at": RECENT, "consecutive_failure_count": 0,
    },
    # A quota_exhausted seat on a CORPSE (seat_dead=true) — terminal,
    # owned by FleetDeadCredentialSeats. Must NOT count (corpses are
    # not "currently quota-walled", they are retired).
    "commandcode__minimax_minimax-m3-free.json": {
        "provider": "commandcode", "model": "minimax/minimax-m3-free",
        "http_status": 402, "health_class": "quota_exhausted",
        "failure_mode": "quota_exhausted", "seat_dead": True,
        "observed_at": RECENT, "consecutive_failure_count": 200,
    },
    # test__ fixture — synthetic. Excluded.
    "test__quota.json": {
        "provider": "test", "model": "quota",
        "http_status": 402, "health_class": "quota_exhausted",
        "failure_mode": "quota_exhausted", "seat_dead": False,
        "observed_at": RECENT, "consecutive_failure_count": 1,
    },
    # .spawn-bench sibling — not a seat observation. Excluded.
    "straitly__deepseek_deepseek-v4-pro.spawn-bench.json": {
        "provider": "straitly", "model": "deepseek/deepseek-v4-pro",
        "usable_at": iso(3600), "reason": "no_block:rc=0", "backoff_s": 300,
    },
    # Garbage observed_at — must be skipped, not crash the helper.
    "straitly__garbage-time.json": {
        "provider": "straitly", "model": "garbage-time",
        "http_status": 402, "health_class": "quota_exhausted",
        "failure_mode": "quota_exhausted", "seat_dead": False,
        "observed_at": "garbage", "consecutive_failure_count": 1,
    },
}
for name, body in fixtures.items():
    (Path(seat_dir) / name).write_text(json.dumps(body))

m.SEAT_LEDGER = Path(seat_dir)
n, providers = m._read_provider_quota_exhausted()
# Only straitly qualifies: 3 recent in-window quota_exhausted seats.
# cline has 1 (below threshold). straitly stale-402 is out of window.
# The healthy/402 and corpse/402 are excluded by their other field.
# test__ and .spawn-bench are excluded by class.
assert n == 1, f"expected 1 provider-level quota-exhausted, got {n}: {providers}"
prov = providers[0]
assert prov["provider"] == "straitly", prov
assert prov["seats"] == 3, prov
assert len(prov["models"]) == 3, prov
assert "deepseek/deepseek-v4-pro" in [mm[0] for mm in prov["models"]], prov
assert "gpt-5.6-sol" in [mm[0] for mm in prov["models"]], prov
assert "qwen/qwen3.8-max" in [mm[0] for mm in prov["models"]], prov
print("OK: straitly collapsed from 3 per-seat faults to 1 provider-level signal (seats=3)")

# Scenario B: add ONE MORE 402 to cline inside the window. Now cline
# also qualifies (seats=2 -> >=2 threshold met).
(Path(seat_dir) / "cline__z-ai_glm-5.3-flash.json").write_text(json.dumps({
    "provider": "cline", "model": "z-ai/glm-5.3-flash",
    "http_status": 402, "health_class": "quota_exhausted",
    "failure_mode": "quota_exhausted", "seat_dead": False,
    "observed_at": RECENT, "consecutive_failure_count": 4,
}))
n2, providers2 = m._read_provider_quota_exhausted()
prov_names = {p["provider"] for p in providers2}
assert prov_names == {"straitly", "cline"}, prov_names
cline = next(p for p in providers2 if p["provider"] == "cline")
assert cline["seats"] == 2, cline
print("OK: cline joined the provider-level signal at 2 quota_exhausted seats")

# Scenario C: drop cline's second seat — cline falls below the threshold
# and disappears; straitly stays. Pin that the threshold is the gate.
(Path(seat_dir) / "cline__z-ai_glm-5.3-flash.json").unlink()
n3, providers3 = m._read_provider_quota_exhausted()
assert {p["provider"] for p in providers3} == {"straitly"}, providers3
print("OK: 402-quota exhaustion is threshold-gated at >=2 seats per provider")

# Scenario D: missing ledger dir returns (0, []) — never raises.
(Path(seat_dir)).rename(Path(seat_dir).parent / "pqe-seats-renamed")
n4, providers4 = m._read_provider_quota_exhausted()
assert n4 == 0 and providers4 == [], (n4, providers4)
print("OK: missing ledger dir returns empty signal (no crash)")
PY
# =========================================================================
# 18. fleet-ops#2752: _read_never_released must skip future-walled seats.
#     A seat whose bench_until/usable_at wall is still in the future is
#     legitimately benched — the comeback-release prober will re-probe it
#     when the wall passes. It must NOT be counted as a "never-probed
#     comeback" (consecutive_failure_count in the stuck window), otherwise
#     a long monthly/quota bench can reach NEVER_RELEASED_MIN_COUNT and
#     trigger a false FleetSeatComebackNeverReleased alarm.
# =========================================================================
NR_SEATS="$scratch/nr-seats"
mkdir -p "$NR_SEATS"
python3 - "$exporter" "$NR_SEATS" <<'PY' || fail "never-released future-wall test failed"
import importlib.util, json, sys, time
from datetime import datetime, timezone
from pathlib import Path

exporter, seat_dir = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("fme", exporter)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

now = time.time()

def iso(offset_s):
    return datetime.fromtimestamp(now + offset_s, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

PAST = iso(-7200)  # wall passed 2h ago
FUT  = iso(7200)   # wall holds for another 2h

fixtures = {
    # 1. No wall clock, count in stuck window -> never-probed comeback.
    "opencode__no-wall.json": {
        "provider": "opencode", "model": "no-wall",
        "http_status": 503, "health_class": "overload_bench",
        "seat_dead": False, "usable_at": None, "bench_until": None,
        "consecutive_failure_count": 19,
    },
    # 2. Past wall, count in stuck window -> still a never-probed comeback
    #    (the wall has released, yet the seat is not healthy).
    "opencode__past-wall.json": {
        "provider": "opencode", "model": "past-wall",
        "http_status": 503, "health_class": "overload_bench",
        "seat_dead": False, "usable_at": PAST, "bench_until": PAST,
        "consecutive_failure_count": 19,
    },
    # 3. Future wall, count in stuck window -> must NOT count; wall still
    #    has the seat benched legitimately.
    "opencode__future-wall.json": {
        "provider": "opencode", "model": "future-wall",
        "http_status": 503, "health_class": "overload_bench",
        "seat_dead": False, "usable_at": FUT, "bench_until": FUT,
        "consecutive_failure_count": 19,
    },
    # 4. Future wall but below stuck floor -> must NOT count anyway.
    "opencode__future-wall-low.json": {
        "provider": "opencode", "model": "future-wall-low",
        "http_status": 503, "health_class": "overload_bench",
        "seat_dead": False, "usable_at": FUT, "bench_until": FUT,
        "consecutive_failure_count": 5,
    },
    # 5. Corpse -> excluded (FleetDeadCredentialSeats owns corpses).
    "opencode__corpse.json": {
        "provider": "opencode", "model": "corpse",
        "http_status": 500, "health_class": "corpse",
        "seat_dead": True, "usable_at": PAST, "bench_until": None,
        "consecutive_failure_count": 19,
    },
    # 6. Healthy -> excluded.
    "opencode__healthy.json": {
        "provider": "opencode", "model": "healthy",
        "http_status": 200, "health_class": "healthy",
        "seat_dead": False, "usable_at": None, "bench_until": None,
        "consecutive_failure_count": 0,
    },
    # 7. test__ fixture -> excluded.
    "test__synthetic.json": {
        "provider": "test", "model": "synthetic",
        "http_status": 503, "health_class": "overload_bench",
        "seat_dead": False, "usable_at": None, "bench_until": None,
        "consecutive_failure_count": 19,
    },
    # 8. .spawn-bench sibling -> excluded.
    "opencode__future-wall.spawn-bench.json": {
        "provider": "opencode", "model": "future-wall",
        "usable_at": FUT, "reason": "no_block:rc=0", "backoff_s": 300,
    },
}
for name, body in fixtures.items():
    (Path(seat_dir) / name).write_text(json.dumps(body))

# Hermetic seat-caps so the fleet-ops#3661 phantom-key guard treats these
# synthetic opencode fixtures as REAL enrolled seats (their models are not in
# the production config/seat-caps.json). Without this the guard would exclude
# opencode/no-wall + opencode/past-wall as phantoms and the future-wall
# test would silently pass on 0 fixtures, not on genuine future-wall exclusion.
nr_caps = Path(seat_dir) / "seat-caps.json"
nr_caps.write_text(json.dumps({
    "providers": {"opencode": {"cap": 3, "class": "free", "models": {
        "no-wall": {"cap": 1}, "past-wall": {"cap": 1},
        "future-wall": {"cap": 1}, "future-wall-low": {"cap": 1},
        "corpse": {"cap": 1}, "healthy": {"cap": 1},
    }}}
}))
m.SEAT_CAPS_DEFAULT = nr_caps
m.SEAT_CAPS_FALLBACK = Path("/nonexistent/seat-caps.json")
m.SEAT_CAPS_LIVE = Path("/nonexistent/live-caps.json")  # hermetic: repo-checkouts path list only

m.SEAT_LEDGER = Path(seat_dir)
n, seats = m._read_never_released()
ids = {f"{s['provider']}__{s['model']}" for s in seats}

assert n == 2, f"never_released_n must be 2, got {n}: {ids}"
assert {"opencode__no-wall", "opencode__past-wall"} <= ids, ids
assert "opencode__future-wall" not in ids, f"future-walled seat must not count as never-released: {ids}"
assert "opencode__future-wall-low" not in ids, "future-walled + below floor must not count"
assert not any(i.startswith("test__") for i in ids), "test__ leaked into never-released"
assert not any("corpse" in i for i in ids), "corpse leaked into never-released"
assert not any(".spawn-bench" in i for i in ids), "spawn-bench leaked into never-released"
print("OK: _read_never_released excludes future-walled, healthy, corpse, test, and spawn-bench seats (fleet-ops#2752)")

# Missing ledger dir returns (0, []) — never raises.
(Path(seat_dir)).rename(Path(seat_dir).parent / "nr-seats-renamed")
n2, seats2 = m._read_never_released()
assert n2 == 0 and seats2 == [], (n2, seats2)
print("OK: _read_never_released missing ledger dir returns empty signal (no crash)")
PY

ok "fleet-ops#2712 + #2752: provider-level 402 collapse and never-released skips future-walled seats"

# =========================================================================
# fleet-ops#3161: fleet_close_duplicates_closes_total{cross_repo,protected}
# The exporter reads the last close-duplicates summary's closes_by_label and
# emits four labelled series. cross_repo and protected must stay 0; only
# cross_repo=false,protected=false may increment. Missing/unparseable file
# emits all four as 0 (family always present, absent rule stays quiet).
# =========================================================================
python3 - "$exporter" <<'PY' || fail "close-duplicates metric emission failed"
import importlib.util, json, os, sys, tempfile
from pathlib import Path
def load(p, name):
    spec = importlib.util.spec_from_file_location(name, p)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m
m = load(sys.argv[1], "fme")

# 1. Missing file -> all four series 0, family present.
with tempfile.TemporaryDirectory() as td:
    m.CLOSE_DUP_JSON = Path(td) / "missing.json"
    lines = []
    m._emit_close_duplicates(lines)
    out = "\n".join(lines)
    assert "fleet_close_duplicates_closes_total" in out, out
    assert out.count("# HELP fleet_close_duplicates_closes_total") == 1, out
    assert out.count("# TYPE fleet_close_duplicates_closes_total") == 1, out
    for cr, pr in [("false","false"),("false","true"),("true","false"),("true","true")]:
        assert f'fleet_close_duplicates_closes_total{{cross_repo="{cr}",protected="{pr}"}} 0' in out, out
    print("OK: missing file -> 4 series all 0, HELP/TYPE once")

# 2. A summary with a legit same-repo close (cross_repo=false,protected=false=1)
#    and a WRONG cross-repo close (cross_repo=true,protected=false=1) is
#    emitted faithfully so the alert can fire on the wrong close.
with tempfile.TemporaryDirectory() as td:
    p = Path(td) / "close-duplicates.json"
    p.write_text(json.dumps({
        "closed": 2,
        "closes_by_label": {
            "cross_repo=false,protected=false": 1,
            "cross_repo=false,protected=true": 0,
            "cross_repo=true,protected=false": 1,
            "cross_repo=true,protected=true": 0,
        },
    }))
    m.CLOSE_DUP_JSON = p
    lines = []
    m._emit_close_duplicates(lines)
    out = "\n".join(lines)
    assert 'cross_repo="false",protected="false"} 1' in out, out
    assert 'cross_repo="true",protected="false"} 1' in out, out
    assert 'cross_repo="false",protected="true"} 0' in out, out
    assert 'cross_repo="true",protected="true"} 0' in out, out
    print("OK: summary with a wrong cross-repo close is emitted faithfully (alert can fire)")

# 3. Unparseable file -> all four 0 (no crash).
with tempfile.TemporaryDirectory() as td:
    p = Path(td) / "bad.json"
    p.write_text("{not json")
    m.CLOSE_DUP_JSON = p
    lines = []
    m._emit_close_duplicates(lines)
    out = "\n".join(lines)
    assert 'cross_repo="false",protected="false"} 0' in out, out
    print("OK: unparseable file -> 4 series all 0 (no crash)")
PY

ok "fleet-ops#3161: fleet_close_duplicates_closes_total{cross_repo,protected} emitted (missing/legit/wrong/unparseable)"

# =========================================================================
# fleet-ops#3312: fleet_nish_decision_rejected_total
# The exporter reads the last blocked-reconcile sweep summary's
# rejected_nish_decisions count. Missing/unparseable files emit 0 so the
# family is always present; a real summary with a rejected count emits it.
# =========================================================================
python3 - "$exporter" <<'PY' || fail "blocked-reconcile metric emission failed"
import importlib.util, json, os, sys, tempfile
from pathlib import Path
def load(p, name):
    spec = importlib.util.spec_from_file_location(name, p)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m
m = load(sys.argv[1], "fme")

# 1. Missing file -> 0, family present.
with tempfile.TemporaryDirectory() as td:
    m.BLOCKED_QUEUE_JSON = Path(td) / "missing.json"
    lines = []
    m._emit_blocked_reconcile(lines)
    out = "\n".join(lines)
    assert "fleet_nish_decision_rejected_total" in out, out
    assert out.count("# HELP fleet_nish_decision_rejected_total") == 1, out
    assert out.count("# TYPE fleet_nish_decision_rejected_total") == 1, out
    assert "fleet_nish_decision_rejected_total 0" in out, out
    print("OK: missing file -> 0, HELP/TYPE once")

# 2. A real summary with rejected_nish_decisions=3 emits 3.
with tempfile.TemporaryDirectory() as td:
    p = Path(td) / "blocked-queue.json"
    p.write_text(json.dumps({"count": 1, "rejected_nish_decisions": 3}))
    m.BLOCKED_QUEUE_JSON = p
    lines = []
    m._emit_blocked_reconcile(lines)
    out = "\n".join(lines)
    assert "fleet_nish_decision_rejected_total 3" in out, out
    print("OK: summary with 3 rejected nish lines emits 3")

# 3. Unparseable file -> 0 (no crash).
with tempfile.TemporaryDirectory() as td:
    p = Path(td) / "bad.json"
    p.write_text("{not json")
    m.BLOCKED_QUEUE_JSON = p
    lines = []
    m._emit_blocked_reconcile(lines)
    out = "\n".join(lines)
    assert "fleet_nish_decision_rejected_total 0" in out, out
    print("OK: unparseable file -> 0 (no crash)")
PY

ok "fleet-ops#3312: fleet_nish_decision_rejected_total emitted (missing/legit/unparseable)"

# =========================================================================
# fleet-ops#4260: fleet_blocked_issues{kind} + needs-orchestrator age stats.
# Every kind is always emitted (0 when absent) so a stale family cannot
# false-fire or false-clear FleetNeedsOrchestratorStale.
# =========================================================================
python3 - "$exporter" <<'PY' || fail "blocked-queue per-kind metric emission failed"
import importlib.util, json, sys, tempfile
from pathlib import Path
def load(p, name):
    spec = importlib.util.spec_from_file_location(name, p)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m
m = load(sys.argv[1], "fme")

KINDS = ["work-item", "nish-decision", "orchestrator", "infra",
         "senior-review", "needs-orchestrator"]

# 1. Missing file -> all kinds present at 0, age series present at 0.
with tempfile.TemporaryDirectory() as td:
    m.BLOCKED_QUEUE_JSON = Path(td) / "missing.json"
    lines = []
    m._emit_blocked_reconcile(lines)
    out = "\n".join(lines)
    assert out.count("# HELP fleet_blocked_issues") == 1, out
    assert out.count("# TYPE fleet_blocked_issues") == 1, out
    for k in KINDS:
        assert f'fleet_blocked_issues{{kind="{k}"}} 0' in out, out
    assert 'fleet_blocked_issue_age_seconds{kind="needs-orchestrator",quantile="0.5"} 0' in out, out
    assert 'fleet_blocked_issue_age_seconds{kind="needs-orchestrator",quantile="1"} 0' in out, out
    print("OK: missing file -> all kinds at 0, age series at 0")

# 2. A snapshot with mixed kinds + a needs_orchestrator block.
with tempfile.TemporaryDirectory() as td:
    p = Path(td) / "blocked-queue.json"
    p.write_text(json.dumps({
        "count": 3,
        "items": [
            {"ref": "Nishfleet/fleet-ops#1", "kind": "work-item", "age_h": 2},
            {"ref": "Nishfleet/fleet-ops#2", "kind": "orchestrator", "age_h": 5},
            {"ref": "Nishfleet/fleet-ops#3", "kind": "nish-decision", "age_h": 9},
        ],
        "needs_orchestrator": {"count": 4, "oldest_age_s": 9000,
                               "p50_age_s": 5400, "items": []},
    }))
    m.BLOCKED_QUEUE_JSON = p
    lines = []
    m._emit_blocked_reconcile(lines)
    out = "\n".join(lines)
    assert 'fleet_blocked_issues{kind="work-item"} 1' in out, out
    assert 'fleet_blocked_issues{kind="orchestrator"} 1' in out, out
    assert 'fleet_blocked_issues{kind="nish-decision"} 1' in out, out
    assert 'fleet_blocked_issues{kind="infra"} 0' in out, out
    assert 'fleet_blocked_issues{kind="needs-orchestrator"} 4' in out, out
    assert 'fleet_blocked_issue_age_seconds{kind="needs-orchestrator",quantile="0.5"} 5400' in out, out
    assert 'fleet_blocked_issue_age_seconds{kind="needs-orchestrator",quantile="1"} 9000' in out, out
    print("OK: per-kind counts + needs-orchestrator age stats emitted")

# 3. Unparseable file -> all kinds at 0 (no crash).
with tempfile.TemporaryDirectory() as td:
    p = Path(td) / "bad.json"
    p.write_text("{not json")
    m.BLOCKED_QUEUE_JSON = p
    lines = []
    m._emit_blocked_reconcile(lines)
    out = "\n".join(lines)
    for k in KINDS:
        assert f'fleet_blocked_issues{{kind="{k}"}} 0' in out, out
    print("OK: unparseable file -> all kinds at 0 (no crash)")
PY

ok "fleet-ops#4260: fleet_blocked_issues{kind} + needs-orchestrator age emitted (missing/legit/unparseable)"

# The alert that consumes the series must exist in the rules file and point
# at the p50 series with a repair path naming the decision-sweep unit.
grep -q 'alert: FleetNeedsOrchestratorStale' "$repo_root/config/fleet_rules.yml" \
    || fail "fleet_rules.yml missing FleetNeedsOrchestratorStale"
grep -q 'fleet_blocked_issue_age_seconds{kind="needs-orchestrator",quantile="0.5"}' "$repo_root/config/fleet_rules.yml" \
    || fail "FleetNeedsOrchestratorStale must key on the needs-orchestrator p50 series"
grep -q 'agent-cron-orchestrator-decision-sweep' "$repo_root/config/fleet_rules.yml" \
    || fail "alert description must name the decision-sweep unit so the repair packet runs it"

# =========================================================================
# 17. fleet-ops#3250: per-seat rolling last-20 issue-work session PR yield.
# =========================================================================
python3 - "$exporter" "$scratch" <<'PY' || fail "seat-yield logic failed"
import importlib.util, json, sys, time
from pathlib import Path

exporter, scratch = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("fme", exporter)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

sessions = Path(scratch) / "sessions"
sessions.mkdir(parents=True, exist_ok=True)
m.SESSIONS_DIR = sessions
m.SEAT_YIELD_JSON = Path(scratch) / "seat-yield.json"
m.SEAT_YIELD_CACHE = Path(scratch) / "seat-yield-cache.json"
m.SEAT_CAPS_DEFAULT = Path(scratch) / "seat-caps.json"
m.SEAT_CAPS_FALLBACK = Path("/nonexistent/seat-caps.json")
m.SEAT_CAPS_LIVE = Path("/nonexistent/live-caps.json")  # hermetic: repo-checkouts path list only

Path(m.SEAT_CAPS_DEFAULT).write_text(json.dumps({
    "providers": {
        "devin": {
            "cap": 4,
            "models": {"glm-5-2": 3, "swe-1-7": 4}
        },
        "opencode": {
            "cap": 3,
            "models": {
                "mimo-v2.5-free": 1,
                "nemotron-3.5-lightning-free": 1
            }
        },
        "bai": {
            "cap": 0,
            "models": {"deepseek-v4-flash": 0}
        }
    }
}))

def session(provider, model, ts, has_pr, cost=None):
    issue = f"pi-issue-{provider}-{model.replace('/', '-')}"
    d = sessions / issue
    d.mkdir(parents=True, exist_ok=True)
    path = d / f"2026-09-04T{ts}.jsonl"
    final_text = (
        "https://github.com/Nishfleet/0509/pull/1234" if has_pr
        else "No PR produced by this session"
    )
    content = [{"type": "text", "text": final_text}]
    base = f'2026-09-04T{ts}Z'
    usage = {"cost": {"total": cost}} if cost is not None else {}
    lines = [
        json.dumps({"type": "session", "version": 3, "timestamp": base, "id": f"{issue}-{ts}"}),
        json.dumps({"type": "model_change", "provider": provider, "modelId": model, "timestamp": base}),
        json.dumps({"type": "message", "message": {"role": "assistant", "content": content, "usage": usage}, "timestamp": base}),
    ]
    path.write_text("\n".join(lines))
    return path

# devin/glm-5-2: 5 sessions, some with PR -> provisional 0.5 (<20).
# fleet-ops#3323: sessions carry usage.cost so cost_per_session = 0.10.
for i in range(5):
    session("devin", "glm-5-2", f"00:00:{i:02d}", i % 2 == 0, cost=0.10)

# opencode/mimo-v2.5-free: exactly 20 sessions, 5 with PR -> 0.25.
# Odd sessions cost 0.20 -> cost_per_session = 0.10 over the window.
for i in range(20):
    session("opencode", "mimo-v2.5-free", f"01:00:{i:02d}", i % 4 == 0,
            cost=0.20 if i % 2 == 1 else None)

# devin/swe-1-7: 25 sessions; last 20 (i>=5) all have PR -> 1.0
for i in range(25):
    session("devin", "swe-1-7", f"02:00:{i:02d}", i >= 5)

result = m._compute_seat_yield()

# JSON sidecar must be written and parseable.
sy_path = Path(m.SEAT_YIELD_JSON)
assert sy_path.exists(), "seat-yield.json sidecar not written"
j = json.loads(sy_path.read_text())

# devin/glm-5-2: provisional 0.5, sessions<20
assert "devin/glm-5-2" in result
assert result["devin/glm-5-2"]["yield"] == 0.5
assert result["devin/glm-5-2"]["sessions"] == 5
assert result["devin/glm-5-2"]["provisional"] is True
assert j["devin/glm-5-2"]["yield"] == 0.5
print("OK: devin/glm-5-2 provisional 0.5 for <20 sessions")

# opencode/mimo-v2.5-free: 20 sessions, 5 PR, 15 no-PR -> 0.25
assert "opencode/mimo-v2.5-free" in result
assert result["opencode/mimo-v2.5-free"]["yield"] == 0.25
assert result["opencode/mimo-v2.5-free"]["sessions"] == 20
assert result["opencode/mimo-v2.5-free"]["pr_count"] == 5
assert result["opencode/mimo-v2.5-free"]["no_pr_count"] == 15
assert result["opencode/mimo-v2.5-free"]["provisional"] is False
print("OK: opencode/mimo-v2.5-free rolling-20 yield 0.25")

# fleet-ops#3323: cost_per_session is the mean usage.cost over the window.
# devin/glm-5-2: 5 sessions x 0.10 -> 0.10 even though yield is provisional.
assert result["devin/glm-5-2"]["cost_per_session"] == 0.10
assert j["devin/glm-5-2"]["cost_per_session"] == 0.10
# opencode/mimo-v2.5-free: 10 of 20 sessions at 0.20 -> 0.10.
assert abs(result["opencode/mimo-v2.5-free"]["cost_per_session"] - 0.10) < 1e-9
# devin/swe-1-7 sessions carry no usage.cost -> 0.0 (the value floor
# 0.001 is applied in pick_seat, not in the ledger).
assert result["devin/swe-1-7"]["cost_per_session"] == 0.0
assert result["opencode/nemotron-3.5-lightning-free"]["cost_per_session"] == 0.0
print("OK: seat-yield ledger carries rolling cost_per_session (fleet-ops#3323)")

# fleet-ops#3322: cost_usd is the TOTAL cost over the rolling window (not
# the mean). The audition lane caps total spend at $1, so the intake tick
# reads cost_usd to enforce that cap. cost_per_session stays for value ranking.
# devin/glm-5-2: 5 sessions x 0.10 -> cost_usd 0.50
assert abs(result["devin/glm-5-2"]["cost_usd"] - 0.50) < 1e-9
assert abs(j["devin/glm-5-2"]["cost_usd"] - 0.50) < 1e-9
# opencode/mimo-v2.5-free: 10 of 20 sessions at 0.20 -> cost_usd 2.00
assert abs(result["opencode/mimo-v2.5-free"]["cost_usd"] - 2.00) < 1e-9
# devin/swe-1-7: no cost -> 0.0
assert result["devin/swe-1-7"]["cost_usd"] == 0.0
print("OK: seat-yield ledger carries total cost_usd (fleet-ops#3322)")

# devin/swe-1-7: 25 sessions, last-20 all PR -> 1.0
assert "devin/swe-1-7" in result
assert result["devin/swe-1-7"]["yield"] == 1.0
assert result["devin/swe-1-7"]["pr_count"] == 20
assert result["devin/swe-1-7"]["provisional"] is False
print("OK: devin/swe-1-7 last-20 all PR -> 1.0")

# opencode/nemotron-3.5-lightning-free: cap>0 but no sessions -> 0.5
assert "opencode/nemotron-3.5-lightning-free" in result
assert result["opencode/nemotron-3.5-lightning-free"]["yield"] == 0.5
assert result["opencode/nemotron-3.5-lightning-free"]["sessions"] == 0
assert result["opencode/nemotron-3.5-lightning-free"]["provisional"] is True
print("OK: idle cap-map seat gets provisional 0.5")

# cap=0 bai must not be in result
assert "bai/deepseek-v4-flash" not in result
print("OK: cap=0 bai/deepseek-v4-flash excluded from yield")

# _emit_seat_yield produces valid prom lines.
lines = []
m._emit_seat_yield(lines, result)
out = "\n".join(lines)
assert "# HELP fleet_seat_yield" in out
assert "# TYPE fleet_seat_yield gauge" in out
assert "# HELP fleet_sessions_no_pr_total" in out
assert 'fleet_seat_yield{seat="devin/glm-5-2"} 0.500000' in out
assert 'fleet_seat_yield{seat="opencode/mimo-v2.5-free"} 0.250000' in out
assert 'fleet_seat_yield{seat="devin/swe-1-7"} 1.000000' in out
assert 'fleet_sessions_no_pr_total{seat="opencode/mimo-v2.5-free"} 15' in out
assert out.count("# HELP fleet_seat_yield") == 1
assert out.count("# HELP fleet_sessions_no_pr_total") == 1
print("OK: _emit_seat_yield HELP/TYPE once and per-seat series")

# fleet-ops#3322: fleet_sessions_to_pr_pct emitted as a percentage (0..100),
# HELP/TYPE once, and does NOT replace fleet_sessions_no_pr_total.
assert "# HELP fleet_sessions_to_pr_pct" in out
assert "# TYPE fleet_sessions_to_pr_pct gauge" in out
assert 'fleet_sessions_to_pr_pct{seat="devin/glm-5-2"} 50.00' in out
assert 'fleet_sessions_to_pr_pct{seat="opencode/mimo-v2.5-free"} 25.00' in out
assert 'fleet_sessions_to_pr_pct{seat="devin/swe-1-7"} 100.00' in out
assert out.count("# HELP fleet_sessions_to_pr_pct") == 1
# Both families coexist — the new metric does not replace the old one.
assert 'fleet_sessions_no_pr_total{seat="opencode/mimo-v2.5-free"} 15' in out
print("OK: fleet_sessions_to_pr_pct emitted alongside fleet_sessions_no_pr_total (fleet-ops#3322)")

# _parse_session_file handles bare string content and missing PR.
no_pr_path = session("devin", "glm-5-2", "04:00:00", False)
parsed = m._parse_session_file(no_pr_path)
assert parsed["has_pr_url"] is False
assert parsed["seat"] == "devin/glm-5-2"
print("OK: _parse_session_file extracts seat and has_pr_url")

# _extract_text returns only text objects, not reasoning blocks.
assert m._extract_text("plain string") == "plain string"
assert m._extract_text([{"type": "text", "text": "a"}, {"type": "thinking", "thinking": "b"}]) == "a"
print("OK: _extract_text handles string and filters thinking blocks")
PY

ok "fleet-ops#3250: seat-yield ledger, JSON sidecar, and prom output"

# =========================================================================
# 17b. fleet-ops#3250/#3310: infra deaths never count as seat yield.
#
# The rule was written into both issues and into the seat-retirement policy,
# but the ledger counted a provider-side death as a no-PR miss, so a seat was
# marked low-quality for the fleet's own infrastructure failing. That is how
# devin/swe-1-7 was wrongly retired (#3389, corrected in #3473).
# =========================================================================
python3 - "$exporter" "$scratch" <<'PY' || fail "seat-yield infra-death exclusion failed"
import importlib.util, json, sys
from pathlib import Path

exporter, scratch = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("fme2", exporter)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

sessions = Path(scratch) / "sessions-infra"
sessions.mkdir(parents=True, exist_ok=True)
m.SESSIONS_DIR = sessions
m.SEAT_YIELD_JSON = Path(scratch) / "seat-yield-infra.json"
m.SEAT_YIELD_CACHE = Path(scratch) / "seat-yield-infra-cache.json"
m.SEAT_CAPS_DEFAULT = Path(scratch) / "seat-caps-infra.json"
m.SEAT_CAPS_FALLBACK = Path("/nonexistent/seat-caps.json")
m.SEAT_CAPS_LIVE = Path("/nonexistent/live-caps.json")
Path(m.SEAT_CAPS_DEFAULT).write_text(json.dumps({"providers": {}}))

def session(provider, model, ts, kind, cost=None):
    """kind: pr | miss | infra | infra_prose"""
    d = sessions / f"pi-issue-{provider}-{model}"
    d.mkdir(parents=True, exist_ok=True)
    base = f"2026-09-04T{ts}Z"
    msg = {"role": "assistant", "content": [], "usage": {}}
    if cost is not None:
        msg["usage"] = {"cost": {"total": cost}}
    if kind == "pr":
        msg["content"] = [{"type": "text",
                           "text": "https://github.com/Nishfleet/0509/pull/1234"}]
    elif kind == "miss":
        msg["content"] = [{"type": "text", "text": "No PR produced."}]
    elif kind == "infra":
        msg["stopReason"] = "error"
        msg["errorMessage"] = ('Devin exited with code 1: Error: Agent error: '
                               '{"cognition.ai/errorKind": "resource_exhausted"}')
    elif kind == "infra_prose":
        # The model WORKED and merely talked about a timeout. It must count as
        # a real miss: the words appear in content, never in a stopReason pair.
        msg["content"] = [{"type": "text",
                           "text": "The upload timed out and returned 503; "
                                   "I fixed the ETIMEDOUT retry. No PR yet."}]
    lines = [
        json.dumps({"type": "session", "version": 3, "timestamp": base,
                    "id": f"{provider}-{ts}"}),
        json.dumps({"type": "model_change", "provider": provider,
                    "modelId": model, "timestamp": base}),
        json.dumps({"type": "message", "message": msg, "timestamp": base}),
    ]
    (d / f"2026-09-04T{ts}.jsonl").write_text("\n".join(lines))

# seat A: 20 working sessions (10 PR) buried under 10 NEWER infra deaths.
# Poisoned reading = the 10 deaths evict half the real evidence and score 0.25;
# correct reading reaches past them and scores 10/20 = 0.50.
for i in range(20):
    session("prov", "worked", f"01:00:{i:02d}", "pr" if i % 2 == 0 else "miss")
for i in range(10):
    session("prov", "worked", f"02:00:{i:02d}", "infra", cost=0.05)

# seat B: every session died on infrastructure -> no quality evidence.
for i in range(20):
    session("prov", "alldead", f"03:00:{i:02d}", "infra")

# seat C: 20 sessions where the model worked and discussed a timeout in prose.
for i in range(20):
    session("prov", "prose", f"04:00:{i:02d}", "infra_prose")

r = m._compute_seat_yield()

a = r["prov/worked"]
assert a["infra_deaths"] == 10, a
assert a["sessions"] == 20, f"infra deaths must not occupy the window: {a}"
assert a["pr_count"] == 10, a
assert a["yield"] == 0.5, a
assert a["provisional"] is False, a
# The audition spend cap must still see what the dead sessions burned.
assert abs(a["cost_usd"] - 0.5) < 1e-9, a

b = r["prov/alldead"]
assert b["sessions"] == 0, b
assert b["yield"] == 0.0, f"all-infra seat must not be promoted to 0.5: {b}"
assert b["provisional"] is False, b

c = r["prov/prose"]
assert c["infra_deaths"] == 0, f"prose must never be read as an infra death: {c}"
assert c["yield"] == 0.0, c
assert c["sessions"] == 20, c

print("OK: infra deaths excluded from yield; prose not misread; spend intact")
PY
ok "fleet-ops#3250/#3310: infra deaths never count as seat yield"

# =========================================================================
# 18. fleet-ops#3231: fleet_observe_to_close_total{reason}
# The exporter reads the last observe-to-close summary's closes_by_reason
# and emits four labelled series. only claim-branch and closes-trailer may
# increment; bare-mention and protected must stay 0 (an alert fires on
# either > 0 — the PR #3205 regression class that closed #3140/#3146 by a
# bare mention). Missing/unparseable file emits all four as 0.
# =========================================================================
python3 - "$exporter" <<'PY' || fail "observe-to-close metric emission failed"
import importlib.util, json, sys, tempfile
from pathlib import Path
def load(p, name):
    spec = importlib.util.spec_from_file_location(name, p)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m
m = load(sys.argv[1], "fme")

# 1. Missing file -> all five series 0, family present with HELP/TYPE once.
with tempfile.TemporaryDirectory() as td:
    m.MERGED_PR_CLOSE_JSON = Path(td) / "missing.json"
    lines = []
    m._emit_observe_to_close(lines)
    out = "\n".join(lines)
    assert "fleet_observe_to_close_total" in out, out
    assert out.count("# HELP fleet_observe_to_close_total") == 1, out
    assert out.count("# TYPE fleet_observe_to_close_total") == 1, out
    for r in ["claim-branch","closes-trailer","verdict-pass","bare-mention","protected"]:
        assert f'fleet_observe_to_close_total{{reason="{r}"}} 0' in out, out
    print("OK: missing file -> 5 series all 0, HELP/TYPE once")

# 2. Legal closes (claim-branch + closes-trailer + verdict-pass) are emitted
#    faithfully; a WRONG bare-mention close is emitted too so the alert fires.
with tempfile.TemporaryDirectory() as td:
    p = Path(td) / "merged-pr-close.json"
    p.write_text(json.dumps({
        "closed": 3,
        "closes_by_reason": {
            "claim-branch": 1,
            "closes-trailer": 1,
            "verdict-pass": 1,
            "bare-mention": 1,
            "protected": 0,
        },
    }))
    m.MERGED_PR_CLOSE_JSON = p
    lines = []
    m._emit_observe_to_close(lines)
    out = "\n".join(lines)
    assert 'reason="claim-branch"} 1' in out, out
    assert 'reason="closes-trailer"} 1' in out, out
    assert 'reason="verdict-pass"} 1' in out, out
    assert 'reason="bare-mention"} 1' in out, out
    assert 'reason="protected"} 0' in out, out
    print("OK: summary with legal closes + a wrong bare-mention close is emitted faithfully (alert can fire)")

# 3. Unparseable file -> all five 0 (no crash).
with tempfile.TemporaryDirectory() as td:
    p = Path(td) / "bad.json"
    p.write_text("{not json")
    m.MERGED_PR_CLOSE_JSON = p
    lines = []
    m._emit_observe_to_close(lines)
    out = "\n".join(lines)
    assert 'reason="claim-branch"} 0' in out, out
    print("OK: unparseable file -> 5 series all 0 (no crash)")
PY

ok "fleet-ops#3231: fleet_observe_to_close_total{reason} emitted (missing/legit/wrong/unparseable)"

# =========================================================================
# 18b. fleet-ops#5785: fleet_deploy_fault_* gauges
# lifecycle-label-sweep.json feeds the closed-without-green tripwire (must
# be 0) and the labeled count; merged-pr-close.json feeds gate_blocked.
# Missing/unparseable files emit 0 — never crash, never false-fire.
# =========================================================================
python3 - "$exporter" <<'PY' || fail "deploy-fault metric emission failed"
import importlib.util, json, sys, tempfile
from pathlib import Path
def load(p, name):
    spec = importlib.util.spec_from_file_location(name, p)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m
m = load(sys.argv[1], "fme")

# 1. Missing files -> all three 0, HELP/TYPE once each.
with tempfile.TemporaryDirectory() as td:
    m.LIFECYCLE_SWEEP_JSON = Path(td) / "missing-sweep.json"
    m.MERGED_PR_CLOSE_JSON = Path(td) / "missing-close.json"
    lines = []
    m._emit_deploy_fault_gate(lines)
    out = "\n".join(lines)
    for name in ("fleet_deploy_fault_closed_without_green",
                 "fleet_deploy_fault_gate_blocked",
                 "fleet_deploy_fault_labeled"):
        assert out.count(f"# HELP {name}") == 1, out
        assert out.count(f"# TYPE {name}") == 1, out
        assert f"{name} 0" in out, out
    print("OK: missing summaries -> all three gauges 0, HELP/TYPE once")

# 2. Real counts land — including a nonzero tripwire (the 0509#2662 class:
#    a deploy-fault issue the sweep found closed without a green run).
with tempfile.TemporaryDirectory() as td:
    sweep = Path(td) / "lifecycle-label-sweep.json"
    sweep.write_text(json.dumps({
        "deploy_fault_closed_without_green": 1,
        "deploy_fault_labeled": 2,
    }))
    close = Path(td) / "merged-pr-close.json"
    close.write_text(json.dumps({"deploy_fault_gate_blocked": 1}))
    m.LIFECYCLE_SWEEP_JSON = sweep
    m.MERGED_PR_CLOSE_JSON = close
    lines = []
    m._emit_deploy_fault_gate(lines)
    out = "\n".join(lines)
    assert "fleet_deploy_fault_closed_without_green 1" in out, out
    assert "fleet_deploy_fault_labeled 2" in out, out
    assert "fleet_deploy_fault_gate_blocked 1" in out, out
    print("OK: nonzero tripwire + labeled + gate_blocked emitted faithfully")

# 3. Unparseable file -> 0, no crash.
with tempfile.TemporaryDirectory() as td:
    bad = Path(td) / "bad.json"
    bad.write_text("{not json")
    m.LIFECYCLE_SWEEP_JSON = bad
    m.MERGED_PR_CLOSE_JSON = bad
    lines = []
    m._emit_deploy_fault_gate(lines)
    out = "\n".join(lines)
    assert "fleet_deploy_fault_closed_without_green 0" in out, out
    print("OK: unparseable summaries -> 0 (no crash)")
PY

ok "fleet-ops#5785: fleet_deploy_fault_* gauges emitted (missing/real/unparseable)"

# =========================================================================
# fleet-ops#3301: cap=0 credentials_bad corpses do not page as dead-cred.
# Lived 2026-09-04T16:30Z: FleetDeadCredentialSeats fired on
# opencode/hy3-free and opencode/x-preview-f-free (both already cap=0 in
# seat-caps.json) while the control seat (ling-3.0-flash-fin-free, cap>0)
# was healthy. A 401 on a retired slug is not a re-auth action.
# =========================================================================
python3 - "$exporter" <<'PY' || fail "3301 dead-cred enrollment filter failed"
import importlib.util, json, os, sys, tempfile
from pathlib import Path
spec = importlib.util.spec_from_file_location("fme", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
scratch = Path(tempfile.mkdtemp(prefix="deadcred-3301-"))
ledger = scratch / "seats"
ledger.mkdir()
(ledger / "opencode__hy3-free.json").write_text(json.dumps({
    "provider": "opencode", "model": "hy3-free", "http_status": 401,
    "health_class": "corpse", "seat_dead": True,
    "failure_mode": "credentials_bad", "usable_at": None,
}))
(ledger / "opencode__x-preview-f-free.json").write_text(json.dumps({
    "provider": "opencode", "model": "x-preview-f-free", "http_status": 401,
    "health_class": "corpse", "seat_dead": True,
    "failure_mode": "credentials_bad", "usable_at": None,
}))
(ledger / "xai-oauth__grok-4.5.json").write_text(json.dumps({
    "provider": "xai-oauth", "model": "grok-4.5", "http_status": 401,
    "health_class": "credentials_bad", "seat_dead": True,
    "failure_mode": "credentials_bad", "usable_at": None,
}))
caps = scratch / "seat-caps.json"
caps.write_text(json.dumps({
    "providers": {
        "opencode": {
            "cap": 3,
            "models": {
                "hy3-free": {"cap": 0, "intentional_cap_zero": "corpse"},
                "x-preview-f-free": {"cap": 0, "intentional_cap_zero": "stale"},
                "ling-3.0-flash-fin-free": 1,
            },
        },
        "xai-oauth": {"cap": 1, "models": {"grok-4.5": 1}},
    }
}))
m.SEAT_LEDGER = ledger
m.SEAT_CAPS_DEFAULT = caps
m.SEAT_CAPS_FALLBACK = Path("/nonexistent/seat-caps.json")
m.SEAT_CAPS_LIVE = Path("/nonexistent/live-caps.json")  # hermetic: repo-checkouts path list only
n, seats = m._read_dead_credentials()
assert n == 1, f"enrolled dead-cred must be 1 (xai-oauth), got {n}: {seats}"
assert seats[0]["provider"] == "xai-oauth" and seats[0]["model"] == "grok-4.5", seats
ids = {(s["provider"], s["model"]) for s in seats}
assert ("opencode", "hy3-free") not in ids, "cap=0 hy3-free must not page"
assert ("opencode", "x-preview-f-free") not in ids, "cap=0 x-preview-f-free must not page"
print("OK: cap=0 credentials_bad corpses excluded from dead-cred total (fleet-ops#3301)")
# Fail-open: unreadable caps still count every dead-cred seat so a genuine
# enrolled 401 cannot go silent.
m.SEAT_CAPS_DEFAULT = Path("/nonexistent/missing-caps.json")
m.SEAT_CAPS_FALLBACK = Path("/nonexistent/missing-caps-2.json")
m.SEAT_CAPS_LIVE = Path("/nonexistent/live-caps.json")  # hermetic: repo-checkouts path list only
n2, seats2 = m._read_dead_credentials()
assert n2 == 3, f"fail-open must count all 3 dead-cred seats, got {n2}: {seats2}"
print("OK: unreadable seat-caps fail-open counts all dead-cred seats (fleet-ops#3301)")
PY

ok "fleet-ops#3301: cap=0 dead-cred corpses excluded; unreadable caps fail-open"

# =========================================================================
# 17. fleet-ops#3124 part 4/4: week-later revert-candidate check.
#     For each fleet-ops PR merged ~7 days ago with a `moves:` metric,
#     compare the metric's 7d value before vs after; if it did not improve,
#     file ONE revert-candidate issue (never re-filed). Hermetic: gh and
#     Prometheus are stubbed; the state ledger is a scratch file.
# =========================================================================
WL_SCRATCH="$scratch/week-later"
mkdir -p "$WL_SCRATCH"
python3 - "$exporter" "$WL_SCRATCH" <<'PY' || fail "week-later revert check test failed"
import importlib.util, json, sys, time
from pathlib import Path

exporter, scratch = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("fme", exporter)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

m.PR_CACHE_DIR = Path(scratch)
m.WEEK_LATER_CACHE = Path(scratch) / "wl-cache.json"
m.WEEK_LATER_STATE = Path(scratch) / "wl-state.json"

# --- _MOVES_RE parsing ---
assert m._MOVES_RE.search("moves: product_merges_per_day\n").group(1) == "product_merges_per_day"
assert m._MOVES_RE.search("- moves: sessions_to_pr_pct\n").group(1) == "sessions_to_pr_pct"
assert m._MOVES_RE.search("no moves line here\n") is None
print("OK: _MOVES_RE parses the moves: line")

# --- metric mapping ---
assert m._MOVES_METRIC_QUERIES["product_merges_per_day"] == 'sum(fleet_self_maintenance_merges{kind="product"})'
assert m._metric_7d_value("unknown_metric", 0) is None
print("OK: moves metric -> Prometheus expression mapping")

# --- _week_later_revert_check: improved vs not-improved vs already-filed ---
# PR100 merged 2026-08-29 (before=2, improved -> no file).
# PR101 merged 2026-08-20 (before=8, not improved -> file).
# PR102 merged 2026-08-20 (before=8, not improved, but already-filed -> skip).
m._week_later_prs = lambda: [
    {"number": 100, "title": "feat: x", "moves": "product_merges_per_day", "merged_at": "2026-08-29T00:00:00Z"},
    {"number": 101, "title": "feat: y", "moves": "product_merges_per_day", "merged_at": "2026-08-20T00:00:00Z"},
    {"number": 102, "title": "feat: z", "moves": "product_merges_per_day", "merged_at": "2026-08-20T00:00:00Z"},
]
now = time.time()
def fake_metric(metric, t):
    if metric != "product_merges_per_day":
        return None
    if abs(t - now) <= 1:
        return 5.0  # after (now)
    return 2.0 if t > 1787500000 else 8.0  # 08-29->2 improved, 08-20->8 not
m._metric_7d_value = fake_metric
m._revert_candidate_exists = lambda n, metric: (n == 102)  # 102 already filed
filed = []
m._file_revert_candidate = lambda n, metric, b, a, ma: (filed.append((n, metric, b, a)) or True)

summary = m._week_later_revert_check()
assert filed == [(101, "product_merges_per_day", 8.0, 5.0)], filed
state = m._read_week_later_state()
assert state["100"]["verdict"] == "improved", state
assert state["101"]["verdict"] == "filed", state
assert state["102"]["verdict"] == "already-filed", state
print("OK: week-later check files only the not-improved, not-already-filed PR")

# --- state-skip: a PR already in the ledger is never re-evaluated ---
filed.clear()
summary2 = m._week_later_revert_check()
assert filed == [], f"state-skip must not re-file: {filed}"
print("OK: week-later check never re-evaluates a PR already in the ledger")

# --- Prometheus-unavailable: metric None -> PR left unevaluated (retried) ---
m._week_later_prs = lambda: [
    {"number": 200, "title": "feat: w", "moves": "product_merges_per_day", "merged_at": "2026-08-20T00:00:00Z"},
]
m._metric_7d_value = lambda metric, t: None  # Prometheus down
filed.clear()
summary3 = m._week_later_revert_check()
assert filed == [], "no file when Prometheus is unavailable"
state3 = m._read_week_later_state()
assert "200" not in state3, "unevaluated PR must not be recorded (retried later)"
print("OK: Prometheus-unavailable PR is left unevaluated, not filed, not recorded")

# --- fleet-ops#3948: a PR younger than 7d-6h is never evaluated ---
# The live organ filed #3605 89 min after #3577 merged (before == after,
# same trailing-7d data) because the search window leaked. Whatever the
# search returns, a young PR is skipped and left unrecorded (retried when
# it is really a week old).
import re
from datetime import datetime, timezone
young_iso = datetime.fromtimestamp(now - 2 * 3600, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
m._week_later_prs = lambda: [
    {"number": 300, "title": "feat: v", "moves": "product_merges_per_day", "merged_at": young_iso},
]
m._metric_7d_value = lambda metric, t: 5.0 if abs(t - now) <= 1 else 8.0  # not improved
m._revert_candidate_exists = lambda n, metric: False
filed.clear()
summary4 = m._week_later_revert_check()
assert filed == [], f"fleet-ops#3948: PR merged 2h ago must not be filed: {filed}"
assert "300" not in m._read_week_later_state(), "fleet-ops#3948: young PR must not be recorded"
print("OK: fleet-ops#3948 PR merged 2h ago is skipped, not filed, not recorded")

# --- fleet-ops#3948: the search uses one merged:A..B range, never two qualifiers ---
captured = []
m._gh_graphql = lambda q, c: captured.append(q) or None
m._gh_week_later_prs()
assert captured, "fleet-ops#3948: week-later search must run"
q = captured[0]
assert "merged:>=" not in q and "merged:<=" not in q, q
assert re.search(r"merged:\d{4}-\d{2}-\d{2}T[0-9:]+Z\.\.\d{4}-\d{2}-\d{2}T[0-9:]+Z", q), q
print("OK: fleet-ops#3948 week-later search uses a merged:A..B range")
PY

ok "fleet-ops#3124 part 4/4: week-later revert-candidate check pinned"

# =========================================================================
# 18. fleet-ops#3283: seat spend and metered provider balances.
#     Spend is summed from pi session usage.cost per message, per provider,
#     per UTC day. OpenRouter and xKiro balances are fetched from their
#     vendor endpoints when a key is available.
# =========================================================================

# --- Pure helpers: _day_from_iso, _parse_session_file_for_cost, _compute_spend
python3 - "$exporter" <<'PY' || fail "3283 spend helpers failed"
import importlib.util, json, tempfile, os, sys
from pathlib import Path
exporter = sys.argv[1]
spec = importlib.util.spec_from_file_location("fme", exporter)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# _day_from_iso
assert m._day_from_iso("2026-09-04T07:32:18.303Z") == "2026-09-04"
assert m._day_from_iso("2026-09-04T23:59:59.000Z") == "2026-09-04"
assert m._day_from_iso("") is None
assert m._day_from_iso("not-a-date") is None
print("OK: _day_from_iso extracts UTC day")

# _parse_session_file_for_cost
# Real pi session jsonl carries provider ONLY on model_change lines, never on
# messages. The parser must track it across the file; messages without a
# provider key must still be attributed. Pin that real shape here.
td = Path(tempfile.mkdtemp())
session = td / "2026-09-04T12-00-00Z_s.jsonl"
session.write_text(
    json.dumps({"type": "session", "id": "s", "timestamp": "2026-09-04T12:00:00Z"}) + "\n"
    + json.dumps({"type": "model_change", "provider": "openrouter", "modelId": "x"}) + "\n"
    + json.dumps({"type": "message", "timestamp": "2026-09-04T12:01:00Z",
                  "message": {"role": "assistant", "usage": {"cost": {"total": 0.123}}}}) + "\n"
    + json.dumps({"type": "message", "timestamp": "2026-09-04T12:02:00Z",
                  "message": {"role": "assistant", "usage": {"cost": {"total": 0.456}}}}) + "\n"
    + json.dumps({"type": "model_change", "provider": "minimax", "modelId": "y"}) + "\n"
    + json.dumps({"type": "message", "timestamp": "2026-09-04T12:03:00Z",
                  "message": {"role": "assistant", "usage": {"cost": {"total": 0.111}}}}) + "\n"
    + json.dumps({"type": "model_change", "provider": "xkiro", "modelId": "z"}) + "\n"
    + json.dumps({"type": "message", "timestamp": "2026-09-04T12:04:00Z",
                  "message": {"role": "assistant", "usage": {"cost": {"total": 0}}}}) + "\n"
    + json.dumps({"type": "message", "timestamp": "2026-09-05T00:01:00Z",
                  "message": {"role": "assistant", "usage": {"cost": {"total": 0.789}}}}) + "\n"
    + json.dumps({"type": "message", "message": {"role": "user", "content": "hi"},
                  "timestamp": "2026-09-04T12:05:00Z"}) + "\n"
    + "{not json\n"
)
spend = m._parse_session_file_for_cost(session)
assert spend == {"openrouter": {"2026-09-04": 0.579}, "minimax": {"2026-09-04": 0.111}, "xkiro": {"2026-09-05": 0.789}}, spend
print("OK: _parse_session_file_for_cost attributes provider via model_change; ignores zero/no-usage/malformed")

# _compute_spend with mtime cache
sd = td / "sessions" / "pi-issue-fleet-ops-3283"
sd.mkdir(parents=True)
(session).rename(sd / "2026-09-04T12-00-00Z_s.jsonl")
m.SESSIONS_DIR = sd.parent
m.SPEND_CACHE = td / "spend-cache.json"
spend = m._compute_spend()
assert spend == {"openrouter": {"2026-09-04": 0.579}, "minimax": {"2026-09-04": 0.111}, "xkiro": {"2026-09-05": 0.789}}, spend
# second run: cached by mtime, same result
spend2 = m._compute_spend()
assert spend2 == spend, spend2
print("OK: _compute_spend scans sessions and caches by mtime")

# fleet-ops#3284: _emit_spend also emits fleet_seat_spend_today_usd{provider}
# — the day-less copy of the current UTC day's row the FleetProviderSpendBoundary
# rule selects on ('today' cannot be expressed against the day-labelled series
# in a static PromQL rule).
import datetime as _dt
_today = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%d")
lines = []
m._emit_spend(lines, {"openrouter": {_today: 6.25, "2020-01-01": 99.0},
                      "minimax": {"2020-01-02": 7.0}})
body = "\n".join(lines)
assert f'fleet_seat_spend_usd{{provider="openrouter",day="{_today}"}} 6.250000' in body, body
assert f'fleet_seat_spend_today_usd{{provider="openrouter"}} 6.250000' in body, body
# a provider with no spend today emits NO today row (absent = 0 — the alert
# must not trip on a stale day from the trailing window)
assert 'fleet_seat_spend_today_usd{provider="minimax"}' not in body, body
# days older than the 30d retention window are filtered from BOTH families
assert 'day="2020-01-01"' not in body and 'day="2020-01-02"' not in body, body
assert body.count("# HELP fleet_seat_spend_today_usd") == 1, body
assert body.count("# TYPE fleet_seat_spend_today_usd") == 1, body
# no spend at all -> no today family (absent, not a fake 0)
lines = []
m._emit_spend(lines, {})
assert 'fleet_seat_spend_today_usd' not in "\n".join(lines)
print("OK: _emit_spend emits the current-day copy only for providers with spend today")

# _read_env_key
env_file = td / ".env"
env_file.write_text("# comment\nXKIRO_API_KEY=secret123\nOPENROUTER_API_KEY=or456\n")
assert m._read_env_key(env_file, ("XKIRO_API_KEY", "API_KEY")) == "secret123"
assert m._read_env_key(env_file, ("OPENROUTER_API_KEY",)) == "or456"
assert m._read_env_key(td / "missing.env", ("XKIRO_API_KEY",)) is None
print("OK: _read_env_key resolves dotenv keys")
PY

# --- main() emission with stubbed vendor fetches
SPEND_SCRATCH="$scratch/spend-3283"
mkdir -p "$SPEND_SCRATCH"
SPEND_OUT="$SPEND_SCRATCH/fleet.prom"
python3 - "$exporter" "$SPEND_OUT" "$SPEND_SCRATCH" <<'PY' || fail "3283 main() emission failed"
import importlib.util, json, os, sys, tempfile
from pathlib import Path
exporter, out_path, scratch = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("fme", exporter)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

sd = Path(scratch) / "sessions" / "pi-issue-fleet-ops-3283"
sd.mkdir(parents=True)
(sd / "2026-09-04T12-00-00Z_s.jsonl").write_text(
    json.dumps({"type": "session", "id": "s", "timestamp": "2026-09-04T12:00:00Z"}) + "\n"
    + json.dumps({"type": "model_change", "provider": "openrouter", "modelId": "x"}) + "\n"
    + json.dumps({"type": "message", "timestamp": "2026-09-04T12:01:00Z",
                  "message": {"role": "assistant", "usage": {"cost": {"total": 0.123}}}}) + "\n"
    + json.dumps({"type": "model_change", "provider": "minimax", "modelId": "y"}) + "\n"
    + json.dumps({"type": "message", "timestamp": "2026-09-04T12:02:00Z",
                  "message": {"role": "assistant", "usage": {"cost": {"total": 0.456}}}}) + "\n"
)

# fleet-ops#3284: a second session stamped TODAY (UTC) so the day-less
# fleet_seat_spend_today_usd row has something to emit.
import datetime as _dt
_today = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%d")
(sd / f"{_today}T03-04-05Z_t.jsonl").write_text(
    json.dumps({"type": "session", "id": "t", "timestamp": f"{_today}T03:04:05Z"}) + "\n"
    + json.dumps({"type": "model_change", "provider": "minimax", "modelId": "m"}) + "\n"
    + json.dumps({"type": "message", "timestamp": f"{_today}T03:05:00Z",
                  "message": {"role": "assistant", "usage": {"cost": {"total": 6.5}}}}) + "\n"
)

m.OUT = Path(out_path)
m.PR_CACHE_DIR = Path(scratch) / "cache"
m.PR_CACHE_DIR.mkdir(parents=True, exist_ok=True)
m.SESSIONS_DIR = sd.parent
m.SELF_MAINT_JSON_DEFAULT = Path("/nonexistent/sm.json")
m.SELF_MAINT_JSON_FALLBACK = Path("/nonexistent/fb.json")
m.SEAT_HEALTH = Path("/nonexistent/seat.json")
m.SEAT_LEDGER = Path("/nonexistent/seatdb")
m.SEAT_CAPS_DEFAULT = Path("/nonexistent/sc.json")
m.SEAT_CAPS_FALLBACK = Path("/nonexistent/sc2.json")
m.SEAT_CAPS_LIVE = Path("/nonexistent/live-caps.json")  # hermetic: repo-checkouts path list only
m.HC_URL_FILE = Path("/nonexistent/hc.url")
m.ACTIONS_LOG = Path("/nonexistent/actions.log")
m.MAINTENANCE_FLAG = Path("/nonexistent/maint.json")
m.INTAKE_JSON_DEFAULT = Path("/nonexistent/intake.json")
m.INTAKE_JSON_FALLBACK = Path("/nonexistent/intake2.json")
m.KEYSTONE_LEDGER = Path("/nonexistent/keystone.jsonl")
m.WORKTREE_REAPER_SUMMARY = Path("/nonexistent/reaper.json")
m.STALENESS_CACHE = Path("/nonexistent/stale.json")
m.DETAIL_CACHE = m.PR_CACHE_DIR / "detail.cache.json"
m.OPENROUTER_BALANCE_CACHE = m.PR_CACHE_DIR / "openrouter-balance.json"
m.XKIRO_BALANCE_CACHE = m.PR_CACHE_DIR / "xkiro-balance.json"
# fleet-ops#3284: pin the spend mtime cache into scratch too — SPEND_CACHE is
# bound at module load to the LIVE path, so without this the test reads and
# rewrites the real seat-spend cache.
m.SPEND_CACHE = m.PR_CACHE_DIR / "spend-cache.json"

m._list_timers = lambda: [{"unit": "fleet-metrics-export.timer", "last_usec": 0}]
m._timer_active = lambda unit: 1
m._read_seat = lambda: (1, 0)
m._merged_prs_detail = lambda: None
m._repo_snapshot = lambda: None
m._queue_composition = lambda: {
    "ready-work": {"total": 5, "self": 1},
    "agent-ready": {"total": 6, "self": 2},
}
m._escalations_24h = lambda: {}
m._oomd_kills_6h = lambda: {}
m._repair_log_counts_24h = lambda: (0, 0)
m._worker_units = lambda: []
m._standalone_pi_print_count = lambda u: 0
m._maintenance_quiescing = lambda: 0
m._keystone_routing_counts = lambda: (0, 0, None)
m._ping_healthcheck = lambda: None
m._fetch_openrouter_credits = lambda: None
m._fetch_xkiro_usage = lambda: None
m._fetch_openrouter_key = lambda: None
m._fetch_claude_usage = lambda: None
m._fetch_codex_usage = lambda: None
m._fetch_cursor_usage = lambda: None
m._fetch_devin_usage = lambda: None
m._fetch_xkiro_quota = lambda: None
m._gh_rate_limit = lambda: None
m._read_dead_credentials = lambda: (0, [])
m._fetch_openrouter_credits = lambda: 6.95
m._fetch_xkiro_usage = lambda: (999999, 0.0, 0.0)
m._VENDOR_BALANCE_FETCHED = set()

m._fetch_signups_7d = lambda: None
rc = m.main()
assert rc == 0, f"main rc={rc}"
body = Path(out_path).read_text()

assert '# HELP fleet_seat_spend_usd' in body, body
assert '# TYPE fleet_seat_spend_usd gauge' in body, body
assert 'fleet_seat_spend_usd{provider="openrouter",day="2026-09-04"} 0.123000' in body, body
assert 'fleet_seat_spend_usd{provider="minimax",day="2026-09-04"} 0.456000' in body, body

# fleet-ops#3284: the day-less current-day copy for the spend-boundary rule.
assert '# HELP fleet_seat_spend_today_usd' in body, body
assert '# TYPE fleet_seat_spend_today_usd gauge' in body, body
assert f'fleet_seat_spend_usd{{provider="minimax",day="{_today}"}} 6.500000' in body, body
assert f'fleet_seat_spend_today_usd{{provider="minimax"}} 6.500000' in body, body
# no spend today for openrouter -> no today row (absent = 0, never a fake 0)
assert 'fleet_seat_spend_today_usd{provider="openrouter"}' not in body, body

assert '# HELP fleet_seat_credits_remaining_usd' in body, body
assert '# TYPE fleet_seat_credits_remaining_usd gauge' in body, body
assert 'fleet_seat_credits_remaining_usd{provider="openrouter"} 6.950000' in body, body
assert 'fleet_seat_credits_remaining_usd{provider="xkiro"} 0.000000' in body, body

assert '# HELP fleet_seat_free_tokens_remaining' in body, body
assert '# TYPE fleet_seat_free_tokens_remaining gauge' in body, body
assert 'fleet_seat_free_tokens_remaining{provider="xkiro"} 999999' in body, body

assert '# HELP fleet_seat_credits_held_usd' in body, body
assert '# TYPE fleet_seat_credits_held_usd gauge' in body, body
assert 'fleet_seat_credits_held_usd{provider="xkiro"} 0.000000' in body, body

# HELP/TYPE emitted exactly once per metric family.
from collections import Counter
help_counts = Counter()
type_counts = Counter()
for line in body.splitlines():
    if line.startswith("# HELP "):
        help_counts[line.split()[2]] += 1
    elif line.startswith("# TYPE "):
        type_counts[line.split()[2]] += 1
for fam in (
    "fleet_seat_spend_usd",
    "fleet_seat_spend_today_usd",
    "fleet_seat_credits_remaining_usd",
    "fleet_seat_free_tokens_remaining",
    "fleet_seat_credits_held_usd",
):
    assert help_counts[fam] == 1, f"{fam} HELP count {help_counts[fam]}"
    assert type_counts[fam] == 1, f"{fam} TYPE count {type_counts[fam]}"

print("OK: main() emits spend, credits, xkiro free tokens and held; HELP/TYPE once")
PY

ok "fleet-ops#3283: spend, credits, xkiro wallet/free-token metrics"

# =========================================================================
# fleet-ops#4217: live seat quotas. The exporter emits
# fleet_seat_quota_remaining_pct{provider,window,source},
# fleet_seat_quota_reset_seconds{provider,window,source}, and
# fleet_seat_quota_observed_seconds{provider,source} from VPS-native API
# reads. Phase 1 covers OpenRouter /key, Claude OAuth, Codex OAuth. This
# test stubs the fetchers and pins the metric shape + the HELP/TYPE-once
# rule + the _resolve_cut_directive fix (the pre-existing 401 on
# OpenRouter /credits caused by the unresolved `!cut` directive in
# models.json).
# =========================================================================
python3 - "$exporter" <<'PY' || fail "fleet-ops#4217 quota metric test failed"
import importlib.util, json, os, sys, time
from pathlib import Path

spec = importlib.util.spec_from_file_location("m", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# 1. Helpers exist.
for fn in ("_fetch_openrouter_key", "_fetch_claude_usage", "_fetch_codex_usage",
           "_fetch_cursor_usage", "_fetch_xkiro_quota",
           "_emit_seat_quota", "_emit_seat_quota_headers", "_cached_quota_json",
           "_iso_to_seconds_until", "_resolve_cut_directive"):
    assert hasattr(m, fn), f"missing {fn}"

# 2. _resolve_cut_directive: a `!cut -d= -f2 <file>` directive resolves to the
#    real key; a plain key passes through; a malformed directive returns None.
cut_dir = "/tmp/fme-cut-test.env"
Path(cut_dir).write_text("OPENROUTER_API_KEY=sk-or-v1-realkey123\n# comment\n")
assert m._resolve_cut_directive(f"!cut -d= -f2 {cut_dir}") == "sk-or-v1-realkey123", "cut directive did not resolve"
assert m._resolve_cut_directive("sk-or-v1-plainkey") == "sk-or-v1-plainkey", "plain key mutated"
assert m._resolve_cut_directive("!cut -d= -f2 /nonexistent/file.env") is None, "missing file should return None"
assert m._resolve_cut_directive(None) is None, "None input should return None"
assert m._resolve_cut_directive(42) is None, "non-string input should return None"
os.unlink(cut_dir)
print("OK: _resolve_cut_directive resolves !cut directives, passes plain keys, returns None on failure")

# 3. _iso_to_seconds_until: parses ISO, returns seconds; None/invalid -> None.
from datetime import datetime, timezone
future = (datetime.now(timezone.utc).isoformat())
s = m._iso_to_seconds_until(future)
assert s is not None and s >= 0, f"future ISO -> {s}"
assert m._iso_to_seconds_until(None) is None, "None -> None"
assert m._iso_to_seconds_until("not-a-date") is None, "invalid -> None"
print("OK: _iso_to_seconds_until parses ISO timestamps, rejects garbage")

# 4. _emit_seat_quota: emits pct, reset, observed with correct labels.
#    Headers are emitted once via _emit_seat_quota_headers (fleet-ops#1844:
#    duplicate HELP/TYPE makes the textfile unparseable).
lines = []
m._emit_seat_quota_headers(lines)
rows = [{"pct": 92.0, "reset_s": 2250.0, "window": "session"},
        {"pct": 46.0, "reset_s": 450.0, "window": "weekly"}]
m._emit_seat_quota(lines, "claude", rows, "api", time.time())
body = "\n".join(lines)
assert 'fleet_seat_quota_remaining_pct{provider="claude",window="session",source="api"} 92.0000' in body, body
assert 'fleet_seat_quota_remaining_pct{provider="claude",window="weekly",source="api"} 46.0000' in body, body
assert 'fleet_seat_quota_reset_seconds{provider="claude",window="session",source="api"} 2250.0000' in body, body
assert 'fleet_seat_quota_reset_seconds{provider="claude",window="weekly",source="api"} 450.0000' in body, body
assert 'fleet_seat_quota_observed_seconds{provider="claude",source="api"}' in body, body
assert body.count("# HELP fleet_seat_quota_remaining_pct") == 1, "duplicate HELP pct"
assert body.count("# TYPE fleet_seat_quota_remaining_pct") == 1, "duplicate TYPE pct"
assert body.count("# HELP fleet_seat_quota_reset_seconds") == 1, "duplicate HELP reset"
assert body.count("# TYPE fleet_seat_quota_reset_seconds") == 1, "duplicate TYPE reset"
assert body.count("# HELP fleet_seat_quota_observed_seconds") == 1, "duplicate HELP observed"
assert body.count("# TYPE fleet_seat_quota_observed_seconds") == 1, "duplicate TYPE observed"
# Two providers must NOT duplicate HELP/TYPE (the fleet-ops#1844 regression).
lines2 = []
m._emit_seat_quota_headers(lines2)
m._emit_seat_quota(lines2, "claude", rows, "api", time.time())
m._emit_seat_quota(lines2, "codex", [{"pct": 0.0, "reset_s": 438205.0, "window": "primary"}], "api", time.time())
body2 = "\n".join(lines2)
assert body2.count("# HELP fleet_seat_quota_remaining_pct") == 1, "two providers dup HELP pct"
assert body2.count("# TYPE fleet_seat_quota_remaining_pct") == 1, "two providers dup TYPE pct"
assert 'fleet_seat_quota_remaining_pct{provider="codex",window="primary",source="api"} 0.0000' in body2, body2
print("OK: _emit_seat_quota emits pct/reset/observed; headers once even for multiple providers")

# 5. _emit_seat_quota with empty rows emits nothing.
lines3 = []
m._emit_seat_quota(lines3, "empty", [], "api", time.time())
assert lines3 == [], "empty rows should emit nothing"
print("OK: _emit_seat_quota with empty rows emits nothing")

# 6. _fetch_claude_usage maps the live response shape (five_hour + seven_day
#    utilization -> remaining_pct = 100 - utilization).
#    _fetch_codex_usage maps rate_limit.primary_window.used_percent.
#    Stub the token + urlopen to avoid network.
import urllib.request
class _FakeResp:
    def __init__(self, data): self._data = json.dumps(data).encode()
    def __enter__(self): return self
    def __exit__(self, *a): pass
    def read(self): return self._data

claude_payload = {
    "five_hour": {"utilization": 8.0, "resets_at": "2099-01-01T00:00:00+00:00"},
    "seven_day": {"utilization": 54.0, "resets_at": "2099-01-01T00:00:00+00:00"},
}
m._claude_access_token = lambda: "fake-token"
orig_urlopen = urllib.request.urlopen
urllib.request.urlopen = lambda req, timeout=15: _FakeResp(claude_payload)
try:
    rows = m._fetch_claude_usage()
finally:
    urllib.request.urlopen = orig_urlopen
assert rows is not None, "claude fetch returned None for valid payload"
assert len(rows) == 2, f"expected 2 windows, got {len(rows)}"
session = [r for r in rows if r["window"] == "session"][0]
weekly = [r for r in rows if r["window"] == "weekly"][0]
assert abs(session["pct"] - 92.0) < 0.01, f"session pct {session['pct']}"
assert abs(weekly["pct"] - 46.0) < 0.01, f"weekly pct {weekly['pct']}"
print("OK: _fetch_claude_usage maps five_hour/seven_day utilization -> remaining_pct")

codex_payload = {
    "rate_limit": {
        "allowed": False,
        "limit_reached": True,
        "primary_window": {"used_percent": 100, "limit_window_seconds": 2592000, "reset_after_seconds": 438205},
    },
}
m._codex_access_token = lambda: "fake-token"
urllib.request.urlopen = lambda req, timeout=15: _FakeResp(codex_payload)
try:
    rows = m._fetch_codex_usage()
finally:
    urllib.request.urlopen = orig_urlopen
assert rows is not None, "codex fetch returned None for valid payload"
assert len(rows) == 1, f"expected 1 window, got {len(rows)}"
assert abs(rows[0]["pct"] - 0.0) < 0.01, f"codex pct {rows[0]['pct']} (100% used -> 0% remaining)"
assert abs(rows[0]["reset_s"] - 438205.0) < 0.01, f"codex reset_s {rows[0]['reset_s']}"
print("OK: _fetch_codex_usage maps rate_limit.primary_window.used_percent -> remaining_pct")

# 7. _fetch_openrouter_key returns None when limit is null (no per-key cap).
or_payload_nocap = {"data": {"limit": None, "limit_remaining": None, "limit_reset": None, "usage": 60.0}}
m._openrouter_api_key = lambda: "fake-key"
urllib.request.urlopen = lambda req, timeout=15: _FakeResp(or_payload_nocap)
try:
    assert m._fetch_openrouter_key() is None, "null limit should return None"
finally:
    urllib.request.urlopen = orig_urlopen
print("OK: _fetch_openrouter_key returns None when limit is null (no per-key cap)")

or_payload_cap = {"data": {"limit": 100.0, "limit_remaining": 40.0, "limit_reset": "2099-01-01T00:00:00+00:00"}}
urllib.request.urlopen = lambda req, timeout=15: _FakeResp(or_payload_cap)
try:
    r = m._fetch_openrouter_key()
    assert r is not None, "cap payload should return a row"
    assert abs(r["pct"] - 40.0) < 0.01, f"openrouter key pct {r['pct']}"
    assert r["window"] == "key_cap"
finally:
    urllib.request.urlopen = orig_urlopen
print("OK: _fetch_openrouter_key maps limit/limit_remaining -> pct when a cap exists")

# 8. _fetch_cursor_usage maps GetCurrentPeriodUsage planUsage.totalPercentUsed
#    (percent USED) -> remaining_pct = 100 - used, and billingCycleEnd
#    (epoch-milliseconds) -> reset_s. Stub the token + urlopen to avoid network.
cursor_payload = {
    "billingCycleStart": "1787371371000",
    "billingCycleEnd": "1790049771000",
    "planUsage": {
        "totalSpend": 215819,
        "includedSpend": 40000,
        "limit": 40000,
        "totalPercentUsed": 61.66257142857143,
        "autoPercentUsed": 71.93666666666667,
        "apiPercentUsed": 0.018,
    },
}
m._cursor_access_token = lambda: "fake-token"
urllib.request.urlopen = lambda req, timeout=15: _FakeResp(cursor_payload)
try:
    rows = m._fetch_cursor_usage()
finally:
    urllib.request.urlopen = orig_urlopen
assert rows is not None, "cursor fetch returned None for valid payload"
assert len(rows) == 1, f"expected 1 window, got {len(rows)}"
assert abs(rows[0]["pct"] - 38.3374) < 0.01, f"cursor pct {rows[0]['pct']} (61.66% used -> 38.34% remaining)"
assert rows[0]["window"] == "monthly", f"cursor window {rows[0]['window']}"
assert rows[0]["reset_s"] is not None and rows[0]["reset_s"] > 0, f"cursor reset_s {rows[0]['reset_s']}"
print("OK: _fetch_cursor_usage maps planUsage.totalPercentUsed + billingCycleEnd -> remaining_pct")

# 9. _fetch_devin_usage maps GetUserStatus planStatus.dailyQuotaRemainingPercent /
#    weeklyQuotaRemainingPercent (percent REMAINING) -> remaining_pct, and the
#    dailyQuotaResetAtUnix / weeklyQuotaResetAtUnix (epoch seconds) -> reset_s.
#    Stub the key + urlopen to avoid network. The reset epochs are relative to
#    run time (now + offsets), NOT hardcoded calendar instants: a hardcoded
#    epoch goes stale the moment it passes and reds this test for every PR
#    (2026-09-08: dailyQuotaResetAtUnix=1788854400 was 08:00Z that day;
#    fleet-metrics-export red'd on main CI with "devin daily reset_s 0.0").
_future_daily = int(time.time()) + 3600
_future_weekly = _future_daily + 5 * 86400
devin_payload = {
    "userStatus": {
        "pro": True,
        "planStatus": {
            "planInfo": {"planName": "Pro"},
            "dailyQuotaRemainingPercent": 96,
            "weeklyQuotaRemainingPercent": 93,
            "dailyQuotaResetAtUnix": _future_daily,
            "weeklyQuotaResetAtUnix": _future_weekly,
        },
    }
}
m._devin_windsurf_api_key = lambda: "fake-key"
urllib.request.urlopen = lambda req, timeout=15: _FakeResp(devin_payload)
try:
    rows = m._fetch_devin_usage()
finally:
    urllib.request.urlopen = orig_urlopen
assert rows is not None, "devin fetch returned None for valid payload"
assert len(rows) == 2, f"expected 2 windows (daily+weekly), got {len(rows)}"
by_window = {r["window"]: r for r in rows}
assert "daily" in by_window, f"missing daily window: {list(by_window)}"
assert "weekly" in by_window, f"missing weekly window: {list(by_window)}"
assert abs(by_window["daily"]["pct"] - 96.0) < 0.01, f"devin daily pct {by_window['daily']['pct']}"
assert abs(by_window["weekly"]["pct"] - 93.0) < 0.01, f"devin weekly pct {by_window['weekly']['pct']}"
assert by_window["daily"]["reset_s"] is not None and by_window["daily"]["reset_s"] > 0, f"devin daily reset_s {by_window['daily']['reset_s']}"
assert by_window["weekly"]["reset_s"] is not None and by_window["weekly"]["reset_s"] > 0, f"devin weekly reset_s {by_window['weekly']['reset_s']}"
print("OK: _fetch_devin_usage maps planStatus daily/weeklyQuotaRemainingPercent + ResetAtUnix -> remaining_pct")

# 10. _fetch_xkiro_quota maps free_tokens.remaining / limit_per_day -> pct,
#     and computes reset_s as seconds until next UTC midnight.
xkiro_payload = {
    "object": "usage",
    "free_tokens": {"used_today": 5012001, "limit_per_day": 5000000, "remaining": 0},
    "wallet": {"balance_usd": "5.000000", "held_usd": "0.000000"},
}
m._read_env_key = lambda path, names: "fake-key"
urllib.request.urlopen = lambda req, timeout=15: _FakeResp(xkiro_payload)
try:
    rows = m._fetch_xkiro_quota()
finally:
    urllib.request.urlopen = orig_urlopen
assert rows is not None, "xkiro fetch returned None for valid payload"
assert len(rows) == 1, f"expected 1 window, got {len(rows)}"
assert abs(rows[0]["pct"] - 0.0) < 0.01, f"xkiro pct {rows[0]['pct']} (0 remaining)"
assert rows[0]["window"] == "daily", f"xkiro window {rows[0]['window']}"
assert rows[0]["reset_s"] is not None and rows[0]["reset_s"] > 0, f"xkiro reset_s {rows[0]['reset_s']}"
print("OK: _fetch_xkiro_quota maps free_tokens.remaining / limit_per_day -> pct + UTC-midnight reset")

print("OK: fleet-ops#4217 live seat quota metric family + VPS-native reads")
PY
ok "fleet-ops#4217: live seat quota metric family + VPS-native reads (OpenRouter /key, Claude OAuth, Codex OAuth, Cursor, Devin, xKiro, !cut resolver)"

# =========================================================================
# fleet-ops#4611: the claude OAuth quota meter must emit OR be loud.
# The pre-fix exporter dropped the whole claude gauge family when
# _fetch_claude_usage() returned None (HTTP 401/429 past the 30-min stale
# window), and the generic FleetSeatQuotaStale absent() leg never fired because
# other providers kept the family present — so a billable seat's meter went
# silently dark for days. Two hermetic regressions (no network, no live state):
#   (a) 200-path: a parseable api.anthropic.com/api/oauth/usage payload ->
#       fleet_seat_quota_remaining_pct{provider="claude",...} (+ reset +
#       observed) is written to the exported body.
#   (b) fail-loud: a dead fetch (None) with no servable cache must NOT go
#       silent — the exporter emits
#       fleet_seat_quota_observed_seconds{provider="claude",source="stale"}
#       with a growing value so FleetClaudeQuotaStale fires.
#   (c) config/fleet_rules.yml carries the FleetClaudeQuotaStale rule keyed on
#       the claude observed_seconds > 900 OR absent remaining_pct.
# =========================================================================
CL_200="$scratch/claude-200.prom"
CL_FAIL="$scratch/claude-fail.prom"
cat >"$scratch/claude-quota-4611.test.py" <<'PY'
import importlib.util, json, os, sys, time
from pathlib import Path
exporter, out_path, cache_dir, mode = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("fme", exporter)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

m.OUT = Path(out_path)
m.PR_CACHE_DIR = Path(cache_dir)
# Pin every quota/vendor cache + ledger into scratch so the run is hermetic.
for _name in ("CLAUDE_QUOTA_CACHE","CODEX_QUOTA_CACHE","OPENROUTER_KEY_CACHE",
              "CURSOR_QUOTA_CACHE","DEVIN_QUOTA_CACHE","XKIRO_QUOTA_CACHE",
              "OPENROUTER_BALANCE_CACHE","XKIRO_BALANCE_CACHE","SPEND_CACHE",
              "DETAIL_CACHE"):
    setattr(m, _name, Path(cache_dir) / (_name.lower() + ".json"))
m.SELF_MAINT_JSON_DEFAULT = Path("/nonexistent/sm.json")
m.SELF_MAINT_JSON_FALLBACK = Path("/nonexistent/fb.json")
m.SEAT_HEALTH = Path("/nonexistent/seat.json")
m.SEAT_LEDGER = Path("/nonexistent/ledger.json")
m.SEAT_CAPS_DEFAULT = Path("/nonexistent/caps.json")
m.SEAT_CAPS_FALLBACK = Path("/nonexistent/caps-fb.json")
m.SEAT_CAPS_LIVE = Path("/nonexistent/live.json")
m.HC_URL_FILE = Path("/nonexistent/hc.url")
m.ACTIONS_LOG = Path("/nonexistent/actions.log")
m.MAINTENANCE_FLAG = Path("/nonexistent/maint.json")
m.INTAKE_JSON_DEFAULT = Path("/nonexistent/intake.json")
m.INTAKE_JSON_FALLBACK = Path("/nonexistent/intake2.json")
m.KEYSTONE_LEDGER = Path("/nonexistent/keystone.jsonl")
m.WORKTREE_REAPER_SUMMARY = Path("/nonexistent/reaper.json")
m.STALENESS_CACHE = Path("/nonexistent/stale.json")

m._list_timers = lambda: [{"unit": "fleet-metrics-export.timer", "last_usec": 0}]
m._timer_active = lambda unit: 1
m._read_seat = lambda: (1, 0)
m._merged_prs_detail = lambda: None
m._repo_snapshot = lambda: None
m._queue_composition = lambda: {"ready-work": {"total": 5, "self": 1}, "agent-ready": {"total": 6, "self": 2}}
m._escalations_24h = lambda: {}
m._oomd_kills_6h = lambda: {}
m._repair_log_counts_24h = lambda: (0, 0)
m._worker_units = lambda: []
m._standalone_pi_print_count = lambda u: 0
m._maintenance_quiescing = lambda: 0
m._keystone_routing_counts = lambda: (0, 0, None)
m._ping_healthcheck = lambda: None
m._fetch_openrouter_credits = lambda: None
m._fetch_xkiro_usage = lambda: None
m._fetch_openrouter_key = lambda: None
m._fetch_codex_usage = lambda: None
m._fetch_cursor_usage = lambda: None
m._fetch_devin_usage = lambda: None
m._fetch_xkiro_quota = lambda: None
m._gh_rate_limit = lambda: None
m._read_dead_credentials = lambda: (0, [])
m._fetch_signups_7d = lambda: None
m._VENDOR_BALANCE_FETCHED = set()

if mode == "200":
    m._fetch_claude_usage = lambda: [
        {"pct": 92.0, "reset_s": 2250.0, "window": "session"},
        {"pct": 46.0, "reset_s": 450.0, "window": "weekly"},
    ]
else:
    m._fetch_claude_usage = lambda: None

rc = m.main()
assert rc == 0, f"main rc={rc}"
body = Path(out_path).read_text()

if mode == "200":
    assert 'fleet_seat_quota_remaining_pct{provider="claude",window="session",source="api"} 92.0000' in body, body
    assert 'fleet_seat_quota_remaining_pct{provider="claude",window="weekly",source="api"} 46.0000' in body, body
    assert 'fleet_seat_quota_reset_seconds{provider="claude",window="session",source="api"} 2250.0000' in body, body
    assert 'fleet_seat_quota_observed_seconds{provider="claude",source="api"}' in body, body
    print("OK: claude 200-path emits remaining_pct/reset/observed (source=api)")
else:
    assert 'fleet_seat_quota_remaining_pct{provider="claude"' not in body, \
        "dead fetch must not emit a claude remaining_pct: " + body
    assert 'fleet_seat_quota_observed_seconds{provider="claude",source="stale"}' in body, \
        "dead claude fetch must emit growing observed_seconds (source=stale), not go silent: " + body
    print("OK: claude dead fetch fails loud via observed_seconds{source=stale}")
PY
python3 "$scratch/claude-quota-4611.test.py" "$exporter" "$CL_200" "$scratch/cl-200-cache" "200" \
  || fail "claude 200-path emission failed"
python3 "$scratch/claude-quota-4611.test.py" "$exporter" "$CL_FAIL" "$scratch/cl-fail-cache" "fail" \
  || fail "claude fail-loud emission failed"
# rule presence (acceptance #2/#3: the alert fires when the claude gauge is
# absent/stale > threshold)
grep -q "alert: FleetClaudeQuotaStale" "$rules" \
  || fail "fleet_rules.yml missing FleetClaudeQuotaStale"
grep -q 'fleet_seat_quota_observed_seconds{provider="claude"} > 900' "$rules" \
  || fail "FleetClaudeQuotaStale must key on claude observed_seconds > 900"
grep -q 'absent(fleet_seat_quota_remaining_pct{provider="claude"})' "$rules" \
  || fail "FleetClaudeQuotaStale must also fire when the claude remaining_pct is absent"
ok "fleet-ops#4611: claude quota emits on 200, fails loud on dead fetch; FleetClaudeQuotaStale rule present"

# =========================================================================
# fleet-ops#4670: the file OAuth token that /api/oauth/usage needs expires
# ~8h and setup-token cannot replace it. claude setup-token / CLAUDE_CODE_OAUTH_TOKEN
# is inference-only (user:inference); /api/oauth/usage 403s with
# oauth_scope_insufficient. Official CLI: "Long-lived tokens (from `claude
# setup-token` or CLAUDE_CODE_OAUTH_TOKEN) are limited to inference-only for
# security reasons." OpenUsage's Claude plugin is the prior art: refresh the
# FILE credential via POST platform.claude.com/v1/oauth/token (grant_type=
# refresh_token, client_id 9d1c250a-..., scopes including user:profile) and
# write the rotation back to ~/.claude/.credentials.json. This is an edit
# inside the existing exporter, not a new grok-token-refresh-shaped unit
# (issue accept #3 / Nish: no new organ). Mac/VPS historically share one
# rotating pair; this VPS file is local (not syncthing'd) so a VPS write does
# not fight the Mac.
#
# Hermetic regressions (no network, no live credentials):
#   (a) CLAUDE_CODE_OAUTH_TOKEN is never used as the usage token.
#   (b) Near-expiry (expiresAt within 5 min, OpenUsage needsRefresh) POSTs
#       the OpenUsage refresh grant and persists access+refresh+expiresAt
#       at mode 0600, preserving sibling oauth fields.
#   (c) Fresh token (expiresAt > 5 min) does not POST.
#   (d) CAS: if the file's refreshToken changed under us, do not overwrite.
#   (e) Failed refresh (401) leaves the file untouched.
# =========================================================================
python3 - "$exporter" <<'PY' || fail "fleet-ops#4670 claude file-token refresh failed"
import importlib.util, json, os, stat, sys, tempfile, time, urllib.error, urllib.request
from pathlib import Path

spec = importlib.util.spec_from_file_location("m", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

for fn in ("_claude_access_token", "_ensure_claude_file_token",
           "_claude_needs_refresh", "_claude_refresh_grant",
           "_persist_claude_oauth"):
    assert hasattr(m, fn), f"missing {fn}"

scratch = Path(tempfile.mkdtemp(prefix="fme-4670-"))
cred = scratch / ".credentials.json"
m.CLAUDE_CREDENTIALS_JSON = cred

SKEW_MS = 5 * 60 * 1000
NOW_MS = 1_800_000_000_000  # pinned so tests do not depend on wall clock

def _oauth(**over):
    base = {
        "accessToken": "sk-ant-file-OLD",
        "refreshToken": "sk-ant-refresh-OLD",
        "expiresAt": NOW_MS + 8 * 3600 * 1000,
        "refreshTokenExpiresAt": NOW_MS + 30 * 86400 * 1000,
        "scopes": ["user:file_upload", "user:inference", "user:mcp_servers",
                    "user:profile", "user:sessions:claude_code"],
        "subscriptionType": "max",
        "rateLimitTier": "default_claude_max_5x",
    }
    base.update(over)
    return base

def _write_cred(oauth):
    cred.write_text(json.dumps({"claudeAiOauth": oauth}, separators=(",", ":")))
    os.chmod(cred, 0o600)

class _FakeResp:
    def __init__(self, data, status=200):
        self._data = json.dumps(data).encode()
        self.status = status
    def __enter__(self): return self
    def __exit__(self, *a): pass
    def read(self): return self._data

posted = []
orig_urlopen = urllib.request.urlopen
orig_time = m.time.time

def _restore():
    urllib.request.urlopen = orig_urlopen
    m.time.time = orig_time
    os.environ.pop("CLAUDE_CODE_OAUTH_TOKEN", None)

# Pin wall clock so expiresAt math is deterministic.
m.time.time = lambda: NOW_MS / 1000.0

# (a) env setup-token is inference-only: never used for usage.
_write_cred(_oauth())
os.environ["CLAUDE_CODE_OAUTH_TOKEN"] = "sk-ant-env-SETUP-TOKEN"
tok = m._claude_access_token()
assert tok == "sk-ant-file-OLD", f"setup-token leaked into usage token: {tok!r}"
print("OK: CLAUDE_CODE_OAUTH_TOKEN is ignored; file token is used")

# (c) fresh token: no refresh POST.
def _boom(req, timeout=15):
    raise AssertionError(f"urlopen must not run on a fresh token: {getattr(req, 'full_url', req)}")
urllib.request.urlopen = _boom
tok = m._ensure_claude_file_token()
assert tok == "sk-ant-file-OLD"
print("OK: fresh file token (expiresAt > 5 min) does not POST refresh")

# needsRefresh pin (OpenUsage: expiresAt - now <= 5 min).
assert m._claude_needs_refresh(_oauth(expiresAt=NOW_MS + SKEW_MS), now_ms=NOW_MS) is True
assert m._claude_needs_refresh(_oauth(expiresAt=NOW_MS + SKEW_MS + 1), now_ms=NOW_MS) is False
assert m._claude_needs_refresh(_oauth(expiresAt=NOW_MS - 1), now_ms=NOW_MS) is True
assert m._claude_needs_refresh({"accessToken": "x"}, now_ms=NOW_MS) is False  # no expiresAt
print("OK: _claude_needs_refresh matches OpenUsage 5-min skew")

# (b) near-expiry POSTs the OpenUsage grant and persists rotation at 0600.
_write_cred(_oauth(expiresAt=NOW_MS + 60_000))  # 1 min left
posted.clear()
def _refresh_ok(req, timeout=15):
    posted.append({
        "url": req.full_url,
        "method": req.get_method(),
        "ctype": req.headers.get("Content-type") or req.headers.get("Content-Type"),
        "body": json.loads(req.data.decode()) if req.data else None,
    })
    return _FakeResp({
        "access_token": "sk-ant-file-NEW",
        "refresh_token": "sk-ant-refresh-NEW",
        "expires_in": 28800,
        "refresh_token_expires_in": 2592000,
        "scope": "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload",
    })
urllib.request.urlopen = _refresh_ok
tok = m._ensure_claude_file_token()
assert tok == "sk-ant-file-NEW", f"refreshed token not returned: {tok!r}"
assert len(posted) == 1, posted
assert posted[0]["url"] == "https://platform.claude.com/v1/oauth/token", posted[0]["url"]
assert posted[0]["method"] == "POST", posted[0]["method"]
body = posted[0]["body"]
assert body["grant_type"] == "refresh_token", body
assert body["refresh_token"] == "sk-ant-refresh-OLD", body
assert body["client_id"] == "9d1c250a-e61b-44d9-88ed-5944d1962f5e", body
assert "user:profile" in body["scope"], body
assert posted[0]["ctype"].startswith("application/json"), posted[0]["ctype"]
saved = json.loads(cred.read_text())["claudeAiOauth"]
assert saved["accessToken"] == "sk-ant-file-NEW"
assert saved["refreshToken"] == "sk-ant-refresh-NEW"
assert saved["expiresAt"] == NOW_MS + 28800 * 1000
assert saved["refreshTokenExpiresAt"] == NOW_MS + 2592000 * 1000
assert saved["subscriptionType"] == "max", "sibling field dropped"
assert saved["rateLimitTier"] == "default_claude_max_5x"
assert "user:profile" in saved["scopes"]
mode = stat.S_IMODE(cred.stat().st_mode)
assert mode == 0o600, f"credentials mode {oct(mode)} (must stay 0600, not _atomic_write's 0644)"
print("OK: near-expiry refresh POSTs OpenUsage grant and persists rotation at 0600")

# (d) CAS: file refreshToken changed under us -> no overwrite.
_write_cred(_oauth(expiresAt=NOW_MS + 60_000))
def _refresh_then_race(req, timeout=15):
    # Simulate another writer rotating the file between read and persist.
    raced = _oauth(accessToken="sk-ant-file-MAC", refreshToken="sk-ant-refresh-MAC",
                   expiresAt=NOW_MS + 8 * 3600 * 1000)
    cred.write_text(json.dumps({"claudeAiOauth": raced}, separators=(",", ":")))
    return _FakeResp({
        "access_token": "sk-ant-file-NEW2",
        "refresh_token": "sk-ant-refresh-NEW2",
        "expires_in": 28800,
    })
urllib.request.urlopen = _refresh_then_race
tok = m._ensure_claude_file_token()
# Returned token is the grant's access (in-memory), but disk must keep the racer.
saved = json.loads(cred.read_text())["claudeAiOauth"]
assert saved["refreshToken"] == "sk-ant-refresh-MAC", saved
assert saved["accessToken"] == "sk-ant-file-MAC", saved
print("OK: CAS refuses to overwrite when file refreshToken changed under us")

# (e) failed refresh leaves the file untouched.
_write_cred(_oauth(expiresAt=NOW_MS + 60_000))
before = cred.read_text()
def _refresh_401(req, timeout=15):
    raise urllib.error.HTTPError(req.full_url, 401, "Unauthorized", hdrs=None, fp=None)
urllib.request.urlopen = _refresh_401
tok = m._ensure_claude_file_token()
assert tok == "sk-ant-file-OLD", f"failed refresh must keep current access: {tok!r}"
assert cred.read_text() == before, "failed refresh must not clobber credentials"
print("OK: 401 refresh leaves credentials untouched and keeps current access")

# _fetch_claude_usage 401 -> one forced refresh then retry.
_write_cred(_oauth(expiresAt=NOW_MS + 8 * 3600 * 1000))  # fresh, but usage 401s
calls = []
def _usage_401_then_ok(req, timeout=15):
    calls.append(req.full_url)
    if "oauth/usage" in req.full_url and calls.count(req.full_url) == 1:
        raise urllib.error.HTTPError(req.full_url, 401, "Unauthorized", hdrs=None, fp=None)
    if "oauth/token" in req.full_url:
        return _FakeResp({
            "access_token": "sk-ant-file-RETRY",
            "refresh_token": "sk-ant-refresh-RETRY",
            "expires_in": 28800,
        })
    if "oauth/usage" in req.full_url:
        return _FakeResp({
            "five_hour": {"utilization": 2.0, "resets_at": "2099-01-01T00:00:00+00:00"},
            "seven_day": {"utilization": 23.0, "resets_at": "2099-01-01T00:00:00+00:00"},
        })
    raise AssertionError(req.full_url)
urllib.request.urlopen = _usage_401_then_ok
rows = m._fetch_claude_usage()
assert rows is not None, "401 usage should recover via refresh+retry"
assert any(r["window"] == "session" and abs(r["pct"] - 98.0) < 0.01 for r in rows), rows
assert any("oauth/token" in u for u in calls), calls
saved = json.loads(cred.read_text())["claudeAiOauth"]
assert saved["accessToken"] == "sk-ant-file-RETRY"
print("OK: usage 401 forces one refresh and retries the usage GET")

# Missing expires_in: do not persist a 0-lifetime token.
_write_cred(_oauth(expiresAt=NOW_MS + 60_000))
before = cred.read_text()
def _refresh_no_exp(req, timeout=15):
    return _FakeResp({"access_token": "sk-ant-file-NOEXP", "refresh_token": "sk-ant-refresh-NOEXP"})
urllib.request.urlopen = _refresh_no_exp
tok = m._ensure_claude_file_token()
assert tok == "sk-ant-file-OLD", f"missing expires_in must keep current access: {tok!r}"
assert cred.read_text() == before, "missing expires_in must not persist"
print("OK: refresh without expires_in leaves credentials untouched")

_restore()
print("OK: fleet-ops#4670 claude file-token refresh (OpenUsage grant, no setup-token, 0600, CAS)")
PY
grep -q 'platform.claude.com/v1/oauth/token' "$rules" \
  || fail "FleetClaudeQuotaStale annotation must name the in-exporter refresh endpoint"
if grep -q 'there is no fleet-side token refresh for claude' "$rules"; then
  fail "FleetClaudeQuotaStale annotation still claims there is no fleet-side token refresh"
fi
ok "fleet-ops#4670: claude file OAuth refresh inside exporter; setup-token ignored"

# =========================================================================
# fleet-ops#3180: fleet_escalations_24h must not count template starts the
# escalation pipeline refuses. The metric counts "Starting
# unit-escalation@<failed-unit>.service" journal lines; unit-escalation-write
# refuses the units in its first `case "$UNIT" in` block (no STOP-REASON, no
# auditor dispatch), so their starts are churn, not escalation volume. The
# list drifted once already: pi-issue@* was refused by the writer on
# 2026-08-30 (#2133/#2475 — workers self-heal via the reaper + re-dispatch
# lane) yet stayed counted here, and the seat-famine crash-loop pushed
# 868 refused pi-issue@ starts into the 936 counted in 24h, tripping
# FleetEscalationStorm. This section replays EVERY writer-refused glob
# through the live filter so the two lists can never silently drift again.
# =========================================================================
python3 - "$exporter" "$repo_root/bin/unit-escalation-write" <<'PY' || fail "escalation exclusion drift-lock failed"
import importlib.util, re, sys
from types import SimpleNamespace
exp_path, writer_path = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("fme", exp_path)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

# Pull the FIRST `case "$UNIT" in <globs>)` block — the no-self-trigger /
# own-lane refuse list. Later case blocks (scout-futility dedupe, class
# gates) are conditional, not unit-name exclusions, so only the first is
# mirrored.
src = open(writer_path).read()
mm = re.search(r'case "\$UNIT" in\s*\n\s*([^)\n]+)\)', src)
assert mm, "could not locate refuse-list case block in unit-escalation-write"
globs = [g for g in mm.group(1).split("|") if g]
assert "pi-issue@*.service" in globs, globs

# One journal line per refused glob -> none may be counted.
lines = []
for g in globs:
    unit = g.replace("*", "SAMPLE")
    if not unit.endswith((".service", ".timer", ".path")):
        unit += ".service"
    lines.append(
        f"Starting unit-escalation@{unit}.service - Universal failure escalation"
    )
# fleet-ops#3349: the alert-repair-* recovery units (hyphen separator) also
# escape the *-repair@* glob and must never count toward FleetEscalationStorm.
# One journal line for a real alert-repair unit -> none may be counted.
lines.append(
    "Starting unit-escalation@alert-repair-FleetMainRed-20260904T172208Z.service - Universal failure escalation"
)
# Control: a genuinely failing unit must still be counted.
lines.append(
    "Starting unit-escalation@pi-intake@ctlrepo.service.service - Universal failure escalation"
)
journal = "\n".join(lines) + "\n"

orig = m.subprocess.run
m.subprocess.run = lambda *a, **k: SimpleNamespace(
    returncode=0, stdout=journal, stderr=""
)
try:
    counts = m._escalations_24h()
finally:
    m.subprocess.run = orig

bad = {u: c for u, c in counts.items() if u != "pi-intake@ctlrepo"}
assert not bad, f"writer-refused units counted by fleet_escalations_24h: {bad}"
assert counts.get("pi-intake@ctlrepo") == 1, counts
print(
    f"OK: {len(globs)} writer-refused globs replayed through "
    "_escalations_24h — none counted; control counted once"
)
PY
ok "fleet-ops#3180: fleet_escalations_24h exclusions locked to unit-escalation-write refuse list"

# =========================================================================
# 12. fleet-ops#3558: _gh_latest_ci_verdict must NOT treat a 'cancelled'
#     run as a red verdict on a PENDING rollup. A cancelled run is a
#     superseded/abandoned run (a newer push replaced it, or auto-revert /
#     stop-the-line cancelled it while a fresh run was queued) — not a red
#     trunk. Treating it as red made the PENDING fallback emit
#     fleet_main_ci_green{repo="Nishfleet/fleet-ops"} 0 (FleetMainRed) even
#     though the real latest completed verdict on main was green, so the
#     alert flapped every time a rapid merge cancelled the prior CI run.
# =========================================================================
python3 - "$exporter" <<'PY' || fail "ci-verdict cancelled-not-red test failed"
import importlib.util, json, sys, types
path = sys.argv[1]
spec = importlib.util.spec_from_file_location("fme_verdict", path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class FakeR:
    def __init__(self, rows):
        self.returncode = 0
        self.stdout = json.dumps(rows)
        self.stderr = ""

def run_latest(rows):
    def fake_run(*a, **k):
        return FakeR(rows)
    m.subprocess.run = fake_run
    return m._gh_latest_ci_verdict("Nishfleet/fleet-ops", "main")

success = {"status": "completed", "conclusion": "success"}
failure = {"status": "completed", "conclusion": "failure"}
cancelled = {"status": "completed", "conclusion": "cancelled"}
in_progress = {"status": "in_progress", "conclusion": None}
skipped = {"status": "completed", "conclusion": "skipped"}

# the live 2026-09-05 fleet-ops main shape: in_progress HEAD, then a cancelled
# superseded run, then the real green run -> must resolve green (was red prior
# to the fix because the first completed run was 'cancelled').
assert run_latest([in_progress, cancelled, cancelled, success]) == 1, \
    "cancelled runs must not mask a later green verdict"

# a genuine failure after the cancelled runs must still be caught -> red.
assert run_latest([in_progress, cancelled, cancelled, failure]) == 0, \
    "a real failure must still resolve red behind cancelled runs"

# a genuine failure as the FIRST completed verdict (no cancelled in front)
# must still be red (unchanged pre-fix behaviour).
assert run_latest([failure, cancelled]) == 0, \
    "first-completed genuine red must resolve red"

# a plain latest green with no cancelled in front stays green.
assert run_latest([success]) == 1, "plain green must resolve green"

# only cancelled/skipped/in_progress completed runs -> no verdict -> None (omit),
# never a false 0.
assert run_latest([in_progress, cancelled, skipped, cancelled]) is None, \
    "no run with a real conclusion must omit, not emit a false red"

print("OK: _gh_latest_ci_verdict treats cancelled as no-verdict (fleet-ops#3558)")
PY

ok "fleet-ops#3558: cancelled CI runs are not a red verdict"


# =========================================================================
# fleet-ops#4164: fleet_oomd_kills_6h metric + FleetOomdKillsHigh alert.
# The metric scrapes journalctl for systemd-oomd kills of app-pi-issue.slice
# units in the last 6h; the alert (sum > 3 for 5m) routes to repair-dispatch
# (severity=critical, NOT page) so a repair packet raises the live
# ram_gb_per_worker charge back to 2.0. Pins:
#   - the metric HELP/TYPE constants exist and name the alert + the 2.0 raise
#   - _oomd_kills_6h parses both oomd log shapes ("Killed unit ..." and
#     "Killed process ... in unit ..."), scopes to pi-issue@*/app-pi-issue,
#     and ignores unrelated services + kernel OOM lines
#   - main() emits the gauge lines for a stubbed journal
#   - fleet_rules.yml carries FleetOomdKillsHigh with the right expr/severity
# =========================================================================
python3 - "$exporter" <<'PY' || fail "oomd metric constants/helpers missing"
import importlib.util, sys
exp_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("fme", exp_path)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert hasattr(m, "HELP_OOMD") and "fleet_oomd_kills_6h" in m.HELP_OOMD, m.HELP_OOMD
assert hasattr(m, "TYPE_OOMD") and "fleet_oomd_kills_6h" in m.TYPE_OOMD, m.TYPE_OOMD
assert "FleetOomdKillsHigh" in m.HELP_OOMD, "HELP must name the alert"
assert "2.0" in m.HELP_OOMD, "HELP must name the 2.0 raise"
assert callable(m._oomd_kills_6h), "_oomd_kills_6h must be callable"
print("OK: HELP_OOMD/TYPE_OOMD constants + _oomd_kills_6h helper present")
PY

# Parse both oomd log shapes, scope to fleet units, ignore noise.
OOMD_STUB="$scratch/oomd-journal.txt"
cat >"$OOMD_STUB" <<'EOF'
Killed process 12345 (pi) in unit pi-issue@fleet-ops-4164.service.
Killed process 12346 (pi) in unit pi-issue@0509-1752.service.
Killed unit pi-issue@fleet-ops-3737.service.
Killed unit app-pi-issue.slice.
Killed process 999 (node) in unit some-other-app.service.
out of memory: Killed process 4242 (chrome) total-vm:4096kB anon-rss:2048kB
Killed process 12347 (pi) in unit pi-issue@fleet-ops-4164.service.
EOF
python3 - "$exporter" "$OOMD_STUB" <<'PY' || fail "_oomd_kills_6h parse/scope failed"
import importlib.util, os, sys
exp_path, stub = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("fme", exp_path)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
os.environ["FLEET_OOMD_JOURNAL_STUB"] = stub
counts = m._oomd_kills_6h()
# pi-issue@fleet-ops-4164 killed twice (process + process), pi-issue@0509-1752
# once (process), pi-issue@fleet-ops-3737 once (unit), app-pi-issue once (unit).
assert counts.get("pi-issue@fleet-ops-4164") == 2, counts
assert counts.get("pi-issue@0509-1752") == 1, counts
assert counts.get("pi-issue@fleet-ops-3737") == 1, counts
assert counts.get("app-pi-issue") == 1, counts
# Unrelated service and kernel OOM line must NOT be counted.
assert "some-other-app" not in counts, counts
assert all("chrome" not in k for k in counts), counts
assert sum(counts.values()) == 5, counts
print(f"OK: _oomd_kills_6h parsed both log shapes, scoped to fleet units, ignored noise (n={sum(counts.values())})")
PY

# main() emits the gauge lines for a stubbed journal.
OOMD_OUT="$scratch/oomd-out.prom"
python3 - "$exporter" "$OOMD_OUT" "$OOMD_STUB" <<'PY' || fail "main() oomd emission failed"
import importlib.util, json, os, sys
from pathlib import Path
exp_path, out_path, stub = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("fme", exp_path)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
os.environ["FLEET_OOMD_JOURNAL_STUB"] = stub
m.OUT = Path(out_path)
m.SELF_MAINT_JSON_DEFAULT = Path("/nonexistent/sm.json")
m.SELF_MAINT_JSON_FALLBACK = Path("/nonexistent/sm2.json")
m.SEAT_HEALTH = Path("/nonexistent/seat.json")
m.SEAT_LEDGER = Path("/nonexistent/ledger")
m.SEAT_CAPS_DEFAULT = Path("/nonexistent/caps.json")
m.SEAT_CAPS_FALLBACK = Path("/nonexistent/caps2.json")
m.SEAT_CAPS_LIVE = Path("/nonexistent/caps3.json")
m.HC_URL_FILE = Path("/nonexistent/hc.url")
m.ACTIONS_LOG = Path("/nonexistent/actions.log")
m.MAINTENANCE_FLAG = Path("/nonexistent/maint.json")
m.INTAKE_JSON_DEFAULT = Path("/nonexistent/intake.json")
m.INTAKE_JSON_FALLBACK = Path("/nonexistent/intake2.json")
m.KEYSTONE_LEDGER = Path("/nonexistent/keystone.jsonl")
m.WORKTREE_REAPER_SUMMARY = Path("/nonexistent/reaper.json")
m.STALENESS_CACHE = Path("/nonexistent/stale.json")
m.PR_CACHE_DIR = Path(os.path.dirname(out_path))
m.DETAIL_CACHE = Path(os.path.dirname(out_path)) / "detail.cache.json"
m._list_timers = lambda: [{"unit": "fleet-metrics-export.timer", "last_usec": 0}]
m._timer_active = lambda unit: 1
m._read_seat = lambda: (1, 0)
m._merged_prs_detail = lambda: []
m._repo_snapshot = lambda: None
m._queue_composition = lambda: {"ready-work": {"total": 0, "self": 0}, "agent-ready": {"total": 0, "self": 0}}
m._escalations_24h = lambda: {}
m._repair_log_counts_24h = lambda: (0, 0)
m._worker_units = lambda: []
m._standalone_pi_print_count = lambda u: 0
m._maintenance_quiescing = lambda: 0
m._keystone_routing_counts = lambda: (0, 0, None)
m._ping_healthcheck = lambda: None
m._fetch_openrouter_credits = lambda: None
m._fetch_xkiro_usage = lambda: None
m._fetch_openrouter_key = lambda: None
m._fetch_claude_usage = lambda: None
m._fetch_codex_usage = lambda: None
m._fetch_cursor_usage = lambda: None
m._fetch_devin_usage = lambda: None
m._fetch_xkiro_quota = lambda: None
m._GH_FETCHED_THIS_RUN = False
m._fetch_signups_7d = lambda: None
rc = m.main()
assert rc == 0, f"main rc={rc}"
body = Path(out_path).read_text()
assert "# HELP fleet_oomd_kills_6h" in body, "missing HELP"
assert "# TYPE fleet_oomd_kills_6h gauge" in body, "missing TYPE"
assert 'fleet_oomd_kills_6h{unit="pi-issue@fleet-ops-4164"} 2' in body, body
assert 'fleet_oomd_kills_6h{unit="app-pi-issue"} 1' in body, body
# one HELP / one TYPE
assert body.count("# HELP fleet_oomd_kills_6h") == 1, "duplicate HELP"
assert body.count("# TYPE fleet_oomd_kills_6h") == 1, "duplicate TYPE"
print("OK: main() emits fleet_oomd_kills_6h gauges (HELP/TYPE once) for a stubbed journal")
PY

# Alert rule shape: name, expr, severity=critical (repair-dispatch, NOT page).
grep -q "alert: FleetOomdKillsHigh" "$rules" \
  || fail "fleet_rules.yml missing FleetOomdKillsHigh (fleet-ops#4164)"
grep -q 'sum(fleet_oomd_kills_6h) > 3' "$rules" \
  || fail "FleetOomdKillsHigh must trip on sum(fleet_oomd_kills_6h) > 3"
oomd_block="$(awk '/- alert: FleetOomdKillsHigh/,/- alert: FleetThroughputCollapse/' "$rules")"
[[ -n "$oomd_block" ]] || fail "could not extract FleetOomdKillsHigh block"
grep -q "severity: critical" <<<"$oomd_block" \
  || fail "FleetOomdKillsHigh must be severity=critical (repair-dispatch route, not phone page)"
grep -q "service: fleet" <<<"$oomd_block" \
  || fail "FleetOomdKillsHigh must carry service=fleet"
grep -q "ram_gb_per_worker" <<<"$oomd_block" \
  || fail "FleetOomdKillsHigh description must name ram_gb_per_worker (the live charge to raise)"
grep -q "2.0" <<<"$oomd_block" \
  || fail "FleetOomdKillsHigh description must name the 2.0 raise target"
# Must NOT be severity=page (only RepairDispatchDown pages).
if grep -q "severity: page" <<<"$oomd_block"; then
  fail "FleetOomdKillsHigh must NOT be severity=page (only RepairDispatchDown pages)"
fi
ok "fleet-ops#4164: FleetOomdKillsHigh rule shape (expr, severity=critical, names ram_gb_per_worker 2.0 raise)"

# =========================================================================
# fleet-ops#4118: worktree reaper gauge family. The reaper
# (bin/fleet-worktree-reaper) writes a daily summary JSON; the exporter
# reads it to emit the count metric the heartbeat can gauge
# (fleet_worktree_dirs) plus a liveness signal. Pins:
#   - _read_worktree_reaper parses a present summary into the count fields
#   - degradation: missing / unparseable / stale summary -> present=False
#   - main() emits the present gauge always, and the count + heartbeat
#     gauges only when the summary is present and fresh
# =========================================================================
python3 - "$exporter" <<'PY' || fail "worktree reaper constants/helper missing"
import importlib.util, sys
exp_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("fme", exp_path)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert hasattr(m, "HELP_WTP") and "fleet_worktree_reaper_present" in m.HELP_WTP, m.HELP_WTP
assert hasattr(m, "TYPE_WTP") and "fleet_worktree_reaper_present" in m.TYPE_WTP, m.TYPE_WTP
assert hasattr(m, "HELP_WTD") and "fleet_worktree_dirs" in m.HELP_WTD, m.HELP_WTD
assert hasattr(m, "TYPE_WTD") and "fleet_worktree_dirs" in m.TYPE_WTD, m.TYPE_WTD
assert hasattr(m, "HELP_WTR") and "fleet_worktree_reaped" in m.HELP_WTR, m.HELP_WTR
assert hasattr(m, "HELP_WTHB") and "fleet_worktree_reaper_heartbeat_seconds" in m.HELP_WTHB, m.HELP_WTHB
assert callable(m._read_worktree_reaper), "_read_worktree_reaper must be callable"
print("OK: worktree reaper HELP/TYPE constants + _read_worktree_reaper helper present")
PY

# _read_worktree_reaper: present summary -> counts; missing/unparseable/stale -> present=False.
WT_SUMMARY="$scratch/reaper-summary.json"
cat >"$WT_SUMMARY" <<'JSON'
{"script":"fleet-worktree-reaper","ts":"2026-09-07T13:33:53Z","scanned":307,"reaped":14,"post_count":326,"pre_count":341,"bound_breached":0,"skipped_dirty":60,"skipped_notpushed":137,"skipped_live":9,"skipped_young":14,"skipped_unmerged":60,"skipped_notterminal":12,"salvaged":0,"failed":1}
JSON
python3 - "$exporter" "$WT_SUMMARY" <<'PY' || fail "_read_worktree_reaper parse/degrade failed"
import importlib.util, json, os, sys, time
from pathlib import Path
exp_path, summary = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("fme", exp_path)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

# present summary
m.WORKTREE_REAPER_SUMMARY = Path(summary)
r = m._read_worktree_reaper()
assert r["present"] is True, r
assert r["post_count"] == 326, r
assert r["reaped"] == 14, r
assert r["scanned"] == 307, r
assert r["bound_breached"] == 0, r
assert r["skipped_dirty"] == 60, r
assert r["age_s"] is not None and r["age_s"] >= 0, r
print("OK: _read_worktree_reaper parses a present summary into count fields")

# missing
m.WORKTREE_REAPER_SUMMARY = Path("/nonexistent/reaper.json")
r = m._read_worktree_reaper()
assert r["present"] is False and r["reason"] == "summary-missing", r
print("OK: _read_worktree_reaper degrades to summary-missing")

# unparseable
bad = Path(summary + ".bad")
bad.write_text("{not json")
m.WORKTREE_REAPER_SUMMARY = bad
r = m._read_worktree_reaper()
assert r["present"] is False and r["reason"] == "summary-unparseable", r
print("OK: _read_worktree_reaper degrades to summary-unparseable")

# stale (older than WORKTREE_REAPER_STALE_S)
stale = Path(summary + ".stale")
stale_ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - m.WORKTREE_REAPER_STALE_S - 3600))
stale.write_text(json.dumps({"ts": stale_ts, "post_count": 5}))
m.WORKTREE_REAPER_SUMMARY = stale
r = m._read_worktree_reaper()
assert r["present"] is False and r["reason"] == "summary-stale", r
print("OK: _read_worktree_reaper degrades to summary-stale")
PY

# main() emits the present gauge always; count + heartbeat gauges only when present+fresh.
WT_OUT="$scratch/wt-out.prom"
python3 - "$exporter" "$WT_OUT" "$WT_SUMMARY" <<'PY' || fail "main() worktree gauge emission failed"
import importlib.util, json, os, sys
from pathlib import Path
exp_path, out_path, summary = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("fme", exp_path)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.OUT = Path(out_path)
m.SELF_MAINT_JSON_DEFAULT = Path("/nonexistent/sm.json")
m.SELF_MAINT_JSON_FALLBACK = Path("/nonexistent/sm2.json")
m.SEAT_HEALTH = Path("/nonexistent/seat.json")
m.SEAT_LEDGER = Path("/nonexistent/ledger")
m.SEAT_CAPS_DEFAULT = Path("/nonexistent/caps.json")
m.SEAT_CAPS_FALLBACK = Path("/nonexistent/caps2.json")
m.SEAT_CAPS_LIVE = Path("/nonexistent/caps3.json")
m.HC_URL_FILE = Path("/nonexistent/hc.url")
m.ACTIONS_LOG = Path("/nonexistent/actions.log")
m.MAINTENANCE_FLAG = Path("/nonexistent/maint.json")
m.INTAKE_JSON_DEFAULT = Path("/nonexistent/intake.json")
m.INTAKE_JSON_FALLBACK = Path("/nonexistent/intake2.json")
m.KEYSTONE_LEDGER = Path("/nonexistent/keystone.jsonl")
m.STALENESS_CACHE = Path("/nonexistent/stale.json")
m.PR_CACHE_DIR = Path(os.path.dirname(out_path))
m.DETAIL_CACHE = Path(os.path.dirname(out_path)) / "detail.cache.json"
m.WORKTREE_REAPER_SUMMARY = Path(summary)
m._list_timers = lambda: [{"unit": "fleet-metrics-export.timer", "last_usec": 0}]
m._timer_active = lambda unit: 1
m._read_seat = lambda: (1, 0)
m._merged_prs_detail = lambda: []
m._repo_snapshot = lambda: None
m._queue_composition = lambda: {"ready-work": {"total": 0, "self": 0}, "agent-ready": {"total": 0, "self": 0}}
m._escalations_24h = lambda: {}
m._oomd_kills_6h = lambda: {}
m._repair_log_counts_24h = lambda: (0, 0)
m._worker_units = lambda: []
m._standalone_pi_print_count = lambda u: 0
m._maintenance_quiescing = lambda: 0
m._keystone_routing_counts = lambda: (0, 0, None)
m._ping_healthcheck = lambda: None
m._fetch_openrouter_credits = lambda: None
m._fetch_xkiro_usage = lambda: None
m._fetch_openrouter_key = lambda: None
m._fetch_claude_usage = lambda: None
m._fetch_codex_usage = lambda: None
m._GH_FETCHED_THIS_RUN = False
m._fetch_signups_7d = lambda: None
rc = m.main()
assert rc == 0, f"main rc={rc}"
body = Path(out_path).read_text()
# present + count + reaped + heartbeat gauges emitted for a fresh summary.
assert "fleet_worktree_reaper_present 1" in body, body
assert "fleet_worktree_dirs 326" in body, body
assert "fleet_worktree_reaped 14" in body, body
assert "# HELP fleet_worktree_dirs" in body, "missing HELP"
assert "# TYPE fleet_worktree_dirs gauge" in body, "missing TYPE"
assert "# HELP fleet_worktree_reaper_present" in body, "missing present HELP"
assert "# TYPE fleet_worktree_reaper_present gauge" in body, "missing present TYPE"
assert "fleet_worktree_reaper_heartbeat_seconds " in body, "missing heartbeat gauge"
# one HELP / one TYPE per metric name
assert body.count("# HELP fleet_worktree_dirs") == 1, "duplicate HELP"
assert body.count("# TYPE fleet_worktree_dirs") == 1, "duplicate TYPE"
assert body.count("# HELP fleet_worktree_reaper_present") == 1, "duplicate present HELP"
assert body.count("# TYPE fleet_worktree_reaper_present") == 1, "duplicate present TYPE"
print("OK: main() emits worktree reaper gauges (present + count + reaped + heartbeat) for a fresh summary")
PY

# main() with a MISSING summary: present gauge = 0, count gauges omitted.
WT_OUT2="$scratch/wt-out2.prom"
python3 - "$exporter" "$WT_OUT2" <<'PY' || fail "main() worktree gauge missing-summary failed"
import importlib.util, os, sys
from pathlib import Path
exp_path, out_path = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("fme", exp_path)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.OUT = Path(out_path)
m.SELF_MAINT_JSON_DEFAULT = Path("/nonexistent/sm.json")
m.SELF_MAINT_JSON_FALLBACK = Path("/nonexistent/sm2.json")
m.SEAT_HEALTH = Path("/nonexistent/seat.json")
m.SEAT_LEDGER = Path("/nonexistent/ledger")
m.SEAT_CAPS_DEFAULT = Path("/nonexistent/caps.json")
m.SEAT_CAPS_FALLBACK = Path("/nonexistent/caps2.json")
m.SEAT_CAPS_LIVE = Path("/nonexistent/caps3.json")
m.HC_URL_FILE = Path("/nonexistent/hc.url")
m.ACTIONS_LOG = Path("/nonexistent/actions.log")
m.MAINTENANCE_FLAG = Path("/nonexistent/maint.json")
m.INTAKE_JSON_DEFAULT = Path("/nonexistent/intake.json")
m.INTAKE_JSON_FALLBACK = Path("/nonexistent/intake2.json")
m.KEYSTONE_LEDGER = Path("/nonexistent/keystone.jsonl")
m.STALENESS_CACHE = Path("/nonexistent/stale.json")
m.PR_CACHE_DIR = Path(os.path.dirname(out_path))
m.DETAIL_CACHE = Path(os.path.dirname(out_path)) / "detail.cache.json"
m.WORKTREE_REAPER_SUMMARY = Path("/nonexistent/reaper.json")
m._list_timers = lambda: [{"unit": "fleet-metrics-export.timer", "last_usec": 0}]
m._timer_active = lambda unit: 1
m._read_seat = lambda: (1, 0)
m._merged_prs_detail = lambda: []
m._repo_snapshot = lambda: None
m._queue_composition = lambda: {"ready-work": {"total": 0, "self": 0}, "agent-ready": {"total": 0, "self": 0}}
m._escalations_24h = lambda: {}
m._oomd_kills_6h = lambda: {}
m._repair_log_counts_24h = lambda: (0, 0)
m._worker_units = lambda: []
m._standalone_pi_print_count = lambda u: 0
m._maintenance_quiescing = lambda: 0
m._keystone_routing_counts = lambda: (0, 0, None)
m._ping_healthcheck = lambda: None
m._fetch_openrouter_credits = lambda: None
m._fetch_xkiro_usage = lambda: None
m._fetch_openrouter_key = lambda: None
m._fetch_claude_usage = lambda: None
m._fetch_codex_usage = lambda: None
m._GH_FETCHED_THIS_RUN = False
m._fetch_signups_7d = lambda: None
rc = m.main()
assert rc == 0, f"main rc={rc}"
body = Path(out_path).read_text()
assert "fleet_worktree_reaper_present 0" in body, body
assert "fleet_worktree_dirs" not in body, "count gauge must be omitted when summary missing: " + body
assert "fleet_worktree_reaped" not in body, "reaped gauge must be omitted when summary missing: " + body
print("OK: main() emits present=0 and omits count gauges when the summary is missing")
PY
ok "fleet-ops#4118: worktree reaper gauge family (present + count + reaped + heartbeat)"

# =========================================================================
# 12. fleet-ops#4217: fleet_seat_quota_observed_seconds reports the REAL age
#     of the quota figure, and the stale-quota alert rule exists.
# =========================================================================
# The pre-fix exporter passed `now` as the quota observation time, so
# observed_seconds was always ~0 even when a dying fetch served a 25-min-old
# cache — the metric that must power the "Stale >15 min => absent" alert could
# never fire because it never reported a real age. This pins: (a) a stale
# cache returns its own ts as observed_at (truthful age, not None), (b) the
# emitted observed_seconds is that age (non-zero), and (c) fleet_rules.yml
# carries the new FleetSeatQuotaStale rule keyed on observed_seconds > 900.
cat >"$scratch/quota-stale.test.py" <<'PY'
import importlib.util, json, sys, time
from pathlib import Path
exporter, rules, cache_path = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("fme", exporter)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# 1. A stale quota cache: its own ts is 1200s in the past.
stale_ts = time.time() - 1200
Path(cache_path).write_text(json.dumps({
    "ts": stale_ts,
    "data": [{"pct": 42.0, "reset_s": 3600.0, "window": "daily"}],
}))

# 2. A dying fetch: cache is older than QUOTA_TTL and the fetcher fails, so
#    _cached_quota_json must serve the stale cache WITH its true ts.
data, obs = m._cached_quota_json(Path(cache_path), lambda: None, "testquota")
assert data is not None, "stale cache should still be served while <= QUOTA_STALE_CACHE"
assert obs is not None, "stale cache must carry its true observation ts (never fresh-looking None)"
assert abs(obs - stale_ts) < 2, f"observed_at must be the cache ts, got {obs} (expected ~{stale_ts})"

# 3. Emit through _emit_seat_quota; observed_seconds must be the real age.
lines = []
m._emit_seat_quota(lines, "testquota", data, "api", obs)
obs_line = next(l for l in lines if l.startswith("fleet_seat_quota_observed_seconds"))
val = float(obs_line.split()[-1])
assert val > 900, f"observed_seconds must reflect the stale age (>900), got {val}"
assert val < 1260, f"observed_seconds sanity bound, got {val}"

# 4. A FRESH observation still reports ~0 (a healthy read is not flagged stale).
lines2 = []
m._emit_seat_quota(lines2, "testquota", data, "api", time.time())
obs2 = float(next(l for l in lines2 if l.startswith("fleet_seat_quota_observed_seconds")).split()[-1])
assert obs2 < 600, f"fresh observation must report ~0 observed_seconds, got {obs2}"
print("OK: stale quota cache carries its true ts -> fleet_seat_quota_observed_seconds reports real age")

# 5. The stale-quota alert rule exists and keys on the staleness metric.
Y = __import__("yaml")
cfg = Y.safe_load(Path(rules).read_text())
names = [r.get("alert") for g in cfg["groups"] for r in g.get("rules", [])]
assert "FleetSeatQuotaStale" in names, "fleet_rules.yml must carry the FleetSeatQuotaStale alert (fleet-ops#4217)"
rule = next(r for g in cfg["groups"] for r in g.get("rules", []) if r.get("alert") == "FleetSeatQuotaStale")
expr = rule["expr"]
assert "fleet_seat_quota_observed_seconds" in expr, f"FleetSeatQuotaStale must key on observed_seconds, got: {expr}"
print("OK: fleet_rules.yml has FleetSeatQuotaStale keyed on fleet_seat_quota_observed_seconds (fleet-ops#4217)")
PY
python3 "$scratch/quota-stale.test.py" "$exporter" "$rules" "$scratch/stale-quota-cache.json" \
  || fail "quota-observed-staleness logic/rule failed"
ok "fleet-ops#4217: fleet_seat_quota_observed_seconds reports real age; FleetSeatQuotaStale rule present"

# =========================================================================
# 16d. fleet-ops#4582: 0509 signups_7d gauge (direction metric) — mocked D1.
# =========================================================================
# The direction metric (signups/week) is read live from 0509's D1 `user`
# table each tick over the sanctioned Cloudflare REST "query" path (same
# endpoint + token as lib/fleet-product-slo.py — no new credential).
# Acceptance pinned here, hermetic (no network, no token file):
#   (a) a mocked D1 response of 0 rows -> _fetch_signups_7d() returns 0 and
#       the output carries `fleet_signups_7d 0` (healthy empty table, NOT a
#       scrape error);
#   (b) a mocked D1 response of 3 rows -> _fetch_signups_7d() returns 3 and
#       the output carries `fleet_signups_7d 3`;
#   (c) a Cloudflare error / unreachable source -> None, so the family is
#       OMITTED (never a fabricated 0 — the exporter's no-fail-open rule).
S7_TEST="$scratch/s7.out"
python3 - "$exporter" "$S7_TEST" <<'PY' || fail "signups_7d unit test failed"
import importlib.util, json, sys
from pathlib import Path
exporter, out_path = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("fme", exporter)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

class _Resp:
    def __init__(self, payload):
        self._b = json.dumps(payload).encode("utf-8")
    def read(self):
        return self._b
    def __enter__(self):
        return self
    def __exit__(self, *a):
        return False

def _run(count_spec):
    """Return (fetch_result, body). _fetch_signups_7d returns the count;
    _emit_signups_7d writes it to a lines list as main() would."""
    m._s7_cf_token = lambda: "fake-token"
    def _urlopen(req, timeout=15):
        return _Resp(count_spec)
    m.urllib.request.urlopen = _urlopen  # noqa: B950
    got = m._fetch_signups_7d()
    lines = []
    m._emit_signups_7d(lines, got)
    return got, "\n".join(lines)

# (a) empty-but-reachable table -> 0, exported (not an error).
val, body = _run({"success": True, "result": [{"results": [{"n": 0}]}]})
assert val == 0, f"empty table must read 0, got {val}"
assert "fleet_signups_7d 0" in body, "gauge must be present with 0 for an empty table:\n" + body
assert body.count("# HELP fleet_signups_7d") == 1, body
assert body.count("# TYPE fleet_signups_7d gauge") == 1, body
print("OK: D1 mocked response 0 -> fleet_signups_7d 0 present (empty table is a value)")

# (b) three signups -> 3, present.
val, body = _run({"success": True, "result": [{"results": [{"n": 3}]}]})
assert val == 3, f"three signups must read 3, got {val}"
assert "fleet_signups_7d 3" in body, "three signups must be exported: " + body
print("OK: D1 mocked response 3 -> fleet_signups_7d 3 present")

# (c) Cloudflare error / unreachable source -> None -> family omitted (no 0).
val, body = _run({"success": False, "errors": [{"message": "boom", "code": 0}]})
assert val is None, f"cloudflare error must read unavailable (None), got {val}"
assert "fleet_signups_7d" not in body, "unreachable source must OMIT the family, not emit 0: " + body
assert "fleet_signups_7d 0" not in body and "fleet_signups_7d 3" not in body, body
print("OK: D1 unreachable -> family omitted (no fabricated 0)")

# (d) no token -> None (source read gate); never a fabricated 0.
m._s7_cf_token = lambda: None
assert m._fetch_signups_7d() is None
print("OK: no sanctioned token -> None (family omitted)")
PY
ok "fleet-ops#4582: signups_7d gauge present for mocked D1 0 and 3, omitted on unreachable"

# =========================================================================
# 16d-bis. fleet-ops#5001 (accept #4): the trailing-7-day signup window must
# parse BOTH sides. `user.createdAt` is ISO-8601 TEXT ('...T...Z') while
# datetime('now','-7 days') renders 'YYYY-MM-DD HH:MM:SS' — with no 'T' and
# no 'Z'. SQLite compares those as TEXT, so every row sitting on the cutoff
# CALENDAR DAY — including ones older than the cutoff — read as inside the
# window. The shipped `_S7_SQL` literal is executed here against a real
# in-memory sqlite3 DB, so this pins the SQL text itself, not a mock value:
#   fixture: 8d old -> EXCLUDED, 6d23h old -> INCLUDED -> exactly 1 row;
#   guard:   the pre-#5001 TEXT predicate counts 2 on that same DB (it drags
#            in a row on the cutoff calendar day that is older than the
#            cutoff), so the boundary above is proved to be doing work.
# =========================================================================
python3 - "$exporter" <<'PY' || fail "fleet-ops#5001: signups_7d window boundary failed"
import importlib.util, sqlite3, sys
from datetime import datetime, timedelta, timezone

spec = importlib.util.spec_from_file_location("fme", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

con = sqlite3.connect(":memory:")
con.execute("CREATE TABLE user (id TEXT, createdAt TEXT NOT NULL);")
# The cutoff's own calendar day, read from the same clock the SQL uses.
cutoff_day = con.execute("SELECT date('now','-7 days')").fetchone()[0]
now = datetime.now(timezone.utc)

def iso(delta):
    return (now - delta).strftime("%Y-%m-%dT%H:%M:%S.000Z")

con.executemany(
    "INSERT INTO user (id, createdAt) VALUES (?, ?);",
    [
        ("u_8d", iso(timedelta(days=8))),               # 8 days old: OUTSIDE
        ("u_6d23h", iso(timedelta(days=6, hours=23))),  # 6d23h old: INSIDE
        # Older than the cutoff, but on the cutoff calendar day: the row the
        # TEXT comparison wrongly swallows.
        ("u_stale_cutoff_day", cutoff_day + "T00:00:00.000Z"),
    ],
)

# (a) the SHIPPED literal counts exactly the 6d23h row.
sql = m._S7_SQL
got = con.execute(sql).fetchone()[0]
assert got == 1, (
    f"_S7_SQL must count only the 6d23h row (8d excluded), got {got} "
    f"from {sql!r}"
)

# (b) guard: the pre-#5001 TEXT predicate is wrong on this same fixture, so
# (a) cannot be green for the wrong reason (e.g. a fixture that never
# exercises the boundary at all).
old = (
    "SELECT COUNT(*) AS n FROM user "
    "WHERE createdAt >= datetime('now','-7 days');"
)
wrong = con.execute(old).fetchone()[0]
assert wrong == 2, (
    "the old TEXT predicate must wrongly count 2 rows (6d23h + the older "
    f"cutoff-day row), got {wrong}"
)

# (c) the committed literal itself is the parse-both-sides form, so a
# regression in the SQL text is caught directly.
assert "julianday(createdAt)" in sql, f"column must be parsed as a date: {sql!r}"
assert "julianday('now','-7 days')" in sql, f"cutoff must be parsed: {sql!r}"
assert "datetime('now','-7 days')" not in sql, f"TEXT cutoff regressed: {sql!r}"
print("OK: _S7_SQL counts 1 (8d excluded, 6d23h included); TEXT predicate counts 2")
PY
ok "fleet-ops#5001: signups_7d trailing-7d SQL parses both sides (8d row excluded, 6d23h included)"

# =========================================================================
# fleet-ops#4481: a worker-token mint failure degrades the tick to READ-ONLY.
# The fleet-ops#3445 guard still refuses a human-identity WRITE (the
# week-later revert-candidate gh issue create is skipped). The rest of the
# tick still writes fleet.prom and exits 0, so a transient mint hiccup
# cannot blank every fleet_* gauge or trip unit-escalation.
# =========================================================================
MINT_FAIL_OUT="$scratch/mint-fail.prom"
MINT_FAIL_BIN="$scratch/worker-token-fail"
cat >"$MINT_FAIL_BIN" <<'EOF'
#!/bin/bash
# Exact trip journal from fleet-metrics-export.service 2026-09-08T06:10:01Z.
echo "worker-token --print rc=3 - refusing human-gh writes: no installation of nishfleet-worker in org 'Nishfleet'" >&2
exit 3
EOF
chmod +x "$MINT_FAIL_BIN"
python3 - "$exporter" "$MINT_FAIL_OUT" "$MINT_FAIL_BIN" <<'PY' || fail "mint-failure degrade test failed"
import contextlib, importlib.util, io, os, sys
from pathlib import Path
exp_path, out_path, wt_bin = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("fme", exp_path)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

# Production-shaped env: no inherited token, not Actions, real gh name.
# Otherwise _ensure_worker_token early-returns and this path is untested.
os.environ.pop("GITHUB_ACTIONS", None)
os.environ.pop("GH_TOKEN", None)
os.environ["GH"] = "gh"
os.environ["NISHFLEET_WORKER_TOKEN_BIN"] = wt_bin

m.OUT = Path(out_path)
m.LEGACY_STALENESS_PROM = Path("/nonexistent/fleet-staleness.prom")
m.SELF_MAINT_JSON_DEFAULT = Path("/nonexistent/sm.json")
m.SELF_MAINT_JSON_FALLBACK = Path("/nonexistent/sm2.json")
m.SEAT_HEALTH = Path("/nonexistent/seat.json")
m.SEAT_LEDGER = Path("/nonexistent/ledger")
m.SEAT_CAPS_DEFAULT = Path("/nonexistent/caps.json")
m.SEAT_CAPS_FALLBACK = Path("/nonexistent/caps2.json")
m.SEAT_CAPS_LIVE = Path("/nonexistent/caps3.json")
m.HC_URL_FILE = Path("/nonexistent/hc.url")
m.ACTIONS_LOG = Path("/nonexistent/actions.log")
m.MAINTENANCE_FLAG = Path("/nonexistent/maint.json")
m.INTAKE_JSON_DEFAULT = Path("/nonexistent/intake.json")
m.INTAKE_JSON_FALLBACK = Path("/nonexistent/intake2.json")
m.KEYSTONE_LEDGER = Path("/nonexistent/keystone.jsonl")
m.WORKTREE_REAPER_SUMMARY = Path("/nonexistent/reaper.json")
m.STALENESS_CACHE = Path("/nonexistent/stale.json")
m.PR_CACHE_DIR = Path(os.path.dirname(out_path))
m.DETAIL_CACHE = Path(os.path.dirname(out_path)) / "detail.cache.json"
m._list_timers = lambda: [{"unit": "fleet-metrics-export.timer", "last_usec": 0}]
m._timer_active = lambda unit: 1
m._read_seat = lambda: (1, 0)
m._merged_prs_detail = lambda: []
m._repo_snapshot = lambda: None
m._queue_composition = lambda: {"ready-work": {"total": 0, "self": 0}, "agent-ready": {"total": 0, "self": 0}}
m._escalations_24h = lambda: {}
m._oomd_kills_6h = lambda: {}
m._repair_log_counts_24h = lambda: (0, 0)
m._worker_units = lambda: []
m._standalone_pi_print_count = lambda u: 0
m._maintenance_quiescing = lambda: 0
m._keystone_routing_counts = lambda: (0, 0, None)
m._ping_healthcheck = lambda: None
m._fetch_openrouter_credits = lambda: None
m._fetch_xkiro_usage = lambda: None
m._fetch_openrouter_key = lambda: None
m._fetch_claude_usage = lambda: None
m._fetch_codex_usage = lambda: None
m._fetch_cursor_usage = lambda: None
m._fetch_devin_usage = lambda: None
m._fetch_xkiro_quota = lambda: None
m._GH_FETCHED_THIS_RUN = False
m._fetch_signups_7d = lambda: None

def _week_later_must_not_run():
    raise AssertionError("week-later write must be skipped on mint failure")
m._week_later_revert_check = _week_later_must_not_run

err = io.StringIO()
with contextlib.redirect_stderr(err):
    rc = m.main()
assert rc == 0, f"mint failure must exit 0 (degrade, not fail-close), got rc={rc} stderr={err.getvalue()}"
assert Path(out_path).exists(), "mint failure must still write fleet.prom"
body = Path(out_path).read_text()
assert "fleet_ready_work" in body, "fleet.prom must carry the ready_work gauge:\n" + body
log = err.getvalue()
assert "READ-ONLY" in log, log
assert "week-later: skipped (app token unavailable — no human-gh write)" in log, log
assert "app token unavailable this tick" in log, log
print("OK: token-mint-failure still writes fleet.prom and exits 0 with the write skipped")
PY
ok "fleet-ops#4481: mint failure writes fleet.prom, exits 0, skips the week-later write"

# fleet-ops#4508: prevent the next hardcoded-epoch time-bomb from re-red'ing
# this P14 step. Hosted here (not in .github/workflows/ci.yml) so worker
# tokens can wire it without a workflow-file edit; this file is already on
# the P14 path.
bash "$here/hardcoded-epoch-guard.test.sh"
ok "fleet-ops#4508: hardcoded-epoch guard green on P14 path"

# fleet-ops#4643: prompt prefix-cache layout — stable prefix first, volatile
# tail last. Hosted here (not in .github/workflows/ci.yml) so worker tokens
# can wire it without a workflow-file edit.
bash "$here/packet-layout.test.sh" || fail "packet-layout tests failed"
ok "fleet-ops#4643: packet-layout determinism green on P14 path"

# fleet-ops#4643: FleetPromptCacheHitLow alert + seat-caps TTL comment.
bash "$here/fleet-prompt-cache-hit-alert.test.sh" || fail "fleet-prompt-cache-hit-alert tests failed"
ok "fleet-ops#4643: fleet-prompt-cache-hit-alert green on P14 path"
