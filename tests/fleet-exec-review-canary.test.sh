#!/usr/bin/env bash
# tests/fleet-exec-review-canary.test.sh
#
# fleet-ops#537: journal/proof receipt check for Execution IS the review.
# Offline. Live gh is stubbed. Proves:
#   1. --body with Verification: + journalctl -> exit 0.
#   2. --body with run-proof: line -> exit 0.
#   3. --body with Verification: but no run-cue -> exit 1.
#   4. --body with no Verification: -> exit 1 (the skip).
#   4d. --body with the same-repo 'Closes fleet-ops#N' short form -> exit 1
#       (fleet-ops#3960: such a body cannot auto-close its issue on merge,
#       so the pre-create body gate rejects it before arm).
#   5. Scan: worker PR with receipt -> exit 0, EXEC-REVIEW-OK, no file.
#   6. Scan: worker PR without receipt -> exit 0 (observe-to-open), files.
#   7. Scan: human PR without receipt -> exit 0, no file.
#   8. Scan: worker PR outside the window -> quiet.
#   9. Auto-file dedupes the signal key on a second run.
#  10. Broken watch (missing helper / bad fixture) fails loud.
#  11. Contracts: worker.md, heartbeat wiring, MANIFEST, nested CI host,
#      matrix enforced, no bin/exec-review dispatcher.
#  12. Observe-to-close: a green tick comments resolved-at on a previously
#      filed slug that now has a receipt; a later tick with that marker
#      closes; a still-dirty slug is neither commented nor closed
#      (fleet-ops#729).
#  13. Grammar extension (fleet-ops#3731): the fleet's real merged-PR
#      evidence formats — `## Test plan` / `#### Test plan` checked
#      command boxes, `## Verification` bullets with backticked commands
#      and no magic keyword, `## run-proof` heading — classify as
#      receipts; unchecked boxes and prose do not.
#  14. Hard gate (fleet-ops#3731): a no-receipt worker PR that is ARMED
#      for auto-merge gets `gh pr merge --disable-auto` — the merge is
#      mechanically blocked, not just filed. Unarmed findings file as
#      before; a receipt-carrying armed PR is never disarmed;
#      FLEET_EXEC_REVIEW_DISARM=0 restores observe-only.
#  15. tier1 contract: the queue-pass arm gate calls the SHARED
#      classifier (fleet-exec-review-canary --body via
#      FLEET_VERIFY_CUE_GATE) instead of a private grep grammar.
#  16. Any-author hard gate (fleet-ops#4117): an armed HUMAN PR without
#      a receipt is disarmed (the merge block) but NOT filed; an armed
#      human PR WITH a receipt is never disarmed. The 2026-09-07 24h
#      sample flagged 0509#1848 and fleet-ops#4094 — both human-armed
#      merges with no VERIFY grammar.
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-exec-review-canary"
lib="$repo_root/lib/exec-review-receipt.py"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
worker="$repo_root/prompts/worker.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$lib" ]] || fail "missing $lib"
[[ -f "$tier1" ]] || fail "missing $tier1"
[[ -f "$worker" ]] || fail "missing $worker"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t exec-review-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
triage="$scratch/triage.md"
: >"$triage"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export FLEET_EXEC_REVIEW_LIB="$lib"
export FLEET_EXEC_REVIEW_ISSUE_REPO="Nishfleet/fleet-ops"
export FLEET_EXEC_REVIEW_WINDOW_HOURS=24
export FLEET_EXEC_REVIEW_NOW="2026-08-27T00:00:00Z"

gh_store="$scratch/gh-issues"
mkdir -p "$gh_store"
cat >"$scratch/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
store="${GH_MOCK_STORE:?}"
cmd="$1"; shift
case "$cmd" in
  issue)
    sub="$1"; shift
    case "$sub" in
      create)
        title=""; body=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --title) title="$2"; shift 2 ;;
            --body) body="$2"; shift 2 ;;
            --repo|-R) shift 2 ;;
            *) shift ;;
          esac
        done
        n=$(find "$store" -maxdepth 1 -name 'issue-*.body' | wc -l)
        f="$store/issue-$((n+1)).body"
        printf '%s\n' "$title" > "$f"
        printf '%s\n' "$body" >> "$f"
        echo "https://github.com/Nishfleet/fleet-ops/issues/9999"
        ;;
      comment)
        num=""; body=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --body) body="$2"; shift 2 ;;
            --repo|-R) shift 2 ;;
            *)
              if [ -z "$num" ]; then num="$1"; fi
              shift
              ;;
          esac
        done
        printf '%s\n' "$body" >"$store/issue-${num}.comments"
        printf '%s\n' "$num" >>"$store/commented"
        echo "https://github.com/Nishfleet/fleet-ops/issues/${num}#issuecomment-1"
        ;;
      list)
        printf '[\n'
        first=1
        for f in "$store"/issue-*.body; do
          [ -f "$f" ] || continue
          num=$(basename "$f" .body)
          num=${num#issue-}
          [ -f "$store/issue-${num}.closed" ] && continue
          body=$(tail -n +2 "$f")
          comments_file="$store/issue-${num}.comments"
          if [ -f "$comments_file" ]; then
            comments_json=$(python3 -c 'import json,sys;print(json.dumps([{"body": sys.stdin.read()}]))' <"$comments_file")
          else
            comments_json='[]'
          fi
          if [ "$first" = 1 ]; then first=0; else printf ',\n'; fi
          printf '{"number":%s,"title":"","body":%s,"comments":%s}' "$num" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$body")" "$comments_json"
        done
        printf '\n]\n'
        ;;
      close)
        num=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --reason|--comment|--repo|-R) shift 2 ;;
            *)
              if [ -z "$num" ]; then num="$1"; fi
              shift
              ;;
          esac
        done
        [ -n "$num" ] || exit 1
        : > "$store/issue-${num}.closed"
        printf '%s\n' "$num" >>"$store/closed"
        echo "Closed issue #$num"
        ;;
      *) exit 1 ;;
    esac
    ;;
  pr)
    sub="$1"; shift
    case "$sub" in
      merge)
        # fleet-ops#3731: record `gh pr merge <N> -R <repo> --disable-auto`
        num=""; repo=""; disable=0
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --disable-auto) disable=1; shift ;;
            --repo|-R) repo="$2"; shift 2 ;;
            --auto|--squash|--merge|--rebase) shift ;;
            -* ) shift ;;
            *)
              if [ -z "$num" ]; then num="$1"; fi
              shift
              ;;
          esac
        done
        [ "$disable" = "1" ] || exit 1
        [ -n "$num" ] || exit 1
        printf '%s\n' "${repo}#${num}" >>"$store/disarmed"
        echo "Auto-merge disabled for ${repo}#${num}"
        ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$scratch/gh"
