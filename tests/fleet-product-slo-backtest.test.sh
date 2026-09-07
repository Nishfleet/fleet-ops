#!/usr/bin/env bash
# tests/fleet-product-slo-backtest.test.sh
#
# fleet-ops#3759: the quality-ceiling proxy replay drill. Proves the
# `--backtest 4w --repo <r>` termination command recomputes the quality
# proxies over a historical merged-PR set and prints per-repo per-metric JSON
# that matches a hand-classified sample. Offline (no live gh) via fixture.
#
# Proves:
#   (a) --backtest 4w --repo <r> prints per-repo per-metric JSON
#   (b) post_merge_defects_per_100 counts only defect-labeled closing issues
#       (fleet-ops#3587) — a feat/fix closing its own original issue is NOT a
#       defect; a fix closing a bug-labeled issue IS
#   (c) reverts_per_100_merges counts in-week reverts
#   (d) sessions_to_pr_pct = 100 * in-week session dirs / merges_7d
#   (e) --backtest without --repo, or an unsupported window, exits nonzero
#   (f) --backtest works end-to-end through main() on a fixture

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
helper="$repo_root/lib/fleet-product-slo.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$helper" ]] || fail "missing $helper"
command -v python3 >/dev/null 2>&1 || fail "python3 required"
command -v jq >/dev/null 2>&1 || fail "jq required"

scratch="$(mktemp -d -t product-slo-backtest.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Fixed "now": 2026-09-02T12:00:00Z
NOW_ISO="2026-09-02T12:00:00Z"
NOW_TS=1788350400
DAY=86400

# Hand-classified fixture. NOW = 1788350400.
# 0509:
#   #1 feat merged 2d ago, closes its own issue (no defect label) -> NOT a defect
#   #2 Revert of #1 merged 1d ago -> in-week revert
#   #3 fix merged 1.5d ago closing a bug-labeled issue -> IS a post-merge defect
#   #4 fix merged 1d ago closing its own issue (no defect label) -> NOT a defect
#   #5 feat merged 10d ago (outside week) -> not in merges_7d
# fleet-ops:
#   #6 fix merged 1d ago closing its own issue (no defect label) -> NOT a defect
cat >"$scratch/fixture.json" <<JSON
{
  "repos": ["0509", "fleet-ops"],
  "prs": [
    {"number": 1, "repo": "0509", "title": "feat: a", "head_ref": "claim/1",
     "merged_ts": $((NOW_TS - 2 * DAY)), "issue_created_ts": $((NOW_TS - 3 * DAY))},
    {"number": 2, "repo": "0509", "title": "Revert \"feat: a\"", "head_ref": "revert/1",
     "merged_ts": $((NOW_TS - 1 * DAY)), "issue_created_ts": null},
    {"number": 3, "repo": "0509", "title": "fix: billing crash", "head_ref": "claim/3",
     "merged_ts": $((NOW_TS - 1 * DAY - 43200)), "issue_created_ts": $((NOW_TS - 2 * DAY)),
     "defect_issue_created_ts": $((NOW_TS - 2 * DAY))},
    {"number": 4, "repo": "0509", "title": "fix: copy", "head_ref": "claim/4",
     "merged_ts": $((NOW_TS - 1 * DAY)), "issue_created_ts": $((NOW_TS - 2 * DAY))},
    {"number": 5, "repo": "0509", "title": "feat: old", "head_ref": "claim/5",
     "merged_ts": $((NOW_TS - 10 * DAY)), "issue_created_ts": null},
    {"number": 6, "repo": "fleet-ops", "title": "fix: exporter", "head_ref": "claim/6",
     "merged_ts": $((NOW_TS - 1 * DAY)), "issue_created_ts": $((NOW_TS - 2 * DAY))}
  ]
}
JSON

# =========================================================================
# (a)(b)(c)(d) backtest JSON matches the hand-classified sample
# =========================================================================
# 4 in-week session dirs for 0509 -> sessions_to_pr_pct = 100 * 4 / 4 = 100.
mkdir -p "$scratch/sessions"
recent="$(date +%s)"
for n in 10 11 12 13; do
  d="$scratch/sessions/pi-issue-0509-$n"
  mkdir -p "$d"
  printf '{}\n' >"$d/session.jsonl"
  touch -d "@$recent" "$d/session.jsonl"
