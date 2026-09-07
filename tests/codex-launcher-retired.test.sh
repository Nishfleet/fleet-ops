#!/usr/bin/env bash
# tests/codex-launcher-retired.test.sh
#
# fleet-ops#4148 (child of #4140 row 9): shape-only landing of per-role
# systemd unit templates (systemd/codex-sol@.service, systemd/codex-luna@.service)
# whose ExecStart hard-codes model/provider/effort so launch identity holds
# by construction (DECISIONS on #4148; orchestrator option 3 2026-09-07;
# #4159 closed as duplicate). The live PATH wrapper + governed-run +
# agent-governor-runtime stay in place until a green proof (c) on a
# Sol-capable seat returning HTTP 200. The archive commit is the git backup
# of the loose ~/.local files (same rule as #4141); it is not a wipe.
#
# This test pins the shape-only replacement:
#   1. No wrapper/runtime/governed-run file in active repo dirs (bin/, lib/,
#      libexec/) — archive/codex-launcher-retired-2026-09-07/ is the only home
#      inside git. (Live ~/.local copies are out of scope for this hermetic
#      test; the wipe is a follow-up.)
#   2. No reference to those names in active code paths (prompts/, config/,
#      systemd/, MANIFEST).
#   3. The design doc row 9 verdict records SHAPE-ONLY + wipe gated.
#   4. The templates exist in systemd/ + MANIFEST and pin identity in
#      ExecStart: real binary path (codex-real), explicit model,
#      model_provider=openai, and a fixed effort (Sol effort = instance %i
#      sanctioned medium/xhigh; Luna effort = max). A template that omits a
#      pin or reintroduces the wrapper path fails this test.
#   5. The archive README must not claim the live copies were wiped.
#
# A rebuild that re-adds a wrapper to active repo code without a Nish-endorsed
# exception fails this test. The machinery-authorization-gate (fleet-ops#1548)
# is the mechanical prevention; this test is the shape pin.

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

# --- 3. design doc row 9 verdict is SHAPE-ONLY, wipe gated -------------------
if ! grep -q 'codex launcher.*SHAPE-ONLY.*#4148' \
     "$repo_root/docs/design/hand-built-vs-off-the-shelf.md"; then
  fail "design doc row 9 must record SHAPE-ONLY (#4148)"
fi
if ! grep -q 'wipe gated' \
     "$repo_root/docs/design/hand-built-vs-off-the-shelf.md"; then
  fail "design doc row 9 must record that the wipe is gated"
fi
ok "design doc row 9 records SHAPE-ONLY and wipe gated"

# --- 4. archive exists --------------------------------------------------------
[[ -f "$repo_root/archive/codex-launcher-retired-2026-09-07/codex" ]] \
  || fail "archive missing the codex wrapper"
[[ -d "$repo_root/archive/codex-launcher-retired-2026-09-07/agent-governor-runtime" ]] \
  || fail "archive missing agent-governor-runtime"
[[ -f "$repo_root/archive/codex-launcher-retired-2026-09-07/governed-run" ]] \
  || fail "archive missing governed-run"
readme="$repo_root/archive/codex-launcher-retired-2026-09-07/README.md"
[[ -f "$readme" ]] || fail "archive missing README"
if grep -qiE 'Live copies were wiped|live copies were deleted' "$readme"; then
  fail "archive README must not claim a wipe that option 3 forbade"
fi
grep -q 'live wrapper remains' "$readme" \
  || fail "archive README must say the live wrapper remains"
ok "archive/codex-launcher-retired-2026-09-07/ is complete and does not claim a wipe"

# --- 5. replacement templates exist and pin identity --------------------------
sol="$repo_root/systemd/codex-sol@.service"
luna="$repo_root/systemd/codex-luna@.service"
[[ -f "$sol" ]] || fail "missing replacement template systemd/codex-sol@.service"
[[ -f "$luna" ]] || fail "missing replacement template systemd/codex-luna@.service"
grep -qF 'codex-real' "$sol" || fail "codex-sol@ must launch the real binary (codex-real), not a wrapper"
grep -qF 'codex-real' "$luna" || fail "codex-luna@ must launch the real binary (codex-real), not a wrapper"
grep -qF -e '--skip-git-repo-check' "$sol" || fail "codex-sol@ must carry --skip-git-repo-check (trust/git gate would block packet runs)"
grep -qF -e '--skip-git-repo-check' "$luna" || fail "codex-luna@ must carry --skip-git-repo-check (trust/git gate would block packet runs)"
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
