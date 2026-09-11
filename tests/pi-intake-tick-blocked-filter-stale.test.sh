#!/usr/bin/env bash
# tests/pi-intake-tick-blocked-filter-stale.test.sh
#
# fleet-ops#4395 belt-and-braces: the intake tick's blocked_filter must NOT
# count a `blocked-on:` line whose target issue/PR is CLOSED/MERGED as a live
# blocker. blocked-reconcile owns the agent-blocked label and clears closed-ref
# blockers on its sweep, but the intake-side guard must not re-claim an issue
# whose blocker is already resolved (the stale-label window). This test drives
# the enhanced blocked_filter with a stubbed gh and proves:
#   - no blocked-on line -> claimable
#   - blocked-on a CLOSED issue -> stale, claimable
#   - blocked-on an OPEN issue -> blocked
#   - blocked-on a MERGED PR -> stale, claimable
#   - blocked-on a CLOSED-UNMERGED PR -> blocked (fleet-ops#364)
#   - blocked-on: nish-decision / orchestrator / infra / senior-review -> blocked
#   - mixed closed+open -> blocked
#   - all closed -> stale, claimable
#   - cross-repo closed ref -> stale, claimable
#   - gh lookup failure -> blocked (fail-safe, never claim on a lookup error)
#   - the tick calls blocked_filter with the repo + issue number context
#   - shellcheck is clean on the tick
# fleet-ops#3575: comment-level blocked-on lines must also block (the worker
#   bounce protocol puts machine-readable blocked-on: lines in a COMMENT, not
#   the body). Prove:
#   - blocked-on only in comments (open target)   -> blocked
#   - blocked-on only in comments (closed target) -> stale, claimable
#   - the tick passes the LATEST comment (not the joined history) to
#     blocked_filter: a released agent-ready issue (DECISION then relabel)
#     must not stay skipped-blocked-on because older comments still say
#     `blocked-on: orchestrator` / `blocked-on: split` (0509#1383/#1981)

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

# === Test 1: the tick calls blocked_filter with repo + issue + LATEST comment ==
grep -qF 'blocked_filter "$body" "$FULL" "$N" "$last_comment"' "$tick" \
    || fail "tick must call blocked_filter with last_comment only (historical bounce lines must not skip a released issue)"
grep -qF '.comments[-1].body' "$tick" \
    || fail "tick must take comments[-1].body as last_comment (newest comment)"
ok "Test 1: tick passes repo + issue number + latest comment to blocked_filter"

# === Test 2: blocked_filter resolves closed/merged targets via stubbed gh ====
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin"

cat >"$scratch/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_DIR/gh.log"
case "$1" in
  api)
    path="$2"
    case "$path" in
      repos/Nishfleet/0509/issues/10) echo '{"state":"closed"}'; exit 0 ;;
      repos/Nishfleet/fleet-ops/issues/10) echo '{"state":"closed"}'; exit 0 ;;
      repos/Nishfleet/0509/issues/11) echo '{"state":"open"}'; exit 0 ;;
      repos/Nishfleet/0509/issues/12) echo '{"state":"closed","pull_request":{}}'; exit 0 ;;
      repos/Nishfleet/0509/pulls/12) echo '{"state":"closed","merged":true}'; exit 0 ;;
      repos/Nishfleet/0509/issues/13) echo '{"state":"closed","pull_request":{}}'; exit 0 ;;
      repos/Nishfleet/0509/pulls/13) echo '{"state":"closed","merged":false}'; exit 0 ;;
      repos/Nishfleet/0509/issues/14) echo '{"state":"open"}'; exit 0 ;;
      repos/Nishfleet/0509/issues/15) echo '{"state":"closed"}'; exit 0 ;;
      *) echo '{"message":"Not Found"}' >&2; exit 1 ;;
    esac ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$scratch/bin/gh"
export FAKE_DIR="$scratch"
export PATH="$scratch/bin:$PATH"

