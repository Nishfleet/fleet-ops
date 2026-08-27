#!/usr/bin/env bash
# tests/fleet-wipe-lessons.test.sh
#
# fleet-ops#533: Lessons from the 2026-08-23 fleet wipe.
# Proves the real checker in bin/fleet-wipe-lessons-check (and its
# Python lib) plus the FLEET-PAUSED skip in heartbeat-tier1 block 5.
#
#   1. Worker prompt names the helper and forbids pgrep -f.
#   2. scan: a fixture pgrep -f / pkill -f / ps|grep is REJECTED.
#   3. scan: argv-running in code is accepted; comments mentioning
#      pgrep -f do not trip.
#   4. Live production scan of this checkout is clean.
#   5. argv-running matches argv[0] basename, not a later argument
#      (the pgrep -f false-positive class).
#   6. pgrep -f DOES match that later-argument process (class proof).
#   7. worktree-remove refuses unpushed HEAD; allows once HEAD is on origin.
#   8. Heartbeat-tier1 block 5 no-ops enable --now when FLEET-PAUSED exists.
#   9. Matrix row sr-fleet-wipe-lessons is enforced.
#  10. MANIFEST installs the helper.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-wipe-lessons-check"
lib="$repo_root/lib/fleet-wipe-lessons.py"
worker="$repo_root/prompts/worker.md"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
matrix="$repo_root/config/rule-enforcement.json"
manifest="$repo_root/MANIFEST"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "missing or not executable: $bin"
[[ -f "$lib" ]] || fail "missing: $lib"
[[ -f "$worker" ]] || fail "missing: $worker"
[[ -f "$tier1" ]] || fail "missing: $tier1"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t wipe-lessons.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# ============================================================================
# 1. worker prompt
# ============================================================================
grep -F -- 'fleet-wipe-lessons-check' "$worker" >/dev/null \
    || fail "worker.md must name bin/fleet-wipe-lessons-check"
grep -qE 'pgrep -f|pgrep --full' "$worker" \
    || fail "worker.md must forbid pgrep -f"
grep -q 'worktree-remove' "$worker" \
    || fail "worker.md must tell authors to use worktree-remove"
ok "1: worker.md carries argv[0] + push-before-delete"

# ============================================================================
# 2-3. scan fixtures
# ============================================================================
fix="$scratch/repo"
mkdir -p "$fix/bin" "$fix/lib"
printf '%s\n' '#!/bin/sh' 'pgrep -x sshd' >"$fix/bin/ok.sh"
printf '%s\n' '#!/bin/sh' 'pgrep -f fleet-ops-deploy' >"$fix/bin/bad-pgrep.sh"
set +e
out=$("$bin" scan --root "$fix" 2>&1)
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scan must reject pgrep -f (rc=$rc out=$out)"
grep -q 'bad-pgrep.sh' <<<"$out" || fail "scan must name the offending file (out=$out)"
ok "2a: scan rejects pgrep -f"

printf '%s\n' '#!/bin/sh' 'pkill --full foo' >"$fix/bin/bad-pkill.sh"
rm -f "$fix/bin/bad-pgrep.sh"
set +e
out=$("$bin" scan --root "$fix" 2>&1)
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scan must reject pkill --full (rc=$rc out=$out)"
ok "2b: scan rejects pkill --full"

printf '%s\n' '#!/bin/sh' 'ps aux | grep fleet-ops-deploy' >"$fix/bin/bad-ps.sh"
rm -f "$fix/bin/bad-pkill.sh"
set +e
out=$("$bin" scan --root "$fix" 2>&1)
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scan must reject ps|grep (rc=$rc out=$out)"
ok "2c: scan rejects ps | grep"

rm -f "$fix/bin/bad-ps.sh"
printf '%s\n' '#!/bin/sh' '# never pgrep -f; that matches arguments' \
    'pgrep -x sshd' >"$fix/bin/ok.sh"
set +e
out=$("$bin" scan --root "$fix" 2>&1)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scan must accept comments + pgrep -x (rc=$rc out=$out)"
ok "3: scan accepts comments and pgrep -x"

# ============================================================================
# 4. live production scan
# ============================================================================
set +e
out=$("$bin" scan --root "$repo_root" 2>&1)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "live checkout scan must be clean (rc=$rc out=$out)"
ok "4: live bin/ + lib/ scan is clean"

# ============================================================================
# 5-6. argv-running vs pgrep -f class proof
# ============================================================================
python3 -c 'import time,sys; time.sleep(20)' wipe-lesson-false-positive &
arg_pid=$!
sleep 0.2
set +e
"$bin" argv-running wipe-lesson-false-positive >/dev/null 2>&1
arg_rc=$?
pgrep -f wipe-lesson-false-positive >/dev/null 2>&1
pgrep_rc=$?
set -e
kill "$arg_pid" 2>/dev/null || true
wait "$arg_pid" 2>/dev/null || true
[[ "$arg_rc" == "1" ]] || fail "argv-running must ignore a later argument (rc=$arg_rc)"
[[ "$pgrep_rc" == "0" ]] || fail "pgrep -f must match that later argument (class proof, rc=$pgrep_rc)"
ok "5: argv-running ignores an argument-only match"
ok "6: pgrep -f matches that same process (the class this gate prevents)"

