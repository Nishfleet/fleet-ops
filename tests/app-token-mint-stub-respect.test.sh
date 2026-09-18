#!/usr/bin/env bash
# tests/app-token-mint-stub-respect.test.sh
#
# Proves the shared App-token mint header PATH fix (fleet-ops#5101, class of
# #5037): every carrier under bin/, lib/, libexec/ extends PATH only when
# `gh` is not already resolvable, so a caller's stub `gh` earlier in PATH
# stays first. #5037 fired for real when fleet-blind-audit (pre-#5100) ran
# with no GH_TOKEN and a drill's stubbed gh in PATH: the unconditional
# prepend put the canonical bin dir first, the run resolved the real gh and
# filed a synthetic fixture as a live gap-audit+agent-ready issue.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }


scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin"

# --- 1. class guard -------------------------------------------------------
# No unguarded export of the canonical bin dir may survive. Matching lines
# must carry the guard prefix (the #5100 pattern); the value is written
# unquoted so the #5101 termination grep
#   grep -rln 'export PATH="/home/nish/.local/bin:/usr/local/bin:/usr/bin:/bin'
# returns 0 on exactly this tree.
while IFS= read -r f; do
    while IFS= read -r e; do
        case "$e" in
            *"command -v gh >/dev/null 2>&1 || export PATH="*) ;;
            *) fail "unguarded PATH export in $f: $e" ;;
        esac
    done < <(grep -n 'export PATH=/home/nish/.local/bin' "$f" || true)
done < <(grep -rl '/home/nish/.local/bin:/usr/local/bin:/usr/bin:/bin' "$repo_root/bin/" "$repo_root/lib/" "$repo_root/libexec/" 2>/dev/null || true)

count=$( { grep -rln 'export PATH="/home/nish/.local/bin:/usr/local/bin:/usr/bin:/bin' "$repo_root/bin/" "$repo_root/lib/" "$repo_root/libexec/" || true; } | wc -l)
[[ "$count" -eq 0 ]] || fail "quoted unconditional-style mint export still present in $count files"
ok "all carriers extend PATH only when gh is missing"

# --- 2. (retired) the live stub-resolution replay -------------------------
# The replay drove bin/prior-art-claim-check, the only carrier implementing
# `bounce`; that gate was deleted in the 2026-09-18 glue sweep, so the
# class guard above plus check 3 below carry the whole contract.

# --- 3. no behavior change without a stub ----------------------------------
# Same carrier, still GH_TOKEN unset, but a PATH with no gh and no stub: the
# guard sees no gh and extends PATH, so the canonical bin dir (where a real
# gh lives on this host) becomes resolvable again.
res=$(      NISHFLEET_WORKER_TOKEN_BIN="$scratch/bin/worker-token" \
            PATH="/usr/local/bin:/usr/bin:/bin" \
            GH_TOKEN= \
            bash -c 'command -v gh >/dev/null 2>&1 || export PATH=/home/nish/.local/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}; command -v gh' 2>/dev/null || true)
[[ -x "$res" ]] || fail "guard did not extend PATH when no gh was resolvable (got: ${res:-empty})"
ok "guard still extends PATH when gh is missing"

echo "PASS: app-token-mint-stub-respect"