# Extract the blocked_filter function body from the tick (the tick runs
# top-level, so it cannot be sourced directly).
awk '/^blocked_filter\(\)/,/^}/' "$tick" >"$scratch/blocked_filter.sh"
# fleet-ops#5489: blocked_filter reads via the _gh_read seam; give the sourced
# extract a matching passthrough (the stub gh above answers for both).
_gh_read() { gh "$@"; }
source "$scratch/blocked_filter.sh"

# 2a. no blocked-on -> claimable
if blocked_filter "no blocker here" "Nishfleet/0509" "50"; then
    fail "no blocked-on line must be claimable"
fi
ok "Test 2a: no blocked-on -> claimable"

# 2b. blocked-on a CLOSED issue -> stale, claimable
if blocked_filter "blocked-on: #10" "Nishfleet/0509" "50"; then
    fail "closed issue dep must be stale (claimable)"
fi
ok "Test 2b: closed issue dep -> stale, claimable"

# 2c. blocked-on an OPEN issue -> blocked
if ! blocked_filter "blocked-on: #11" "Nishfleet/0509" "50"; then
    fail "open issue dep must stay blocked"
fi
ok "Test 2c: open issue dep -> blocked"

# 2d. blocked-on a MERGED PR -> stale, claimable
if blocked_filter "blocked-on: https://github.com/Nishfleet/0509/pull/12" "Nishfleet/0509" "50"; then
    fail "merged PR dep must be stale (claimable)"
fi
ok "Test 2d: merged PR dep -> stale, claimable"

# 2e. blocked-on a CLOSED-UNMERGED PR -> blocked (fleet-ops#364)
if ! blocked_filter "blocked-on: https://github.com/Nishfleet/0509/pull/13" "Nishfleet/0509" "50"; then
    fail "closed-unmerged PR dep must stay blocked"
fi
ok "Test 2e: closed-unmerged PR dep -> blocked"

# 2f. blocked-on: nish-decision -> blocked
if ! blocked_filter "blocked-on: nish-decision" "Nishfleet/0509" "50"; then
    fail "nish-decision marker must stay blocked"
fi
ok "Test 2f: nish-decision -> blocked"

# 2g. blocked-on: orchestrator -> blocked
if ! blocked_filter "blocked-on: orchestrator" "Nishfleet/0509" "50"; then
    fail "orchestrator marker must stay blocked"
fi
ok "Test 2g: orchestrator -> blocked"

# 2h. mixed closed + open -> blocked
if ! blocked_filter "blocked-on: #10
blocked-on: #11" "Nishfleet/0509" "50"; then
    fail "mixed closed+open must stay blocked"
fi
ok "Test 2h: mixed closed+open -> blocked"

# 2i. all closed -> stale, claimable
if blocked_filter "blocked-on: #10
blocked-on: #12" "Nishfleet/0509" "50"; then
    fail "all-closed deps must be stale (claimable)"
fi
ok "Test 2i: all closed -> stale, claimable"

# 2j. cross-repo closed ref -> stale, claimable
if blocked_filter "blocked-on: Nishfleet/fleet-ops#10" "Nishfleet/0509" "50"; then
    fail "cross-repo closed dep must be stale (claimable)"
fi
ok "Test 2j: cross-repo closed -> stale, claimable"

# 2k. gh lookup failure -> blocked (fail-safe)
if ! blocked_filter "blocked-on: #999" "Nishfleet/0509" "50"; then
    fail "gh lookup failure must stay blocked (fail-safe)"
fi
ok "Test 2k: gh lookup failure -> blocked (fail-safe)"

# fleet-ops#4626: date-gate. A past re-open-<ISO> is stale (claimable) so a
# flipped issue whose body still carries the spent gate is not re-wedged.
# A future gate stays blocked. Unknown form stays blocked (fail-safe).
# Freeze "now" by wrapping date only when we need a known clock: the filter
# uses `date -u +%s` / `date -u -d`. We assert against the live clock by
# picking timestamps firmly in the past and the far future.
if blocked_filter "blocked-on: re-open-2020-01-01T00:00:00Z-alibaba-smoke-ok" "Nishfleet/fleet-ops" "4447"; then
    fail "past date-gate must be stale (claimable) so a flipped issue can be claimed"
