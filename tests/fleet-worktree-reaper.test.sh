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
#    38. ARCHIVED repo + dirty + STALE + push fails -> SALVAGE-BANKED-LOCAL
#        + REAPED-C (read-only origin can never take the bank)
#
#   16. MANIFEST + unit files present    -> install rail intact
#
#   Per-worktree report (fleet-ops#4118) — summary JSON carries a
#   `worktrees` array with per-worktree path/owner/branch/mode/age/verdict:
#    55. --summary-file (default report) -> worktrees[] non-empty, each row
#        has path/owner_repo/branch/mode/age_s/verdict/reason; a reaped
#        row and a skipped row both appear; report_rows matches the array
#        length; report_capped is 0 under the limit.
#    56. --no-report-file -> worktrees[] is empty, report_rows is 0.
#    57. --report-limit 1 -> worktrees[] capped at 1 row, report_capped=1.
#    58. --report-file PATH -> the TSV is written to PATH and parsed into
#        the summary worktrees[] array.
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
if [ "${1:-}" = "repo" ] && [ "${2:-}" = "view" ]; then
    # gh repo view <owner/repo> --json isArchived -q .isArchived
    # A <basename>.archived marker under GH_STATE_DIR makes the repo
    # report archived (Mode D local-bank path, fleet-ops#3023).
    rbase="${3##*/}"
    if [ -f "$GH_STATE_DIR/${rbase}.archived" ]; then
        printf 'true\n'
    else
        printf 'false\n'
    fi
    exit 0
fi
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
printf '%s|%s\n' "$wt" "${PI_SALVAGE_NO_PUSH:-0}" \
    >>"${FAKE_SALVAGE_DIR:?need FAKE_SALVAGE_DIR}/invoked"
git -C "$wt" add -A -- . >/dev/null 2>&1
git -C "$wt" -c user.email=fleet-salvage@localhost -c user.name=fleet-salvage \
    commit -q -m "salvage: bank uncommitted work for unit ${unit}" >/dev/null 2>&1 || true
git -C "$wt" branch -f "$br" HEAD >/dev/null 2>&1 || true
status=local
if [ "${PI_SALVAGE_NO_PUSH:-0}" != "1" ] \
   && [ ! -f "$FAKE_SALVAGE_DIR/${base}.no-push" ]; then
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
# Isolate AGENT_STATE so test runs that rely on the default --summary-file
# path (cases 1-22 etc.) do not overwrite the live
# agent-state/worktree-reaper-last-run.json (fleet-ops#4118). The default
# summary + report files land under the scratch dir instead.
export AGENT_STATE="$scratch/agent-state"
mkdir -p "$AGENT_STATE"
# Mode F isolation (fleet-ops#5837): point the stale standalone-checkout
# pass at a scratch dir so every case below runs (and mutates) a sandbox,
# never the live /home/nish/workspaces root.
wsroot="$scratch/workspaces"
mkdir -p "$wsroot"
export FLEET_WORKTREE_REAPER_STALE_ROOT="$wsroot"
export FLEET_WORKTREE_REAPER_CANONICAL="$wsroot/tooling/fleet-ops-deploy-clone"

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

# --- 38. ARCHIVED repo + dirty + STALE + push fails -> local bank reaps ---
# On an archived repo the push can never land (read-only origin), so the
# local wip ref the helper leaves in the parent clone is the maximal
# possible preservation — and it must be verified before the reap.
printf '1\n' >"$GH_STATE_DIR/proj-x.archived"
add_modec_worktree "$parent_b" "$wroot" "fix-branch-900" "fix/mode-d-900" 0 1 0
touch -d '20 days ago' "$wroot/fix-branch-900"
printf '1\n' >"$FAKE_SALVAGE_DIR/fix-branch-900.no-push"
out_arch=$("$bin" --root "$wroot" 2>&1) || true
[ ! -d "$wroot/fix-branch-900" ] \
    || fail "case38: archived-repo stale dirty orphan should be locally banked + REAPED-C; output: $out_arch"
echo "$out_arch" | grep -q "fix-branch-900: SALVAGE-BANKED-LOCAL" \
    || fail "case38: expected SALVAGE-BANKED-LOCAL tag; output: $out_arch"
echo "$out_arch" | grep -q "fix-branch-900: REAPED-C" \
    || fail "case38: expected REAPED-C tag; output: $out_arch"
# The local bank must exist in the parent clone.
git -C "$parent_b" for-each-ref 'refs/heads/wip/wfr-fix-branch-900-*' \
    | grep -q . \
    || fail "case38: local banked wip ref missing in parent; output: $out_arch"
# The reaper must pass PI_SALVAGE_NO_PUSH=1 to the helper on an archived
# repo — the push is a doomed network round-trip the helper should skip.
grep -q 'fix-branch-900|1' "$FAKE_SALVAGE_DIR/invoked" \
    || fail "case38: helper should be called with PI_SALVAGE_NO_PUSH=1 on an archived repo; invoked: $(cat "$FAKE_SALVAGE_DIR/invoked" 2>/dev/null)"
