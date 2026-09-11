#!/usr/bin/env bash
# .github/scripts/auto-revert.sh
#
# Revert red commits on main. Two repair shapes:
#
#   - single red: the failing run's head is still main HEAD -> revert that
#     commit, but only when at least one required status check failed.
#     Non-required failures (e.g. P14 tests on a hosted runner) surface as a
#     halt issue instead of an automatic revert.
#   - consecutive red (>=2 completed runs of the watched workflow on main in
#     a row, newest first): commits outpaced the per-commit freshness guard,
#     so identify the commit(s) since the last green main run and open ONE
#     range-revert PR from a repair branch that restores the last green
#     tree. Loud: an ALERT log line plus an auto-filed issue naming the
#     reverted shas and the failing run ids. Never silent. (fleet-ops#5597)
#
# Refusals — a deliberate decision not to open a revert PR (main moved on a
# single red, a red revert, no green baseline, a recovery PR already in
# flight, an already-open revert for this sha) — end the run NEUTRAL: the
# halt issue is the loud surface and a red Auto revert run is a false red
# signal in exactly the window humans and detectors read (fleet-ops#5572,
# #5597). Mechanism failures mid-repair (revert conflict, push/PR/arm
# failure) still fail the run — that red is real, and it is filed loud.
#
# Range repairs use repair/red-main-* branches, not revert/*: the
# stale-auto-revert sweep (#349) closes revert/* PRs whose sha main moved
# past, which is by definition every range repair — the range exists
# because main moved.

set -euo pipefail

ISSUE_FILE="${FLEET_ISSUE_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/bin/fleet-issue-file}"

short="$(git rev-parse --short=7 "$HEAD_SHA")"
subject="$(git log --format=%s -n 1 "$HEAD_SHA")"
parents="$(git rev-list --parents -n 1 "$HEAD_SHA")"
merge_flag=()
[ "$(printf '%s' "$parents" | wc -w)" -gt 2 ] && merge_flag=(-m 1)

gh label create auto-revert-halt --repo "$REPO" --color B60205 \
  --description "Auto-revert halted — a human must look" --force >/dev/null 2>&1 || true

halt () {
  title="$1"; body="$2"
  # Dedup by exact title, not by label. Post-#336 SKIP runs had Issues: write
  # and `gh issue create --label auto-revert-halt` exited 0 (run 32983348879
  # printed https://github.com/Nishfleet/fleet-ops/issues/361), yet every
  # created issue has zero labels and zero label events. Label lookup always
  # missed, so every red event opened a new issue. Halt titles are constant
  # strings; an exact-title list finds the rolling issue even when the label
  # never sticks. --label on create stays best-effort tagging.
  hits="$(gh issue list --repo "$REPO" --state open --limit 100 \
    --search "\"$title\" in:title" \
    --json number,title 2>/dev/null || true)"
  num=""
  if [ -n "$hits" ]; then
    num="$(printf '%s' "$hits" | jq -r --arg t "$title" \
      '[.[] | select(.title == $t)] | sort_by(.number) | .[0].number // empty' \
      2>/dev/null || true)"
  fi
  if [ -n "$num" ]; then
    # gh issue comment uses GraphQL addComment. AUTO_REVERT_PAT is a personal
    # access token; GitHub refuses that mutation with
    # "Resource not accessible by personal access token (addComment)"
    # (run 33014946635, fleet-ops#596). REST Create an issue comment accepts
    # the same PAT. `gh api -F` POSTs when fields are set (see gh api --help).
    # Comment failure must not redden Auto revert: the halt issue already
    # exists, which is the loud surface. SKIP then exits 0.
    if ! printf '%s' "$body" | gh api "repos/${REPO}/issues/${num}/comments" \
         -F body=@- >/dev/null; then
      echo "warning: REST comment on #${num} failed; halt issue already open" >&2
    fi
    extras="$(printf '%s' "$hits" | jq -r --arg t "$title" --arg n "$num" \
      '.[] | select(.title == $t and (.number | tostring) != $n) | .number' \
      2>/dev/null || true)"
    while IFS= read -r extra; do
      [ -z "$extra" ] && continue
      gh issue close "$extra" --repo "$REPO" --duplicate-of "$num" \
        --comment "Duplicate of #$num. Later SKIP events comment there instead of opening a new issue." \
        || true
    done <<< "$extras"
  else
    "$ISSUE_FILE" file --repo "$REPO" --title "$title" --body "$body" --label auto-revert-halt
  fi
}

