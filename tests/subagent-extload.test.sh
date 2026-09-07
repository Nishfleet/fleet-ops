#!/usr/bin/env bash
# tests/subagent-extload.test.sh
#
# fleet-ops#3277: install.sh owns the subagent extension + unpinned agent
# defs, and pi-transport-check --subagent asserts EXTLOAD at worker start.
#
# Invariants:
#   1. MANIFEST declares the wrapper, npm-pin symlinks, and agent defs.
#   2. Wrapper prints EXTLOAD-OK and re-exports stock (not a fork).
#   3. Agent defs have no model: pin.
#   4. Default pi-transport-check stays cli.js-only (self-heal / seat-lib).
#   5. --subagent fails loud without the handshake; passes when present.
#   6. install.sh npm-pin creates a symlink to the package examples dir.
#   7. pi-issue-run calls --subagent at worker start.
#
# Lock-and-leave. Runs offline (scratch HOME, stubbed npm examples).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
manifest="$repo_root/MANIFEST"
wrapper="$repo_root/template/extensions/subagent/index.ts"
probe="$repo_root/bin/pi-transport-check"
install_src="$repo_root/install.sh"
run_src="$repo_root/bin/pi-issue-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$manifest" ]] || fail "MANIFEST missing"
[[ -f "$wrapper" ]] || fail "wrapper missing: $wrapper"
[[ -x "$probe" ]] || fail "not executable: $probe"
[[ -x "$install_src" ]] || fail "not executable: $install_src"
[[ -f "$run_src" ]] || fail "missing: $run_src"

# --- 1. MANIFEST owns dests ------------------------------------------------
entries=(
  "template/extensions/subagent/index.ts /home/nish/.pi/agent/extensions/subagent/index.ts"
  "npm-pin:extensions/subagent/agents.ts /home/nish/.pi/agent/extensions/subagent/agents.ts"
  "npm-pin:extensions/subagent/prompts/implement.md /home/nish/.pi/agent/prompts/implement.md"
  "npm-pin:extensions/subagent/prompts/implement-and-review.md /home/nish/.pi/agent/prompts/implement-and-review.md"
  "npm-pin:extensions/subagent/prompts/scout-and-plan.md /home/nish/.pi/agent/prompts/scout-and-plan.md"
  "template/agents/planner.md /home/nish/.pi/agent/agents/planner.md"
  "template/agents/reviewer.md /home/nish/.pi/agent/agents/reviewer.md"
  "template/agents/scout.md /home/nish/.pi/agent/agents/scout.md"
  "template/agents/worker.md /home/nish/.pi/agent/agents/worker.md"
  "bin/pi-transport-check /home/nish/.local/bin/pi-transport-check"
)
for entry in "${entries[@]}"; do
  grep -Fxq "$entry" "$manifest" || fail "MANIFEST missing: $entry"
done
ok "MANIFEST declares subagent wrapper, npm-pin symlinks, agent defs, probe"

# Deploy order: wrapper before probe before pi-issue-run, so a mid-install
# worker never asserts EXTLOAD against the pre-wrapper stock symlink.
wrap_n=$(grep -nFx 'template/extensions/subagent/index.ts /home/nish/.pi/agent/extensions/subagent/index.ts' "$manifest" | head -1 | cut -d: -f1)
probe_n=$(grep -nFx 'bin/pi-transport-check /home/nish/.local/bin/pi-transport-check' "$manifest" | head -1 | cut -d: -f1)
run_n=$(grep -nFx 'bin/pi-issue-run /home/nish/.local/bin/pi-issue-run' "$manifest" | head -1 | cut -d: -f1)
[[ -n "$wrap_n" && -n "$probe_n" && -n "$run_n" ]] || fail "could not find MANIFEST line numbers"
(( wrap_n < probe_n && probe_n < run_n )) \
  || fail "MANIFEST order must be wrapper ($wrap_n) < probe ($probe_n) < pi-issue-run ($run_n)"
ok "MANIFEST install order: wrapper then probe then pi-issue-run"

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
  fail "default probe must not assert subagent EXTLOAD (self-heal / seat-lib): $out"
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

# --- 6. install.sh npm-pin + wrapper copy ----------------------------------
install="$scratch/install.sh"
cp -a "$install_src" "$install"
chmod +x "$install"
mkdir -p "$scratch/template/extensions/subagent" "$scratch/template/agents"
cp "$wrapper" "$scratch/template/extensions/subagent/index.ts"
cp "$repo_root/template/agents/planner.md" "$scratch/template/agents/planner.md"
printf 'export const stockAgents = true;\n' >"$scratch/examples/extensions/subagent/agents.ts"
printf '# implement\n' >"$scratch/examples/extensions/subagent/prompts/implement.md"

cat >"$scratch/MANIFEST" <<EOF
template/extensions/subagent/index.ts $scratch/live/extensions/subagent/index.ts
npm-pin:extensions/subagent/agents.ts $scratch/live/extensions/subagent/agents.ts
npm-pin:extensions/subagent/prompts/implement.md $scratch/live/prompts/implement.md
template/agents/planner.md $scratch/live/agents/planner.md
EOF

export PI_PACKAGE_EXAMPLES="$scratch/examples"
export FLEET_OPS_ALLOW_NONCANONICAL=1
export SYSTEMCTL="$scratch/bin/systemctl"
printf '#!/bin/sh\nexit 0\n' >"$scratch/bin/systemctl"
chmod +x "$scratch/bin/systemctl"

mkdir -p "$scratch/live"
cd "$scratch"
"$install" >/dev/null
[[ -f "$scratch/live/extensions/subagent/index.ts" ]] \
  || fail "install.sh did not copy the wrapper"
[[ -L "$scratch/live/extensions/subagent/agents.ts" ]] \
  || fail "install.sh npm-pin must create a symlink for agents.ts"
got=$(readlink -f "$scratch/live/extensions/subagent/agents.ts")
want=$(readlink -f "$scratch/examples/extensions/subagent/agents.ts")
[[ "$got" == "$want" ]] || fail "agents.ts symlink want $want got $got"
[[ -L "$scratch/live/prompts/implement.md" ]] \
  || fail "install.sh npm-pin must create a symlink for implement.md"
[[ -L "$scratch/live/agents/planner.md" ]] \
  || fail "install.sh must symlink unpinned agent def"
grep -q 'EXTLOAD-OK extension=subagent' "$scratch/live/extensions/subagent/index.ts" \
  || fail "installed wrapper lost EXTLOAD handshake"
if ! "$install" --check >/dev/null; then
  fail "install.sh --check must be clean after install"
fi
ok "install.sh copies wrapper, npm-pins stock symlinks, links agent defs"

rm -f "$scratch/live/extensions/subagent/agents.ts"
set +e
out=$("$install" --check 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "--check must DIFF a dropped npm-pin dest, rc=$rc out=$out"
grep -q 'DIFF:' <<<"$out" || fail "--check must name DIFF for dropped agents.ts: $out"
ok "install.sh --check reports a dropped subagent symlink"

# --- 7. pi-issue-run wires the assert --------------------------------------
grep -q 'pi-transport-check --subagent' "$run_src" \
  || fail "pi-issue-run must call pi-transport-check --subagent"
grep -q 'assert_subagent_extload' "$run_src" \
  || fail "pi-issue-run must define assert_subagent_extload"
ok "pi-issue-run asserts subagent EXTLOAD at worker start"

echo "ALL OK: subagent extension is MANIFEST-owned and EXTLOAD-asserted"
