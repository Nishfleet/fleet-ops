#!/usr/bin/env bash
# tests/install-manifest-comment-purity.test.sh
#
# fleet-ops#156 finding 11: `install.sh --check` must fail if any MANIFEST
# comment line has produced a filesystem entry. The old parser did not skip
# `#`-led lines cleanly and created symlinks named after the comment text.
#
# This test reproduces that scenario in a scratch directory and proves the
# current install.sh detects it as drift.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
install_src="$repo_root/install.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$install_src" ]] || fail "not executable: $install_src"

# --- 1. Static lock: the script contains the comment-junk guard ------------
grep -q 'check_comment_junk' "$install_src" \
  || fail "install.sh must define check_comment_junk"
grep -q 'MANIFEST comment line produced a filesystem entry' "$install_src" \
  || fail "install.sh must emit the comment-junk DIFF line"
ok "install.sh has check_comment_junk guard"

# --- 2. Build a scratch install environment ----------------------------------
scratch="$(mktemp -d -t install-comment.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

install="$scratch/install.sh"
cp -a "$install_src" "$install"
chmod +x "$install"

cat >"$scratch/MANIFEST" <<MANIFEST
# P14: nishfleet-worker GitHub App identity for workers
foo $scratch/home/nish/.local/bin/foo
MANIFEST

mkdir -p "$scratch/home/nish/.local/bin"
ln -s "$scratch/foo" "$scratch/home/nish/.local/bin/foo"

printf '%s\n' 'this is foo' >"$scratch/foo"

# --- 3. --check with no junk must pass (rc=0) -------------------------------
cd "$scratch"
if ! "$install" --check >/dev/null 2>&1; then
  fail "install.sh --check must pass when there is no comment-junk"
fi
ok "install.sh --check passes without comment-junk"

# --- 4. Simulate the old bug: a filesystem entry named after the comment -----
# The comment's second token is "P14: nishfleet-worker GitHub App identity for
# workers". A buggy parser would create a symlink/file with that name.
junk="P14: nishfleet-worker GitHub App identity for workers"
ln -s "$scratch/foo" "$scratch/$junk"

# --- 5. --check must now fail and name the junk -----------------------------
set +e
out=$("$install" --check 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "install.sh --check must fail (rc=1) when comment-junk exists, got rc=$rc"
grep -q 'MANIFEST comment line produced a filesystem entry' <<< "$out" \
  || fail "install.sh --check did not report the comment-junk as a comment-line artifact"
grep -qF "$junk" <<< "$out" \
  || fail "install.sh --check did not name the junk file in its output"
ok "install.sh --check fails and reports comment-junk"

# --- 6. Removing the junk must restore a green --check ----------------------
rm "$scratch/$junk"
if ! "$install" --check >/dev/null 2>&1; then
  fail "install.sh --check must pass again after comment-junk is removed"
fi
ok "install.sh --check is green after junk removal"

# --- 7. Live repo MANIFEST must have no existing comment-junk ---------------
cd "$repo_root"
out=$("$install" --check 2>&1 || true)
if grep -q 'MANIFEST comment line produced a filesystem entry' <<< "$out"; then
  fail "live repo has existing MANIFEST comment-junk: $out"
fi
ok "live repo MANIFEST has no comment-junk"

echo "OK: install.sh --check detects MANIFEST comment-line filesystem entries (fleet-ops#156 finding 11)"
