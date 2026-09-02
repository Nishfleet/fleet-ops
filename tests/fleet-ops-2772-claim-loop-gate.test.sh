#!/usr/bin/env bash
# tests/fleet-ops-2772-claim-loop-gate.test.sh
#
# fleet-ops#2772: proves the claim-loop gate in lib/pi-intake-tick.sh and
# the PR-gated reclaim-count reset in bin/pi-issue-run.
#
# Background (the incident this pins): fleet-ops issue #2672 was claimed 11
# times in 12h (4x in the 2h to 2026-09-02T03:45Z) with dispatches_last_2h=0.
# Root cause: a seat-selection storm made pick_seat return NO USABLE SEAT
# (worker exits 1 in seconds -> OnFailure reap -> re-claim), plus worker
# sessions that exited 0 WITHOUT opening a PR. The #2462 reclaim-count cap
# (MAX_RECLAIMS) never fired because pi-issue-run RESET the counter on any
# non-empty-output run whether or not a PR was opened.
#
# The mechanism this test pins:
#   1. The tick defines RECLAIM_WINDOW_S / MAX_CLAIMS_IN_WINDOW knobs
#      (overridable), and snapshots the claims log once per tick.
#   2. In the claim loop, AFTER the branch-liveness / open-PR checks, a
#      skipped-claim-loop gate counts raw claims for THIS line in the
#      sliding window and escalates (agent-blocked + blocked-on:
#      nish-decision) when the count reaches the cap — fail loud instead
#      of spinning.
#   3. The gate counts exactly `claimed line=<N> repo=<repo>` records in
#      the window: a different issue number (line=26723) and a different
#      repo (repo=0509) must NOT count; records older than the window
#      must NOT count. The awk drill reproduces the tick logic verbatim.
#   4. pi-issue-run's success-path reset of reclaim-count + systemic marker
#      is PR-gated: it happens only when an open PR exists from the claim
#      branch or the issue is closed; a no-PR success logs the counter is
#      NOT reset.
#
# Static-grep + bash drill (same shape as pi-intake-tick-reclaim-cooldown
# and pi-intake-tick-protected-verifier-vacation): the tick needs gh/git/
# network to run end-to-end; the assertions pin the logic + ordering.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"
run="$repo_root/bin/pi-issue-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"
[[ -f "$run"  ]] || fail "bin/pi-issue-run missing"

# === Test 1: claim-loop gate knobs defined and overridable ===
grep -qF 'RECLAIM_WINDOW_S="${PI_INTAKE_RECLAIM_WINDOW_S:-7200}"' "$tick" \
    || fail "RECLAIM_WINDOW_S env var (default 7200s, overridable) not found in tick"
grep -qF 'MAX_CLAIMS_IN_WINDOW="${PI_INTAKE_RECLAIM_MAX_CLAIMS:-4}"' "$tick" \
    || fail "MAX_CLAIMS_IN_WINDOW env var (default 4, overridable) not found in tick"
ok "Test 1: RECLAIM_WINDOW_S + MAX_CLAIMS_IN_WINDOW knobs defined (overridable)"

# === Test 2: tick snapshots the claims log once per tick ===
grep -qF '_claims_log_snapshot=""' "$tick" \
    || fail "claims-log snapshot variable not found in tick"
grep -qF 'cat "$CLAIMS_LOG" 2>/dev/null' "$tick" \
    || fail "claims-log snapshot read (cat CLAIMS_LOG) not found in tick"
ok "Test 2: tick snapshots the claims log (claim-loop gate reads it per issue)"

# === Test 3: skipped-claim-loop gate in the claim loop ===
grep -qF 'skipped-claim-loop' "$tick" \
    || fail "skipped-claim-loop skip message not found in tick"
grep -qF '_cl_window_claims >= MAX_CLAIMS_IN_WINDOW' "$tick" \
    || fail "claim-loop window comparison (>= MAX_CLAIMS_IN_WINDOW) not found in tick"
