#!/usr/bin/env bash
# tests/fleet-merged-pr-close.test.sh
#
# Proves fleet-ops#1435 + fleet-ops#3231: an OPEN issue that a merged PR
# already shipped is observed-to-close by the heartbeat within one tick —
# but ONLY when the PR is an explicit delivery. A mere mention never closes.
#
# DELIVERY RULES (fleet-ops#3231, the PR #3205 regression that wrongly
# closed #3140/#3146):
#   - closes when the merged PR head branch is claim/issue-<N>, or its body
#     carries an explicit `Closes|Fixes|Resolves #N` trailer —
#     reason=claim-branch | closes-trailer
#   - a bare reference (prose, blocked-on:, comment, quoted text) is
#     comment-only: 'PR #M mentions this issue; not closing' — NEVER closes
#   - a protected issue (critical-path label or nish3451-authored) is
#     ALWAYS comment-only, even on a real delivery — NEVER closes
#   - regression replay: PR #3205 vs issues #3140/#3146/#3161 closes ONLY
#     3161 (claim branch); 3140/3146 get a protected note, stay open
#
# Plus the original #1435 safety guards:
#   - close is OFF by default (FLEET_MERGED_PR_CLOSE_OK != 1): candidate is
#     described but the live repo is never touched
#   - open PR on the claim branch -> skip (in flight)
#   - claim/issue-<N> branch exists WITH divergent commits -> skip (worktree)
#   - claim/issue-<N> branch exists with NO divergent commits -> stale
#     re-queue pointer, fall through and close (fleet-ops#2080)
#   - no agent-in-progress / critical-path label -> not scanned
#   - a live pi-issue worker -> skip (actively being worked)
#   - more than one merged PR DELIVERS the issue -> AMBIGUOUS LOUD skip
#   - merged PR outside the 7-day window -> no reference -> leave open
#   - reference matcher is exact-number: #11352 / claim/issue-1135 do not
#     match issue 1135
#   - mention notes are deduped per (issue, PR) across ticks
#   - per-tick closes_by_reason summary JSON is written for the
#     fleet_observe_to_close_total{reason} metric (bare-mention/protected 0)
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
      comment)
        # Append the --body so a later `issue view` sees it (dedup test).
        body=$(printf '%s' "$*" | sed -n 's/.*--body //p')
        printf '%s' "$body" >>"$FAKE_DIR/view-comments.txt"
        printf '%s\n' "$*" >>"$FAKE_DIR/comments.log"
        exit 0
        ;;
      view)
        # Existing comment bodies, accumulated by `issue comment`.
        printf '[{"body":"%s"}]' "$(cat "$FAKE_DIR/view-comments.txt" 2>/dev/null || true)"
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
    case "$*" in
      *"/compare/"*)
        # repos/<repo>/compare/<base>...<head> — ahead_by drives the
        # stale-branch guard (fleet-ops#2080). Default 0 = stale pointer.
        # Honor --jq '.ahead_by' the way real gh does (prints the bare value).
        if [[ "$*" == *"--jq"* ]]; then
          printf '%s' "${FAKE_AHEAD_BY:-0}"
        else
          printf '%s' '{"ahead_by":'"${FAKE_AHEAD_BY:-0}"',"behind_by":0,"status":"identical"}'
        fi
        exit 0
        ;;
      *"git/refs/heads/claim/issue-"*)
        # 200 + ref.json means the branch exists; 404 (FAKE_REF_RC=1) = gone.
        cat "$FAKE_DIR/ref.json"
        exit "${FAKE_REF_RC:-1}"
        ;;
      *"repos/"*"/git/refs/heads/"*)
        # Non-claim ref lookup — not used by the detector, but be safe.
        cat "$FAKE_DIR/ref.json"
        exit "${FAKE_REF_RC:-1}"
        ;;
      *"repos/"*)
        # repos/<repo> — default_branch for the compare base. Honor --jq.
        if [[ "$*" == *"--jq"* ]]; then
          printf '%s' "main"
        else
          printf '%s' '{"default_branch":"main"}'
        fi
        exit 0
        ;;
      *)
        echo "unexpected gh api $*" >&2
        exit 1
        ;;
    esac ;;
  *) echo "unexpected gh $1" >&2; exit 1 ;;
