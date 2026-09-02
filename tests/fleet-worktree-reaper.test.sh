#!/usr/bin/env bash
# tests/fleet-worktree-reaper.test.sh
#
# Proves the orphan worktree reaper (fleet-ops#2227, fleet-ops#2637)
# deletes ONLY worktrees whose cycle state is recorded as terminal AND
# whose work is preserved on origin AND whose tree is clean. Two modes:
#
#   Mode A (claim/issue-<N> + MERGED PR) — fleet-ops#2227 original.
#   Mode B (issue-<short>-<N> path + dispatch-ledger terminal) — fleet-ops#2637.
#
# Hermetic: fake gh (file-backed merged-PR answers), fake systemctl
# (live-unit marker files), local bare repos + worktrees, no network.
# The dispatch ledger is mocked via FLEET_DISPATCH_LEDGER pointing at a
# scratch JSONL.
#
# Cases:
#   Mode A (existing):
#     1. merged + terminal + clean        -> REAPED-A
#     2. merged + terminal + dirty        -> SKIPPED (left in place)
#     3. merged + LIVE worker             -> SKIPPED (never touch a live cycle)
#     4. NOT merged + terminal + clean    -> SKIPPED (no merged PR)
#     5. gh merged query fails for a repo -> SKIPPED (fail safe, never blind)
#     6. worktree on a non-claim branch   -> untouched (other mechanism owns it)
#     7. --dry-run                        -> reports, deletes nothing
#
#   Mode B (new — fleet-ops#2637):
#     9.  pi-issue path + ledger-terminal + pushed + clean -> REAPED-B
#    10.  pi-issue path + ledger-OPEN                       -> SKIP-B not-terminal
#    11.  pi-issue path + ledger-terminal + HEAD not on origin -> SKIP-B head-not-on-origin
#    12.  pi-issue path + ledger-terminal + LIVE worker     -> SKIP live
#    13.  pi-issue path + ledger-terminal + pushed + dirty  -> SKIP dirty
#    14.  ledger file missing                              -> SKIP-B not-terminal
#                                                            (fail closed, never blind)
#    15.  pi-issue path + multiple ledger entries (open -> salvaged) -> REAPED-B
#                                                            (most-recent wins)
#
#   16. MANIFEST + unit files present    -> install rail intact
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

# =====================================================================
# Mode B (fleet-ops#2637): pi-issue PATH + ledger-terminal + on origin
# =====================================================================
# The dispatch ledger is mocked as JSONL at $scratch/ledger.jsonl.
# FLEET_DISPATCH_LEDGER env override (see reaper source) wires the
# script to the scratch file. Each case adds a worktree on a NON-claim
# branch (main, fix/*, etc.) so Mode A's branch filter alone cannot
# touch it — only Mode B's path+ledger+pushed gates can.

# Helper: create a worktree on a non-claim branch, push it to origin,
# and return the path. push=0 leaves HEAD local (off origin) so the
# reaper's head_on_origin gate refuses.
add_path_worktree() {
    local parent="$1" wroot="$2" n="$3" branch="$4" push="${5:-1}" dirty="${6:-0}"
    local parent_base; parent_base=$(basename "$parent")
    local wt="$wroot/issue-${parent_base}-${n}"
    # Make a UNIQUE commit on the parent so the new branch points at a
    # SHA that is NOT on origin (the parent's HEAD == origin/main's SHA
    # at clone time, so without a new commit HEAD would be on origin and
    # the push=0 case would not exercise head_not_on_origin).
    printf 'wip-%s-%s\n' "$branch" "$n" >>"$parent/unpushed.txt"
    git_ident "$parent"
    git -C "$parent" add unpushed.txt
    git -C "$parent" commit -q -m "add wip-${branch}-${n}"
    git -C "$parent" branch -f "$branch" HEAD >/dev/null 2>&1
    git -C "$parent" worktree add -q -B "$branch" "$wt" 2>/dev/null
    if [ "$dirty" = 1 ]; then
        printf 'uncommitted\n' >"$wt/dirty.txt"
    fi
    if [ "$push" = 1 ]; then
        git -C "$wt" push -q origin "$branch" 2>/dev/null
    fi
    printf '%s' "$wt"
}

# Helper: append a ledger entry. Each arg is "<unit>|<status>|<ts>".
ledger_add() {
    for entry in "$@"; do
        local u="${entry%%|*}" rest="${entry#*|}"
        local s="${rest%%|*}" ts="${rest##*|}"
        jq -nc --arg u "$u" --arg s "$s" --arg ts "$ts" \
            '{unit:$u,status:$s,ts:$ts}' >>"$scratch/ledger.jsonl"
    done
}

# Make the test scratch + scratch ledger.
mkdir -p "$scratch"
: >"$scratch/ledger.jsonl"

# Re-point the reaper at the scratch ledger via FLEET_DISPATCH_LEDGER.
export FLEET_DISPATCH_LEDGER="$scratch/ledger.jsonl"

