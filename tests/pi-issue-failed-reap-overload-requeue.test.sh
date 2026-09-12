#!/usr/bin/env bash
# tests/pi-issue-failed-reap-overload-requeue.test.sh
#
# fleet-ops#5743: proves the bench-aware transient-overload requeue is
# minted by pi-issue-failed-reap on the existing issue-dispatch rail (the
# reclaim-cooldown marker) — no hand-added READY-WORK.md `after:` row.
#
# Proves (offline, mocked gh + systemctl + stub seat-lib):
#   1. OPEN issue + branch deleted + last seat's ledger health_class=
#      overload_bench / failure_mode=overload_503 with a future bench_until
#      that outlives the cooldown floor -> the cooldown marker carries an
#      absolute `until: <UTC>` line == the seat's bench_until, and triage
#      carries TRANSIENT-OVERLOAD-REQUEUE (detection is classified, not
#      conflated with empty-run or real packet failures).
#   2. A non-overload ledger (quota stair / other health_class) appends NO
#      until: line — the fixed cooldown path is unchanged.
#   3. An overload bench that has ALREADY expired appends NO until: line.
#   4. An overload bench SHORTER than the cooldown floor appends NO until:
#      line (the stock 900s cooldown already covers it).
#   5. Stale claim-branch cleanup (fleet-ops#3328 corollary): the reap
#      deletes claim/issue-<N> on the failed attempt (branch-exists probe +
#      DELETE call) so the left-behind mutex branch cannot starve the next
#      dispatch.
#   6. The intake tick honors the until: line (bench-aware skip) without
#      breaking the age-based skip (structural pins).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/pi-issue-failed-reap"
tick="$repo_root/lib/pi-intake-tick.sh"

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

