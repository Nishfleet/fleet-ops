#!/usr/bin/env bash
# tests/fleet-merged-pr-close.test.sh
#
# Proves fleet-ops#1435: an OPEN issue that a merged PR already shipped but
# forgot to close (the forgotten-Closes-trailer class) is observed-to-close
# by the heartbeat within one tick. No new scheduler.
#
#   - merged PR references the issue by #<N> / <repo>#<N> in title or body,
#     plus the safety guards all pass (no open PR on claim branch, claim
#     branch gone, no live worker) -> closes with a comment citing the
#     merged PR URL and the verification
#   - close is OFF by default (FLEET_MERGED_PR_CLOSE_OK != 1): candidate is
#     described but the live repo is never touched
#   - open PR on the claim branch -> skip (in flight)
#   - claim/issue-<N> branch still exists -> skip (may be in a worktree)
#   - no agent-in-progress / critical-path label -> not scanned
#   - a live pi-issue worker -> skip (actively being worked)
#   - more than one merged PR references the issue -> AMBIGUOUS LOUD skip,
#     UNLESS one of them is the claim/issue-<N> delivery PR, which
#     disambiguates a passing mention (fleet-ops#1672)
#   - merged PR outside the 7-day window -> no reference -> leave open
#   - reference matcher is exact-number: #11352 / claim/issue-1135 do not
#     match issue 1135
#   - crash paths (gh missing, invalid intake JSON, bad window) -> rc 2
#   - contracts: tier1 call + MANIFEST entry
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-merged-pr-close"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch=$(mktemp -d)
mkdir -p "$scratch/bin"

# Mock gh shim. Logs every call and serves per-command fixtures.
cat >"$scratch/bin/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_DIR/gh.log"
case "$1" in
  issue)
    case "$2" in
      list)
        cat "$FAKE_DIR/list.json"
        exit 0
        ;;
      close)
        printf '%s\n' "$*" >>"$FAKE_DIR/closes.log"
        exit 0
        ;;
      *) echo "unexpected gh issue $2" >&2; exit 1 ;;
    esac ;;
  pr)
    case "$2" in
      list)
        case "$*" in
          *"--state merged"*)
            cat "$FAKE_DIR/merged.json"
            exit 0
            ;;
          *"claim/issue"*)
            cat "$FAKE_DIR/openpr.json"
            exit 0
            ;;
          *) echo '[]'; exit 0 ;;
        esac ;;
      *) echo "unexpected gh pr $2" >&2; exit 1 ;;
    esac ;;
  api)
    # repos/<repo>/git/refs/heads/claim/issue-N — 404 means the branch is
    # gone (close eligible); 200 means it still exists (skip).
    cat "$FAKE_DIR/ref.json"
    exit "${FAKE_REF_RC:-1}"
    ;;
  *) echo "unexpected gh $1" >&2; exit 1 ;;
esac
FAKE
chmod +x "$scratch/bin/gh"

run() {
    # $@ -> env overrides; set default env then run the bin, print stdout.
    env \
        MERGED_PR_CLOSE_REPOS="Nishfleet/fleet-ops" \
        MERGED_PR_CLOSE_NOW="${TEST_NOW:-2026-08-28T00:53:00Z}" \
        MERGED_PR_CLOSE_TRIAGE="$scratch/triage.md" \
        "$@" \
        "$bin" 2>&1
}

set_fixtures() {
    # $1 = list.json content, $2 = merged.json content, $3 = openpr.json
    printf '%s' "$1" >"$scratch/list.json"
    printf '%s' "$2" >"$scratch/merged.json"
    printf '%s' "${3:-[]}" >"$scratch/openpr.json"
    printf '%s' '{"message":"Not Found"}' >"$scratch/ref.json"
    : >"$scratch/closes.log"
    : >"$scratch/gh.log"
    : >"$scratch/triage.md" 2>/dev/null || true
}

export FAKE_DIR="$scratch"

# --- Case 1: close OFF by default — candidate found, repo never touched ---
set_fixtures \
  '[{"number":1135,"title":"bare-metal rebuild","labels":[{"name":"critical-path"},{"name":"agent-in-progress"}],"body":"x"}]' \
  '[{"number":1429,"title":"feat(disaster-recovery): bare-metal rebuild (fleet-ops#1135)","body":"shipped work. See fleet-ops#1135.","mergedAt":"2026-08-28T00:22:21Z","url":"https://github.com/Nishfleet/fleet-ops/pull/1429"}]'
export PATH="$scratch/bin:$PATH"
out=$(run)
grep -q 'CANDIDATE' <<<"$out" || fail "close-off should report a candidate: $out"
[[ -s "$scratch/closes.log" ]] && fail "close-off must not close live issues: $(cat "$scratch/closes.log")"
ok "close-off: candidate described, live repo untouched (fail-closed gate)"

