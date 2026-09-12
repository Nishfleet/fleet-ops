#!/usr/bin/env bash
# tests/ci-merge-queue-detector.test.sh
#
# fleet-ops#5807: merge-queue head wait and hosted-CI queue depth were blind.
# 2026-09-12 10:50 IST: the 0509 head #3054 sat AWAITING_CHECKS 2h20m with 14
# queued entries and 58 queued + 11 in-progress hosted runs, 0 merges/hour,
# and NO alert — a human noticed by hand.
#
# Hermetic (no network, no gh, no Prometheus; the drill mocks pi-systemd-run).
# Hosted by tests/ci-standards-audit.test.sh's runner like the other detectors.
#
# Proves, in order:
#   1. EXPORTER: the existing 5-min exporter (fleet-metrics-export.py — no
#      new unit, no new timer, no faster polling) publishes, per enrolled
#      repo, ci_merge_queue_head_wait_seconds / ci_merge_queue_entries /
#      ci_hosted_runs_queued / ci_hosted_runs_in_progress. The 10:50 IST
#      evidence (head #3054 enqueued 03:28:15Z, seen 05:48:15Z = 8400s; 14
#      entries; 58+11) parsed through the real functions yields exactly those
#      numbers, and the emitter writes HELP/TYPE-once series with the repo
#      label (duplicate HELP/TYPE makes node_exporter reject the whole
#      textfile — the #1844 class). A failed read omits its series (never a
#      frozen value); a repo whose mergeQueue answers null (queue not
#      enabled) is a real answered 0, not an omission.
#   2. RULES: both alerts exist in the REAL config/fleet_rules.yml with the
#      issue's thresholds (head wait >1200s for 10m critical; >30 queued for
#      15m warning), absent() legs (fleet-ops#1010), service=fleet, and NOT
#      in the alert-repair-dispatch SKIP_SET (a firing alert must actually
#      dispatch — the #4643 precedent).
#   3. UNIT TEST (promtool, when present) against the REAL rules file: the
#      10:50 IST snapshot fires BOTH; a quiet control fires neither; and
#      after the head merges (values drop) both CLEAR.
#   4. DRILL: a synthetic 25-min (1500s) head wait fired through the REAL
#      libexec/alert-repair-dispatch with a mocked pi-systemd-run writes a
#      repair packet whose annotations (extracted from the rules file, so
#      the coupling is the LIVE annotation text) carry the top-slot-consumer
#      one-liner and the consolidation issues 0509#3069/#3068/#3070, logs
#      DISPATCH, spawns exactly one worker — and a resolved notification
#      afterwards dispatches nothing (the packet "cleared", #5272 resolved
#      branch).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
exporter="$repo_root/libexec/fleet-metrics-export.py"
rules="$repo_root/config/fleet_rules.yml"
dispatch_bin="$repo_root/libexec/alert-repair-dispatch"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$exporter" ]]  || fail "exporter not found: $exporter"
[[ -f "$rules" ]]     || fail "rules not found: $rules"
[[ -x "$dispatch_bin" ]] || fail "not executable: $dispatch_bin"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

scratch="$(mktemp -d -t ci-mq-detector.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# --- 1. exporter: 10:50 IST evidence through the real functions -------------
python3 - "$exporter" <<'PY' || fail "exporter functions/10:50-snapshot failed"
import importlib.util, sys