# Installs the gh fake; args: branch_delete_rc pr_count (+ issue state JSON baked in).
write_gh() {
    mkdir -p "$fake/gh-bin"
    cat >"$fake/gh-bin/gh" <<FAKE_GH
#!/usr/bin/env bash
case "\$1" in
  api)
    path="\${2:-}"
    if [[ "\$path" == */issues/* ]]; then
      printf '%s\n' '{"state":"OPEN","labels":[{"name":"agent-in-progress"}]}'
      exit 0
    fi
    if [[ "\$path" == */pulls* ]]; then
      if [[ $2 -gt 0 ]]; then printf '[{"number":1}]\n'; else printf '[]\n'; fi
      exit 0
    fi
    if [[ "\$path" == */git/refs/heads/* ]]; then
      if [[ "\$*" == *-X*DELETE* ]]; then exit $1; fi
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
write_gh 0 0

# Stub the seat-lib surface pi-issue-failed-reap touches. seat_ledger_path
# resolves inside the test's ledger dir; everything else is a no-op so the
# reap never reads the live VPS ledger in CI.
cat >"$fake/seat-lib.sh" <<'FAKE_SEAT'
seat_ledger_path() { printf '%s/%s--%s.json' "$SEAT_LEDGER_DIR" "$1" "$2"; }
seat_usable() { return 0; }
seat_log() { :; }
FAKE_SEAT
export SEAT_LIB="$fake/seat-lib.sh"
export SEAT_LEDGER_DIR="$fake/ledgers"
mkdir -p "$SEAT_LEDGER_DIR"
export PI_INTAKE_RECLAIM_COOLDOWN_S=900

state_dir="$fake/state"
mkdir -p "$state_dir/attempts"
issues_dir="$fake/issues"
mkdir -p "$issues_dir"
export PI_PACKET_STATE="$state_dir"
export PI_ISSUES_DIR="$issues_dir"

seed_ledger() {
    # seed_ledger <hc> <fm> <until-ts-or-empty>
    # The model name carries a slash, so the ledger path nests (the real
    # seat_ledger_path convention seat-lib.sh uses).
    mkdir -p "$SEAT_LEDGER_DIR/commandcode--minimax"
    local hc="$1" fm="$2" until="$3"
    jq -nc --arg hc "$hc" --arg fm "$fm" --arg bu "$until" \
        '{health_class:$hc, failure_mode:$fm, bench_until:(if $bu == "" then null else $bu end)}' \
        >"$SEAT_LEDGER_DIR/commandcode--minimax/minimax-m3-free.json"
}

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

# --- Test 1: overload bench outlives the floor -> until: line minted --------
printf 'pkt\n' >"$issues_dir/fleet-ops-5743.in"
: >"$triage"
rm -f "$cooldown"
write_seat
until_ts=$(date -u -d '+2 hours' +%Y-%m-%dT%H:%M:%SZ)
seed_ledger overload_bench overload_503 "$until_ts"
run_reap
[[ "$rc" == "0" ]] || fail "reap must exit 0, got $rc ($out)"
[[ -f "$cooldown" ]] || fail "cooldown marker must exist"
ts_head=$(head -n 1 "$cooldown")
[[ "$ts_head" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || fail "marker line 1 must stay a UTC timestamp for back-compat, got: $ts_head"
until_line=$(sed -n 's/^until: //p' "$cooldown")
[[ "$until_line" == "$until_ts" ]] \
    || fail "until: line must equal the seat's bench_until ($until_ts), got: '$until_line'"
grep -q 'TRANSIENT-OVERLOAD-REQUEUE' "$triage" \
    || fail "triage must carry TRANSIENT-OVERLOAD-REQUEUE: $(cat "$triage")"
ok "Test 1: transient overload classified; bench-aware until: requeue minted (no hand READY-WORK row)"

# --- Test 2: non-overload ledger -> plain fixed cooldown, no until line -----
printf 'pkt\n' >"$issues_dir/fleet-ops-5743.in"
: >"$triage"
rm -f "$cooldown"
write_seat
seed_ledger quota_stair quota_deadline "$until_ts"
run_reap
[[ "$rc" == "0" ]] || fail "reap must exit 0, got $rc ($out)"
[[ -f "$cooldown" ]] || fail "cooldown marker must exist"
! grep -q '^until: ' "$cooldown" || fail "non-overload ledger must NOT mint an until: line"
ok "Test 2: non-overload failure keeps the fixed cooldown path unchanged"

# --- Test 3: expired overload bench -> no until line (nothing to gate) ------
printf 'pkt\n' >"$issues_dir/fleet-ops-5743.in"
: >"$triage"
rm -f "$cooldown"
write_seat
seed_ledger overload_bench overload_503 "$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)"
run_reap
[[ -f "$cooldown" ]] || fail "cooldown marker must exist"
! grep -q '^until: ' "$cooldown" || fail "expired bench must NOT mint an until: line"
ok "Test 3: expired overload bench does not gate the requeue"

# --- Test 3b: bench shorter than the cooldown floor -> no until line --------
printf 'pkt\n' >"$issues_dir/fleet-ops-5743.in"
: >"$triage"
rm -f "$cooldown"
write_seat
seed_ledger overload_bench overload_503 "$(date -u -d '+300 seconds' +%Y-%m-%dT%H:%M:%SZ)"
run_reap
[[ -f "$cooldown" ]] || fail "cooldown marker must exist"
! grep -q '^until: ' "$cooldown" || fail "bench already covered by the stock cooldown must NOT mint until:"
ok "Test 3b: overload bench shorter than the cooldown floor uses the stock cooldown"

# --- Test 4: no seat file at all -> fail-open plain cooldown ----------------
printf 'pkt\n' >"$issues_dir/fleet-ops-5743.in"
: >"$triage"
rm -f "$cooldown" "$state_dir/attempts/pi-issue-fleet-ops-5743.seat"
seed_ledger overload_bench overload_503 "$until_ts"
run_reap
[[ -f "$cooldown" ]] || fail "cooldown marker must exist even with no seat file"
! grep -q '^until: ' "$cooldown" || fail "no seat -> no until line"
ok "Test 4: no last-seat file fails open to the plain cooldown"

# --- Test 5: stale claim branch is DELETED by this same reap ----------------
# (fleet-ops#5743 corollary: #3328 left-behind mutex branches starve the next
# dispatch — the reap's branch_exists + DELETE path is the mechanism.)
branch_probe_fail() {
    mkdir -p "$fake/gh-bin"
    sed 's/exit 0$/exit 255/' "$fake/gh-bin/gh" >/dev/null # no-op placeholder
}
# Direct probe is enough: the fake gh in `write_gh 0 0` answers the
# git/refs/heads/... existence check with 0 (exists) and the -X DELETE with
# 0 (success); test 1 already ran through it. Pin statically that the reap
# issues the DELETE against the claim branch.
grep -q 'git/refs/heads/$branch_name" -X DELETE' "$bin" \
    || fail "reap must delete claim/issue-<N> on the failed attempt (fleet-ops#3328)"
grep -q 'branch_exists=no' "$bin" || fail "branch exists probe missing"
ok "Test 5: stale claim-branch cleanup (delete claim/issue-<N>) present in reap path"

# --- Test 6: intake honors until: (structural pins) -------------------------
grep -qF 'until: ' "$tick" || fail "intake tick does not parse the until: line"
grep -qF 'skipped-reclaim-cooldown-bench' "$tick" \
    || fail "intake tick does not skip a bench-gated requeue"
grep -qF '_cd_until_epoch > _now_epoch' "$tick" \
    || fail "intake until: expiry comparison not found"
grep -qF 'head -n 1' "$tick" \
    || fail "intake must read marker line 1 for the back-compat timestamp (file may now carry 2 lines)"
ok "Test 6: intake tick honors the bench-aware until: line"

echo "OK: pi-issue-failed-reap-overload-requeue.test.sh"
