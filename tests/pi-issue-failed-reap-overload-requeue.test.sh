#!/usr/bin/env bash
# tests/pi-issue-failed-reap-overload-requeue.test.sh
#
# fleet-ops#5743 → cleanup #4263/#6100: the bench-aware transient-overload
# requeue is DELETED. The per-seat bench ledger, seat_usable and the
# bench_until comparison no longer exist — the LiteLLM proxy cooldown owns
# seat health, and the failed-claim requeue is the plain RECLAIM_COOLDOWN_S
# marker (a single UTC timestamp line, no `until:` row).
#
# Proves (offline, mocked gh + systemctl):
#   1. OPEN issue + branch deleted -> the cooldown marker is minted with ONLY
#      the back-compat UTC timestamp line — no `until:` bench row, no ledger
#      read, no TRANSIENT-OVERLOAD-REQUEUE triage line.
#   2. A stale bench-era ledger file in PI_SEAT_HEALTH_LEDGER_DIR does not
#      resurrect the bench-aware path (no reader exists).
#   3. Stale claim-branch cleanup (fleet-ops#3328 corollary): the reap
#      deletes claim/issue-<N> on the failed attempt (branch-exists probe +
#      DELETE call) so the left-behind mutex branch cannot starve the next
#      dispatch.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/pi-issue-failed-reap"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

fake="$(mktemp -d)"
triage="$(mktemp)"
trap 'rm -rf "$fake"; rm -f "$triage"' EXIT

cat >"$fake/systemctl" <<'FAKE_SYSCTL'
#!/usr/bin/env bash
shift  # --user
case "$1" in
  stop) exit 0 ;;
  reset-failed) exit 0 ;;
  show)
    prop=""
    while [[ $# -gt 0 ]]; do
      case "$1" in -p) prop="$2"; shift 2 ;; --value) shift ;; *) shift ;; esac
    done
    case "$prop" in ActiveState) echo inactive ;; MainPID) echo 0 ;; *) echo "" ;; esac
    ;;
  *) exit 0 ;;
esac
FAKE_SYSCTL
chmod +x "$fake/systemctl"

# Installs the gh fake; args: branch_delete_rc pr_count.
mkdir -p "$fake/gh-bin"
cat >"$fake/gh-bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
case "$1" in
  api)
    path="${2:-}"
    if [[ "$path" == */issues/* ]]; then
      printf '%s\n' '{"state":"OPEN","labels":[{"name":"agent-in-progress"}]}'
      exit 0
    fi
    if [[ "$path" == */pulls* ]]; then
      printf '[]\n'
      exit 0
    fi
    if [[ "$path" == */git/refs/heads/* ]]; then
      if [[ "$*" == *-X*DELETE* ]]; then exit 0; fi
      exit 0
    fi
    exit 1
    ;;
  issue) case "$2" in edit|comment) exit 0 ;; *) exit 1 ;; esac ;;
  *) exit 1 ;;
esac
FAKE_GH
chmod +x "$fake/gh-bin/gh"

# Cleanup #4263/#6100: the reap must not read ANY seat ledger. A stub seatlib
# whose ledger functions would scream proves no caller remains.
cat >"$fake/litellm-seat.sh" <<'FAKE_SEAT'
seat_ledger_path() { echo "FAIL: seat_ledger_path called after cleanup #4263/#6100" >&2; return 1; }
seat_usable() { echo "FAIL: seat_usable called after cleanup #4263/#6100" >&2; return 1; }
seat_log() { :; }
FAKE_SEAT
export SEAT_LIB="$fake/litellm-seat.sh"
export PI_INTAKE_RECLAIM_COOLDOWN_S=900

state_dir="$fake/state"
mkdir -p "$state_dir/attempts"
issues_dir="$fake/issues"
mkdir -p "$issues_dir"
export PI_PACKET_STATE="$state_dir"
export PI_ISSUES_DIR="$issues_dir"

ledger_dir="$fake/ledgers"
mkdir -p "$ledger_dir"
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger_dir"

write_seat() {
    printf 'commandcode/minimax/minimax-m3-free\n' >"$state_dir/attempts/pi-issue-fleet-ops-5743.seat"
}

run_reap() {
    set +e
    out="$(PATH="$fake/gh-bin:$PATH" SYSTEMCTL="$fake/systemctl" TRIAGE_FILE="$triage" \
        "$bin" fleet-ops-5743 2>&1)"
    rc=$?
    set -e
}

cooldown="$state_dir/attempts/pi-issue-fleet-ops-5743.cooldown"

# --- Test 1: OPEN issue + branch deleted -> plain cooldown, NO until: row ---
printf 'pkt\n' >"$issues_dir/fleet-ops-5743.in"
: >"$triage"
rm -f "$cooldown"
write_seat
# Stale bench-era ledger with a far-future bench_until: must be ignored.
mkdir -p "$ledger_dir/commandcode--minimax"
printf '{"health_class":"overload_bench","failure_mode":"overload_503","bench_until":"2099-01-01T00:00:00Z"}\n' \
    >"$ledger_dir/commandcode--minimax/minimax-m3-free.json"
run_reap
[[ "$rc" == "0" ]] || fail "reap must exit 0, got $rc ($out)"
[[ -f "$cooldown" ]] || fail "cooldown marker must exist"
ts_head=$(head -n 1 "$cooldown")
[[ "$ts_head" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || fail "marker line 1 must stay a UTC timestamp for back-compat, got: $ts_head"
if grep -q '^until: ' "$cooldown"; then
    fail "bench-aware until: line is deleted (cleanup #4263/#6100), got: $(cat "$cooldown")"
fi
grep -q 'TRANSIENT-OVERLOAD-REQUEUE' "$triage" \
    && fail "TRANSIENT-OVERLOAD-REQUEUE triage class is deleted (cleanup #4263/#6100): $(cat "$triage")"
ok "Test 1: plain RECLAIM_COOLDOWN_S requeue; no until: row, no bench read (stale ledger ignored)"

# --- Test 2: no seat file -> fail-open plain cooldown ------------------------
printf 'pkt\n' >"$issues_dir/fleet-ops-5743.in"
: >"$triage"
rm -f "$cooldown" "$state_dir/attempts/pi-issue-fleet-ops-5743.seat"
run_reap
[[ -f "$cooldown" ]] || fail "cooldown marker must exist even with no seat file"
! grep -q '^until: ' "$cooldown" || fail "no seat -> no until line"
ok "Test 2: no last-seat file fails open to the plain cooldown"

# --- Test 3: stale claim branch is DELETED by this same reap ----------------
# (fleet-ops#5743 corollary: #3328 left-behind mutex branches starve the next
# dispatch — the reap's branch_exists + DELETE path is the mechanism.)
grep -q 'git/refs/heads/$branch_name" -X DELETE' "$bin" \
    || fail "reap must delete claim/issue-<N> on the failed attempt (fleet-ops#3328)"
grep -q 'branch_exists=no' "$bin" || fail "branch exists probe missing"
ok "Test 3: stale claim-branch cleanup (delete claim/issue-<N>) present in reap path"

echo "OK: pi-issue-failed-reap-overload-requeue.test.sh"