export GH="$scratch/gh"
export GH_MOCK_STORE="$gh_store"

run_body() {
  local rc
  set +e
  FLEET_EXEC_REVIEW_LIB="$lib" "$bin" --body "$1" >"$scratch/body.out" 2>"$scratch/body.err"
  rc=$?
  set -e
  return "$rc"
}

# --- 1. --body with Verification: + journalctl ------------------------------
printf '%s\n' '## Summary
changed

## Verification:
- journalctl -u fleet-heartbeat.service --since "5 min ago"
' >"$scratch/body.md"
run_body "$scratch/body.md" || fail "1: Verification + journalctl must accept ($(cat "$scratch/body.err"))"
grep -q '^OK:' "$scratch/body.out" || fail "1: expected OK line"
ok "1: --body Verification + journalctl accepted"

# --- 2. --body with run-proof: ---------------------------------------------
printf '%s\n' '## Summary
changed
run-proof: journal fleet-heartbeat.service lines below
' >"$scratch/body.md"
run_body "$scratch/body.md" || fail "2: run-proof: must accept"
ok "2: --body run-proof: accepted"

# --- 2b. --body with `## Verification` heading (no colon) + fenced run-cue (fleet-ops#728) ---
printf '%s\n' '## What changed
- changed

## Verification
```
npx vitest run --project node tests/foo.test.ts
Test Files 2 passed (2), Tests 13 passed (13).
```

Closes #1198
' >"$scratch/body.md"
run_body "$scratch/body.md" || fail "2b: heading form (no colon) must accept ($(cat "$scratch/body.err"))"
ok "2b: --body heading form (no colon) + fenced run-cue accepted"

# --- 2c. --body with `## Verification` heading (no colon) but no run-cue -----
printf '%s\n' '## Summary
changed

## Verification
- I did the thing.
' >"$scratch/body.md"
if run_body "$scratch/body.md"; then
  fail "2c: heading form (no colon) without a run-cue must reject"
fi
ok "2c: --body heading form (no colon) without run-cue rejected"

# --- 3. --body Verification: without a run-cue ------------------------------
printf '%s\n' '## Summary
changed

## Verification:
- I did the thing.
' >"$scratch/body.md"
if run_body "$scratch/body.md"; then
  fail "3: Verification without a run-cue must reject"
fi
ok "3: --body Verification without run-cue rejected"

# --- 4. --body with no receipt (the skip) ----------------------------------
printf '%s\n' '## Summary
- changed some files

Closes #537
' >"$scratch/body.md"
if run_body "$scratch/body.md"; then
  fail "4: missing receipt must reject — gate is broken"
fi
grep -q 'REJECT:' "$scratch/body.err" || fail "4: REJECT missing from stderr"
ok "4: --body with no receipt rejected (the skip drill)"

# --- 4a. --body with `## Verification` (no colon) + fenced block accepted ----
# Locks the canary's lenient colon handling (fleet-ops#728): a markdown
# heading WITHOUT the trailing colon is accepted as a section marker when
# the body has a fenced block. Workers commonly write `## Verification`
# without the colon; rejecting that shape produced false positives for
# legitimately run-cued PRs (#728). The prior strict-colon test (#731)
# was rendered obsolete by the canary regex change in PR #834.
printf '%s\n' 'Heartbeat canary.

## Verification
- exit 0

```
[2026-08-26T22:49:01Z] [canary] LOUD rc=0
```
' >"$scratch/body.md"
run_body "$scratch/body.md" \
  || fail "4a: \`## Verification\` (no colon) + fenced block must accept ($(cat "$scratch/body.err"))"
ok "4a: --body with \`## Verification\` (no colon) + fenced block accepted (the #728 shape)"

# --- 4b. --body with `## Verification:` (colon) + fenced block accepted ----
# PR #630's post-fix shape (fleet-ops#731): colon + fenced block + exit N
# is the loudest receipt. Locks the remediation so the canary cannot
# silently drop the colon form in a future regex edit.
printf '%s\n' 'Heartbeat canary.

## Verification:
- exit 0

```
[2026-08-26T22:49:01Z] [canary] LOUD rc=0
```
' >"$scratch/body.md"
run_body "$scratch/body.md" || fail "4b: `## Verification:` + fenced block must accept ($(cat "$scratch/body.err"))"
ok "4b: --body with `## Verification:` + fenced block accepted (the #630 post-fix shape)"

# --- 4c. --body with run-proof: + `## Verification` (no colon) accepted ----
# The run-proof: line is a louder, regex-orthogonal signal. Even when the
# heading lacks a colon, a run-proof: line carries the receipt.
printf '%s\n' 'Heartbeat canary.

run-proof: journal fleet-prepaid-util-canary exit 0

## Verification
- exit 0
' >"$scratch/body.md"
run_body "$scratch/body.md" || fail "4c: run-proof: must accept even without colon heading"
ok "4c: --body with run-proof: (no colon heading) accepted (the louder signal)"

