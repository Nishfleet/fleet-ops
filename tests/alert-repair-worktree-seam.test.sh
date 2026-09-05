#!/usr/bin/env bash
# tests/alert-repair-worktree-seam.test.sh
#
# fleet-ops-3389: the alert-repair dispatcher spawned its pi worker with NO
# working directory (cwd=/home/nish), so a weak model found the live
# deploy-clone symlinks (~/.local/bin/* -> deploy-clone) and edited files in
# place (git checkout -b + edits), blocking merge-to-live for hours. The fix
# gives the worker the same worktree seam pi-issue-run uses:
#   - a repo-targeted alert gets a real git worktree (detached at the repo's
#     origin/main) under $ALERT_REPAIR_WORKTREE_ROOT/alert-repair-<name>;
#   - a fleet-internal alert (no repo label) gets a safe scratch working dir;
#   - either way the dispatch passes `--working-directory <dir>` to
#     pi-systemd-run, so the worker's cwd is NEVER the live deploy-clone;
#   - the packet names the working directory and forbids the live clone.
#
# What we prove (hermetic; no live 9090, no real systemd spawn — pi-systemd-run
# is mocked; the git worktree IS created from a scratch checkout):
#   1. Repo-targeted alert creates a real git worktree and passes its path as
#      --working-directory to the (mock) pi-systemd-run.
#   2. The packet for the repo-targeted alert carries a "## Working directory"
#      section naming the worktree and warning against the live deploy-clone.
#   3. A fleet-internal alert (no repo) gets a safe scratch working dir under
#      $ALERT_REPAIR_WORKDIR — never the live deploy-clone.
#   4. NO-SPAWN (ALERT_REPAIR_NO_SPAWN) does NOT create a worktree (hermetic
#      test guard stays intact).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

claim_bin="$repo_root/libexec/alert-repair-claim"
dispatch_bin="$repo_root/libexec/alert-repair-dispatch"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$claim_bin"    ]] || fail "not executable: $claim_bin"
[[ -x "$dispatch_bin" ]] || fail "not executable: $dispatch_bin"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export XDG_RUNTIME_DIR="$scratch/run"
export FLEET_CLAIM_CHECKOUT_ROOT="$scratch/products"
export FLEET_CLAIM_REMOTE=origin
export FLEET_CLAIM_MAIN_BRANCH=main
export ALERT_REPAIR_STATE_DIR="$scratch/alert-repair-state"
export ALERT_REPAIR_PACKET_DIR="$scratch/agent-state/alert-repair"
export PACKET_DIR="$scratch/agent-state/alert-repair"
export SEAT_HEALTH_FILE="$scratch/pi-seat-health.json"
export ALERT_REPAIR_CLAIM_BIN="$claim_bin"
# fleet-ops-3389 overrides: redirect all worktree/dir creation into scratch.
export ALERT_REPAIR_WORKTREE_ROOT="$scratch/agent-worktrees"
export ALERT_REPAIR_REPO_CHECKOUT_ROOT="$scratch/products"
export ALERT_REPAIR_FLEET_OPS_CLONE="$scratch/products/fleet-ops"
export ALERT_REPAIR_WORKDIR="$scratch/workdir"
mkdir -p "$FLEET_CLAIM_CHECKOUT_ROOT" "$ALERT_REPAIR_STATE_DIR" "$PACKET_DIR" \
    "$XDG_RUNTIME_DIR" "$ALERT_REPAIR_WORKTREE_ROOT" "$ALERT_REPAIR_WORKDIR"

# --- bare remote + product checkout (fleet-ops) -----------------------------
bare="$scratch/bare/fleet-ops.git"
mkdir -p "$scratch/bare"
git -c init.defaultBranch=main init --bare -q "$bare"
checkout="$FLEET_CLAIM_CHECKOUT_ROOT/fleet-ops"
git -c init.defaultBranch=main clone -q "$bare" "$checkout"
(
    cd "$checkout"
    git config user.email "test@example.com"
    git config user.name "Test"
    echo 'init' > file.txt
    git add file.txt
    git commit -q -m 'initial'
    git branch -M main
    git push -q -u origin main
)

# --- mock pi-systemd-run: records the argv, never spawns ---------------------
mock_bin="$scratch/mock-bin"
mkdir -p "$mock_bin"
cat >"$mock_bin/pi-systemd-run" <<'MOCK'
#!/usr/bin/env bash
echo "mock-pi-systemd-run $*" >> "${MOCK_LOG:-/dev/null}"
exit 0
MOCK
chmod +x "$mock_bin/pi-systemd-run"
MOCK_LOG="$scratch/mock-pi-systemd-run.log"
export MOCK_LOG

# Seat health file: fresh fallback-ladder seat.
cat >"$SEAT_HEALTH_FILE" <<'EOF'
{"provider":"minimax","model":"MiniMax-M3","health_class":"healthy","observed_at":"2099-01-01T00:00:00Z"}
EOF

# --- mock git? No: real git. To make _make_working_dir fall to scratch, we
# point the fleet-ops clone at a path that is not a git checkout in scenario 3.

