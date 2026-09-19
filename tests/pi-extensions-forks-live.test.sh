#!/usr/bin/env bash
# tests/pi-extensions-forks-live.test.sh
#
# fleet-ops#5912: live-vs-repo drift on ~/.pi/agent/extensions must surface
# the day it happens, not in a weekly-review issue. The 2026-09-18 glue sweep
# (7c2b2beac) declared three extensions LOCAL FORK files — everything else in
# that directory is a symlink into pi's shipped examples so a pi upgrade
# updates it for free. On 2026-09-19 10:39 a manual `ln -sf` pass re-symlinked
# the fork files to stock, silently dropping the fleet rules: permission-gate
# lost git-stash / systemctl-restart / wrangler-deploy (rules 6 -> 3),
# protected-paths lost the fleet credential paths, and subagent lost the
# EXTLOAD-OK handshake line its index.ts exists for. spawn-guard-core.ts
# (the file #5912 was filed about) was deleted on both sides by the sweep,
# so this test is the class fix: pin every declared fork as a REGULAR file
# byte-identical to the repo template.
#
# Invariants (per template/extensions/README.md "Local files" table):
#   1. Each declared fork exists live as a regular file — NOT a symlink.
#      [[ -f ]] follows links, so the symlink check must run first.
#   2. Its content is byte-identical to template/extensions/<path>.
#   3. Forks never live inside a dir symlink: the parent chain is real dirs.
#
# VPS-only: skips when the live extensions dir is absent (hosted CI has no
# ~/.pi). Listed in live_skip in tests/p14-test-listing-gate.test.sh.
# PI_EXTENSIONS_DIR overrides the live root for drills.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
template="$repo_root/template/extensions"
live_dir="${PI_EXTENSIONS_DIR:-$HOME/.pi/agent/extensions}"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

if [[ ! -d "$live_dir" ]]; then
	echo "SKIP: no live pi extensions dir at $live_dir (hosted CI)"
	exit 0
fi

# Declared forks — keep in lockstep with the README "Local files" table.
forks=(
	"permission-gate.ts"
	"protected-paths.ts"
	"subagent/index.ts"
)

for rel in "${forks[@]}"; do
	live="$live_dir/$rel"
	tmpl="$template/$rel"

	[[ -f "$tmpl" ]] || fail "declared fork missing from repo template: $tmpl"

	# Parent chain must be real directories (a dir symlink up-tree makes the
	# leaf a stock file even when the leaf name looks right).
	dir="$live_dir"
	IFS='/' read -ra parts <<<"$rel"
	for ((i = 0; i < ${#parts[@]} - 1; i++)); do
		dir="$dir/${parts[$i]}"
		[[ -L "$dir" ]] && fail "$rel: parent $dir is a symlink — fork is not live (fleet-ops#5912 class)"
		[[ -d "$dir" ]] || fail "$rel: parent dir missing: $dir"
	done

	[[ -L "$live" ]] && fail "$live is a symlink -> $(readlink "$live"); declared fork must be a regular file"
	[[ -f "$live" ]] || fail "$live missing or not a regular file"
	cmp -s "$tmpl" "$live" || fail "$live differs from repo template (drift): diff -u '$tmpl' '$live'"
	ok "$rel live is a regular file identical to template"
done