# --- 4d. --body with `Closes <repo>#N` short form REJECTED (fleet-ops#3960) ---
# Same-repo PR body using the cross-repo short form (`Closes fleet-ops#3873`)
# does NOT auto-close the issue on merge (the bug that left fleet-ops#3873
# open after PR #3952 merged). The pre-create `--body` gate must reject it
# even when the receipt is present, so a body that cannot close its issue
# never reaches arm. This test runs from the repo root so the origin remote
# resolves the base repo to Nishfleet/fleet-ops.
printf '%s\n' '## Summary
changed

## Verification:
- journalctl -u fleet-heartbeat.service --since "5 min ago"

Closes fleet-ops#3873
' >"$scratch/body.md"
if run_body "$scratch/body.md"; then
  fail "4d: Closes fleet-ops#3873 must be REJECTED by --body gate, but it passed"
fi
grep -q 'REJECT' "$scratch/body.err" \
  || fail "4d: expected a REJECT line in stderr: $(cat "$scratch/body.err")"
grep -q 'does not auto-close' "$scratch/body.err" \
  || fail "4d: REJECT must cite the auto-close gap: $(cat "$scratch/body.err")"
ok "4d: --body REJECTs the same-repo 'Closes fleet-ops#N' short form (fleet-ops#3960)"

run_scan() {
  local fixture="$1"
  set +e
  FLEET_EXEC_REVIEW_LIB="$lib" \
  FLEET_EXEC_REVIEW_PR_LIST="$fixture" \
  FLEET_EXEC_REVIEW_FILE="${FLEET_EXEC_REVIEW_FILE:-1}" \
  FLEET_EXEC_REVIEW_NOW="2026-08-27T00:00:00Z" \
  FLEET_EXEC_REVIEW_WINDOW_HOURS=24 \
  GH="$scratch/gh" \
  GH_MOCK_STORE="$gh_store" \
  FLEET_HEARTBEAT_TRIAGE="$triage" \
    "$bin" >"$scratch/scan.out" 2>"$scratch/scan.err"
  rc=$?
  set -e
  return "$rc"
}

