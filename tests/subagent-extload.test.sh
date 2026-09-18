#!/usr/bin/env bash
# tests/subagent-extload.test.sh
#
# fleet-ops#3277: the repo owns the subagent extension + unpinned agent
# defs, and pi-transport-check --subagent asserts EXTLOAD at worker start.
#
# Invariants:
#   1. The wrapper, agent defs and probe exist in the repo.
#   2. Wrapper prints EXTLOAD-OK and re-exports stock (not a fork).
#   3. Agent defs have no model: pin.
#   4. Default pi-transport-check stays cli.js-only (self-heal / seatlib).
#   5. --subagent fails loud without the handshake; passes when present.
#
# Lock-and-leave. Runs offline (scratch HOME, stubbed npm examples).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
wrapper="$repo_root/template/extensions/subagent/index.ts"
probe="$repo_root/bin/pi-transport-check"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$wrapper" ]] || fail "wrapper missing: $wrapper"
[[ -x "$probe" ]] || fail "not executable: $probe"

# --- 1. repo sources exist -------------------------------------------------
# MANIFEST deleted 2026-09-18: live user paths are symlinks into this repo,
# and the four npm-pin: dests are symlinks into the installed pi package's
# examples/ (see README "Install"). What CI can still prove is that every
# source the fleet links to is present.
for f in template/extensions/subagent/index.ts \
         template/agents/planner.md \
         template/agents/reviewer.md \
         template/agents/scout.md \
         template/agents/worker.md \
         bin/pi-transport-check; do
  [[ -f "$repo_root/$f" ]] || fail "missing repo source: $f"
done
ok "subagent wrapper, agent defs and probe are in the repo"

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

# --- 4+5. Probe: default ignores missing subagent; --subagent asserts ------
scratch="$(mktemp -d -t subagent-extload.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
mkdir -p "$scratch/bin" "$scratch/home/.pi/agent/extensions/subagent" \
  "$scratch/home/.pi/agent/agents" "$scratch/examples/extensions/subagent/prompts"

# fake cli.js for default probe
{
  printf '#!/usr/bin/env node\n'
  for _ in {1..20}; do
    printf '// padding to exceed 300 bytes 1234567890123456789012345678901234567890\n'
  done
} >"$scratch/cli.js"
printf '#!/bin/sh\necho 0.84.4\n' >"$scratch/bin/pi"
chmod +x "$scratch/bin/pi"

export HOME="$scratch/home"
set +e
out=$("$probe" "$scratch/cli.js" "$scratch/bin/pi" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "default probe must stay green without subagent dests, rc=$rc out=$out"
grep -q 'PI-TRANSPORT-OK' <<<"$out" || fail "default probe must print PI-TRANSPORT-OK: $out"
if grep -q 'EXTLOAD-OK extension=subagent' <<<"$out"; then
  fail "default probe must not assert subagent EXTLOAD (self-heal / seatlib): $out"
fi
ok "default probe is cli.js-only (missing subagent is not transport-down)"

set +e
out=$("$probe" --subagent 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "--subagent with missing dests must exit 1, got rc=$rc out=$out"
grep -q 'PI-TRANSPORT-CORRUPT' <<<"$out" || fail "--subagent must fail loud: $out"
ok "--subagent fails loud when handshake dests are missing"

cp "$wrapper" "$scratch/home/.pi/agent/extensions/subagent/index.ts"
printf 'export const agents = true;\n' >"$scratch/home/.pi/agent/extensions/subagent/agents.ts"
for name in planner reviewer scout worker; do
  cp "$repo_root/template/agents/$name.md" "$scratch/home/.pi/agent/agents/$name.md"
done
set +e
out=$("$probe" --subagent 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "--subagent must pass when dests are present, rc=$rc out=$out"
grep -q 'EXTLOAD-OK extension=subagent' <<<"$out" \
  || fail "--subagent must print EXTLOAD-OK: $out"
ok "--subagent prints EXTLOAD-OK when handshake dests are present"

printf 'model: claude-sonnet-4-5\n' >>"$scratch/home/.pi/agent/agents/worker.md"
set +e
out=$("$probe" --subagent 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "pinned worker.md must fail --subagent, rc=$rc out=$out"
grep -q 'pinned' <<<"$out" || fail "--subagent must name the pin: $out"
ok "--subagent rejects a pinned agent def"
# restore unpinned worker for later steps
cp "$repo_root/template/agents/worker.md" "$scratch/home/.pi/agent/agents/worker.md"

# Sections 6 (install.sh npm-pin + wrapper copy) and 7 (pi-issue-run wires
# the EXTLOAD assert) were deleted 2026-09-18 with their subjects: install.sh
# went with the deploy-cluster cut (live paths are symlinks into this repo,
# so there is nothing to install), and bin/pi-issue-run went with the
# run-wrapper cut (pi-issue@.service execs `pi --print` directly).

echo "ALL OK: subagent extension sources present and EXTLOAD handshake locked"
