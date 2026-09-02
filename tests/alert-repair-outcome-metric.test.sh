#!/usr/bin/env bash
# tests/alert-repair-outcome-metric.test.sh
#
# fleet-ops#2694: fleet_alert_outcome_24h must distinguish phantom-alert
# resolutions from real fixes. actions.log RESOLVED entries whose
# root_cause starts with PHANTOM_ALERT are drill fixtures (no real
# Prometheus rule, no real defect) and must bucket as kind="phantom_resolved",
# not kind="resolved" — otherwise the metric looks like "no work happened"
# while LLM seats were burned on synthetic repair dispatches, and the WFR
# alert-quality lens cannot tell productive repair work from drill-fixture
# amplification loops.
#
# What we prove (hermetic, no gh, no prometheus, no systemd, no live
# actions.log):
#   1. The exporter module imports and _repair_log_per_alertname_24h exists.
#   2. A synthetic actions.log with 3 PHANTOM_ALERT RESOLVED + 2 real
#      RESOLVED entries for the SAME alertname yields
#      phantom_resolved=3, resolved=2 for that alertname.
#   3. A real RESOLVED entry without a PHANTOM_ALERT root_cause stays
#      kind="resolved" (existing four kinds unchanged).
#
# Times out the alert window check cleanly: all synthetic entries are
# stamped within the trailing 24h, so the trailing-window cutoff is
# exercised by the real cutoff value, not dodged.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
exporter="$repo_root/libexec/fleet-metrics-export.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$exporter" ]] || fail "exporter not found: $exporter"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

scratch="$(mktemp -d -t alert-outcome-test.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT

python3 - "$exporter" "$scratch" <<'PY' || fail "outcome classification failed"
import sys
from pathlib import Path
import importlib.util

exporter, scratch = sys.argv[1], Path(sys.argv[2])
log = scratch / "actions.log"

now = __import__("datetime").datetime.now(__import__("datetime").timezone.utc)
def ts(minutes_ago):
    t = (now - __import__("datetime").timedelta(minutes=minutes_ago))
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")

# Synthetic trailing-24h actions.log for one alertname:
# 3 RESOLVED with PHANTOM_ALERT root_cause -> phantom_resolved
# 2 RESOLVED with a real root_cause (and one with no root_cause token) -> resolved
lines = [
    f"{ts(10)} RESOLVED alertname=ClassExpiredAlert root_cause=PHANTOM_ALERT_no_real_Prometheus_rule_no_firing_state fix=NONE_required source=repair-dispatch",
    f"{ts(20)} RESOLVED alertname=ClassExpiredAlert root_cause=PHANTOM_ALERT_drill_scenario_4 fix=NONE_required source=repair-dispatch",
    f"{ts(30)} RESOLVED alertname=ClassExpiredAlert root_cause=PHANTOM_ALERT_no_real_rule fix=NONE_required source=repair-dispatch",
    f"{ts(40)} RESOLVED alertname=ClassExpiredAlert repo=Nishfleet/siterep-public root_cause=transient_upstream_failure_re_runs=1 fix=no_retry_needed",
    f"{ts(50)} RESOLVED alertname=ClassExpiredAlert reason=drill-cleanup source=fleet-completion-canary",
    # A dispatch line for the same alertname must not disturb the counts.
    f"{ts(60)} DISPATCH alertname=ClassExpiredAlert unit=alert-repair-x source=fleet-completion-canary",
]
log.write_text("\n".join(lines) + "\n")

spec = importlib.util.spec_from_file_location("fme", exporter)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.ACTIONS_LOG = log

counts = m._repair_log_per_alertname_24h()
d = counts.get("ClassExpiredAlert")
assert d is not None, f"alertname missing from counts: {counts}"
assert d["phantom_resolved"] == 3, f"phantom_resolved={d['phantom_resolved']}, want 3: {d}"
assert d["resolved"] == 2, f"resolved={d['resolved']}, want 2: {d}"
assert d["dispatch"] == 1, f"dispatch={d['dispatch']}, want 1: {d}"
assert d["failed"] == 0 and d["skipped"] == 0, f"failed/skipped should be 0: {d}"
print(f"OK: alertname=ClassExpiredAlert phantom_resolved={d['phantom_resolved']} resolved={d['resolved']}")
PY

python3 - "$exporter" "$scratch" <<'PY' || fail "emit-loop kind coverage failed"
import sys
from pathlib import Path
import importlib.util

exporter, scratch = sys.argv[1], Path(sys.argv[2])

spec = importlib.util.spec_from_file_location("fme", exporter)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
# The emit loop must cover all five kinds, phantom_resolved last.
import re
src = Path(exporter).read_text()
emit = re.search(r'for kind in \(([^)]*)\):', src)
assert emit, "emit loop not found"
kinds = [k.strip().strip('"').strip("'") for k in emit.group(1).split(",") if k.strip()]
assert kinds == ["dispatch", "resolved", "failed", "skipped", "phantom_resolved"], f"emit kinds wrong: {kinds}"
# HELP_AD must tell the WFR lens about the new kind.
assert "phantom_resolved" in m.HELP_AD, "HELP_AD does not mention phantom_resolved"
print("OK: emit loop kinds = ", ", ".join(kinds))
PY

echo "OK: alert-repair-outcome-metric classification green"