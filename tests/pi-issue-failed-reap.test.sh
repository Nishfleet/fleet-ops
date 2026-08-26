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
