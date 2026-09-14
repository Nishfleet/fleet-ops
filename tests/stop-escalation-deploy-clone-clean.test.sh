#!/usr/bin/env bash
# tests/stop-escalation-deploy-clone-clean.test.sh
#
# fleet-ops#5863: the 2026-09-12 live fault — a senior auditor dispatched by
# stop-escalation.service repaired siterep-live-canary by editing
# bin/siterep-live-canary DIRECTLY inside the deploy clone (the live install
# source that must stay clean origin/main, fleet-ops#3758), tripping
# DEPLOY-CHECK-DIRTY-CLONE and stalling merge-to-live. Proves the repair path
# now carries three layers:
#   1. the SENIOR AUDITOR packet instructs worktree + PR, never the clone
#      (packet text rule),
#   2. the auditor session is cwd-anchored away from any inherited repo cwd
#      (the pi-issue-run fleet-ops#5783 anchor, applied to the auditor),
#   3. a mechanical gate: an auditor run that leaves the deploy clone dirty
#      is recorded LOUD as AUDITOR-DIRTY-CLONE in AUDITOR-LOG.md.
#
# Runs entirely offline with a stubbed litellm-seat.sh and a fake `pi` binary.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
dispatch="$repo_root/bin/stop-escalation-dispatch"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$dispatch" ]] || fail "stop-escalation-dispatch not executable"

echo "=== layer 1: packet text carries the deploy-clone rule ==="
grep -q 'DEPLOY-CLONE RULE' "$dispatch" \
  || fail "packet lacks the DEPLOY-CLONE RULE (worktree + PR, never the clone)"
grep -q 'fleet-ops#3758' "$dispatch" \
  || fail "packet rule does not cite the standing rule it enforces (fleet-ops#3758)"
grep -q 'agent-worktrees' "$dispatch" \
  || fail "packet rule does not name the worktree root to repair in"
ok "packet instructs worktree + PR, never the deploy clone"

# Shared stub scaffolding -------------------------------------------------
setup_env() {
  local scratch="$1"
  export HOME="$scratch/home"
  mkdir -p "$HOME"

  cat >"$HOME/.gitconfig" <<'EOF'
[user]
name = test
email = test@example.com
[init]
defaultBranch = main
EOF

  mkdir -p "$scratch/agent-state"
  cat >"$scratch/agent-state/STOP-REASON.json" <<'JSON'
{"reason":"unit-failure","detail":{"unit":"pi-issue@fleet-ops-5863.service"}}
JSON

  # Seat stub: one healthy capable seat, matching the real
  # lib/litellm-seat.sh contract (group + tried-file args).
  cat >"$scratch/seatlib-stub.sh" <<'EOF'
#!/usr/bin/env bash
litellm_seat() {
  local TAB=$'\t'
  printf 'devin%sglm-5-2\n' "$TAB"
  return 0
}
mark_seat_spawn_fail() { :; }
is_credentials_error() { return 1; }
mark_seat_credentials_bad() { return 1; }
is_quota_cap_error() { return 1; }
mark_seat_quota_bench() { :; }
is_overload_error() { return 1; }
mark_seat_overload_bench() { :; }
seat_log() { :; }
EOF

  # Fake deploy clone: a real tiny git repo the gate can read dirt from.
  git init -q "$scratch/deploy-clone"
  git -C "$scratch/deploy-clone" commit -q --allow-empty -m "clean main"

  cat >"$scratch/pi" <<EOF
#!/usr/bin/env bash
# Fake \`pi\` for tests; behaviour driven by STOP_ESCALATION_TEST_PI_MODE.
mode="\${STOP_ESCALATION_TEST_PI_MODE:-block}"
# Record the cwd the dispatcher handed the auditor session (layer 2 probe).
printf '%s\n' "\$PWD" > "\${STOP_ESCALATION_TEST_CWD_FILE:?}"
case "\$mode" in
  block)
    printf -- '---\n## 2026-09-12T12:00:00Z — SENIOR AUDITOR\n**Summoning trip:** test\n**Root cause:** test cause\n'
    exit 0
    ;;
  dirty)
    # Simulate the 2026-09-12 fault: the auditor edits a tracked file
    # DIRECTLY inside the deploy clone mid-repair.
    printf 'auditor direct edit\n' >> "\${STOP_ESCALATION_TEST_CLONE_FILE:?}"
    printf -- '---\n## 2026-09-12T12:00:00Z — SENIOR AUDITOR\n**Root cause:** repaired in clone (bad)\n'
    exit 0
    ;;
  *)
    echo "pi-stub: unknown mode \$mode" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$scratch/pi"

  export STOP_ESCALATION_AS="$scratch/agent-state"
  export STOP_ESCALATION_STOP_REASON="$scratch/agent-state/STOP-REASON.json"
  export STOP_ESCALATION_SEEN="$scratch/agent-state/stop-escalation-seen.txt"
  export STOP_ESCALATION_KILLS="$scratch/agent-state/stop-escalation-kills.txt"
  export STOP_ESCALATION_WALLED="$scratch/agent-state/stop-escalation-walled.txt"
  export STOP_ESCALATION_NISH="$scratch/agent-state/NISH-ESCALATIONS.md"
  export STOP_ESCALATION_AUDITOR_LOG="$scratch/agent-state/AUDITOR-LOG.md"
  export STOP_ESCALATION_PI_BIN="$scratch/pi"
  export PI_PACKET_SEAT_LIB="$scratch/seatlib-stub.sh"
  export STOP_ESCALATION_AUDITOR_TIMEOUT=5
  export STOP_ESCALATION_COOLDOWN=0
  export STOP_ESCALATION_WALLED_CD=0
  export STOP_ESCALATION_DEPLOY_CLONE="$scratch/deploy-clone"
  export STOP_ESCALATION_TEST_CLONE_FILE="$scratch/deploy-clone/tracked.txt"
  export STOP_ESCALATION_TEST_CWD_FILE="$scratch/auditor-cwd-recorded.txt"
  export STOP_ESCALATION_AUDITOR_CWD="$scratch/auditor-cwd"
  mkdir -p "$scratch/auditor-cwd"
  printf 'original\n' > "$scratch/deploy-clone/tracked.txt"
  git -C "$scratch/deploy-clone" add tracked.txt
  git -C "$scratch/deploy-clone" commit -q -m "tracked file"
}

