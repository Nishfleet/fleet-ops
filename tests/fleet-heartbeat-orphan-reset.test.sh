#!/usr/bin/env bash
# tests/fleet-heartbeat-orphan-reset.test.sh
#
# fleet-ops#3617: the tier1 orphan-pass released a dead worker's claim but
# never cleared the corresponding `pi-issue@<repo>-<issue>.service` failed
# state. Those units are `observe`-class at §4 and the OnFailure reaper only
# clears its own happy path, so a released claim left the unit sitting in
# `failed` forever. The blind-audit's failed-units lens then re-filed it as
# an "orphan systemd unit is failed" gap-audit every cycle (fleet-ops#3617).
#
# This test pins the fix:
#   A. The orphan-pass must reset-failed the dead worker's unit exactly when
#      it determines the claim is orphaned (no live process, no open PR),
#      using `pi-issue@${short}-${issue_n}.service` — safe because the unit
#      has ConditionPathExists on its .in packet, so a stray restart is a
#      clean SKIP, and reset-failed is a no-op when the unit is not failed.
#   B. reset-failed is a plain `systemctl --user reset-failed` (no agent
#      lane), so the cleanup works even with a dead provider.
#   C. The release block still does the claim work (branch delete, label
#      flip, comment) after the unit state is cleared.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-heartbeat-tier1"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

# --- Phase A: the orphan-release path resets-failed the dead worker unit ----
# The orphan-pass owns direction A: an issue with agent-in-progress / no live
# pi-issue@ unit / no open claim PR. When it releases the claim it must also
# clear the unit's failed state so the audit stops re-filing it.
line=$(grep -nF 'systemctl --user reset-failed "pi-issue@${short}-${issue_n}.service"' "$bin" | head -1) \
    || fail "orphan-pass must reset-failed the released dead worker unit: systemctl --user reset-failed pi-issue@\${short}-\${issue_n}\.service"
orphan_line=$(printf '%s\n' "$line" | cut -d: -f1)
release_line=$(grep -nF '# Orphan. Release it.' "$bin" | head -1 | cut -d: -f1)
[[ -n "$release_line" ]] || fail "could not find '# Orphan. Release it.' marker in $bin"
[[ "$orphan_line" -gt "$release_line" ]] \
    || fail "reset-failed must be inside the orphan-release block (after '# Orphan. Release it.', got line $orphan_line vs marker $release_line)"
# It must be gated behind the orphan determination, i.e. before the branch delete
# that also only happens once an orphan is identified.
branch_line=$(grep -nF 'gh api "repos/${repo}/git/refs/heads/${branch}"' "$bin" | head -1 | cut -d: -f1)
[[ -n "$branch_line" ]] || fail "could not find the orphan branch-delete in $bin"
[[ "$orphan_line" -lt "$branch_line" ]] \
    || fail "reset-failed must run once an orphan is determined (before branch delete, got line $orphan_line vs $branch_line)"
ok "orphan-pass reset-failed is placed inside the orphan-release block, before the branch delete"

# --- Phase B: reset-failed is a plain systemctl call (agent-lane-independent)
grep -qF 'systemctl --user reset-failed' <(printf '%s\n' "$line") \
    || fail "orphan reset must be a plain systemctl --user reset-failed (no agent lane)"
ok "orphan reset-failed uses the plain systemctl floor (works with a dead provider)"

# --- Phase C: release block still does the claim work after clearing state --
# The reset is followed by `&& log ... || true` across its continuation so a
# failure to reset cannot abort the release, and the branch-delete / label-flip
# follow unconditionally.
if ! awk -v ln="$orphan_line" -v n="$(( orphan_line + 1 ))" \
        'NR==ln||NR==n' "$bin" | grep -q '|| true'; then
    fail "orphan reset-failed must tolerate failure (trailing '|| true') so it cannot abort the claim release"
fi
ok "orphan reset-failed is non-fatal (cannot block the claim release)"

# --- Phase D: functional — reset-failed clears a failed unit to inactive -----
# Prove the underlying semantics the fix depends on: on the live host,
# `systemctl --user reset-failed` on a failed oneshot returns the unit to
# inactive (no accidental start). We do this WITHOUT creating a fleet unit by
# using a throwaway stub under the gap-closure drill slice, mirroring
# fleet-gap-closure-drill's fault-injection pattern.
if [ "${CI:-}" = "true" ]; then
    ok "CI: skipping live systemd reset-failed proof (no user systemd in CI)"
else
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    stub="fleet-orphan-reset-probe@$$.service"
    # A throwaway oneshot that fails on demand.
    if ! systemctl --user cat "$stub" >/dev/null 2>&1; then
        mkdir -p "${XDG_RUNTIME_DIR}/systemd/user"
        printf '[Unit]\nDescription=orphan-reset probe\n[Service]\nType=oneshot\nExecStart=/bin/false\n' \
            > "${XDG_RUNTIME_DIR}/systemd/user/$stub"
        systemctl --user daemon-reload 2>/dev/null || true
    fi
    systemctl --user reset-failed "$stub" >/dev/null 2>&1 || true
    systemctl --user start "$stub" >/dev/null 2>&1 || true
    sleep 1
    st=$(systemctl --user show "$stub" --property=ActiveState --value 2>/dev/null || echo "")
    if [ "$st" != "failed" ]; then
        systemctl --user reset-failed "$stub" >/dev/null 2>&1 || true
        rm -f "${XDG_RUNTIME_DIR}/systemd/user/$stub"
        fail "probe did not reach failed state before reset (ActiveState=$st)"
    fi
    systemctl --user reset-failed "$stub" >/dev/null 2>&1 || true
    after=$(systemctl --user show "$stub" --property=ActiveState --value 2>/dev/null || echo "")
    rm -f "${XDG_RUNTIME_DIR}/systemd/user/$stub"
    systemctl --user daemon-reload 2>/dev/null || true
    if [ "$after" = "failed" ]; then
        fail "reset-failed did not clear the dead unit's failed state (still $after)"
    fi
    ok "live: reset-failed cleared a dead oneshot's failed state to $after (no accidental start)"
fi

echo "ALL PASS: fleet-heartbeat-orphan-reset"
