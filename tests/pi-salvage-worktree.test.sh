#!/usr/bin/env bash
# tests/pi-salvage-worktree.test.sh
#
# fleet-ops#1204: a dying worker's dirty tree is banked on wip/<unit>-<ts>.
# Hermetic: fake remotes, no network. Live SIGTERM drill is last and skipped
# when user systemd is absent (CI runner).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
salvage="$repo_root/bin/pi-salvage-worktree"
wrapper="$repo_root/bin/pi-systemd-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$salvage" ]] || fail "not executable: $salvage"
[[ -x "$wrapper" ]] || fail "not executable: $wrapper"

scratch="$(mktemp -d -t pi-salvage.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export PI_SALVAGE_SKIP_SGSCAN=1
export AGENT_STATE="$scratch/agent-state"
export FLEET_DISPATCH_LEDGER="$AGENT_STATE/dispatch-ledger.jsonl"
mkdir -p "$AGENT_STATE"
# fleet-ops#5800: the hook now also reads PI_UNIT_INSTANCE /
# PI_DEADMAN_DELIVERABLE / PI_SALVAGE_WORKTREE_ROOT —
# a worker running this test carries its own values; scrub them so every
# section controls its own env.
unset PI_UNIT_INSTANCE PI_DEADMAN_DELIVERABLE \
      PI_SALVAGE_WORKTREE_ROOT SYSTEMCTL \
      PI_SALVAGE_PACKET PI_SALVAGE_NOW PI_SALVAGE_WORKDIR PI_SALVAGE_UNIT \
      PI_SALVAGE_REMOTE PI_SALVAGE_SCAN PI_SALVAGE_NO_PUSH PI_SALVAGE_DISABLE \
      SERVICE_RESULT EXIT_CODE EXIT_STATUS

git_ident() {
    git -C "$1" config user.email salvage-test@localhost
    git -C "$1" config user.name salvage-test
}