# --- Case 2: close ON — closes with a comment citing the merged PR ---
set_fixtures \
  '[{"number":1135,"title":"bare-metal rebuild","labels":[{"name":"critical-path"},{"name":"agent-in-progress"}],"body":"x"}]' \
  '[{"number":1429,"title":"feat(disaster-recovery): bare-metal rebuild (fleet-ops#1135)","body":"shipped work. See fleet-ops#1135.","mergedAt":"2026-08-28T00:22:21Z","url":"https://github.com/Nishfleet/fleet-ops/pull/1429"}]'
out=$(run FLEET_MERGED_PR_CLOSE_OK=1)
grep -q 'CLOSED' <<<"$out" || fail "close-on should close: $out"
grep -q 'issue close 1135' "$scratch/closes.log" || fail "close-on must call gh issue close 1135: $(cat "$scratch/closes.log")"
grep -q 'fleet-ops/pull/1429' "$scratch/closes.log" || fail "close comment must cite the merged PR URL: $(cat "$scratch/closes.log")"
grep -q 'verification' "$scratch/closes.log" || fail "close comment must carry the verification: $(cat "$scratch/closes.log")"
ok "close-on: issue closed, comment cites merged PR URL + verification"

# --- Case 3: open PR on the claim branch -> skip (work in flight) ---
set_fixtures \
  '[{"number":1135,"title":"t","labels":[{"name":"agent-in-progress"}],"body":"b"}]' \
  '[{"number":1429,"title":"feat: x (fleet-ops#1135)","body":"See fleet-ops#1135","mergedAt":"2026-08-28T00:22:21Z","url":"https://url/1429"}]' \
  '[{"number":1}]'
out=$(run FLEET_MERGED_PR_CLOSE_OK=1)
grep -q 'open claim PR' <<<"$out" || fail "open-PR guard must log: $out"
[[ -s "$scratch/closes.log" ]] && fail "open-PR guard must not close: $(cat "$scratch/closes.log")"
ok "open PR on claim branch -> skip, no close"

# --- Case 4: claim branch still exists -> skip (may be in a worktree) ---
set_fixtures \
  '[{"number":1135,"title":"t","labels":[{"name":"agent-in-progress"}],"body":"b"}]' \
  '[{"number":1429,"title":"feat: x (fleet-ops#1135)","body":"See fleet-ops#1135","mergedAt":"2026-08-28T00:22:21Z","url":"https://url/1429"}]'
out=$(run FLEET_MERGED_PR_CLOSE_OK=1 FAKE_REF_RC=0)
grep -q 'branch still exists' <<<"$out" || fail "claim-branch guard must log: $out"
[[ -s "$scratch/closes.log" ]] && fail "claim-branch guard must not close: $(cat "$scratch/closes.log")"
ok "claim/issue-N branch still exists -> skip, no close"

# --- Case 5: no agent-in-progress / critical-path label -> not scanned ---
set_fixtures \
  '[{"number":1135,"title":"t","labels":[{"name":"bug"}],"body":"b"}]' \
  '[{"number":1429,"title":"feat: x (fleet-ops#1135)","body":"See fleet-ops#1135","mergedAt":"2026-08-28T00:22:21Z","url":"https://url/1429"}]'
out=$(run FLEET_MERGED_PR_CLOSE_OK=1)
grep -q 'scanned=0' <<<"$out" || fail "no-lifecycle-label must scan 0: $out"
[[ -s "$scratch/closes.log" ]] && fail "no-lifecycle-label must not close: $(cat "$scratch/closes.log")"
ok "issue without agent-in-progress/critical-path label is not scanned"

# --- Case 6: a live worker -> skip (actively being worked) ---
set_fixtures \
  '[{"number":1135,"title":"t","labels":[{"name":"agent-in-progress"}],"body":"b"}]' \
  '[{"number":1429,"title":"feat: x (fleet-ops#1135)","body":"See fleet-ops#1135","mergedAt":"2026-08-28T00:22:21Z","url":"https://url/1429"}]'
mkdir -p "$scratch/livebin"
cat >"$scratch/livebin/systemctl" <<'FAKE'
#!/usr/bin/env bash
# Report pi-issue@fleet-ops-1135.service as active -> live worker.
printf '%s\n' "pi-issue@fleet-ops-1135.service"
exit 0
FAKE
chmod +x "$scratch/livebin/systemctl"
out=$(env PATH="$scratch/livebin:$scratch/bin:$PATH" \
  MERGED_PR_CLOSE_REPOS="Nishfleet/fleet-ops" \
  MERGED_PR_CLOSE_NOW="2026-08-28T00:53:00Z" \
  MERGED_PR_CLOSE_TRIAGE="$scratch/triage.md" \
  FLEET_MERGED_PR_CLOSE_OK=1 \
  "$bin" 2>&1)
