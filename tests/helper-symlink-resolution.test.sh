#!/usr/bin/env bash
# tests/helper-symlink-resolution.test.sh
#
# fleet-ops#5059: a helper symlink under ~/.local/bin or
# ~/.local/lib/pi-packet whose target no longer exists is a dead entry on
# PATH. Live 2026-09-10T21:46-23:50Z the deploy clone held another repo's
# tree (fleet-ops#5016), so ~/.local/bin/unit-escalation-write dangled and
# every OnFailure escalation (unit-escalation@*.service) exited 127 for
# ~7.5h — the fleet's own fail-loud path went silent and nothing paged.
#
# install.sh owns the check because its --check output is already the
# DRIFT-INSTALL loud class (fleet-ops-drift fail_louds and auto-files every
# heartbeat tick) and because the earlier loud classes cannot mask it: it
# reports in the same run as the MANIFEST drift, while fleet-ops-drift's
# DRIFT-EXTRAS pass is never reached once an earlier class is loud.
#
# Invariants:
#   1. install.sh defines the checker/remover and calls both.
#   2. --check is green when no helper link dangles.
#   3. A dangling helper link into a fleet-ops checkout -> rc=1 and the DIFF
#      line names the link and its vanished target (bin/).
#   4. Same for ~/.local/lib/pi-packet.
#   5. A healthy helper link is not flagged; a dangling NON-fleet link is
#      not flagged (the class is the fleet-ops link, not every broken link).
#   6. --check is green again once the dangling links are gone.
#   7. An install removes the dangling link (self-heal) and keeps the healthy
#      one and the non-fleet one.
#   8. The live box has no dangling fleet-ops helper link (skips when the
#      live dirs are absent, i.e. hosted CI).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
install_src="$repo_root/install.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$install_src" ]] || fail "not executable: $install_src"

# --- 1. Static lock: the guard exists and both paths call it ----------------
grep -q 'dangling_helper_symlinks' "$install_src" \
  || fail "install.sh must define dangling_helper_symlinks"
grep -q 'check_helper_symlinks' "$install_src" \
  || fail "install.sh must call check_helper_symlinks from --check"
grep -q 'remove_dangling_helper_symlinks' "$install_src" \
  || fail "install.sh must call remove_dangling_helper_symlinks on install"
grep -q 'dangling helper symlink' "$install_src" \
  || fail "install.sh must emit the dangling-helper DIFF line"
ok "1: install.sh defines the dangling-helper guard and wires check + remove"

# --- 2. Scratch install environment -----------------------------------------
scratch="$(mktemp -d -t helper-symlink.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

install="$scratch/install.sh"
cp -a "$install_src" "$install"
chmod +x "$install"

# A fake fleet-ops checkout under $scratch (the link target path must name a
# fleet-ops tree — that string is what classifies the link as this class).
clone="$scratch/workspaces/tooling/fleet-ops-deploy-clone"
export HOME="$scratch/home"
bin_dir="$HOME/.local/bin"
lib_dir="$HOME/.local/lib/pi-packet"
mkdir -p "$clone/bin" "$clone/lib" "$bin_dir" "$lib_dir" "$scratch/vendor"

# The one live helper: a MANIFEST entry, so it is installed + checked normally.
printf '%s\n' '#!/bin/sh' 'exit 0' >"$clone/bin/helper-a"
chmod +x "$clone/bin/helper-a"

cat >"$scratch/MANIFEST" <<MANIFEST
workspaces/tooling/fleet-ops-deploy-clone/bin/helper-a $bin_dir/helper-a
MANIFEST

# Healthy: the MANIFEST dest, a symlink into the fake checkout.
ln -s "$clone/bin/helper-a" "$bin_dir/helper-a"

export FLEET_HELPER_SYMLINK_DIRS="$bin_dir:$lib_dir"

# `install.sh --check` never refuses a non-canonical checkout, but install
# mode does; $scratch is under /tmp so the guard already passes — assert that
# rather than set the override, so this test cannot hide a regression there.
unset FLEET_OPS_ALLOW_NONCANONICAL || true

# A systemctl stub: install mode enable/daemon-reload must not touch the box.
cat >"$scratch/systemctl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$scratch/systemctl"
export SYSTEMCTL="$scratch/systemctl"

# --- 3. Baseline: no dangling helper link -> --check green ------------------
run_check() {
  set +e
  out=$("$install" --check 2>&1)
  rc=$?
  set -e
}