mkdir -p "$scratch/named"
cp /bin/sleep "$scratch/named/wipe-lesson-argv0"
"$scratch/named/wipe-lesson-argv0" 20 &
named_pid=$!
sleep 0.2
set +e
"$bin" argv-running wipe-lesson-argv0 >/dev/null 2>&1
named_rc=$?
set -e
kill "$named_pid" 2>/dev/null || true
wait "$named_pid" 2>/dev/null || true
[[ "$named_rc" == "0" ]] || fail "argv-running must match argv[0] basename (rc=$named_rc)"
ok "5b: argv-running matches argv[0] basename"

python3 -c 'import time; time.sleep(20)' -- --provider wipe-count-token &
count_pid=$!
sleep 0.2
set +e
got=$("$bin" count-argv python3 --has provider wipe-count-token)
count_rc=$?
set -e
kill "$count_pid" 2>/dev/null || true
wait "$count_pid" 2>/dev/null || true
[[ "$count_rc" == "0" ]] || fail "count-argv must exit 0 (rc=$count_rc)"
[[ "$got" -ge 1 ]] || fail "count-argv must see the python3 --provider wipe-count-token process (got=$got)"
ok "5c: count-argv matches identity plus adjacent FLAG VALUE"

# ============================================================================
# 7. push-before-delete
# ============================================================================
origin="$scratch/origin.git"
git -c init.defaultBranch=main init -q --bare "$origin"
main="$scratch/main"
git clone -q "$origin" "$main"
git -C "$main" config user.email t@t
git -C "$main" config user.name t
echo one >"$main/f"
git -C "$main" add f
git -C "$main" commit -qm one
git -C "$main" push -q origin HEAD:main
git -C "$main" branch -M main
git -C "$main" push -q -u origin main
wt="$scratch/wt"
git -C "$main" worktree add -q -b claim/issue-533-drill "$wt"
echo two >"$wt/g"
git -C "$wt" add g
git -C "$wt" commit -qm two
set +e
out=$("$bin" worktree-remove "$wt" 2>&1)
wt_rc=$?
set -e
[[ "$wt_rc" == "1" ]] || fail "unpushed worktree must be refused (rc=$wt_rc out=$out)"
grep -qi 'push before deleting' <<<"$out" || fail "refuse must say push before deleting (out=$out)"
[[ -d "$wt" ]] || fail "refused remove must leave the worktree on disk"
ok "7a: unpushed HEAD is refused"

git -C "$wt" push -q origin HEAD:claim/issue-533-drill
set +e
out=$("$bin" worktree-remove "$wt" 2>&1)
wt_rc=$?
set -e
[[ "$wt_rc" == "0" ]] || fail "pushed worktree must be removable (rc=$wt_rc out=$out)"
[[ ! -d "$wt" ]] || fail "pushed worktree must actually be removed"
ok "7b: HEAD on origin allows worktree-remove"

# ============================================================================
# 8. FLEET-PAUSED is code in heartbeat-tier1 block 5
# ============================================================================
grep -q 'FLEET_PAUSED_MARKER' "$tier1" \
    || fail "fleet-heartbeat-tier1 must name FLEET_PAUSED_MARKER"
grep -q 'FLEET-PAUSED' "$tier1" \
    || fail "fleet-heartbeat-tier1 must name the FLEET-PAUSED marker"
# The enable --now path must sit after the marker check so a pause cannot
# be undone by timer-arm.  Both strings live in block 5; the marker test
# must appear first in the file.
marker_line=$(grep -n 'FLEET_PAUSED_MARKER' "$tier1" | head -n1 | cut -d: -f1)
enable_line=$(grep -n 'enable --now' "$tier1" | awk -F: '$2 ~ /systemctl/ {print $1; exit}')
[[ -n "$marker_line" && -n "$enable_line" ]] \
    || fail "could not locate marker/enable lines (marker=$marker_line enable=$enable_line)"
[[ "$marker_line" -lt "$enable_line" ]] \
    || fail "FLEET-PAUSED check must precede enable --now (marker=$marker_line enable=$enable_line)"
ok "8: heartbeat-tier1 skips timer re-enable when FLEET-PAUSED is set"

# ============================================================================
# 9. matrix enforced
# ============================================================================
jq -e '.rules[] | select(.id == "sr-fleet-wipe-lessons" and .status == "enforced")' \
    "$matrix" >/dev/null \
    || fail "sr-fleet-wipe-lessons must be status=enforced"
jq -e '.rules[] | select(.id == "sr-fleet-wipe-lessons") | .proof | test("fleet-wipe-lessons")' \
    "$matrix" >/dev/null \
    || fail "sr-fleet-wipe-lessons proof must name the helper"
ok "9: matrix row is enforced"

# ============================================================================
# 10. MANIFEST
# ============================================================================
grep -q 'bin/fleet-wipe-lessons-check' "$manifest" \
    || fail "MANIFEST must install bin/fleet-wipe-lessons-check"
grep -q 'lib/fleet-wipe-lessons.py' "$manifest" \
    || fail "MANIFEST must install lib/fleet-wipe-lessons.py"
ok "10: MANIFEST installs the helper"

echo "OK: fleet-wipe-lessons: scan, argv-running, push-before-delete, FLEET-PAUSED, matrix"
