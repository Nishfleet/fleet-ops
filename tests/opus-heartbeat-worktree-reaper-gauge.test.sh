#!/usr/bin/env bash
# tests/opus-heartbeat-worktree-reaper-gauge.test.sh
#
# fleet-ops#4118: the thorough heartbeat snapshot's hygiene_counts slot
# reported worktree_dirs=316 with "no orphan-worktree reaper result in
# the snapshot" — a bare count that hides whether the reaper drain is
# working. The fix surfaces the reaper's last-run summary as
# hygiene_counts.worktree_reaper so the judge can gauge reaped vs
# skipped_dirty vs skipped_notpushed and see the oldest worktrees still
# on disk, instead of a count that could be steady-state OR a stuck
# drain.
#
# This test drives opus-heartbeat-gather in THOROUGH mode with
# FLEET_WORKTREE_REAPER_SUMMARY pointed at fixture JSON files and proves:
#   1. present + counts: a fresh reaper summary surfaces present=true,
#      the count fields (reaped, skipped_dirty, post_count,
#      bound_breached, ...), and the oldest[] array sorted by age_s desc.
#   2. missing summary: a missing file degrades to present=false,
#      reason=summary-missing (data, not a crash — the gather stays
#      defensive).
#   3. unparseable summary: a garbage file degrades to present=false,
#      reason=summary-unparseable.
#   4. stale summary: a summary older than 7d degrades to present=false,
#      reason=summary-stale (so the judge does not act on a reaper that
#      stopped running).
#   5. oldest[] is sorted by age_s desc and capped at REAPER_OLDEST_N
#      (10): a fixture with 12 worktrees yields oldest[] of length 10,
#      and oldest[0].age_s >= oldest[1].age_s.
#   6. source-pin: the installed gather source carries the
#      fleet-ops#4118 citation and the worktree_reaper_result function,
#      so a refactor cannot silently drop the gauge.
#
# Live/VPS-only (per the existing opus-heartbeat-* test convention): the
# gather script at /home/nish/.local/libexec/opus-heartbeat-gather is
# absent on hosted CI runners. The test skips with exit 77 (NOTRUN) when
# the gather is missing, mirroring the failed-units-gate test's guard.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

GATHER="${OPUS_HB_GATHER:-/home/nish/.local/libexec/opus-heartbeat-gather}"
TMPD="$(mktemp -d -t opus-4118-gauge.XXXXXX)"
DEAD_PROM="${OPUS_HB_DEAD_PROM:-http://127.0.0.1:9}"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# VPS-only guard: skip on hosted CI where the gather is absent.
if [[ ! -f "$GATHER" ]]; then
  echo "NOTRUN: gather missing at $GATHER (hosted CI runner) — fleet-ops#4118"
  exit 77
fi
command -v python3 >/dev/null 2>&1 || fail "python3 missing"