ok "case38: archived repo local bank SALVAGE-BANKED-LOCAL + REAPED-C"
# And the mirror-image: same shape on a LIVE repo must NOT reap — a
# push that never landed is not a bank.
rm -f "$GH_STATE_DIR/proj-x.archived"
add_modec_worktree "$parent_b" "$wroot" "fix-branch-901" "fix/mode-d-901" 0 1 0
touch -d '20 days ago' "$wroot/fix-branch-901"
printf '1\n' >"$FAKE_SALVAGE_DIR/fix-branch-901.no-push"
out_live=$("$bin" --root "$wroot" 2>&1) || true
[ -d "$wroot/fix-branch-901" ] \
    || fail "case38b: live-repo push-failed salvage must NOT reap; output: $out_live"
echo "$out_live" | grep -q "fix-branch-901: salvage not on origin" \
    || fail "case38b: expected 'salvage not on origin'; output: $out_live"
ok "case38b: live repo + push-failed salvage keeps the worktree"
rm -f "$FAKE_SALVAGE_DIR/fix-branch-901.no-push"

# =====================================================================
# Mode E (fleet-ops#3830): orphan directory GC. Dirs under $ROOT that
# are NOT registered worktrees in any parent — standalone clones (`.git`
# is a directory) and plain scratch dirs (no `.git`). The per-parent
# loop only sees registered worktrees; these orphans accumulate. Mode E
# scans $ROOT after the per-parent loop and reaps the leftovers.
#
# Safety: NOT-REGISTERED (skip evaluated_paths) + STALE (14d mtime) +
# LIVE (pi-issue path unit not active). E1 clones also gate on CLEAN +
# PUSHED; E2 plain dirs have no git gates (the stale gate + location is
# the safety proof).
# =====================================================================

# Helper: create a standalone clone (`.git` is a directory, NOT a
# worktree pointer) under $ROOT. push=1 pushes HEAD to the clone's
# origin; push=0 leaves HEAD local. dirty=1 adds an uncommitted file.
# old=1 sets the dir mtime 20 days back so the 14d stale gate passes.
add_clone_dir() {
    local wroot="$1" name="$2" push="${3:-1}" dirty="${4:-0}" old="${5:-0}"
    local bare="$scratch/${name}.git"
    local clone="$wroot/$name"
    git -c init.defaultBranch=main init -q --bare "$bare"
    git clone -q "$bare" "$clone"
    git_ident "$clone"
    printf 'base\n' >"$clone/README"
    git -C "$clone" add README
    git -C "$clone" commit -q -m base
    git -C "$clone" push -q origin HEAD:main
    git -C "$clone" checkout -q -B main origin/main
    if [ "$dirty" = 1 ]; then
        printf 'uncommitted\n' >"$clone/dirty.txt"
    fi
    if [ "$push" = 1 ]; then
        # HEAD is already on origin/main after the push above.
        :
    else
        # Make a unique commit so HEAD is NOT on origin.
        printf 'local-only-%s\n' "$name" >>"$clone/local.txt"
        git_ident "$clone"
        git -C "$clone" add local.txt
        git -C "$clone" commit -q -m "local-only $name"
    fi
    if [ "$old" = 1 ]; then
        touch -d '20 days ago' "$clone" 2>/dev/null || true
    fi
    printf '%s' "$clone"
}

# Helper: create a plain scratch dir (no `.git`) under $ROOT. old=1 sets
# the dir mtime 20 days back so the 14d stale gate passes.
add_plain_dir() {
    local wroot="$1" name="$2" old="${3:-1}"
    local d="$wroot/$name"
    mkdir -p "$d"
    printf 'scratch\n' >"$d/note.txt"
    if [ "$old" = 1 ]; then
        touch -d '20 days ago' "$d" 2>/dev/null || true
    fi
    printf '%s' "$d"
}

# --- 39. E1 clone + pushed + clean + stale -> REAPED-E1 --------------------
add_clone_dir "$wroot" "clone-e1-1000" 1 0 1
out_e1=$("$bin" --root "$wroot" 2>&1) || true
[ ! -d "$wroot/clone-e1-1000" ] \
    || fail "case39: stale clean pushed clone should be REAPED-E1; output: $out_e1"
echo "$out_e1" | grep -q "clone-e1-1000: REAPED-E1" \
    || fail "case39: expected REAPED-E1 tag; output: $out_e1"
ok "case39: E1 clone + pushed + clean + stale REAPED-E1"

# --- 40. E1 clone + YOUNG -> SKIP-E too-young ------------------------------
add_clone_dir "$wroot" "clone-e1-1001" 1 0 0
out_e2=$("$bin" --root "$wroot" 2>&1) || true
[ -d "$wroot/clone-e1-1001" ] \
    || fail "case40: young clone must NOT be reaped; output: $out_e2"
