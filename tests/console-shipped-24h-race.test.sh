#!/usr/bin/env bash
# tests/console-shipped-24h-race.test.sh
#
# fleet-ops#2690 — console tile shipped_24h disputed. Locks the two-source
# fix:
#   (a) the GraphQL exporter query pushes the 24h filter and sort:merged-
#       desc into the search itself (the previous `sort:updated-desc` +
#       client-side cutoff under-counted when stale-but-recently-updated
#       PRs exhausted the page cap before the in-window merges were
#       reached);
#   (b) the console verifier skips the Prom re-query for shipped_24h when
#       the textfile mtime advanced past the tile's observed_at — the
#       5-min exporter and 12-min console push run independently, so the
#       tile and the verifier were looking at the SAME Prom family at
#       DIFFERENT snapshots, and the difference was a transient timing
#       artifact, not a lying tile.
# Both are offline: stubs the network and tests the Python contract.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

exp="$repo_root/libexec/fleet-metrics-export.py"
ver="$repo_root/libexec/fleet-console-pi/verify.py"

[[ -f "$exp" ]] || fail "missing $exp"
[[ -f "$ver" ]] || fail "missing $ver"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

scratch="$(mktemp -d -t shipped-race.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# =========================================================================
# 1. MERGED_PRS_SEARCH_QUERY_TEMPLATE carries the in-window filter and the
#    correct sort. fleet-ops#2690.
# =========================================================================
grep -q 'MERGED_PRS_SEARCH_QUERY_TEMPLATE' "$exp" \
  || fail "MERGED_PRS_SEARCH_QUERY_TEMPLATE must replace the old constant"
grep -q 'sort:merged-desc' "$exp" \
  || fail "GraphQL query must use sort:merged-desc (was sort:updated-desc)"
grep -q 'merged:>={CUTOFF}' "$exp" \
  || fail "GraphQL query must carry merged:>={CUTOFF} (was client-side filter)"
# Regression guard: the broken $cutoff-via-graphql-variable pattern that
# does not work (GraphQL does not expand variables inside the search(query:)
# string field) must not be present in the search query string.
if grep -E 'merged:>=\\\$cutoff' "$exp" >/dev/null 2>&1; then
  fail "query must NOT pass cutoff as a GraphQL dollar-variable inside search(query:)"
fi
ok 'GraphQL exporter query: merged:>={CUTOFF} sort:merged-desc (template, not $dollar-variable)'

