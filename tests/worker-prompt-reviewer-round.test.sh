#!/usr/bin/env bash
# tests/worker-prompt-reviewer-round.test.sh
#
# fleet-ops#3264 (child of #3127): product PRs (0509, siterep-public,
# inish-site) must get ONE reviewer round before the auto-merge arm, with
# findings landed in the review-adjudication buckets. This lock keeps the
# contract in prompts/worker.md and the product marking in
# config/intake-repos.json from silently drifting.
#
# Invariants:
#   1. prompts/worker.md step 8 names the reviewer round and the exact
#      reviewer prompt (`Use reviewer to review the diff origin/main...HEAD
#      against the issue acceptance and the repo tests`).
#   2. The reviewer round precedes the auto-merge arm (arm is step 9).
#   3. Findings land in the review-adjudication buckets (Act on / Consider /
#      Noted / Dismissed-with-reason) in the PR body.
#   4. One round only; no loops.
#   5. config/intake-repos.json marks 0509, siterep-public, inish-site as
#      product.
#   6. CI host exists (fleet-ops#82): this file is listed in ci.yml OR
#      invoked from a test that already is (currently pi-issue-start.test.sh).
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
prompt="$repo_root/prompts/worker.md"
intake="$repo_root/config/intake-repos.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$prompt" ]] || fail "missing $prompt"
[[ -f "$intake" ]] || fail "missing $intake"

# --- 1. reviewer round named with the exact reviewer prompt -----------------
grep -q 'Use reviewer to review the diff origin/main...HEAD against' "$prompt" \
  || fail "worker.md must carry the reviewer prompt (fleet-ops#3264)"
ok "worker.md carries the reviewer prompt"

# --- 2. reviewer round precedes the auto-merge arm --------------------------
# The reviewer round must be step 8 and the arm step 9, so the round runs
# before arming. A future edit that moves the arm ahead of the round goes red.
reviewer_line=$(grep -n '^8\. Reviewer round' "$prompt" | head -1 | cut -d: -f1)
arm_line=$(grep -n '^9\. Arm the merge queue' "$prompt" | head -1 | cut -d: -f1)
[[ -n "$reviewer_line" ]] || fail "worker.md must have a step 8 'Reviewer round'"
[[ -n "$arm_line" ]] || fail "worker.md must have a step 9 'Arm the merge queue'"
[[ "$reviewer_line" -lt "$arm_line" ]] \
  || fail "reviewer round (line $reviewer_line) must precede the arm (line $arm_line)"
ok "reviewer round (step 8) precedes the auto-merge arm (step 9)"

# --- 3. review-adjudication buckets in the PR body --------------------------
for bucket in 'Act on' Consider Noted 'Dismissed-with-reason'; do
  grep -q "$bucket" "$prompt" || fail "worker.md must name review-adjudication bucket '$bucket'"
done
ok "review-adjudication buckets (Act on / Consider / Noted / Dismissed-with-reason) present"

# --- 4. one round only; no loops --------------------------------------------
grep -q 'One round only; no loops' "$prompt" \
  || fail "worker.md must cap the reviewer round at one (no loops)"
ok "reviewer round is one round only; no loops"

# --- 5. product marking in intake-repos.json --------------------------------
for repo in 0509 siterep-public inish-site; do
  python3 - "$intake" "$repo" <<'PY' || fail "product marking missing for $repo"
import json, sys
data = json.load(open(sys.argv[1]))
name = sys.argv[2]
rows = (data.get("repos") or []) + (data.get("deferred") or [])
if not any(r.get("name") == name and r.get("product") is True for r in rows):
    sys.exit(1)
PY
done
ok "intake-repos.json marks 0509, siterep-public, inish-site as product"

# --- 6. CI host (fleet-ops#82) ---------------------------------------------
# Workers have no Workflows permission, so this file cannot be added to ci.yml
# verify-command by a worker. It rides an existing CI-listed test instead
# (pi-issue-start.test.sh).
ci_yml="$repo_root/.github/workflows/ci.yml"
host="$repo_root/tests/pi-issue-start.test.sh"
listed=0
hosted=0
grep -Fq 'bash tests/worker-prompt-reviewer-round.test.sh' "$ci_yml" && listed=1
grep -Fq 'bash "$here/worker-prompt-reviewer-round.test.sh"' "$host" && hosted=1
if [[ "$listed" -eq 0 && "$hosted" -eq 0 ]]; then
  fail "worker-prompt-reviewer-round.test.sh has no CI host (fleet-ops#82): list it in ci.yml or invoke it from pi-issue-start.test.sh"
fi
ok "CI host exists (ci.yml listed=$listed pi-issue-start hosted=$hosted)"

# Empty-host drill: an empty ci.yml + empty host must miss both, proving the
# check is not trivially true.
empty=$(mktemp -d)
trap 'rm -rf "$empty"' EXIT
: >"$empty/ci.yml"
: >"$empty/host.test.sh"
empty_listed=0
empty_hosted=0
grep -Fq 'bash tests/worker-prompt-reviewer-round.test.sh' "$empty/ci.yml" && empty_listed=1
grep -Fq 'bash "$here/worker-prompt-reviewer-round.test.sh"' "$empty/host.test.sh" && empty_hosted=1
[[ "$empty_listed" -eq 0 && "$empty_hosted" -eq 0 ]] \
  || fail "empty-host drill must miss both hosts (listed=$empty_listed hosted=$empty_hosted)"
ok "empty-host drill trips (neither host matches empty files)"

echo "worker-prompt-reviewer-round: PASS"