esac
FAKE
chmod +x "$scratch/bin/gh"

# Default systemctl mock: report NO live workers so the live-worker guard is
# hermetic (a real pi-issue@fleet-ops-<N>.service activating on the VPS would
# otherwise leak into every case). Case 6 overrides this with a live mock.
cat >"$scratch/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
# Echo nothing for list-units; is-active returns "inactive" (exit 3).
case "$*" in
  *list-units*) exit 0 ;;
  *) exit 3 ;;
esac
FAKE
chmod +x "$scratch/bin/systemctl"

run() {
    # $@ -> env overrides; set default env then run the bin, print stdout.
    env \
        MERGED_PR_CLOSE_REPOS="Nishfleet/fleet-ops" \
        MERGED_PR_CLOSE_NOW="${TEST_NOW:-2026-08-28T00:53:00Z}" \
        MERGED_PR_CLOSE_TRIAGE="$scratch/triage.md" \
        MERGED_PR_CLOSE_SUMMARY="$scratch/summary.json" \
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
    : >"$scratch/comments.log"
    : >"$scratch/view-comments.txt"
    : >"$scratch/summary.json" 2>/dev/null || true
    : >"$scratch/gh.log"
    : >"$scratch/triage.md" 2>/dev/null || true
}

# A runnable issue: agent-in-progress only, non-protected author.
NOOP_ISSUE='[{"number":1135,"title":"bare-metal rebuild","labels":[{"name":"agent-in-progress"}],"body":"x","author":{"login":"fleet-issue-bot"}}]'
# Trailer-delivering merged PR: explicit `Closes #1135`, not on the claim branch.
TRAILER_PR='[{"number":1429,"title":"feat(disaster-recovery): bare-metal rebuild (fleet-ops#1135)","body":"shipped work. See fleet-ops#1135.\n\nCloses #1135","mergedAt":"2026-08-28T00:22:21Z","url":"https://github.com/Nishfleet/fleet-ops/pull/1429","headRefName":"fix/rebuild-v2"}]'

export FAKE_DIR="$scratch"

# --- Case 1: close OFF by default — delivery candidate logged, no writes ---
set_fixtures "$NOOP_ISSUE" "$TRAILER_PR"
export PATH="$scratch/bin:$PATH"
out=$(run)
grep -q 'CANDIDATE' <<<"$out" || fail "close-off should report a candidate: $out"
grep -q 'reason=closes-trailer' <<<"$out" || fail "candidate must name the delivery reason: $out"
[[ -s "$scratch/closes.log" ]] && fail "close-off must not close live issues: $(cat "$scratch/closes.log")"
[[ -s "$scratch/comments.log" ]] && fail "close-off must not comment live issues: $(cat "$scratch/comments.log")"
ok "close-off: delivery candidate described, live repo untouched (fail-closed gate)"

# --- Case 2: close ON — Closes-trailer delivery closes with a comment ---
set_fixtures "$NOOP_ISSUE" "$TRAILER_PR"
out=$(run FLEET_MERGED_PR_CLOSE_OK=1)
grep -q 'CLOSED' <<<"$out" || fail "close-on should close: $out"
grep -q 'issue close 1135' "$scratch/closes.log" || fail "close-on must call gh issue close 1135: $(cat "$scratch/closes.log")"
grep -q 'fleet-ops/pull/1429' "$scratch/closes.log" || fail "close comment must cite the merged PR URL: $(cat "$scratch/closes.log")"
grep -q 'verification' "$scratch/closes.log" || fail "close comment must carry the verification: $(cat "$scratch/closes.log")"
grep -q 'closes-trailer":1' "$scratch/summary.json" || fail "summary must count the closes-trailer close: $(cat "$scratch/summary.json")"
grep -q '"bare-mention":0' "$scratch/summary.json" || fail "summary must keep bare-mention at 0: $(cat "$scratch/summary.json")"
ok "close-on: Closes-trailer delivery -> issue closed, comment cites PR URL + verification, summary written"