# --- 1. repo-targeted alert creates a worktree + --working-directory --------
fire_dispatch() {
    local alertname="$1" repo="$2" out="$3" err="$4"
    AMX_ALERT_1_LABEL_alertname="$alertname" \
    AMX_ALERT_1_LABEL_repo="$repo" \
    AMX_ALERT_1_LABEL_severity="critical" \
    AMX_ALERT_1_LABEL_service="fleet" \
    AMX_LABEL_repo="$repo" \
    AMX_STATUS="firing" \
    AMX_RECEIVER="test-receiver" \
    PATH="$mock_bin:$PATH" \
    HOME="$scratch" \
    "$dispatch_bin" \
        >"$out" 2>"$err"
}

: >"$MOCK_LOG"
fire_dispatch FleetWorktreeSeamAlert fleet-ops \
    "$scratch/out.1" "$scratch/err.1"
rc=$?
[[ "$rc" == 0 ]] || fail "repo dispatch must exit 0, got rc=$rc ($(cat "$scratch/err.1"))"
grep -q '\] DISPATCH ' "$PACKET_DIR/actions.log" \
    || fail "repo dispatch must write a DISPATCH line (log: $(cat "$PACKET_DIR/actions.log"))"

# pi-systemd-run was invoked with a --working-directory that is a scratch
# worktree path (never the live deploy-clone).
mock_args=$(grep 'mock-pi-systemd-run ' "$MOCK_LOG" | tail -1)
[[ "$mock_args" == *"--working-directory"* ]] \
    || fail "must pass --working-directory (got: $mock_args)"
wt=$(printf '%s\n' "$mock_args" \
    | awk '{for(i=1;i<=NF;i++){if($i=="--working-directory"){print $(i+1)}}}')
[[ -n "$wt" ]] || fail "could not extract --working-directory value"
case "$wt" in
    "$ALERT_REPAIR_WORKTREE_ROOT"/alert-repair-*) : ;;
    *) fail "working dir must be under the scratch worktree root, got: $wt" ;;
esac
[[ "$wt" != *"deploy-clone"* ]] \
    || fail "working dir must never be the live deploy-clone, got: $wt"
# The worktree really exists and is a git worktree.
git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || fail "worktree not a git working tree at $wt"
ok "repo alert: real git worktree created and passed as --working-directory"

# The packet names the working directory and forbids the live clone.
pkt=$(ls "$PACKET_DIR"/packet-FleetWorktreeSeamAlert-*.md | tail -1)
grep -q '## Working directory' "$pkt" \
    || fail "packet must carry a '## Working directory' section"
grep -q "$wt" "$pkt" \
    || fail "packet must name the working directory ($wt)"
grep -q 'fleet-ops-deploy-clone' "$pkt" \
    || fail "packet must warn against the live deploy-clone"
ok "repo alert: packet names the worktree and forbids the live clone"

# --- 2. fleet-internal alert (no repo) gets a safe scratch working dir ------
# Release the repo claim isn't needed (different alert -> different claim).
: >"$MOCK_LOG"
fire_dispatch FleetInternalSeamAlert "" \
    "$scratch/out.2" "$scratch/err.2"
rc=$?
[[ "$rc" == 0 ]] || fail "internal dispatch must exit 0, got rc=$rc ($(cat "$scratch/err.2"))"
mock_args=$(grep 'mock-pi-systemd-run ' "$MOCK_LOG" | tail -1)
wt=$(printf '%s\n' "$mock_args" \
    | awk '{for(i=1;i<=NF;i++){if($i=="--working-directory"){print $(i+1)}}}')
case "$wt" in
    "$ALERT_REPAIR_WORKDIR"/*) : ;;
    *) fail "internal alert must get a scratch working dir under workdir root, got: $wt" ;;
esac
pkt=$(ls "$PACKET_DIR"/packet-FleetInternalSeamAlert-*.md | tail -1)
grep -q '## Working directory' "$pkt" \
    || fail "internal alert packet must carry a '## Working directory' section"
ok "internal alert: safe scratch working dir named, never the live clone"

# --- 3. NO-SPAWN does not create a worktree (hermetic guard intact) ---------
# With ALERT_REPAIR_NO_SPAWN the dispatch returns before _make_working_dir, so
# no worktree and no --working-directory are produced — the earlier hermetic
# tests stay truly hermetic.
: >"$MOCK_LOG"
ALERT_REPAIR_NO_SPAWN=1 \
AMX_ALERT_1_LABEL_alertname="FleetNoSpawnSeamAlert" \
AMX_ALERT_1_LABEL_repo="fleet-ops" \
AMX_ALERT_1_LABEL_severity="critical" \
AMX_ALERT_1_LABEL_service="fleet" \
AMX_LABEL_repo="fleet-ops" \
AMX_STATUS="firing" \
AMX_RECEIVER="test-receiver" \
PATH="$mock_bin:$PATH" \
HOME="$scratch" \
"$dispatch_bin" >"$scratch/out.3" 2>"$scratch/err.3" || true
[[ ! -s "$MOCK_LOG" ]] \
    || fail "NO-SPAWN must not invoke pi-systemd-run (got: $(cat "$MOCK_LOG"))"
ls "$ALERT_REPAIR_WORKTREE_ROOT"/alert-repair-FleetNoSpawnSeamAlert-* >/dev/null 2>&1 \
    && fail "NO-SPAWN must not create a worktree"
ok "NO-SPAWN leaves no worktree behind (hermetic guard intact)"

echo
echo "alert-repair-worktree-seam test: 4/4 OK"