echo "$out_e2" | grep -q "clone-e1-1001: SKIP-E too-young" \
    || fail "case40: expected SKIP-E too-young; output: $out_e2"
ok "case40: E1 clone + YOUNG SKIP-E too-young"
# Age it and reap to clean up.
touch -d '20 days ago' "$wroot/clone-e1-1001" 2>/dev/null || true
"$bin" --root "$wroot" >/dev/null 2>&1 || true

# --- 41. E1 clone + NOT pushed + clean + stale -> SKIP-E head-not-on-origin
add_clone_dir "$wroot" "clone-e1-1002" 0 0 1
out_e3=$("$bin" --root "$wroot" 2>&1) || true
[ -d "$wroot/clone-e1-1002" ] \
    || fail "case41: not-pushed clone must NOT be reaped; output: $out_e3"
echo "$out_e3" | grep -q "clone-e1-1002: SKIP-E head-not-on-origin" \
    || fail "case41: expected SKIP-E head-not-on-origin; output: $out_e3"
ok "case41: E1 clone + NOT pushed SKIP-E head-not-on-origin"

# --- 42. E1 clone + pushed + dirty + stale -> SKIP-E dirty -----------------
add_clone_dir "$wroot" "clone-e1-1003" 1 1 1
out_e4=$("$bin" --root "$wroot" 2>&1) || true
[ -d "$wroot/clone-e1-1003" ] \
    || fail "case42: dirty clone must NOT be reaped; output: $out_e4"
echo "$out_e4" | grep -q "clone-e1-1003: SKIP-E dirty clone" \
    || fail "case42: expected SKIP-E dirty clone; output: $out_e4"
ok "case42: E1 clone + dirty SKIP-E dirty clone"

# --- 43. E2 plain dir + stale -> REAPED-E2 --------------------------------
add_plain_dir "$wroot" "plain-e2-1100" 1
out_e5=$("$bin" --root "$wroot" 2>&1) || true
[ ! -d "$wroot/plain-e2-1100" ] \
    || fail "case43: stale plain dir should be REAPED-E2; output: $out_e5"
echo "$out_e5" | grep -q "plain-e2-1100: REAPED-E2" \
    || fail "case43: expected REAPED-E2 tag; output: $out_e5"
ok "case43: E2 plain dir + stale REAPED-E2"

# --- 44. E2 plain dir + YOUNG -> SKIP-E too-young -------------------------
add_plain_dir "$wroot" "plain-e2-1101" 0
out_e6=$("$bin" --root "$wroot" 2>&1) || true
[ -d "$wroot/plain-e2-1101" ] \
    || fail "case44: young plain dir must NOT be reaped; output: $out_e6"
echo "$out_e6" | grep -q "plain-e2-1101: SKIP-E too-young" \
    || fail "case44: expected SKIP-E too-young; output: $out_e6"
ok "case44: E2 plain dir + YOUNG SKIP-E too-young"
# Age it and reap to clean up.
touch -d '20 days ago' "$wroot/plain-e2-1101" 2>/dev/null || true
"$bin" --root "$wroot" >/dev/null 2>&1 || true

# --- 45. E2 plain dir + pi-issue path + LIVE worker -> SKIP-E live --------
add_plain_dir "$wroot" "issue-fleet-ops-1200" 1
printf 'running\n' >"$scratch/live/pi-issue@fleet-ops-1200.service"
out_e7=$("$bin" --root "$wroot" 2>&1) || true
[ -d "$wroot/issue-fleet-ops-1200" ] \
    || fail "case45: live-worker plain dir must NOT be reaped; output: $out_e7"
echo "$out_e7" | grep -q "issue-fleet-ops-1200: SKIP-E live worker" \
    || fail "case45: expected SKIP-E live worker; output: $out_e7"
ok "case45: E2 plain dir + pi-issue path + LIVE worker SKIP-E live"
rm -f "$scratch/live/pi-issue@fleet-ops-1200.service" 2>/dev/null || true
"$bin" --root "$wroot" >/dev/null 2>&1 || true

# --- 46. Mode E never touches a registered worktree -----------------------
# A registered worktree (created via `git worktree add`) must NOT be
# seen by Mode E even if it is stale + clean + on origin — the per-
# parent loop already evaluated it and recorded it in evaluated_paths.
add_modec_worktree "$parent_a" "$wroot" "reg-wt-1300" "fix/reg-1300" 1 0 1
# Re-run; the registered worktree is handled by Mode C (reaped), but
# Mode E must NOT double-count or error on it.
out_e8=$("$bin" --root "$wroot" 2>&1) || true
# The registered worktree should be reaped by Mode C, not Mode E.
echo "$out_e8" | grep -q "reg-wt-1300: REAPED-C" \
    || fail "case46: registered worktree should be REAPED-C (not Mode E); output: $out_e8"
echo "$out_e8" | grep -q "reg-wt-1300: REAPED-E" \
    && fail "case46: registered worktree must NOT be touched by Mode E; output: $out_e8" || true