# --- Case 2b: close ON — claim-branch delivery closes even with no #N
# reference in title/body (the claim branch IS the delivery signal) ---
set_fixtures "$NOOP_ISSUE" \
  '[{"number":1429,"title":"feat: bare-metal rebuild","body":"shipped work","mergedAt":"2026-08-28T00:22:21Z","url":"https://github.com/Nishfleet/fleet-ops/pull/1429","headRefName":"claim/issue-1135"}]'
out=$(run FLEET_MERGED_PR_CLOSE_OK=1)
grep -q 'CLOSED' <<<"$out" || fail "claim-branch delivery should close: $out"
grep -q 'via claim-branch' <<<"$out" || fail "close must be attributed to claim-branch: $out"
grep -q 'issue close 1135' "$scratch/closes.log" || fail "claim-branch close must call gh issue close: $(cat "$scratch/closes.log")"
grep -q '"claim-branch":1' "$scratch/summary.json" || fail "summary must count the claim-branch close: $(cat "$scratch/summary.json")"
ok "close-on: claim/issue-N branch delivery -> close with reason=claim-branch"

# --- Case 3: open PR on the claim branch -> skip (work in flight) ---
set_fixtures "$NOOP_ISSUE" "$TRAILER_PR" '[{"number":1}]'
out=$(run FLEET_MERGED_PR_CLOSE_OK=1)
grep -q 'open claim PR' <<<"$out" || fail "open-PR guard must log: $out"
[[ -s "$scratch/closes.log" ]] && fail "open-PR guard must not close: $(cat "$scratch/closes.log")"
ok "open PR on claim branch -> skip, no close"

# --- Case 4: claim branch exists WITH divergent commits -> skip (real worktree) ---
set_fixtures "$NOOP_ISSUE" "$TRAILER_PR"
out=$(run FLEET_MERGED_PR_CLOSE_OK=1 FAKE_REF_RC=0 FAKE_AHEAD_BY=3)
grep -q 'divergent commit' <<<"$out" || fail "divergent-branch guard must log: $out"
[[ -s "$scratch/closes.log" ]] && fail "divergent-branch guard must not close: $(cat "$scratch/closes.log")"
ok "claim/issue-N branch with divergent commits -> skip, no close"

# --- Case 4b: claim branch exists with NO divergent commits -> stale pointer,
# fall through and close (fleet-ops#2080: the bug that kept #1135 cycling) ---
set_fixtures "$NOOP_ISSUE" \
  '[{"number":1429,"title":"feat: bare-metal rebuild","body":"shipped work","mergedAt":"2026-08-28T00:22:21Z","url":"https://url/1429","headRefName":"claim/issue-1135"}]'
out=$(run FLEET_MERGED_PR_CLOSE_OK=1 FAKE_REF_RC=0 FAKE_AHEAD_BY=0)
grep -q 'stale re-queue pointer' <<<"$out" || fail "stale-branch fall-through must log: $out"
grep -q 'CLOSED' <<<"$out" || fail "stale-branch must fall through and close: $out"
grep -q 'issue close 1135' "$scratch/closes.log" || fail "stale-branch must close: $(cat "$scratch/closes.log")"
ok "claim/issue-N branch with no divergent commits (stale) -> fall through, close"

# --- Case 5: no agent-in-progress / critical-path label -> not scanned ---
set_fixtures \
  '[{"number":1135,"title":"t","labels":[{"name":"bug"}],"body":"b","author":{"login":"x"}}]' \
  "$TRAILER_PR"
out=$(run FLEET_MERGED_PR_CLOSE_OK=1)
grep -q 'scanned=0' <<<"$out" || fail "no-lifecycle-label must scan 0: $out"
[[ -s "$scratch/closes.log" ]] && fail "no-lifecycle-label must not close: $(cat "$scratch/closes.log")"
ok "issue without agent-in-progress/critical-path label is not scanned"

# --- Case 6: a live worker -> skip (actively being worked) ---
set_fixtures "$NOOP_ISSUE" "$TRAILER_PR"
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
  MERGED_PR_CLOSE_SUMMARY="$scratch/summary.json" \
  FLEET_MERGED_PR_CLOSE_OK=1 \
  "$bin" 2>&1)