cleanup() { rm -rf "$TMPD" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# Run gather in THOROUGH mode with the reaper summary pointed at <fixture>
# (or "MISSING" to point at a non-existent path). Prints the parsed
# hygiene_counts.worktree_reaper object to stdout as JSON.
run_gather() {
  local fixture="$1"
  local summary_env="$TMPD/reaper-summary.json"
  if [ "$fixture" = "MISSING" ]; then
    summary_env="$TMPD/does-not-exist.json"
  else
    cp "$fixture" "$summary_env"
  fi
  OPUS_HB_THOROUGH=1 OPUS_HB_STATE="$TMPD" PROM_URL="$DEAD_PROM" \
    FLEET_WORKTREE_REAPER_SUMMARY="$summary_env" \
    python3 "$GATHER" >"$TMPD/snap.json" 2>"$TMPD/snap.err" \
    || fail "gather THOROUGH failed rc=$? (a slot fault is data, not a crash)"
  python3 - "$TMPD/snap.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
hc = d.get("thorough", {}).get("slots", {}).get("hygiene_counts", {})
wr = hc.get("worktree_reaper")
assert wr is not None, "hygiene_counts.worktree_reaper missing from thorough snapshot"
print(json.dumps(wr))
PY
}

# --- 1. present + counts + oldest[] ----------------------------------------
cat >"$TMPD/fresh.json" <<'JSON'
{
  "script": "fleet-worktree-reaper",
  "ts": "2026-09-07T05:16:33Z",
  "dry_run": 0,
  "scanned": 298,
  "reaped": 7,
  "skipped_dirty": 59,
  "skipped_notpushed": 138,
  "skipped_young": 23,
  "skipped_live": 0,
  "skipped_unmerged": 58,
  "skipped_notterminal": 12,
  "salvaged": 0,
  "salvage_candidates": 1,
  "failed": 1,
  "post_count": 318,
  "pre_count": 325,
  "bound_breached": 0,
  "report_rows": 298,
  "report_capped": 1,
  "worktrees": [
    {"path": "/a", "owner_repo": "Nishfleet/fleet-ops", "branch": "fix/x", "mode": "C", "age_s": 100, "verdict": "skipped", "reason": "notpushed"},
    {"path": "/b", "owner_repo": "Nishfleet/fleet-ops", "branch": "claim/issue-9", "mode": "A", "age_s": 9000, "verdict": "reaped", "reason": "merged"},
    {"path": "/c", "owner_repo": "", "branch": "(unregistered)", "mode": "E", "age_s": 5000, "verdict": "skipped", "reason": "dirty"}
  ]
}
JSON
wr1=$(run_gather "$TMPD/fresh.json")
python3 - "$wr1" <<'PY' || fail "scenario 1 assertion failed"
import json, sys
wr = json.loads(sys.argv[1])
assert wr.get("present") is True, f"present must be true, got {wr.get('present')}"
assert wr.get("reaped") == 7, f"reaped must be 7, got {wr.get('reaped')}"
assert wr.get("skipped_dirty") == 59, f"skipped_dirty must be 59, got {wr.get('skipped_dirty')}"
assert wr.get("post_count") == 318, f"post_count must be 318, got {wr.get('post_count')}"
assert wr.get("bound_breached") == 0, f"bound_breached must be 0, got {wr.get('bound_breached')}"
assert wr.get("report_capped") == 1, f"report_capped must be 1, got {wr.get('report_capped')}"
oldest = wr.get("oldest") or []
assert len(oldest) == 3, f"oldest must have 3 rows, got {len(oldest)}"
# Sorted by age_s desc: 9000, 5000, 100.
assert oldest[0]["age_s"] == 9000, f"oldest[0].age_s must be 9000, got {oldest[0]['age_s']}"
assert oldest[1]["age_s"] == 5000, f"oldest[1].age_s must be 5000, got {oldest[1]['age_s']}"
assert oldest[2]["age_s"] == 100, f"oldest[2].age_s must be 100, got {oldest[2]['age_s']}"
# age_s of the summary itself is present (non-negative).
assert wr.get("age_s") is not None and wr.get("age_s") >= 0, f"age_s must be non-negative, got {wr.get('age_s')}"
print("OK: scenario 1: present + counts + oldest[] sorted by age_s desc")
PY

# --- 2. missing summary -> present:false, reason=summary-missing ----------
wr2=$(run_gather "MISSING")
python3 - "$wr2" <<'PY' || fail "scenario 2 assertion failed"
import json, sys
wr = json.loads(sys.argv[1])
assert wr.get("present") is False, f"present must be false, got {wr.get('present')}"
assert wr.get("reason") == "summary-missing", f"reason must be summary-missing, got {wr.get('reason')}"
print("OK: scenario 2: missing summary -> present:false, reason=summary-missing")
PY

# --- 3. unparseable summary -> present:false, reason=summary-unparseable --
printf 'not json{' >"$TMPD/garbage.json"
wr3=$(run_gather "$TMPD/garbage.json")
python3 - "$wr3" <<'PY' || fail "scenario 3 assertion failed"
import json, sys
wr = json.loads(sys.argv[1])
assert wr.get("present") is False, f"present must be false, got {wr.get('present')}"
assert wr.get("reason") == "summary-unparseable", f"reason must be summary-unparseable, got {wr.get('reason')}"
print("OK: scenario 3: unparseable summary -> present:false, reason=summary-unparseable")
PY

# --- 4. stale summary -> present:false, reason=summary-stale --------------
# A ts 30 days ago is older than the 7d REAPER_STALE_S gate.
python3 -c "
import datetime
ts = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=30)).strftime('%Y-%m-%dT%H:%M:%SZ')
import json
json.dump({'script':'fleet-worktree-reaper','ts':ts,'reaped':0,'post_count':0,'worktrees':[]}, open('$TMPD/stale.json','w'))
"
wr4=$(run_gather "$TMPD/stale.json")
python3 - "$wr4" <<'PY' || fail "scenario 4 assertion failed"
import json, sys
wr = json.loads(sys.argv[1])
assert wr.get("present") is False, f"present must be false, got {wr.get('present')}"
assert wr.get("reason") == "summary-stale", f"reason must be summary-stale, got {wr.get('reason')}"
print("OK: scenario 4: stale summary -> present:false, reason=summary-stale")
PY