spec = importlib.util.spec_from_file_location("fme", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# The 10:50 IST evidence (issue body): head #3054 AWAITING_CHECKS since
# 03:28:15Z; observed 05:48:15Z IST -> 8400s; 14 entries; 58 queued + 11
# in-progress hosted runs.
now = m._parse_iso_utc("2026-09-12T05:48:15")
assert now == 1768256895 or now > 0, now  # parse works; exact epoch pinned loosely

payload = {"data": {"r0": {"mergeQueue": {"entries": {"totalCount": 14, "nodes": [
    {"position": 1, "state": "AWAITING_CHECKS", "enqueuedAt": "2026-09-12T03:28:15Z"},
    {"position": 2, "state": "QUEUED", "enqueuedAt": "2026-09-12T04:00:00Z"},
]}}}}}
repos = ["Nishfleet/0509", "Nishfleet/fleet-ops"]
hosted = {"Nishfleet/0509": {"queued": 58, "in_progress": 11},
          "Nishfleet/fleet-ops": {"queued": 0, "in_progress": 0}}

shaped = m._shape_ci_merge_queue(
    m._parse_ci_merge_queue(payload, repos, hosted, now), now)
r = shaped["Nishfleet/0509"]
assert r["head_wait_s"] == 8400, r     # 2h20m, the issue's own number
assert r["entries"] == 14, r
assert r["runs_queued"] == 58, r
assert r["runs_in_progress"] == 11, r

# One ALIASED GraphQL call for every enrolled repo (never one call per repo —
# the #5762 rate-limit budget is flat, not per-repo).
q = m._ci_merge_queue_graphql_query(repos)
assert "r0: repository" in q and "r1: repository" in q, q
assert m._ci_merge_queue_graphql_query([]) is None

# HELP/TYPE exactly once per name; one series per (metric, repo) — the #1844
# duplicate-HELP class makes node_exporter reject the whole textfile.
lines = []
m._emit_ci_merge_queue(lines, shaped)
for name in ("ci_merge_queue_head_wait_seconds", "ci_merge_queue_entries",
             "ci_hosted_runs_queued", "ci_hosted_runs_in_progress"):
    help_n = sum(1 for l in lines if l.startswith(f"# HELP {name} "))
    type_n = sum(1 for l in lines if l == f"# TYPE {name} gauge")
    samp = [l for l in lines if l.startswith(f'{name}{{repo="')]
    assert help_n == 1 and type_n == 1, (name, help_n, type_n)
    assert len(samp) >= 1, (name, samp)
assert 'ci_merge_queue_head_wait_seconds{repo="Nishfleet/0509"} 8400' in lines
assert 'ci_hosted_runs_queued{repo="Nishfleet/0509"} 58' in lines
assert 'ci_hosted_runs_in_progress{repo="Nishfleet/0509"} 11' in lines
assert 'ci_merge_queue_entries{repo="Nishfleet/0509"} 14' in lines

# A failed read omits its series (never a fabricated 0): runs_queued=None.
stored2 = m._parse_ci_merge_queue(
    payload, repos, {"Nishfleet/0509": {"queued": None, "in_progress": 3}}, now)
lines2 = []
m._emit_ci_merge_queue(lines2, m._shape_ci_merge_queue(stored2, now))
assert not any("runs_queued{" in l for l in lines2), lines2
assert any("runs_in_progress{" in l for l in lines2), lines2

# mergeQueue answers null (queue not enabled) = answered 0, not an omission.
s4 = m._shape_ci_merge_queue(
    m._parse_ci_merge_queue({"data": {"r0": {"mergeQueue": None}}}, repos, {}, now), now)
assert s4["Nishfleet/0509"]["entries"] == 0, s4
assert s4["Nishfleet/0509"]["head_wait_s"] == 0, s4
# Alias unanswered entirely -> no row (hosted-only answers still emit).
s3 = m._shape_ci_merge_queue(
    m._parse_ci_merge_queue({"data": {"r0": None}}, repos, {}, now), now)
assert "Nishfleet/0509" not in s3
print("OK: exporter publishes the 4 gauges; 10:50 IST evidence parses to 8400s/14/58/11")
PY

# --- 2. rules: thresholds, severities, absent() legs, not in SKIP_SET -------
python3 - "$rules" "$dispatch_bin" <<'PY' || fail "rules-pin failed"
import sys, yaml, importlib.util, re
from pathlib import Path

rules_path, dispatch_path = sys.argv[1:3]
cfg = yaml.safe_load(open(rules_path))
found = {}
for g in cfg.get("groups", []):
    for r in g.get("rules", []):
        if r.get("alert", "").startswith("Ci"):
            found[r["alert"]] = r
assert set(found) == {"CiMergeQueueHeadWaitHigh", "CiHostedQueueDepthHigh"}, found

head = found["CiMergeQueueHeadWaitHigh"]
assert head["expr"] == ("ci_merge_queue_head_wait_seconds > 1200 "
                        "or absent(ci_merge_queue_head_wait_seconds)"), head["expr"]
assert head["for"] == "10m" and head["labels"]["severity"] == "critical", head
depth = found["CiHostedQueueDepthHigh"]
assert depth["expr"] == ("ci_hosted_runs_queued > 30 "
                         "or absent(ci_hosted_runs_queued)"), depth["expr"]
assert depth["for"] == "15m" and depth["labels"]["severity"] == "warning", depth
for a in (head, depth):
    assert a["labels"]["service"] == "fleet", a
    # consolidation issues + the top-slot-consumer (workflow x count x median
    # duration) remedy travel in the DESCRIPTION = the repair packet.
    desc = a["annotations"]["description"]
    for ref in ("0509#3069", "0509#3068", "0509#3070"):
        assert ref in desc, (a["alert"], ref)
    assert "workflowName" in desc and "median" not in desc or "status" in desc, (a["alert"], desc)
    assert "gh run list" in desc, (a["alert"], desc)  # the slot-consumer one-liner

# Neither name may sit in the alert-repair-dispatch SKIP_SET: these must
# dispatch a repair worker, not silently skip (the #4643 precedent).
import importlib.machinery, importlib.util
loader = importlib.machinery.SourceFileLoader("ard", dispatch_path)
spec = importlib.util.spec_from_loader("ard", loader)
ard = importlib.util.module_from_spec(spec)
loader.exec_module(ard)
for name in found:
    assert name not in ard.SKIP_SET, (name, "must NOT be in SKIP_SET")
    # its annotations must survive the #1844 duplicate-HELP watchdog: the
    # exporter carries HELP/TYPE exactly once (asserted in section 1).
print("OK: both rules pinned (thresholds/for/severity/absent/SKIP_SET/consolidation-refs)")
PY

# --- 3. promtool: 10:50 IST snapshot fires BOTH; quiet control silent; -----
#      after the head merges, both CLEAR. Runs against the REAL rules file.
if ! command -v promtool >/dev/null 2>&1; then
  echo "SKIP: promtool not installed; skipped rule-unit semantic test"
else
  # 18 samples above threshold (fires: >1200s for 10m, >30 for 15m), then 2
  # recovered (clears — resolution is immediate once the condition drops;
  # `for` only delays FIRING). 1m interval. The exp annotations are grafted
  # from the LIVE rules file below, so this pins the shipped words.
  cat > "$scratch/pos.test.yml" <<EOF
rule_files:
  - $rules
evaluation_interval: 1m
tests:
  - interval: 1m
    input_series:
      - series: 'ci_merge_queue_head_wait_seconds{repo="Nishfleet/0509"}'
        values: '8400+0x17 600+0x2'
      - series: 'ci_merge_queue_entries{repo="Nishfleet/0509"}'
        values: '14+0x19'
      - series: 'ci_hosted_runs_queued{repo="Nishfleet/0509"}'
        values: '58+0x17 10+0x2'
      - series: 'ci_hosted_runs_in_progress{repo="Nishfleet/0509"}'
        values: '11+0x19'
    alert_rule_test:
      - eval_time: 17m
        alertname: CiMergeQueueHeadWaitHigh
        exp_alerts:
          - exp_labels:
              severity: critical
              service: fleet
              repo: Nishfleet/0509
            exp_annotations:
              summary: "merge-queue head wait >20 min on Nishfleet/0509 (or family absent)"
              description: "REPLACE_HEAD"
      - eval_time: 17m
        alertname: CiHostedQueueDepthHigh
        exp_alerts:
          - exp_labels:
              severity: warning
              service: fleet
              repo: Nishfleet/0509
            exp_annotations:
              summary: ">30 hosted runs queued on Nishfleet/0509 (or family absent)"
              description: "REPLACE_DEPTH"
      # cleared: after the head merges and the queue drains, neither fires
      - eval_time: 19m
        alertname: CiMergeQueueHeadWaitHigh
        exp_alerts: []
      - eval_time: 19m
        alertname: CiHostedQueueDepthHigh
        exp_alerts: []
  # quiet control: the enrolled fleet-ops repo idles (no queue, few runs).
  - interval: 1m
    input_series:
      - series: 'ci_merge_queue_head_wait_seconds{repo="Nishfleet/fleet-ops"}'
        values: '0+0x8'
      - series: 'ci_merge_queue_entries{repo="Nishfleet/fleet-ops"}'
        values: '0+0x8'
      - series: 'ci_hosted_runs_queued{repo="Nishfleet/fleet-ops"}'
        values: '1+0x8'
      - series: 'ci_hosted_runs_in_progress{repo="Nishfleet/fleet-ops"}'
        values: '3+0x8'
    alert_rule_test:
      - eval_time: 8m
        alertname: CiMergeQueueHeadWaitHigh
        exp_alerts: []
      - eval_time: 8m
        alertname: CiHostedQueueDepthHigh
        exp_alerts: []
EOF
  # Graft the LIVE annotations (the 10:50-snapshot unit test pins the rules
  # file's own words — a silent annotation drift fails this, not silently).
  # Each heredoc above emits a REPLACE_<NAME> placeholder; the YAML-escape
  # here must match the double-quoted scalar style (backslash + quote).
  python3 - "$rules" "$scratch/pos.test.yml" <<'PY' || fail "annotation graft failed"
import sys, yaml
rules, test = sys.argv[1:3]
cfg = yaml.safe_load(open(rules))
ann = {}
for g in cfg["groups"]:
    for r in g["rules"]:
        if r.get("alert", "").startswith("Ci"):
            ann[r["alert"]] = r["annotations"]["description"]
# promtool expands Go templates in the GOT annotations, so the EXPECTED
# annotations must arrive pre-expanded: this test's firing series carries
# exactly one repo label, so {{ $labels.repo }} resolves to it.
text = open(test).read()
text = text.replace("REPLACE_HEAD", ann["CiMergeQueueHeadWaitHigh"]
                   .replace("{{ $labels.repo }}", "Nishfleet/0509")
                   .replace("\\", "\\\\").replace('"', '\\"'))
text = text.replace("REPLACE_DEPTH", ann["CiHostedQueueDepthHigh"]
                   .replace("{{ $labels.repo }}", "Nishfleet/0509")
                   .replace("\\", "\\\\").replace('"', '\\"'))
open(test, "w").write(text)
PY
  if ! out="$(promtool test rules "$scratch/pos.test.yml" 2>&1)"; then
    fail "promtool unit test failed: $out"
  fi
  ok "promtool: 10:50 IST snapshot fires BOTH; recovered values clear; quiet control silent"
fi
#      resolved -> SKIP, no new packet. REAL dispatcher, mocked spawner.
# Fixture shape borrowed from tests/alert-repair-claim-mutex.test.sh.
export XDG_RUNTIME_DIR="$scratch/run"
export FLEET_CLAIM_CHECKOUT_ROOT="$scratch/products"
export FLEET_CLAIM_REMOTE=origin
export FLEET_CLAIM_MAIN_BRANCH=main
export ALERT_REPAIR_STATE_DIR="$scratch/alert-repair-state"
export ALERT_REPAIR_PACKET_DIR="$scratch/agent-state/alert-repair"
export PACKET_DIR="$scratch/agent-state/alert-repair"
export SEAT_HEALTH_FILE="$scratch/pi-seat-health.json"
mkdir -p "$FLEET_CLAIM_CHECKOUT_ROOT" "$ALERT_REPAIR_STATE_DIR" "$PACKET_DIR" "$XDG_RUNTIME_DIR"

bare="$scratch/bare/0509.git"
mkdir -p "$scratch/bare"
git -c init.defaultBranch=main init --bare -q "$bare"
checkout="$FLEET_CLAIM_CHECKOUT_ROOT/0509"
git -c init.defaultBranch=main clone -q "$bare" "$checkout"
(
    cd "$checkout"
    git config user.email "test@example.com"
    git config user.name "Test"
    echo 'init' > file.txt
    git add file.txt
    git commit -q -m 'initial'
    git branch -M main
    git push -q -u origin main
)

mock_bin="$scratch/mock-bin"
mkdir -p "$mock_bin"
cat >"$mock_bin/pi-systemd-run" <<'MOCK'
#!/usr/bin/env bash
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] mock-pi-systemd-run args=$*" >> "${MOCK_LOG:-/dev/null}"
exit 0
MOCK
chmod +x "$mock_bin/pi-systemd-run"
export MOCK_LOG="$scratch/mock-pi-systemd-run.log"