make_clone() {
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

# --- 1. clean worktree is a no-op ------------------------------------------
clone="$(make_clone clean)"
export PI_SALVAGE_WORKDIR="$clone"
export PI_SALVAGE_UNIT="unit-clean"
export SERVICE_RESULT=exit-code EXIT_STATUS=7
"$salvage"
git -C "$clone" rev-parse --abbrev-ref HEAD | grep -qx main \
    || fail "clean salvage must stay on main"
[[ ! -f "$FLEET_DISPATCH_LEDGER" ]] || ! grep -q salvaged_branch "$FLEET_DISPATCH_LEDGER" \
    || fail "clean salvage must not write a salvage branch"
ok "clean worktree is a no-op"

# --- 2. dirty tree salvages even on SERVICE_RESULT=success (#1134 class) ---
clone="$(make_clone success-dirty)"
printf 'engine done\n' >"$clone/engine.txt"
export PI_SALVAGE_WORKDIR="$clone"
export PI_SALVAGE_UNIT="unit-success"
export PI_SALVAGE_NOW="20260827T160000Z"
export SERVICE_RESULT=success EXIT_CODE=exited EXIT_STATUS=0
"$salvage"
git -C "$scratch/success-dirty.git" show-ref --verify -q refs/heads/wip/unit-success-20260827T160000Z \
    || fail "success+dirty must push wip/unit-success-20260827T160000Z"
grep -q '"salvaged_branch":"wip/unit-success-20260827T160000Z"' "$FLEET_DISPATCH_LEDGER" \
    || fail "ledger must name salvaged_branch"
grep -q '"salvage_status":"pushed"' "$FLEET_DISPATCH_LEDGER" \
    || fail "clean salvage must be salvage_status=pushed"
ok "dirty tree on success is banked (1134 class)"

# --- 3. packet resume stamp ------------------------------------------------
clone="$(make_clone pkt)"
pkt="$scratch/packet.md"
printf 'implement the thing\n' >"$pkt"
printf 'work\n' >"$clone/work.txt"
export PI_SALVAGE_WORKDIR="$clone"
export PI_SALVAGE_UNIT="unit-pkt"
export PI_SALVAGE_PACKET="$pkt"
export PI_SALVAGE_NOW="20260827T160100Z"
export SERVICE_RESULT=signal EXIT_CODE=killed EXIT_STATUS=KILL
"$salvage"
grep -q 'fleet-ops#1204 salvage resume' "$pkt" || fail "packet must carry resume stamp"
grep -q 'wip/unit-pkt-20260827T160100Z' "$pkt" || fail "packet must name the wip branch"
ok "packet file is stamped with the resume branch"

# --- 4. secret in diff → local only, salvage_quarantined -------------------
clone="$(make_clone secret)"
# planted fake GitHub PAT (guard_secrets HARD_PATTERNS). Not a real token.
printf 'token=ghp_%s\n' "$(printf 'A%.0s' {1..36})" >"$clone/leaked.env"
export PI_SALVAGE_WORKDIR="$clone"
export PI_SALVAGE_UNIT="unit-secret"
export PI_SALVAGE_PACKET=""
export PI_SALVAGE_NOW="20260827T160200Z"
export SERVICE_RESULT=signal EXIT_CODE=killed EXIT_STATUS=TERM
unset PI_SALVAGE_PACKET
"$salvage"
if git -C "$scratch/secret.git" show-ref --verify -q refs/heads/wip/unit-secret-20260827T160200Z; then
    fail "secret salvage must NOT push"
fi
git -C "$clone" rev-parse --abbrev-ref HEAD | grep -qx 'wip/unit-secret-20260827T160200Z' \
    || fail "secret salvage must still create a local wip branch"
grep -q '"salvage_status":"quarantined"' "$FLEET_DISPATCH_LEDGER" \
    || fail "secret salvage must mark salvage_quarantined"
ok "secret hit → local branch, salvage_quarantined, no push"

# --- 4b. PI_SALVAGE_NO_PUSH=1 banks locally without pushing (fleet-ops#3023)
# Callers that already know the remote cannot accept the push (archived
# repo) use this to skip the doomed network round-trip; the local wip
# ref + ledger record still land.
clone="$(make_clone no-push)"
printf 'dirty\n' >"$clone/dirty.txt"
export PI_SALVAGE_WORKDIR="$clone"
export PI_SALVAGE_UNIT="unit-nopush"
export PI_SALVAGE_NOW="20260827T160300Z"
export PI_SALVAGE_NO_PUSH=1
export SERVICE_RESULT=signal EXIT_CODE=killed EXIT_STATUS=KILL
"$salvage"
if git -C "$scratch/no-push.git" show-ref --verify -q refs/heads/wip/unit-nopush-20260827T160300Z; then
    fail "NO_PUSH salvage must NOT push to origin"
fi
git -C "$clone" for-each-ref 'refs/heads/wip/unit-nopush-20260827T160300Z' \
    | grep -q . \
    || fail "NO_PUSH salvage must still create the local wip ref"
grep -q '"salvage_status":"local"' "$FLEET_DISPATCH_LEDGER" \
    || fail "NO_PUSH salvage must mark salvage_status=local"
unset PI_SALVAGE_NO_PUSH
ok "PI_SALVAGE_NO_PUSH=1 banks locally, skips the push"

# --- 4c. fleet-ops#5800: orphan worktrees banked, shared checkout untouched -
# Replay of the 2026-09-12 die-off: the unit's WorkingDirectory is the
# shared checkout (dirty on main — must be left in place), while the
# worker's real work sits dirty in sibling `git worktree add` trees on the
# worker's own branches. Salvage must enumerate them (worktree list +
# name tokens), commit `wip(salvage): <unit> <reason>`
# on the worker's branch, push it, and name the exclusions.
# fleet-ops#5984: a sibling whose name/branch carries no unit token is never
# swept (ownership unproven) — its branch, index and files stay untouched.
wtroot="$scratch/wt-root"
mkdir -p "$wtroot"
clone="$(make_clone orphan)"
printf 'shared dirt\n' >"$clone/shared-dirt.txt"
# Sibling A: no unit token in its name — must be left completely alone.
sib_a="$wtroot/0509-9999-notes"
git -C "$clone" worktree add -q "$sib_a" -b fix/dead-worker
printf 'one\n' >"$sib_a/one.txt"
printf 'two\n' >"$sib_a/two.txt"
printf 'three\n' >"$sib_a/three.txt"
a_head_before="$(git -C "$sib_a" rev-parse HEAD)"
# fleet-ops#5984 acceptance: salvage runs while a LIVE process (cwd inside
# the unowned sibling) holds the worktree — the incident was salvage
# committing+pushing a live interactive session's mid-edit tree. The holder
# must survive the sweep with the tree uncommitted and unpushed.
( cd "$sib_a" && exec sleep 600 ) &
live_holder=$!
# Sibling B: found via name token (dir carries the unit name).
sib_b="$wtroot/unit-orphan-extra"
git -C "$clone" worktree add -q "$sib_b" -b fix/dead-worker-2
printf 'extra\n' >"$sib_b/extra.txt"
printf 'SECRET=1\n' >"$sib_b/.env"
# Sibling C: dirty but sitting on main — NOT the worker's own branch.
sib_c="$wtroot/on-main"
git -C "$clone" worktree add -q --force "$sib_c" main
printf 'not ours\n' >"$sib_c/not-ours.txt"
export PI_SALVAGE_WORKDIR="$clone"
export PI_SALVAGE_UNIT="unit-orphan"
export PI_SALVAGE_PACKET="$scratch/orphan-packet.md"
printf 'orphan packet\n' >"$PI_SALVAGE_PACKET"
export PI_SALVAGE_NOW="20260827T160400Z"
export PI_SALVAGE_WORKTREE_ROOT="$wtroot"
export SERVICE_RESULT=exit-code EXIT_CODE=exited EXIT_STATUS=1
"$salvage" 2>"$scratch/orphan.log"

# Sibling A (no unit token): never swept — no push, no wip ref, untouched.
git -C "$scratch/orphan.git" show-ref --verify -q refs/heads/fix/dead-worker \
    && fail "unowned sibling's branch must NOT be pushed (fleet-ops#5984)"
git -C "$scratch/orphan.git" for-each-ref 'refs/heads/wip/' | grep -q . \
    && fail "no wip ref may be pushed for an unowned sibling (fleet-ops#5984)"
[[ "$(git -C "$sib_a" rev-parse HEAD)" == "$a_head_before" ]] \
    || fail "unowned sibling HEAD must be untouched (fleet-ops#5984)"
git -C "$sib_a" diff --cached --quiet \
    || fail "unowned sibling index must be untouched (fleet-ops#5984)"
git -C "$sib_a" status --porcelain | grep -q 'one.txt' \
    || fail "unowned sibling must be left dirty (fleet-ops#5984)"
# Sibling B (name token): banked on its own branch and pushed, .env excluded.
git -C "$scratch/orphan.git" show-ref --verify -q refs/heads/fix/dead-worker-2 \
    || fail "name-matched sibling must push fix/dead-worker-2"
git -C "$scratch/orphan.git" ls-tree -r --name-only refs/heads/fix/dead-worker-2 | grep -qx 'extra.txt' \
    || fail "pushed commit must carry extra.txt"
git -C "$scratch/orphan.git" ls-tree -r --name-only refs/heads/fix/dead-worker-2 | grep -q '^\.env$' \
    && fail ".env must be excluded from the pushed commit"
git -C "$scratch/orphan.git" log -1 --format=%B refs/heads/fix/dead-worker-2 \
    | grep -q '^wip(salvage): unit-orphan exit-code/1$' \
    || fail "name-matched sibling commit must read wip(salvage): <unit> <reason>"
# The worker's branch, not main, got the commit; nothing pushed to main.
git -C "$scratch/orphan.git" ls-tree -r --name-only refs/heads/main \
    | grep -q '\.env\|one\.txt\|not-ours\.txt' \
    && fail "remote main must stay clean of salvaged content"
# Sibling on main: untouched locally, never committed.
git -C "$sib_c" status --porcelain | grep -q 'not-ours.txt' \
    || fail "main-branch sibling must be left dirty"
git -C "$sib_c" rev-parse --abbrev-ref HEAD | grep -qx main \
    || fail "main-branch sibling must stay on main"
# Shared checkout: never swept, still dirty on main.
git -C "$clone" status --porcelain | grep -q 'shared-dirt.txt' \
    || fail "shared checkout dirt must be left in place"
git -C "$clone" rev-parse --abbrev-ref HEAD | grep -qx main \
    || fail "shared checkout must stay on main"
git -C "$clone" for-each-ref 'refs/heads/wip/' | grep -q . \
    && fail "no wip ref may be created when the seed is the shared checkout"
# Log + ledger + packet + note file name the salvage.
grep -q 'shared checkout dirty' "$scratch/orphan.log" \
    || fail "log must name the shared-checkout skip"
grep -q 'secrets-looking paths excluded.*\.env' "$scratch/orphan.log" \
    || fail "log must name the excluded .env"
grep -q '"salvaged_branch":"fix/dead-worker-2"' "$FLEET_DISPATCH_LEDGER" \
    || fail "ledger must name the pushed name-matched sibling branch"
grep -q 'fleet-ops#1204 salvage resume' "$PI_SALVAGE_PACKET" \
    || fail "packet must carry the resume stamp"
grep -q 'fix/dead-worker' "$PI_SALVAGE_PACKET" \
    || fail "packet must name the salvaged branches"
ls "$scratch"/salvage-unit-orphan-*.md >/dev/null 2>&1 \
    || fail "no linked issue -> salvage note must land next to the packet"
grep -q 'fix/dead-worker' "$scratch"/salvage-unit-orphan-*.md \
    || fail "salvage note must name branch + commit"
kill -0 "$live_holder" 2>/dev/null \
    || fail "live cwd holder must survive the salvage run (fleet-ops#5984)"
kill "$live_holder" 2>/dev/null || true
wait "$live_holder" 2>/dev/null || true
unset PI_SALVAGE_WORKTREE_ROOT PI_SALVAGE_PACKET
ok "owned sibling banked+pushed; unowned sibling untouched (#5984); shared checkout untouched (#5800)"

# --- 5. pi-systemd-run dry-run wires ExecStopPost --------------------------
out="$("$wrapper" --dry-run --unit salvage-shape --working-directory "$clone" -- /bin/true)"
printf '%s\n' "$out" | grep -q 'ExecStopPost=' || fail "dry-run must set ExecStopPost: $out"
printf '%s\n' "$out" | grep -q 'pi-salvage-worktree' || fail "ExecStopPost must call pi-salvage-worktree: $out"
printf '%s\n' "$out" | grep -q 'TimeoutStopSec=180' || fail "dry-run must set TimeoutStopSec=180: $out"
printf '%s\n' "$out" | grep -q 'PI_SALVAGE_WORKDIR' || fail "dry-run must export PI_SALVAGE_WORKDIR: $out"
ok "pi-systemd-run dry-run wires ExecStopPost + TimeoutStopSec=180"

out="$(PI_SALVAGE_DISABLE=1 "$wrapper" --dry-run --unit salvage-off -- /bin/true)"
# fleet-ops#4266: PI_SALVAGE_DISABLE drops ONLY the salvage leg; the
# dead-man ExecStopPost must stay armed (a disabled salvage must not also
# disable the death detector).
printf '%s\n' "$out" | grep -q 'pi-salvage-worktree' && fail "PI_SALVAGE_DISABLE=1 must omit the salvage hook: $out"
printf '%s\n' "$out" | grep -q 'ExecStopPost=.*pi-detached-deadman' \
  || fail "PI_SALVAGE_DISABLE=1 must keep the dead-man ExecStopPost: $out"
ok "PI_SALVAGE_DISABLE=1 omits salvage, keeps the dead-man hook"

# --- 6. WIP GC: merged deleted; open-ledger kept; stale unreferenced deleted
gcroot="$scratch/gc-products"
mkdir -p "$gcroot"
gc_clone="$(make_clone gcrepo)"
# restow under products-style root
mv "$gc_clone" "$gcroot/gcrepo"
mv "$scratch/gcrepo.git" "$scratch/gcrepo-origin.git"
# remotes still point at $scratch/gcrepo.git which we moved — fix
git -C "$gcroot/gcrepo" remote set-url origin "$scratch/gcrepo-origin.git"

# merged wip: branch equal to main
git -C "$gcroot/gcrepo" checkout -q -b wip/merged-unit-20260101T000000Z
git -C "$gcroot/gcrepo" push -q origin HEAD:wip/merged-unit-20260101T000000Z
git -C "$gcroot/gcrepo" checkout -q main

# live unique wip (referenced by open ledger)
printf 'live work\n' >"$gcroot/gcrepo/live.txt"
git -C "$gcroot/gcrepo" checkout -q -b wip/live-unit-20260827T160000Z
git -C "$gcroot/gcrepo" add live.txt
git -C "$gcroot/gcrepo" commit -q -m 'live unique'
git -C "$gcroot/gcrepo" push -q origin HEAD:wip/live-unit-20260827T160000Z
git -C "$gcroot/gcrepo" checkout -q main
printf '{"id":"open1","status":"open","unit":"live-unit","salvaged_branch":"wip/live-unit-20260827T160000Z"}\n' \
    >>"$FLEET_DISPATCH_LEDGER"

# stale unique unreferenced wip (backdated commit)
printf 'old work\n' >"$gcroot/gcrepo/old.txt"
git -C "$gcroot/gcrepo" checkout -q -b wip/stale-unit-20260101T000000Z
git -C "$gcroot/gcrepo" add old.txt
GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' \
    git -C "$gcroot/gcrepo" commit -q -m 'stale unique'
git -C "$gcroot/gcrepo" push -q origin HEAD:wip/stale-unit-20260101T000000Z
git -C "$gcroot/gcrepo" checkout -q main

export PI_SALVAGE_GC_ROOT="$gcroot"
"$salvage" --gc

git -C "$scratch/gcrepo-origin.git" show-ref --verify -q refs/heads/wip/merged-unit-20260101T000000Z \
    && fail "GC must delete merged wip branch"
git -C "$scratch/gcrepo-origin.git" show-ref --verify -q refs/heads/wip/live-unit-20260827T160000Z \
    || fail "GC must keep wip branch referenced by an open ledger entry"
git -C "$scratch/gcrepo-origin.git" show-ref --verify -q refs/heads/wip/stale-unit-20260101T000000Z \
    && fail "GC must delete 14d-old unreferenced wip branch"
ok "WIP GC: merged deleted, open-ledger kept, stale unreferenced deleted"

# --- 7. MANIFEST + weekly drop-in + pi-issue ExecStopPost ------------------
manifest="$repo_root/MANIFEST"
grep -Fxq 'bin/pi-salvage-worktree /home/nish/.local/bin/pi-salvage-worktree' "$manifest" \
    || fail "MANIFEST missing pi-salvage-worktree"
dropin="$repo_root/systemd/vps-weekly-update.service.d/20-wip-gc.conf"
[[ -f "$dropin" ]] || fail "missing $dropin"
grep -q 'pi-salvage-worktree --gc' "$dropin" || fail "drop-in must run --gc"
grep -qE '^ExecStopPost=-?/home/nish/.local/bin/pi-salvage-worktree$' \
    "$repo_root/systemd/pi-issue@.service" \
    || fail "pi-issue@.service must ExecStopPost the salvage hook"
ok "MANIFEST, weekly GC drop-in, and pi-issue@.service are wired"

# --- 8. live SIGTERM drill -------------------------------------------------
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    echo "SKIP: GitHub Actions — live SIGTERM salvage drill needs pi-systemd-run + push credentials (hermetic scenarios above cover the logic)"
    echo "ALL pi-salvage-worktree tests passed"
    exit 0
elif ! systemctl --user is-system-running >/dev/null 2>&1 \
    && ! systemctl --user show -p Version >/dev/null 2>&1; then
    echo "SKIP: no user systemd — live SIGTERM salvage drill not run here"
    echo "ALL pi-salvage-worktree tests passed"
    exit 0
fi

clone="$(make_clone live)"
printf 'uncommitted engine\n' >"$clone/engine.txt"
pkt="$scratch/live-packet.md"
printf 'live packet\n' >"$pkt"
unit="salvage-live-$$"
export PI_SALVAGE_NOW="20260827T161000Z"
# fleet-ops#5800: keep the sibling sweep's root scan on a scratch root —
# the real agent-worktrees dir must never be touched by a test unit.
export PI_SALVAGE_WORKTREE_ROOT="$scratch/agent-worktrees"
# wrapper sets PI_SALVAGE_* on the unit from --working-directory / --unit / --stdin
"$wrapper" --unit "$unit" --working-directory "$clone" --stdin "$pkt" -- /bin/sleep 25
sleep 0.5
state="$(systemctl --user is-active "${unit}.service" 2>/dev/null || true)"
if [[ "$state" != "active" && "$state" != "activating" ]]; then
    systemctl --user status "${unit}.service" --no-pager >&2 || true
    fail "live unit ${unit}.service should be active before SIGTERM, state=$state"
fi
systemctl --user stop "${unit}.service" >/dev/null 2>&1 || true
# ExecStopPost runs during stop; systemctl stop waits for it.
git -C "$scratch/live.git" show-ref --verify -q refs/heads/wip/${unit}-20260827T161000Z \
    || git -C "$scratch/live.git" show-ref | grep -q "wip/${unit}-" \
    || fail "live SIGTERM must push a wip/${unit}-* branch: $(git -C "$scratch/live.git" show-ref || true)"
grep -q 'fleet-ops#1204 salvage resume' "$pkt" || fail "live packet must be stamped"
systemctl --user reset-failed "${unit}.service" >/dev/null 2>&1 || true
ok "live SIGTERM of a pi-systemd-run unit banks a wip/ branch on the remote"

echo "ALL pi-salvage-worktree tests passed"
