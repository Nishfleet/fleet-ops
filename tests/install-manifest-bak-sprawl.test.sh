#!/usr/bin/env bash
# tests/install-manifest-bak-sprawl.test.sh
#
# fleet-ops#3273: `install.sh --check` must fail if any .bak (or .bak-*)
# file/directory sits next to a managed MANIFEST destination. These copies are
# not loaded and they confuse every grep.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
install_src="$repo_root/install.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$install_src" ]] || fail "not executable: $install_src"

# --- 1. Static lock: the script contains the .bak-sprawl guard -------------
grep -q 'check_bak_sprawl' "$install_src" \
  || fail "install.sh must define check_bak_sprawl"
grep -q '.bak next to managed MANIFEST file' "$install_src" \
  || fail "install.sh must emit the .bak-sprawl DIFF line"
ok "install.sh has check_bak_sprawl guard"

# --- 2. Build a scratch install environment ----------------------------------
scratch="$(mktemp -d -t install-bak.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

install="$scratch/install.sh"
cp -a "$install_src" "$install"
chmod +x "$install"

cat >"$scratch/MANIFEST" <<MANIFEST
foo $scratch/home/nish/.local/bin/foo
bar $scratch/home/nish/.pi/agent/extensions/bar/index.ts
MANIFEST

mkdir -p "$scratch/home/nish/.local/bin" \
         "$scratch/home/nish/.pi/agent/extensions/bar"

# Sources live next to the scratch install.sh; the dest entries are symlinks
# to them so a vanilla --check is clean before any .bak sprawl is introduced.
printf '%s\n' 'this is foo' >"$scratch/foo"
printf '%s\n' 'this is bar' >"$scratch/bar"
ln -s "$scratch/foo" "$scratch/home/nish/.local/bin/foo"
ln -s "$scratch/bar" "$scratch/home/nish/.pi/agent/extensions/bar/index.ts"

# --- 3. --check with no .bak must pass (rc=0) -------------------------------
cd "$scratch"
if ! "$install" --check >/dev/null 2>&1; then
  fail "install.sh --check must pass when there is no .bak sprawl"
fi
ok "install.sh --check passes without .bak sprawl"

# --- 4. Simulate the sprawl: .bak next to a managed file --------------------
bak_foo="$scratch/home/nish/.local/bin/foo.bak-20260905-test"
bak_ts="$scratch/home/nish/.pi/agent/extensions/bar/index.ts.bak-20260905-test"
ln -s "$scratch/home/nish/.local/bin/foo" "$bak_foo"
ln -s "$scratch/home/nish/.pi/agent/extensions/bar/index.ts" "$bak_ts"

# --- 5. --check must now fail and name the .bak entries ---------------------
set +e
out=$("$install" --check 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "install.sh --check must fail (rc=1) when .bak sprawl exists, got rc=$rc"
grep -q '.bak next to managed MANIFEST file' <<< "$out" \
  || fail "install.sh --check did not report the .bak files as sprawl"
grep -qF "$bak_foo" <<< "$out" \
  || fail "install.sh --check did not name the .bak-foo file in its output"
grep -qF "$bak_ts" <<< "$out" \
  || fail "install.sh --check did not name the .bak-.ts file in its output"
ok "install.sh --check fails and reports .bak sprawl"

# --- 6. Removing the .bak must restore a green --check ----------------------
rm "$bak_foo" "$bak_ts"
if ! "$install" --check >/dev/null 2>&1; then
  fail "install.sh --check must pass again after .bak sprawl is removed"
fi
ok "install.sh --check is green after .bak removal"

# --- 7. Live repo MANIFEST must have no existing .bak sprawl ---------------
cd "$repo_root"
out=$("$install" --check 2>&1 || true)
if grep -q '.bak next to managed MANIFEST file' <<< "$out"; then
  fail "live repo has existing .bak sprawl: $out"
fi
ok "live repo MANIFEST has no .bak sprawl"

echo "OK: install.sh --check detects .bak files next to managed MANIFEST destinations (fleet-ops#3273)"