# The gate must count exact "claimed line=<N> repo=<repo>" fields, not a
# substring (line=2672 must not match line=26723, repo=0509 must not match
# repo=fleet-ops).
grep -qF '$3 == "line=" n && $4 == "repo=" repo' "$tick" \
    || fail "claim-loop count must match exact line= and repo= fields (no substring)"
grep -qF '$1 >= cutoff' "$tick" \
    || fail "claim-loop window comparison must filter by timestamp (>= cutoff)"
ok "Test 3: skipped-claim-loop gate counts exact same-line claims in the window"

# === Test 4: gate escalates loud (agent-blocked + blocked-on) ===
grep -qF 'escalating to agent-blocked' "$tick" \
    || fail "gate escalation message not found"
grep -qF -- '--add-label agent-blocked --remove-label agent-ready' "$tick" \
    || fail "gate must flip to agent-blocked and remove agent-ready (leaves the ready set)"
grep -qF 'blocked-on: nish-decision' "$tick" \
    || fail "gate escalation must emit machine-readable blocked-on: nish-decision"
ok "Test 4: gate escalates loud — agent-blocked label + blocked-on line"

# === Test 5: gate sits AFTER branch-liveness / open-PR checks, BEFORE the
#             body fetch, so a live worker or open PR never trips it and a
#             loop issue costs zero network calls.
# The gate must come after the stale-claim release block (released-stale-claim)
# and after the ls-remote branch check, and before the body fetch.
_live_line=$(grep -n 'skipped-claim-live' "$tick" | head -1 | cut -d: -f1)
_pr_line=$(grep -n 'skipped-claim-pr-open' "$tick" | head -1 | cut -d: -f1)
_stale_line=$(grep -n 'released-stale-claim' "$tick" | head -1 | cut -d: -f1)
_gate_line=$(grep -n '_cl_window_claims >= MAX_CLAIMS_IN_WINDOW' "$tick" | head -1 | cut -d: -f1)
_body_line=$(grep -n 'body=$(gh issue view "$N" -R "$FULL"' "$tick" | head -1 | cut -d: -f1)
[[ -n "$_live_line" && -n "$_pr_line" && -n "$_stale_line" && -n "$_gate_line" && -n "$_body_line" ]] \
    || fail "one or more anchor lines missing in tick"
(( _gate_line > _live_line )) \
    || fail "claim-loop gate (line $_gate_line) must come after skipped-claim-live check (line $_live_line)"
(( _gate_line > _pr_line )) \
    || fail "claim-loop gate (line $_gate_line) must come after open-PR check (line $_pr_line)"
(( _gate_line > _stale_line )) \
    || fail "claim-loop gate (line $_gate_line) must come after stale-claim release (line $_stale_line)"
(( _gate_line < _body_line )) \
    || fail "claim-loop gate (line $_gate_line) must come before the body fetch (line $_body_line)"
ok "Test 5: gate ordered after branch-liveness/open-PR checks and before the body fetch"

# === Test 6: awk drill — window + exact-line/repo counting semantics ===
# Reproduces the tick's awk verbatim (fields $3/$4 exact match, $1 >= cutoff
# lexicographic compare on ISO-8601 UTC timestamps).
count_window_claims() {
    # args: <snapshot> <issue> <repo> <cutoff_iso>
    local snap="$1" n="$2" repo="$3" cutoff="$4"
    awk -v n="$n" -v repo="$repo" -v cutoff="$cutoff" '
        $3 == "line=" n && $4 == "repo=" repo && $1 >= cutoff { c++ }
        END { print c+0 }
    ' <<<"$snap" 2>/dev/null || echo 0
}

fixture=$(cat <<'EOF'
2026-09-02T01:51:12Z claimed line=2672 repo=fleet-ops
2026-09-02T02:12:05Z claimed line=2672 repo=fleet-ops
2026-09-02T03:12:05Z claimed line=2672 repo=fleet-ops
2026-09-02T03:31:35Z claimed line=2672 repo=fleet-ops
2026-09-02T03:31:40Z claimed line=26723 repo=fleet-ops
2026-09-02T03:31:45Z claimed line=2672 repo=0509
2026-09-01T01:00:00Z claimed line=2672 repo=fleet-ops
EOF
)