run_from_inside_clone() {
  set +e
  (cd "$STOP_ESCALATION_DEPLOY_CLONE" && "$dispatch")
  local rc=$?
  set -e
  return "$rc"
}

# ---------------------------------------------------------------------------
# Layer 2: cwd anchor — a dispatch launched from inside the deploy clone must
# hand the auditor session a cwd OUTSIDE the clone (the #5783 anchor).
# ---------------------------------------------------------------------------
scratch1="$(mktemp -d -t stop-esc-clone-a.XXXXXX)"
setup_env "$scratch1"
export STOP_ESCALATION_TEST_PI_MODE=block
run_from_inside_clone || fail "anchor case: dispatch exited non-zero"
[[ -f "$STOP_ESCALATION_TEST_CWD_FILE" ]] || fail "fake pi never ran (no cwd recorded)"
recorded_cwd="$(cat "$STOP_ESCALATION_TEST_CWD_FILE")"
case "$recorded_cwd" in
  "$STOP_ESCALATION_DEPLOY_CLONE"|"$STOP_ESCALATION_DEPLOY_CLONE"/*) \
    fail "auditor session cwd is inside the deploy clone: $recorded_cwd" ;;
esac
[[ "$recorded_cwd" == "$STOP_ESCALATION_AUDITOR_CWD" ]] \
  || fail "auditor session cwd not anchored to AUDITOR_CWD: $recorded_cwd"
ok "auditor session anchored outside the deploy clone ($recorded_cwd)"
rm -rf "$scratch1"

# ---------------------------------------------------------------------------
# Layer 3a: an auditor run that dirties the deploy clone is recorded LOUD as
# AUDITOR-DIRTY-CLONE in AUDITOR-LOG.md (mechanical gate, exit status intact).
# ---------------------------------------------------------------------------
scratch2="$(mktemp -d -t stop-esc-clone-b.XXXXXX)"
setup_env "$scratch2"
export STOP_ESCALATION_TEST_PI_MODE=dirty
run_from_inside_clone || fail "dirty case: dispatch exited non-zero"
grep -q 'AUDITOR-DIRTY-CLONE' "$STOP_ESCALATION_AUDITOR_LOG" \
  || fail "auditor dirtied the deploy clone but no AUDITOR-DIRTY-CLONE line in AUDITOR-LOG.md"
# The loud line must carry the standing-rule citation and the offending path.
grep -q 'fleet-ops#3758' "$STOP_ESCALATION_AUDITOR_LOG" \
  || fail "AUDITOR-DIRTY-CLONE line lacks the fleet-ops#3758 citation"
grep -q "$STOP_ESCALATION_DEPLOY_CLONE" "$STOP_ESCALATION_AUDITOR_LOG" \
  || fail "AUDITOR-DIRTY-CLONE line lacks the clone path"
ok "auditor-dirtied clone -> AUDITOR-DIRTY-CLONE recorded in AUDITOR-LOG.md"
rm -rf "$scratch2"

# ---------------------------------------------------------------------------
# Layer 3b: a clean auditor run leaves NO AUDITOR-DIRTY-CLONE line (no false
# positive) and the diagnosis block is still logged.
# ---------------------------------------------------------------------------
scratch3="$(mktemp -d -t stop-esc-clone-c.XXXXXX)"
setup_env "$scratch3"
export STOP_ESCALATION_TEST_PI_MODE=block
run_from_inside_clone || fail "clean case: dispatch exited non-zero"
if grep -q 'AUDITOR-DIRTY-CLONE' "$STOP_ESCALATION_AUDITOR_LOG"; then
  fail "clean auditor run recorded a false AUDITOR-DIRTY-CLONE"
fi
grep -q 'SENIOR AUDITOR' "$STOP_ESCALATION_AUDITOR_LOG" \
  || fail "clean case: diagnosis block missing from AUDITOR-LOG.md"
ok "clean auditor run -> no AUDITOR-DIRTY-CLONE false positive, block still logged"
rm -rf "$scratch3"

echo "ALL GREEN: stop-escalation-deploy-clone-clean"