# --- 9. pi-issue path + ledger-terminal + pushed + clean -> REAPED-B ----
# Use a non-main branch (the parent has main checked out, so a worktree
# on main would refuse with "branch already checked out"). Mode B only
# cares about the PATH shape; the branch can be anything.
add_path_worktree "$parent_a" "$wroot" 300 "feature/mode-b-300" 1 0
ledger_add "pi-issue-fleet-ops-300|salvaged|2026-08-27T10:00:00Z"
out_b1=$("$bin" --root "$wroot" 2>&1) || true
[ ! -d "$wroot/issue-fleet-ops-300" ] \
    || fail "case9: path+terminal+pushed+clean should be REAPED-B; output: $out_b1"
ok "case9: pi-issue path + ledger-terminal + pushed + clean REAPED-B"

# --- 10. pi-issue path + ledger-OPEN -> SKIP-B not-terminal -------------
add_path_worktree "$parent_a" "$wroot" 301 "feature/mode-b-301" 1 0
ledger_add "pi-issue-fleet-ops-301|salvaged|2026-08-27T10:00:00Z" \
           "pi-issue-fleet-ops-301|open|2026-09-01T10:00:00Z"
out_b2=$("$bin" --root "$wroot" 2>&1) || true
[ -d "$wroot/issue-fleet-ops-301" ] \
    || fail "case10: open-ledger worktree must NOT be reaped; output: $out_b2"
echo "$out_b2" | grep -q "issue-fleet-ops-301: SKIP-B not-ledger-terminal" \
    || fail "case10: expected SKIP-B not-ledger-terminal; output: $out_b2"
ok "case10: pi-issue path + ledger-OPEN SKIP-B not-terminal"

# --- 11. pi-issue path + ledger-terminal + HEAD not on origin -> SKIP-B ---
# push=0 leaves HEAD off origin; ledger-terminal otherwise satisfied.
add_path_worktree "$parent_a" "$wroot" 302 "feature/mode-b-302" 0 0
ledger_add "pi-issue-fleet-ops-302|salvaged|2026-08-27T10:00:00Z"
out_b3=$("$bin" --root "$wroot" 2>&1) || true
[ -d "$wroot/issue-fleet-ops-302" ] \
    || fail "case11: HEAD-not-on-origin worktree must NOT be reaped; output: $out_b3"
echo "$out_b3" | grep -q "issue-fleet-ops-302: SKIP-B head-not-on-origin" \
    || fail "case11: expected SKIP-B head-not-on-origin; output: $out_b3"
ok "case11: pi-issue path + HEAD-not-on-origin SKIP-B"

# --- 12. pi-issue path + ledger-terminal + LIVE worker -> SKIP live -----
add_path_worktree "$parent_a" "$wroot" 303 "feature/mode-b-303" 1 0
printf 'running\n' >"$scratch/live/pi-issue@fleet-ops-303.service"
ledger_add "pi-issue-fleet-ops-303|salvaged|2026-08-27T10:00:00Z"
out_b4=$("$bin" --root "$wroot" 2>&1) || true
[ -d "$wroot/issue-fleet-ops-303" ] \
    || fail "case12: live-worker worktree must NOT be reaped; output: $out_b4"
echo "$out_b4" | grep -q "issue-fleet-ops-303: SKIP live worker" \
    || fail "case12: expected SKIP live worker; output: $out_b4"
ok "case12: pi-issue path + LIVE worker SKIP live"
rm -f "$scratch/live/pi-issue@fleet-ops-303.service"

# --- 13. pi-issue path + ledger-terminal + pushed + dirty -> SKIP dirty --
add_path_worktree "$parent_a" "$wroot" 304 "feature/mode-b-304" 1 1
ledger_add "pi-issue-fleet-ops-304|salvaged|2026-08-27T10:00:00Z"
out_b5=$("$bin" --root "$wroot" 2>&1) || true
[ -d "$wroot/issue-fleet-ops-304" ] \
    || fail "case13: dirty worktree must NOT be reaped; output: $out_b5"
echo "$out_b5" | grep -q "issue-fleet-ops-304: SKIP dirty" \
    || fail "case13: expected SKIP dirty; output: $out_b5"
ok "case13: pi-issue path + dirty SKIP dirty"

# --- 14. ledger file missing -> SKIP-B not-terminal (fail closed) -------
add_path_worktree "$parent_a" "$wroot" 305 "feature/mode-b-305" 1 0
rm -f "$scratch/ledger.jsonl"
out_b6=$("$bin" --root "$wroot" 2>&1) || true
[ -d "$wroot/issue-fleet-ops-305" ] \
    || fail "case14: missing-ledger worktree must NOT be reaped; output: $out_b6"
echo "$out_b6" | grep -q "issue-fleet-ops-305: SKIP-B not-ledger-terminal" \
    || fail "case14: expected SKIP-B not-ledger-terminal when ledger absent; output: $out_b6"
ok "case14: missing ledger SKIP-B not-terminal (fail closed)"
# Recreate ledger for the next case.
: >"$scratch/ledger.jsonl"

# --- 15. multiple ledger entries (open -> salvaged): most-recent wins ---
add_path_worktree "$parent_a" "$wroot" 306 "feature/mode-b-306" 1 0
ledger_add "pi-issue-fleet-ops-306|open|2026-08-25T10:00:00Z" \
           "pi-issue-fleet-ops-306|salvaged|2026-09-01T10:00:00Z"