grep -q 'live worker' <<<"$out" || fail "live-worker guard must log: $out"
[[ -s "$scratch/closes.log" ]] && fail "live-worker guard must not close: $(cat "$scratch/closes.log")"
ok "live pi-issue worker -> skip, no close"

export PATH="$scratch/bin:$PATH"

# --- Case 7: bare mentions with NO delivery -> comment-only, never close ---
# fleet-ops#3231: two merged PRs that merely MENTION the issue (no Closes
# trailer, no claim branch) are NOT ambiguous — they are neither deliveries,
# so the detector comments 'not closing' and leaves the issue open. A
# mention is not a fix.
set_fixtures "$NOOP_ISSUE" \
  '[{"number":1429,"title":"feat: x (fleet-ops#1135)","body":"See fleet-ops#1135","mergedAt":"2026-08-28T00:22:21Z","url":"https://url/1429","headRefName":"fix/a"},{"number":1430,"title":"y (#1135)","body":"z","mergedAt":"2026-08-27T00:00:00Z","url":"https://url/1430","headRefName":"fix/b"}]'
out=$(run FLEET_MERGED_PR_CLOSE_OK=1)
grep -q 'NOTE (mode=mention)' <<<"$out" || fail "mention-only must be reported as a note: $out"
[[ -s "$scratch/closes.log" ]] && fail "mention-only must not close: $(cat "$scratch/closes.log")"
grep -q 'not closing' "$scratch/comments.log" || fail "mention-only must comment 'not closing': $(cat "$scratch/comments.log")"
grep -q 'MERGED-PR-CLOSE-AMBIGUOUS' <<<"$out" && fail "bare mentions must not be AMBIGUOUS: $out"
grep -q 'skipped_mention=1' <<<"$out" || fail "mention must count as skipped_mention: $out"
ok "bare mentions without a delivery -> comment-only, never close (fleet-ops#3231)"

# --- Case 7b: a claim-branch delivery disambiguates a passing mention ---
# fleet-ops#1672: a merged delivery PR (head branch claim/issue-<N>) plus a
# passing body mention in an unrelated PR must NOT be ambiguous — the
# claim-branch PR is the delivery, so the issue closes.
set_fixtures "$NOOP_ISSUE" \
  '[{"number":1429,"title":"feat: x (fleet-ops#1135)","body":"See fleet-ops#1135","mergedAt":"2026-08-28T00:22:21Z","url":"https://url/1429","headRefName":"claim/issue-1135"},{"number":1430,"title":"y","body":"already filed as #1135","mergedAt":"2026-08-27T00:00:00Z","url":"https://url/1430","headRefName":"fix/other"}]'
out=$(run FLEET_MERGED_PR_CLOSE_OK=1)
grep -q 'CLOSED' <<<"$out" || fail "claim-branch PR must disambiguate and close: $out"
grep -q 'issue close 1135' "$scratch/closes.log" || fail "disambiguated close must call gh issue close 1135: $(cat "$scratch/closes.log")"
grep -q 'MERGED-PR-CLOSE-AMBIGUOUS' <<<"$out" && fail "claim-branch PR must not be ambiguous: $out"
ok "claim-branch delivery PR disambiguates a passing mention -> close"

# --- Case 7d: TWO deliveries -> AMBIGUOUS LOUD skip (defer to human) ---
set_fixtures "$NOOP_ISSUE" \
  '[{"number":1429,"title":"feat: x","body":"shipped\n\nCloses #1135","mergedAt":"2026-08-28T00:22:21Z","url":"https://url/1429","headRefName":"fix/a"},{"number":1430,"title":"y","body":"z\n\nFixes #1135","mergedAt":"2026-08-27T00:00:00Z","url":"https://url/1430","headRefName":"fix/b"}]'
out=$(run FLEET_MERGED_PR_CLOSE_OK=1)
grep -q 'MERGED-PR-CLOSE-AMBIGUOUS' <<<"$out" || fail "two deliveries must be LOUD ambiguous: $out"
[[ -s "$scratch/closes.log" ]] && fail "ambiguous deliveries must not close: $(cat "$scratch/closes.log")"
grep -q 'MERGED-PR-CLOSE-AMBIGUOUS' "$scratch/triage.md" || fail "ambiguous must land in triage: $(cat "$scratch/triage.md")"
ok "two delivery PRs -> AMBIGUOUS LOUD skip, no close"

