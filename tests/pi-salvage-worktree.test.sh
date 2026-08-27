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

git_ident() {
    git -C "$1" config user.email salvage-test@localhost
    git -C "$1" config user.name salvage-test
}

make_clone() {
    local name="$1"
    local bare="$scratch/${name}.git"
    local clone="$scratch/${name}"
    git init --bare -q "$bare"
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

# --- 5. pi-systemd-run dry-run wires ExecStopPost --------------------------
out="$("$wrapper" --dry-run --unit salvage-shape --working-directory "$clone" -- /bin/true)"
printf '%s\n' "$out" | grep -q 'ExecStopPost=' || fail "dry-run must set ExecStopPost: $out"
printf '%s\n' "$out" | grep -q 'pi-salvage-worktree' || fail "ExecStopPost must call pi-salvage-worktree: $out"
printf '%s\n' "$out" | grep -q 'TimeoutStopSec=180' || fail "dry-run must set TimeoutStopSec=180: $out"
printf '%s\n' "$out" | grep -q 'PI_SALVAGE_WORKDIR' || fail "dry-run must export PI_SALVAGE_WORKDIR: $out"
ok "pi-systemd-run dry-run wires ExecStopPost + TimeoutStopSec=180"

out="$(PI_SALVAGE_DISABLE=1 "$wrapper" --dry-run --unit salvage-off -- /bin/true)"
printf '%s\n' "$out" | grep -q 'ExecStopPost=' && fail "PI_SALVAGE_DISABLE=1 must omit ExecStopPost: $out"
ok "PI_SALVAGE_DISABLE=1 omits the salvage hook"

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
if ! systemctl --user is-system-running >/dev/null 2>&1 \
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
