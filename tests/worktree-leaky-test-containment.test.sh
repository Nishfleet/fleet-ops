#!/usr/bin/env bash
# tests/worktree-leaky-test-containment.test.sh
#
# fleet-ops#2769: containment detector for the leaky
# tests/alert-repair-class-park-skip.test.sh phantom-worker vector.
#
# Background: PR #2660 (commit 3b82c00f, merged 2026-09-01) added
# `export ALERT_REPAIR_NO_SPAWN=1` to tests/alert-repair-class-park-skip.test.sh
# so the dispatcher's spawn guard suppresses real pi-systemd-run units during
# the test. Worktrees created BEFORE that commit still carry the leaky test
# (no export). Any agent running that test in a leaky worktree spawns 3 real
# pi-systemd-run units for fixture alertnames with no Prometheus rules —
# re-triggering the phantom-alert amplification loop (workers fail, exit
# non-zero, OnFailure re-summons the senior auditor, which runs the test
# again). 100+ phantom packets and 4 concurrent phantom workers accumulated
# on 2026-08-31..09-01.
#
# What this detector does:
#   1. Enumerates every directory under the configured worktree roots
#      (default: ~/workspaces/agent-worktrees/ and
#      ~/workspaces/tooling/fleet-ops-1164/ if it exists).
#   2. For each worktree that contains tests/alert-repair-class-park-skip.test.sh:
#      a. STATIC CHECK: grep the test file for the ALERT_REPAIR_NO_SPAWN guard.
#         - Guard ABSENT  -> LEAKY. The worktree is flagged and FAILS. The
#           test is NOT run dynamically (running it would spawn the very
#           phantom workers we are trying to prevent — see SAFETY note below).
#         - Guard PRESENT -> proceed to dynamic confirmation.
#      b. DYNAMIC CHECK (fixed worktrees only): run the test in a subprocess
#         with ALERT_REPAIR_NO_SPAWN unset in the parent env. The test
#         re-exports the guard internally, so the dispatcher must suppress
#         the spawn. Count active pi-systemd-run units before/after; assert
#         zero delta.
#   3. Exit non-zero if any leaky worktree is found, or any fixed worktree
#      shows a non-zero spawn delta. The forcing function: a failing
#      worktree must be rebased or recreated from origin/main.
#
# SAFETY NOTE (why leaky worktrees are caught statically, not dynamically):
# The issue's accept criteria describe running the test with the guard unset
# and counting spawns. Running the LEAKY test, however, IS the harm — it
# spawns 3 real pi-systemd-run units per leaky worktree (the dispatcher
# prepends $HOME/.local/bin to PATH, so a PATH shim cannot intercept it;
# only the in-process ALERT_REPAIR_NO_SPAWN guard suppresses the spawn, and
# that guard is absent in a leaky worktree). A dynamic run on 10 leaky
# worktrees would burn 30 fleet seats — the exact amplification this detector
# exists to prevent. The static grep detects the same condition (guard
# absent) with zero side effects. Fixed worktrees ARE run dynamically to
# prove the guard actually suppresses the spawn end-to-end.
#
# Hermetic self-test: before the live scan, this script builds scratch
# fixture worktrees (one fixed, one leaky) and proves the detector catches
# the leaky fixture and passes the fixed fixture. The self-test is the
# green-run proof for the PR; the live scan is the detector in production.
#
# Overlay: set WORKTREE_LEAKY_ROOTS to a colon-separated list of dirs to
# scan instead of the live roots (used by the self-test and CI).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
leaky_test_rel="tests/alert-repair-class-park-skip.test.sh"
guard_marker='ALERT_REPAIR_NO_SPAWN'

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }
warn() { echo "WARN: $*" >&2; }

[[ -f "$repo_root/$leaky_test_rel" ]] \
    || fail "missing $repo_root/$leaky_test_rel (run from a fleet-ops checkout)"
grep -q "$guard_marker" "$repo_root/$leaky_test_rel" \
    || fail "this checkout's own $leaky_test_rel is LEAKY (no $guard_marker guard) — rebase from origin/main first"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Count active pi-systemd-run units. Returns 0 if systemctl --user is
# unavailable (CI). Never fails — a missing systemctl is a SKIP, not an error.
_count_pi_systemd_run() {
    local xdg="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    if ! command -v systemctl >/dev/null 2>&1; then
        echo 0
        return
    fi
    XDG_RUNTIME_DIR="$xdg" systemctl --user list-units --state=active 2>/dev/null \
        | grep -c 'pi-systemd-run' || true
}

