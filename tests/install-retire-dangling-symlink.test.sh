#!/usr/bin/env bash
# tests/install-retire-dangling-symlink.test.sh
#
# fleet-ops#4199: the #4182 dead-man-canary retire removed the manifest
# entries but left the live unit files on disk as DANGLING symlinks (they
# pointed at systemd/ files deleted from the deploy clone). install.sh's
# remove_retired_canaries() guarded on `[ -f ... ]`, which is FALSE for a
# dangling symlink (its target is gone), so the stale timers were never
# removed and the timer-manifest drill went red on clean main.
#
# This test proves remove_retired_canaries() now removes dangling symlinks
# (both the unit file and its timers.target.wants symlink), so a re-run of
# install.sh cleans the drift class the #4182 retire left behind.
#
# Nested from tests/rule-enforcement.test.sh so CI covers it without a
# workflow edit this token cannot push.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
install_src="$repo_root/install.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$install_src" ]] || fail "not executable: $install_src"

# --- 1. Static lock: remove_retired_canaries catches dangling symlinks ------
# A future refactor that reverts to `-f` (false for dangling symlinks) re-reds
# CI here.
grep -q 'remove_retired_canaries' "$install_src" \
  || fail "install.sh must define remove_retired_canaries"
grep -q '\[ -e "\$p" \] || \[ -L "\$p" \]' "$install_src" \
  || fail "install.sh remove_retired_canaries must use -e || -L to catch dangling symlinks"
grep -q 'timers.target.wants' "$install_src" \
  || fail "install.sh remove_retired_canaries must remove the timers.target.wants symlink"
ok "install.sh remove_retired_canaries catches dangling symlinks (fleet-ops#4199)"

# --- 2. Build a scratch install environment ----------------------------------
scratch="$(mktemp -d -t install-retire.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

install="$scratch/install.sh"
cp -a "$install_src" "$install"
chmod +x "$install"

mkdir -p "$scratch/home/nish/.config/systemd/user/timers.target.wants"

# The six retired dead-man canary units, as DANGLING symlinks (target gone),
# exactly the state #4182 left on the live box. Plus a timers.target.wants
# symlink for each so the timer-manifest live check would see them.
STALE_UNITS=(
    gh-webhook-canary-deadman.service gh-webhook-canary-deadman.timer
    fleet-completion-canary.service fleet-completion-canary.timer
    fleet-loose-ends-canary.service fleet-loose-ends-canary.timer
)
for unit in "${STALE_UNITS[@]}"; do
    ln -s "/nonexistent/systemd/$unit" "$scratch/home/nish/.config/systemd/user/$unit"
    ln -s "/nonexistent/systemd/$unit" "$scratch/home/nish/.config/systemd/user/timers.target.wants/$unit"
done

# Minimal MANIFEST so install.sh's main loop has nothing to install.
: > "$scratch/MANIFEST"

# Stub systemctl: record every call, always succeed.
calls="$scratch/calls.log"
: > "$calls"
cat >"$scratch/stub.sh" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$calls"
exit 0
EOF
chmod +x "$scratch/stub.sh"

# --- 3. Run install.sh (user install mode) and assert the symlinks are gone --
cd "$scratch"
out=$(SYSTEMCTL="$scratch/stub.sh" HOME="$scratch/home/nish" "$install" 2>&1 || true)

for unit in "${STALE_UNITS[@]}"; do
    if [ -e "$scratch/home/nish/.config/systemd/user/$unit" ] || [ -L "$scratch/home/nish/.config/systemd/user/$unit" ]; then
        fail "stale unit symlink not removed: $unit; out: $out"
    fi
    if [ -e "$scratch/home/nish/.config/systemd/user/timers.target.wants/$unit" ] || [ -L "$scratch/home/nish/.config/systemd/user/timers.target.wants/$unit" ]; then
        fail "stale timers.target.wants symlink not removed: $unit; out: $out"
    fi
done
ok "install.sh removed all six dangling dead-man canary unit + wants symlinks"

# --- 4. Precision: a live (non-dangling) unit is NOT removed ---------------
# remove_retired_canaries must only touch the retired names, never a live
# canary that still belongs in the manifest (e.g. gh-webhook-canary.timer).
live="$scratch/home/nish/.config/systemd/user/gh-webhook-canary.timer"
printf '[Unit]\nDescription=live\n' >"$live"
out2=$(SYSTEMCTL="$scratch/stub.sh" HOME="$scratch/home/nish" "$install" 2>&1 || true)
[ -f "$live" ] || fail "live unit gh-webhook-canary.timer was removed by remove_retired_canaries; out: $out2"
ok "live non-retired unit is untouched (precision)"

echo "OK: install.sh remove_retired_canaries removes dangling dead-man canary symlinks (fleet-ops#4199)"
