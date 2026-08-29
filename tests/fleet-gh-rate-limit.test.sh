#!/usr/bin/env bash
# tests/fleet-gh-rate-limit.test.sh
#
# fleet-ops#1350: pin the GitHub API rate-limit metrics and the side-car
# state file that gates pi-intake-tick.sh.
#
# Proves, offline (no gh, no prometheus, no systemd):
#   1. The exporter emits fleet_gh_rate_limit_* families when gh returns data.
#   2. The low gauge is 1 when any consumed resource is <20% of limit.
#   3. The side-car state file is written with low/remaining/limit/reset/fetched_at
#      and the binding floor across core/search/graphql.
#   4. A healthy (>=20%) payload sets low=0 and the side-car reflects the
#      tightest resource.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
exporter="$repo_root/libexec/fleet-metrics-export.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$exporter" ]] || fail "exporter not found: $exporter"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

scratch="$(mktemp -d -t fme-gh-rl.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

SM_CONFIG="$scratch/sm.json"
cat >"$SM_CONFIG" <<'JSON'
{ "repos": ["fleet-ops"] }
JSON

HEALTHY="$scratch/healthy.json"
LOW="$scratch/low.json"
cat >"$HEALTHY" <<'JSON'
{
  "resources": {
    "core": { "remaining": 4000, "limit": 5000, "reset": 1787990400 },
    "search": { "remaining": 20, "limit": 30, "reset": 1787988600 },
    "graphql": { "remaining": 4800, "limit": 5000, "reset": 1787990400 }
  }
}
JSON
cat >"$LOW" <<'JSON'
{
  "resources": {
    "core": { "remaining": 4000, "limit": 5000, "reset": 1787990400 },
    "search": { "remaining": 5, "limit": 30, "reset": 1787988600 },
    "graphql": { "remaining": 4800, "limit": 5000, "reset": 1787990400 }
  }
}
JSON

python3 - "$exporter" "$scratch" "$SM_CONFIG" "$HEALTHY" "$LOW" <<'PY' || fail "rate-limit family logic failed"
import importlib.util, json, os, sys, time
from pathlib import Path
exporter, scratch, sm_cfg, healthy, low = sys.argv[1:6]
spec = importlib.util.spec_from_file_location("fme", exporter)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

m.OUT = Path(scratch) / "out.prom"
m.GH_RATE_LIMIT_CACHE = Path(scratch) / "rl.cache.json"
m.GH_RATE_LIMIT_STATE = Path(scratch) / "rl.state.json"
m.SEAT_HEALTH = Path(scratch) / "seat.json"
m.HC_URL_FILE = Path(scratch) / "hc.url"
m.ACTIONS_LOG = Path(scratch) / "actions.log"
m.MAINTENANCE_FLAG = Path(scratch) / "maint.json"
m.INTAKE_JSON_DEFAULT = Path(sm_cfg)
m.INTAKE_JSON_FALLBACK = Path("/nonexistent/fb.json")
m.KEYSTONE_LEDGER = Path(scratch) / "keystone.jsonl"
m.STALENESS_CACHE = Path(scratch) / "stale.json"
m.PR_CACHE_DIR = Path(scratch)
m.DETAIL_CACHE = Path(scratch) / "detail.cache.json"
m.SELF_MAINT_JSON_DEFAULT = Path(sm_cfg)
m.SELF_MAINT_JSON_FALLBACK = Path("/nonexistent/fb2.json")

m._list_timers = lambda: [{"unit": "fleet-metrics-export.timer", "last_usec": 0}]
m._timer_active = lambda u: 1
m._read_seat = lambda: (1, time.time())
m._merged_prs_detail = lambda: []
m._repo_snapshot = lambda: None
m._queue_composition = lambda: None
m._escalations_24h = lambda: {}
m._repair_log_counts_24h = lambda: (0, 0)
m._worker_units = lambda: []
m._standalone_pi_print_count = lambda u: 0
m._maintenance_quiescing = lambda: 0
m._keystone_routing_counts = lambda: (0, 0, None)
m._ping_healthcheck = lambda: None
m._truth_staleness = lambda: None
m._waste_ledger = lambda: None
m._GH_FETCHED_THIS_RUN = False

def _run(payload_file, expect_low, expect_remaining, expect_limit):
    payload = json.loads(Path(payload_file).read_text())
    # reset must be in the future for the test payload
    now = int(time.time())
    for r in payload["resources"].values():
        r["reset"] = now + 3600
    m._gh_rate_limit_now = lambda: payload
    try:
        m.GH_RATE_LIMIT_CACHE.unlink()
    except FileNotFoundError:
        pass
    try:
        m.GH_RATE_LIMIT_STATE.unlink()
    except FileNotFoundError:
        pass
    rc = m.main()
    assert rc == 0, f"main rc={rc}"
    body = m.OUT.read_text()
    assert "fleet_gh_rate_limit_remaining" in body, "missing remaining family"
    assert "fleet_gh_rate_limit_limit" in body, "missing limit family"
    assert "fleet_gh_rate_limit_reset" in body, "missing reset family"
    assert "fleet_gh_rate_limit_low" in body, "missing low family"
    assert "fleet_gh_rate_limit_fetched_seconds" in body, "missing heartbeat family"
    state = json.loads(m.GH_RATE_LIMIT_STATE.read_text())
    assert state["low"] == expect_low, f"state low={state['low']}, expected {expect_low}"
    assert state["remaining"] == expect_remaining, f"state remaining={state['remaining']}, expected {expect_remaining}"
    assert state["limit"] == expect_limit, f"state limit={state['limit']}, expected {expect_limit}"
    assert state["reset"] > now, f"state reset={state['reset']} not future"
    assert "fetched_at" in state, "missing fetched_at"
    return body, state

_run(healthy, expect_low=0, expect_remaining=20, expect_limit=30)
print("OK: healthy rate-limit emits metrics + sidecar; low=0, binding floor=20/30")

_run(low, expect_low=1, expect_remaining=5, expect_limit=30)
print("OK: exhausted rate-limit (<20% on search) sets low=1, sidecar=5/30")
PY

ok "fleet-ops#1350 gh rate-limit metrics + sidecar verified"
