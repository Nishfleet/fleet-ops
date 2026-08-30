#!/usr/bin/env bash
# tests/fleet-worktree-reaper.test.sh
#
# Proves the orphan worktree reaper (fleet-ops#2227) deletes ONLY worktrees
# whose claim branch is merged AND whose worker cycle is terminal AND whose
# tree is clean. Hermetic: fake gh (file-backed merged-PR answers), fake
# systemctl (live-unit marker files), local bare repos + worktrees, no network.
#
# Cases:
#   1. merged + terminal + clean        -> REAPED
#   2. merged + terminal + dirty        -> SKIPPED (left in place)
#   3. merged + LIVE worker             -> SKIPPED (never touch a live cycle)
#   4. NOT merged + terminal + clean    -> SKIPPED (no merged PR)
#   5. gh merged query fails for a repo -> SKIPPED (fail safe, never blind)
#   6. worktree on a non-claim branch   -> untouched (other mechanism owns it)
#   7. --dry-run                        -> reports, deletes nothing
#   8. MANIFEST + unit files present    -> install rail intact
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-worktree-reaper"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch="$(mktemp -d -t wt-reaper.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

mkdir -p "$scratch/bin" "$scratch/live" "$scratch/gh-state"

git_ident() {
    git -C "$1" config user.email reaper-test@localhost
    git -C "$1" config user.name reaper-test
}

# make_repo <name> -> echoes the clone path; origin is a bare remote so
# worktree add works and `git -C <parent> config remote.origin.url` resolves
# to a file:// URL. The reaper parses owner/repo from the URL's last segment.
make_repo() {
    local name="$1"
    local bare="$scratch/${name}.git"
    local clone="$scratch/${name}"
    git -c init.defaultBranch=main init -q --bare "$bare"
    git clone -q "$bare" "$clone"
    git_ident "$clone"
    printf 'base\n' >"$clone/README"
    git -C "$clone" add README
    git -C "$clone" commit -q -m base
    git -C "$clone" push -q origin HEAD:main
    git -C "$clone" checkout -q -B main origin/main
    printf '%s' "$clone"
}

# add_claim_worktree <parent> <wt-root> <N> [<dirty>]
# Creates a worktree at <wt-root>/issue-<parent-basename>-<N> on
# claim/issue-<N>, and registers <N> as merged in the fake gh state.
add_claim_worktree() {
    local parent="$1" wroot="$2" n="$3" dirty="${4:-0}"
    local parent_base; parent_base=$(basename "$parent")
    local wt="$wroot/issue-${parent_base}-${n}"
    git -C "$parent" worktree add -q -B "claim/issue-${n}" "$wt" 2>/dev/null
    if [ "$dirty" = 1 ]; then
        printf 'uncommitted\n' >"$wt/dirty.txt"
    fi
    # Register merged PR for this claim branch on this repo.
    printf 'claim/issue-%s\n' "$n" >>"$scratch/gh-state/${parent_base}.merged"
}

# --- fake gh: answers `gh pr list -R <owner/repo> --state merged` ---------
# The reaper only uses `gh pr list --state merged --json headRefName`. The
# fake returns the merged set for the repo named on -R, or exits 1 to
# simulate a gh failure (case 5).
cat >"$scratch/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
repo=""
while [ $# -gt 0 ]; do
    case "$1" in
        -R) repo="$2"; shift 2 ;;
        *) shift ;;
    esac
done
# repo is OWNER/REPO; the merged file is keyed by repo basename.
base="${repo##*/}"
state="$GH_STATE_DIR/${base}.merged"
if [ -f "$GH_STATE_DIR/${base}.fail" ]; then
    exit 1
fi
if [ -f "$state" ]; then
    # Emit JSON array of {headRefName} for each merged claim branch.
    jq -R -s 'split("\n") | map(select(length>0)) | map({headRefName: .})' "$state"
else
    echo '[]'
fi
FAKE
chmod +x "$scratch/bin/gh"

# --- fake systemctl: live-unit marker files (mirrors claim-reconcile) -----
cat >"$scratch/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
# Only the two call shapes the reaper uses:
#   --user list-units <pattern> --state=... --no-legend
#   --user list-units --no-legend --type=service --state=running
if [ "${1:-}" = "--user" ]; then
    shift
    cmd="$1"; shift
    case "$cmd" in
        list-units)
            pattern=""; running=0
            while [ $# -gt 0 ]; do
                case "$1" in
                    --state=active,activating) ;;
                    --state=running) running=1 ;;
                    --no-legend|--type=service) ;;
                    --state=*) ;;
                    *) pattern="$1" ;;
                esac
                shift
            done
            if [ -n "$pattern" ]; then
                if [ -f "$FAKE_LIVE/$pattern" ]; then
                    printf '%s loaded active running\tfake\n' "$pattern"
                fi
                exit 0
            fi
            if [ "$running" = 1 ]; then
                ls "$FAKE_LIVE" 2>/dev/null | while IFS= read -r u; do
                    [ -f "$FAKE_LIVE/$u" ] && printf '%s loaded active running\tfake\n' "$u"
                done
            fi
            exit 0
            ;;
        *) exit 0 ;;
    esac
