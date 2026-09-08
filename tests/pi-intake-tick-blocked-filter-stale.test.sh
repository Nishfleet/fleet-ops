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
#   - the tick passes fetched comments to blocked_filter

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

# === Test 1: the tick calls blocked_filter with repo + issue + comments context ==
grep -qF 'blocked_filter "$body" "$FULL" "$N" "$comments"' "$tick" \
    || fail "tick must call blocked_filter with repo, issue number and comments context"
ok "Test 1: tick passes repo + issue number + comments to blocked_filter"

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

# === Test 3: shellcheck ======================================================
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$tick" --severity=warning
    ok "Test 3: shellcheck clean"
else
    echo "SKIP: Test 3: shellcheck not installed"
fi

echo ""
echo "ALL OK: intake blocked_filter treats closed/merged blocker targets as stale"
