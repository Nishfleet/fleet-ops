#!/usr/bin/env bash
# tests/closed-undelivered-detector.test.sh
#
# fleet-ops#3683 drill: the closed-but-undelivered detector flags an issue
# that was closed after a PR tried to deliver it but none of the referencing
# PRs merged (the #221/#76/#124 class), stays quiet when the referencing PR
# did merge, respects exclusion labels (duplicate / wontfix / triage-mass-
# close / staleness-detector / invalid), and ignores issues closed with no
# PR references at all (closed by hand for another reason — not a delivery).
#
# This is the mechanism that replaces the hand-verification seam filed in
# fleet-ops#3683: a mechanical detector, not a human eyeballing closed tabs.
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/closed-undelivered-gate.py"
fixtures="$here/fixtures/closed-undelivered-gate"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
python3 -m py_compile "$lib" || fail "closed-undelivered-gate.py failed py_compile"

# --- drill: flag a closed-but-undelivered issue ----------------------------
out=$(python3 "$lib" hunt --input "$fixtures/hunt-undelivered.json")
jq -e '.findings | length == 1' <<<"$out" >/dev/null \
  || fail "undelivered fixture must yield 1 finding, got: $out"
title=$(jq -r '.findings[0].title' <<<"$out")
grep -q 'closed-but-undelivered' <<<"$title" || fail "title must name the class: $title"
grep -q '#221' <<<"$title" || fail "title must name the issue number: $title"
evidence=$(jq -r '.findings[0].evidence' <<<"$out")
grep -q '#199' <<<"$evidence" || fail "evidence must name the unmerged referencing PR: $evidence"
grep -q 'fleet-ops#3683' <<<"$(jq -r '.findings[0].body' <<<"$out")" \
  || fail "body must cite fleet-ops#3683"
ok "drill FLAG: closed issue with unmerged referencing PR is flagged"

# --- drill: stay quiet when the referencing PR merged ----------------------
out=$(python3 "$lib" hunt --input "$fixtures/hunt-delivered.json")
jq -e '.findings | length == 0' <<<"$out" >/dev/null \
  || fail "delivered fixture must yield 0 findings, got: $out"
ok "drill QUIET: closed issue with a merged referencing PR is not flagged"

# --- drill: respect exclusion labels ---------------------------------------
out=$(python3 "$lib" hunt --input "$fixtures/hunt-excluded.json")
jq -e '.findings | length == 0' <<<"$out" >/dev/null \
  || fail "excluded fixture must yield 0 findings, got: $out"
ok "drill EXCLUDE: duplicate / wontfix / triage-mass-close are not flagged"

# --- drill: ignore issues closed with no PR references ---------------------
out=$(python3 "$lib" hunt --input "$fixtures/hunt-no-refs.json")
jq -e '.findings | length == 0' <<<"$out" >/dev/null \
  || fail "no-refs fixture must yield 0 findings, got: $out"
ok "drill NO-REFS: closed-by-hand issue with no PR refs is not flagged"

# --- stdin contract: same result via stdin as --input ----------------------
out_stdin=$(python3 "$lib" hunt < "$fixtures/hunt-undelivered.json")
jq -e '.findings | length == 1' <<<"$out_stdin" >/dev/null \
  || fail "stdin must match --input behaviour: $out_stdin"
ok "stdin and --input produce the same result"

# --- blind-audit wires the hunt (fleet-ops#3683) ---------------------------
grep -q 'closed-but-undelivered hunt' "$repo_root/bin/fleet-blind-audit" \
  || fail "fleet-blind-audit must merge the closed-but-undelivered hunt"
grep -q 'closedByPullRequestsReferences' "$repo_root/bin/fleet-blind-audit" \
  || fail "fleet-blind-audit must fetch closedByPullRequestsReferences"
grep -q 'closed-undelivered-gate.py' "$repo_root/bin/fleet-blind-audit" \
  || fail "fleet-blind-audit must resolve the closed-undelivered-gate lib"
ok "blind-audit wires the closed-but-undelivered hunt (fleet-ops#3683)"

echo "OK: closed-undelivered detector (fleet-ops#3683)"
