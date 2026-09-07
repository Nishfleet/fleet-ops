#!/usr/bin/env bash
# tests/venue-claim-open-question-deleted.test.sh
#
# fleet-ops#4143 (child of #4140 row 3): the hand-built claim/lock/queue
# scripts `venue-claim` (1,008 lines) and `open-question` (802 lines) were
# retired. They were live-only (never tracked in this repo) and orphaned (no
# systemd units, no data dir). The fleet already runs claim/lock/queue on
# GitHub issue assignment + Projects, Actions concurrency groups, and
# flock/systemd for local locks.
#
# This test pins the retirement so a future rebuild is caught:
#   1. No venue-claim / open-question / venue-ledger script in the repo's
#      active code dirs (bin/, lib/, libexec/).
#   2. No reference to them in active code paths (prompts/, config/,
#      systemd/, MANIFEST).
#   3. The design doc row 3 is marked DONE.
#
# A rebuild that re-adds any of these to active code without a Nish-endorsed
# exception fails this test. The machinery-authorization-gate (fleet-ops#1548)
# is the mechanical prevention; this test is the deletion pin.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# --- 1. no script in active code dirs --------------------------------------
for name in venue-claim open-question venue-ledger; do
  for dir in bin lib libexec; do
    f="$repo_root/$dir/$name"
    if [[ -e "$f" ]]; then
      fail "active code must not carry $f - $name was retired (#4143)"
    fi
  done
done
ok "no venue-claim/open-question/venue-ledger script in bin/, lib/, libexec/"

# --- 2. no reference in active code paths -----------------------------------
# The design doc (docs/design/hand-built-vs-off-the-shelf.md) and the
# retired/ archive are the retirement record and are allowed. Everything else
# must be clean.
for path in prompts config systemd MANIFEST; do
  if grep -rn 'venue-claim\|venue-ledger' "$repo_root/$path" >/dev/null 2>&1; then
    fail "active code path $path must not reference venue-claim/venue-ledger - retired (#4143)"
  fi
done
# open-question: allow the loose-ends canary's distinct "open-question" kind
# (open questions in memory files), the open-question-sweep deletion pin, and
# the "open-questions" memory section; reject any reference to the retired
# script itself (open-question NOT followed by -sweep or -s).
if grep -rnE 'open-question([^-s]|$)' "$repo_root/prompts" "$repo_root/config" "$repo_root/systemd" "$repo_root/MANIFEST" >/dev/null 2>&1; then
  fail "active code path must not reference the open-question script - retired (#4143)"
fi
ok "no reference to the retired scripts in prompts/, config/, systemd/, MANIFEST"

# --- 3. design doc row 3 is marked DONE -------------------------------------
if ! grep -q 'venue-claim + open-question.*DONE' "$repo_root/docs/design/hand-built-vs-off-the-shelf.md"; then
  fail "design doc row 3 must be marked DONE (#4143)"
fi
ok "design doc row 3 is marked DONE"

exit 0
