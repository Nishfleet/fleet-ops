#!/usr/bin/env bash
# tests/pi-intake-topup.test.sh
#
# fleet-ops#3695: continuous intake top-up. pi-intake@<repo>.timer ticks
# every 20 min while a worker cohort finishes inside ~10 min, leaving half
# of every window idle next to ready work (observed 2026-09-05T15:56Z:
# 0 productive pi-issue@ units against 72 agent-ready issues). The fix:
# pi-issue@ ExecStopPost re-triggers the worker's own repo intake on exit,
# the tick debounce coalesces the burst — a tick starting within 60s of
# the previous tick's finish sleeps out the remainder while holding the
# flock, then runs once — and StartLimitBurst 8 -> 90 keeps the top-ups
# from tripping the start limit and silencing the timer tick.
#
# Proves:
#   1. pi-issue@.service has a SECOND ExecStopPost that starts
#      pi-intake@<repo> with --no-block and a '-' prefix, deriving the repo
#      as the instance prefix before the last '-'.
#   2. The top-up ExecStopPost runs AFTER the salvage one (worktree is
#      banked before the next claim cycle begins).
#   3. pi-intake@.service StartLimitBurst is 90 inside [Unit] so top-up
#      starts cannot silence the 20-min timer tick.
#   4. lib/pi-intake-tick.sh has the debounce: PI_INTAKE_TOPUP_DEBOUNCE_S
#      (default 60), a per-repo last-finish stamp next to the lock, an
#      EXIT trap that stamps every exit AFTER the flock, and a sleep of
#      the remainder — the sleep holds the lock so siblings coalesce.
#   5. Behavioral: a tick starting inside the window sleeps the remainder
#      before doing any work; a first-ever tick does not sleep.
#   6. Behavioral: the EXIT trap stamps the finish even on a FAILING tick.
#   7. Behavioral: a second start while a tick sleeps in its debounce is
#      still a fast no-op on the flock — the coalesce, not a second tick.
#   8. Behavioral: a corrupt stamp is treated as no prior finish (no
#      sleep, no crash).
#   9. shellcheck is clean on the tick; systemd-analyze verify accepts
#      both unit files.
#
# Hosted by tests/pi-intake-run.test.sh (the ci.yml-listed intake hub) so
# the drill runs in CI without a .github/workflows edit.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"
issue_unit="$repo_root/systemd/pi-issue@.service"
intake_unit="$repo_root/systemd/pi-intake@.service"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"
[[ -f "$issue_unit" ]] || fail "systemd/pi-issue@.service missing"
[[ -f "$intake_unit" ]] || fail "systemd/pi-intake@.service missing"

# === Test 1: pi-issue@ ExecStopPost top-up ===============================
topup_lines=$(grep -c '^ExecStopPost=' "$issue_unit" || true)
(( topup_lines == 2 )) \
    || fail "pi-issue@.service must have exactly 2 ExecStopPost lines (salvage + top-up), found $topup_lines"
grep -qF 'ExecStopPost=-/bin/sh -c '"'"'inst="%i"; systemctl --user start --no-block "pi-intake@$${inst%-*}.service"'"'"'' "$issue_unit" \
    || fail "top-up ExecStopPost line missing/mis-shaped: want '-' prefix, --no-block, pi-intake@<prefix-before-last-dash>"

# === Test 2: top-up runs AFTER salvage ===================================
salvage_line=$(grep -n 'ExecStopPost=-/home/nish/.local/bin/pi-salvage-worktree' "$issue_unit" | cut -d: -f1)
topup_line=$(grep -n 'pi-intake@$${inst%-\*}.service' "$issue_unit" | cut -d: -f1)
[[ -n "$salvage_line" && -n "$topup_line" ]] || fail "could not locate salvage/top-up ExecStopPost lines"
(( salvage_line < topup_line )) \
    || fail "salvage ExecStopPost (line $salvage_line) must precede top-up (line $topup_line)"
ok "Test 1-2: pi-issue@ ExecStopPost fires pi-intake@<repo> --no-block after salvage"

# === Test 3: StartLimitBurst 90 in [Unit] ================================
grep -qF 'StartLimitBurst=90' "$intake_unit" \
    || fail "pi-intake@.service StartLimitBurst must be 90 (top-ups share the start budget with timer ticks)"