run_check
[[ "$rc" -eq 0 ]] || fail "baseline --check must be green, got rc=$rc: $out"
ok "2: --check is green with only a healthy helper symlink"

# --- 4. Plant the dangling links -------------------------------------------
# bin/: the unit-escalation-write shape — a helper retired from the checkout.
ln -s "$clone/bin/unit-escalation-write" "$bin_dir/unit-escalation-write"
# lib/pi-packet/: same class in the other managed dir.
ln -s "$clone/lib/retired-lib.py" "$lib_dir/retired-lib.py"
# Out of scope: a dangling link that is NOT a fleet-ops helper.
ln -s "$scratch/vendor/versions/gone/bin/tool" "$bin_dir/vendor-tool"

run_check
[[ "$rc" -eq 1 ]] || fail "--check must fail (rc=1) on a dangling helper symlink, got rc=$rc"
grep -qF 'DIFF: '"$bin_dir"'/unit-escalation-write -> ' <<<"$out" \
  || fail "--check did not name the dangling bin helper: $out"
grep -qF 'dangling helper symlink' <<<"$out" \
  || fail "--check did not emit the dangling-helper DIFF line: $out"
grep -qF "$clone/bin/unit-escalation-write" <<<"$out" \
  || fail "--check did not name the vanished target: $out"
ok "3: dangling bin helper -> rc=1 + DIFF naming link and vanished target"

grep -qF "$lib_dir/retired-lib.py" <<<"$out" \
  || fail "--check did not flag the pi-packet dangling helper: $out"
ok "4: dangling pi-packet helper is flagged too"

if grep -qF "$bin_dir/helper-a" <<<"$out"; then
  fail "--check flagged the healthy helper symlink: $out"
fi
if grep -qF "$bin_dir/vendor-tool" <<<"$out"; then
  fail "--check flagged a dangling non-fleet symlink (out of scope): $out"
fi
ok "5: healthy link and dangling non-fleet link are not flagged"

# --- 5. Removing the dangling links restores green --------------------------
unlink "$bin_dir/unit-escalation-write"
unlink "$lib_dir/retired-lib.py"
run_check
[[ "$rc" -eq 0 ]] || fail "--check must be green after the dangling links are gone, got rc=$rc: $out"
ok "6: --check green again once the dangling helpers are removed"

# --- 6. Install mode removes them (self-heal) -------------------------------
ln -s "$clone/bin/unit-escalation-write" "$bin_dir/unit-escalation-write"
ln -s "$clone/lib/retired-lib.py" "$lib_dir/retired-lib.py"

set +e
out=$("$install" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "install must succeed (rc=0), got rc=$rc: $out"
grep -qF "removed dangling helper symlink: $bin_dir/unit-escalation-write" <<<"$out" \
  || fail "install did not report removing the dangling bin helper: $out"
nonfatal=$(grep -c 'NONFATAL REFUSE' <<<"$out" || true)
[[ "$nonfatal" == "0" ]] || fail "install hit an unrelated NONFATAL REFUSE: $out"
[[ ! -e "$bin_dir/unit-escalation-write" && ! -L "$bin_dir/unit-escalation-write" ]] \
  || fail "install left the dangling bin helper symlink in place"
[[ ! -e "$lib_dir/retired-lib.py" && ! -L "$lib_dir/retired-lib.py" ]] \
  || fail "install left the dangling pi-packet helper symlink in place"
[[ -L "$bin_dir/helper-a" ]] \
  || fail "install removed the healthy helper symlink"
[[ -L "$bin_dir/vendor-tool" ]] \
  || fail "install removed a non-fleet symlink (out of scope)"
ok "7: install removes dangling fleet helpers and leaves everything else alone"

# --- 7. The live box has no dangling fleet-ops helper link ------------------
for d in /home/nish/.local/bin /home/nish/.local/lib/pi-packet; do
  [[ -d "$d" ]] || continue
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    link=$(readlink "$f" 2>/dev/null || true)
    case "$link" in
      *fleet-ops*)
        fail "live dangling fleet-ops helper symlink: $f -> $link"
        ;;
    esac
  done < <(find "$d" -maxdepth 1 -xtype l 2>/dev/null)
done
ok "8: no live dangling fleet-ops helper symlink"

echo "OK: install.sh flags and removes dangling helper symlinks (fleet-ops#5059)"
