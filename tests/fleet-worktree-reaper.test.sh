#!/usr/bin/env bash
# tests/fleet-worktree-reaper.test.sh
#
# Proves the orphan worktree reaper (fleet-ops#2227, fleet-ops#2637,
# fleet-ops#2774) deletes ONLY worktrees whose cycle state is recorded
# as terminal AND whose work is preserved on origin AND whose tree is
# clean. Three modes:
#
#   Mode A (claim/issue-<N> + MERGED PR) — fleet-ops#2227 original.
#   Mode B (issue-<short>-<N> path + dispatch-ledger terminal) — fleet-ops#2637.
#   Mode C (any worktree + HEAD-on-origin + age gate) — fleet-ops#2774.
#
# Hermetic: fake gh (file-backed merged-PR answers), fake systemctl
# (live-unit marker files), local bare repos + worktrees, no network.
# The dispatch ledger is mocked via FLEET_DISPATCH_LEDGER pointing at a
# scratch JSONL. The age gate is tested via `touch -d` on the worktree
# directory.
#
# Cases:
#   Mode A (existing + fleet-ops#3023 CLOSED extension):
#     1. merged + terminal + clean        -> REAPED-A
#     2. merged + terminal + dirty        -> SKIPPED (left in place)
#     3. merged + LIVE worker             -> SKIPPED (never touch a live cycle)
#     4. NOT merged + terminal + clean    -> SKIPPED (no merged/closed PR)
#     5. gh closed query fails for a repo -> SKIPPED (fail safe, never blind)
#     6. worktree on a non-claim branch   -> REAPED-C (Mode C catch-all, fleet-ops#2774)
#     7. --dry-run                        -> reports, deletes nothing
#    25. CLOSED + terminal + clean + OLD  -> REAPED-A (closed)  [fleet-ops#3023]
#    26. CLOSED + terminal + clean + YOUNG-> SKIP-A closed-too-young [fleet-ops#3023]
#    27. CLOSED + terminal + dirty + old  -> SKIP dirty (common gate) [fleet-ops#3023]
#    28. CLOSED + LIVE worker             -> SKIP live (common gate) [fleet-ops#3023]
#
#   Mode B (fleet-ops#2637):
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
#   Mode C (fleet-ops#2774 — any branch, HEAD-on-origin + age gate):
#    18. fix/* branch + pushed + clean + old     -> REAPED-C
#    19. fix/* branch + pushed + clean + YOUNG   -> SKIP-C too-young
#    20. fix/* branch + NOT pushed + clean + old -> SKIP-C head-not-on-origin
#    21. fix/* branch + pushed + dirty + old     -> SKIP dirty
#    22. detached HEAD + on origin + clean + old -> REAPED-C
#
#   Summary file (fleet-ops#2965):
#    23. --summary-file PATH writes valid JSON run breakdown
#    24. --no-summary-file disables the write
#
#   Mode D (fleet-ops#3023 follow-through — stale dirty orphan salvage):
#    30. Mode C + dirty + STALE + banked   -> SALVAGE-BANKED + REAPED-C
#    31. Mode C + dirty + STALE + no-push  -> kept (unbanked, fail safe)
#    32. Mode C + dirty + YOUNG (<salvage age) -> SKIP dirty, helper NOT invoked
#    33. claim + merged PR + dirty + STALE -> SALVAGE-BANKED + REAPED-A
#    34. --dry-run + dirty + STALE          -> DRY-SALVAGE-CAND, no bank
#    35. --salvage-limit 0 + dirty + STALE  -> SKIP-D salvage-limit, no bank
#    36. summary JSON carries salvaged/salvage_attempts/salvage_candidates
#    37. Mode B + ledger-terminal + dirty + STALE + unpushed -> SALVAGE-BANKED
#        + REAPED-B (the pushed wip ref is the head-on-origin proof)
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

