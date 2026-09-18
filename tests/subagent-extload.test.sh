#!/usr/bin/env bash
# tests/subagent-extload.test.sh
#
# fleet-ops#3277: the repo owns the subagent extension + unpinned agent defs.
#
# Invariants:
#   1. The wrapper and agent defs exist in the repo.
#   2. Wrapper prints EXTLOAD-OK and re-exports stock (not a fork).
#   3. Agent defs have no model: pin.
#
# Invariants 4 and 5 covered bin/pi-transport-check's default and --subagent
# modes; both went with that binary in the 2026-09-18 glue sweep (its only
# programmatic reader, lib/litellm-seat.sh, was deleted in the same sweep).
# The EXTLOAD-OK handshake itself is still locked by invariant 2 — what the
# probe used to grep for is exactly what section 2 greps for.
#
# Lock-and-leave. Runs offline (scratch HOME, stubbed npm examples).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
wrapper="$repo_root/template/extensions/subagent/index.ts"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$wrapper" ]] || fail "wrapper missing: $wrapper"

# --- 1. repo sources exist -------------------------------------------------
# MANIFEST deleted 2026-09-18: live user paths are symlinks into this repo,
# and the four npm-pin: dests are symlinks into the installed pi package's
# examples/ (see README "Install"). What CI can still prove is that every
# source the fleet links to is present.
for f in template/extensions/subagent/index.ts \
         template/agents/planner.md \
         template/agents/reviewer.md \
         template/agents/scout.md \
         template/agents/worker.md; do
  [[ -f "$repo_root/$f" ]] || fail "missing repo source: $f"
done
ok "subagent wrapper and agent defs are in the repo"

# --- 2. Wrapper is a handshake + re-export, not a stock fork ---------------
grep -q 'EXTLOAD-OK extension=subagent' "$wrapper" \
  || fail "wrapper must print EXTLOAD-OK extension=subagent"
grep -q 'examples/extensions/subagent/index.ts' "$wrapper" \
  || fail "wrapper must re-export the stock package example"
if grep -q 'MAX_PARALLEL_TASKS' "$wrapper"; then
  fail "wrapper must not fork the stock subagent (MAX_PARALLEL_TASKS)"
fi
ok "wrapper is EXTLOAD handshake + stock re-export"

# --- 3. Unpinned agent defs ------------------------------------------------
for name in planner reviewer scout worker; do
  def="$repo_root/template/agents/$name.md"
  [[ -f "$def" ]] || fail "missing agent def: $def"
  if grep -qE '^model:' "$def"; then
    fail "$def is pinned (has model:); fleet defs stay unpinned"
  fi
  grep -qE "^name: $name$" "$def" || fail "$def missing name: $name"
done
ok "agent defs exist and are unpinned"

# Sections 4 and 5 (the pi-transport-check default and --subagent probe
# behaviour) were deleted 2026-09-18 with that binary. Sections 6 (install.sh
# npm-pin + wrapper copy) and 7 (pi-issue-run wires the EXTLOAD assert) were
# deleted 2026-09-18 with their subjects too: install.sh
# went with the deploy-cluster cut (live paths are symlinks into this repo,
# so there is nothing to install), and bin/pi-issue-run went with the
# run-wrapper cut (pi-issue@.service execs `pi --print` directly).

echo "ALL OK: subagent extension sources present and EXTLOAD handshake locked"