ok "case46: Mode E never touches a registered worktree (Mode C handles it)"

# --- 47. --dry-run reports E1 + E2 without deleting -----------------------
add_clone_dir "$wroot" "clone-e1-1400" 1 0 1
add_plain_dir "$wroot" "plain-e2-1401" 1
dry_e=$("$bin" --dry-run --root "$wroot" 2>&1) || true
[ -d "$wroot/clone-e1-1400" ] \
    || fail "case47: dry-run must not delete clone; output: $dry_e"
[ -d "$wroot/plain-e2-1401" ] \
    || fail "case47: dry-run must not delete plain dir; output: $dry_e"
echo "$dry_e" | grep -q "clone-e1-1400: DRY-REAP-E1" \
    || fail "case47: expected DRY-REAP-E1; output: $dry_e"
echo "$dry_e" | grep -q "plain-e2-1401: DRY-REAP-E2" \
    || fail "case47: expected DRY-REAP-E2; output: $dry_e"
ok "case47: --dry-run reports E1 + E2 without deleting"

# --- 48. summary JSON carries Mode E fields -------------------------------
summary_out_e="$(mktemp -t wt-reaper-summary-e.XXXXXX)"
add_clone_dir "$wroot" "clone-e1-1500" 1 0 1
add_plain_dir "$wroot" "plain-e2-1501" 1
"$bin" --root "$wroot" --summary-file "$summary_out_e" >/dev/null 2>&1 || true
jq -e 'has("reaped_e") and has("reaped_e_clone") and has("reaped_e_plain")' \
    "$summary_out_e" >/dev/null 2>&1 \
    || fail "case48: summary JSON missing Mode E reaped fields; content: $(cat "$summary_out_e")"
jq -e 'has("mode_e_scanned") and has("skipped_e_young")' \
    "$summary_out_e" >/dev/null 2>&1 \
    || fail "case48: summary JSON missing Mode E skip fields; content: $(cat "$summary_out_e")"
jq -e '.reaped_e >= 2' "$summary_out_e" >/dev/null 2>&1 \
    || fail "case48: reaped_e should be >=2 (clone + plain); content: $(cat "$summary_out_e")"
ok "case48: summary JSON carries Mode E fields"
rm -f "$summary_out_e"

# =====================================================================
# Bound (fleet-ops#3995): --max-worktrees caps the dir count under $ROOT.
# Pre-pass: when the count is over the bound, the run raises the salvage
# cap to the full backlog so one tick drains the dirty pile. Post-pass:
# when the count is STILL over the bound after the reap, the run emits
# BOUND-BREACH and exits 3 so the escalation drop-in pages. Dry-run never
# breaches (it deletes nothing). 0 disables the bound.
#
# Uses a FRESH isolated root so the dir count is deterministic (the main
# $wroot accumulates survivors from earlier cases).
# =====================================================================
bound_root="$scratch/bound-worktrees"
mkdir -p "$bound_root"

# Helper: create N young plain dirs under $ROOT that Mode E will SKIP as
# too-young (so they survive the reap and hold the count over the bound).
# Young = mtime now, well under the 14d stale gate.
make_young_dirs() {
    local root="$1" prefix="$2" n="$3"
    local i
    for i in $(seq 1 "$n"); do
        mkdir -p "$root/${prefix}-${i}"
        printf 'young\n' >"$root/${prefix}-${i}/note.txt"
    done
}

# --- 49. bound breach: count over max after reap -> exit 3 + BOUND-BREACH --
# 5 young dirs that survive + max=3 => post-count=5 > 3 => breach.
make_young_dirs "$bound_root" "bound-breach" 5
set +e
out_bound=$("$bin" --root "$bound_root" --max-worktrees 3 2>&1)
rc_bound=$?
set -e
[ "$rc_bound" -eq 3 ] \
    || fail "case49: over-bound run must exit 3, got rc=$rc_bound; output: $out_bound"
echo "$out_bound" | grep -q "BOUND-BREACH" \
    || fail "case49: expected BOUND-BREACH line; output: $out_bound"
# The young dirs must still exist (the bound does not force-delete; it
# only escalates). The reaper's safety gates still hold.
live_count=$(find "$bound_root" -mindepth 1 -maxdepth 1 -type d -name 'bound-breach-*' | wc -l)
[ "$live_count" -eq 5 ] \
    || fail "case49: bound must not force-delete young dirs; live=$live_count; output: $out_bound"
