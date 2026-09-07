#!/usr/bin/env bash
# tests/codex-launcher-retired.test.sh
#
# fleet-ops#4148 (child of #4140 row 9): the hand-built codex launcher
# governance stack — ~/.local/bin/codex wrapper (281 lines) + governed-run
# (31) + ~/.local/libexec/agent-governor-runtime/ (~3,664 lines, incl. one
# .bak) — was retired 2026-09-07 under the "nothing hand built" umbrella
# (#4140). Replaced by per-role systemd unit templates
# (systemd/codex-sol@.service, systemd/codex-luna@.service) whose ExecStart
# hard-codes model/provider/effort so launch identity holds by construction
# (DECISIONS on #4148; #4159 closed as duplicate). The wrapper/runtime were
# live-only; the archive commit is the git backup (same rule as #4141).
#
# This test pins the retirement + the replacement:
#   1. No wrapper/runtime/governed-run file in active code dirs (bin/, lib/,
#      libexec/) — archive/codex-launcher-retired-2026-09-07/ is the only home.
#   2. No reference to the retired names in active code paths (prompts/,
#      config/, systemd/, MANIFEST).
#   3. The design doc row 9 verdict records the retirement.
#   4. The replacement templates exist in systemd/ + MANIFEST and pin
#      identity in ExecStart: real binary path (codex-real), explicit model,
#      model_provider=openai, and a fixed effort (Sol effort = instance %i
#      sanctioned medium/xhigh; Luna effort = max). A template that omits a
#      pin or reintroduces the wrapper path fails this test.
#
# A rebuild that re-adds any of these to active code without a Nish-endorsed
# exception fails this test. The machinery-authorization-gate (fleet-ops#1548)
# is the mechanical prevention; this test is the deletion pin.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# --- 1. no retired launcher file in active code dirs -------------------------
for dir in bin lib libexec; do
  if [[ -e "$repo_root/$dir/governed-run" ]]; then
    fail "active code must not carry $dir/governed-run - retired (#4148)"
  fi
  if [[ -d "$repo_root/$dir/agent-governor-runtime" ]]; then
    fail "active code must not carry $dir/agent-governor-runtime - retired (#4148)"
  fi
done
ok "no governed-run / agent-governor-runtime in bin/, lib/, libexec/"

# --- 2. no reference in active code paths ------------------------------------
# The design doc (docs/design/hand-built-vs-off-the-shelf.md) is the
# retirement record and is allowed. This test file is also allowed (it
# pins the retirement). archive/ is the archive. Everything else must be
# clean of the retired names.
for path in prompts config systemd MANIFEST; do
  if grep -rInE 'governed-run|agent-governor-runtime' "$repo_root/$path" >/dev/null 2>&1; then
    fail "active code path $path must not reference the retired launcher stack (#4148)"
  fi
done
ok "no reference to governed-run / agent-governor-runtime in prompts/, config/, systemd/, MANIFEST"

# --- 3. design doc row 9 verdict is recorded ---------------------------------
if ! grep -q 'codex launcher.*DONE.*#4148' \
     "$repo_root/docs/design/hand-built-vs-off-the-shelf.md"; then
  fail "design doc row 9 must record the codex launcher retirement (#4148)"
fi
ok "design doc row 9 records the codex launcher verdict"

# --- 4. archive exists --------------------------------------------------------
[[ -f "$repo_root/archive/codex-launcher-retired-2026-09-07/codex" ]] \
  || fail "archive missing the codex wrapper"
[[ -d "$repo_root/archive/codex-launcher-retired-2026-09-07/agent-governor-runtime" ]] \
  || fail "archive missing agent-governor-runtime"
[[ -f "$repo_root/archive/codex-launcher-retired-2026-09-07/governed-run" ]] \
  || fail "archive missing governed-run"
[[ -f "$repo_root/archive/codex-launcher-retired-2026-09-07/README.md" ]] \
  || fail "archive missing README"
ok "archive/codex-launcher-retired-2026-09-07/ is complete"

# --- 5. replacement templates exist and pin identity --------------------------
sol="$repo_root/systemd/codex-sol@.service"
luna="$repo_root/systemd/codex-luna@.service"
[[ -f "$sol" ]] || fail "missing replacement template systemd/codex-sol@.service"
[[ -f "$luna" ]] || fail "missing replacement template systemd/codex-luna@.service"
grep -qF 'codex-real' "$sol" || fail "codex-sol@ must launch the real binary (codex-real), not a wrapper"
grep -qF 'codex-real' "$luna" || fail "codex-luna@ must launch the real binary (codex-real), not a wrapper"
for pin in '-m gpt-5.6-sol' 'model_provider=openai' 'model_reasoning_effort=%i'; do
  grep -qF -e "$pin" "$sol" || fail "codex-sol@ must pin '$pin' in ExecStart"
done
grep -qF '%i' "$sol" || fail "codex-sol@ must carry the effort as the instance (%i)"
for pin in '-m gpt-5.6-luna' 'model_provider=openai' 'model_reasoning_effort=max'; do
  grep -qF -e "$pin" "$luna" || fail "codex-luna@ must pin '$pin' in ExecStart"
done
ok "codex-sol@ / codex-luna@ pin model/provider/effort by construction"

# --- 6. MANIFEST carries both templates ---------------------------------------
grep -qF 'systemd/codex-sol@.service' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install systemd/codex-sol@.service"
grep -qF 'systemd/codex-luna@.service' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install systemd/codex-luna@.service"
ok "MANIFEST installs both templates"

exit 0
