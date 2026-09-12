#!/usr/bin/env bash
# tests/pi-issue-failed-reap.test.sh
#
# Proves the reaper does not release a claim while the worker is still live.
# Uses --dry-run plus a fake systemctl; never talks to GitHub.
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

write_fake() {
    local active="$1" pid="$2" sub="${3:-running}"
    cat >"$fake/systemctl" <<FAKE
#!/usr/bin/env bash
shift  # --user
case "\$1" in
  is-active) echo ${active}; exit 0 ;;
  stop)
    # Reaper now cancels the pending restart ladder before archiving packets
    # (fleet-ops#638 follow-up, senior auditor 2026-08-27). Record the call
    # for the regression assertions and report success.
    echo stopped >>"\${FAKE_SYSTEMCTL_LOG:-/dev/null}"
    exit 0
    ;;
  reset-failed)
    echo reset-failed >>"\${FAKE_SYSTEMCTL_LOG:-/dev/null}"
    exit 0
    ;;
  show)
    # systemctl --user show -p ActiveState --value UNIT
    # systemctl --user show -p MainPID --value UNIT
    prop=""
    while [[ \$# -gt 0 ]]; do
      case "\$1" in
        -p) prop="\$2"; shift 2 ;;
        --value) shift ;;
        *) shift ;;
      esac
    done
    case "\$prop" in
      ActiveState) echo ${active} ;;
      MainPID) echo ${pid} ;;
      SubState) echo ${sub} ;;
      *) echo "" ;;
    esac
    exit 0
    ;;
  *) echo "unexpected: \$*" >&2; exit 1 ;;
esac
FAKE
    chmod +x "$fake/systemctl"
}

# Live worker (activating + nonzero MainPID): must skip before any gh call.
write_fake activating 4242
set +e
out="$(SYSTEMCTL="$fake/systemctl" TRIAGE_FILE="$triage" \
    "$bin" --dry-run fleet-ops-20 2>&1)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "live worker must exit 0, got $rc ($out)"
printf '%s\n' "$out" | grep -qi 'still live' || fail "must say still live, got: $out"
grep -q 'CLAIM-REAP-SKIP-LIVE' "$triage" || fail "triage missing CLAIM-REAP-SKIP-LIVE: $(cat "$triage")"
# Must not have reached GitHub (CLAIM-REAP-STARTED is after the live check).
grep -q 'CLAIM-REAP-STARTED' "$triage" && fail "must not start reap while live: $(cat "$triage")"
ok "reaper skips while worker MainPID is live"

# Inactive + MainPID 0: live-check passes; --dry-run then hits gh (may fail
# offline — that's OK). We only assert it did NOT skip-live.
: >"$triage"
write_fake inactive 0
set +e
out="$(SYSTEMCTL="$fake/systemctl" TRIAGE_FILE="$triage" \
    "$bin" --dry-run fleet-ops-20 2>&1)"
rc=$?
set -e
grep -q 'CLAIM-REAP-SKIP-LIVE' "$triage" && fail "inactive worker must not skip-live: $(cat "$triage")"
ok "reaper does not skip-live when worker is inactive (rc=$rc)"

# Regression (fleet-ops#109, 2026-08-26): activating + MainPID=0 + SubState=
# auto-restart is NOT a live worker — the process has exited and only systemd's
# restart timer is pending. The old code treated any `activating` as live and
# refused to release the claim, so a worker that exited non-zero thrashed
# forever (StartLimitIntervalSec resets hourly). Must NOT skip-live here.
: >"$triage"
write_fake activating 0 auto-restart
set +e
out="$(SYSTEMCTL="$fake/systemctl" TRIAGE_FILE="$triage" \
    "$bin" --dry-run fleet-ops-20 2>&1)"
rc=$?
set -e
grep -q 'CLAIM-REAP-SKIP-LIVE' "$triage" && fail "auto-restart (MainPID=0) must not skip-live: $(cat "$triage")"
ok "reaper does not skip-live when worker is in auto-restart (MainPID=0) — the fleet-ops#109 regression (rc=$rc)"

# fleet-ops#381: after claim release, truncate the per-issue tried-seats file
# so the next claim starts seat rotation fresh. Live skip must leave it intact.
state="$fake/state"
mkdir -p "$state/attempts"
tried="$state/attempts/pi-issue-fleet-ops-381.tried-seats"
printf 'devin/swe-1-7\ncursor/composer-2.5\n' >"$tried"
: >"$triage"
write_fake activating 4242
set +e
out="$(SYSTEMCTL="$fake/systemctl" TRIAGE_FILE="$triage" PI_PACKET_STATE="$state" \
    "$bin" --dry-run fleet-ops-381 2>&1)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "live skip must exit 0, got $rc ($out)"
[[ -s "$tried" ]] || fail "live skip must leave tried-seats intact"
grep -q 'devin/swe-1-7' "$tried" || fail "live skip must not truncate tried-seats"
ok "live skip leaves tried-seats intact"