# A refusal is a deliberate decision not to open a revert PR. It files the
# loud halt issue (the surface humans read), writes the refused: line to the
# step summary, and ends the run NEUTRAL — never a false red (fleet-ops#5597).
refuse () {
  title="$1"; body="$2"; reason="$3"
  halt "$title" "$body"
  line="refused: checks non-green on ${HEAD_SHA} — ${reason}"
  echo "$line"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf -- '- %s\n' "$line" >> "$GITHUB_STEP_SUMMARY" || true
  fi
  exit 0
}

# A mechanism failure mid-repair (conflict, push, PR create/arm) is a real
# red — but it is filed loud first, never a silent exit.
repair_failed () {
  title="$1"; body="$2"
  halt "$title" "$body"
  echo "ALERT: auto-revert mechanism failed — ${title}" >&2
  exit 1
}

main_head="$(git rev-parse HEAD)"
main_short="$(git rev-parse --short=7 "$main_head")"

# --- consecutive-red streak (fleet-ops#5597) --------------------------------
# Count the newest completed push runs of the triggering workflow on main
# that ended failure/timed_out, stopping at the first green. The triggering
# run is itself completed (workflow_run fired), so a lone red gives
# streak=1. An unreachable/empty API response degrades to streak=0 — the
# single-red path below is the safe fallback.
streak=0
last_green=""
failing_lines=""
if [ -n "${WORKFLOW_ID:-}" ]; then
  runs_tsv="$(gh api "repos/$REPO/actions/workflows/$WORKFLOW_ID/runs?branch=main&event=push&status=completed&per_page=30" \
    --jq '.workflow_runs[] | [.conclusion, .head_sha, (.id|tostring), .html_url] | @tsv' 2>/dev/null || true)"
  while IFS=$'\t' read -r concl sha rid url; do
    [ -z "${concl:-}" ] && continue
    case "$concl" in
      failure|timed_out)
        streak=$((streak + 1))
        failing_lines="${failing_lines}- ${RUN_NAME} run ${rid} on \`${sha}\` — ${url}"$'\n'
        ;;
      success)
        last_green="$sha"
        break
        ;;
      *) ;;  # cancelled/skipped/neutral: neither red nor green evidence
    esac
  done <<< "$runs_tsv"
  failing_lines="${failing_lines%$'\n'}"
fi

if [ "$streak" -ge 2 ]; then
  # --- consecutive-red range repair ---------------------------------------
  # The single-commit freshness guard cannot catch up when each red landing
  # is followed by another before the workflow_run fires. Revert the whole
  # range since the last green main run instead (fleet-ops#5597).
  main_subject="$(git log --format=%s -n 1 "$main_head")"
  case "$main_subject" in
    revert:*|Revert*)
      refuse "AUTO-REVERT HALT: revert commit itself is red on main" \
"Main's red tip is itself a revert, so an automatic revert would loop.

