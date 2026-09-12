#!/usr/bin/env bash
# tests/pi-packet-guard.test.sh
#
# Proves the pi-packet guard distinguishes launcher faults from lane faults.
# Runs offline — no Claude, no systemd, no network.

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$here/.." && pwd)
export PI_PACKET_GUARD_LIB="$repo_root/lib/guard_pi_packet.py"
guard="$repo_root/bin/pi-packet-guard"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch=$(mktemp -d -t pi-packet-guard.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM

run_guard() {
    local json="$1"
    set +e
    out=$("$guard" <<< "$json" 2>&1)
    rc=$?
    set -e
}

# --- 1. non-pi command is ignored -------------------------------------------------
run_guard '{"tool_input": {"command": "ls -la"}}'
[[ "$rc" == 0 ]] || fail "non-pi command must exit 0, got $rc ($out)"
ok "non-pi command is ignored"

# --- 2. clean pi run with a verdict line is allowed -------------------------------
log="$scratch/clean.log"
{
    printf 'EXTLOAD-OK\nEXTLOAD-OK\nEXTLOAD-OK\nEXTLOAD-OK\n'
    printf 'RESULT: opened https://github.com/Nishfleet/fleet-ops/pull/1\n'
} >"$log"
run_guard "{\"tool_input\":{\"command\":\"pi --print --provider devin --model glm-5-2 < packet.md > $log\"}}"
[[ "$rc" == 0 ]] || fail "clean run with verdict must exit 0, got $rc ($out)"
ok "clean run with verdict is allowed"

# --- 3. lane fault: rate limit / quota in log is a lane fault ---------------------
log="$scratch/lane.log"
{
    printf 'EXTLOAD-OK\nEXTLOAD-OK\nEXTLOAD-OK\nEXTLOAD-OK\n'
    printf 'rate_limit_error: please retry after 60s\n'
} >"$log"
run_guard "{\"tool_input\":{\"command\":\"pi --print --provider devin --model glm-5-2 < packet.md > $log\"}}"
[[ "$rc" == 2 ]] || fail "lane fault must exit 2, got $rc ($out)"
printf '%s\n' "$out" | grep -qi 'lane fault' || fail "stderr must mention 'lane fault': $out"
printf '%s\n' "$out" | grep -qi 'rotate' || fail "stderr must mention rotating the seat: $out"
ok "lane fault (rate_limit) exits 2 and tells agent to rotate"

# --- 4. lane fault: ETIMEDOUT in log is a lane fault ------------------------------
log="$scratch/etimeout.log"
{
    printf 'EXTLOAD-OK\nEXTLOAD-OK\nEXTLOAD-OK\nEXTLOAD-OK\n'
    printf 'Error: spawn timed out (ETIMEDOUT)\n'
} >"$log"
run_guard "{\"tool_input\":{\"command\":\"pi --print --provider devin --model glm-5-2 < packet.md > $log\"}}"
[[ "$rc" == 2 ]] || fail "ETIMEDOUT lane fault must exit 2, got $rc ($out)"
printf '%s\n' "$out" | grep -qi 'lane fault' || fail "stderr must mention 'lane fault': $out"
ok "lane fault (ETIMEDOUT) exits 2"

# --- 5. launcher fault: nohup with short/no-verdict log ---------------------------
log="$scratch/nohup.log"
{
    printf 'EXTLOAD-OK\nEXTLOAD-OK\nEXTLOAD-OK\nEXTLOAD-OK\n'
} >"$log"
run_guard "{\"tool_input\":{\"command\":\"nohup pi --print --provider devin --model glm-5-2 < packet.md > $log\"}}"
[[ "$rc" == 2 ]] || fail "nohup launcher fault must exit 2, got $rc ($out)"
printf '%s\n' "$out" | grep -qi 'launcher fault' || fail "stderr must mention 'launcher fault': $out"
printf '%s\n' "$out" | grep -qi 'pi-systemd-run' || fail "stderr must tell agent to use pi-systemd-run: $out"
ok "nohup short/no-verdict log is a launcher fault"

# --- 6. launcher fault: trailing '&' with short/no-verdict log --------------------
log="$scratch/background.log"
{
    printf 'EXTLOAD-OK\nEXTLOAD-OK\nEXTLOAD-OK\nEXTLOAD-OK\n'
} >"$log"
run_guard "{\"tool_input\":{\"command\":\"pi --print --provider devin --model glm-5-2 < packet.md > $log &\"}}"
[[ "$rc" == 2 ]] || fail "trailing '&' launcher fault must exit 2, got $rc ($out)"
printf '%s\n' "$out" | grep -qi 'launcher fault' || fail "stderr must mention 'launcher fault': $out"
ok "trailing '&' short/no-verdict log is a launcher fault"

# --- 7. launcher fault: nohup when no log was produced ----------------------------
missing="$scratch/missing.log"
run_guard "{\"tool_input\":{\"command\":\"nohup pi --print --provider devin --model glm-5-2 < packet.md > $missing\"}}"
[[ "$rc" == 2 ]] || fail "nohup with missing log must exit 2, got $rc ($out)"
printf '%s\n' "$out" | grep -qi 'launcher fault' || fail "stderr must mention 'launcher fault': $out"
ok "nohup with missing log is a launcher fault"

# --- 8. short/no-verdict without nohup or background is still suspicious ---------
log="$scratch/short.log"
{
    printf 'EXTLOAD-OK\nEXTLOAD-OK\nEXTLOAD-OK\n'
} >"$log"
run_guard "{\"tool_input\":{\"command\":\"pi --print --provider devin --model glm-5-2 < packet.md > $log\"}}"
[[ "$rc" == 2 ]] || fail "short/no-verdict log must exit 2, got $rc ($out)"
printf '%s\n' "$out" | grep -qi 'suspiciously short\|no verdict' || fail "stderr must mention short/no-verdict: $out"
ok "short/no-verdict log without nohup is still flagged"

# --- 9. nohup that actually produced a verdict is allowed -------------------------
log="$scratch/nohup-clean.log"
{
    printf 'EXTLOAD-OK\nEXTLOAD-OK\nEXTLOAD-OK\nEXTLOAD-OK\n'
    printf 'OK: packet completed\n'
} >"$log"
run_guard "{\"tool_input\":{\"command\":\"nohup pi --print --provider devin --model glm-5-2 < packet.md > $log\"}}"
[[ "$rc" == 0 ]] || fail "nohup run that produced a verdict must exit 0, got $rc ($out)"
ok "nohup run with a verdict is not blocked"

# --- 10-12. false LIVE-claim gate (fleet-ops#5786) --------------------------------
# The hook reuses lib/pi-packet-verdict.py's LIVE-claim gate: a packet log
# claiming LIVE/DEPLOYED/live-on-host without a same-line merged origin/main
# SHA is a fault — exit 2, do not report the packet as working. Fixture repo:
# main_sha is merged; branch_sha is still on the worker's branch.
claim_repo="$scratch/claim-repo"
git init -q -b main "$claim_repo"
git -C "$claim_repo" config user.email t@t
git -C "$claim_repo" config user.name t
git -C "$claim_repo" commit -qm init --allow-empty
main_sha=$(git -C "$claim_repo" rev-parse HEAD)
git -C "$claim_repo" remote add origin "$claim_repo"
git -C "$claim_repo" fetch -q origin
git -C "$claim_repo" checkout -qb fix/issue-x
git -C "$claim_repo" commit -qm wip --allow-empty
branch_sha=$(git -C "$claim_repo" rev-parse HEAD)
git -C "$claim_repo" checkout -q main
export PI_VERDICT_LIVE_REPO_DIRS="$claim_repo"
export PI_VERDICT_LIVE_FETCH=0

log="$scratch/false-claim.log"
{
    printf 'EXTLOAD-OK\nEXTLOAD-OK\nEXTLOAD-OK\nEXTLOAD-OK\n'
    printf 'fix landed as PR #5762 and is LIVE on this host (deploy-clone on the branch)\n'
    printf 'RESULT: reported the repair\n'
} >"$log"
run_guard "{\"tool_input\":{\"command\":\"pi --print --provider devin --model glm-5-2 < packet.md > $log\"}}"
[[ "$rc" == 2 ]] || fail "a false LIVE claim must exit 2, got $rc ($out)"
printf '%s\n' "$out" | grep -qi 'LIVE/DEPLOYED claim' \
    || fail "stderr must name the false-claim fault: $out"
ok "packet log claiming LIVE without a merged SHA -> exit 2 (fleet-ops#5786)"

log="$scratch/true-claim.log"
{
    printf 'EXTLOAD-OK\nEXTLOAD-OK\nEXTLOAD-OK\nEXTLOAD-OK\n'
    printf 'gate is LIVE on this host: %s is on origin/main\n' "$main_sha"
    printf 'RESULT: reported the repair\n'
} >"$log"
run_guard "{\"tool_input\":{\"command\":\"pi --print --provider devin --model glm-5-2 < packet.md > $log\"}}"
[[ "$rc" == 0 ]] || fail "a LIVE claim citing a merged origin/main SHA must pass, got $rc ($out)"
ok "LIVE claim citing a merged origin/main SHA -> allowed"

log="$scratch/branch-claim.log"
{
    printf 'EXTLOAD-OK\nEXTLOAD-OK\nEXTLOAD-OK\nEXTLOAD-OK\n'
    printf 'fix is DEPLOYED to production: %s\n' "$branch_sha"
    printf 'RESULT: reported the repair\n'
} >"$log"
run_guard "{\"tool_input\":{\"command\":\"pi --print --provider devin --model glm-5-2 < packet.md > $log\"}}"
[[ "$rc" == 2 ]] || fail "a claim citing an unmerged branch SHA must exit 2, got $rc ($out)"
ok "DEPLOYED claim citing an unmerged branch SHA -> exit 2"

ok "pi-packet-guard distinguishes launcher faults, lane faults, and false LIVE claims"

# fleet-ops#1545: cursor keystone lane output wrapper reuses this guard's
# verdict grammar verbatim. Hosted here (not a new ci.yml line — workers
# cannot push .github/workflows/**) so P14 runs it without a workflow edit.
bash "$here/guard-cursor-packet.test.sh"