grep -q 'live worker' <<<"$out" || fail "live-worker guard must log: $out"
[[ -s "$scratch/closes.log" ]] && fail "live-worker guard must not close: $(cat "$scratch/closes.log")"
ok "live pi-issue worker -> skip, no close"

export PATH="$scratch/bin:$PATH"

# --- Case 7: two merged PRs reference the issue -> AMBIGUOUS LOUD skip ---
set_fixtures \
  '[{"number":1135,"title":"t","labels":[{"name":"agent-in-progress"}],"body":"b"}]' \
  '[{"number":1429,"title":"feat: x (fleet-ops#1135)","body":"See fleet-ops#1135","mergedAt":"2026-08-28T00:22:21Z","url":"https://url/1429"},{"number":1430,"title":"y (#1135)","body":"z","mergedAt":"2026-08-27T00:00:00Z","url":"https://url/1430"}]'
out=$(run FLEET_MERGED_PR_CLOSE_OK=1)
grep -q 'MERGED-PR-CLOSE-AMBIGUOUS' <<<"$out" || fail "ambiguous must be LOUD: $out"
[[ -s "$scratch/closes.log" ]] && fail "ambiguous must not close: $(cat "$scratch/closes.log")"
grep -q 'MERGED-PR-CLOSE-AMBIGUOUS' "$scratch/triage.md" || fail "ambiguous must land in triage: $(cat "$scratch/triage.md")"
ok "multiple merged PRs reference the issue -> AMBIGUOUS LOUD skip"

# --- Case 7b: a claim-branch PR disambiguates a passing mention ---
# fleet-ops#1672: a merged delivery PR (head branch claim/issue-<N>) plus a
# passing body mention in an unrelated PR must NOT be ambiguous — the
# claim-branch PR is the delivery, so the issue closes.
set_fixtures \
  '[{"number":1135,"title":"t","labels":[{"name":"agent-in-progress"}],"body":"b"}]' \
  '[{"number":1429,"title":"feat: x (fleet-ops#1135)","body":"See fleet-ops#1135","mergedAt":"2026-08-28T00:22:21Z","url":"https://url/1429","headRefName":"claim/issue-1135"},{"number":1430,"title":"y","body":"already filed as #1135","mergedAt":"2026-08-27T00:00:00Z","url":"https://url/1430","headRefName":"fix/other"}]'
out=$(run FLEET_MERGED_PR_CLOSE_OK=1)
grep -q 'CLOSED' <<<"$out" || fail "claim-branch PR must disambiguate and close: $out"
grep -q 'issue close 1135' "$scratch/closes.log" || fail "disambiguated close must call gh issue close 1135: $(cat "$scratch/closes.log")"
grep -q 'MERGED-PR-CLOSE-AMBIGUOUS' <<<"$out" && fail "claim-branch PR must not be ambiguous: $out"
ok "claim-branch delivery PR disambiguates a passing mention -> close"

# --- Case 7c: claim-branch PR wins even when the passing mention is in a
# title, and the delivery PR itself carries no #<N> reference ---
set_fixtures \
  '[{"number":1135,"title":"t","labels":[{"name":"agent-in-progress"}],"body":"b"}]' \
  '[{"number":1429,"title":"feat: x","body":"shipped work","mergedAt":"2026-08-28T00:22:21Z","url":"https://url/1429","headRefName":"claim/issue-1135"},{"number":1430,"title":"y (#1135)","body":"z","mergedAt":"2026-08-27T00:00:00Z","url":"https://url/1430","headRefName":"fix/other"}]'
out=$(run FLEET_MERGED_PR_CLOSE_OK=1)
grep -q 'CLOSED' <<<"$out" || fail "claim-branch PR must win over a title mention: $out"
grep -q 'issue close 1135' "$scratch/closes.log" || fail "claim-branch win must close: $(cat "$scratch/closes.log")"
ok "claim-branch delivery PR wins over a title mention -> close"

# --- Case 8: merged PR outside the 7-day window -> leave open ---
set_fixtures \
  '[{"number":1135,"title":"t","labels":[{"name":"agent-in-progress"}],"body":"b"}]' \
  '[{"number":1429,"title":"feat: x (fleet-ops#1135)","body":"See fleet-ops#1135","mergedAt":"2026-07-01T00:22:21Z","url":"https://url/1429"}]'
out=$(run FLEET_MERGED_PR_CLOSE_OK=1)
grep -q 'no merged PR references it' <<<"$out" || fail "out-of-window should leave open: $out"
[[ -s "$scratch/closes.log" ]] && fail "out-of-window must not close: $(cat "$scratch/closes.log")"
ok "merged PR outside window -> no reference, issue left open"