gh_bin="$fake/gh-bin"
mkdir -p "$gh_bin"
cat >"$gh_bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
# The reaper loads issue state + open PRs via REST `gh api` (fleet-ops#1001),
# not GraphQL `gh issue view` / `gh pr list`.
case "$1" in
  api)
    path="${2:-}"
    if [[ "$path" == */issues/* ]]; then
      printf '%s\n' '{"state":"open","labels":[{"name":"agent-in-progress"}]}'
      exit 0
    fi
    if [[ "$path" == */pulls* ]]; then
      printf '%s\n' '[]'
      exit 0
    fi
    if [[ "$path" == */git/refs/heads/* ]]; then
      # Branch does not exist — skip delete, continue to label flip + reset.
      exit 1
    fi
    echo "unexpected gh api $*" >&2
    exit 1
    ;;
  issue)
    case "$2" in
      edit|comment) exit 0 ;;
      *) echo "unexpected gh issue $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
FAKE_GH
chmod +x "$gh_bin/gh"

: >"$triage"
write_fake inactive 0
# fleet-ops#1227: isolate the seat ledger. The reaper sources seat-lib and
# keeps tried-seats when seat_usable says the last seat is benched
# (TRIED-SEATS-KEPT). Point SEAT_LIB at the repo copy and
# PI_SEAT_HEALTH_LEDGER_DIR at an empty scratch ledger so a live VPS bench
# cannot leak into this recover case. Write last-seat so seat_usable is
# actually consulted (no ledger file fail-opens as usable → RESET).
printf 'cursor/composer-2.5\n' >"$state/attempts/pi-issue-fleet-ops-381.seat"
ledger_reset="$fake/ledger-reset"
mkdir -p "$ledger_reset"
set +e
out="$(PATH="$gh_bin:$PATH" SYSTEMCTL="$fake/systemctl" TRIAGE_FILE="$triage" \
    PI_PACKET_STATE="$state" \
    SEAT_LIB="$repo_root/lib/seat-lib.sh" \
    PI_SEAT_HEALTH_LEDGER_DIR="$ledger_reset" \
    PI_SEAT_LIB_CHECK_SYSTEMD=0 \
    "$bin" fleet-ops-381 2>&1)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "claim-release reap must exit 0, got $rc ($out)"
[[ -f "$tried" ]] || fail "tried-seats file must still exist after reap"
[[ ! -s "$tried" ]] || fail "tried-seats must be truncated after claim release, got: $(cat "$tried")"
grep -q 'TRIED-SEATS-RESET' "$triage" || fail "triage missing TRIED-SEATS-RESET: $(cat "$triage")"
grep -q 'TRIED-SEATS-KEPT' "$triage" && fail "empty ledger must not KEEP tried-seats: $(cat "$triage")"
ok "reaper truncates tried-seats after claim release (fleet-ops#381)"

# Inverse of the recover case (fleet-ops#516): last seat is benched in the
# isolated ledger, so the re-claim must keep tried-seats and pick a different
# seat. Own state + ledger dirs so this cannot poison the RESET case.
state_keep="$fake/state-keep"
mkdir -p "$state_keep/attempts"
tried_keep="$state_keep/attempts/pi-issue-fleet-ops-516.tried-seats"
printf 'devin/swe-1-7\ncursor/composer-2.5\n' >"$tried_keep"
printf 'cursor/composer-2.5\n' >"$state_keep/attempts/pi-issue-fleet-ops-516.seat"
ledger_keep="$fake/ledger-keep"
mkdir -p "$ledger_keep"
cat >"$ledger_keep/cursor__composer-2.5.json" <<'LEDGER'
{"health_class":"quota_bench","seat_dead":false,"observed_at":"2026-08-27T00:00:00Z","bench_until":"2099-01-01T00:00:00Z"}
LEDGER
: >"$triage"
write_fake inactive 0
set +e
out="$(PATH="$gh_bin:$PATH" SYSTEMCTL="$fake/systemctl" TRIAGE_FILE="$triage" \
    PI_PACKET_STATE="$state_keep" \
    SEAT_LIB="$repo_root/lib/seat-lib.sh" \
    PI_SEAT_HEALTH_LEDGER_DIR="$ledger_keep" \
    PI_SEAT_LIB_CHECK_SYSTEMD=0 \
    "$bin" fleet-ops-516 2>&1)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "benched-last-seat reap must exit 0, got $rc ($out)"
[[ -s "$tried_keep" ]] || fail "benched last-seat must keep tried-seats, file empty or missing"
grep -q 'cursor/composer-2.5' "$tried_keep" || fail "kept tried-seats lost last seat, got: $(cat "$tried_keep")"
grep -q 'devin/swe-1-7' "$tried_keep" || fail "kept tried-seats lost earlier seat, got: $(cat "$tried_keep")"
grep -q 'TRIED-SEATS-KEPT' "$triage" || fail "triage missing TRIED-SEATS-KEPT: $(cat "$triage")"
grep -q 'TRIED-SEATS-RESET' "$triage" && fail "benched last-seat must not RESET tried-seats: $(cat "$triage")"
ok "reaper keeps tried-seats when last seat is benched (fleet-ops#516)"

# fleet-ops#638 (auditor 2026-08-27T03:31Z): a stale .in packet at
# $PI_ISSUES_DIR/<instance>.in keeps pi-issue@<instance>.service on
# Restart=on-failure life support after a closed issue's PR is already
# merged. The reap must mv .in/.out/.err -> ARCHIVED-<instance>.<ext>-<ts>
# when it actually reaps a CLOSED issue, so the next unit fire is a no-op.
write_gh_fake() {
    local state_json="$1" branch_delete="$2"
    cat >"$gh_bin/gh" <<FAKE_GH
#!/usr/bin/env bash
case "\$1" in
  api)
    path="\${2:-}"
    if [[ "\$path" == */issues/* ]]; then
      printf '%s\n' '$state_json'
      exit 0
    fi
    if [[ "\$path" == */pulls* ]]; then
      printf '%s\n' '[]'
      exit 0
    fi
    if [[ "\$path" == */git/refs/heads/* ]]; then
      if [[ "\$*" == *-X*DELETE* ]]; then
        exit 0
      fi
      exit ${branch_delete}
    fi
    echo "unexpected gh api \$*" >&2
    exit 1
    ;;
  issue)
    case "\$2" in
      edit|comment) exit 0 ;;
      *) echo "unexpected gh issue \$*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected gh \$*" >&2; exit 1 ;;
esac
FAKE_GH
    chmod +x "$gh_bin/gh"
}

# --- Test A: live-skip must NOT archive (worker is still live) ---------------
state_638="$fake/state-638"
mkdir -p "$state_638/attempts"
issues_dir="$fake/issues-638"
mkdir -p "$issues_dir"
printf 'packet-body-638\n' >"$issues_dir/fleet-ops-638.in"
printf 'out-body-638\n' >"$issues_dir/fleet-ops-638.out"
printf 'err-body-638\n' >"$issues_dir/fleet-ops-638.err"
: >"$triage"
write_fake activating 4242
set +e
out="$(PATH="$gh_bin:$PATH" SYSTEMCTL="$fake/systemctl" TRIAGE_FILE="$triage" \
    PI_PACKET_STATE="$state_638" PI_ISSUES_DIR="$issues_dir" \
    "$bin" --dry-run fleet-ops-638 2>&1)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "live skip must exit 0, got $rc ($out)"
[[ -f "$issues_dir/fleet-ops-638.in" ]] || fail "live skip must not archive .in packet"
[[ -f "$issues_dir/fleet-ops-638.out" ]] || fail "live skip must not archive .out packet"
[[ -f "$issues_dir/fleet-ops-638.err" ]] || fail "live skip must not archive .err packet"
shopt -s nullglob
archived_live=("$issues_dir"/ARCHIVED-*)
shopt -u nullglob
[[ "${#archived_live[@]}" -eq 0 ]] || fail "live skip must not create ARCHIVED- files, got: ${archived_live[*]}"
grep -q 'PACKETS-ARCHIVED' "$triage" && fail "live skip must not write PACKETS-ARCHIVED: $(cat "$triage")"
ok "live skip leaves packets intact (no premature archive)"

# --- Test B: CLOSED reap must archive .in/.out/.err (the 638 root cause) -----
state_638b="$fake/state-638b"
mkdir -p "$state_638b/attempts"
issues_dir_b="$fake/issues-638b"
mkdir -p "$issues_dir_b"
printf 'packet-body-638b\n' >"$issues_dir_b/fleet-ops-638.in"
printf 'out-body-638b\n' >"$issues_dir_b/fleet-ops-638.out"
printf 'err-body-638b\n' >"$issues_dir_b/fleet-ops-638.err"
: >"$triage"
write_gh_fake '{"state":"CLOSED","labels":[]}' 1   # branch ref exists, DELETE ok
write_fake inactive 0
set +e
out="$(PATH="$gh_bin:$PATH" SYSTEMCTL="$fake/systemctl" TRIAGE_FILE="$triage" \
    PI_PACKET_STATE="$state_638b" PI_ISSUES_DIR="$issues_dir_b" \
    "$bin" fleet-ops-638 2>&1)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "CLOSED reap must exit 0, got $rc ($out)"
[[ ! -f "$issues_dir_b/fleet-ops-638.in" ]] || fail "CLOSED reap must archive .in (still present)"
[[ ! -f "$issues_dir_b/fleet-ops-638.out" ]] || fail "CLOSED reap must archive .out (still present)"
[[ ! -f "$issues_dir_b/fleet-ops-638.err" ]] || fail "CLOSED reap must archive .err (still present)"
shopt -s nullglob
archived_b=("$issues_dir_b"/ARCHIVED-fleet-ops-638.in-*)
archived_out=("$issues_dir_b"/ARCHIVED-fleet-ops-638.out-*)
archived_err=("$issues_dir_b"/ARCHIVED-fleet-ops-638.err-*)
shopt -u nullglob
[[ "${#archived_b[@]}" -eq 1 ]] || fail "expected one ARCHIVED .in, got: ${archived_b[*]}"
[[ "${#archived_out[@]}" -eq 1 ]] || fail "expected one ARCHIVED .out, got: ${archived_out[*]}"
[[ "${#archived_err[@]}" -eq 1 ]] || fail "expected one ARCHIVED .err, got: ${archived_err[*]}"
# Same timestamp across the three (one stamp per invocation).
[[ "${archived_b[0]##*-}" == "${archived_out[0]##*-}" ]] || fail "stamp mismatch between .in and .out archive"
[[ "${archived_out[0]##*-}" == "${archived_err[0]##*-}" ]] || fail "stamp mismatch between .out and .err archive"
grep -q 'PACKETS-ARCHIVED' "$triage" || fail "triage missing PACKETS-ARCHIVED: $(cat "$triage")"
grep -q 'CLAIM-CLOSED-CLEANUP' "$triage" || fail "triage missing CLAIM-CLOSED-CLEANUP: $(cat "$triage")"
# Original content preserved (mv, not delete).
grep -q 'packet-body-638b' "${archived_b[0]}" || fail "archived .in must preserve content"
ok "CLOSED reap archives .in/.out/.err to ARCHIVED-<instance>.<ext>-<ts> (fleet-ops#638)"

# --- Test C: branch_deleted on OPEN issue must also archive ------------------
state_638c="$fake/state-638c"
mkdir -p "$state_638c/attempts"
issues_dir_c="$fake/issues-638c"
mkdir -p "$issues_dir_c"
printf 'open-packet\n' >"$issues_dir_c/fleet-ops-639.in"
printf 'open-out\n' >"$issues_dir_c/fleet-ops-639.out"
: >"$triage"
write_gh_fake '{"state":"OPEN","labels":[{"name":"agent-in-progress"}]}' 0  # branch ref exists, DELETE ok
write_fake inactive 0
set +e
out="$(PATH="$gh_bin:$PATH" SYSTEMCTL="$fake/systemctl" TRIAGE_FILE="$triage" \
    PI_PACKET_STATE="$state_638c" PI_ISSUES_DIR="$issues_dir_c" \
    "$bin" fleet-ops-639 2>&1)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "OPEN branch_deleted reap must exit 0, got $rc ($out)"
[[ ! -f "$issues_dir_c/fleet-ops-639.in" ]] || fail "branch_deleted reap must archive .in (still present)"
[[ ! -f "$issues_dir_c/fleet-ops-639.out" ]] || fail "branch_deleted reap must archive .out (still present)"
shopt -s nullglob
archived_c=("$issues_dir_c"/ARCHIVED-*)
shopt -u nullglob
[[ "${#archived_c[@]}" -ge 1 ]] || fail "branch_deleted reap must create ARCHIVED- files, got: ${archived_c[*]}"
grep -q 'PACKETS-ARCHIVED' "$triage" || fail "triage missing PACKETS-ARCHIVED: $(cat "$triage")"
ok "branch_deleted reap archives packets (OPEN issue re-claim)"

# --- Test C2: a real (non-dry) reap must CANCEL the unit's restart ladder
# before archiving (fleet-ops#638 follow-up, senior auditor 2026-08-27). The
# reaper runs on OnFailure= at the FIRST failure; systemd's Restart=on-failure
# ladder is still armed, and the unit got 3 more chances after OnFailure fired.
# If the .in is archived while the ladder is pending, the next ladder restart
# fails 208/STDIN (missing StandardInput=file) -> another OnFailure -> another
# STOP-REASON -> another auditor summon per ladder step (live: pi-issue@
# fleet-ops-938 2026-08-27 07:16Z, archived .in at 07:16:49Z, restart 208/STDIN
# at 07:20:44Z). The reaper must stop + reset-failed the unit so the ladder is
# cancelled BEFORE the packets move.
state_638c2="$fake/state-638c2"
mkdir -p "$state_638c2/attempts"
issues_dir_c2="$fake/issues-638c2"
mkdir -p "$issues_dir_c2"
sysctl_log="$fake/systemctl-ops.log"
printf 'open-packet-c2\n' >"$issues_dir_c2/fleet-ops-641.in"
printf 'open-out-c2\n' >"$issues_dir_c2/fleet-ops-641.out"
: >"$triage"
write_gh_fake '{"state":"OPEN","labels":[{"name":"agent-in-progress"}]}' 0  # branch exists, DELETE ok
write_fake inactive 0
set +e
out="$(PATH="$gh_bin:$PATH" SYSTEMCTL="$fake/systemctl" TRIAGE_FILE="$triage" \
    PI_PACKET_STATE="$state_638c2" PI_ISSUES_DIR="$issues_dir_c2" \
    FAKE_SYSTEMCTL_LOG="$sysctl_log" "$bin" fleet-ops-641 2>&1)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "ladder-cancel reap must exit 0, got $rc ($out)"
grep -q 'stopped' "$sysctl_log" || fail "reap must stop the unit before archiving (ladder cancel), ops log: $(cat "$sysctl_log" 2>/dev/null)"
grep -q 'reset-failed' "$sysctl_log" || fail "reap must reset-failed the unit before archiving, ops log: $(cat "$sysctl_log" 2>/dev/null)"
[[ ! -f "$issues_dir_c2/fleet-ops-641.in" ]] || fail "ladder-cancel reap must archive .in (still present)"
grep -q 'PACKETS-ARCHIVED' "$triage" || fail "triage missing PACKETS-ARCHIVED: $(cat "$triage")"
ok "reap stops + reset-failed the unit before archiving (cancels 208/STDIN ladder re-fire)"

# --- Test D: dry-run must NOT archive (no mutating gh, no mv) ---------------
state_638d="$fake/state-638d"
mkdir -p "$state_638d/attempts"
issues_dir_d="$fake/issues-638d"
mkdir -p "$issues_dir_d"
printf 'dry-packet\n' >"$issues_dir_d/fleet-ops-640.in"
: >"$triage"
write_gh_fake '{"state":"CLOSED","labels":[]}' 1
write_fake inactive 0
set +e
out="$(PATH="$gh_bin:$PATH" SYSTEMCTL="$fake/systemctl" TRIAGE_FILE="$triage" \
    PI_PACKET_STATE="$state_638d" PI_ISSUES_DIR="$issues_dir_d" \
    "$bin" --dry-run fleet-ops-640 2>&1)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "dry-run must exit 0, got $rc ($out)"
[[ -f "$issues_dir_d/fleet-ops-640.in" ]] || fail "dry-run must NOT archive .in"
shopt -s nullglob
archived_d=("$issues_dir_d"/ARCHIVED-*)
shopt -u nullglob
[[ "${#archived_d[@]}" -eq 0 ]] || fail "dry-run must NOT create ARCHIVED- files, got: ${archived_d[*]}"
grep -q 'PACKETS-ARCHIVED' "$triage" && fail "dry-run must NOT write PACKETS-ARCHIVED: $(cat "$triage")"
ok "dry-run leaves packets intact (archive is not a side effect of --dry-run)"

# --- Test E: open-PR guard must query GitHub with owner:branch ---------------
# 2026-09-05 08:32-08:38Z: the reaper deleted claim/issue-3268, -3254 and
# -3445 while each had an OPEN PR (#3528, #3538 green-ready, #3539), closing
# the PRs and destroying finished work. Root cause: the REST `head=` filter
# was built as `${repo_slug#*/}` (the REPO name, "fleet-ops:claim/...") but
# GitHub's pulls API expects `owner:branch` ("Nishfleet:claim/..."). A wrong
# owner matches nothing, the guard sees 0 open PRs and deletes the branch.
# Live proof: `gh api repos/Nishfleet/0509/pulls?state=open&head=0509:claim/issue-1140`
# -> 0, `...head=Nishfleet:claim/issue-1140` -> 1 (PR #1509).
state_e="$fake/state-e"
mkdir -p "$state_e/attempts"
ledger_e="$fake/ledger-e"
mkdir -p "$ledger_e"
deleted_marker_e="$fake/deleted-claim-issue-3254"
rm -f "$deleted_marker_e"
cat >"$gh_bin/gh" <<FAKE_GH
#!/usr/bin/env bash
case "\$1" in
  api)
    path="\${2:-}"
    if [[ "\$path" == */issues/* ]]; then
      printf '%s\n' '{"state":"open","labels":[{"name":"agent-ready"}]}'
      exit 0
    fi
    if [[ "\$path" == */pulls* ]]; then
      # Only the owner-qualified head filter finds the open PR, exactly as
      # GitHub behaves; a repo-name-qualified filter matches nothing.
      if [[ "\$path" == *"head=Nishfleet:claim/issue-3254"* ]]; then
        printf '%s\n' '[{"number":3538}]'
      else
        printf '%s\n' '[]'
      fi
      exit 0
    fi
    if [[ "\$path" == */git/refs/heads/* ]]; then
      if [[ "\$*" == *-X*DELETE* ]]; then
        : >"$deleted_marker_e"
        exit 0
      fi
      exit 0
    fi
    echo "unexpected gh api \$*" >&2
    exit 1
    ;;
  issue)
    case "\$2" in
      edit|comment) exit 0 ;;
      *) echo "unexpected gh issue \$*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected gh \$*" >&2; exit 1 ;;
esac
FAKE_GH
chmod +x "$gh_bin/gh"
: >"$triage"
write_fake inactive 0
set +e
out="$(PATH="$gh_bin:$PATH" SYSTEMCTL="$fake/systemctl" TRIAGE_FILE="$triage" \
    PI_PACKET_STATE="$state_e" \
    SEAT_LIB="$repo_root/lib/seat-lib.sh" \
    PI_SEAT_HEALTH_LEDGER_DIR="$ledger_e" \
    PI_SEAT_LIB_CHECK_SYSTEMD=0 \
    "$bin" fleet-ops-3254 2>&1)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "open-PR guard reap must exit 0, got $rc ($out)"
[[ ! -f "$deleted_marker_e" ]] || fail "reaper deleted claim/issue-3254 although PR #3538 is open on it (head filter must be owner:branch): $out"
grep -q 'CLAIM-REAP-NEEDED' "$triage" || fail "triage missing CLAIM-REAP-NEEDED for the open-PR hold: $(cat "$triage")"
grep -q 'open_pr_count=1' "$triage" || fail "open-PR hold must report open_pr_count=1: $(cat "$triage")"
ok "reaper holds the claim branch when an open PR exists (owner:branch head filter)"

# --- Test F: agent-blocked guard (fleet-ops#3763) ---------------------------
# A dead worker's claim release must NOT re-add agent-ready when the issue is
# already agent-blocked (a worker posted blocked-on:, or intake escalated via
# max-reclaims/claim-loop). Re-adding agent-ready re-arms the spawn churn the
# block was meant to stop. The reaper must clear agent-in-progress ONLY and
# leave agent-blocked for blocked-reconcile to resolve.
state_f="$fake/state-f"
mkdir -p "$state_f/attempts"
ledger_f="$fake/ledger-f"
mkdir -p "$ledger_f"
edit_log_f="$fake/edit-log-f"
rm -f "$edit_log_f"
cat >"$gh_bin/gh" <<FAKE_GH
#!/usr/bin/env bash
case "\$1" in
  api)
    path="\${2:-}"
    if [[ "\$path" == */issues/* ]]; then
      printf '%s\n' '{"state":"open","labels":[{"name":"agent-in-progress"},{"name":"agent-blocked"},{"name":"needs-orchestrator"}]}'
      exit 0
    fi
    if [[ "\$path" == */pulls* ]]; then
      printf '%s\n' '[]'
      exit 0
    fi
    if [[ "\$path" == */git/refs/heads/* ]]; then
      if [[ "\$*" == *-X*DELETE* ]]; then
        exit 0
      fi
      exit 0
    fi
    echo "unexpected gh api \$*" >&2
    exit 1
    ;;
  issue)
    case "\$2" in
      edit)
        # Record the full arg list so the test can assert which labels were
        # added/removed.
        printf '%s\n' "\$*" >>"$edit_log_f"
        exit 0
        ;;
      comment) exit 0 ;;
      *) echo "unexpected gh issue \$*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected gh \$*" >&2; exit 1 ;;
esac
FAKE_GH
chmod +x "$gh_bin/gh"
: >"$triage"
write_fake inactive 0
set +e
out="$(PATH="$gh_bin:$PATH" SYSTEMCTL="$fake/systemctl" TRIAGE_FILE="$triage" \
    PI_PACKET_STATE="$state_f" \
    SEAT_LIB="$repo_root/lib/seat-lib.sh" \
    PI_SEAT_HEALTH_LEDGER_DIR="$ledger_f" \
    PI_SEAT_LIB_CHECK_SYSTEMD=0 \
    "$bin" fleet-ops-3763 2>&1)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "agent-blocked reap must exit 0, got $rc ($out)"
# At least one `issue edit` call (the label flip).
grep -q 'issue edit' "$edit_log_f" \
    || fail "reaper must call gh issue edit at least once, log: $(cat "$edit_log_f" 2>/dev/null)"
# The edit must NOT add agent-ready.
grep -q -- '--add-label agent-ready' "$edit_log_f" \
    && fail "reaper re-added agent-ready on an agent-blocked issue (spawn-churn loop): edit log: $(cat "$edit_log_f")" \
    || true
# The edit must remove agent-in-progress.
grep -q -- '--remove-label agent-in-progress' "$edit_log_f" \
    || fail "reaper did not clear agent-in-progress on the agent-blocked issue: edit log: $(cat "$edit_log_f")"
ok "reaper clears agent-in-progress only on an agent-blocked issue (no agent-ready re-queue, fleet-ops#3763)"

# --- Test F2: inverse — an unblocked OPEN issue still gets agent-ready --------
# The guard must not regress the normal reclaim path: an OPEN issue with only
# agent-in-progress (no agent-blocked) must still flip to agent-ready.
state_f2="$fake/state-f2"
mkdir -p "$state_f2/attempts"
ledger_f2="$fake/ledger-f2"
mkdir -p "$ledger_f2"
edit_log_f2="$fake/edit-log-f2"
rm -f "$edit_log_f2"
cat >"$gh_bin/gh" <<FAKE_GH
#!/usr/bin/env bash
case "\$1" in
  api)
    path="\${2:-}"
    if [[ "\$path" == */issues/* ]]; then
      printf '%s\n' '{"state":"open","labels":[{"name":"agent-in-progress"}]}'
      exit 0
    fi
    if [[ "\$path" == */pulls* ]]; then
      printf '%s\n' '[]'
      exit 0
    fi
    if [[ "\$path" == */git/refs/heads/* ]]; then
      if [[ "\$*" == *-X*DELETE* ]]; then
        exit 0
      fi
      exit 0
    fi
    echo "unexpected gh api \$*" >&2
    exit 1
    ;;
  issue)
    case "\$2" in
      edit)
        printf '%s\n' "\$*" >>"$edit_log_f2"
        exit 0
        ;;
      comment) exit 0 ;;
      *) echo "unexpected gh issue \$*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected gh \$*" >&2; exit 1 ;;
esac
FAKE_GH
chmod +x "$gh_bin/gh"
: >"$triage"
write_fake inactive 0
set +e
out="$(PATH="$gh_bin:$PATH" SYSTEMCTL="$fake/systemctl" TRIAGE_FILE="$triage" \
    PI_PACKET_STATE="$state_f2" \
    SEAT_LIB="$repo_root/lib/seat-lib.sh" \
    PI_SEAT_HEALTH_LEDGER_DIR="$ledger_f2" \
    PI_SEAT_LIB_CHECK_SYSTEMD=0 \
    "$bin" fleet-ops-3764 2>&1)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "normal reap must exit 0, got $rc ($out)"
grep -q -- '--add-label agent-ready' "$edit_log_f2" \
    || fail "normal reap must re-add agent-ready on an unblocked issue: edit log: $(cat "$edit_log_f2")"
grep -q -- '--remove-label agent-in-progress' "$edit_log_f2" \
    || fail "normal reap must remove agent-in-progress: edit log: $(cat "$edit_log_f2")"
ok "reaper still flips agent-in-progress -> agent-ready on an unblocked issue (no guard regression)"

# --- Test G: App-GraphQL write failure retries via App REST (fleet-ops#5781) --
# Live case 2026-09-12T03:06Z on #5734: installation 156789042's graphql
# bucket was exhausted, so `gh issue edit` / `gh issue comment` failed and the
# claim stayed inconsistent with only WARN-level lines. The reaper must retry
# each failed write once through the REST endpoint on the SAME App credential
# (the core bucket is independent of graphql; writes never drop to the human
# identity — fleet-ops#3445). Fake gh: every GraphQL write fails, REST writes
# succeed and are logged.
state_g="$fake/state-g"
mkdir -p "$state_g/attempts"
ledger_g="$fake/ledger-g"
mkdir -p "$ledger_g"
write_log_g="$fake/write-log-g"
rm -f "$write_log_g"
cat >"$gh_bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
case "$1" in
  api)
    path="${2:-}"
    if [[ "$*" == *"-X PUT"* ]]; then
      # Label-set write: body arrives on stdin via --input -.
      printf 'PUT %s body=%s\n' "$path" "$(cat)" >>"${GH_WRITE_LOG:-/dev/null}"
      exit 0
    fi
    if [[ "$*" == *"-X POST"* ]]; then
      printf 'POST %s %s\n' "$path" "$*" >>"${GH_WRITE_LOG:-/dev/null}"
      exit 0
    fi
    if [[ "$*" == *"-X DELETE"* ]]; then
      exit 0
    fi
    if [[ "$path" == */issues/* ]]; then
      printf '%s\n' '{"state":"open","labels":[{"name":"agent-in-progress"}]}'
      exit 0
    fi
    if [[ "$path" == */pulls* ]]; then
      printf '%s\n' '[]'
      exit 0
    fi
    if [[ "$path" == */git/refs/heads/* ]]; then
      exit 0
    fi
    echo "unexpected gh api $*" >&2
    exit 1
    ;;
  issue)
    case "$2" in
      # The installation's graphql bucket is dead.
      edit|comment)
        echo "GraphQL: API rate limit already exceeded for installation ID 156789042" >&2
        exit 1
        ;;
      *) echo "unexpected gh issue $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
FAKE_GH
chmod +x "$gh_bin/gh"
: >"$triage"
write_fake inactive 0
set +e
out="$(PATH="$gh_bin:$PATH" SYSTEMCTL="$fake/systemctl" TRIAGE_FILE="$triage" \
    PI_PACKET_STATE="$state_g" \
    SEAT_LIB="$repo_root/lib/seat-lib.sh" \
    PI_SEAT_HEALTH_LEDGER_DIR="$ledger_g" \
    PI_SEAT_LIB_CHECK_SYSTEMD=0 \
    GH_WRITE_LOG="$write_log_g" \
    "$bin" fleet-ops-7001 2>&1)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "REST-retry reap must exit 0, got $rc ($out)"
grep -q 'PUT repos/Nishfleet/fleet-ops/issues/7001/labels' "$write_log_g" \
    || fail "failed label flip must retry via REST PUT on the labels endpoint, write log: $(cat "$write_log_g" 2>/dev/null)"
grep -q 'body={"labels":\["agent-ready"\]}' "$write_log_g" \
    || fail "REST retry must PUT the desired label set (agent-in-progress out, agent-ready in), got: $(cat "$write_log_g")"
grep -q 'POST repos/Nishfleet/fleet-ops/issues/7001/comments' "$write_log_g" \
    || fail "failed comment must retry via REST POST on the comments endpoint, write log: $(cat "$write_log_g")"
printf '%s' "$out" | grep -q 'via App REST retry' \
    || fail "log must record the REST-retry path, got: $out"
grep -q 'label_flipped=yes comment_posted=yes' "$triage" \
    || fail "CLAIM-RELEASED must report both writes succeeded via retry: $(cat "$triage")"
grep -q 'CLAIM-REAP-LABEL-FAIL\|CLAIM-REAP-COMMENT-FAIL' "$triage" \
    && fail "a successful REST retry must not emit the FAIL tag: $(cat "$triage")" || true
ok "failed GraphQL writes retry once via App REST and the reap lands (fleet-ops#5781)"

# --- Test H: double write failure emits one LOUD triage line ------------------
# When BOTH the GraphQL write and the App-REST retry fail, the issue is left
# inconsistent — that is a named fault the judges must see, not a WARN buried
# in a unit journal. The reaper must emit one LOUD line per failed write.
state_h="$fake/state-h"
mkdir -p "$state_h/attempts"
ledger_h="$fake/ledger-h"
mkdir -p "$ledger_h"
cat >"$gh_bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
case "$1" in
  api)
    path="${2:-}"
    if [[ "$*" == *"-X PUT"* || "$*" == *"-X POST"* ]]; then
      # App REST bucket is dead too (e.g. 5xx) — retry fails.
      echo "HTTP 502: upstream connect error" >&2
      exit 1
    fi
    if [[ "$*" == *"-X DELETE"* ]]; then
      exit 0
    fi
    if [[ "$path" == */issues/* ]]; then
      printf '%s\n' '{"state":"open","labels":[{"name":"agent-in-progress"}]}'
      exit 0
    fi
    if [[ "$path" == */pulls* ]]; then
      printf '%s\n' '[]'
      exit 0
    fi
    if [[ "$path" == */git/refs/heads/* ]]; then
      exit 0
    fi
    echo "unexpected gh api $*" >&2
    exit 1
    ;;
  issue)
    case "$2" in
      edit|comment)
        echo "GraphQL: API rate limit already exceeded for installation ID 156789042" >&2
        exit 1
        ;;
      *) echo "unexpected gh issue $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
FAKE_GH
chmod +x "$gh_bin/gh"
: >"$triage"
write_fake inactive 0
set +e
out="$(PATH="$gh_bin:$PATH" SYSTEMCTL="$fake/systemctl" TRIAGE_FILE="$triage" \
    PI_PACKET_STATE="$state_h" \
    SEAT_LIB="$repo_root/lib/seat-lib.sh" \
    PI_SEAT_HEALTH_LEDGER_DIR="$ledger_h" \
    PI_SEAT_LIB_CHECK_SYSTEMD=0 \
    "$bin" fleet-ops-7002 2>&1)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "double-fail reap still exits 0 (partial cleanup is not a hard error), got $rc ($out)"
printf '%s' "$out" | grep -q 'LOUD \[CLAIM-REAP-LABEL-FAIL\]' \
    || fail "double label failure must emit one LOUD journal line, got: $out"
printf '%s' "$out" | grep -q 'LOUD \[CLAIM-REAP-COMMENT-FAIL\]' \
    || fail "double comment failure must emit one LOUD journal line, got: $out"
grep -q 'CLAIM-REAP-LABEL-FAIL' "$triage" \
    || fail "triage must carry CLAIM-REAP-LABEL-FAIL for the judges: $(cat "$triage")"
grep -q 'CLAIM-REAP-COMMENT-FAIL' "$triage" \
    || fail "triage must carry CLAIM-REAP-COMMENT-FAIL for the judges: $(cat "$triage")"
grep -q 'label_flipped=no comment_posted=no' "$triage" \
    || fail "CLAIM-RELEASED must record both writes failed: $(cat "$triage")"
ok "double write failure emits LOUD journal + triage lines instead of a silent WARN (fleet-ops#5781)"

# fleet-ops#5092: park-resurrection regression — reaper fail-closed on
# awaiting-runtime-gate, pi-issue-run exits 0 on a parked issue. Hosted here
# because the worker App token has no Workflows scope to list it in ci.yml.
bash "$here/pi-issue-park-resurrection.test.sh"
