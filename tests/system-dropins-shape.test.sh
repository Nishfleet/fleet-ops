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
#   6. fleet-ops#1499: the user-scope BASE unit files
#      (fleet-completion-canary.{service,timer},
#      fleet-metrics-export.{service,timer}) are repo-owned under systemd/
#      AND have exact MANIFEST entries, and the metrics-export drop-ins
#      (fleet-metrics-export.service.d/) are kept + MANIFEST-listed. The
#      #1480 audit found these base units hand-placed in
#      ~/.config/systemd/user/ bypassing the repo; #2097 moved them in.
#      This guard stops the migration gap silently re-opening.
#
# Lock-and-leave. If any invariant fails, exit 1 and CI fails.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

gov="$repo_root/systemd/system/user-1000.slice.d/50-ram-governor.conf"
ndk="$repo_root/systemd/system/user@1000.service.d/50-no-distro-oomd-kill.conf"
ts="$repo_root/systemd/system/tailscaled.service.d/50-restart-always.conf"
manifest="$repo_root/MANIFEST"
install="$repo_root/install.sh"

# 1. File existence.
[[ -f "$gov" ]] || fail "missing: $gov"
[[ -f "$ndk" ]] || fail "missing: $ndk"
[[ -f "$ts" ]] || fail "missing: $ts"

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
ts_line="systemd/system/tailscaled.service.d/50-restart-always.conf /etc/systemd/system/tailscaled.service.d/50-restart-always.conf"
grep -Fxq "$gov_line" "$manifest" \
  || fail "MANIFEST missing entry: $gov_line"
grep -Fxq "$ndk_line" "$manifest" \
  || fail "MANIFEST missing entry: $ndk_line"
grep -Fxq "$ts_line" "$manifest" \
  || fail "MANIFEST missing entry: $ts_line"

# fleet-ops#455: tailscaled is the access-plane lifeline. Restart=always
# plus no start limit so systemd never benches it.
grep -q '^\[Unit\]$' "$ts" || fail "50-restart-always.conf: missing [Unit] (StartLimitIntervalSec lives there)"
grep -q '^StartLimitIntervalSec=0$' "$ts" \
  || fail "50-restart-always.conf: StartLimitIntervalSec=0"
grep -q '^\[Service\]$' "$ts" || fail "50-restart-always.conf: missing [Service]"
grep -q '^Restart=always$' "$ts" || fail "50-restart-always.conf: Restart=always"
grep -q '^RestartSec=5s$' "$ts" || fail "50-restart-always.conf: RestartSec=5s"

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

echo "OK: system drop-ins shape locked (50-ram-governor + 50-no-distro-oomd-kill + tailscaled Restart=always, MANIFEST entries live, install.sh routing works)"

# --- 6. fleet-ops#1499: user-scope BASE units repo-owned + MANIFEST-listed --
# The #1480 audit found these base unit files hand-placed in
# ~/.config/systemd/user/ and bypassing the repo; #2097 moved them into
# systemd/ + MANIFEST. Lock both halves: base units repo-owned + listed, and
# the metrics-export drop-ins kept + listed.
cc_svc="$repo_root/systemd/fleet-completion-canary.service"
cc_tmr="$repo_root/systemd/fleet-completion-canary.timer"
me_svc="$repo_root/systemd/fleet-metrics-export.service"
me_tmr="$repo_root/systemd/fleet-metrics-export.timer"
[[ -f "$cc_svc" ]] || fail "missing base unit: $cc_svc"
[[ -f "$cc_tmr" ]] || fail "missing base unit: $cc_tmr"
[[ -f "$me_svc" ]] || fail "missing base unit: $me_svc"
[[ -f "$me_tmr" ]] || fail "missing base unit: $me_tmr"

for entry in \
  "systemd/fleet-completion-canary.service /home/nish/.config/systemd/user/fleet-completion-canary.service" \
  "systemd/fleet-completion-canary.timer /home/nish/.config/systemd/user/fleet-completion-canary.timer" \
  "systemd/fleet-metrics-export.service /home/nish/.config/systemd/user/fleet-metrics-export.service" \
  "systemd/fleet-metrics-export.timer /home/nish/.config/systemd/user/fleet-metrics-export.timer" \
; do
  grep -Fxq "$entry" "$manifest" \
    || fail "MANIFEST missing base-unit entry (fleet-ops#1499): $entry"
done
ok "fleet-ops#1499: completion-canary + metrics-export base units repo-owned + MANIFEST-listed"

me_dropdir="$repo_root/systemd/fleet-metrics-export.service.d"
for d in 10-git-mirrors.conf staleness-checker.conf waste-ledger.conf; do
  [[ -f "$me_dropdir/$d" ]] || fail "missing drop-in (fleet-ops#1499 keep-drop-ins): $me_dropdir/$d"
  grep -Fxq "systemd/fleet-metrics-export.service.d/$d /home/nish/.config/systemd/user/fleet-metrics-export.service.d/$d" "$manifest" \
    || fail "MANIFEST missing drop-in entry (fleet-ops#1499): systemd/fleet-metrics-export.service.d/$d"
done
ok "fleet-ops#1499: metrics-export drop-ins kept (10-git-mirrors + staleness-checker + waste-ledger) + MANIFEST-listed"

# fleet-ops#62: drill tooling. CI lists THIS file explicitly; the worker
# GitHub App cannot add a workflow step, so the drill test rides along.
bash "$here/oomd-drill.test.sh"

# fleet-ops#92: slice syntax. Same CI-list constraint; the dedicated
# unit-verify job cannot gain systemd/*.slice without a workflow push.
bash "$here/systemd-analyze-slices.test.sh"

# fleet-ops#3280: fleet-work.slice TasksMax=8000 + spawn-guard 7500/8000.
# Same CI-list constraint; workers cannot push .github/workflows/**.
bash "$here/fleet-work-slice-tasksmax.test.sh"
