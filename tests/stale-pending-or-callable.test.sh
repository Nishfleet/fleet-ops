#!/usr/bin/env bash
# tests/stale-pending-or-callable.test.sh
#
# fleet-ops#3311: the triage-close workflow may live in docs/pending-stale/
# while the nishfleet-worker PR is open, then move to .github/workflows/
# when a token with Workflows scope lands it. This test checks either
# location, validates the fleet-ops#3311 input contract, and proves every
# `with:` input name exists in the pinned actions/stale action.yml.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()  { echo "OK: $*"; }

# Prefer the callable path once landed; fall back to the parked dir.
resolve_wf() {
  if [ -f "$repo_root/.github/workflows/stale.yml" ]; then
    echo "$repo_root/.github/workflows/stale.yml"
  else
    echo "$repo_root/docs/pending-stale/stale.yml"
  fi
}
wf="$(resolve_wf)"
[[ -f "$wf" ]] || fail "stale.yml not found in .github/workflows/ or docs/pending-stale/"
ok "workflow found: $wf"

# 1. fleet-ops#3311 input contract (Nish 2026-09-04, battle-tested only).
grep -q 'uses: actions/stale@' "$wf" || fail "workflow must pin actions/stale"
grep -q 'days-before-stale: 2' "$wf" || fail "days-before-stale must be 2 (48h)"
grep -q 'days-before-close: 0' "$wf" || fail "days-before-close must be 0 (close in the run it goes stale)"
grep -q 'days-before-pr-stale: -1' "$wf" || fail "PR staleness must be disabled"
grep -q 'days-before-pr-close: -1' "$wf" || fail "PR closes must be disabled"
grep -q '^[[:space:]]*only-issue-labels: ""' "$wf" \
  || fail "only-issue-labels must be empty (unlabeled auto-filed issues are the target)"
grep -Fq 'critical-path,landing-0904,umbrella,agent-in-progress,agent-ready,escalate-senior,research-delta,red-on-main,stop-the-line' "$wf" \
  || fail "exempt-issue-labels must carry the full protected list"
# The close-issue-message is a folded scalar (>-); YAML joins the continuation
# lines with single spaces, so grep a whitespace-normalized view of the file.
wf_norm="$(tr '\n' ' ' < "$wf" | tr -s ' ')"
grep -Fq 'triage-closed: unclaimed 48h' <<< "$wf_norm" || fail "close message must be the triage-closed note"
grep -Fq 're-file with a moves: line if it still matters' <<< "$wf_norm" \
  || fail "close message must carry the re-file rule"
grep -q 'operations-per-run: 30' "$wf" || fail "operations-per-run must be capped (30)"
ok "fleet-ops#3311 input contract present (2 days, close 0, empty only-issue-labels, exempt list, capped ops)"

# 2. Every `with:` input must exist in the pinned actions/stale action.yml.
pin="$(grep -oE 'actions/stale@[0-9a-f]{40}' "$wf" | head -1 | cut -d@ -f2)"
[[ "$pin" =~ ^[0-9a-f]{40}$ ]] || fail "could not extract a pinned actions/stale SHA from $wf"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "https://raw.githubusercontent.com/actions/stale/$pin/action.yml" -o "$tmp/action.yml" \
    || fail "could not fetch actions/stale action.yml at $pin"
else
  fail "curl not found; cannot validate inputs against the pinned action.yml"
fi
sed -n '/^inputs:/,/^runs:/p' "$tmp/action.yml" \
  | grep -E '^  [a-z-]+:' | sed 's/^  //;s/:$//' | sort -u > "$tmp/input-names.txt"
# with: keys in the workflow are indented one level under `with:`.
grep -oE '^ {10}[a-z-]+:' "$wf" | tr -d ' :' | sort -u > "$tmp/used-inputs.txt"
[[ -s "$tmp/used-inputs.txt" ]] || fail "no with: inputs extracted from $wf"
while read -r name; do
  grep -qx "$name" "$tmp/input-names.txt" || fail "unknown actions/stale input: $name"
done < "$tmp/used-inputs.txt"
ok "all with: inputs ($(wc -l < "$tmp/used-inputs.txt") unique) exist in actions/stale@${pin:0:7} action.yml"

# 3. The README must exist while the workflow is parked and name the target.
if [ ! -f "$repo_root/.github/workflows/stale.yml" ]; then
  readme="$repo_root/docs/pending-stale/README.md"
  [[ -f "$readme" ]] || fail "docs/pending-stale/README.md must exist while the workflow is parked"
  grep -q '.github/workflows/' "$readme" || fail "README must name the target .github/workflows/ path"
  ok "README documents the workflow-scoped landing path"
fi

# 4. CI host check (fleet-ops#497 shape): listed in ci.yml's verify-command or
#    invoked from a test that is already in the P14 reachable set.
ci_yml="$repo_root/.github/workflows/ci.yml"
hosted=0
grep -Fq 'bash tests/stale-pending-or-callable.test.sh' "$ci_yml" && hosted=1 || true
grep -Fq 'bash "$here/stale-pending-or-callable.test.sh"' "$here/reusable-workflows.test.sh" \
  && hosted=1 || true
if [ "$hosted" -ne 1 ]; then
  fail "stale-pending-or-callable.test.sh has no CI host: list it in ci.yml's verify-command or invoke it from reusable-workflows.test.sh"
fi
ok "hosted in the P14 reachable set via tests/reusable-workflows.test.sh"

echo "OK: stale triage-close workflow is shape-correct, input-valid, and hosted"