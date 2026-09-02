#!/usr/bin/env bash
# tests/fleet-product-slo.test.sh
#
# fleet-ops#2755: product delivery SLO family. Offline (no live gh).
# Hosted by tests/ci-standards-audit.test.sh so P14 runs it without a
# workflow-file edit.
#
# Proves:
#   (a) throughput_weekly counts non-revert merges in the trailing 7d
#   (b) lead_time_days excludes revert PRs (median of non-revert only)
#   (c) revert_rate = reverts / merges over trailing 28d
#   (d) product repo list = intake-repos.json repos[] minus
#       self-maintenance-repos.json (fleet-ops dropped; 0509 kept)
#   (e) empty window still emits fleet_product_slo_last_run_seconds
#   (f) main() end-to-end writes a textfile with exact metric names
#   (g) MANIFEST installs the helper + exporter drop-in (no new timer)
#   (h) fleet_rules.yml ships FleetProductSloAbsent + ProductThroughputStalled
#       + ProductLeadTimeDegrading + ProductRevertRateHigh
#   (i) config/fleet-organs.json registers the organ
#   (j) console shipped_24h source is fleet_product_merged_24h

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
helper="$repo_root/lib/fleet-product-slo.py"
rules="$repo_root/config/fleet_rules.yml"
manifest="$repo_root/MANIFEST"
dropin="$repo_root/systemd/fleet-metrics-export.service.d/product-slo.conf"
organs="$repo_root/config/fleet-organs.json"
intake="$repo_root/config/intake-repos.json"
selfm="$repo_root/config/self-maintenance-repos.json"
generate="$repo_root/libexec/fleet-console-pi/generate.py"
verify="$repo_root/libexec/fleet-console-pi/verify.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$helper" ]] || fail "missing $helper"
[[ -f "$rules" ]] || fail "missing $rules"
[[ -f "$dropin" ]] || fail "missing $dropin"
[[ -f "$organs" ]] || fail "missing $organs"
[[ -f "$intake" ]] || fail "missing $intake"
[[ -f "$selfm" ]] || fail "missing $selfm"
command -v python3 >/dev/null 2>&1 || fail "python3 required"
command -v jq >/dev/null 2>&1 || fail "jq required"

scratch="$(mktemp -d -t product-slo-test.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Fixed "now": 2026-09-02T12:00:00Z
NOW_ISO="2026-09-02T12:00:00Z"
NOW_TS=1788350400