# --- Case 8: merged PR outside the 7-day window -> leave open ---
set_fixtures "$NOOP_ISSUE" "$TRAILER_PR"
out=$(run FLEET_MERGED_PR_CLOSE_OK=1 TEST_NOW="2026-08-28T00:53:00Z")
# Shift the fixture mergedAt out of the window via TEST_NOW far ahead.
set_fixtures "$NOOP_ISSUE" \
  '[{"number":1429,"title":"feat: x (fleet-ops#1135)","body":"See fleet-ops#1135","mergedAt":"2026-07-01T00:22:21Z","url":"https://url/1429"}]'
out=$(run FLEET_MERGED_PR_CLOSE_OK=1)
grep -q 'no merged PR references it' <<<"$out" || fail "out-of-window should leave open: $out"
[[ -s "$scratch/closes.log" ]] && fail "out-of-window must not close: $(cat "$scratch/closes.log")"
ok "merged PR outside window -> no reference, issue left open"

# --- Case 9: reference matcher is exact-number (no false positives) ---
# A PR body mentioning #11352 or claim/issue-1135 must NOT count as a
# reference to issue 1135.
set_fixtures "$NOOP_ISSUE" \
  '[{"number":1429,"title":"feat: x","body":"backport of #11352; see claim/issue-1135","mergedAt":"2026-08-28T00:22:21Z","url":"https://url/1429"}]'
out=$(run FLEET_MERGED_PR_CLOSE_OK=1)
grep -q 'no merged PR references it' <<<"$out" || fail "exact-number matcher must not match #11352: $out"
[[ -s "$scratch/closes.log" ]] && fail "exact-number matcher must not close: $(cat "$scratch/closes.log")"
ok "reference matcher is exact-number (#11352 / claim/issue-1135 do not match 1135)"

# --- Case 9b: a `blocked-on: #N` line in a PR body is a bare mention ---
# fleet-ops#3231 exact shape: PR #3205 mentioned 3140/3146 because they
# carried `blocked-on: #3161` — a blocked-on line must never close.
set_fixtures "$NOOP_ISSUE" \
  '[{"number":1429,"title":"feat: x","body":"implements the blocker list; the dependents carry blocked-on: #1135","mergedAt":"2026-08-28T00:22:21Z","url":"https://url/1429"}]'
out=$(run FLEET_MERGED_PR_CLOSE_OK=1)
grep -q 'NOTE (mode=mention)' <<<"$out" || fail "blocked-on mention must be comment-only: $out"
[[ -s "$scratch/closes.log" ]] && fail "blocked-on line must not close: $(cat "$scratch/closes.log")"
ok "blocked-on: #N is a bare mention -> comment-only, never close"

# --- Case 9c: blocked-on as a CLAIM-word line ("Closes #N" IS a delivery) ---
set_fixtures "$NOOP_ISSUE" \
  '[{"number":1429,"title":"feat: x","body":"work\n\nCloses #1135","mergedAt":"2026-08-28T00:22:21Z","url":"https://url/1429","headRefName":"fix/a"}]'
out=$(run FLEET_MERGED_PR_CLOSE_OK=1)
grep -q 'CLOSED' <<<"$out" || fail "explicit Closes trailer must close: $out"
ok "explicit Closes trailer -> close"

# --- Case 10: PROTECTED issue (critical-path) — even a real delivery is
# comment-only, never closed (fleet-ops#3231, same rule as #3161) ---
set_fixtures \
  '[{"number":3140,"title":"critical packet","labels":[{"name":"critical-path"},{"name":"agent-in-progress"}],"body":"x","author":{"login":"nish3451"}}]' \
  '[{"number":1429,"title":"feat: packet work","body":"shipped work\n\nCloses #3140","mergedAt":"2026-08-28T00:22:21Z","url":"https://github.com/Nishfleet/fleet-ops/pull/1429","headRefName":"fix/rebuild-v2"}]'
