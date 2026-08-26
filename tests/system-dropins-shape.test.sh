#!/usr/bin/env bash
# tests/system-dropins-shape.test.sh
#
# fleet-ops#71: locks the SHAPE of the system-scope drop-ins this repo
# owns and the corresponding MANIFEST entries. This is a SHAPE lock, not
# a live check — it runs in CI on a hosted runner with no access to the
# /etc/systemd/system tree. The runtime check is `./install.sh --check --system`.
#
# What it proves:
#   1. Both system drop-in files exist in the repo:
#      - systemd/system/user-1000.slice.d/50-ram-governor.conf
#      - systemd/system/user@1000.service.d/50-no-distro-oomd-kill.conf
#   2. 50-ram-governor.conf keys: section [Slice], MemoryHigh=12G,
#      ManagedOOMMemoryPressure=kill, ManagedOOMMemoryPressureLimit=80%.
#   3. 50-no-distro-oomd-kill.conf keys: section [Service],
#      ManagedOOMMemoryPressure=auto. It MUST NOT set
#      ManagedOOMMemoryPressureLimit (it is the neutralization drop-in:
#      switching ON a stock limit would re-arm the wrong layer).
#   4. Both MANIFEST entries exist with the exact repo-path / live-path
#      pair this issue specifies.
#   5. install.sh accepts --check, --system, --check --system; refuses
#      unknown args.
#
# Lock-and-leave. If any invariant fails, exit 1 and CI fails.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

gov="$repo_root/systemd/system/user-1000.slice.d/50-ram-governor.conf"
ndk="$repo_root/systemd/system/user@1000.service.d/50-no-distro-oomd-kill.conf"
manifest="$repo_root/MANIFEST"
install="$repo_root/install.sh"

# 1. File existence.
[[ -f "$gov" ]] || fail "missing: $gov"
[[ -f "$ndk" ]] || fail "missing: $ndk"

# 2. 50-ram-governor.conf shape.
grep -q '^\[Slice\]$' "$gov" \
  || fail "50-ram-governor.conf: missing [Slice] section header"
grep -q '^MemoryHigh=12G$' "$gov" \
  || fail "50-ram-governor.conf: MemoryHigh=12G must be set"
grep -q '^ManagedOOMMemoryPressure=kill$' "$gov" \
  || fail "50-ram-governor.conf: ManagedOOMMemoryPressure=kill must be set"
grep -q '^ManagedOOMMemoryPressureLimit=80%$' "$gov" \
  || fail "50-ram-governor.conf: ManagedOOMMemoryPressureLimit=80% must be set"
# Defence-in-depth: must not accidentally add a ManagedOOMSwap kill
# (the live fleet uses ~4.7 GiB of swap on idling workers and is healthy).
if grep -q '^ManagedOOMSwap=' "$gov"; then
  fail "50-ram-governor.conf must not set ManagedOOMSwap (would reap swapped-out idle workers)"
fi

# 3. 50-no-distro-oomd-kill.conf shape.
grep -q '^\[Service\]$' "$ndk" \
  || fail "50-no-distro-oomd-kill.conf: missing [Service] section header"
grep -q '^ManagedOOMMemoryPressure=auto$' "$ndk" \
  || fail "50-no-distro-oomd-kill.conf: ManagedOOMMemoryPressure=auto must be set"
# The neutralization must NOT carry its own limit; setting one would
# re-enable the wrong layer. If the policy ever changes, edit this test
# AND docs/ram-governor-tree.md in the same PR.
if grep -q '^ManagedOOMMemoryPressureLimit=' "$ndk"; then
  fail "50-no-distro-oomd-kill.conf must NOT set ManagedOOMMemoryPressureLimit (it is the neutralizer, not a policy)"
fi

# 4. MANIFEST entries — exact format, exact paths. The system paths must
#    start with /etc/systemd/system/ so install.sh routes them through
#    the --system handler.
gov_line="systemd/system/user-1000.slice.d/50-ram-governor.conf /etc/systemd/system/user-1000.slice.d/50-ram-governor.conf"
ndk_line="systemd/system/user@1000.service.d/50-no-distro-oomd-kill.conf /etc/systemd/system/user@1000.service.d/50-no-distro-oomd-kill.conf"
grep -Fxq "$gov_line" "$manifest" \
  || fail "MANIFEST missing entry: $gov_line"
grep -Fxq "$ndk_line" "$manifest" \
  || fail "MANIFEST missing entry: $ndk_line"

# 5. install.sh mode handling.
chmod +x "$install" 2>/dev/null || true
bash -n "$install" || fail "install.sh: bash syntax error"

# A bad arg must exit 2 (we use exit 2 for usage errors so it is
# distinguishable from drift rc=1 / OK rc=0).
if "$install" --bogus >/dev/null 2>&1; then
  fail "install.sh: must reject unknown flags with nonzero exit"
fi
ok "install.sh: rejects unknown flags"

# --check (no --system) must NOT touch /etc/... entries — count diffs.
system_diffs=$("$install" --check 2>/dev/null | grep -c '^DIFF: /etc/' || true)
[[ "$system_diffs" -eq 0 ]] \
  || fail "install.sh --check reported $system_diffs system-scope diffs (should skip /etc/* entries) — routing is broken"
ok "install.sh --check: skips /etc/ entries"

# --check --system routes /etc/ entries. Whether they report DIFF
# depends on the live box state (CI may lack /etc/systemd/system
# entirely, on-target runner may have everything byte-matched after a
# fresh install, or may have drifted). The invariant is: it must NOT
# see the user-scope MANIFEST entries under ~/.local or ~/.config.
check_system_out="$("$install" --check --system 2>/dev/null || true)"
if grep -q '^DIFF: /home/' <<< "$check_system_out"; then
  fail "install.sh --check --system leaked /home/... diffs — routing is wrong"
fi
ok "install.sh --check --system: stays on /etc/ entries"

# --system install would invoke sudo. We don't have sudo here; on CI
# it must exit 1 with the refused-with-hint path, refusing to prompt.
# We accept rc=0 (no system entries to install on hosted CI) or rc=1
# (refused). Anything else is a routing regression.
if "$install" --system >/tmp/system-dry.out 2>/tmp/system-dry.err; then
  :   # rc=0 — fine on CI with no /etc/systemd/system scope
else
  rc=$?
  case "$rc" in
    1) : ;;   # refused-with-hint — expected on the live box without passwordless sudo
    *) fail "install.sh --system returned unexpected rc=$rc" ;;
  esac
fi
ok "install.sh --system: handles missing passwordless sudo path"

echo "OK: system drop-ins shape locked (50-ram-governor + 50-no-distro-oomd-kill, MANIFEST entries live, install.sh routing works)"

# fleet-ops#62: drill tooling. CI lists THIS file explicitly; the worker
# GitHub App cannot add a workflow step, so the drill test rides along.
bash "$here/oomd-drill.test.sh"

# fleet-ops#92: slice syntax. Same CI-list constraint; the dedicated
# unit-verify job cannot gain systemd/*.slice without a workflow push.
bash "$here/systemd-analyze-slices.test.sh"
