#!/usr/bin/env bash
# tests/fleet-bin-exclude-canary.test.sh
#
# fleet-ops#1396: .git/info/exclude held 'bin/**' and silently dropped
# new bin executables from commits. Proves:
#   1. bin/ is not ignored by .git/info/exclude or .gitignore.
#   2. Every bin/ source declared in MANIFEST is tracked and exists on disk.
#   3. Drill: a scratch repo with 'bin/**' in its exclude ignores a new bin file.
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
manifest="$repo_root/MANIFEST"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

command -v git >/dev/null 2>&1 || fail "git missing"
[[ -f "$manifest" ]] || fail "MANIFEST missing: $manifest"

# --- 1. bin/ is not ignored --------------------------------------------------
# Use --git-common-dir because the canonical checkout may be a worktree; the
# shared .git/info/exclude is the file that hurt us.
git_common=$(git -C "$repo_root" rev-parse --git-common-dir)
exclude="$git_common/info/exclude"
[[ -f "$exclude" ]] || fail "git info/exclude missing: $exclude"

# Reject the literal 'bin/**' pattern (and near variants) in the local exclude.
grep -qE '^[[:space:]]*bin/[[:space:]]*$' "$exclude" \
  && fail "git info/exclude ignores the bin/ directory (fleet-ops#1396)"
grep -qE '^[[:space:]]*bin/\*+[[:space:]]*$' "$exclude" \
  && fail "git info/exclude contains a bin/* pattern (fleet-ops#1396)"

# Also reject bin/ patterns in the tracked .gitignore — a future PR must not
# move the local exclude into the repo.
if [[ -f "$repo_root/.gitignore" ]]; then
  grep -qE '^[[:space:]]*bin/[[:space:]]*$' "$repo_root/.gitignore" \
    && fail ".gitignore ignores the bin/ directory (fleet-ops#1396)"
  grep -qE '^[[:space:]]*bin/\*+[[:space:]]*$' "$repo_root/.gitignore" \
    && fail ".gitignore contains a bin/* pattern (fleet-ops#1396)"
fi

# Live check with a throwaway probe: if git considers any new bin file ignored,
# the old silent-drop class is still active.
probe_dot=$(mktemp -p "$repo_root/bin" .fleet-bin-exclude-canary-probe-XXXXXX)
probe_regular=$(mktemp -p "$repo_root/bin" fleet-bin-exclude-canary-probe-XXXXXX)
cleanup_probes() { rm -f "$probe_dot" "$probe_regular"; }
trap 'cleanup_probes' EXIT INT TERM

chmod +x "$probe_dot" "$probe_regular" 2>/dev/null || true

# check-ignore from inside the repo needs the path relative to the worktree.
# The probes are in bin/, so use bin/<name>.
dot_name="bin/${probe_dot##*/}"
regular_name="bin/${probe_regular##*/}"
set +e
git -C "$repo_root" check-ignore --quiet "$dot_name" >/dev/null 2>&1
dot_rc=$?
git -C "$repo_root" check-ignore --quiet "$regular_name" >/dev/null 2>&1
regular_rc=$?
set -e

[[ "$dot_rc" -ne 0 ]] || fail "dotfile under bin/ is ignored; 'bin/**' or similar may be in .git/info/exclude (fleet-ops#1396)"
[[ "$regular_rc" -ne 0 ]] || fail "new file under bin/ is ignored; 'bin/**' or similar may be in .git/info/exclude (fleet-ops#1396)"

cleanup_probes
trap - EXIT INT TERM

ok "bin/ is not ignored by git exclude or .gitignore"

# --- 2. Every MANIFEST bin/ source is tracked and exists ---------------------
missing=0
while read -r src _ || [[ -n "$src" ]]; do
  [[ -z "$src" ]] && continue
  [[ "$src" == \#* ]] && continue
  [[ "$src" == bin/* ]] || continue
  if [[ ! -f "$repo_root/$src" ]]; then
    echo "MISSING on disk: $src" >&2
    missing=1
    continue
  fi
  if ! git -C "$repo_root" ls-files --error-unmatch "$src" >/dev/null 2>&1; then
    echo "NOT TRACKED: $src" >&2
    missing=1
  fi
done < "$manifest"
[[ "$missing" -eq 0 ]] || fail "one or more MANIFEST bin/ sources are missing or not tracked"
ok "every MANIFEST bin/ source exists and is tracked"

# --- 3. Drill: 'bin/**' exclude actually ignores a new bin file ------------
scratch="$(mktemp -d -t bin-exclude-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

git -C "$scratch" init -q -b main
mkdir -p "$scratch/bin"
printf '#!/bin/sh\n' > "$scratch/bin/dummy"
chmod +x "$scratch/bin/dummy"
printf 'bin/**\n' > "$scratch/.git/info/exclude"

set +e
git -C "$scratch" check-ignore --quiet bin/dummy >/dev/null 2>&1
drill_rc=$?
set -e
[[ "$drill_rc" -eq 0 ]] || fail "drill: expected probe to be ignored in scratch repo with 'bin/**' exclude, got rc=$drill_rc"
ok "drill: 'bin/**' exclude ignores a new bin file in a scratch repo"

# --- 4. Nested CI host -------------------------------------------------------
grep -Fq 'bash "$here/fleet-bin-exclude-canary.test.sh"' "$here/rule-enforcement.test.sh" \
  || fail "rule-enforcement.test.sh must nest this test (worker token cannot edit .github/workflows)"
ok "rule-enforcement.test.sh nests this test"

ok "fleet-bin-exclude-canary: bin/ not ignored, MANIFEST sources exist and tracked, drill passes"