# --- 5. worker PR with receipt -> OK, no file -------------------------------
cat >"$scratch/prs-ok.json" <<'JSON'
[
  {
    "repo": "Nishfleet/fleet-ops",
    "number": 700,
    "title": "feat: with receipt",
    "body": "## Summary\nchanged\n\n## Verification:\n- exit 0\n",
    "createdAt": "2026-08-26T23:00:00Z",
    "url": "https://github.com/Nishfleet/fleet-ops/pull/700",
    "headRefName": "claim/issue-700",
    "author": {"login": "app/nishfleet-worker", "is_bot": true}
  }
]
JSON
rm -f "$gh_store"/*.body
: >"$triage"
FLEET_EXEC_REVIEW_FILE=1 run_scan "$scratch/prs-ok.json" || fail "5: receipt PR must exit 0 ($(cat "$scratch/scan.err"))"
grep -q 'EXEC-REVIEW-OK' "$scratch/scan.err" || fail "5: expected EXEC-REVIEW-OK ($(cat "$scratch/scan.err"))"
[[ -z "$(ls -A "$gh_store" 2>/dev/null | grep issue || true)" ]] || fail "5: must not file on a receipt PR"
ok "5: worker PR with receipt is OK, no file"

# --- 5b. worker PR with `## Verification` heading (no colon) + fenced run-cue is OK (fleet-ops#728) ---
cat >"$scratch/prs-ok-heading.json" <<'JSON'
[
  {
    "repo": "Nishfleet/0509",
    "number": 1233,
    "title": "fix(docs): heading-form Verification is also a receipt",
    "body": "## What changed\nremoved stale comment\n\n## Verification\n```\nnpx vitest run --project node tests/foo.test.ts\nTest Files 2 passed (2), Tests 13 passed (13).\n```\n\nCloses #1198\n",
    "createdAt": "2026-08-26T23:00:00Z",
    "url": "https://github.com/Nishfleet/0509/pull/1233",
    "headRefName": "claim/issue-1198",
    "author": {"login": "app/nishfleet-worker", "is_bot": true}
  }
]
JSON
rm -f "$gh_store"/*.body
: >"$triage"
FLEET_EXEC_REVIEW_FILE=1 run_scan "$scratch/prs-ok-heading.json" || fail "5b: heading-form receipt PR must exit 0 ($(cat "$scratch/scan.err"))"
grep -q 'EXEC-REVIEW-OK' "$scratch/scan.err" || fail "5b: expected EXEC-REVIEW-OK ($(cat "$scratch/scan.err"))"
[[ -z "$(ls -A "$gh_store" 2>/dev/null | grep issue || true)" ]] || fail "5b: must not file on a heading-form receipt PR"
ok "5b: worker PR with `## Verification` heading (no colon) + fenced run-cue is OK, no file"

# --- 6. worker PR without receipt -> observe-to-open, files -----------------
cat >"$scratch/prs-skip.json" <<'JSON'
[
  {
    "repo": "Nishfleet/fleet-ops",
    "number": 701,
    "title": "feat: skipped the run",
    "body": "## Summary\nchanged\n\nCloses #701\n",
    "createdAt": "2026-08-26T23:00:00Z",
    "url": "https://github.com/Nishfleet/fleet-ops/pull/701",
    "headRefName": "claim/issue-701",
    "author": {"login": "app/nishfleet-worker", "is_bot": true}
  }
]
JSON
rm -f "$gh_store"/*.body
: >"$triage"
FLEET_EXEC_REVIEW_FILE=1 run_scan "$scratch/prs-skip.json" || fail "6: skip PR must stay exit 0 (observe-to-open) ($(cat "$scratch/scan.err"))"
grep -q 'EXEC-REVIEW-SKIP' "$scratch/scan.err" || fail "6: expected EXEC-REVIEW-SKIP"
grep -q 'FILED' "$scratch/scan.err" || fail "6: expected auto-file FILED ($(cat "$scratch/scan.err"))"
grep -rq "signal: exec-review-receipt/Nishfleet/fleet-ops#701" "$gh_store" \
  || fail "6: filed issue missing signal key"
ok "6: worker PR without receipt files (observe-to-open)"

# --- 7. human PR without receipt -> no file ---------------------------------
cat >"$scratch/prs-human.json" <<'JSON'
[
  {
    "repo": "Nishfleet/fleet-ops",
    "number": 702,
    "title": "docs: human",
    "body": "no receipt here",
    "createdAt": "2026-08-26T23:00:00Z",
    "url": "https://github.com/Nishfleet/fleet-ops/pull/702",
    "headRefName": "docs/human",
    "author": {"login": "nish3451", "is_bot": false}
  }
]
JSON
rm -f "$gh_store"/*.body
: >"$triage"
FLEET_EXEC_REVIEW_FILE=1 run_scan "$scratch/prs-human.json" || fail "7: human PR must exit 0"
grep -q 'EXEC-REVIEW-OK' "$scratch/scan.err" || fail "7: human PR should be OK (not a worker skip)"
[[ -z "$(ls -A "$gh_store" 2>/dev/null | grep issue || true)" ]] || fail "7: must not file on a human PR"
ok "7: human PR without receipt is ignored"

# --- 8. worker PR outside the window -> quiet -------------------------------
cat >"$scratch/prs-old.json" <<'JSON'
[
  {
    "repo": "Nishfleet/fleet-ops",
    "number": 703,
    "title": "old skip",
    "body": "no receipt",
    "createdAt": "2026-08-20T00:00:00Z",
    "url": "https://github.com/Nishfleet/fleet-ops/pull/703",
    "headRefName": "claim/issue-703",
    "author": {"login": "app/nishfleet-worker", "is_bot": true}
  }
]
JSON
rm -f "$gh_store"/*.body
: >"$triage"
FLEET_EXEC_REVIEW_FILE=1 run_scan "$scratch/prs-old.json" || fail "8: old PR must exit 0"
grep -q 'EXEC-REVIEW-OK' "$scratch/scan.err" || fail "8: old skip should age out"
[[ -z "$(ls -A "$gh_store" 2>/dev/null | grep issue || true)" ]] || fail "8: must not file on an aged-out PR"
ok "8: worker PR outside the window is quiet"

# --- 9. dedup ---------------------------------------------------------------
rm -f "$gh_store"/*.body
: >"$triage"
FLEET_EXEC_REVIEW_FILE=1 run_scan "$scratch/prs-skip.json" || fail "9a: first skip run must exit 0"
grep -q 'FILED' "$scratch/scan.err" || fail "9a: first skip run must file ($(cat "$scratch/scan.err"))"
: >"$triage"
FLEET_EXEC_REVIEW_FILE=1 run_scan "$scratch/prs-skip.json" || fail "9b: second skip run must exit 0"
grep -q 'deduped' "$scratch/scan.err" || fail "9b: second run did not dedupe ($(cat "$scratch/scan.err"))"
grep -rl "signal: exec-review-receipt/" "$gh_store" | wc -l | grep -q "^1$" \
  || fail "9: signal key filed more than once"
ok "9: auto-file dedupes the signal key"

# --- 9a. PR #630 pre-fix shape: `## Verification` (no colon) + run-cue -> OK ----
# Regression lock (fleet-ops#728 supersedes #731). The canary's lenient
# colon handling (PR #834) accepts `## Verification` without a colon as
# long as the body has a run-cue (fenced block, exit N, etc.). PR #630's
# pre-fix shape is now correctly classified as a RECEIPT, not a skip.
# The legacy strict-colon test was rendered obsolete by the canary
# regex change; this lock proves the post-#728 classification holds.
cat >"$scratch/prs-630-pre.json" <<'JSON'
[
  {
    "repo": "Nishfleet/fleet-ops",
    "number": 630,
    "title": "feat(enforcement): prepaid utilization canary for sr-prepaid-max-util",
    "body": "Heartbeat canary.\n\n## Verification\n- exit 0\n\n```\n[2026-08-26T22:49:01Z] [canary] LOUD rc=0\n```\n",
    "createdAt": "2026-08-26T23:00:00Z",
    "url": "https://github.com/Nishfleet/fleet-ops/pull/630",
    "headRefName": "claim/issue-531",
    "author": {"login": "app/nishfleet-worker", "is_bot": true}
  }
]
JSON
rm -f "$gh_store"/*.body
: >"$triage"
FLEET_EXEC_REVIEW_FILE=1 run_scan "$scratch/prs-630-pre.json" \
  || fail "9a1: pre-fix scan must exit 0"
grep -q 'EXEC-REVIEW-OK' "$scratch/scan.err" \
  || fail "9a1: pre-fix PR #630 must be OK-flagged (no colon, but run-cue present) ($(cat "$scratch/scan.err"))"
ok "9a1: PR #630 pre-fix shape (\`## Verification\`, no colon) is OK-classified (the #728 lenient-colon shape)"

# --- 9a. PR #630 post-fix shape: `## Verification:` + run-proof: -> OK ------
# Regression lock (fleet-ops#731). Once the worker adds the colon and a
# run-proof: line, the canary must classify the same PR as a receipt.
cat >"$scratch/prs-630-post.json" <<'JSON'
[
  {
    "repo": "Nishfleet/fleet-ops",
    "number": 630,
    "title": "feat(enforcement): prepaid utilization canary for sr-prepaid-max-util",
    "body": "Heartbeat canary.\n\nrun-proof: journal fleet-prepaid-util-canary exit 0\n\n## Verification:\n- exit 0\n\n```\n[2026-08-26T22:49:01Z] [canary] LOUD rc=0\n```\n",
    "createdAt": "2026-08-26T23:00:00Z",
    "url": "https://github.com/Nishfleet/fleet-ops/pull/630",
    "headRefName": "claim/issue-531",
    "author": {"login": "app/nishfleet-worker", "is_bot": true}
  }
]
JSON
rm -f "$gh_store"/*.body
: >"$triage"
FLEET_EXEC_REVIEW_FILE=1 run_scan "$scratch/prs-630-post.json" \
  || fail "9a2: post-fix scan must exit 0"
grep -q 'EXEC-REVIEW-OK' "$scratch/scan.err" \
  || fail "9a2: post-fix PR #630 must be receipt-OK ($(cat "$scratch/scan.err"))"
[[ -z "$(ls -A "$gh_store" 2>/dev/null | grep issue || true)" ]] \
  || fail "9a2: must not file on post-fix PR #630"
ok "9a2: PR #630 post-fix shape (`## Verification:` + run-proof:) is receipt-OK"

# --- 10. broken watch fails loud -------------------------------------------
set +e
FLEET_EXEC_REVIEW_LIB="$scratch/no-such.py" \
FLEET_EXEC_REVIEW_PR_LIST="$scratch/prs-ok.json" \
FLEET_EXEC_REVIEW_FILE=0 \
FLEET_HEARTBEAT_TRIAGE="$triage" \
  "$bin" >/dev/null 2>"$scratch/broken.err"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "10a: missing helper should exit 1 (got $rc)"
grep -q "EXEC-REVIEW-BROKEN" "$scratch/broken.err" || fail "10a: missing helper must be LOUD"
ok "10a: missing helper fails loud"

printf 'not-json\n' >"$scratch/bad.json"
set +e
FLEET_EXEC_REVIEW_LIB="$lib" \
FLEET_EXEC_REVIEW_PR_LIST="$scratch/bad.json" \
FLEET_EXEC_REVIEW_FILE=0 \
FLEET_HEARTBEAT_TRIAGE="$triage" \
  "$bin" >/dev/null 2>"$scratch/bad.err"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "10b: bad fixture should exit 1 (got $rc)"
grep -q "EXEC-REVIEW-BROKEN" "$scratch/bad.err" || fail "10b: bad fixture must be LOUD"
ok "10b: unparseable fixture fails loud"

# --- 11. contracts ----------------------------------------------------------
grep -F -- 'fleet-exec-review-canary' "$worker" >/dev/null \
  || fail "worker.md must tell authors to run bin/fleet-exec-review-canary"
grep -q 'fleet-exec-review-canary' "$tier1" \
  || fail "fleet-heartbeat-tier1 must invoke fleet-exec-review-canary"
grep -q 'exec_review_canary_rc' "$tier1" \
  || fail "fleet-heartbeat-tier1 must propagate exec_review_canary_rc"
grep -F -- 'exit "$exec_review_canary_rc"' "$tier1" >/dev/null \
  || fail "tier1 must exit non-zero when the exec-review watch is broken"
grep -q 'bin/fleet-exec-review-canary' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/fleet-exec-review-canary"
grep -q 'lib/exec-review-receipt.py' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install lib/exec-review-receipt.py"
grep -Fq 'bash "$here/fleet-exec-review-canary.test.sh"' "$here/rule-enforcement.test.sh" \
  || fail "rule-enforcement.test.sh must nest this file (CI cannot gain a new workflow line)"
jq -e '.rules[] | select(.id == "sr-execution-is-review" and .status == "enforced")' \
  "$repo_root/config/rule-enforcement.json" >/dev/null \
  || fail "sr-execution-is-review must be status=enforced in the matrix"
[[ ! -e "$repo_root/bin/exec-review" ]] \
  || fail "bin/exec-review must not exist (inner loop stays agentic)"
grep -q 'observe-to-close' "$bin" \
  || fail "fleet-exec-review-canary must observe-to-close auto-filed receipts (fleet-ops#729)"
ok "11: contracts: worker.md, heartbeat, MANIFEST, nested CI, matrix enforced, no dispatcher"

# --- 12. observe-to-close (fleet-ops#729) -----------------------------------
rm -f "$gh_store"/issue-* "$gh_store"/commented "$gh_store"/closed
: >"$gh_store/commented"
: >"$gh_store/closed"
: >"$triage"
printf '%s\n' "fix(exec-review): Nishfleet/fleet-ops#668" >"$gh_store/issue-729.body"
printf '%s\n' "Do not close until the detector reports this clean.

signal: exec-review-receipt/Nishfleet/fleet-ops#668" >>"$gh_store/issue-729.body"

# Green tick: PR 668 now has a receipt. Comment resolved-at; do not close yet.
cat >"$scratch/prs-668-receipt.json" <<'JSON'
[
  {
    "repo": "Nishfleet/fleet-ops",
    "number": 668,
    "title": "feat: token efficiency",
    "body": "## Summary\nchanged\n\n## Verification:\n- exit 0\n",
    "createdAt": "2026-08-26T23:00:00Z",
    "url": "https://github.com/Nishfleet/fleet-ops/pull/668",
    "headRefName": "claim/issue-523",
    "author": {"login": "app/nishfleet-worker", "is_bot": true}
  }
]
JSON
FLEET_EXEC_REVIEW_FILE=1 FLEET_EXEC_REVIEW_CLOSE=1 \
  run_scan "$scratch/prs-668-receipt.json" \
  || fail "12a: receipt PR must exit 0 ($(cat "$scratch/scan.err"))"
grep -q "OBSERVED-RESOLVED" "$scratch/scan.err" \
  || fail "12a: green tick must log OBSERVED-RESOLVED ($(cat "$scratch/scan.err"))"
grep -q '^729$' "$gh_store/commented" \
  || fail "12a: green tick must comment on #729 (commented=$(cat "$gh_store/commented"))"
grep -q "resolved-at: signal: exec-review-receipt/Nishfleet/fleet-ops#668" \
  "$gh_store/issue-729.comments" \
  || fail "12a: comment missing resolved-at marker"
if [ -s "$gh_store/closed" ]; then
  fail "12a: same-tick must not close (closed=$(cat "$gh_store/closed"))"
fi
ok "12a: observe-to-close: green tick comments resolved-at, does not close same tick"

# Later tick: marker already present, slug still absent from findings -> close
: >"$gh_store/commented"
: >"$gh_store/closed"
: >"$triage"
FLEET_EXEC_REVIEW_FILE=1 FLEET_EXEC_REVIEW_CLOSE=1 \
  run_scan "$scratch/prs-668-receipt.json" \
  || fail "12b: close tick must exit 0 ($(cat "$scratch/scan.err"))"
grep -q "OBSERVE-CLOSED" "$scratch/scan.err" \
  || fail "12b: later tick must log OBSERVE-CLOSED ($(cat "$scratch/scan.err"))"
grep -q '^729$' "$gh_store/closed" \
  || fail "12b: later tick must close #729 (closed=$(cat "$gh_store/closed"))"
if [ -s "$gh_store/commented" ]; then
  fail "12b: later tick must not comment again (commented=$(cat "$gh_store/commented"))"
fi
ok "12b: observe-to-close: later tick with resolved-at marker closes"

# Still-dirty: PR 668 still has no receipt, even with a resolved-at marker
: >"$gh_store/commented"
: >"$gh_store/closed"
rm -f "$gh_store/issue-729.closed"
: >"$triage"
cat >"$scratch/prs-668-skip.json" <<'JSON'
[
  {
    "repo": "Nishfleet/fleet-ops",
    "number": 668,
    "title": "feat: token efficiency",
    "body": "## Summary\nchanged\n\nCloses #523\n",
    "createdAt": "2026-08-26T23:00:00Z",
    "url": "https://github.com/Nishfleet/fleet-ops/pull/668",
    "headRefName": "claim/issue-523",
    "author": {"login": "app/nishfleet-worker", "is_bot": true}
  }
]
JSON
FLEET_EXEC_REVIEW_FILE=1 FLEET_EXEC_REVIEW_CLOSE=1 \
  run_scan "$scratch/prs-668-skip.json" \
  || fail "12c: still-dirty must stay exit 0 (observe-to-open) ($(cat "$scratch/scan.err"))"
if [ -s "$gh_store/closed" ]; then
  fail "12c: still-dirty slug must not close (closed=$(cat "$gh_store/closed"))"
fi
if [ -s "$gh_store/commented" ]; then
  fail "12c: still-dirty slug must not comment resolved-at (commented=$(cat "$gh_store/commented"))"
fi
grep -q "still a finding" "$scratch/scan.err" \
  || fail "12c: expected still-a-finding skip ($(cat "$scratch/scan.err"))"
ok "12c: observe-to-close: still-dirty slug is neither commented nor closed"

# --- 13. grammar extension (fleet-ops#3731) --------------------------------
# The 2026-09-05/06 24h merged sample (60 PRs): the old grammar flagged 9
# as no-receipt; all 9 carried real run evidence in formats the grammar
# did not know. Each shape below is a real merged PR body.

# 13a. `## Test plan` + checked backticked command boxes (fleet-ops#3734)
printf '%s\n' '## Summary

- changed

#### Test plan

- [x] `bash tests/seatlib-aimd.test.sh` — exit 0
- [x] `bash tests/fleet-token-economy.test.sh` — exit 0
- [ ] CI green
' >"$scratch/body.md"
run_body "$scratch/body.md" \
  || fail "13a: Test plan + checked backticked boxes must accept ($(cat "$scratch/body.err"))"
ok "13a: #### Test plan checked backticked boxes accepted (the #3734 shape)"

# 13b. `## Verification` + backticked-command bullets, no magic keyword
# (fleet-ops#3761)
printf '%s\n' '## Fix

host the test

## Verification

- `bash tests/fleet-close-and-archive-repo.test.sh` — all drill checks pass
- `bash tests/p14-test-listing-gate.test.sh` — P14 closed
' >"$scratch/body.md"
run_body "$scratch/body.md" \
  || fail "13b: Verification bullets with backticked commands must accept ($(cat "$scratch/body.err"))"
ok "13b: Verification + backticked-command bullets accepted (the #3761 shape)"

# 13c. `## run-proof` heading (no colon) + backticked command (the #3717
# body that triggered the false has_verify_cue=false finding)
printf '%s\n' '## Verification

```
$ bash tests/fleet-metrics-export.test.sh
OK: section 9b passed
```

## run-proof

`bash tests/x.test.sh` exit 0; passed under TZ=Asia/Kolkata.
' >"$scratch/body.md"
run_body "$scratch/body.md" \
  || fail "13c: run-proof heading form must accept ($(cat "$scratch/body.err"))"
ok "13c: ## run-proof heading + backticked command accepted (the #3717 shape)"

# 13d. `## Test plan` with only unchecked boxes is a plan, not a run
printf '%s\n' '## Summary

- changed

## Test plan

- [ ] `npm test` — to be run
- [ ] CI on this PR
' >"$scratch/body.md"
if run_body "$scratch/body.md"; then
  fail "13d: unchecked-only Test plan must reject"
fi
ok "13d: unchecked-only Test plan rejected (a plan is not a run)"

# 13e. Checked box + result word, no backticks (fleet-ops#3627 shape)
printf '%s\n' '## Summary

- fix

## Test plan

- [x] fleet-restore-drill passes: backup/restore/verify OK, MANIFEST OK
' >"$scratch/body.md"
run_body "$scratch/body.md" \
  || fail "13e: checked box + result word must accept ($(cat "$scratch/body.err"))"
ok "13e: checked box + result word accepted (the #3627 shape)"

# --- 14. hard gate: armed no-receipt PR is disarmed (fleet-ops#3731) -------
# A worker arms its own PR via `gh pr merge --auto`; absent a required
# status check (the App token has no Workflows scope) the only mechanical
# gate an organ can apply is --disable-auto. Prove the canary does it.

# 14a. armed + no receipt -> EXEC-REVIEW-DISARM + disarm recorded + filed
cat >"$scratch/prs-armed-skip.json" <<'JSON'
[
  {
    "repo": "Nishfleet/fleet-ops",
    "number": 800,
    "title": "feat: armed with no receipt",
    "body": "## Summary\nchanged\n\nCloses #800\n",
    "createdAt": "2026-08-26T23:00:00Z",
    "url": "https://github.com/Nishfleet/fleet-ops/pull/800",
    "headRefName": "claim/issue-800",
    "author": {"login": "app/nishfleet-worker", "is_bot": true},
    "autoMergeRequest": {"enabledAt": "2026-08-26T23:05:00Z"}
  }
]
JSON
rm -f "$gh_store"/*.body "$gh_store/disarmed"
: >"$triage"
FLEET_EXEC_REVIEW_FILE=1 run_scan "$scratch/prs-armed-skip.json" \
  || fail "14a: armed skip must stay exit 0 ($(cat "$scratch/scan.err"))"
grep -q 'EXEC-REVIEW-DISARM' "$scratch/scan.err" \
  || fail "14a: expected EXEC-REVIEW-DISARM ($(cat "$scratch/scan.err"))"
grep -qxF 'Nishfleet/fleet-ops#800' "$gh_store/disarmed" \
  || fail "14a: gh pr merge --disable-auto not called ($(cat "$gh_store/disarmed" 2>/dev/null))"
grep -rq "signal: exec-review-receipt/Nishfleet/fleet-ops#800" "$gh_store" \
  || fail "14a: disarm must not replace the filing"
ok "14a: armed no-receipt worker PR is disarmed AND filed (hard gate)"

# 14b. NOT armed + no receipt -> files, no disarm call
cat >"$scratch/prs-unarmed-skip.json" <<'JSON'
[
  {
    "repo": "Nishfleet/fleet-ops",
    "number": 801,
    "title": "feat: unarmed no receipt",
    "body": "## Summary\nchanged\n\nCloses #801\n",
    "createdAt": "2026-08-26T23:00:00Z",
    "url": "https://github.com/Nishfleet/fleet-ops/pull/801",
    "headRefName": "claim/issue-801",
    "author": {"login": "app/nishfleet-worker", "is_bot": true},
    "autoMergeRequest": null
  }
]
JSON
rm -f "$gh_store"/*.body "$gh_store/disarmed"
: >"$triage"
FLEET_EXEC_REVIEW_FILE=1 run_scan "$scratch/prs-unarmed-skip.json" \
  || fail "14b: unarmed skip must exit 0 ($(cat "$scratch/scan.err"))"
grep -q 'EXEC-REVIEW-SKIP' "$scratch/scan.err" \
  || fail "14b: expected EXEC-REVIEW-SKIP"
if grep -q 'EXEC-REVIEW-DISARM' "$scratch/scan.err"; then
  fail "14b: unarmed PR must NOT be disarmed"
fi
[[ ! -s "$gh_store/disarmed" ]] || fail "14b: no disarm call expected"
ok "14b: unarmed no-receipt PR files without a disarm call"

# 14c. armed WITH receipt -> no finding, no disarm
cat >"$scratch/prs-armed-ok.json" <<'JSON'
[
  {
    "repo": "Nishfleet/fleet-ops",
    "number": 802,
    "title": "feat: armed with receipt",
    "body": "## Summary\nchanged\n\n## Test plan\n\n- [x] `bash tests/foo.test.sh` — exit 0\n",
    "createdAt": "2026-08-26T23:00:00Z",
    "url": "https://github.com/Nishfleet/fleet-ops/pull/802",
    "headRefName": "claim/issue-802",
    "author": {"login": "app/nishfleet-worker", "is_bot": true},
    "autoMergeRequest": {"enabledAt": "2026-08-26T23:05:00Z"}
  }
]
JSON
rm -f "$gh_store"/*.body "$gh_store/disarmed"
: >"$triage"
FLEET_EXEC_REVIEW_FILE=1 run_scan "$scratch/prs-armed-ok.json" \
  || fail "14c: armed receipt PR must exit 0 ($(cat "$scratch/scan.err"))"
grep -q 'EXEC-REVIEW-OK' "$scratch/scan.err" \
  || fail "14c: expected EXEC-REVIEW-OK ($(cat "$scratch/scan.err"))"
[[ ! -s "$gh_store/disarmed" ]] || fail "14c: receipt PR must never be disarmed"
ok "14c: armed PR with a receipt is never disarmed"

# 14d. FLEET_EXEC_REVIEW_DISARM=0 -> observe-only, no disarm
rm -f "$gh_store"/*.body "$gh_store/disarmed"
: >"$triage"
FLEET_EXEC_REVIEW_DISARM=0 FLEET_EXEC_REVIEW_FILE=1 \
  run_scan "$scratch/prs-armed-skip.json" \
  || fail "14d: disarm-off scan must exit 0 ($(cat "$scratch/scan.err"))"
grep -q 'EXEC-REVIEW-SKIP' "$scratch/scan.err" \
  || fail "14d: expected EXEC-REVIEW-SKIP"
if grep -q 'EXEC-REVIEW-DISARM' "$scratch/scan.err"; then
  fail "14d: FLEET_EXEC_REVIEW_DISARM=0 must suppress the disarm"
fi
[[ ! -s "$gh_store/disarmed" ]] || fail "14d: no disarm call expected under DISARM=0"
ok "14d: FLEET_EXEC_REVIEW_DISARM=0 keeps observe-only behaviour"

# --- 15. tier1 shared-classifier contract -----------------------------------
# fleet-ops#3731: three cue grammars drifted (gather slot, tier1 inline
# grep, receipt lib). The tier1 queue-pass arm gate must call the shared
# classifier — bin/fleet-exec-review-canary --body — via the
# FLEET_VERIFY_CUE_GATE seam, and must not regrow a private grammar.
grep -q 'FLEET_VERIFY_CUE_GATE' "$tier1" \
  || fail "15: tier1 must route the verify-cue gate through FLEET_VERIFY_CUE_GATE"
grep -q -- '--body' "$tier1" \
  || fail "15: tier1 must call the canary in --body mode"
if grep -q 'in_v=0' "$tier1"; then
  fail "15: tier1 regrew a private cue grammar (in_v loop is back)"
fi
grep -q 'no run receipt' "$tier1" \
  || fail "15: tier1 must distinguish a true reject ('no run receipt') from a broken helper"
ok "15: tier1 queue-pass arm gate uses the shared classifier (one grammar)"

# --- 16. any-author hard gate (fleet-ops#4117) -------------------------------
# A human-armed PR without a receipt is the same silent pass as a
# worker-armed one. The disarm hard gate applies to any armed author;
# filing stays worker-only (a human PR is not a worker skip to file
# about). The 2026-09-07 24h sample flagged 0509#1848 and fleet-ops#4094
# — both human-armed merges with no VERIFY grammar.

# 16a. armed human PR, no receipt -> disarmed, NOT filed
cat >"$scratch/prs-human-armed-skip.json" <<'JSON'
[
  {
    "repo": "Nishfleet/0509",
    "number": 1848,
    "title": "fix(search): tablet title collapse",
    "body": "## What\nResponsive layout fix.\n\n## Verification\n- Full canonical release proof: 73/73 passed, 7.9 min local run.",
    "createdAt": "2026-08-26T23:00:00Z",
    "url": "https://github.com/Nishfleet/0509/pull/1848",
    "headRefName": "fix/journey1-tablet-empty-race",
    "author": {"login": "nish3451", "is_bot": false},
    "autoMergeRequest": {"enabledAt": "2026-08-26T23:05:00Z"}
  }
]
JSON
rm -f "$gh_store"/issue-* "$gh_store/disarmed"
: >"$triage"
FLEET_EXEC_REVIEW_FILE=1 run_scan "$scratch/prs-human-armed-skip.json" \
  || fail "16a: armed human skip must stay exit 0 ($(cat "$scratch/scan.err"))"
grep -q 'EXEC-REVIEW-DISARM' "$scratch/scan.err" \
  || fail "16a: expected EXEC-REVIEW-DISARM for armed human PR ($(cat "$scratch/scan.err"))"
grep -q 'human PR Nishfleet/0509#1848' "$scratch/scan.err" \
  || fail "16a: LOUD line must name the human PR ($(cat "$scratch/scan.err"))"
grep -qxF 'Nishfleet/0509#1848' "$gh_store/disarmed" \
  || fail "16a: gh pr merge --disable-auto not called for human PR ($(cat "$gh_store/disarmed" 2>/dev/null))"
[[ -z "$(ls -A "$gh_store" 2>/dev/null | grep '^issue-' || true)" ]] \
  || fail "16a: must NOT file an issue for a human PR ($(ls -A "$gh_store" 2>/dev/null | grep '^issue-'))"
ok "16a: armed human PR without receipt is disarmed but NOT filed (any-author hard gate)"

# 16b. armed human PR WITH receipt -> no finding, no disarm
cat >"$scratch/prs-human-armed-ok.json" <<'JSON'
[
  {
    "repo": "Nishfleet/fleet-ops",
    "number": 4095,
    "title": "fix: human with receipt",
    "body": "## Summary\nchanged\n\n## Test plan\n\n- [x] `bash tests/foo.test.sh` — exit 0\n",
    "createdAt": "2026-08-26T23:00:00Z",
    "url": "https://github.com/Nishfleet/fleet-ops/pull/4095",
    "headRefName": "fix/human-receipt",
    "author": {"login": "nish3451", "is_bot": false},
    "autoMergeRequest": {"enabledAt": "2026-08-26T23:05:00Z"}
  }
]
JSON
rm -f "$gh_store"/issue-* "$gh_store/disarmed"
: >"$triage"
FLEET_EXEC_REVIEW_FILE=1 run_scan "$scratch/prs-human-armed-ok.json" \
  || fail "16b: armed human receipt PR must exit 0 ($(cat "$scratch/scan.err"))"
grep -q 'EXEC-REVIEW-OK' "$scratch/scan.err" \
  || fail "16b: expected EXEC-REVIEW-OK ($(cat "$scratch/scan.err"))"
[[ ! -s "$gh_store/disarmed" ]] || fail "16b: receipt PR must never be disarmed"
ok "16b: armed human PR with a receipt is never disarmed"

# 16c. unarmed human PR, no receipt -> skipped (no disarm, no file)
cat >"$scratch/prs-human-unarmed-skip.json" <<'JSON'
[
  {
    "repo": "Nishfleet/fleet-ops",
    "number": 702,
    "title": "docs: human direct merge",
    "body": "no receipt here",
    "createdAt": "2026-08-26T23:00:00Z",
    "url": "https://github.com/Nishfleet/fleet-ops/pull/702",
    "headRefName": "docs/human",
    "author": {"login": "nish3451", "is_bot": false},
    "autoMergeRequest": null
  }
]
JSON
rm -f "$gh_store"/issue-* "$gh_store/disarmed"
: >"$triage"
FLEET_EXEC_REVIEW_FILE=1 run_scan "$scratch/prs-human-unarmed-skip.json" \
  || fail "16c: unarmed human skip must exit 0 ($(cat "$scratch/scan.err"))"
grep -q 'EXEC-REVIEW-OK' "$scratch/scan.err" \
  || fail "16c: expected EXEC-REVIEW-OK ($(cat "$scratch/scan.err"))"
[[ ! -s "$gh_store/disarmed" ]] || fail "16c: unarmed human PR must not be disarmed"
[[ -z "$(ls -A "$gh_store" 2>/dev/null | grep '^issue-' || true)" ]] \
  || fail "16c: must not file on an unarmed human PR"
ok "16c: unarmed human PR without receipt is skipped (cannot block a direct merge)"

echo "OK: fleet-exec-review-canary: receipt gate, skip drill, observe-to-open, observe-to-close, dedupe, broken watch, grammar extension, disarm hard gate, any-author hard gate"
