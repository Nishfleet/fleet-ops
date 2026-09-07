#!/usr/bin/env bash
# tests/claim-pr-head-owner.test.sh
#
# Proves the GitHub `head=` PR filter always names the repository OWNER, not
# the repository name.
#
# Root cause (session-waste research, 2026-09-07): every open-PR probe on a
# claim branch was written as `head=<repo>:claim/issue-<N>`. The REST API
# expects `head=<owner>:<branch>`, so the filter matched nothing and every
# probe returned an empty list. Three call sites all read "no open PR":
#   * lib/pi-intake-tick.sh  -> skipped-claim-pr-open never fired, so intake
#     deleted the claim branch of a live PR and re-claimed finished work;
#   * bin/pi-issue-run       -> "SUCCESS but no open PR" on runs that shipped;
#   * bin/pi-issue-failed-reap -> reaped branches that had an open PR.
# Live proof at the time: head=0509:claim/issue-1894 -> 0 results,
# head=Nishfleet:claim/issue-1894 -> 1 result (PR Nishfleet/0509#1904 OPEN).
#
# (a) no call site passes a bare repo name in the head= filter;
# (b) every head= filter resolves to the owner segment;
# (c) the shell expansions used actually yield "Nishfleet".

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
fail=0

mapfile -t hits < <(grep -rn 'pulls?state=open&head=' "$repo_root/bin" "$repo_root/lib" || true)
if (( ${#hits[@]} == 0 )); then
    echo "FAIL: no head= PR probes found — test is stale" >&2
    exit 1
fi

for line in "${hits[@]}"; do
    frag="${line#*head=}"; frag="${frag%%:*}"
    case "$frag" in
        'Nishfleet'|'${repo_slug%/*}'|'${FULL%%/*}'|'${repo_slug%%/*}')
            echo "ok  owner-scoped head filter: $line" ;;
        *)
            echo "FAIL: head= filter is not owner-scoped: $line" >&2
            fail=1 ;;
    esac
done

# (b) the repo name must never appear as the head owner.
if grep -rn 'head=\${pkt_repo}:\|head=\${REPO}:\|head=\${FULL#\*/}:\|head=\${repo_slug#\*/}:' \
        "$repo_root/bin" "$repo_root/lib" >/dev/null 2>&1; then
    echo "FAIL: a head= filter still uses the repo name as the owner" >&2
    fail=1
fi

# (c) the expansions really produce the owner.
repo_slug="Nishfleet/fleet-ops"; FULL="Nishfleet/0509"
[[ "${repo_slug%/*}" == "Nishfleet" ]]  || { echo "FAIL: repo_slug%/* != Nishfleet" >&2; fail=1; }
[[ "${repo_slug%%/*}" == "Nishfleet" ]] || { echo "FAIL: repo_slug%%/* != Nishfleet" >&2; fail=1; }
[[ "${FULL%%/*}" == "Nishfleet" ]]      || { echo "FAIL: FULL%%/* != Nishfleet" >&2; fail=1; }

if (( fail )); then
    echo "claim-pr-head-owner.test.sh FAILED" >&2
    exit 1
fi
echo "claim-pr-head-owner.test.sh PASSED (${#hits[@]} head= probes checked)"