# add_closed_claim_worktree <parent> <wt-root> <N> [<dirty>] [<old>]
# Creates a worktree at <wt-root>/issue-<parent-basename>-<N> on
# claim/issue-<N>, and registers <N> as CLOSED (not merged) in the fake
# gh state — the orphan shape Mode A now reaps after the age gate
# (fleet-ops#3023). old=1 sets the directory mtime 2 days ago so the
# default 24h age gate passes.
add_closed_claim_worktree() {
    local parent="$1" wroot="$2" n="$3" dirty="${4:-0}" old="${5:-0}"
    local parent_base; parent_base=$(basename "$parent")
    local wt="$wroot/issue-${parent_base}-${n}"
    git -C "$parent" worktree add -q -B "claim/issue-${n}" "$wt" 2>/dev/null
    if [ "$dirty" = 1 ]; then
        printf 'uncommitted\n' >"$wt/dirty.txt"
    fi
    # Register CLOSED (not merged) PR for this claim branch.
    printf 'claim/issue-%s\n' "$n" >>"$scratch/gh-state/${parent_base}.closed"
    if [ "$old" = 1 ]; then
        touch -d '2 days ago' "$wt" 2>/dev/null || true
    fi
}

# --- fake gh: answers `gh pr list -R <owner/repo> --state closed` ----------
# The reaper queries `gh pr list --state closed --json headRefName,state`,
# which returns both MERGED and CLOSED PRs (a merged PR has state=MERGED
# inside the closed set). The fake reads per-repo .merged and .closed
# marker files and emits a combined JSON array with the state field, so
# Mode A can split MERGED (reap immediately) from CLOSED (reap after the
# age gate, fleet-ops#3023). A .fail marker simulates a gh failure (case 5).
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
# repo is OWNER/REPO; the state files are keyed by repo basename.
base="${repo##*/}"
if [ -f "$GH_STATE_DIR/${base}.fail" ]; then
    exit 1
fi
merged_file="$GH_STATE_DIR/${base}.merged"
closed_file="$GH_STATE_DIR/${base}.closed"
merged_json='[]'
closed_json='[]'
[ -f "$merged_file" ] && merged_json=$(jq -R -s 'split("\n")|map(select(length>0))|map({headRefName:.,state:"MERGED"})' "$merged_file")
[ -f "$closed_file" ] && closed_json=$(jq -R -s 'split("\n")|map(select(length>0))|map({headRefName:.,state:"CLOSED"})' "$closed_file")
jq -n --argjson m "$merged_json" --argjson c "$closed_json" '$m + $c'
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

# --- fake pi-salvage-worktree: Mode D bank helper ------------------------
# Emulates the real helper's contract: commit the worktree's dirt, create
# wip/<unit>-<NOW> pointing at the post-commit HEAD, push it to origin
# (the scratch bare repo via file://), and log `status=pushed`. A
# <basename>.no-push marker under $FAKE_SALVAGE_DIR emulates a
# quarantined/push-failed (local-only) salvage: the dirt is committed
# locally but nothing lands on origin, so the reaper's ls-remote proof
# must fail and the worktree is kept. Every invocation is appended to
# $FAKE_SALVAGE_DIR/invoked so cases can prove the helper was or was not
# called. Exporting PI_SALVAGE_BIN also guarantees the REAL helper is
# never invoked by any case in this file.
mkdir -p "$scratch/salvage-state"
cat >"$scratch/bin/pi-salvage-worktree" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
wt="${PI_SALVAGE_WORKDIR:?need PI_SALVAGE_WORKDIR}"
unit="${PI_SALVAGE_UNIT:?need PI_SALVAGE_UNIT}"
ts="${PI_SALVAGE_NOW:?need PI_SALVAGE_NOW}"
br="wip/${unit}-${ts}"
base="${wt##*/}"
printf '%s\n' "$wt" >>"${FAKE_SALVAGE_DIR:?need FAKE_SALVAGE_DIR}/invoked"
git -C "$wt" add -A -- . >/dev/null 2>&1
git -C "$wt" -c user.email=fleet-salvage@localhost -c user.name=fleet-salvage \
    commit -q -m "salvage: bank uncommitted work for unit ${unit}" >/dev/null 2>&1 || true
git -C "$wt" branch -f "$br" HEAD >/dev/null 2>&1 || true
status=local
if [ ! -f "$FAKE_SALVAGE_DIR/${base}.no-push" ]; then
    if git -C "$wt" push -q origin "HEAD:refs/heads/${br}" >/dev/null 2>&1; then
        status=pushed
    fi
fi
echo "salvaged branch=$br status=$status unit=$unit" >&2
FAKE
chmod +x "$scratch/bin/pi-salvage-worktree"