burst_line=$(grep -n '^StartLimitBurst=90$' "$intake_unit" | cut -d: -f1)
service_line=$(grep -n '^\[Service\]$' "$intake_unit" | cut -d: -f1)
(( burst_line < service_line )) \
    || fail "StartLimitBurst must live in [Unit] (line $burst_line), before [Service] (line $service_line)"
ok "Test 3: pi-intake@.service StartLimitBurst=90 in [Unit]"

# === Test 4: debounce shape in the tick ==================================
grep -qF 'TOPUP_DEBOUNCE_S="${PI_INTAKE_TOPUP_DEBOUNCE_S:-60}"' "$tick" \
    || fail "TOPUP_DEBOUNCE_S env var not found (must default 60 and be overridable for tests)"
grep -qF '_tick_last_finish_stamp="$lockdir/${REPO}.last-finish"' "$tick" \
    || fail "per-repo last-finish stamp must sit next to the lock (\$lockdir/\${REPO}.last-finish)"
grep -qF "trap 'date +%s >\"\$_tick_last_finish_stamp\" 2>/dev/null || true' EXIT" "$tick" \
    || fail "EXIT trap that stamps the finish not found (must cover every exit path)"
grep -qF 'sleep "$_tick_sleep_remainder"' "$tick" \
    || fail "debounce must SLEEP the remainder (not skip) — sleep line not found"

# Ordering: the debounce block must come AFTER the non-blocking flock (the
# sleep holds the lock so siblings coalesce) and the stamp trap must be
# installed AFTER the no-op exit (a lock no-op never moves the window).
flock_line=$(grep -n 'flock -n 9' "$tick" | head -1 | cut -d: -f1)
noop_line=$(grep -n 'tick already running (no-op)' "$tick" | head -1 | cut -d: -f1)
debounce_line=$(grep -n 'TOPUP_DEBOUNCE_S=' "$tick" | head -1 | cut -d: -f1)
trap_line=$(grep -n "trap 'date +%s" "$tick" | head -1 | cut -d: -f1)
[[ -n "$flock_line" && -n "$noop_line" && -n "$debounce_line" && -n "$trap_line" ]] \
    || fail "could not locate flock/no-op/debounce/trap lines"
(( flock_line < debounce_line )) \
    || fail "debounce (line $debounce_line) must come after the flock (line $flock_line)"
(( noop_line < trap_line )) \
    || fail "EXIT trap (line $trap_line) must be installed after the no-op exit (line $noop_line)"
ok "Test 4: debounce sits after the flock; stamp trap installed after the no-op path"

# === Behavioral drill ====================================================
# The tick exits 1 quickly at the precedence-band lib check when
# PRECEDENCE_BAND_LIB points at a missing file — AFTER the debounce block,
# BEFORE any gh/git/network work. Running a COPY of the script out of a
# scratch dir keeps the checkout fallback (sibling lib/) from rescuing the
# stub, so the fast exit is deterministic on hosted CI and the VPS.
scratch="$(mktemp -d)"
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT
cp "$tick" "$scratch/tick.sh"
chmod +x "$scratch/tick.sh"

run_tick() {
    # $1 = stamp content to plant ('' = no stamp), $2 = debounce window.
    # Prints elapsed_seconds on stdout's last line; tick output on stderr.
    local stamp="$1" window="$2" lockdir="$scratch/locks" start end
    mkdir -p "$lockdir"
    rm -f "$lockdir/testrepo.last-finish"
    [[ -n "$stamp" ]] && printf '%s' "$stamp" > "$lockdir/testrepo.last-finish"
    start=$(date +%s)
    set +e
    GH_TOKEN=test-dummy \
        PI_INTAKE_LOCKDIR="$lockdir" \
        PI_INTAKE_TOPUP_DEBOUNCE_S="$window" \
        PRECEDENCE_BAND_LIB="$scratch/no-such-precedence-band.sh" \
        bash "$scratch/tick.sh" testrepo >&2
    set -e
    end=$(date +%s)
    echo $(( end - start ))
}

# === Test 5: first tick does not sleep; a tick inside the window does ====
elapsed_first=$(run_tick '' 6)
(( elapsed_first <= 3 )) \
    || fail "first-ever tick must not sleep (no stamp), took ${elapsed_first}s"