# Runtime substitution replaces {CUTOFF} with a real ISO timestamp
python3 - "$exp" "$scratch" <<'PY' || fail "query substitution test failed"
import importlib.util, re, sys, time
from pathlib import Path
from datetime import datetime, timezone, timedelta
exp_path, scratch = sys.argv[1], Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("fme", exp_path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# 1.1 Template uses a placeholder
tpl = m.MERGED_PRS_SEARCH_QUERY_TEMPLATE
assert "{CUTOFF}" in tpl, "template must keep a {CUTOFF} placeholder"
# 1.2 The in-window qualifier AND sort are both in the template (no $-vars)
assert "merged:>={CUTOFF}" in tpl, "merged:>={CUTOFF} qualifier missing"
assert "sort:merged-desc" in tpl, "sort:merged-desc missing"
# 1.3 No GraphQL $-variable form of cutoff inside the search string
assert "merged:>=$cutoff" not in tpl, "dollar-variable form would not expand inside search()"

# 1.4 Substituting {CUTOFF} with an ISO timestamp yields a query with a
# real merged:>={iso} filter and no leftover placeholder.
cutoff_epoch = time.time() - 86400
cutoff_iso = datetime.fromtimestamp(cutoff_epoch, tz=timezone.utc).strftime(
    "%Y-%m-%dT%H:%M:%SZ"
)
filled = tpl.replace("{CUTOFF}", cutoff_iso)
assert "{CUTOFF}" not in filled, "placeholder must be replaced"
assert f"merged:>={cutoff_iso}" in filled, "filled query must carry the real ISO"
assert "sort:merged-desc" in filled
print("OK: MERGED_PRS_SEARCH_QUERY_TEMPLATE substitution yields in-window merged:>=")

# 1.5 Defensive backstop inside _gh_merged_prs_raw: even with the query
# filter, a node whose mergedAt slipped past cutoff_epoch is still dropped.
nodes = [
    {"repository": {"nameWithOwner": "Org/repo"}, "mergedAt": "1970-01-01T00:00:00",
     "title": "old", "body": "", "additions": 0, "deletions": 0, "changedFiles": 0},
    {"repository": {"nameWithOwner": "Org/repo"}, "mergedAt": cutoff_iso + "X",  # malformed
     "title": "bad", "body": "", "additions": 0, "deletions": 0, "changedFiles": 0},
]
fake_payload = {"data": {"search": {
    "pageInfo": {"hasNextPage": False, "endCursor": None},
    "nodes": nodes,
}}}
m._gh_graphql = lambda q, c=None: fake_payload
out = m._gh_merged_prs_raw()
assert out == [], f"defensive backstop must drop out-of-window and malformed, got {out}"
print("OK: defensive client-side cutoff drops out-of-window + malformed mergedAt")
PY
ok "exporter query contract (in-window + defensive backstop)"

# =========================================================================
# 2. verify.py: shipped_24h Prom check is skipped on textfile race
# =========================================================================
grep -q '_race_against_tile' "$ver" \
  || fail "verify.py must define _race_against_tile"
grep -q 'def run_shipped_prom' "$ver" \
  || fail "verify.py must define run_shipped_prom"
ok "verify.py: race gate + shipped_prom runner present"

# 2.1 Race gate returns True when mtime advanced, False otherwise.
# 2.2 run_shipped_prom raises VerifyError("textfile mtime advanced") on race.
# 2.3 run_shipped_prom still queries Prom on no-race (negative test).
python3 - "$ver" "$scratch" <<'PY' || fail "verify race test failed"
import importlib.util, sys, time
from pathlib import Path
ver_path, scratch = sys.argv[1], Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("cv", ver_path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# --- 2.1 race gate truth table ---
now = time.time()
tile_now = {"observed_at": now}

# Mtime == observed_at: not a race (within +1s tolerance)
m._prom_textfile_mtime = lambda: now + 0.5
assert m._race_against_tile(tile_now) is False, "mtime <= observed_at must NOT be race"

# Mtime > observed_at + 1s: race
m._prom_textfile_mtime = lambda: now + 5
assert m._race_against_tile(tile_now) is True, "mtime advanced past observed_at must be race"

# Missing mtime (Prom has no series): not a race; let downstream checks run
m._prom_textfile_mtime = lambda: None
assert m._race_against_tile(tile_now) is False, "absent mtime must NOT be race"

# Missing observed_at on tile: not a race; let downstream checks run
m._prom_textfile_mtime = lambda: now + 5
assert m._race_against_tile({"observed_at": None}) is False, "no observed_at must NOT be race"

# Prom unreachable: not a race; downstream spot check still runs
def boom():
    raise m.VerifyError("prom down")
m._prom_textfile_mtime = boom
assert m._race_against_tile(tile_now) is False, "Prom down must NOT be race"
print("OK: _race_against_tile truth table (advance / same / absent / Prom-down)")

# --- 2.2 run_shipped_prom raises on race ---
calls = {"prom": 0, "textfile": 0}
def fake_textfile():
    calls["textfile"] += 1
    return now + 5  # race
def fake_promql_sum(expr):
    calls["prom"] += 1
    return 41.0
m._prom_textfile_mtime = fake_textfile
m._promql_sum = fake_promql_sum
try:
    m.run_shipped_prom(tile_now)
    raise AssertionError("expected VerifyError on race")
except m.VerifyError as e:
    assert "race" in str(e), str(e)
assert calls["prom"] == 0, f"run_shipped_prom must NOT query Prom on race, did {calls['prom']}"
print("OK: run_shipped_prom raises VerifyError on race; does NOT query Prom")

# --- 2.3 Negative — no race, query runs ---
m._prom_textfile_mtime = lambda: now
m._promql_sum = fake_promql_sum
calls["prom"] = 0
result = m.run_shipped_prom(tile_now)
assert result == 41, f"no-race must run Prom, got {result}"
assert calls["prom"] == 1, "no-race must call _promql_sum exactly once"
print("OK: run_shipped_prom runs Prom when no race")
PY
ok "verify.py: race gate prevents false DISPUTED on textfile refresh"

# =========================================================================
# 3. End-to-end: a tile whose tile.observed_at is OLD vs the live mtime
#    must NOT be marked DISPUTED by the shipped_prom runner. The gh spot
#    check is what catches lying tiles; the Prom check is a race-bypass.
# =========================================================================
python3 - "$ver" "$scratch" <<'PY' || fail "end-to-end race test failed"
import importlib.util, json, sys, time
from pathlib import Path
ver_path, scratch = sys.argv[1], Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("cv", ver_path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# Live-ish fake tile doc matching the deployed shape. observed_at is set
# to T1; the live mtime is T1+5 (textfile refreshed in between).
t1 = time.time() - 60
doc = {"tiles": {
    "open_prs": {"source": "x", "stale_after_s": 900, "ok": True,
                  "observed_at": t1, "count": 0, "items": []},
    "shipped_24h": {"source": "prometheus:fleet_product_merged_24h",
                     "stale_after_s": 900, "ok": True,
                     "observed_at": t1, "count": 41,
                     "items": [{"repo": "Nishfleet/fleet-ops", "count": 31},
                               {"repo": "Nishfleet/0509", "count": 10}]},
    "main_ci": {"source": "x", "stale_after_s": 900, "ok": True,
                 "observed_at": t1, "red_count": 0, "items": []},
    "firing_alerts": {"source": "x", "stale_after_s": 900, "ok": True,
                       "observed_at": t1, "count": 0, "items": []},
    "repairs_inflight": {"source": "x", "stale_after_s": 1200, "ok": True,
                          "observed_at": t1, "count": 0},
    "running_pi": {"source": "x", "stale_after_s": 1800, "ok": True,
                    "observed_at": t1, "count": 0},
    "fleet_state": {"source": "x", "stale_after_s": 3600, "ok": True,
                     "observed_at": t1, "paused": False},
}}
data = scratch / "data.json"
prom_out = scratch / "tiles.prom"
data.write_text(json.dumps(doc))
m.PROM_OUT = prom_out
m.SKIP_GH = True

# Fake Prom: mtime advanced past observed_at (race), Prom sum is 42
# (textfile refreshed between tile and verify).
m._prom_textfile_mtime = lambda: t1 + 5
m._promql_sum = lambda expr: 42.0  # would DISPUTED without the race gate
m.RUNNERS["repairs_units"] = lambda t: 0
m.RUNNERS["fleet_paused"] = lambda t: 0
m.RUNNERS["open_prs_prom"] = lambda t: 0
m.RUNNERS["main_ci_prom"] = lambda t: 0
m.RUNNERS["alerts_am"] = lambda t: 0
m.RUNNERS["running_pi_execstart"] = lambda t: 0

results = m.run(data_path=data, inject=None)
assert results["shipped_24h"] == 0, \
    f"race must NOT dispute (tile=41, prom=42, race gate should skip), got {results['shipped_24h']}"  # product-slo source
out = json.loads(data.read_text())
tile = out["tiles"]["shipped_24h"]
assert tile["disputed"] is False, tile
# Spot reason: skipped (race detected)
assert "race" in tile.get("verify", {}).get("error", "").lower() \
    or "race" in str(tile.get("verify", {})).lower(), tile.get("verify")
# fleet-console-tiles.prom must say mismatch=0 for shipped_24h (a skipped
# Prom check is not a dispute).
text = prom_out.read_text()
assert 'fleet_console_tile_mismatch{tile="shipped_24h"} 0' in text, text
print("OK: end-to-end race (tile=41, prom=42, mtime advanced) -> NOT DISPUTED")

# 3.b — same tile WITHOUT race: Prom=42 disagrees with tile=41, DISPUTED.
m._prom_textfile_mtime = lambda: t1  # same mtime -> no race
results = m.run(data_path=data, inject=None)
assert results["shipped_24h"] == 1, \
    f"Prom check must DISPUTE when tile != Prom and no race, got {results['shipped_24h']}"
out = json.loads(data.read_text())
assert out["tiles"]["shipped_24h"]["disputed"] is True
print("OK: end-to-end no-race mismatch (tile=41, prom=42) -> DISPUTED (the lying-tile path)")
PY
ok "verify.py end-to-end: race skipped, lying tile still DISPUTED"

# =========================================================================
# 4. Regression: the shipped_prom runner contract is documented in the
#    spec so the dashboard "what is this?" still cites the check
# =========================================================================
grep -q 'shipped_24h' "$ver" || fail "verify.py lost the shipped_24h spec"
grep -q 'shipped_prom' "$ver" || fail "verify.py lost the shipped_prom runner"
grep -q 'run_shipped_gh_spot' "$ver" || fail "verify.py lost the gh spot check"
ok "verify.py spec + runners intact"

echo "OK: console-shipped-24h-race.test.sh"