export PATH="$scratch/bin:$PATH"
export SYSTEMCTL="$scratch/bin/systemctl"
export GH="$scratch/bin/gh"
export GH_STATE_DIR="$scratch/gh-state"
export FAKE_LIVE="$scratch/live"
export FAKE_SALVAGE_DIR="$scratch/salvage-state"
export PI_SALVAGE_BIN="$scratch/bin/pi-salvage-worktree"
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
# Case 6: non-claim branch worktree -> Mode C candidate, but freshly
# created so the age gate skips it (too young). Proves the age gate
# protects a just-created worktree even when HEAD is on origin.
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

# Case 6: non-claim worktree skipped by Mode C age gate (too young)
[ -d "$wroot/feature-other-fleet-ops" ] \
    || fail "case6: young Mode C worktree must be skipped (age gate)"
ok "case6: non-claim branch skipped by Mode C age gate (too young)"

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

# =====================================================================
# Mode C (fleet-ops#2774): ANY worktree + HEAD-on-origin + age gate
# =====================================================================
# Mode C is the catch-all for worktrees not matched by Mode A (claim/
# issue-* branch) or Mode B (issue-<short>-<N> path). It reaps orphan
# worktrees on other branch shapes (fix/*, lane1/*, detached, …) when
# HEAD is on origin (the vault's safe-cleanup check), the tree is clean,
# and the worktree is older than --min-age-hours.

# Helper: create a Mode C worktree at a NON-issue path on a NON-claim
# branch. push=1 pushes the branch to origin; push=0 leaves HEAD local.
# dirty=1 adds an uncommitted file. old=1 sets the directory mtime far
# in the past so the age gate passes.
add_modec_worktree() {
    local parent="$1" wroot="$2" name="$3" branch="$4" \
          push="${5:-1}" dirty="${6:-0}" old="${7:-0}"
    local wt="$wroot/$name"
    # Unique commit so HEAD is NOT the base commit (avoids accidental
    # origin/main match when push=0).
    printf 'modec-%s-%s\n' "$branch" "$name" >>"$parent/modec.txt"
    git_ident "$parent"
    git -C "$parent" add modec.txt
    git -C "$parent" commit -q -m "modec-${branch}-${name}"
    git -C "$parent" branch -f "$branch" HEAD >/dev/null 2>&1
    git -C "$parent" worktree add -q -B "$branch" "$wt" 2>/dev/null
    if [ "$dirty" = 1 ]; then
        printf 'uncommitted\n' >"$wt/dirty.txt"
    fi
    if [ "$push" = 1 ]; then
        git -C "$wt" push -q origin "$branch" 2>/dev/null
    fi
    if [ "$old" = 1 ]; then
        # Set the worktree directory mtime to 2 days ago so the default
        # 24h age gate passes.
        touch -d '2 days ago' "$wt" 2>/dev/null || true
    fi
    printf '%s' "$wt"
}

# --- 18. fix/* branch + pushed + clean + old -> REAPED-C -------------------
add_modec_worktree "$parent_a" "$wroot" "fix-branch-500" "fix/mode-c-500" 1 0 1
out_c1=$("$bin" --root "$wroot" 2>&1) || true
[ ! -d "$wroot/fix-branch-500" ] \
    || fail "case18: fix/* + pushed + clean + old should be REAPED-C; output: $out_c1"
echo "$out_c1" | grep -q "fix-branch-500: REAPED-C" \
    || fail "case18: expected REAPED-C tag; output: $out_c1"
ok "case18: fix/* branch + pushed + clean + old REAPED-C"

# --- 19. fix/* branch + pushed + clean + YOUNG -> SKIP-C too-young ---------
add_modec_worktree "$parent_a" "$wroot" "fix-branch-501" "fix/mode-c-501" 1 0 0
out_c2=$("$bin" --root "$wroot" 2>&1) || true
[ -d "$wroot/fix-branch-501" ] \
    || fail "case19: young Mode C worktree must NOT be reaped; output: $out_c2"
echo "$out_c2" | grep -q "fix-branch-501: SKIP-C too-young" \
    || fail "case19: expected SKIP-C too-young; output: $out_c2"
ok "case19: fix/* branch + pushed + clean + YOUNG SKIP-C too-young"
# Now age it and reap to clean up.
touch -d '2 days ago' "$wroot/fix-branch-501" 2>/dev/null || true
"$bin" --root "$wroot" >/dev/null 2>&1 || true

# --- 20. fix/* branch + NOT pushed + clean + old -> SKIP-C head-not-on-origin
add_modec_worktree "$parent_a" "$wroot" "fix-branch-502" "fix/mode-c-502" 0 0 1
out_c3=$("$bin" --root "$wroot" 2>&1) || true
[ -d "$wroot/fix-branch-502" ] \
    || fail "case20: not-pushed Mode C worktree must NOT be reaped; output: $out_c3"