ok "case49: bound breach exits 3 + BOUND-BREACH, safety gates hold"
rm -rf "$bound_root"/*; rm -rf "$bound_root"/.* 2>/dev/null || true

# --- 50. bound ok: count under max after reap -> exit 0 --------------------
# 2 young dirs + max=3 => post-count=2 <= 3 => no breach, exit 0.
make_young_dirs "$bound_root" "bound-ok" 2
set +e
out_ok=$("$bin" --root "$bound_root" --max-worktrees 3 2>&1)
rc_ok=$?
set -e
[ "$rc_ok" -eq 0 ] \
    || fail "case50: under-bound run must exit 0, got rc=$rc_ok; output: $out_ok"
echo "$out_ok" | grep -q "bound-ok:" \
    || fail "case50: expected bound-ok line; output: $out_ok"
echo "$out_ok" | grep -q "BOUND-BREACH" \
    && fail "case50: under-bound run must NOT breach; output: $out_ok" || true
ok "case50: under-bound run exits 0, no breach"
rm -rf "$bound_root"/*; rm -rf "$bound_root"/.* 2>/dev/null || true

# --- 51. dry-run never breaches even when over bound -----------------------
# 5 young dirs + max=3 + --dry-run => no deletion, no breach, exit 0.
make_young_dirs "$bound_root" "bound-dry" 5
set +e
out_dry=$("$bin" --dry-run --root "$bound_root" --max-worktrees 3 2>&1)
rc_dry=$?
set -e
[ "$rc_dry" -eq 0 ] \
    || fail "case51: dry-run must exit 0 even when over bound, got rc=$rc_dry; output: $out_dry"
echo "$out_dry" | grep -q "BOUND-BREACH" \
    && fail "case51: dry-run must NOT breach; output: $out_dry" || true
# All 5 dirs still present (dry-run deletes nothing).
live_count=$(find "$bound_root" -mindepth 1 -maxdepth 1 -type d -name 'bound-dry-*' | wc -l)
[ "$live_count" -eq 5 ] \
    || fail "case51: dry-run must not delete; live=$live_count; output: $out_dry"
ok "case51: dry-run never breaches even when over bound"
rm -rf "$bound_root"/*; rm -rf "$bound_root"/.* 2>/dev/null || true

# --- 52. --max-worktrees 0 disables the bound ------------------------------
# 5 young dirs + max=0 => no bound check, exit 0 even though count > 0.
make_young_dirs "$bound_root" "bound-off" 5
set +e
out_off=$("$bin" --root "$bound_root" --max-worktrees 0 2>&1)
rc_off=$?
set -e
[ "$rc_off" -eq 0 ] \
    || fail "case52: max=0 must disable bound and exit 0, got rc=$rc_off; output: $out_off"
echo "$out_off" | grep -q "BOUND-BREACH" \
    && fail "case52: max=0 must not breach; output: $out_off" || true
ok "case52: --max-worktrees 0 disables the bound"
rm -rf "$bound_root"/*; rm -rf "$bound_root"/.* 2>/dev/null || true

# --- 53. summary JSON carries the bound fields -----------------------------
summary_out_b="$(mktemp -t wt-reaper-summary-b.XXXXXX)"
make_young_dirs "$bound_root" "bound-json" 4
set +e
"$bin" --root "$bound_root" --max-worktrees 3 --summary-file "$summary_out_b" >/dev/null 2>&1
set -e
jq -e 'has("max_worktrees") and has("pre_count") and has("post_count") and has("bound_breached")' \
    "$summary_out_b" >/dev/null 2>&1 \
    || fail "case53: summary JSON missing bound fields; content: $(cat "$summary_out_b")"
jq -e '.max_worktrees == 3' "$summary_out_b" >/dev/null 2>&1 \
    || fail "case53: max_worktrees must be 3; content: $(cat "$summary_out_b")"
jq -e '.pre_count >= 4' "$summary_out_b" >/dev/null 2>&1 \
    || fail "case53: pre_count must be >=4; content: $(cat "$summary_out_b")"
jq -e '.bound_breached == 1' "$summary_out_b" >/dev/null 2>&1 \
    || fail "case53: bound_breached must be 1 (4 young dirs > max 3); content: $(cat "$summary_out_b")"
ok "case53: summary JSON carries bound fields + breach flag"
rm -f "$summary_out_b"
rm -rf "$bound_root"/*; rm -rf "$bound_root"/.* 2>/dev/null || true

# --- 54. pre-pass raises salvage cap when over bound (aggressive drain) ---
# A stale dirty worktree that WOULD be salvaged but for the salvage cap.
# With --salvage-limit 1 and the count over the bound, the pre-pass
# raises the cap so the full backlog is banked in one tick. We verify the
# raise happened by checking the run banked MORE than the configured cap.
add_modec_worktree "$parent_a" "$bound_root" "fix-branch-1600" "fix/mode-d-1600" 0 1 0
add_modec_worktree "$parent_a" "$bound_root" "fix-branch-1601" "fix/mode-d-1601" 0 1 0
touch -d '20 days ago' "$bound_root/fix-branch-1600"
touch -d '20 days ago' "$bound_root/fix-branch-1601"
# Plus 4 young dirs to push the count over max=3.
make_young_dirs "$bound_root" "bound-raise" 4
summary_raise="$(mktemp -t wt-reaper-raise.XXXXXX)"
set +e
out_raise=$("$bin" --root "$bound_root" --max-worktrees 3 --salvage-limit 1 \
    --summary-file "$summary_raise" 2>&1)
set -e
# Both stale dirty worktrees should be salvaged + reaped (cap raised).
[ ! -d "$bound_root/fix-branch-1600" ] \
    || fail "case54: fix-branch-1600 should be reaped (cap raised); output: $out_raise"
[ ! -d "$bound_root/fix-branch-1601" ] \
    || fail "case54: fix-branch-1601 should be reaped (cap raised); output: $out_raise"
# The summary should show salvage_attempts >= 2 (both banked), proving the
# configured cap of 1 was raised.
jq -e '.salvage_attempts >= 2' "$summary_raise" >/dev/null 2>&1 \
    || fail "case54: salvage_attempts must be >=2 (cap raised); content: $(cat "$summary_raise")"
ok "case54: pre-pass raises salvage cap when over bound (aggressive drain)"
rm -f "$summary_raise"
rm -rf "$bound_root"/*; rm -rf "$bound_root"/.* 2>/dev/null || true

# =====================================================================
# Per-worktree report (fleet-ops#4118): the summary JSON carries a
# `worktrees` array with one row per scanned dir (path, owner_repo,
# branch, mode, age_s, verdict, reason) so the duty officer and the
# heartbeat can see per-worktree age/owner without grepping journalctl.
# The count fields still carry the full totals; the array is capped at
# --report-limit (default 200) with report_capped marking a sample.
# =====================================================================

# --- 55. default report -> worktrees[] non-empty with both verdicts --------
# One reaped (Mode C, pushed, clean, old) + one skipped (Mode C, young).
# The summary must carry a worktrees[] array whose rows have all seven
# columns, include at least one reaped and one skipped, and whose
# report_rows matches the array length.
summary_55="$(mktemp -t wt-reaper-55.XXXXXX)"
add_modec_worktree "$parent_a" "$wroot" "fix-branch-5500" "fix/mode-c-5500" 1 0 1
add_modec_worktree "$parent_a" "$wroot" "fix-branch-5501" "fix/mode-c-5501" 1 0 0
out_55=$("$bin" --root "$wroot" --summary-file "$summary_55" 2>&1) || true
jq -e 'has("worktrees") and (.worktrees | type == "array")' "$summary_55" >/dev/null 2>&1 \
    || fail "case55: summary missing worktrees array; content: $(cat "$summary_55")"
n55=$(jq '.worktrees | length' "$summary_55")
[ "$n55" -ge 2 ] || fail "case55: worktrees[] should have >=2 rows, got $n55; content: $(cat "$summary_55")"
# Every row has the seven columns.
jq -e '.worktrees[] | has("path") and has("owner_repo") and has("branch") and has("mode") and has("age_s") and has("verdict") and has("reason")' \
    "$summary_55" >/dev/null 2>&1 \
    || fail "case55: a worktrees row is missing a column; content: $(cat "$summary_55")"
# At least one reaped and one skipped row.
jq -e '[.worktrees[].verdict] | any(. == "reaped")' "$summary_55" >/dev/null 2>&1 \
    || fail "case55: no reaped row in worktrees[]; content: $(cat "$summary_55")"
jq -e '[.worktrees[].verdict] | any(. == "skipped")' "$summary_55" >/dev/null 2>&1 \
    || fail "case55: no skipped row in worktrees[]; content: $(cat "$summary_55")"
# report_rows matches the array length; report_capped is 0 under the default limit.
jq -e ".report_rows == $n55" "$summary_55" >/dev/null 2>&1 \
    || fail "case55: report_rows must equal worktrees[] length ($n55); content: $(cat "$summary_55")"
jq -e '.report_capped == 0' "$summary_55" >/dev/null 2>&1 \
    || fail "case55: report_capped must be 0 under the limit; content: $(cat "$summary_55")"
# The reaped row's owner_repo is the parent's resolved owner/repo (a
# file:// URL -> the last path segment is the repo name; the reaper
# strips the scheme so owner_repo ends with /fleet-ops).
jq -e '[.worktrees[] | select(.verdict == "reaped")] | all(.owner_repo | endswith("/fleet-ops"))' \
    "$summary_55" >/dev/null 2>&1 \
    || fail "case55: reaped row owner_repo must end with /fleet-ops; content: $(cat "$summary_55")"
ok "case55: default report -> worktrees[] non-empty with both verdicts + owner_repo"
rm -f "$summary_55"

# --- 56. --no-report-file -> worktrees[] empty, report_rows 0 --------------
summary_56="$(mktemp -t wt-reaper-56.XXXXXX)"
add_modec_worktree "$parent_a" "$wroot" "fix-branch-5600" "fix/mode-c-5600" 1 0 1
out_56=$("$bin" --root "$wroot" --summary-file "$summary_56" --no-report-file 2>&1) || true
jq -e 'has("worktrees") and (.worktrees | length == 0)' "$summary_56" >/dev/null 2>&1 \
    || fail "case56: --no-report-file must yield worktrees[] empty; content: $(cat "$summary_56")"
jq -e '.report_rows == 0' "$summary_56" >/dev/null 2>&1 \
    || fail "case56: report_rows must be 0; content: $(cat "$summary_56")"
ok "case56: --no-report-file -> worktrees[] empty, report_rows 0"
rm -f "$summary_56"

# --- 57. --report-limit 1 -> worktrees[] capped at 1, report_capped=1 -----
summary_57="$(mktemp -t wt-reaper-57.XXXXXX)"
add_modec_worktree "$parent_a" "$wroot" "fix-branch-5700" "fix/mode-c-5700" 1 0 1
add_modec_worktree "$parent_a" "$wroot" "fix-branch-5701" "fix/mode-c-5701" 1 0 1
out_57=$("$bin" --root "$wroot" --summary-file "$summary_57" --report-limit 1 2>&1) || true
jq -e '.worktrees | length == 1' "$summary_57" >/dev/null 2>&1 \
    || fail "case57: worktrees[] must be capped at 1; content: $(cat "$summary_57")"
jq -e '.report_capped == 1' "$summary_57" >/dev/null 2>&1 \
    || fail "case57: report_capped must be 1; content: $(cat "$summary_57")"
jq -e '.report_limit == 1' "$summary_57" >/dev/null 2>&1 \
    || fail "case57: report_limit must be 1; content: $(cat "$summary_57")"
ok "case57: --report-limit 1 -> worktrees[] capped at 1, report_capped=1"
rm -f "$summary_57"

# --- 58. --report-file PATH -> TSV written + parsed into worktrees[] ------
summary_58="$(mktemp -t wt-reaper-58.XXXXXX)"
report_58="$(mktemp -t wt-reaper-58-report.XXXXXX)"
add_modec_worktree "$parent_a" "$wroot" "fix-branch-5800" "fix/mode-c-5800" 1 0 1
out_58=$("$bin" --root "$wroot" --summary-file "$summary_58" --report-file "$report_58" 2>&1) || true
[ -s "$report_58" ] || fail "case58: report TSV not written; output: $out_58"
# TSV has 7 tab-separated columns per non-empty line.
awk -F'\t' 'NF==7 {ok=1} NF>0 && NF!=7 {exit 1} END{if(!ok) exit 2}' "$report_58" \
    || fail "case58: report TSV rows must have 7 columns; content: $(cat "$report_58")"
# The summary worktrees[] length matches the TSV non-empty line count.
tsv_n=$(grep -c . "$report_58" || true)
json_n=$(jq '.worktrees | length' "$summary_58")
[ "$tsv_n" = "$json_n" ] \
    || fail "case58: TSV rows ($tsv_n) must match worktrees[] length ($json_n); content: $(cat "$summary_58")"
ok "case58: --report-file PATH -> TSV written + parsed into worktrees[]"
rm -f "$summary_58" "$report_58"

# ==========================================================================
# MODE F (fleet-ops#5837): stale canonical-looking standalone checkouts
# under the flat workspaces root. Rename-to-mark: STALE-do-not-read-
# prefix in the name, never delete.
# ==========================================================================
#
# helper: make a standalone git dir under the Mode F sandbox root.
make_stale_dir() { # <name> <branch> <age: 1=old 0=young>
    local name="$1" branch="$2" old="$3"
    mkdir -p "$wsroot/$name"
    if [ "${branch:-none}" != "none" ]; then
        git -C "$wsroot" init -q -b "$branch" "$name"
        git -C "$wsroot/$name" -c user.email=t@t -c user.name=t \
            commit -q --allow-empty -m seed
    fi
    [ "$old" = "1" ] && touch -d '30 days ago' "$wsroot/$name" || true
}

# --- 59. stale fleet-ops-* dir on a named branch -> RENAMED-F -------------
make_stale_dir fleet-ops-sync chore/repo-standards-sync 1
out_f1=$("$bin" --root "$wroot" 2>&1) || true
[ ! -d "$wsroot/fleet-ops-sync" ] \
    || fail "case59: stale fleet-ops-* dir should be renamed; output: $out_f1"
[ -d "$wsroot/STALE-do-not-read-fleet-ops-sync" ] \
    || fail "case59: STALE-do-not-read-fleet-ops-sync target must exist"
git -C "$wsroot/STALE-do-not-read-fleet-ops-sync" rev-parse --abbrev-ref HEAD 2>/dev/null | grep -qx 'chore/repo-standards-sync' \
    || fail "case59: renamed dir must keep its branch (rename preserves git state)"
echo "$out_f1" | grep -q "fleet-ops-sync: RENAMED-F" \
    || fail "case59: expected RENAMED-F tag; output: $out_f1"
ok "case59: stale non-main fleet-ops-* dir renamed to STALE-do-not-read- prefix"
rmdir "$wsroot/STALE-do-not-read-fleet-ops-sync" 2>/dev/null || true

# --- 60. YOUNG dir -> SKIP-F too-young (today's checkout protected) ------
make_stale_dir fleet-ops-fresh-958 fix/live-branch 0
out_f2=$("$bin" --root "$wroot" 2>&1) || true
[ -d "$wsroot/fleet-ops-fresh-958" ] \
    || fail "case60: young dir must NOT be renamed; output: $out_f2"
echo "$out_f2" | grep -q "fleet-ops-fresh-958: SKIP-F too-young" \
    || fail "case60: expected SKIP-F too-young; output: $out_f2"
ok "case60: young fleet-ops-* dir SKIP-F too-young"
rm -rf "$wsroot/fleet-ops-fresh-958"

# --- 61. branch main -> SKIP-F unclassifiable-or-main --------------------
make_stale_dir fleet-ops-canonical main 1
out_f3=$("$bin" --root "$wroot" 2>&1) || true
[ -d "$wsroot/fleet-ops-canonical" ] \
    || fail "case61: dir on main must NOT be renamed; output: $out_f3"
echo "$out_f3" | grep -q "fleet-ops-canonical: SKIP-F" \
    || fail "case61: expected SKIP-F for main-HEAD dir; output: $out_f3"
ok "case61: dir on main skipped (SKIP-F)"
rm -rf "$wsroot/fleet-ops-canonical"

# --- 62. already STALE-prefixed -> not scanned (idempotent) --------------
mkdir -p "$wsroot/STALE-do-not-read-fleet-ops-already"
out_f4=$("$bin" --root "$wroot" 2>&1) || true
echo "$out_f4" | grep -q "STALE-do-not-read-fleet-ops-already" \
    && fail "case62: prefixed dir must not be re-scanned; output: $out_f4" \
    || true
[ -d "$wsroot/STALE-do-not-read-fleet-ops-already" ] \
    || fail "case62: prefixed dir must be left untouched"
ok "case62: already-prefixed dir idempotently skipped"
rm -rf "$wsroot/STALE-do-not-read-fleet-ops-already"

# --- 63. name not matching the glob -> untouched; target-exists collision -> failed
make_stale_dir not-a-fleet-ops-dir chore/other 1
make_stale_dir fleet-ops-collision chore/other 1
mkdir -p "$wsroot/STALE-do-not-read-fleet-ops-collision"
out_f5=$("$bin" --root "$wroot" 2>&1) || true
[ -d "$wsroot/not-a-fleet-ops-dir" ] \
    || fail "case63: non-glob dir must NOT be renamed; output: $out_f5"
[ -d "$wsroot/fleet-ops-collision" ] \
    || fail "case63: collision dir must be left in place (fail safe); output: $out_f5"
echo "$out_f5" | grep -q "fleet-ops-collision: RENAME-F FAILED" \
    || fail "case63: expected RENAME-F FAILED tag; output: $out_f5"
ok "case63: non-matching name untouched; rename collision fails safe"
rm -rf "$wsroot/not-a-fleet-ops-dir" "$wsroot/fleet-ops-collision" "$wsroot/STALE-do-not-read-fleet-ops-collision"

# --- 64. dry-run renames nothing but reports DRY-RENAME-F ----------------
make_stale_dir fleet-ops-dryrun chore/dry 1
dry_f=$("$bin" --dry-run --root "$wroot" 2>&1) || true
[ -d "$wsroot/fleet-ops-dryrun" ] \
    || fail "case64: dry-run renames nothing; output: $dry_f"
echo "$dry_f" | grep -q "fleet-ops-dryrun: DRY-RENAME-F" \
    || fail "case64: expected DRY-RENAME-F tag; output: $dry_f"
"$bin" --root "$wroot" >/dev/null 2>&1 || true
[ -d "$wsroot/STALE-do-not-read-fleet-ops-dryrun" ] \
    || fail "case64: post-dry-run live run should rename"
rm -rf "$wsroot/STALE-do-not-read-fleet-ops-dryrun"
ok "case64: dry-run reports DRY-RENAME-F, renames nothing"

# --- 65. summary JSON carries the Mode F fields --------------------------
summary_f="$scratch/summary-f.json"
make_stale_dir fleet-ops-json-flip chore/json 1
"$bin" --root "$wroot" --summary-file "$summary_f" >/dev/null 2>&1 || true
jq -e '.mode_f_scanned >= 1 and .reaped_f >= 1' "$summary_f" >/dev/null 2>&1 \
    || fail "case65: summary JSON must carry Mode F counters; content: $(cat "$summary_f")"
dbg_f=$("$bin" --root "$wroot" 2>&1); echo "$dbg_f" | grep -q 'reaped_f=' || fail "case65: summary line must report reaped_f; got: $dbg_f"
ok "case65: summary JSON + line carry Mode F fields"
rm -rf "$wsroot/STALE-do-not-read-fleet-ops-json-flip"

# --- 16. install rail intact ----------------------------------------------
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