out=$(run FLEET_MERGED_PR_CLOSE_OK=1)
[[ -s "$scratch/closes.log" ]] && fail "protected delivery must not close: $(cat "$scratch/closes.log")"
grep -q 'protected' <<<"$out" || fail "protected delivery must be logged as protected: $out"
grep -q 'protected' "$scratch/comments.log" || fail "protected delivery must post a protected note: $(cat "$scratch/comments.log")"
grep -q 'skipped_protected=1' <<<"$out" || fail "protected must count as skipped_protected: $out"
ok "critical-path issue + real delivery -> note only, never close"

# --- Case 10b: PROTECTED issue (nish3451-authored) — comment-only even with
# a claim-branch delivery ---
set_fixtures \
  '[{"number":3146,"title":"owner packet","labels":[{"name":"agent-in-progress"}],"body":"x","author":{"login":"nish3451"}}]' \
  '[{"number":3205,"title":"feat: owner work","body":"shipped work","mergedAt":"2026-09-04T10:29:00Z","url":"https://url/3205","headRefName":"claim/issue-3146"}]'
out=$(run FLEET_MERGED_PR_CLOSE_OK=1)
[[ -s "$scratch/closes.log" ]] && fail "owner-authored delivery must not close: $(cat "$scratch/closes.log")"
grep -q 'protected' "$scratch/comments.log" || fail "owner-authored delivery must post a protected note: $(cat "$scratch/comments.log")"
ok "nish3451-authored issue + claim-branch delivery -> note only, never close"

# --- Case 10c: mention notes are deduped per (issue, PR) across ticks ---
set_fixtures "$NOOP_ISSUE" \
  '[{"number":1429,"title":"feat: x (fleet-ops#1135)","body":"See fleet-ops#1135","mergedAt":"2026-08-28T00:22:21Z","url":"https://url/1429","headRefName":"fix/a"}]'
out=$(run FLEET_MERGED_PR_CLOSE_OK=1)
grep -q 'NOTE' <<<"$out" || fail "first tick must post the mention note: $out"
n1=$(wc -l <"$scratch/comments.log")
out=$(run FLEET_MERGED_PR_CLOSE_OK=1)
grep -q 'already posted' <<<"$out" || fail "second tick must dedupe the note: $out"
n2=$(wc -l <"$scratch/comments.log")
[[ "$n1" -eq 1 && "$n2" -eq 1 ]] || fail "note must be posted exactly once (n1=$n1 n2=$n2)"
ok "mention note deduped across ticks (1 comment, not spam)"

# --- Case 11: REGRESSION REPLAY — PR #3205 vs issues #3140/#3146/#3161 ---
# fleet-ops#3231 mandated replay: only 3161 closes. #3205 is the #3161
# claim-branch delivery; its body mentions fleet-ops#3140/#3146 only in
# prose (they carried `blocked-on: #3161`), and both are critical-path +
# nish3451-authored. #3140/#3146 get the protected note and stay open.
set_fixtures \
  '[{"number":3161,"title":"close-duplicates wrong-close","labels":[{"name":"agent-in-progress"}],"body":"x","author":{"login":"fleet-issue-bot"}},{"number":3140,"title":"packet A","labels":[{"name":"critical-path"},{"name":"agent-in-progress"}],"body":"blocked-on: #3161","author":{"login":"nish3451"}},{"number":3146,"title":"packet B","labels":[{"name":"critical-path"},{"name":"agent-in-progress"}],"body":"blocked-on: #3161","author":{"login":"nish3451"}}]' \
  '[{"number":3205,"title":"fix(close-duplicates): protect critical-path + owner issues (fleet-ops#3161)","body":"close-duplicates once closed 18 issues (incl. two Nish-endorsed critical-path packets, fleet-ops#3140 and #3146) as score=1.00 duplicates.\n\nCloses #3161","mergedAt":"2026-09-04T10:29:00Z","url":"https://github.com/Nishfleet/fleet-ops/pull/3205","headRefName":"claim/issue-3161"}]'