echo "$out_c3" | grep -q "fix-branch-502: SKIP-C head-not-on-origin" \
    || fail "case20: expected SKIP-C head-not-on-origin; output: $out_c3"
ok "case20: fix/* branch + NOT pushed SKIP-C head-not-on-origin"

# --- 21. fix/* branch + pushed + dirty + old -> SKIP dirty -----------------
add_modec_worktree "$parent_a" "$wroot" "fix-branch-503" "fix/mode-c-503" 1 1 1
out_c4=$("$bin" --root "$wroot" 2>&1) || true
[ -d "$wroot/fix-branch-503" ] \
    || fail "case21: dirty Mode C worktree must NOT be reaped; output: $out_c4"
echo "$out_c4" | grep -q "fix-branch-503: SKIP dirty" \
    || fail "case21: expected SKIP dirty; output: $out_c4"
ok "case21: fix/* branch + pushed + dirty SKIP dirty"

# --- 22. detached HEAD + on origin + clean + old -> REAPED-C ---------------
# Create a worktree, push its branch, then detach HEAD in the worktree
# to a commit that IS on origin (the pushed branch tip). A detached
# worktree whose HEAD SHA is on an origin ref is safe to reap.
add_modec_worktree "$parent_a" "$wroot" "detached-wt-504" "fix/detached-504" 1 0 1
# Detach HEAD in the worktree (it's at the branch tip, which is on origin).
git -C "$wroot/detached-wt-504" checkout -q --detach 2>/dev/null
out_c5=$("$bin" --root "$wroot" 2>&1) || true
[ ! -d "$wroot/detached-wt-504" ] \
    || fail "case22: detached + on-origin + clean + old should be REAPED-C; output: $out_c5"
echo "$out_c5" | grep -q "detached-wt-504: REAPED-C" \
    || fail "case22: expected REAPED-C tag for detached; output: $out_c5"
ok "case22: detached HEAD + on origin + clean + old REAPED-C"

# --- 23. --summary-file writes JSON run breakdown (fleet-ops#2965) ---------
# The reaper persists its run breakdown as JSON so the duty officer can
# see WHY worktree_dirs is high (reaped vs skipped_dirty vs
# skipped_notpushed) without grepping journalctl. Verify the file is
# valid JSON, has the expected fields, and reflects the run's counts.
summary_out="$(mktemp -t wt-reaper-summary.XXXXXX)"
add_modec_worktree "$parent_a" "$wroot" "fix-branch-600" "fix/mode-c-600" 1 0 1
out_s=$("$bin" --root "$wroot" --summary-file "$summary_out" 2>&1) || true
[ -f "$summary_out" ] || fail "case23: summary file not written"
jq -e '.script == "fleet-worktree-reaper"' "$summary_out" >/dev/null 2>&1 \
    || fail "case23: summary JSON missing script field; content: $(cat "$summary_out")"
jq -e '.reaped >= 1' "$summary_out" >/dev/null 2>&1 \
    || fail "case23: summary JSON reaped should be >=1; content: $(cat "$summary_out")"
jq -e '.dry_run == 0' "$summary_out" >/dev/null 2>&1 \
    || fail "case23: summary JSON dry_run should be 0 for live run; content: $(cat "$summary_out")"
jq -e 'has("skipped_dirty") and has("skipped_notpushed")' "$summary_out" >/dev/null 2>&1 \
    || fail "case23: summary JSON missing skip fields; content: $(cat "$summary_out")"
ok "case23: --summary-file writes valid JSON run breakdown"

# --- 24. --no-summary-file disables the write (fleet-ops#2965) -------------
add_modec_worktree "$parent_a" "$wroot" "fix-branch-601" "fix/mode-c-601" 1 0 1
rm -f "$summary_out"
out_ns=$("$bin" --root "$wroot" --no-summary-file 2>&1) || true
[ ! -f "$summary_out" ] \
    || fail "case24: --no-summary-file should not write; file exists: $(cat "$summary_out")"
ok "case24: --no-summary-file disables summary write"

rm -f "$summary_out"