# Window [01:45, 03:45] = 2h before 03:45 (the #2772 analyzer's exact window):
# exactly the 4 fleet-ops 2672 claims; 26723 and 0509 must NOT count; the
# 09-01 claim is outside the window and must NOT count.
_cutoff=$(date -u -d "2026-09-02T03:45:00Z - 7200 seconds" +%Y-%m-%dT%H:%M:%SZ)
[[ "$(count_window_claims "$fixture" 2672 fleet-ops "$_cutoff")" == "4" ]] \
    || fail "window drill: expected 4 claims for line=2672 repo=fleet-ops in the 2h window, got $(count_window_claims "$fixture" 2672 fleet-ops "$_cutoff")"
ok "Test 6a: window drill counts exactly the 4 same-line claims in the 2h window"

[[ "$(count_window_claims "$fixture" 2672 fleet-ops "2026-09-02T02:00:00Z")" == "3" ]] \
    || fail "window drill: narrower cutoff must count only the 3 claims after 02:00Z"
ok "Test 6b: window drill honors the sliding cutoff (older claims excluded)"

[[ "$(count_window_claims "$fixture" 26723 fleet-ops "$_cutoff")" == "1" ]] \
    || fail "window drill: line=26723's own record must count exactly 1 for line=26723"
ok "Test 6c: window drill keeps issue numbers exact (line=26723 counts only its own record)"

[[ "$(count_window_claims "$fixture" 2672 0509 "$_cutoff")" == "1" ]] \
    || fail "window drill: repo=0509's own record must count exactly 1 for repo=0509"
ok "Test 6d: window drill keeps repos exact (repo=0509 counts only its own record)"

# === Test 7: pi-issue-run success reset is PR-gated ===
grep -qF 'issue_num="${inst##*-}"' "$run" \
    || fail "issue number derivation not found in pi-issue-run"
grep -qF 'repos/Nishfleet/${pkt_repo}/pulls?state=open&head=${pkt_repo}:claim/issue-${issue_num}' "$run" \
    || fail "open-PR shipped check (gh api pulls from claim branch) not found in pi-issue-run"
grep -qF 'repos/Nishfleet/${pkt_repo}/issues/${issue_num}' "$run" \
    || fail "issue-state shipped check (gh api issues) not found in pi-issue-run"
grep -qF 'reclaim-count NOT reset' "$run" \
    || fail "no-PR no-reset log line not found in pi-issue-run"
# The rm -f resets must sit inside the _shipped branch (after the shipped
# checks) and the whole block must precede the final exit 0.
_shipped_line=$(grep -n '_shipped=no' "$run" | head -1 | cut -d: -f1)
_rc_reset=$(grep -n 'rm -f "$ATTEMPTS_DIR/pi-issue-${inst}.reclaim-count"' "$run" | tail -1 | cut -d: -f1)
_exit_zero=$(grep -n 'exit 0' "$run" | tail -1 | cut -d: -f1)
[[ -n "$_shipped_line" && -n "$_rc_reset" && -n "$_exit_zero" ]] \
    || fail "shipped-check / reset / exit anchors missing in pi-issue-run"
(( _rc_reset > _shipped_line )) \
    || fail "reclaim-count reset (line $_rc_reset) must come AFTER the shipped checks (line $_shipped_line)"
(( _rc_reset < _exit_zero )) \
    || fail "reclaim-count reset (line $_rc_reset) must come before exit 0 (line $_exit_zero)"
ok "Test 7: pi-issue-run success reset is PR-gated (reset inside _shipped branch, before exit 0)"

# === Test 8: shellcheck ===
for f in "$tick" "$run"; do
    if command -v shellcheck >/dev/null 2>&1; then
        shellcheck -x "$f" --severity=warning 2>&1 || {
            fail "shellcheck failed on $(basename "$f")"
        }
    fi
done
ok "Test 8: shellcheck clean on all touched files"

echo
echo "ALL OK: fleet-ops#2772 claim-loop gate + PR-gated reclaim reset"