# --- Case 9: reference matcher is exact-number (no false positives) ---
# A PR body mentioning #11352 or claim/issue-1135 must NOT count as a
# reference to issue 1135.
set_fixtures \
  '[{"number":1135,"title":"t","labels":[{"name":"agent-in-progress"}],"body":"b"}]' \
  '[{"number":1429,"title":"feat: x","body":"backport of #11352; see claim/issue-1135","mergedAt":"2026-08-28T00:22:21Z","url":"https://url/1429"}]'
out=$(run FLEET_MERGED_PR_CLOSE_OK=1)
grep -q 'no merged PR references it' <<<"$out" || fail "exact-number matcher must not match #11352: $out"
[[ -s "$scratch/closes.log" ]] && fail "exact-number matcher must not close: $(cat "$scratch/closes.log")"
ok "reference matcher is exact-number (#11352 / claim/issue-1135 do not match 1135)"

# --- Case 10: crash paths fail closed with rc 2 ---
# gh missing
set_fixtures \
  '[{"number":1135,"title":"t","labels":[{"name":"agent-in-progress"}],"body":"b"}]' \
  '[{"number":1429,"title":"feat: x (fleet-ops#1135)","body":"See fleet-ops#1135","mergedAt":"2026-08-28T00:22:21Z","url":"https://url/1429"}]'
# An isolated tool dir built from symlinks to ONLY the commands the script
# needs, so `gh` is genuinely unresolvable regardless of where it lives on
# the runner. On GitHub-hosted runners gh shares a directory with bash, so
# a PATH filtered only by "dirname of the core tools" still resolves gh and
# the gh-missing crash path never fires (fleet-ops#1919). Symlinking each
# needed tool into one fresh dir makes the crash path deterministic: gh is
# absent there by construction, and the script's tools are all present.
mkdir -p "$scratch/minbin"
for t in bash env id jq date grep sed awk; do
  ln -sf "$(command -v "$t")" "$scratch/minbin/$t"
done
out=$(env PATH="$scratch/minbin" MERGED_PR_CLOSE_REPOS="Nishfleet/fleet-ops" \
  MERGED_PR_CLOSE_NOW="2026-08-28T00:53:00Z" MERGED_PR_CLOSE_TRIAGE="$scratch/triage.md" \
  "$bin" 2>&1; echo "rc=$?")
grep -q 'rc=2' <<<"$out" || fail "gh-missing must exit rc 2: $out"
ok "crash: gh missing -> rc 2"

# invalid intake JSON
out=$(env PATH="$scratch/bin:$PATH" MERGED_PR_CLOSE_REPOS="" \
  MERGED_PR_CLOSE_INTAKE_JSON="$scratch/bad.json" \
  MERGED_PR_CLOSE_NOW="2026-08-28T00:53:00Z" MERGED_PR_CLOSE_TRIAGE="$scratch/triage.md" \
  "$bin" 2>&1; echo "rc=$?")
printf 'not json{' >"$scratch/bad.json"
out=$(env PATH="$scratch/bin:$PATH" MERGED_PR_CLOSE_REPOS="" \
  MERGED_PR_CLOSE_INTAKE_JSON="$scratch/bad.json" \
  MERGED_PR_CLOSE_NOW="2026-08-28T00:53:00Z" MERGED_PR_CLOSE_TRIAGE="$scratch/triage.md" \
  "$bin" 2>&1; echo "rc=$?")
grep -q 'rc=2' <<<"$out" || fail "invalid intake JSON must exit rc 2: $out"
ok "crash: invalid intake JSON -> rc 2"

# invalid WINDOW_DAYS
out=$(env PATH="$scratch/bin:$PATH" MERGED_PR_CLOSE_REPOS="Nishfleet/fleet-ops" \
  MERGED_PR_CLOSE_WINDOW_DAYS="bogus" \
  MERGED_PR_CLOSE_NOW="2026-08-28T00:53:00Z" MERGED_PR_CLOSE_TRIAGE="$scratch/triage.md" \
  "$bin" 2>&1; echo "rc=$?")
grep -q 'rc=2' <<<"$out" || fail "invalid WINDOW_DAYS must exit rc 2: $out"
ok "crash: invalid WINDOW_DAYS -> rc 2"

# --- Case 11: contracts — tier1 call + MANIFEST entry ---
grep -q 'fleet-merged-pr-close' "$repo_root/bin/fleet-heartbeat-tier1" \
  || fail "tier1 must call fleet-merged-pr-close"
grep -q 'FLEET_MERGED_PR_CLOSE_OK=1' "$repo_root/bin/fleet-heartbeat-tier1" \
  || fail "tier1 must set FLEET_MERGED_PR_CLOSE_OK=1"
grep -q 'bin/fleet-merged-pr-close' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/fleet-merged-pr-close"
ok "contracts: tier1 call + close gate + MANIFEST entry present"

echo "all fleet-merged-pr-close cases passed"
