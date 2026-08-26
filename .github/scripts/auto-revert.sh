#!/usr/bin/env bash
# .github/scripts/auto-revert.sh
#
# Revert a red commit on main, but only when at least one required status
# check failed. Non-required failures (e.g. P14 tests on a hosted runner)
# surface as a halt issue instead of an automatic revert.

set -euo pipefail

short="$(git rev-parse --short=7 "$HEAD_SHA")"
subject="$(git log --format=%s -n 1 "$HEAD_SHA")"
parents="$(git rev-list --parents -n 1 "$HEAD_SHA")"
merge_flag=()
[ "$(printf '%s' "$parents" | wc -w)" -gt 2 ] && merge_flag=(-m 1)

gh label create auto-revert-halt --repo "$REPO" --color B60205 \
  --description "Auto-revert halted — a human must look" --force >/dev/null 2>&1 || true

halt () {
  title="$1"; body="$2"
  num="$(gh issue list --repo "$REPO" --state open --label auto-revert-halt \
    --json number --jq '.[0].number // empty' 2>/dev/null || true)"
  if [ -n "$num" ]; then
    gh issue comment "$num" --repo "$REPO" --body "$body"
  else
    gh issue create --repo "$REPO" --title "$title" --body "$body" --label auto-revert-halt
  fi
}

case "$subject" in
  revert:*|Revert*)
    halt "AUTO-REVERT HALT: revert commit itself is red on main" "The failing run's head commit is itself a revert, so an automatic revert would loop.

- Failing run: $RUN_NAME — $RUN_URL
- Red commit: \`$HEAD_SHA\` — \`$subject\`

One level of automatic undo only. A red revert is a structural stop; a human must look."
    exit 1
    ;;
esac

main_head="$(git rev-parse HEAD)"
if [ "$main_head" != "$HEAD_SHA" ]; then
  halt "AUTO-REVERT HALT: main moved after the red commit" "main's HEAD no longer matches the failing commit, so a blind revert could restore the wrong state.

- Failing run: $RUN_NAME — $RUN_URL
- Red commit: \`$HEAD_SHA\` — \`$subject\`
- main HEAD now: \`$main_head\`

Human-order problem; a human must decide the revert order."
  exit 1
fi

# Failed check-run names, one per line.
failed_names_file="$(mktemp)"
required_names_file="$(mktemp)"
trap 'rm -f "$failed_names_file" "$required_names_file"' EXIT

gh api "repos/$REPO/commits/$HEAD_SHA/check-runs" --paginate \
  --jq '.check_runs[] | select(.conclusion=="failure") | .name' 2>/dev/null \
  | sort -u > "$failed_names_file" || true

failing="$(paste -sd', ' "$failed_names_file" || true)"
[ -z "$failing" ] && failing="(see run — no failed check-runs listed by the API)"

# Required status check contexts from branch protection, one per line.

required_raw="$(
  gh api "repos/$REPO/branches/main/protection" --paginate \
    --jq '[(.required_status_checks.contexts? // []), (.required_status_checks.checks? // [] | map(.context? // empty))] | flatten | .[]' 2>/dev/null || true
)"

if [ -n "$required_raw" ]; then
  printf '%s\n' "$required_raw" | sort -u > "$required_names_file"
else
  : > "$required_names_file"
fi

# Is any failed check a required one?
required_failed=()
while IFS= read -r name; do
  [ -z "$name" ] && continue
  while IFS= read -r ctx; do
    [ -z "$ctx" ] && continue
    if [ "$name" = "$ctx" ]; then
      required_failed+=("$name")
      break
    fi
  done < "$required_names_file"
done < "$failed_names_file"

if [ "${#required_failed[@]}" -eq 0 ]; then
  # No required check is red. Halt loudly, keep the merge on main.
  halt "AUTO-REVERT SKIP: only non-required checks failed" "The CI run failed, but none of the branch's required status checks are red, so the green merge stays on main.

- Failing run: $RUN_NAME — $RUN_URL
- Red commit: \`$HEAD_SHA\` — \`$subject\`
- Non-required failing checks: $failing

This is a loud surface, not a revert. Fix the non-required check; no correct work is being undone."
  exit 0
fi

branch="revert/$short"
git config user.name "Nish"
git config user.email "257724087+nish3451@users.noreply.github.com"
git revert --no-edit "${merge_flag[@]}" "$HEAD_SHA"
git checkout -b "$branch"
git push origin "$branch"
pr_url="$(gh pr create --repo "$REPO" --base main --head "$branch" \
  --title "revert: auto-restore green main (reverts $short)" \
  --body "Automatic revert opened because a push-to-main CI workflow went red.

- Failing run: $RUN_NAME — $RUN_URL
- Reverts commit \`$short\`: \`$subject\`
- Failing checks: $failing

Automatic revert per the reversibility principle (FABLE-VERDICT §17); if this PR fails checks it will sit unmerged and loud.")"

revert_pr="$(printf '%s' "$pr_url" | grep -oE 'https://github\.com/[^/]+/[^/]+/pull/[0-9]+' | tail -n1 | awk -F/ '{print $NF}')" || true
if [[ -z "$revert_pr" ]]; then
  echo "::error::could not parse revert PR number from create output" >&2
  exit 1
fi

gh pr merge --auto --squash --repo "$REPO" "$revert_pr"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$script_dir/reopen-reverted-issues.sh" "$REPO" "$HEAD_SHA" "$revert_pr"