# =========================================================================
# (d) product repos = intake minus self-maintenance
# =========================================================================
python3 - "$helper" "$intake" "$selfm" <<'PY' || fail "product repo list failed"
import importlib.util, json, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("ps", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.modules["ps"] = m
spec.loader.exec_module(m)

repos = m.load_product_repos(Path(sys.argv[2]), Path(sys.argv[3]))
assert "0509" in repos, repos
assert "fleet-ops" not in repos, repos
# Sanity: intake has both; self-maint drops fleet-ops.
intake = json.loads(Path(sys.argv[2]).read_text())
enrolled = {r["name"] for r in intake["repos"]}
assert "0509" in enrolled and "fleet-ops" in enrolled
print("OK: product repos =", repos)
PY
ok "(d) respects intake-repos.json product repo list (fleet-ops excluded)"

# =========================================================================
# (a)(b)(c) compute_repo_slo: throughput, lead time excludes reverts, rate
# =========================================================================
python3 - "$helper" <<'PY' || fail "compute_repo_slo failed"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ps", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.modules["ps"] = m
spec.loader.exec_module(m)

NOW = 1788350400  # 2026-09-02T12:00:00Z
DAY = 86400

prs = [
    # Non-revert, merged 2d ago, issue filed 5d before merge -> lead=5
    m.MergedPR(number=10, repo="0509", title="feat: landing", head_ref="claim/issue-10",
               merged_ts=NOW - 2 * DAY, issue_created_ts=NOW - 2 * DAY - 5 * DAY),
    # Non-revert, merged 3d ago, issue filed 9d before merge -> lead=9
    m.MergedPR(number=11, repo="0509", title="fix: billing", head_ref="claim/issue-11",
               merged_ts=NOW - 3 * DAY, issue_created_ts=NOW - 3 * DAY - 9 * DAY),
    # Revert of #10, merged 1d ago — MUST NOT count in throughput or lead
    m.MergedPR(number=12, repo="0509", title="Revert \"feat: landing\"", head_ref="revert/10",
               merged_ts=NOW - 1 * DAY, issue_created_ts=NOW - 1 * DAY - 1 * DAY),
    # Non-revert outside the 7d window (10d ago) — still in 28d for revert_rate den
    m.MergedPR(number=13, repo="0509", title="feat: old", head_ref="claim/issue-13",
               merged_ts=NOW - 10 * DAY, issue_created_ts=NOW - 20 * DAY),
    # Revert outside week but inside 28d
    m.MergedPR(number=14, repo="0509", title="Revert \"feat: old\"", head_ref="revert/13",
               merged_ts=NOW - 9 * DAY, issue_created_ts=None),
    # Control-plane merge — ignored for 0509 stats
    m.MergedPR(number=99, repo="fleet-ops", title="fix: exporter", head_ref="claim/issue-99",
               merged_ts=NOW - 1 * DAY, issue_created_ts=NOW - 2 * DAY),
    # Non-revert in last 24h
    m.MergedPR(number=15, repo="0509", title="feat: today", head_ref="claim/issue-15",
               merged_ts=NOW - 0.5 * DAY, issue_created_ts=NOW - 2 * DAY),
]

s = m.compute_repo_slo("0509", prs, now_ts=NOW)

# (a) weekly non-revert: #10, #11, #15 (not #12 revert, not #13 outside week)
assert s.throughput_weekly == 3, f"throughput={s.throughput_weekly}"

# (b) lead time excludes reverts: samples 5 and 9 and (2-0.5? wait #15: merged NOW-0.5d, created NOW-2d -> 1.5d)
# leads: #10=5, #11=9, #15=1.5 -> median = 5
assert abs(s.lead_time_days - 5.0) < 1e-9, f"lead={s.lead_time_days} samples={s.lead_samples}"
assert all(x != 1.0 for x in s.lead_samples), "revert lead must not appear"

# (c) revert_rate over 28d: reverts=#12,#14 (2); merges=all 0509 in 28d = #10..#15 = 6
assert s.merges_28d == 6, s.merges_28d
assert s.reverts_28d == 2, s.reverts_28d
assert abs(s.revert_rate - 2 / 6) < 1e-9, s.revert_rate

# 24h non-revert: only #15
assert s.merged_24h == 1, s.merged_24h

print("OK: compute_repo_slo a/b/c")
PY
ok "(a)(b)(c) throughput / lead-time-excludes-reverts / revert_rate"

# =========================================================================
# (e) empty window still emits heartbeat + zeros
# =========================================================================
# export_prom writes to FLEET_PRODUCT_SLO_OUT (like (f)); without it the
# default /var/lib/prometheus/node-exporter path is not writable in hosted
# CI, so the write fails before assertions run (FileNotFoundError, 2026-09-02).
export FLEET_PRODUCT_SLO_OUT="$scratch/heartbeat.prom"
python3 - "$helper" <<'PY' || fail "empty heartbeat failed"
import importlib.util, sys
from datetime import datetime, timezone
spec = importlib.util.spec_from_file_location("ps", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.modules["ps"] = m
spec.loader.exec_module(m)

now = datetime(2026, 9, 2, 12, 0, 0, tzinfo=timezone.utc)
body = m.export_prom([m.RepoSLO(repo="0509")], now=now)
assert "fleet_product_slo_last_run_seconds" in body
assert 'fleet_product_throughput_weekly{repo="0509"} 0' in body
assert 'fleet_product_lead_time_days{repo="0509"} 0.000000' in body
assert 'fleet_product_revert_rate{repo="0509"} 0.000000' in body
assert 'fleet_product_merged_24h{repo="0509"} 0' in body
print("OK: empty heartbeat")
PY
ok "(e) empty window emits heartbeat + zeros"

# =========================================================================
# (f) main() end-to-end via fixture
# =========================================================================
cat >"$scratch/fixture.json" <<'JSON'
{
  "repos": ["0509"],
  "prs": [
    {
      "number": 1,
      "repo": "0509",
      "title": "feat: a",
      "head_ref": "claim/1",
      "merged_ts": 1788264000,
      "issue_created_ts": 1788004800
    },
    {
      "number": 2,
      "repo": "0509",
      "title": "Revert \"feat: a\"",
      "head_ref": "revert/1",
      "merged_ts": 1788300000,
      "issue_created_ts": null
    },
    {
      "number": 3,
      "repo": "0509",
      "title": "feat: b",
      "head_ref": "claim/3",
      "merged_ts": 1788333600,
      "issue_created_ts": 1788240000
    }
  ]
}
JSON
# merged_ts: 1788264000 = NOW-1d, 1788300000 = NOW-14h, 1788333600 = NOW-4.67h
# issue leads: #1 = (1788264000-1788004800)/86400 = 3.0d; #3 = (1788333600-1788240000)/86400 = 1.0833d

OUT="$scratch/out.prom"
FLEET_PRODUCT_SLO_OUT="$OUT" \
FLEET_PRODUCT_SLO_NOW="$NOW_ISO" \
FLEET_PRODUCT_SLO_FIXTURE="$scratch/fixture.json" \
  python3 "$helper" --stdout >"$scratch/stdout.prom"
[[ -f "$OUT" ]] || fail "main() did not write $OUT"
grep -q 'fleet_product_throughput_weekly{repo="0509"} 2' "$OUT" \
  || fail "fixture throughput want 2 (non-reverts #1+#3): $(grep throughput "$OUT")"
# #1 merged_ts = NOW-1d = exactly DAY_S ago; day_cut = NOW - DAY_S, condition is
# day_cut < merged <= now so #1 is NOT in 24h. Only #3 counts -> merged_24h=1.
grep -q 'fleet_product_merged_24h{repo="0509"} 1' "$OUT" \
  || fail "fixture 24h want 1 (#3 only; #1 is exactly 1d ago): $(grep merged_24h "$OUT")"
grep -q 'fleet_product_revert_rate{repo="0509"} 0.333333' "$OUT" \
  || fail "fixture revert_rate want 1/3: $(grep revert_rate "$OUT")"
grep -q 'fleet_product_slo_last_run_seconds ' "$OUT" \
  || fail "missing heartbeat"
# HELP/TYPE once each
for metric in fleet_product_throughput_weekly fleet_product_lead_time_days \
              fleet_product_revert_rate fleet_product_merged_24h \
              fleet_product_slo_last_run_seconds; do
  help_count=$(grep -c "^# HELP $metric " "$OUT" || true)
  type_count=$(grep -c "^# TYPE $metric " "$OUT" || true)
  [[ "$help_count" -eq 1 ]] || fail "$metric HELP count=$help_count"
  [[ "$type_count" -eq 1 ]] || fail "$metric TYPE count=$type_count"
done
# lead median of [3.0, 1.083333...] = average of both sorted mid = (1.0833+3)/2 for even? 
# statistics.median of 2 values = average. Check roughly.
python3 - "$OUT" <<'PY' || fail "lead_time parse"
import sys, re
text = open(sys.argv[1]).read()
m = re.search(r'fleet_product_lead_time_days\{repo="0509"\} ([0-9.]+)', text)
assert m, text
val = float(m.group(1))
# samples: 3.0 and (1788333600-1788240000)/86400 = 93600/86400 = 1.083333...
# median of two = avg = 2.041666...
assert abs(val - 2.041666666) < 1e-5, val
print("OK: lead_time", val)
PY
ok "(f) main() fixture end-to-end textfile"

# =========================================================================
# (g) MANIFEST + drop-in + no new timer
# =========================================================================
grep -Fxq "lib/fleet-product-slo.py /home/nish/.local/lib/pi-packet/fleet-product-slo.py" "$manifest" \
  || fail "MANIFEST missing lib/fleet-product-slo.py dest"
grep -Fxq "systemd/fleet-metrics-export.service.d/product-slo.conf /home/nish/.config/systemd/user/fleet-metrics-export.service.d/product-slo.conf" "$manifest" \
  || fail "MANIFEST missing product-slo drop-in"
grep -q "ExecStart=-/bin/bash -c 'exec /usr/bin/python3 /home/nish/.local/lib/pi-packet/fleet-product-slo.py'" "$dropin" \
  || fail "drop-in must ExecStart=- the helper under ~/.local/lib/pi-packet/"
[[ ! -f "$repo_root/systemd/fleet-product-slo.timer" ]] \
  || fail "must not add a new timer; piggyback fleet-metrics-export (accept §5 rejected as new organ)"
[[ ! -f "$repo_root/systemd/fleet-product-slo.service" ]] \
  || fail "must not add a new service; piggyback fleet-metrics-export"
ok "(g) MANIFEST + drop-in wiring; no new timer"

# =========================================================================
# (h)(i) Rules + organ registry
# =========================================================================
grep -q 'alert: FleetProductSloAbsent' "$rules" \
  || fail "rules missing FleetProductSloAbsent"
grep -q 'absent(fleet_product_slo_last_run_seconds)' "$rules" \
  || fail "Absent rule must watch fleet_product_slo_last_run_seconds"
grep -q 'alert: ProductThroughputStalled' "$rules" \
  || fail "rules missing ProductThroughputStalled"
grep -q 'alert: ProductLeadTimeDegrading' "$rules" \
  || fail "rules missing ProductLeadTimeDegrading"
grep -q 'alert: ProductRevertRateHigh' "$rules" \
  || fail "rules missing ProductRevertRateHigh"
grep -q 'fleet_product_throughput_weekly{repo="0509"}' "$rules" \
  || fail "ProductThroughputStalled must gate on throughput weekly"
grep -q 'fleet_product_lead_time_days{repo="0509"} > 14' "$rules" \
  || fail "ProductLeadTimeDegrading must gate on lead_time > 14"
grep -q 'fleet_product_revert_rate{repo="0509"} > 0.15' "$rules" \
  || fail "ProductRevertRateHigh must gate on revert_rate > 0.15"

jq -e '.organs[] | select(.name=="product-slo")
  | select(.heartbeat_metric=="fleet_product_slo_last_run_seconds")
  | select(.absent_alert=="FleetProductSloAbsent")' "$organs" >/dev/null \
  || fail "fleet-organs.json missing product-slo organ"
ok "(h)(i) rules + organ registry"

# =========================================================================
# (j) console tile single source of truth
# =========================================================================
grep -q 'fleet_product_merged_24h' "$generate" \
  || fail "generate.py must read fleet_product_merged_24h"
grep -q 'prometheus:fleet_product_merged_24h' "$generate" \
  || fail "generate.py shipped tile source must be fleet_product_merged_24h"
! grep -q 'src = "prometheus:fleet_merged_prs_24h"' "$generate" \
  || fail "generate.py must not still source shipped_24h from fleet_merged_prs_24h"
grep -q 'sum(fleet_product_merged_24h)' "$verify" \
  || fail "verify.py shipped_prom must sum fleet_product_merged_24h"
ok "(j) console shipped_24h reads fleet_product_merged_24h"

# =========================================================================
# promtool (optional)
# =========================================================================
if command -v promtool >/dev/null 2>&1; then
  promtool check rules "$rules" >/dev/null \
    || fail "promtool check rules failed"
  ok "promtool check rules"
else
  echo "SKIP: promtool not on PATH"
fi

echo "OK: fleet-product-slo: throughput, lead-time-excludes-reverts, revert-rate, intake list, MANIFEST, rules, organ, console source"