# --- 5. oldest[] capped at REAPER_OLDEST_N (10) ---------------------------
python3 -c "
import json
wts = [{'path': f'/{i}', 'owner_repo': 'o/r', 'branch': 'b', 'mode': 'C', 'age_s': i*100, 'verdict': 'skipped', 'reason': 'young'} for i in range(12)]
json.dump({'script':'fleet-worktree-reaper','ts':'2026-09-07T05:16:33Z','reaped':0,'post_count':12,'worktrees':wts}, open('$TMPD/many.json','w'))
"
wr5=$(run_gather "$TMPD/many.json")
python3 - "$wr5" <<'PY' || fail "scenario 5 assertion failed"
import json, sys
wr = json.loads(sys.argv[1])
oldest = wr.get("oldest") or []
assert len(oldest) == 10, f"oldest must be capped at 10, got {len(oldest)}"
# Sorted desc: 1100, 1000, ... 200.
assert oldest[0]["age_s"] == 1100, f"oldest[0].age_s must be 1100, got {oldest[0]['age_s']}"
assert oldest[9]["age_s"] == 200, f"oldest[9].age_s must be 200, got {oldest[9]['age_s']}"
print("OK: scenario 5: oldest[] capped at 10, sorted desc")
PY

# --- 6. source-pin: the gather carries the #4118 citation + function ------
grep -q 'fleet-ops#4118' "$GATHER" \
  || fail "scenario 6: gather missing fleet-ops#4118 citation"
grep -q 'def worktree_reaper_result' "$GATHER" \
  || fail "scenario 6: gather missing worktree_reaper_result function"
grep -q 'WORKTREE_REAPER_SUMMARY' "$GATHER" \
  || fail "scenario 6: gather missing WORKTREE_REAPER_SUMMARY constant"
ok "scenario 6: gather source carries #4118 citation + worktree_reaper_result"

# --- 7. light snapshot does NOT carry hygiene_counts (unchanged) ----------
# The worktree_reaper gauge lives in the THOROUGH hygiene_counts slot; the
# light snapshot must stay unchanged (no new top-level key).
OPUS_HB_STATE="$TMPD" PROM_URL="$DEAD_PROM" \
  FLEET_WORKTREE_REAPER_SUMMARY="$TMPD/fresh.json" \
  python3 "$GATHER" >"$TMPD/light.json" 2>"$TMPD/light.err" \
  || fail "gather LIGHT failed rc=$?"
python3 - "$TMPD/light.json" <<'PY' || fail "scenario 7 assertion failed"
import json, sys
d = json.load(open(sys.argv[1]))
assert "thorough" not in d, "light snapshot must NOT carry a thorough key"
assert "hygiene_counts" not in d, "light snapshot must NOT carry hygiene_counts"
assert "worktree_reaper" not in d, "light snapshot must NOT carry worktree_reaper"
print("OK: scenario 7: light snapshot unchanged (no worktree_reaper key)")
PY

echo "all opus-heartbeat-worktree-reaper-gauge scenarios passed"