# =====================================================================
# Mode A CLOSED extension (fleet-ops#3023): a claim/issue-<N> worktree
# whose PR is CLOSED (not merged) is an orphan Mode A previously skipped
# forever (claim/issue-* is always tagged Mode A, never Mode C). Mode A
# now reaps CLOSED claims after the age gate, with the same terminal +
# clean gates. These cases prove the matching orphan is collected.
# =====================================================================

# --- 25. CLOSED + terminal + clean + OLD -> REAPED-A (closed) ---------------
add_closed_claim_worktree "$parent_a" "$wroot" 700 0 1
out_cl1=$("$bin" --root "$wroot" 2>&1) || true
[ ! -d "$wroot/issue-fleet-ops-700" ] \
    || fail "case25: CLOSED+terminal+clean+old should be REAPED-A (closed); output: $out_cl1"
echo "$out_cl1" | grep -q "issue-fleet-ops-700: REAPED-A (claim/issue-700, closed)" \
    || fail "case25: expected REAPED-A (closed) tag; output: $out_cl1"
ok "case25: CLOSED + terminal + clean + old REAPED-A (closed)"

# --- 26. CLOSED + terminal + clean + YOUNG -> SKIP-A closed-too-young -------
add_closed_claim_worktree "$parent_a" "$wroot" 701 0 0
out_cl2=$("$bin" --root "$wroot" 2>&1) || true
[ -d "$wroot/issue-fleet-ops-701" ] \
    || fail "case26: young CLOSED worktree must NOT be reaped; output: $out_cl2"
echo "$out_cl2" | grep -q "issue-fleet-ops-701: SKIP-A closed-too-young" \
    || fail "case26: expected SKIP-A closed-too-young; output: $out_cl2"
ok "case26: CLOSED + YOUNG SKIP-A closed-too-young"
# Age it and reap to clean up.
touch -d '2 days ago' "$wroot/issue-fleet-ops-701" 2>/dev/null || true
"$bin" --root "$wroot" >/dev/null 2>&1 || true

# --- 27. CLOSED + terminal + dirty + old -> SKIP dirty (common gate) --------
add_closed_claim_worktree "$parent_a" "$wroot" 702 1 1
out_cl3=$("$bin" --root "$wroot" 2>&1) || true
[ -d "$wroot/issue-fleet-ops-702" ] \
    || fail "case27: dirty CLOSED worktree must NOT be reaped; output: $out_cl3"
echo "$out_cl3" | grep -q "issue-fleet-ops-702: SKIP dirty" \
    || fail "case27: expected SKIP dirty (common gate); output: $out_cl3"
ok "case27: CLOSED + dirty SKIP dirty"
# Clean the dirty file and reap to clean up.
rm -f "$wroot/issue-fleet-ops-702/dirty.txt" 2>/dev/null || true
"$bin" --root "$wroot" >/dev/null 2>&1 || true

# --- 28. CLOSED + LIVE worker -> SKIP live (common gate) --------------------
add_closed_claim_worktree "$parent_a" "$wroot" 703 0 1
printf 'running\n' >"$scratch/live/pi-issue@fleet-ops-703.service"
out_cl4=$("$bin" --root "$wroot" 2>&1) || true
[ -d "$wroot/issue-fleet-ops-703" ] \
    || fail "case28: live-worker CLOSED worktree must NOT be reaped; output: $out_cl4"
echo "$out_cl4" | grep -q "issue-fleet-ops-703: SKIP live worker" \
    || fail "case28: expected SKIP live worker (common gate); output: $out_cl4"
ok "case28: CLOSED + LIVE worker SKIP live"
rm -f "$scratch/live/pi-issue@fleet-ops-703.service" 2>/dev/null || true
"$bin" --root "$wroot" >/dev/null 2>&1 || true

# --- 29. summary JSON carries reaped_a_closed (fleet-ops#3023) --------------
add_closed_claim_worktree "$parent_a" "$wroot" 704 0 1
summary_out_cl="$(mktemp -t wt-reaper-summary-cl.XXXXXX)"
"$bin" --root "$wroot" --summary-file "$summary_out_cl" >/dev/null 2>&1 || true
jq -e '.reaped_a_closed >= 1' "$summary_out_cl" >/dev/null 2>&1 \
    || fail "case29: summary JSON reaped_a_closed should be >=1; content: $(cat "$summary_out_cl")"
ok "case29: summary JSON carries reaped_a_closed"
rm -f "$summary_out_cl"

