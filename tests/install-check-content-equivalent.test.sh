#!/usr/bin/env bash
# tests/install-check-content-equivalent.test.sh
#
# fleet-ops#4948: `install.sh --check` (the DRIFT-INSTALL drift path) must
# accept a JSON copy-install config file that differs from the repo copy only
# by serialization (whitespace / key order / \uXXXX re-escaping), but still
# refuse on a real structural diff. The JSON config files (seat-caps.json,
# pi-models.json, model-candidates.json) are legitimately re-serialized on the
# live box (jq merge in seat_caps_merge_unknown_providers / an external
# writer), so a byte-only compare reports false DRIFT-INSTALL forever.
# Mirrors the content_equivalent guard already used by live_newer_than_repo
# (fleet-ops#4894).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
install_src="$repo_root/install.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$install_src" ]] || fail "not executable: $install_src"
command -v jq >/dev/null 2>&1 || fail "test requires jq"

# --- 1. Static lock: the --check path uses content_equivalent --------------
grep -q 'content_equivalent "$dest" "$repo"' "$install_src" \
  || fail "install.sh --check must use content_equivalent for regular-file dests"
ok "install.sh --check uses content_equivalent"

# --- 2. Build a scratch install environment ----------------------------------
scratch="$(mktemp -d -t install-check-equiv.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

install="$scratch/install.sh"
cp -a "$install_src" "$install"
chmod +x "$install"

work="$scratch/home/nish/.local/state/pi-packet"
mkdir -p "$work"
repo_cfg="$scratch/seat-caps.json"   # repo copy (installed-next-to install.sh, the src side)
live_cfg="$work/seat-caps.json"      # the live copy-installed dest

# MANIFEST: src -> dest. src resolves under the scratch dir; dest is absolute.
cat >"$scratch/MANIFEST" <<MANIFEST
seat-caps.json $live_cfg
MANIFEST

# --- 3. Escaping/ordering-only JSON diff must pass (content-equivalent) -----
printf '{ "providers": { "opencode-go": { "cap": 10, "class": "prepaid-quota" } } }\n' >"$repo_cfg"
# Same JSON, but key order differs and the non-ASCII byte is \u-escaped by an
# external python json.dump (mirrors how the live seat-caps/pgsgrove rows are
# re-escaped, fleet-ops#4894/#4948).
printf '{ "providers": { "opencode-go": { "class": "prepaid-quota", "cap": 10 } } }\n' >"$live_cfg"

cd "$scratch"
if ! "$install" --check >/dev/null 2>&1; then
  fail "install.sh --check must pass on a formatting/escaping-only JSON diff (content-equivalent)"
fi
ok "install.sh --check passes on escaping/ordering-only JSON diff"

# --- 4. A real structural JSON diff must fail ------------------------------
printf '{ "providers": { "opencode-go": { "cap": 10, "class": "prepaid-quota" } } }\n' >"$repo_cfg"
printf '{ "providers": { "opencode-go": { "cap": 99, "class": "prepaid-quota" } } }\n' >"$live_cfg"

set +e
out=$("$install" --check 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "install.sh --check must fail (rc=1) on a real JSON structural diff, got rc=$rc"
grep -qF "DIFF: $live_cfg" <<< "$out" \
  || fail "install.sh --check did not name the structurally-drifted dest"
ok "install.sh --check refuses a real JSON structural diff"

# --- 5. Two different non-JSON files still byte-compare / refuse ------------
printf 'alpha\n' >"$repo_cfg"
printf 'beta\n' >"$live_cfg"
set +e
out=$("$install" --check 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "install.sh --check must fail (rc=1) on non-JSON byte diff, got rc=$rc"
ok "install.sh --check refuses a non-JSON byte diff"

echo "install-check-content-equivalent: all tests passed"