fi
exit 0
FAKE
chmod +x "$scratch/bin/systemctl"

export PATH="$scratch/bin:$PATH"
export SYSTEMCTL="$scratch/bin/systemctl"
export GH="$scratch/bin/gh"
export GH_STATE_DIR="$scratch/gh-state"
export FAKE_LIVE="$scratch/live"
export FLEET_WORKTREE_REAPER_MERGED_LIMIT=5000

# --- build repos + worktrees ----------------------------------------------
parent_a="$(make_repo fleet-ops)"
parent_b="$(make_repo proj-x)"
wroot="$scratch/agent-worktrees"
mkdir -p "$wroot"

# Case 1: merged + terminal + clean -> REAPED
add_claim_worktree "$parent_a" "$wroot" 100
# Case 2: merged + terminal + dirty -> SKIPPED
add_claim_worktree "$parent_a" "$wroot" 101 1
# Case 3: merged + LIVE worker -> SKIPPED
add_claim_worktree "$parent_a" "$wroot" 102
printf 'running\n' >"$scratch/live/pi-issue@fleet-ops-102.service"
# Case 4: NOT merged + terminal + clean -> SKIPPED (no merged entry for 103)
git -C "$parent_a" worktree add -q -B "claim/issue-103" "$wroot/issue-fleet-ops-103" 2>/dev/null
# Case 5: gh fails for proj-x -> all proj-x worktrees SKIPPED
add_claim_worktree "$parent_b" "$wroot" 200
printf '1\n' >"$scratch/gh-state/proj-x.fail"
# Case 6: non-claim branch worktree -> untouched
git -C "$parent_a" worktree add -q -B "feature/other" "$wroot/feature-other-fleet-ops" 2>/dev/null

before=$(find "$wroot" -mindepth 1 -maxdepth 1 -type d | wc -l)
echo "before: $before worktree dirs"

# --- run the reaper (live mode) -------------------------------------------
out=$("$bin" --root "$wroot" 2>&1) || true
echo "$out"

# Case 1: reaped
[ ! -d "$wroot/issue-fleet-ops-100" ] \
    || fail "case1: merged+terminal+clean worktree should be REAPED"
ok "case1: merged+terminal+clean reaped"

# Case 2: dirty skipped
[ -d "$wroot/issue-fleet-ops-101" ] \
    || fail "case2: dirty worktree must NOT be reaped"
ok "case2: dirty skipped"

# Case 3: live worker skipped
[ -d "$wroot/issue-fleet-ops-102" ] \
    || fail "case3: live-worker worktree must NOT be reaped"
ok "case3: live worker skipped"

# Case 4: unmerged skipped
[ -d "$wroot/issue-fleet-ops-103" ] \
    || fail "case4: unmerged worktree must NOT be reaped"
ok "case4: unmerged skipped"

# Case 5: gh-fail repo skipped (fail safe)
[ -d "$wroot/issue-proj-x-200" ] \
    || fail "case5: gh-failed repo worktrees must NOT be reaped (fail safe)"
ok "case5: gh-fail repo skipped"

# Case 6: non-claim worktree untouched
[ -d "$wroot/feature-other-fleet-ops" ] \
    || fail "case6: non-claim worktree must be untouched"
ok "case6: non-claim branch untouched"

# The reaper must report a reaped=1 line.
echo "$out" | grep -q 'reaped=1' || fail "summary should report reaped=1"
ok "summary reports reaped=1"

# --- 7. dry-run deletes nothing ------------------------------------------
# Re-add case 1's worktree so dry-run has something to report.
add_claim_worktree "$parent_a" "$wroot" 104
dry_out=$("$bin" --dry-run --root "$wroot" 2>&1) || true
[ -d "$wroot/issue-fleet-ops-104" ] \
    || fail "dry-run must not delete (case 104 still present)"
echo "$dry_out" | grep -q 'DRY-REAP' || fail "dry-run should report DRY-REAP"
ok "dry-run reports without deleting"
# Now actually reap it to leave a clean state.
"$bin" --root "$wroot" >/dev/null 2>&1 || true

# --- 8. install rail intact -----------------------------------------------
for f in bin/fleet-worktree-reaper \
         systemd/fleet-worktree-reaper.service \
         systemd/fleet-worktree-reaper.timer; do
    [ -f "$repo_root/$f" ] || fail "missing $f"
done
grep -q 'bin/fleet-worktree-reaper' "$repo_root/MANIFEST" \
    || fail "MANIFEST must install bin/fleet-worktree-reaper"
grep -q 'fleet-worktree-reaper.timer' "$repo_root/MANIFEST" \
    || fail "MANIFEST must install the timer"
ok "install rail (bin + units + MANIFEST) intact"

echo "all fleet-worktree-reaper cases passed"