# Check a single worktree dir for the leaky test.
# Echoes one of:
#   NO-TEST   — the worktree has no tests/alert-repair-class-park-skip.test.sh
#   FIXED     — guard present
#   LEAKY     — guard absent (the test file exists but has no ALERT_REPAIR_NO_SPAWN)
# Sets global CHECKED_TEST to the path of the test file when not NO-TEST.
_check_worktree_static() {
    local wt="$1"
    local tf="$wt/$leaky_test_rel"
    if [[ ! -f "$tf" ]]; then
        CHECKED_TEST=""
        echo "NO-TEST"
        return
    fi
    CHECKED_TEST="$tf"
    if grep -q "$guard_marker" "$tf" 2>/dev/null; then
        echo "FIXED"
    else
        echo "LEAKY"
    fi
}

# Dynamic confirmation for a FIXED worktree: run its test with the guard
# unset in the parent env, count pi-systemd-run units before/after, assert
# zero delta. Returns 0 on zero delta, 1 on spawn.
# Skips (returns 0 with a note) if systemctl --user is unavailable.
_check_worktree_dynamic() {
    local wt="$1"
    local tf="$wt/$leaky_test_rel"
    if ! command -v systemctl >/dev/null 2>&1; then
        warn "  dynamic check skipped (no systemctl --user; not on VPS)"
        return 0
    fi
    local before after delta
    before=$(_count_pi_systemd_run)
    # env -u unsets the guard in the child env; the test re-exports it
    # internally if it is fixed, so the dispatcher must suppress the spawn.
    if ! env -u ALERT_REPAIR_NO_SPAWN bash "$tf" >/dev/null 2>&1; then
        # The test itself may exit non-zero for its own assertion reasons;
        # that is not a spawn. We only care about the unit-count delta.
        :
    fi
    after=$(_count_pi_systemd_run)
    delta=$((after - before))
    if [[ "$delta" -ne 0 ]]; then
        echo "SPAWN-DELTA=$delta (before=$before after=$after)"
        return 1
    fi
    echo "zero-spawn (before=$before after=$after)"
    return 0
}

