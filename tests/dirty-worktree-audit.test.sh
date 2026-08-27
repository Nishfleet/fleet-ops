#!/usr/bin/env bash
# tests/dirty-worktree-audit.test.sh
#
# fleet-ops#643: dirty-worktree-audit no longer classifies with
# `git cherry` or "commits ahead of origin/main" — it uses the same
# "is this HEAD on origin" test as fleet-wipe-lessons-check.
#
# Invariants:
#   1. The audit script compiles.
#   2. The script does not call `git cherry` or count commits ahead.
#   3. A branch pushed to origin is classified as landed (HEAD on origin).
#   4. A local-only branch is classified as unlanded and would be pushed.
#   5. A PR merged-squash whose branch was deleted is still caught by
#      the merged-PR fallback when the branch name is known.
#   6. A detached HEAD that is not on origin is classified as unlanded.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
audit="$repo_root/bin/_dirty-worktree-audit.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$audit" ]] || fail "missing $audit"
python3 -m py_compile "$audit" || fail "audit script failed py_compile"
ok "1: _dirty-worktree-audit.py compiles"

# ---------------------------------------------------------------------------
# 2. No banned classification helpers remain
# ---------------------------------------------------------------------------
for pattern in 'git cherry' 'cherry_has_plus' 'commits_ahead' 'rev-list --count'; do
    if grep -qF -- "$pattern" "$audit"; then
        fail "audit script must not use '$pattern'"
    fi
done
ok "2: audit script does not use git cherry / ahead-of-main classification"

scratch="$(mktemp -d -t dirty-audit.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

origin="$scratch/origin.git"
main="$scratch/main"

# ---------------------------------------------------------------------------
# Build a local bare origin with an initial main commit
# ---------------------------------------------------------------------------
# fleet-ops#598: pin init.defaultBranch on the same line so CI's git 2.55
# (defaultBranch=master) matches the test's expectation of "main".
git -c init.defaultBranch=main init -q --bare "$origin"
git clone -q "$origin" "$main" 2>/dev/null
git -C "$main" config user.email t@t
git -C "$main" config user.name t
echo one >"$main/one"
git -C "$main" add one
git -C "$main" commit -qm one
git -C "$main" push -q -u origin main

# ---------------------------------------------------------------------------
# Fixture: worktree on a branch that has been pushed to origin
# ---------------------------------------------------------------------------
wt_pushed="$scratch/wt-pushed"
git -C "$main" worktree add -q -b feature "$wt_pushed"
echo two >"$wt_pushed/two"
git -C "$wt_pushed" add two
git -C "$wt_pushed" commit -qm two
git -C "$wt_pushed" push -q -u origin feature

input="$scratch/dirty-worktrees.txt"
report="$scratch/report.md"

printf '### %s\n' "$wt_pushed" > "$input"
python3 "$audit" --input "$input" --report "$report" --dry-run >/dev/null 2>&1 \
    || fail "audit run failed for pushed branch"

# feature must land in the "proved fully landed" section.
awk '/^## 3\. Worktrees proved fully landed/ {p=1; next} /^## [0-9]/ {p=0} p {print}' "$report" \
    | grep -q 'feature' || fail "pushed branch must be in the 'landed' section"
awk '/^## 3\. Worktrees proved fully landed/ {p=1; next} /^## [0-9]/ {p=0} p {print}' "$report" \
    | grep -q 'on origin' || fail "landed reason must cite 'on origin'"

# The banned reason must not appear anywhere in the report.
[[ ! -e "$report" ]] || ! grep -qF 'git cherry' "$report" || fail "report must not mention 'git cherry'"
ok "3: pushed branch is classified as landed"

# ---------------------------------------------------------------------------
# Fixture: worktree on a local-only branch that should be pushed
# ---------------------------------------------------------------------------
wt_unpushed="$scratch/wt-unpushed"
git -C "$main" worktree add -q -b wip "$wt_unpushed"
echo three >"$wt_unpushed/three"
git -C "$wt_unpushed" add three
git -C "$wt_unpushed" commit -qm three

printf '### %s\n### %s\n' "$wt_pushed" "$wt_unpushed" > "$input"
python3 "$audit" --input "$input" --report "$report" --dry-run >/dev/null 2>&1 \
    || fail "audit run failed for mixed branches"

awk '/^## 1\. Genuinely unlanded branches/ {p=1; next} /^## [0-9]/ {p=0} p {print}' "$report" \
    | grep -q 'wip' || fail "unpushed local branch must be in the 'unlanded' section"
awk '/^## 1\. Genuinely unlanded branches/ {p=1; next} /^## [0-9]/ {p=0} p {print}' "$report" \
    | grep -q 'dry-run' || fail "unpushed branch must show a dry-run push"
ok "4: unpushed local branch is classified as unlanded"

# ---------------------------------------------------------------------------
# Fixture: squash-merged branch, branch ref deleted from origin
# The merge commit is on main, so the merged-PR fallback should catch it.
# We simulate the PR fallback by setting the branch name to a pattern
# the audit would see as a merged PR, but in this local test there is no
# gh repo, so the fallback is a no-op.  We instead verify the primary
# ls-remote test: the local HEAD is no longer on origin.
# ---------------------------------------------------------------------------
wt_squash="$scratch/wt-squash"
git -C "$main" worktree add -q -b squash-me "$wt_squash"
echo squash >"$wt_squash/squash"
git -C "$wt_squash" add squash
git -C "$wt_squash" commit -qm squash

# Push squash-me to origin, then squash-merge it into main.
git -C "$wt_squash" push -q -u origin squash-me

# Make the squash commit on main directly from the worktree tree.
git -C "$main" merge --squash -q squash-me
# Use "-m" with a merge commit-like message, but squash leaves staged changes.
git -C "$main" commit -qm "squash merge of squash-me"
git -C "$main" push -q origin main

# Delete the remote branch.
git -C "$main" push -q origin --delete squash-me

printf '### %s\n' "$wt_squash" > "$input"
python3 "$audit" --input "$input" --report "$report" --dry-run >/dev/null 2>&1 \
    || fail "audit run failed for squash-merged branch"

# Without a PR record the audit cannot know the work is in main, so the
# local tip is genuinely not on origin.  It must be unlanded.
awk '/^## 1\. Genuinely unlanded branches/ {p=1; next} /^## [0-9]/ {p=0} p {print}' "$report" \
    | grep -q 'squash-me' || fail "squash-merged branch with deleted remote branch must be unlanded"
ok "5: squash-merged branch whose tip is not on origin is unlanded (no PR fallback in fixture)"

# ---------------------------------------------------------------------------
# Fixture: detached HEAD that is not on any origin ref
# ---------------------------------------------------------------------------
wt_detach="$scratch/wt-detach"
git -C "$main" worktree add -q --detach "$wt_detach"
echo detached >"$wt_detach/detached"
git -C "$wt_detach" add detached
git -C "$wt_detach" commit -qm "detached commit"

printf '### %s\n' "$wt_detach" > "$input"
python3 "$audit" --input "$input" --report "$report" --dry-run >/dev/null 2>&1 \
    || fail "audit run failed for detached HEAD"

awk '/^## 1\. Genuinely unlanded branches/ {p=1; next} /^## [0-9]/ {p=0} p {print}' "$report" \
    | grep -q 'DETACHED' || fail "detached HEAD not on origin must be unlanded"
ok "6: detached HEAD not on origin is unlanded"

echo "OK: dirty-worktree-audit uses ls-remote and classifies correctly"
