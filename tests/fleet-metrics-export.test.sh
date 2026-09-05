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
# fleet-ops#2712: provider-level quota exhaustion alert — one billing wall,
# many seats. Pin that the rule name + expr are present in fleet_rules.yml.
grep -q "alert: FleetProviderQuotaExhausted" "$rules" \
  || fail "fleet_rules.yml missing FleetProviderQuotaExhausted (fleet-ops#2712)"
grep -q "fleet_provider_quota_exhausted_total > 0" "$rules" \
  || fail "provider-quota-exhausted rule must trip on fleet_provider_quota_exhausted_total > 0"
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
print("OK: _read_comeback_overdue counts past-wall seats, excludes bench/test/corpse + mid-cycle (<1 interval)")

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
n3, seats3 = m._read_healthy_cap0()
assert n3 == 0, f"cap3 config: healthy-cap0 must be 0 (glm-5-2 restored), got {n3}: {seats3}"
print("OK: cap-restored config -> healthy-cap0_total 0 (restore cleared the alarm)")

# --- missing config -> fail safe to 0 (no false alarm from a missing file) ---
m.SEAT_CAPS_DEFAULT = Path("/nonexistent/hc0-caps.json")
m.SEAT_CAPS_FALLBACK = Path("/nonexistent/hc0-caps-fallback.json")
n_miss, _ = m._read_healthy_cap0()
assert n_miss == 0, f"missing config must fail safe to 0, got {n_miss}"
print("OK: missing config -> healthy-cap0_total 0 (fail safe)")

# --- model-cap map parses both bare-int and {cap,class} object values ---
m.SEAT_CAPS_DEFAULT = Path(caps_cap0)
m.SEAT_CAPS_FALLBACK = Path(caps_cap0)
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
m._GH_FETCHED_THIS_RUN = False
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

def session(provider, model, ts, has_pr):
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
    lines = [
        json.dumps({"type": "session", "version": 3, "timestamp": base, "id": f"{issue}-{ts}"}),
        json.dumps({"type": "model_change", "provider": provider, "modelId": model, "timestamp": base}),
        json.dumps({"type": "message", "message": {"role": "assistant", "content": content}, "timestamp": base}),
    ]
    path.write_text("\n".join(lines))
    return path

# devin/glm-5-2: 5 sessions, some with PR -> provisional 0.5 (<20)
for i in range(5):
    session("devin", "glm-5-2", f"00:00:{i:02d}", i % 2 == 0)

# opencode/mimo-v2.5-free: exactly 20 sessions, 5 with PR -> 0.25
for i in range(20):
    session("opencode", "mimo-v2.5-free", f"01:00:{i:02d}", i % 4 == 0)

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

# 1. Missing file -> all four series 0, family present with HELP/TYPE once.
with tempfile.TemporaryDirectory() as td:
    m.MERGED_PR_CLOSE_JSON = Path(td) / "missing.json"
    lines = []
    m._emit_observe_to_close(lines)
    out = "\n".join(lines)
    assert "fleet_observe_to_close_total" in out, out
    assert out.count("# HELP fleet_observe_to_close_total") == 1, out
    assert out.count("# TYPE fleet_observe_to_close_total") == 1, out
    for r in ["claim-branch","closes-trailer","bare-mention","protected"]:
        assert f'fleet_observe_to_close_total{{reason="{r}"}} 0' in out, out
    print("OK: missing file -> 4 series all 0, HELP/TYPE once")

# 2. Legal closes (claim-branch + closes-trailer) are emitted faithfully;
#    a WRONG bare-mention close is emitted too so the alert can fire.
with tempfile.TemporaryDirectory() as td:
    p = Path(td) / "merged-pr-close.json"
    p.write_text(json.dumps({
        "closed": 2,
        "closes_by_reason": {
            "claim-branch": 1,
            "closes-trailer": 1,
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
    assert 'reason="bare-mention"} 1' in out, out
    assert 'reason="protected"} 0' in out, out
    print("OK: summary with a wrong bare-mention close is emitted faithfully (alert can fire)")

# 3. Unparseable file -> all four 0 (no crash).
with tempfile.TemporaryDirectory() as td:
    p = Path(td) / "bad.json"
    p.write_text("{not json")
    m.MERGED_PR_CLOSE_JSON = p
    lines = []
    m._emit_observe_to_close(lines)
    out = "\n".join(lines)
    assert 'reason="claim-branch"} 0' in out, out
    print("OK: unparseable file -> 4 series all 0 (no crash)")
PY

ok "fleet-ops#3231: fleet_observe_to_close_total{reason} emitted (missing/legit/wrong/unparseable)"

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
PY

ok "fleet-ops#3124 part 4/4: week-later revert-candidate check pinned"