# Enumerate worktree dirs from a root, echo each dir path on its own line.
# Only echoes dirs that look like worktree checkouts (have a .git file or dir).
_enum_root() {
    local root="$1"
    [[ -d "$root" ]] || return 0
    local d
    for d in "$root"/*/; do
        [[ -d "$d" ]] || continue
        echo "${d%/}"
    done
}

# ---------------------------------------------------------------------------
# 1. Hermetic self-test: fixture worktrees
# ---------------------------------------------------------------------------
echo "--- hermetic self-test ---"

scratch="$(mktemp -d -t wtree-leaky.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Build a minimal fleet-ops-shaped fixture worktree with the test file.
# Fixed fixture: the test file has the ALERT_REPAIR_NO_SPAWN guard.
# Leaky fixture: the test file lacks the guard.
fix_wt="$scratch/fixture-fixed"
leak_wt="$scratch/fixture-leaky"
mkdir -p "$fix_wt/tests" "$leak_wt/tests"

cat >"$fix_wt/$leaky_test_rel" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export ALERT_REPAIR_NO_SPAWN=1
echo "fixture fixed test (guard present)"
EOF
chmod +x "$fix_wt/$leaky_test_rel"

cat >"$leak_wt/$leaky_test_rel" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "fixture leaky test (no guard)"
EOF
chmod +x "$leak_wt/$leaky_test_rel"

# Self-test 1a: fixed fixture detected as FIXED
res=$(_check_worktree_static "$fix_wt")
[[ "$res" == "FIXED" ]] \
    || fail "self-test: fixed fixture should be FIXED, got $res"
ok "self-test 1a: fixed fixture detected as FIXED"

# Self-test 1b: leaky fixture detected as LEAKY
res=$(_check_worktree_static "$leak_wt")
[[ "$res" == "LEAKY" ]] \
    || fail "self-test: leaky fixture should be LEAKY, got $res"
ok "self-test 1b: leaky fixture detected as LEAKY"

# Self-test 1c: a dir without the test file is NO-TEST
no_test_wt="$scratch/fixture-no-test"
mkdir -p "$no_test_wt"
res=$(_check_worktree_static "$no_test_wt")
[[ "$res" == "NO-TEST" ]] \
    || fail "self-test: dir without test should be NO-TEST, got $res"
ok "self-test 1c: dir without test detected as NO-TEST"

# Self-test 1d: full scan over the scratch root finds exactly one leaky
# fixture and reports it.
leaky_found=0
fixed_found=0
while IFS= read -r wt; do
    res=$(_check_worktree_static "$wt")
    case "$res" in
        FIXED) fixed_found=$((fixed_found + 1)) ;;
        LEAKY) leaky_found=$((leaky_found + 1)) ;;
    esac
done < <(_enum_root "$scratch")
[[ "$fixed_found" -eq 1 ]] \
    || fail "self-test: expected 1 fixed fixture, got $fixed_found"
[[ "$leaky_found" -eq 1 ]] \
    || fail "self-test: expected 1 leaky fixture, got $leaky_found"
ok "self-test 1d: scan found 1 fixed + 1 leaky fixture (NO-TEST dir skipped)"

# Self-test 1e: the dynamic check on the fixed fixture shows zero spawn
# delta (or skips cleanly if no systemctl --user).
dyn=$(_check_worktree_dynamic "$fix_wt") \
    || fail "self-test: fixed fixture dynamic check reported spawn: $dyn"
ok "self-test 1e: fixed fixture dynamic check -> $dyn"

rm -rf "$scratch"
trap - EXIT INT TERM

# ---------------------------------------------------------------------------
# 2. Live scan
# ---------------------------------------------------------------------------
echo
echo "--- live scan ---"

# Resolve roots: explicit overlay, or the live VPS defaults.
if [[ -n "${WORKTREE_LEAKY_ROOTS:-}" ]]; then
    IFS=':' read -ra roots <<<"$WORKTREE_LEAKY_ROOTS"
else
    roots=()
    [[ -d "$HOME/workspaces/agent-worktrees" ]] \
        && roots+=("$HOME/workspaces/agent-worktrees")
    [[ -d "$HOME/workspaces/tooling/fleet-ops-1164" ]] \
        && roots+=("$HOME/workspaces/tooling/fleet-ops-1164")
fi

if [[ "${#roots[@]}" -eq 0 ]]; then
    warn "no worktree roots found (not on VPS, and WORKTREE_LEAKY_ROOTS unset) — live scan skipped"
    echo
    echo "ALL GOOD: hermetic self-test passed; live scan skipped (no roots)"
    exit 0
fi

leaky_list=()
spawn_list=()
scanned=0
has_test=0

for root in "${roots[@]}"; do
    echo "scanning root: $root"
    while IFS= read -r wt; do
        scanned=$((scanned + 1))
        res=$(_check_worktree_static "$wt")
        case "$res" in
            NO-TEST)
                ;;  # not a fleet-ops checkout or no leaky test
            FIXED)
                has_test=$((has_test + 1))
                dyn=$(_check_worktree_dynamic "$wt") || {
                    spawn_list+=("$wt (delta=$dyn)")
                    echo "  SPAWN: $wt -> $dyn"
                }
                echo "  FIXED: $wt -> $dyn"
                ;;
            LEAKY)
                has_test=$((has_test + 1))
                leaky_list+=("$wt")
                echo "  LEAKY: $wt (guard absent — rebase/recreate from origin/main)"
                ;;
        esac
    done < <(_enum_root "$root")
done

echo
echo "summary: scanned=$scanned worktrees-with-test=$has_test leaky=${#leaky_list[@]} spawn-failures=${#spawn_list[@]}"

if [[ "${#leaky_list[@]}" -gt 0 ]]; then
    echo
    echo "LEAKY WORKTREES (rebase or recreate each from origin/main):"
    for wt in "${leaky_list[@]}"; do
        echo "  $wt"
    done
fi

if [[ "${#spawn_list[@]}" -gt 0 ]]; then
    echo
    echo "SPAWN FAILURES (fixed worktree still spawned units — guard broken):"
    for wt in "${spawn_list[@]}"; do
        echo "  $wt"
    done
fi

if [[ "${#leaky_list[@]}" -gt 0 || "${#spawn_list[@]}" -gt 0 ]]; then
    echo
    fail "containment failed: ${#leaky_list[@]} leaky worktree(s), ${#spawn_list[@]} spawn failure(s)"
fi

echo
echo "ALL GOOD: $has_test worktree(s) with the test, all fixed, zero phantom spawns"
