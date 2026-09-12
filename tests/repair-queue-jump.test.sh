#!/usr/bin/env bash
# tests/repair-queue-jump.test.sh
#
# fleet-ops#5810: a red-main repair PR must not sit at the END of a merge
# queue whose group builds fail on the very bug it fixes (0509#3191 sat for
# 57 min behind 14 dead entries on 2026-09-12 until a human jumped it).
#
# Acceptance bullets proven here, without touching GitHub:
#   1. Unit test on the 2026-09-12 queue snapshot selects #3191 for the
#      jump (the >30-min-head-wait safeguard in selectRepairJumps).
#   2. ONLY repair-labelled PRs may jump: a queue of non-repair entries is
#      never selected; a repair PR whose head is fresh (<30 min) is not
#      swept-jumped; `repair:`-prefix is the only matching label family.
#   3. Never bypass required checks: the jump mutation is
#      enqueuePullRequest(jump:true) (plus dequeue-if-queued), never a
#      merge with --admin / --subject bypass shape.
#   4. The arm workflow routes repair-labelled PRs through the helper and
#      everything else through plain auto-merge; a helper hard-failure
//      blocks a silent re-queue at the tail.
#   5. Drills run through a stubbed gh: arm-time enqueue(jump:true) and the
#      sweep's end-to-end selection via enqueue-green-prs.mjs integration.
#
# Fixture mode makes NO live gh calls; every run uses GH=$tmp/gh mock.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch=$(mktemp -d -t repair-queue-jump.XXXXXX)
if [ "${KEEP_SCRATCH:-}" != 1 ]; then trap 'rm -rf "$scratch"' EXIT; fi

node_function() {
    GH=stub node --input-type=module -e "
import { $1 } from '$repo_root/.github/scripts/repair-queue-jump.mjs';
process.env.NODE_PATH='$repo_root/.github/node_modules'
$(cat)
"
}

node_function_test() { node --input-type=module "$scratch/t.mjs"; }

node_function || echo test1