out=$(run FLEET_MERGED_PR_CLOSE_OK=1)
grep -q 'issue close 3161' "$scratch/closes.log" || fail "3161 must close (claim-branch delivery): $(cat "$scratch/closes.log")"
grep -q 'issue close 3140' "$scratch/closes.log" && fail "3140 must NOT close (protected + mere mention): $(cat "$scratch/closes.log")"
grep -q 'issue close 3146' "$scratch/closes.log" && fail "3146 must NOT close (protected + mere mention): $(cat "$scratch/closes.log")"
grep -q 'pull/3205\|(#3205)' "$scratch/comments.log" || fail "3140/3146 must get the note for PR #3205: $(cat "$scratch/comments.log")"
grep -q 'protected' "$scratch/comments.log" || fail "3140/3146 note must say protected: $(cat "$scratch/comments.log")"
grep -q "CLOSED (delivered by merged PR #3205 via claim-branch)" <<<"$out" || fail "3161 close must be via claim-branch: $out"
ok "regression replay #3205 vs #3140/#3146/#3161: only 3161 closes, packets stay open"

# --- Case 11b: summary JSON reflects the replay (only legal reasons > 0) ---
grep -q '"claim-branch":1' "$scratch/summary.json" || fail "replay summary must count claim-branch=1: $(cat "$scratch/summary.json")"
grep -q '"bare-mention":0' "$scratch/summary.json" || fail "replay summary must keep bare-mention=0: $(cat "$scratch/summary.json")"
grep -q '"protected":0' "$scratch/summary.json" || fail "replay summary must keep protected=0: $(cat "$scratch/summary.json")"
ok "replay summary: closes_by_reason legal-only"

# --- Case 12: crash paths fail closed with rc 2 ---
# gh missing
set_fixtures "$NOOP_ISSUE" "$TRAILER_PR"
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

# --- Case 13: contracts — tier1 call + MANIFEST entry ---
grep -q 'fleet-merged-pr-close' "$repo_root/bin/fleet-heartbeat-tier1" \
  || fail "tier1 must call fleet-merged-pr-close"
grep -q 'FLEET_MERGED_PR_CLOSE_OK=1' "$repo_root/bin/fleet-heartbeat-tier1" \
  || fail "tier1 must set FLEET_MERGED_PR_CLOSE_OK=1"
grep -q 'MERGED_PR_CLOSE_SUMMARY="$LOG_DIR/merged-pr-close.json"' "$repo_root/bin/fleet-heartbeat-tier1" \
  || fail "tier1 must pass the summary JSON path (fleet-ops#3231)"
grep -q 'bin/fleet-merged-pr-close' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/fleet-merged-pr-close"
ok "contracts: tier1 call + close gate + summary path + MANIFEST entry present"

# --- Case 14: tick-log fd 3 must be APPEND mode (fleet-ops#2080) ---
# tier1 opens `exec 3>>"$TICK_LOG"` and invokes the helper with `2>>"$TICK_LOG"`.
# A truncate-write `exec 3>` would let fd 3's offset overwrite the helper's
# appended lines, hiding the per-issue output from every tick log. Prove the
# open mode is append so the helper's stderr survives.
grep -q 'exec 3>>"\$TICK_LOG"' "$repo_root/bin/fleet-heartbeat-tier1" \
  || fail "tier1 must open fd 3 in append mode (exec 3>>): $(grep -n 'exec 3' "$repo_root/bin/fleet-heartbeat-tier1")"
# Reproduce the collision class directly: fd 3 append + helper append must
# both preserve their lines in the shared file.
fdtest=$(mktemp)
: > "$fdtest"
exec 4>>"$fdtest"   # simulate tier1's append fd 3
printf '%s\n' "tier1-line-1" >&4
printf '%s\n' "helper-line-appended" >>"$fdtest"   # simulate helper's 2>>
printf '%s\n' "tier1-line-2" >&4
exec 4>&-
grep -q 'helper-line-appended' "$fdtest" || fail "append-mode fd 3 must preserve helper-appended lines"
grep -q 'tier1-line-2' "$fdtest" || fail "append-mode fd 3 must preserve tier1's own lines"
rm -f "$fdtest"
ok "tick-log fd 3 is append mode — helper stderr survives the collision"

echo "all fleet-merged-pr-close cases passed"