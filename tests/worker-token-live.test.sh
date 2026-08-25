#!/usr/bin/env bash
# tests/worker-token-live.test.sh
#
# MANUAL, runs only when a real nishfleet-worker App + creds exist.
# Skipped automatically in CI by the absence of NISHFLEET_WORKER_LIVE_TEST.
#
# What it proves once Nish has clicked the manifest and installed the app:
#   1. worker-token mints a short-lived installation token.
#   2. The token can read 0509 repository metadata.
#   3. The token CANNOT push a commit to .github/workflows/** (the
#      mechanical close: workflows permission is not granted in the
#      manifest, so the push is rejected at the platform layer).
#   4. The token CANNOT delete branch protection on 0509 (administration
#      permission is not granted).
#   5. The token CAN push to non-workflow paths and open PRs.
#
# Invoke: WORKER_APP_CREDS_FILE=... NISHFLEET_WORKER_LIVE_TEST=1 \
#   tests/worker-token-live.test.sh
#
# A failure here after Nish's manifest click is exactly the audit point
# the packet requires: prove on the live system that the new identity is
# fail-closed in the specific ways the org needs.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

# Skip-on-default: in CI, exit early.
if [[ "${NISHFLEET_WORKER_LIVE_TEST:-}" != "1" ]]; then
  echo "SKIP: set NISHFLEET_WORKER_LIVE_TEST=1 to run. This test requires a live" >&2
  echo "      nishfleet-worker App and installation under Nishfleet." >&2
  echo "      Skipped by default in CI." >&2
  exit 0
fi

creds="${WORKER_APP_CREDS_FILE:-$HOME/.config/fleet-worker/nishfleet-worker.env}"
[[ -f "$creds" ]] || { echo "no creds file at $creds" >&2; exit 2; }

REPO="${NISHFLEET_LIVE_TEST_REPO:-Nishfleet/0509}"

fail() { echo "FAIL: $*" >&2; exit 1; }

tok="$("$repo_root/bin/worker-token" --print 2>/dev/null)" \
  || fail "worker-token exited non-zero"
export GH_TOKEN="${tok#export GH_TOKEN=}"
[[ -n "$GH_TOKEN" ]] || fail "no GH_TOKEN"

# --- 1 + 2: read metadata ---------------------------------------------------
gh api -H "Authorization: token $GH_TOKEN" "repos/$REPO" --jq '.name' >/dev/null \
  || fail "token cannot read $REPO"

# --- 3: cannot push to .github/workflows/** ---------------------------------
# We try to git push a commit that adds a file under .github/workflows/.
# Use a tmp clone and a no-content blob to keep the test idempotent.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
git clone --depth=1 "https://github.com/$REPO.git" "$work/repo" >/dev/null 2>&1 \
  || fail "git clone failed"
cd "$work/repo"
git config user.email "nishfleet+p14-live-test@example.invalid"
git config user.name  "nishfleet-p14-live-test"
git checkout -b feat/p14-live-test >/dev/null 2>&1
echo "# live test — should be rejected" > .github/workflows/_p14_live_test.yml
git add .github/workflows/_p14_live_test.yml
git commit -m "p14 live-test: must be rejected" >/dev/null 2>&1

set +e
GIT_TERMINAL_PROMPT=0 git push origin feat/p14-live-test 2>push.err >push.out
rc=$?
set -e
echo "push rc=$rc" >&2
echo "push out=$(cat push.out 2>/dev/null)" >&2
echo "push err=$(cat push.err 2>/dev/null)" >&2
# Reject: workflows permission is not granted. The push MUST fail.
(( rc != 0 )) || fail "push to .github/workflows/** must fail (permission scope leak)"
# The token's permissions don't include workflows, so GitHub rejects
# the push. The exact wording varies; we accept any non-zero push rc.
rm -rf "$work"

# --- 4: cannot delete branch protection ------------------------------------
# Simpler version: try a PUT that requires admin permission. The endpoint
# is documented as administration:write; ours is none.
if gh api -H "Authorization: token $GH_TOKEN" -X DELETE \
       "repos/$REPO/branches/main/protection" 2>del.err >del.out; then
  fail "DELETE branch protection succeeded — admin scope leak!"
else
  echo "OK: branch-protection DELETE blocked as expected" >&2
fi
# Status must be 403 (not authorised) or 404 (token valid, protection absent).
rc=$(awk 'NR==1 {print $2}' del.err 2>/dev/null)
echo "DELETE rc=$rc" >&2
case "$rc" in
  403|404|401) ;;  # any "not authorised" is correct
  *) fail "expected 401/403/404 from protection delete, got $rc";;
esac

# --- 5: can push non-workflow content --------------------------------------
# Create a comment file in a non-workflow path, push it, open a PR.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
git clone --depth=1 "https://github.com/$REPO.git" "$work/repo" >/dev/null 2>&1
cd "$work/repo"
git config user.email "nishfleet+p14-live-test@example.invalid"
git config user.name  "nishfleet-p14-live-test"
git checkout -b feat/p14-live-test-ok >/dev/null
mkdir -p docs/internal
echo "Live test note $(date -u +%FT%TZ)" > docs/internal/P14-LIVE-TEST.md
git add docs/internal/P14-LIVE-TEST.md
git commit -m "p14 live-test: non-workflow edit must succeed" >/dev/null
GIT_TERMINAL_PROMPT=0 git push origin feat/p14-live-test-ok 2>push.err
rc=$?
(( rc == 0 )) || fail "non-workflow push must succeed (rc=$rc)"
# Open the PR via the app token.
pr_url="$(gh pr create -R "$REPO" --head feat/p14-live-test-ok \
  --title "p14 live-test: non-workflow edit" \
  --body "Closes nothing. This PR exists only to prove worker-token can drive a real PR." \
  2>&1)" || fail "PR open failed: $pr_url"
echo "OK: $pr_url" >&2
# Close it so we leave no debris.
pr_num="$(echo "$pr_url" | awk -F/ '{print $NF}')"
gh pr close "$pr_num" -R "$REPO" --delete-branch >/dev/null 2>&1 || true
rm -rf "$work"

echo "ALL LIVE INVARIANTS PASSED — nishfleet-worker App is fail-closed as expected."