elapsed_topup=$(run_tick "$(date +%s)" 6)
(( elapsed_topup >= 4 )) \
    || fail "tick inside the 6s window must sleep the remainder (~6s), took ${elapsed_topup}s"
ok "Test 5: no stamp -> immediate (${elapsed_first}s); fresh stamp -> slept remainder (${elapsed_topup}s)"

# === Test 6: EXIT trap stamps the finish on a FAILING tick ===============
lockdir="$scratch/locks"
rm -f "$lockdir/testrepo.last-finish"
before=$(date +%s)
run_tick '' 6 >/dev/null
[[ -f "$lockdir/testrepo.last-finish" ]] \
    || fail "EXIT trap must write the last-finish stamp even when the tick exits 1"
stamped=$(cat "$lockdir/testrepo.last-finish")
[[ "$stamped" =~ ^[0-9]+$ ]] || fail "stamp must be epoch seconds, got: $stamped"
(( stamped >= before )) \
    || fail "stamp ($stamped) must be >= tick start ($before)"
ok "Test 6: failing tick still stamps $lockdir/testrepo.last-finish"

# === Test 7: a start during the sleep is a fast no-op ====================
rm -f "$lockdir/testrepo.last-finish"
printf '%s' "$(date +%s)" > "$lockdir/testrepo.last-finish"
GH_TOKEN=test-dummy \
    PI_INTAKE_LOCKDIR="$lockdir" \
    PI_INTAKE_TOPUP_DEBOUNCE_S=8 \
    PRECEDENCE_BAND_LIB="$scratch/no-such-precedence-band.sh" \
    bash "$scratch/tick.sh" testrepo >"$scratch/sleeper.out" 2>&1 &
sleeper_pid=$!
sleep 1  # the sleeper is inside its debounce window, holding the flock
start=$(date +%s)
set +e
out=$(GH_TOKEN=test-dummy \
    PI_INTAKE_LOCKDIR="$lockdir" \
    PI_INTAKE_TOPUP_DEBOUNCE_S=8 \
    PRECEDENCE_BAND_LIB="$scratch/no-such-precedence-band.sh" \
    bash "$scratch/tick.sh" testrepo 2>&1)
rc=$?
set -e
end=$(date +%s)
(( rc == 0 )) || fail "sibling start during a debounce sleep must exit 0, got $rc ($out)"
printf '%s' "$out" | grep -q 'already running (no-op)' \
    || fail "sibling start must no-op on the flock, got: $out"
(( end - start <= 3 )) \
    || fail "sibling no-op must be fast (flock -n), took $((end - start))s"
wait "$sleeper_pid" || true
grep -q 'coalescing top-up burst' "$scratch/sleeper.out" \
    || fail "sleeping tick must log the coalesce, got: $(cat "$scratch/sleeper.out")"
ok "Test 7: sibling start during the debounce sleep no-ops fast; sleeper runs once"

# === Test 8: corrupt stamp -> treated as no prior finish =================
elapsed_corrupt=$(run_tick 'not-a-number' 6)
(( elapsed_corrupt <= 3 )) \
    || fail "corrupt stamp must be treated as no prior finish, took ${elapsed_corrupt}s"
ok "Test 8: corrupt stamp cannot wedge the tick (${elapsed_corrupt}s)"

# === Test 9: shellcheck + systemd-analyze =================================
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "$tick" --severity=warning
    ok "Test 9a: shellcheck clean on lib/pi-intake-tick.sh"
else
    echo "SKIP: Test 9a: shellcheck not installed"
fi
if command -v systemd-analyze >/dev/null 2>&1; then
    if ! vout=$(systemd-analyze verify --man=no "$issue_unit" 2>&1); then
        fail "systemd-analyze verify failed for pi-issue@.service: $vout"
    fi
    if ! vout=$(systemd-analyze verify --man=no "$intake_unit" 2>&1); then
        fail "systemd-analyze verify failed for pi-intake@.service: $vout"
    fi
    ok "Test 9b: systemd-analyze verify accepts both unit files"
else
    echo "SKIP: Test 9b: systemd-analyze not on PATH"
fi

echo
echo "ALL OK: intake top-up — worker-exit ExecStopPost + 60s coalescing debounce + StartLimitBurst=90 (fleet-ops#3695)"