done

FLEET_PRODUCT_SLO_NOW="$NOW_ISO" \
FLEET_PRODUCT_SLO_FIXTURE="$scratch/fixture.json" \
FLEET_PRODUCT_SLO_SESSIONS="$scratch/sessions" \
  python3 "$helper" --backtest 4w --repo 0509 --repo fleet-ops \
  >"$scratch/backtest.json" 2>"$scratch/backtest.err" \
  || fail "--backtest exited nonzero: $(cat "$scratch/backtest.err")"

jq -e '.window == "4w"' "$scratch/backtest.json" >/dev/null \
  || fail "window must be 4w: $(cat "$scratch/backtest.json")"

# 0509: merges_7d = #1,#2,#3,#4 = 4 (revert #2 still counts as a merge).
jq -e '.repos["0509"].merges_7d == 4' "$scratch/backtest.json" >/dev/null \
  || fail "0509 merges_7d want 4: $(cat "$scratch/backtest.json")"
# reverts_7d = #2 = 1 -> 25/100.
jq -e '.repos["0509"].reverts_per_100_merges == 25' "$scratch/backtest.json" >/dev/null \
  || fail "0509 reverts want 25/100: $(cat "$scratch/backtest.json")"
# defects: only #3 closes a defect-labeled issue -> 1/4 = 25/100. #1 (feat)
# and #4 (fix, no label) are normal throughput, NOT defects (#3587).
jq -e '.repos["0509"].post_merge_defects_per_100 == 25' "$scratch/backtest.json" >/dev/null \
  || fail "0509 defects want 25/100: $(cat "$scratch/backtest.json")"
# sessions: 4 in-week dirs / 4 merges -> 100.0.
jq -e '.repos["0509"].sessions_to_pr_pct == 100' "$scratch/backtest.json" >/dev/null \
  || fail "0509 sessions want 100.0: $(cat "$scratch/backtest.json")"

# fleet-ops: merges_7d = #6 = 1, no reverts, no defects, no sessions.
jq -e '.repos["fleet-ops"].merges_7d == 1
  and .repos["fleet-ops"].reverts_per_100_merges == 0
  and .repos["fleet-ops"].post_merge_defects_per_100 == 0
  and .repos["fleet-ops"].sessions_to_pr_pct == 0' "$scratch/backtest.json" >/dev/null \
  || fail "fleet-ops backtest wrong: $(cat "$scratch/backtest.json")"
ok "(a)(b)(c)(d) backtest JSON matches hand-classified sample"

# =========================================================================
# (e) bad invocation exits nonzero
# =========================================================================
if FLEET_PRODUCT_SLO_FIXTURE="$scratch/fixture.json" \
   python3 "$helper" --backtest 4w >/dev/null 2>&1; then
  fail "--backtest without --repo must exit nonzero"
fi
if FLEET_PRODUCT_SLO_FIXTURE="$scratch/fixture.json" \
   python3 "$helper" --backtest 2w --repo 0509 >/dev/null 2>&1; then
  fail "--backtest with unsupported window must exit nonzero"
fi
ok "(e) --backtest bad invocation exits nonzero"

# =========================================================================
# (f) end-to-end through main() on a fixture (no live gh)
# =========================================================================
FLEET_PRODUCT_SLO_NOW="$NOW_ISO" \
FLEET_PRODUCT_SLO_FIXTURE="$scratch/fixture.json" \
FLEET_PRODUCT_SLO_SESSIONS="$scratch/sessions" \
  python3 "$helper" --backtest 4w --repo 0509 >"$scratch/bt2.json" 2>/dev/null \
  || fail "--backtest end-to-end exited nonzero"
jq -e '.repos["0509"].merges_7d == 4' "$scratch/bt2.json" >/dev/null \
  || fail "end-to-end 0509 merges_7d want 4: $(cat "$scratch/bt2.json")"
ok "(f) --backtest end-to-end through main()"

echo "OK: fleet-product-slo-backtest: replay drill matches hand-classified sample"
