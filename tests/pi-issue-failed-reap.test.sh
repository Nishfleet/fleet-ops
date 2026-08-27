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
case "$1" in
  issue)
    case "$2" in
      view)
        printf '%s\n' '{"state":"OPEN","labels":[{"name":"agent-in-progress"}]}'
        exit 0
        ;;
      edit|comment)
        exit 0
        ;;
      *) echo "unexpected gh issue $*" >&2; exit 1 ;;
    esac
    ;;
  pr)
    echo 0
    exit 0
    ;;
  api)
    # Branch does not exist — skip delete, continue to label flip + reset.
    exit 1
    ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
FAKE_GH
chmod +x "$gh_bin/gh"

: >"$triage"
write_fake inactive 0
set +e
out="$(PATH="$gh_bin:$PATH" SYSTEMCTL="$fake/systemctl" TRIAGE_FILE="$triage" \
    PI_PACKET_STATE="$state" "$bin" fleet-ops-381 2>&1)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "claim-release reap must exit 0, got $rc ($out)"
[[ -f "$tried" ]] || fail "tried-seats file must still exist after reap"
[[ ! -s "$tried" ]] || fail "tried-seats must be truncated after claim release, got: $(cat "$tried")"
grep -q 'TRIED-SEATS-RESET' "$triage" || fail "triage missing TRIED-SEATS-RESET: $(cat "$triage")"
ok "reaper truncates tried-seats after claim release (fleet-ops#381)"

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
  issue)
    case "\$2" in
      view)
        printf '%s\n' '$state_json'
        exit 0
        ;;
      edit|comment)
        exit 0
        ;;
      *) echo "unexpected gh issue \$*" >&2; exit 1 ;;
    esac
    ;;
  pr)
    echo 0
    exit 0
    ;;
  api)
    # GET refs/heads/<branch>: decide existence by \$3
    if [[ "\${1:-GET}" == "GET" ]]; then
      exit ${branch_delete}
    fi
    # DELETE: succeed on a live delete, no-op otherwise (the script treats
    # exit 0 as a successful delete).
    exit 0
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
