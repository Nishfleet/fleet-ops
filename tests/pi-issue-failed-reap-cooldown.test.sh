#!/usr/bin/env bash
# tests/pi-issue-failed-reap-cooldown.test.sh
#
# fleet-ops#2133: proves the reclaim cooldown marker is written by
# pi-issue-failed-reap when an OPEN issue's claim is released (branch
# deleted, no open PR), and is NOT written in the open-PR shortcut or
# CLOSED paths. The marker tells intake to skip the issue for a cooldown
# window so the spawn-die-respawn loop is broken.
#
# Proves (offline, mocked gh + systemctl):
#   1. OPEN issue + branch deleted -> cooldown file written with a fresh
#      UTC ISO8601 timestamp, triage carries RECLAIM-COOLDOWN-SET.
#   2. OPEN issue + branch delete FAILS -> no cooldown file (the reap did
#      not actually release the claim; re-claiming is safe).
#   3. CLOSED issue -> no cooldown file (the issue is done, not re-queued).
#   4. Dry-run -> no cooldown file (no mutating side effects).
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

# Fake systemctl: inactive + MainPID 0 so worker_is_live returns false.
cat >"$fake/systemctl" <<'FAKE_SYSCTL'
#!/usr/bin/env bash
shift  # --user
case "$1" in
  is-active) echo inactive; exit 0 ;;
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

# Fake gh: configurable issue state + branch existence + PR count.
# Args to write_gh: state_json branch_delete_rc pr_count
write_gh() {
    local state_json="$1" branch_delete_rc="$2" pr_count="$3"
    mkdir -p "$fake/gh-bin"
    cat >"$fake/gh-bin/gh" <<FAKE_GH
#!/usr/bin/env bash
case "\$1" in
  api)
    path="\${2:-}"
    if [[ "\$path" == */issues/* ]]; then
      printf '%s\n' '$state_json'
      exit 0
    fi
    if [[ "\$path" == */pulls* ]]; then
      if [[ $pr_count -gt 0 ]]; then printf '[{"number":1}]\n'; else printf '[]\n'; fi
      exit 0
    fi
    if [[ "\$path" == */git/refs/heads/* ]]; then
      if [[ "\$*" == *-X*DELETE* ]]; then exit $branch_delete_rc; fi
      # ref exists check: exit 0 = exists
      exit 0
    fi
    exit 1
    ;;
  issue) case "\$2" in edit|comment) exit 0 ;; *) exit 1 ;; esac ;;
  *) exit 1 ;;
esac
FAKE_GH
    chmod +x "$fake/gh-bin/gh"
}

state_dir="$fake/state"
mkdir -p "$state_dir/attempts"
issues_dir="$fake/issues"
mkdir -p "$issues_dir"
export PI_PACKET_STATE="$state_dir"
export PI_ISSUES_DIR="$issues_dir"

# --- Test 1: OPEN + branch deleted -> cooldown written ----------------------
: >"$triage"
printf 'pkt\n' >"$issues_dir/fleet-ops-2133.in"
write_gh '{"state":"OPEN","labels":[{"name":"agent-in-progress"}]}' 0 0
set +e
out="$(PATH="$fake/gh-bin:$PATH" SYSTEMCTL="$fake/systemctl" TRIAGE_FILE="$triage" \
    "$bin" fleet-ops-2133 2>&1)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "OPEN reap must exit 0, got $rc ($out)"
cooldown="$state_dir/attempts/pi-issue-fleet-ops-2133.cooldown"
[[ -f "$cooldown" ]] || fail "cooldown file must exist after OPEN branch-deleted reap"
ts=$(cat "$cooldown")
[[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || fail "cooldown file must contain UTC ISO8601 timestamp, got: $ts"
grep -q 'RECLAIM-COOLDOWN-SET' "$triage" || fail "triage missing RECLAIM-COOLDOWN-SET: $(cat "$triage")"
ok "OPEN + branch deleted -> cooldown marker written with fresh timestamp"

# --- Test 2: OPEN + branch delete FAILS -> no cooldown ----------------------
: >"$triage"
rm -f "$cooldown"
write_gh '{"state":"OPEN","labels":[{"name":"agent-in-progress"}]}' 1 0
set +e
out="$(PATH="$fake/gh-bin:$PATH" SYSTEMCTL="$fake/systemctl" TRIAGE_FILE="$triage" \
    "$bin" fleet-ops-2133 2>&1)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "OPEN reap with branch-delete-fail must exit 0, got $rc ($out)"
[[ ! -f "$cooldown" ]] || fail "cooldown must NOT be written when branch delete failed (claim not released)"
grep -q 'RECLAIM-COOLDOWN-SET' "$triage" && fail "triage must NOT have RECLAIM-COOLDOWN-SET when branch delete failed"
ok "OPEN + branch delete failed -> no cooldown (claim not released)"

# --- Test 3: CLOSED issue -> no cooldown ------------------------------------
: >"$triage"
rm -f "$cooldown"
write_gh '{"state":"CLOSED","labels":[]}' 0 0
set +e
out="$(PATH="$fake/gh-bin:$PATH" SYSTEMCTL="$fake/systemctl" TRIAGE_FILE="$triage" \
    "$bin" fleet-ops-2133 2>&1)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "CLOSED reap must exit 0, got $rc ($out)"
[[ ! -f "$cooldown" ]] || fail "cooldown must NOT be written for CLOSED issue (not re-queued)"
grep -q 'RECLAIM-COOLDOWN-SET' "$triage" && fail "triage must NOT have RECLAIM-COOLDOWN-SET for CLOSED issue"
ok "CLOSED issue -> no cooldown (issue is done, not re-queued)"

# --- Test 4: dry-run -> no cooldown -----------------------------------------
: >"$triage"
rm -f "$cooldown"
write_gh '{"state":"OPEN","labels":[{"name":"agent-in-progress"}]}' 0 0
set +e
out="$(PATH="$fake/gh-bin:$PATH" SYSTEMCTL="$fake/systemctl" TRIAGE_FILE="$triage" \
    "$bin" --dry-run fleet-ops-2133 2>&1)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "dry-run must exit 0, got $rc ($out)"
[[ ! -f "$cooldown" ]] || fail "dry-run must NOT write cooldown marker"
grep -q 'RECLAIM-COOLDOWN-SET' "$triage" && fail "dry-run must NOT write RECLAIM-COOLDOWN-SET"
ok "dry-run -> no cooldown (no mutating side effects)"

echo
echo "ALL OK: pi-issue-failed-reap reclaim cooldown (fleet-ops#2133)"