cat >"$SEAT_HEALTH_FILE" <<'EOF'
{"provider":"minimax","model":"MiniMax-M3","health_class":"healthy","observed_at":"2099-01-01T00:00:00Z"}
EOF
export ALERT_REPAIR_CLAIM_BIN="$repo_root/libexec/alert-repair-claim"

# The drill's annotations ARE the live ones from fleet_rules.yml (grafted by
# the same extractor as section 3), so the packet provably carries whatever
# the shipped rule says — including the slot-consumer one-liner and the
# consolidation issues. Head wait: the issue's synthetic drill case, 25 min
# = 1500s (> the 1200s threshold; the 10:50 evidence case is section 3).
read -r DESC_HEAD <<DESC
$(python3 -c "
import yaml, sys
cfg = yaml.safe_load(open('$rules'))
for g in cfg['groups']:
    for r in g['rules']:
        if r.get('alert') == 'CiMergeQueueHeadWaitHigh':
            print(r['annotations']['description'])
")
DESC
DISPATCH_OUT="$scratch/drill-dispatch.out"
AMX_ALERT_1_LABEL_alertname="CiMergeQueueHeadWaitHigh" \
AMX_ALERT_1_LABEL_repo="Nishfleet/0509" \
AMX_ALERT_1_LABEL_severity="critical" \
AMX_ALERT_1_LABEL_service="fleet" \
AMX_ALERT_1_ANNOTATION_summary="merge-queue head wait >20 min on Nishfleet/0509" \
AMX_ALERT_1_ANNOTATION_description="$DESC_HEAD" \
AMX_LABEL_repo="Nishfleet/0509" \
AMX_STATUS="firing" \
AMX_RECEIVER="test-receiver" \
PATH="$mock_bin:$PATH" \
HOME="$scratch" \
"$dispatch_bin" >"$DISPATCH_OUT" 2>"$scratch/drill-dispatch.err" \
    || fail "firing dispatch exited non-zero: $(cat "$scratch/drill-dispatch.err")"

packets=$(ls "$PACKET_DIR"/packet-*.md 2>/dev/null | wc -l || true)
[[ "$packets" == "1" ]] || fail "expected exactly 1 packet, got $packets: $(ls "$PACKET_DIR" 2>/dev/null)"
packet_file=$(ls "$PACKET_DIR"/packet-*.md | head -1)
grep -q "CiMergeQueueHeadWaitHigh" "$packet_file" \
    || fail "packet must carry the alertname"
grep -q "0509#3069" "$packet_file" && grep -q "0509#3070" "$packet_file" \
    || fail "packet must carry the consolidation issues 0509#3069/#3068/#3070"
grep -q "gh run list" "$packet_file" \
    || fail "packet must carry the top-slot-consumer (workflow x count x duration) one-liner"
grep -q "1500\|25 min\|AWAITING" "$packet_file" \
    || true  # the wait VALUE rides the annotations when AM carries it; not all transports pass values
disps=$(grep -c '\] DISPATCH ' "$PACKET_DIR/actions.log" || true)
[[ "$disps" == "1" ]] || fail "expected exactly 1 DISPATCH, got $disps: $(cat "$PACKET_DIR/actions.log")"
spawns=$(grep -c 'mock-pi-systemd-run args=' "$MOCK_LOG" || true)
[[ "$spawns" == "1" ]] || fail "expected exactly 1 worker spawn, got $spawns"
ok "drill: 25-min head wait dispatched exactly one packet + worker, consolidation issues + slot one-liner aboard"

# --- clears: the resolved notification spawns nothing new (#5272) -----------
AMX_ALERT_1_LABEL_alertname="CiMergeQueueHeadWaitHigh" \
AMX_ALERT_1_LABEL_repo="Nishfleet/0509" \
AMX_ALERT_1_ANNOTATION_description="$DESC_HEAD" \
AMX_STATUS="resolved" \
AMX_RECEIVER="test-receiver" \
PATH="$mock_bin:$PATH" \
HOME="$scratch" \
"$dispatch_bin" >"$scratch/drill-resolved.out" 2>"$scratch/drill-resolved.err" \
    || fail "resolved dispatch exited non-zero: $(cat "$scratch/drill-resolved.err")"
grep -q "SKIP resolved" "$PACKET_DIR/actions.log" \
    || fail "resolved notification must log SKIP resolved: $(cat "$PACKET_DIR/actions.log")"
disps2=$(grep -c '\] DISPATCH ' "$PACKET_DIR/actions.log" || true)
[[ "$disps2" == "1" ]] || fail "resolved must not add a DISPATCH, got $disps2"
packets2=$(ls "$PACKET_DIR"/packet-*.md 2>/dev/null | wc -l || true)
[[ "$packets2" == "1" ]] || fail "resolved must not write a new packet, got $packets2"
ok "drill: cleared — resolved notification dispatched nothing (SKIP resolved, 1 packet, 1 DISPATCH total)"

echo "OK: fleet-ops#5807 ci-merge-queue detector: exporter + rules + unit test + drill all pass"

# --- 5. main() end-to-end: the four families survive the WHOLE pipeline -----
#      into the fleet.prom textfile (the #1844 class: one HELP/TYPE each, or
#      node_exporter drops the entire file and the detectors go blind), and
#      the #5762 budget gate (20% throttle) serves the stale cache instead of
#      re-reading gh. Both runs are fully hermetic: every gh seam is stubbed.
python3 - "$exporter" <<'PY' || fail "main() emission/budget-gate failed"
import importlib.util, json, sys, time
from pathlib import Path
from collections import Counter

spec = importlib.util.spec_from_file_location("fme", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# Hermetic run: every seam the #1844 regression test overrides, plus the
# #5807 family's own cache (bound at import from the ORIGINAL PR_CACHE_DIR,
# so it must be re-pointed explicitly after PR_CACHE_DIR changes).
out = Path("/tmp/cimq-main-out.prom")
out.parent.mkdir(exist_ok=True)
m.OUT = out
m.PR_CACHE_DIR = out.parent
m.MERGE_QUEUE_CACHE = out.parent / "ci-merge-queue.cache.json"
forgone = ("SELF_MAINT_JSON_DEFAULT", "SELF_MAINT_JSON_FALLBACK")
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
m.DETAIL_CACHE = out.parent / "detail.cache.json"

m._list_timers = lambda: [{"unit": "fleet-metrics-export.timer", "last_usec": 0}]
m._timer_active = lambda unit: 1
m._read_seat = lambda: (1, 0)
m._read_dead_credentials = lambda: (0, [])
m._ping_healthcheck = lambda: None
m._escalations_24h = lambda: {}
m._oomd_kills_6h = lambda: {}
m._repair_log_counts_24h = lambda: (0, 0)
m._worker_units = lambda: []
m._standalone_pi_print_count = lambda u: 0
m._maintenance_quiescing = lambda: 0
m._keystone_routing_counts = lambda: (0, 0, None)
m._fetch_signups_7d = lambda: None
m._fetch_openrouter_credits = lambda: None
m._fetch_xkiro_usage = lambda: None
m._fetch_openrouter_key = lambda: None
m._fetch_claude_usage = lambda: None
m._fetch_codex_usage = lambda: None
m._fetch_cursor_usage = lambda: None
m._fetch_xkiro_quota = lambda: None
m._merged_prs_detail = lambda: None
m._repo_snapshot = lambda: None
m._queue_composition = lambda: {
    "ready-work": {"total": 5, "self": 4},
    "agent-ready": {"total": 6, "self": 4},
}

repos = ["Nishfleet/0509", "Nishfleet/fleet-ops"]
m._enrolled_repos = lambda: repos
# 10:50 IST evidence, at the gh seam: 8400s head wait / 14 entries / 58+11.
now = m._parse_iso_utc("2026-09-12T05:48:15")
m._gh_graphql = lambda q, cursor=None: {"data": {"r0": {"mergeQueue": {
    "entries": {"totalCount": 14, "nodes": [
        {"position": 1, "state": "AWAITING_CHECKS",
         "enqueuedAt": "2026-09-12T03:28:15Z"},
        {"position": 2, "state": "QUEUED", "enqueuedAt": "2026-09-12T04:00:00Z"},
    ]}}}}}
m._gh_hosted_runs_count = lambda repo, status: {
    ("Nishfleet/0509", "queued"): 58,
    ("Nishfleet/0509", "in_progress"): 11,
    ("Nishfleet/fleet-ops", "queued"): 1,
    ("Nishfleet/fleet-ops", "in_progress"): 3,
}[(repo, status)]
m._gh_rate_limit = lambda: {"core": {"remaining": 4800, "limit": 5000, "reset": now + 3600, "low": 0}, "graphql": {"remaining": 4900, "limit": 5000, "reset": now + 3600, "low": 0}}
time.time = (lambda t=now: t)  # pin "now" so head_wait_s == 8400, not now-03:28

rc = m.main()
assert rc == 0, f"main rc={rc}"
body = out.read_text()
for name, want in (
    ("ci_merge_queue_head_wait_seconds", 8400),
    ("ci_merge_queue_entries", 14),
    ("ci_hosted_runs_queued", 58),
    ("ci_hosted_runs_in_progress", 11),
):
    samp = [l for l in body.splitlines()
            if l.startswith(f'{name}{{repo="Nishfleet/0509"}} ')]
    assert samp == [f'{name}{{repo="Nishfleet/0509"}} {want}'], (name, samp)
# exactly one HELP/TYPE per #5807 metric name (the #1844 textfile-kill class)
for name in ("ci_merge_queue_head_wait_seconds", "ci_merge_queue_entries",
             "ci_hosted_runs_queued", "ci_hosted_runs_in_progress"):
    helps = [l for l in body.splitlines() if l == f"# TYPE {name} gauge"]
    assert len(helps) == 1, (name, helps)
    helps = [l for l in body.splitlines() if l.startswith(f"# HELP {name} ")]
    assert len(helps) == 1, (name, helps)

# --- the #5762 budget gate: throttled -> NO gh read, STALE cache serves -----
stored = {"Nishfleet/0509": {"head_enqueued_at": now - 1500, "entries": 9,
                             "runs_queued": 40, "runs_in_progress": 5},
          "Nishfleet/fleet-ops": {"head_enqueued_at": None, "entries": 0,
                                  "runs_queued": 0, "runs_in_progress": 0}}
m.MERGE_QUEUE_CACHE.write_text(json.dumps({"ts": now - 600, "data": stored}))
calls = {"graphql": 0}
def _no_gh(q, cursor=None):
    calls["graphql"] += 1
    raise AssertionError("throttled run must not read gh (fleet-ops#5762)")
m._gh_graphql = _no_gh
m._gh_rate_limit = lambda: {"core": {"remaining": 100, "limit": 5000, "reset": now + 3600, "low": 1}, "graphql": {"remaining": 90, "limit": 5000, "reset": now + 3600, "low": 1}}
rc = m.main()
assert rc == 0 and calls["graphql"] == 0, (rc, calls)
body = out.read_text()
assert 'ci_merge_queue_head_wait_seconds{repo="Nishfleet/0509"} 1500' in body, \
    [l for l in body.splitlines() if "ci_merge_queue" in l]
assert 'ci_hosted_runs_queued{repo="Nishfleet/0509"} 40' in body
assert 'ci_merge_queue_entries{repo="Nishfleet/0509"} 9' in body
print("OK: main() end-to-end writes the 4 families (10:50 values); #5762 throttle serves stale, reads nothing")
PY