- Failing runs (newest first):
${failing_lines}
- Red tip: \`$main_head\` — \`$main_subject\`

One level of automatic undo only. A red revert is a structural stop; a human must look." \
        "red tip ${main_short} is itself a revert (loop guard)"
      ;;
  esac

  if [ -z "$last_green" ]; then
    refuse "AUTO-REVERT HALT: consecutive red runs but no green baseline" \
"${streak} consecutive ${RUN_NAME} runs failed on main and no green run exists in the last 30 completed main runs to anchor a range revert.

- Failing runs (newest first):
${failing_lines}
- Red tip: \`$main_head\` — \`$main_subject\`

No last-green tree to restore; a human must pick the revert boundary." \
      "no green ${RUN_NAME} baseline in the last 30 completed main runs"
  fi

  if ! git merge-base --is-ancestor "$last_green" "$main_head"; then
    refuse "AUTO-REVERT HALT: last green is not an ancestor of main" \
"${streak} consecutive ${RUN_NAME} runs failed on main, but the last green run's head is not an ancestor of the red tip — main history moved under the run.

- Failing runs (newest first):
${failing_lines}
- Last green run head: \`$last_green\`
- Red tip: \`$main_head\`

A human must pick the revert boundary." \
      "last green ${last_green} is not an ancestor of ${main_short}"
  fi

  mapfile -t range_commits < <(git rev-list "${last_green}..${main_head}")
  if [ "${#range_commits[@]}" -eq 0 ]; then
    refuse "AUTO-REVERT SKIP: red streak but empty range" \
"${streak} consecutive ${RUN_NAME} runs failed on main, yet no commits sit between the last green run and the red tip — nothing to revert.

- Failing runs (newest first):
${failing_lines}
- Last green run head: \`$last_green\`
- Red tip: \`$main_head\`" \
      "empty range ${last_green}..${main_short}"
  fi

  # An earlier recovery PR for an older red tip already reverts a subset of
  # this range; two armed revert PRs would race and conflict. Let it land —
  # if later commits are still red the next run opens the wider range.
  open_repair="$(gh pr list --repo "$REPO" --state open --limit 50 \
    --json number,headRefName \
    --jq '.[] | select(.headRefName | startswith("repair/red-main-")) | .number' \
    2>/dev/null | head -n1 || true)"
  if [ -n "$open_repair" ]; then
    refuse "AUTO-REVERT SKIP: recovery PR already in flight" \
"${streak} consecutive ${RUN_NAME} runs failed on main, but recovery PR #${open_repair} (repair/red-main-*) is already open and reverts an overlapping red range.

- Failing runs (newest first):
${failing_lines}
- Red tip: \`$main_head\`

Let the in-flight recovery land; a still-red main re-triggers this repair." \
      "recovery PR #${open_repair} already in flight"
  fi

  reverted_subjects=""
  for sha in "${range_commits[@]}"; do
    reverted_subjects="${reverted_subjects}- \`$(git rev-parse --short=7 "$sha")\` $(git log --format=%s -n 1 "$sha")"$'\n'
  done

  branch="repair/red-main-${main_short}"
  git config user.name "Nish"
  git config user.email "257724087+nish3451@users.noreply.github.com"
  git checkout -b "$branch"
  for sha in "${range_commits[@]}"; do
    pcount="$(git rev-list --parents -n 1 "$sha" | wc -w)"
    revert_rc=0
    if [ "$pcount" -gt 2 ]; then
      git revert --no-edit -m 1 "$sha" || revert_rc=$?
    else
      git revert --no-edit "$sha" || revert_rc=$?
    fi
    if [ "$revert_rc" -ne 0 ]; then
      git revert --abort >/dev/null 2>&1 || true
      repair_failed "AUTO-REVERT HALT: consecutive-red range revert conflicted" \
"${streak} consecutive ${RUN_NAME} runs failed on main; the range revert could not apply cleanly.

- Failing runs (newest first):
${failing_lines}
- Range: \`${last_green}..${main_head}\` (${#range_commits[@]} commit(s))
- Conflict on: \`$sha\`

A human must revert this range by hand."
    fi
  done

  if ! git push origin "$branch"; then
    repair_failed "AUTO-REVERT HALT: recovery branch push failed" \
"Range revert built locally but \`git push origin ${branch}\` failed (a range touching .github/workflows/** cannot be pushed by the worker App token).

- Range: \`${last_green}..${main_head}\` (${#range_commits[@]} commit(s))"
  fi

  pr_body="Automatic revert opened because a push-to-main CI workflow went red.

Consecutive-red repair (fleet-ops#5597): ${streak} consecutive ${RUN_NAME} runs failed on main, so this PR reverts the ${#range_commits[@]} commit(s) since the last green main run instead of a single tip.

- Range: \`${last_green}..${main_head}\` — restores the last green tree
- Reverted commits (newest first):
${reverted_subjects}
- Failing runs (newest first):
${failing_lines}
- Last green run head: \`${last_green}\`

Automatic revert per the reversibility principle (FABLE-VERDICT §17); if this PR fails checks it will sit unmerged and loud."

  pr_url=""
  if pr_url="$(gh pr create --repo "$REPO" --base main --head "$branch" \
    --title "revert: auto-restore green main (reverts ${last_green:0:7}..${main_short})" \
    --body "$pr_body")"; then
    :
  else
    repair_failed "AUTO-REVERT HALT: recovery PR create failed" \
"Range revert pushed to \`${branch}\` but \`gh pr create\` failed.

- Range: \`${last_green}..${main_head}\` (${#range_commits[@]} commit(s))"
  fi

  revert_pr="$(printf '%s' "$pr_url" | grep -oE 'https://github\.com/[^/]+/[^/]+/pull/[0-9]+' | tail -n1 | awk -F/ '{print $NF}')" || true
  if [[ -z "$revert_pr" ]]; then
    repair_failed "AUTO-REVERT HALT: recovery PR number unparseable" \
"\`gh pr create\` output carried no PR URL: ${pr_url}"
  fi

  if ! gh pr merge --auto --squash --repo "$REPO" "$revert_pr"; then
    repair_failed "AUTO-REVERT HALT: recovery PR arm failed" \
"Recovery PR #${revert_pr} (${pr_url}) opened but \`gh pr merge --auto --squash\` failed; it sits unmerged and loud."
  fi

  echo "ALERT: consecutive-red main — ${streak} ${RUN_NAME} runs failed; opened ${pr_url} reverting ${#range_commits[@]} commit(s) in ${last_green}..${main_head}"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf -- '- repaired: opened %s reverting %s commit(s) since last green %s\n' \
      "$pr_url" "${#range_commits[@]}" "$last_green" >> "$GITHUB_STEP_SUMMARY" || true
  fi
  halt "AUTO-REVERT RECOVERY: consecutive-red main — revert PR opened" \
"${streak} consecutive ${RUN_NAME} runs failed on main; opened ${pr_url} reverting ${#range_commits[@]} commit(s) since the last green run.

- Recovery PR: ${pr_url} (auto-merge armed; required checks are the proof the revert restores green)
- Reverted commits (newest first):
${reverted_subjects}
- Failing runs (newest first):
${failing_lines}
- Last green run head: \`${last_green}\`

fleet-ops#5597: the #5572 freeze clears on the next green Deploy production run with no human step."

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for sha in "${range_commits[@]}"; do
    bash "$script_dir/reopen-reverted-issues.sh" "$REPO" "$sha" "$revert_pr" \
      || echo "warning: reopen pass failed for $sha" >&2
  done
  exit 0
fi

# --- single-red path --------------------------------------------------------

case "$subject" in
  revert:*|Revert*)
    refuse "AUTO-REVERT HALT: revert commit itself is red on main" \
"The failing run's head commit is itself a revert, so an automatic revert would loop.

- Failing run: $RUN_NAME — $RUN_URL
- Red commit: \`$HEAD_SHA\` — \`$subject\`

One level of automatic undo only. A red revert is a structural stop; a human must look." \
      "red commit is itself a revert (loop guard)"
    ;;
esac

if [ "$main_head" != "$HEAD_SHA" ]; then
  refuse "AUTO-REVERT HALT: main moved after the red commit" \
"main's HEAD no longer matches the failing commit, so a blind revert could restore the wrong state.

- Failing run: $RUN_NAME — $RUN_URL
- Red commit: \`$HEAD_SHA\` — \`$subject\`
- main HEAD now: \`$main_head\`

Single red, main moved: the next red run's consecutive-red path repairs the range instead (fleet-ops#5597)." \
    "main moved to ${main_short} after the red commit"
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
  halt "AUTO-REVERT SKIP: only non-required checks failed" \
"The CI run failed, but none of the branch's required status checks are red, so the green merge stays on main.

- Failing run: $RUN_NAME — $RUN_URL
- Red commit: \`$HEAD_SHA\` — \`$subject\`
- Non-required failing checks: $failing

This is a loud surface, not a revert. Fix the non-required check; no correct work is being undone."
  line="refused: checks non-green on ${HEAD_SHA} — only non-required checks failed (${failing})"
  echo "$line"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf -- '- %s\n' "$line" >> "$GITHUB_STEP_SUMMARY" || true
  fi
  exit 0
fi

branch="revert/$short"
existing="$(gh pr list --repo "$REPO" --state open --head "$branch" \
  --json number --jq '.[0].number // empty' 2>/dev/null || true)"
if [ -n "$existing" ]; then
  refuse "AUTO-REVERT SKIP: revert PR already open" \
"A revert PR for \`$HEAD_SHA\` already exists — opening a second would double-revert.

- Failing run: $RUN_NAME — $RUN_URL
- Red commit: \`$HEAD_SHA\` — \`$subject\`
- Open revert PR: #${existing}" \
    "revert PR #${existing} already covers ${short}"
fi

git config user.name "Nish"
git config user.email "257724087+nish3451@users.noreply.github.com"
if ! git revert --no-edit "${merge_flag[@]}" "$HEAD_SHA"; then
  git revert --abort >/dev/null 2>&1 || true
  repair_failed "AUTO-REVERT HALT: single-commit revert conflicted" \
"The revert of \`$HEAD_SHA\` could not apply cleanly.

- Failing run: $RUN_NAME — $RUN_URL
- Red commit: \`$HEAD_SHA\` — \`$subject\`

A human must revert this commit by hand."
fi
git checkout -b "$branch"
if ! git push origin "$branch"; then
  repair_failed "AUTO-REVERT HALT: revert branch push failed" \
"Revert of \`$HEAD_SHA\` built locally but \`git push origin ${branch}\` failed (a diff touching .github/workflows/** cannot be pushed by the worker App token)."
fi
pr_url="$(gh pr create --repo "$REPO" --base main --head "$branch" \
  --title "revert: auto-restore green main (reverts $short)" \
  --body "Automatic revert opened because a push-to-main CI workflow went red.

- Failing run: $RUN_NAME — $RUN_URL
- Reverts commit \`$short\`: \`$subject\`
- Failing checks: $failing

Automatic revert per the reversibility principle (FABLE-VERDICT §17); if this PR fails checks it will sit unmerged and loud.")" \
  || repair_failed "AUTO-REVERT HALT: revert PR create failed" \
"Revert pushed to \`$branch\` but \`gh pr create\` failed."

revert_pr="$(printf '%s' "$pr_url" | grep -oE 'https://github\.com/[^/]+/[^/]+/pull/[0-9]+' | tail -n1 | awk -F/ '{print $NF}')" || true
if [[ -z "$revert_pr" ]]; then
  repair_failed "AUTO-REVERT HALT: revert PR number unparseable" \
    "\`gh pr create\` output carried no PR URL: ${pr_url}"
fi

if ! gh pr merge --auto --squash --repo "$REPO" "$revert_pr"; then
  repair_failed "AUTO-REVERT HALT: revert PR arm failed" \
"Revert PR #${revert_pr} (${pr_url}) opened but \`gh pr merge --auto --squash\` failed; it sits unmerged and loud."
fi
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$script_dir/reopen-reverted-issues.sh" "$REPO" "$HEAD_SHA" "$revert_pr" \
  || echo "warning: reopen pass failed for $HEAD_SHA" >&2