# =====================================================================
# Mode D (fleet-ops#3023 follow-through): stale dirty orphan salvage.
# A dirty worktree older than --salvage-age-days (default 14d; cases
# touch the dir 20 days back so the 2-day-old cases above stay inert)
# is banked to wip/wfr-<basename>-<ts> on origin via the salvage
# helper, then the normal mode gates reap it.
# =====================================================================

# --- 30. Mode C + dirty + STALE + banked -> SALVAGE-BANKED + REAPED-C ----
# push=0 so the branch's HEAD is NOT on origin — the banked wip ref is
# the work-on-origin proof, not the branch.
add_modec_worktree "$parent_a" "$wroot" "fix-branch-800" "fix/mode-d-800" 0 1 0
touch -d '20 days ago' "$wroot/fix-branch-800"
out_d1=$("$bin" --root "$wroot" 2>&1) || true
[ ! -d "$wroot/fix-branch-800" ] \
    || fail "case30: stale dirty orphan should be salvaged + REAPED-C; output: $out_d1"
echo "$out_d1" | grep -q "fix-branch-800: SALVAGE-BANKED" \
    || fail "case30: expected SALVAGE-BANKED tag; output: $out_d1"
echo "$out_d1" | grep -q "fix-branch-800: REAPED-C" \
    || fail "case30: expected REAPED-C tag; output: $out_d1"
# The banked work must be proven on origin (the matching orphan's dirt
# survives the worktree removal — the issue's 'proves it is collected').
git -C "$parent_a" ls-remote origin "refs/heads/wip/wfr-fix-branch-800-*" \
    | grep -q . \
    || fail "case30: banked wip ref missing on origin; output: $out_d1"
ok "case30: stale dirty orphan SALVAGE-BANKED + REAPED-C, wip ref on origin"

# --- 31. Mode C + dirty + STALE + no-push -> kept (fail safe) ------------
# A salvage whose bank never lands on origin must not be reaped.
add_modec_worktree "$parent_a" "$wroot" "fix-branch-801" "fix/mode-d-801" 0 1 0
touch -d '20 days ago' "$wroot/fix-branch-801"
printf '1\n' >"$FAKE_SALVAGE_DIR/fix-branch-801.no-push"
out_d2=$("$bin" --root "$wroot" 2>&1) || true
[ -d "$wroot/fix-branch-801" ] \
    || fail "case31: unbanked salvage must NOT reap the worktree; output: $out_d2"
echo "$out_d2" | grep -q "fix-branch-801: salvage not on origin" \
    || fail "case31: expected 'salvage not on origin' line; output: $out_d2"
ok "case31: push-failed salvage keeps the worktree (fail safe)"
# Clean up: drop the marker so a later run can bank it.
rm -f "$FAKE_SALVAGE_DIR/fix-branch-801.no-push"
"$bin" --root "$wroot" >/dev/null 2>&1 || true

# --- 32. Mode C + dirty + YOUNG -> SKIP dirty, helper NOT invoked ---------
# old=1 touches the dir 2 days back — under the default 14d salvage
# gate, so the helper must never see it.
add_modec_worktree "$parent_a" "$wroot" "fix-branch-802" "fix/mode-d-802" 0 1 1
rm -f "$FAKE_SALVAGE_DIR/invoked"
out_d3=$("$bin" --root "$wroot" 2>&1) || true
[ -d "$wroot/fix-branch-802" ] \
    || fail "case32: young dirty worktree must NOT be reaped; output: $out_d3"
echo "$out_d3" | grep -q "fix-branch-802: SKIP dirty" \
    || fail "case32: expected SKIP dirty; output: $out_d3"
{ [ ! -f "$FAKE_SALVAGE_DIR/invoked" ] \
    || ! grep -q "fix-branch-802" "$FAKE_SALVAGE_DIR/invoked"; } \
    || fail "case32: salvage helper must not run on a young dirty worktree"
ok "case32: dirty but under salvage age SKIP dirty (helper not invoked)"

# --- 33. claim + merged PR + dirty + STALE -> SALVAGE-BANKED + REAPED-A ---
# The dominant real-world shape: a claim worktree whose PR merged but
# whose tree is dirty. Bank the dirt, then the Mode A gate reaps.
add_claim_worktree "$parent_a" "$wroot" 810 1
touch -d '20 days ago' "$wroot/issue-fleet-ops-810"
out_d4=$("$bin" --root "$wroot" 2>&1) || true
[ ! -d "$wroot/issue-fleet-ops-810" ] \
    || fail "case33: stale dirty merged claim should be salvaged + REAPED-A; output: $out_d4"
