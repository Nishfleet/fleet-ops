#!/usr/bin/env bash
# tests/pi-issue-run-cwd-anchor.test.sh
#
# fleet-ops#5687 (reopened): the worker's pi session inherits pi-issue-run's
# cwd. A unit launched or replayed from inside the deploy clone hands the
# clone to the worker as cwd — and a relative `git worktree add
# issue-<repo>-<N>` then plants a live tree INSIDE the clone (live dirt
# 2026-09-12: fleet-ops-deploy-clone/issue-fleet-ops-5746/, worker dead, real
# work sat in agent-worktrees/issue-fleet-ops-5746 + PR #5758).
#
# pi-issue-run now anchors the session to the issue's absolute worktree when
# it exists (re-entrant claims), else the absolute worktree parent, else
# $HOME — never the inherited cwd.
#
# Proves, offline with a fake pi that records its own cwd:
#   1. Launched with cwd=<fake deploy clone>, pi runs with cwd =
#      <wt-root>/issue-<inst> when that worktree exists.
#   2. Worktree absent -> cwd = <wt-root>.
#   3. Worktree root absent -> cwd = $HOME.
#   In every case the clone's cwd is never handed to pi.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/pi-issue-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch="$(mktemp -d -t pi-issue-cwd-anchor.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"

# P14: stub a working App identity so the run reaches pi.
mkdir -p "$HOME/.config/fleet-worker"
: >"$HOME/.config/fleet-worker/nishfleet-worker.env"
chmod 600 "$HOME/.config/fleet-worker/nishfleet-worker.env"

STATE_DIR="$scratch/state"
mkdir -p "$STATE_DIR/attempts" "$STATE_DIR/active-seats"
ISSUES_DIR="$scratch/issues"
mkdir -p "$ISSUES_DIR"
LEDGER="$scratch/ledger"
mkdir -p "$LEDGER"

export PI_PACKET_STATE="$STATE_DIR"
export PI_SEAT_HEALTH_LEDGER_DIR="$LEDGER"
export PI_SEAT_HEALTH_SIDECAR="$scratch/pi-seat-health.json"
export PI_ISSUES_DIR="$ISSUES_DIR"
export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export XDG_RUNTIME_DIR="$scratch/xdg"
export PI_SEAT_LIB_CHECK_SYSTEMD=0
export EMPTY_RUN_RETRY_MAX=0
mkdir -p "$XDG_RUNTIME_DIR"

WT_ROOT="$scratch/agent-worktrees"
export PI_ISSUE_WORKTREE_ROOT="$WT_ROOT"

# A real git repo standing in for the deploy clone — we launch from inside it
# and assert the session cwd is never this directory.
clone="$scratch/fleet-ops-deploy-clone"
mkdir -p "$clone"
git -C "$clone" init -q
git -C "$clone" -c user.email=t@t -c user.name=t commit -qm init --allow-empty

stub_bin="$scratch/stub-bin"
mkdir -p "$stub_bin"

# Fake pi: record its cwd, print a byte, exit 0 (provider no-op path — the
# run exits 1 after the bench, but pi ran and recorded cwd).
cat >"$stub_bin/pi" <<STUB
#!/usr/bin/env bash
pwd >> "$scratch/pi-cwd.log"
printf 'x'
exit 0
STUB
chmod +x "$stub_bin/pi"
export PI_BIN="$stub_bin/pi"

cat >"$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"--jq"* ]]; then
    printf 'open\n'
    exit 0
fi
printf '[]\n'
exit 0
STUB
chmod +x "$stub_bin/gh"

cat >"$stub_bin/worker-token" <<'STUB'
#!/usr/bin/env bash
printf 'export GH_TOKEN=fake-test-token-cccccccccccccccc\n'
exit 0
STUB
chmod +x "$stub_bin/worker-token"
export WORKER_TOKEN_BIN="$stub_bin/worker-token"

cat >"$stub_bin/systemctl" <<'STUB'
#!/usr/bin/env bash
args=" $* "
if [[ "$args" == *" show "* ]] && [[ "$args" == *"ExecStart"* ]]; then
  printf '/home/nish/.local/bin/pi --print --provider devin --model glm-5-2\n'
  exit 0
fi
exit 0
STUB
chmod +x "$stub_bin/systemctl"

export PATH="$stub_bin:/usr/local/bin:/usr/bin:/bin"

cat >"$PI_MODELS_JSON" <<'JSON'
{
  "providers": {
    "devin": {
      "models": [
        { "id": "glm-5-2", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 }
      ]
    }
  }
}
JSON

cat >"$SEAT_CAPS_JSON" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": [],
  "providers": {
    "devin": { "cap": 4, "class": "subscription", "remote_agent": true, "models": { "glm-5-2": 4 } }
  }
}
JSON

export PI_PACKET_SEAT_LIB="$repo_root/lib/litellm-seat.sh"

inst="fleet-ops-5687"
printf 'Implement one GitHub issue: fleet-ops#5687.\n' >"$ISSUES_DIR/${inst}.in"

run_from_clone() {
  # Each case is a fresh claim: the 1-byte no-op benches the seat, so reset
  # the seat ledger and this instance's tried-seats between runs or the next
  # pick finds no usable seat and never reaches pi.
  rm -rf "$LEDGER"; mkdir -p "$LEDGER"
  rm -f "$STATE_DIR/attempts/pi-issue-${inst}.tried-seats"
  set +e
  ( cd "$clone" && bash "$bin" "$inst" ) >"$scratch/run.out" 2>"$scratch/run.err"
  set -e
}

# --- 1. Worktree exists -> session cwd is the absolute worktree --------------
mkdir -p "$WT_ROOT/issue-${inst}"
: >"$scratch/pi-cwd.log"
run_from_clone || true
got="$(tail -1 "$scratch/pi-cwd.log")"
[[ "$got" == "$WT_ROOT/issue-${inst}" ]] \
  || fail "existing worktree: pi cwd must be the absolute worktree, got '$got'"
ok "existing worktree -> pi cwd anchored to $WT_ROOT/issue-$inst"

# --- 2. Worktree absent -> session cwd is the worktree parent ----------------
rm -rf "$WT_ROOT/issue-${inst}"
: >"$scratch/pi-cwd.log"
run_from_clone || true
got="$(tail -1 "$scratch/pi-cwd.log")"
[[ "$got" == "$WT_ROOT" ]] \
  || fail "worktree absent: pi cwd must be the worktree parent, got '$got'"
ok "worktree absent -> pi cwd anchored to worktree parent"

# --- 3. Worktree root absent -> session cwd is $HOME -------------------------
rm -rf "$WT_ROOT"
: >"$scratch/pi-cwd.log"
run_from_clone || true
got="$(tail -1 "$scratch/pi-cwd.log")"
[[ "$got" == "$HOME" ]] \
  || fail "worktree root absent: pi cwd must fall back to \$HOME, got '$got'"
ok "worktree root absent -> pi cwd falls back to \$HOME"

# --- the clone is never the session cwd --------------------------------------
grep -qx "$clone" "$scratch/pi-cwd.log" \
  && fail "pi inherited the deploy clone as cwd — relative worktree adds would plant trees inside it"
[[ -z "$(git -C "$clone" status --porcelain)" ]] \
  || fail "deploy clone must stay clean after a from-clone launch"
ok "launched from the deploy clone: session never inherits the clone cwd, clone stays clean"

echo "pi-issue-run-cwd-anchor: all checks passed"
