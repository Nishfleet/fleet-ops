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
# Offline: stubs the network and tests the Python contract. Part (b) of this
# lock (the console verifier's race gate) went with
# libexec/fleet-console-pi/verify.py in the 2026-09-18 glue sweep.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

exp="$repo_root/libexec/fleet-metrics-export.py"

[[ -f "$exp" ]] || fail "missing $exp"
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

echo "OK: console-shipped-24h-race.test.sh (exporter half; the console verifier
     libexec/fleet-console-pi/verify.py was deleted in the 2026-09-18 glue sweep)"