fi
ok "Test 2k-date: past re-open-<ISO> -> stale, claimable"

if ! blocked_filter "blocked-on: re-open-2099-01-01T00:00:00Z-alibaba-smoke-ok" "Nishfleet/fleet-ops" "4447"; then
    fail "future date-gate must stay blocked"
fi
ok "Test 2k-date: future re-open-<ISO> -> blocked"

if ! blocked_filter "blocked-on: wait-for-the-moon" "Nishfleet/fleet-ops" "50"; then
    fail "unknown blocked-on form must stay blocked (fail-safe)"
fi
ok "Test 2k-date: unknown form -> blocked"

# === fleet-ops#3575: comment-level blocked-on lines ==========================
# The worker bounce protocol writes machine-readable blocked-on: lines in a
# COMMENT. A body-only scan lets such an issue re-claim forever. blocked_filter
# must scan comments (4th arg) the same way it scans the body, incl. its
# live-state staleness resolution.

# 2i. blocked-on only in comments, OPEN target -> blocked
if ! blocked_filter "body has no blocker" "Nishfleet/0509" "50" "bounce: dep open
blocked-on: #14"; then
    fail "comment-level blocked-on (open target) must stay blocked"
fi
ok "Test 2l: comment blocked-on (open) -> blocked"

# 2j. blocked-on only in comments, CLOSED target -> stale, claimable
if blocked_filter "body has no blocker" "Nishfleet/0509" "50" "blocked-on: #15"; then
    fail "comment-level blocked-on (closed target) must be stale (claimable)"
fi
ok "Test 2m: comment blocked-on (closed) -> stale, claimable"

# 2k. mixed body + comment blockers, all closed -> stale, claimable
if blocked_filter "blocked-on: #10" "Nishfleet/0509" "50" "blocked-on: #15"; then
    fail "body+comment all-closed blockers must be stale (claimable)"
fi
ok "Test 2n: body+comment all-closed -> stale, claimable"

# 2l. no comments arg -> unchanged single-scan behavior (backward compat)
if blocked_filter "no blocker here" "Nishfleet/0509" "50"; then
    fail "no blocked-on anywhere must be claimable"
fi
ok "Test 2o: no comments arg -> unchanged body-only behavior"

# === split marker: a spec-gate bounce record, not an independent blocker ====
# `blocked-on: split` is written by the agent-ready spec gate when an issue
# carries >2 live required: lines. The gate re-counts and re-bounces
# (agent-blocked, no claim) on EVERY tick before any claim, so the marker only
# records that bounce. Treating it as a live blocker wedges an issue whose
# split was rejected by a judge decision — 0509#1383 sat agent-ready but
# unclaimable for 7h on 4 stale split-marker comments (2026-09-08).

# 2p. blocked-on: split in body -> claimable (gate re-bounces if still oversized)
if blocked_filter "blocked-on: split" "Nishfleet/0509" "50"; then
    fail "split marker must be claimable (spec gate owns the bounce)"
fi
ok "Test 2p: blocked-on: split (body) -> claimable"

# 2q. blocked-on: split only in comments -> claimable
if blocked_filter "body has no blocker" "Nishfleet/0509" "50" "split me: 3 requirements
blocked-on: split"; then
    fail "comment split marker must be claimable"
fi
ok "Test 2q: blocked-on: split (comments) -> claimable"

# 2r. split + open issue ref -> still blocked by the open ref
if ! blocked_filter "blocked-on: split
blocked-on: #11" "Nishfleet/0509" "50"; then
    fail "split + open ref must stay blocked"
fi
ok "Test 2r: split + open ref -> blocked"

# === Test 3: shellcheck ======================================================
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$tick" --severity=warning
    ok "Test 3: shellcheck clean"
else
    echo "SKIP: Test 3: shellcheck not installed"
fi

echo ""
echo "ALL OK: intake blocked_filter treats closed/merged blocker targets as stale"
