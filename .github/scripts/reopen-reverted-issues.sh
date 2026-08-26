#!/usr/bin/env bash
# .github/scripts/reopen-reverted-issues.sh
#
# Given a reverted merge commit and the revert PR number, find the PR that
# originally landed that commit and reopen any issues it closed.
#
# Usage: reopen-reverted-issues.sh <repo> <head_sha> <revert_pr_number>
#
# Environment:
#   GH_TOKEN  Token for gh (passed through by the caller).
#
# Writes warnings to stderr. Exits 0 when there is nothing to reopen or when
# all closed issues have been processed.

set -euo pipefail

repo="${1:-}"
head_sha="${2:-}"
revert_pr="${3:-}"

if [[ -z "$repo" || -z "$head_sha" || -z "$revert_pr" ]]; then
  echo "usage: $0 <repo> <head_sha> <revert_pr_number>" >&2
  exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "gh not found in PATH" >&2
  exit 1
fi

# Find the first merged PR associated with the failing (reverted) commit.
# A commit may be associated with closed/duplicate PRs; only merged ones can
# have legitimately closed issues via closingIssuesReferences.
orig_pr=$(gh api "repos/$repo/commits/$head_sha/pulls" \
  --jq '[.[] | select(.merged_at != null)] | .[0].number' 2>/dev/null || true)

if [[ -z "$orig_pr" || "$orig_pr" == "null" ]]; then
  echo "no merged PR associated with commit $head_sha; nothing to reopen" >&2
  exit 0
fi

# Double-check the PR state. The merged_at filter above is the source of truth,
# but a deleted PR could still appear in the association list, so gh pr view is
# a cheap guard.
orig_state=$(gh pr view "$orig_pr" -R "$repo" --json state --jq '.state' 2>/dev/null || true)
if [[ "$orig_state" != "MERGED" ]]; then
  echo "associated PR #$orig_pr is not merged (state=$orig_state); nothing to reopen" >&2
  exit 0
fi

closing=$(gh pr view "$orig_pr" -R "$repo" \
  --json closingIssuesReferences --jq '.closingIssuesReferences' 2>/dev/null || true)

if [[ -z "$closing" || "$closing" == "[]" ]]; then
  echo "PR #$orig_pr did not close any issues; nothing to reopen" >&2
  exit 0
fi

revert_url="https://github.com/$repo/pull/$revert_pr"
comment="The delivery in #$orig_pr was undone by revert PR #$revert_pr ($revert_url). Reopening so the gap board reflects the undone work."

reopened=0
while IFS= read -r issue_number; do
  [[ -z "$issue_number" ]] && continue

  issue_state=$(gh issue view "$issue_number" -R "$repo" --json state --jq '.state' 2>/dev/null || true)
  if [[ "$issue_state" != "CLOSED" ]]; then
    echo "issue #$issue_number is not closed (state=$issue_state); skipping" >&2
    continue
  fi

  if gh issue reopen "$issue_number" -R "$repo" --comment "$comment" >/dev/null 2>&1; then
    echo "reopened issue #$issue_number"
    reopened=$((reopened + 1))
  else
    echo "failed to reopen issue #$issue_number" >&2
  fi
done < <(printf '%s' "$closing" | jq -r '.[].number')

if [[ "$reopened" -gt 0 ]]; then
  echo "reopened $reopened issue(s) for PR #$orig_pr"
else
  echo "no issues were reopened for PR #$orig_pr"
fi