echo "$out_d4" | grep -q "issue-fleet-ops-810: REAPED-A" \
    || fail "case33: expected REAPED-A tag; output: $out_d4"
ok "case33: stale dirty merged claim SALVAGE-BANKED + REAPED-A"

# --- 34. --dry-run + dirty + STALE -> candidate, no bank ------------------
add_modec_worktree "$parent_a" "$wroot" "fix-branch-803" "fix/mode-d-803" 0 1 0
touch -d '20 days ago' "$wroot/fix-branch-803"
rm -f "$FAKE_SALVAGE_DIR/invoked"
dry_d=$("$bin" --dry-run --root "$wroot" 2>&1) || true
[ -d "$wroot/fix-branch-803" ] \
    || fail "case34: dry-run must not delete; output: $dry_d"
echo "$dry_d" | grep -q "fix-branch-803: DRY-SALVAGE-CAND" \
    || fail "case34: expected DRY-SALVAGE-CAND; output: $dry_d"
[ ! -f "$FAKE_SALVAGE_DIR/invoked" ] \
    || fail "case34: dry-run must not invoke the salvage helper"
ok "case34: dry-run reports salvage candidate without banking"

# --- 35. --salvage-limit 0 + dirty + STALE -> SKIP-D salvage-limit --------
out_lim=$("$bin" --root "$wroot" --salvage-limit 0 2>&1) || true
[ -d "$wroot/fix-branch-803" ] \
    || fail "case35: --salvage-limit 0 must not bank or reap; output: $out_lim"
echo "$out_lim" | grep -q "fix-branch-803: SKIP-D salvage-limit" \
    || fail "case35: expected SKIP-D salvage-limit; output: $out_lim"
[ ! -f "$FAKE_SALVAGE_DIR/invoked" ] \
    || fail "case35: limit-capped run must not invoke the helper"
ok "case35: --salvage-limit 0 caps salvage attempts"
# Now a real run banks + reaps it.
"$bin" --root "$wroot" >/dev/null 2>&1 || true
[ ! -d "$wroot/fix-branch-803" ] \
    || fail "case35: un-capped run should salvage + reap fix-branch-803"
ok "case35: un-capped run salvages + reaps the candidate"

# --- 36. summary JSON carries the Mode D fields ---------------------------
summary_out_d="$(mktemp -t wt-reaper-summary-d.XXXXXX)"
add_modec_worktree "$parent_a" "$wroot" "fix-branch-804" "fix/mode-d-804" 0 1 0
touch -d '20 days ago' "$wroot/fix-branch-804"
"$bin" --root "$wroot" --summary-file "$summary_out_d" >/dev/null 2>&1 || true
jq -e 'has("salvaged") and has("salvage_attempts") and has("salvage_candidates")' \
    "$summary_out_d" >/dev/null 2>&1 \
    || fail "case36: summary JSON missing Mode D fields; content: $(cat "$summary_out_d")"
jq -e '.salvaged >= 1' "$summary_out_d" >/dev/null 2>&1 \
    || fail "case36: salvaged should be >=1 after a banked run; content: $(cat "$summary_out_d")"
ok "case36: summary JSON carries salvaged/salvage_attempts/salvage_candidates"
rm -f "$summary_out_d"

# --- 37. Mode B + ledger-terminal + dirty + STALE + unpushed -> REAPED-B --
# A dirty pi-issue worktree whose HEAD is not on origin and whose unit
# is ledger-terminal: the pushed wip ref is the head-on-origin proof.
add_path_worktree "$parent_a" "$wroot" 811 "feature/mode-d-811" 0 1
touch -d '20 days ago' "$wroot/issue-fleet-ops-811"
ledger_add "pi-issue-fleet-ops-811|salvaged|2026-09-01T10:00:00Z"
out_db=$("$bin" --root "$wroot" 2>&1) || true
[ ! -d "$wroot/issue-fleet-ops-811" ] \
    || fail "case37: stale dirty ledger-terminal worktree should be salvaged + REAPED-B; output: $out_db"
echo "$out_db" | grep -q "issue-fleet-ops-811: REAPED-B" \
    || fail "case37: expected REAPED-B tag; output: $out_db"
ok "case37: Mode B ledger-terminal stale dirty SALVAGE-BANKED + REAPED-B"

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