out_b7=$("$bin" --root "$wroot" 2>&1) || true
[ ! -d "$wroot/issue-fleet-ops-306" ] \
    || fail "case15: open->salvaged sequence must REAP (most recent wins); output: $out_b7"
ok "case15: most-recent ledger status wins (open -> salvaged -> REAPED-B)"

# --- Mode A/B interaction: a worktree on claim/issue-N AND a path-shape ---
# Mode A wins when the branch matches AND the PR is merged (existing
# behavior, regression). The path-shape check would also match, but
# Mode A's merged-PR gate is the stricter / earlier check. Verify the
# worktree is reaped via Mode A and counted in reaped_a (not reaped_b).
add_claim_worktree "$parent_a" "$wroot" 307
out_b8=$("$bin" --root "$wroot" 2>&1) || true
[ ! -d "$wroot/issue-fleet-ops-307" ] \
    || fail "case-interaction: claim-branch+merged should still be REAPED-A; output: $out_b8"
echo "$out_b8" | grep -q "issue-fleet-ops-307: REAPED-A" \
    || fail "case-interaction: expected REAPED-A tag; output: $out_b8"
ok "Mode A wins over Mode B when branch matches AND PR is merged"

# --- 17. claim/issue-N + NO merged PR + ledger-terminal -> SKIP not-merged ---
# (fleet-ops#2676 — issue's exact scenario, combined gates). A claim
# branch whose cycle is ledger-terminal but whose PR was NEVER merged
# must NOT be reaped. Mode A is the chosen mode for claim/issue-N
# branches; if Mode A's merged gate fails, the reaper must NOT fall
# through to Mode B (which would otherwise pass on the same path+ledger
# gates). The work is on origin only via the branch ref, and the
# branch was never merged — the safe call is to leave the worktree
# alone. Without this guard, a worker whose claim cycle ended in
# `salvaged` (no PR landed) would silently lose its worktree.
add_claim_worktree_ledger() {
    local parent="$1" wroot="$2" n="$3"
    local parent_base; parent_base=$(basename "$parent")
    local wt="$wroot/issue-${parent_base}-${n}"
    # claim/issue-N branch (no merged PR for N+400 in fake gh state)
    git -C "$parent" worktree add -q -B "claim/issue-${n}" "$wt" 2>/dev/null
    # ledger-terminal entry for this unit (most-recent is terminal)
    ledger_add "pi-issue-${parent_base}-${n}|salvaged|2026-09-01T10:00:00Z"
    printf '%s' "$wt"
}
# claim/issue-408 (next free number above 307): ledger says salvaged, but
# no merged PR entry -> SKIP not-merged, NOT a Mode-B fallthrough.
add_claim_worktree_ledger "$parent_a" "$wroot" 408
# Capture the unmerged/notterminal counters from the prior run (case
# Mode-A/B-interaction) so we can prove case 17 incremented only one.
prior_summary=$(echo "$out_b8" | grep -E '^fleet-worktree-reaper ' | tail -1)
prior_unmerged=$(printf '%s' "$prior_summary" | sed -nE 's/.*unmerged=([0-9]+).*/\1/p')
prior_notterminal=$(printf '%s' "$prior_summary" | sed -nE 's/.*notterminal=([0-9]+).*/\1/p')
out_b9=$("$bin" --root "$wroot" 2>&1) || true
[ -d "$wroot/issue-fleet-ops-408" ] \
    || fail "case17: claim+ledger-terminal+no-merged-PR must NOT be reaped; output: $out_b9"
echo "$out_b9" | grep -q "issue-fleet-ops-408: SKIP not-merged" \
    || fail "case17: expected SKIP not-merged (Mode A's gate); output: $out_b9"
# Safety: Mode B's notterminal counter must NOT have moved — proves
# the reaper did not consult Mode B as a fallthrough when Mode A's
# merged gate failed. If a future refactor lets the same worktree
# fall through to Mode B, the notterminal counter would increment and
# this assertion fails.
post_summary=$(echo "$out_b9" | grep -E '^fleet-worktree-reaper ' | tail -1)
post_unmerged=$(printf '%s' "$post_summary" | sed -nE 's/.*unmerged=([0-9]+).*/\1/p')
post_notterminal=$(printf '%s' "$post_summary" | sed -nE 's/.*notterminal=([0-9]+).*/\1/p')
[ "$post_unmerged" = "$((prior_unmerged + 1))" ] \
    || fail "case17: unmerged must increment by 1 (Mode A's gate), was prior=$prior_unmerged post=$post_unmerged; output: $out_b9"
[ "$post_notterminal" = "$prior_notterminal" ] \
    || fail "case17: notterminal must NOT move (no Mode B fallthrough), was prior=$prior_notterminal post=$post_notterminal; output: $out_b9"
ok "case17: claim branch + no merged PR + ledger-terminal SKIP not-merged (no Mode-B fallthrough)"

# --- 16. install rail intact -----------------------------------------------
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
