#!/usr/bin/env bash
# pi-intake-topup.test.sh — worker-exit top-up (fleet-ops#3695).
#
# The intake timer ticks every 20 min; a cohort of workers finishes inside
# ~10 min; the box then idles next to ready work until the next tick
# (2026-09-05T15:56Z: 0 workers, 72 agent-ready). Fix, no new organ:
#   1. pi-issue@.service asks its repo's intake for a refill from its stop
#      path (ExecStopPost, '-' prefixed, --no-block).
#   2. The refill derives the repo from the instance <repo>-<N>, including
#      repos whose names carry '-' or '.'.
#   3. pi-intake@.service's start limit admits one top-up per debounce window.
#   4. The tick coalesces a cohort: a start inside the debounce window sleeps
#      out the remainder (holding the flock, so the rest of the cohort no-ops)
#      and then RUNS — it never skips, so the last worker of a cohort cannot
#      leave its slot idle until the timer. Outside the window it runs at
#      once. Every tick stamps its finish for the next one.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
unit="$repo_root/systemd/pi-issue@.service"
intake_unit="$repo_root/systemd/pi-intake@.service"
tick="$repo_root/lib/pi-intake-tick.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }
[[ -f "$unit" && -f "$intake_unit" && -f "$tick" ]] || fail "unit/tick files missing"
scratch="$(mktemp -d -t pi-topup.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# --- 1. unit line -----------------------------------------------------------
line=$(grep -E '^ExecStopPost=.*pi-intake@' "$unit" || true)
[[ -n "$line" ]] || fail "pi-issue@.service has no ExecStopPost that starts pi-intake@"
[[ "$line" == ExecStopPost=-* ]] || fail "top-up ExecStopPost must be '-' prefixed so a failing systemctl cannot wedge the stop path"
[[ "$line" == *'--no-block'* ]] || fail "top-up must start the tick with --no-block (never wait on intake inside a worker stop path)"
grep -qE '^ExecStopPost=-/home/nish/.local/bin/pi-salvage-worktree' "$unit" || fail "salvage ExecStopPost (fleet-ops#1204) must stay"
ok "pi-issue@.service: top-up ExecStopPost present, '-' prefixed, --no-block, salvage kept"

# --- 2. repo derivation, with a recording systemctl stub --------------------
mkdir -p "$scratch/bin"
cat >"$scratch/bin/systemctl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_LOG"
SH
chmod +x "$scratch/bin/systemctl"
cmd_template=${line#ExecStopPost=-}
STUB_LOG="$scratch/systemctl.log"
run_stop_path() {
    # systemd escaping: %i -> instance, %% -> %, $$ -> $
    local inst="$1" cmd
    cmd=${cmd_template//%i/$inst}
    cmd=${cmd//%%/%}
    cmd=${cmd//\$\$/\$}
    : > "$STUB_LOG"
    PATH="$scratch/bin:$PATH" STUB_LOG="$STUB_LOG" eval "$cmd"
    cat "$STUB_LOG"
}
for case in "0509-1417:0509" "fleet-ops-3692:fleet-ops" "TinyStudio.io-public-7:TinyStudio.io-public"; do
    inst=${case%%:*}; want=${case#*:}
    got=$(run_stop_path "$inst")
    [[ "$got" == "--user start --no-block pi-intake@${want}.service" ]] \
        || fail "instance $inst: want '--user start --no-block pi-intake@${want}.service', got '$got'"
done
ok "repo derived from instance: 0509-1417, fleet-ops-3692, TinyStudio.io-public-7"

# --- 3. intake start limit -------------------------------------------------
burst=$(grep -E '^StartLimitBurst=' "$intake_unit" | cut -d= -f2)
[[ -n "$burst" ]] || fail "pi-intake@.service must set StartLimitBurst"
(( burst >= 60 )) || fail "pi-intake@.service StartLimitBurst=$burst: one top-up per 60 s window needs >= 60/h, or a busy hour silences the timer tick too"
ok "pi-intake@.service StartLimitBurst=$burst admits one top-up per debounce window"

# --- 4. tick debounce coalesces a cohort ------------------------------------
stubs="$scratch/seat-lib-stub.sh"
cat >"$stubs" <<'SH'
total_seat_cap() { echo 8; }
issue_seat_cap() { echo 5; }
pick_seat() { echo "commandcode	deepseek/deepseek-v4-flash		0"; return 0; }
precedence_band_phase() { echo "band"; }
precedence_band_pending_clear() { true; }
precedence_band_pending_starvation_clear() { true; }
precedence_band_is_leverage_issue() { return 1; }
precedence_band_allow_claim() { return 0; }
product_first_export_product_ratio() { return 0; }
product_first_is_self_maintenance() { return 1; }
product_first_ratio() { return 1; }
product_first_hold() { return 1; }
SH
prior_art_stub="$scratch/prior-art-claim-check"
printf 'exit 0\n' >"$prior_art_stub"; chmod +x "$prior_art_stub"
gh() { if [[ "${1:-}" == "issue" && "${2:-}" == "list" ]]; then echo '[]'; return 0; fi; return 0; }
git() { return 0; }
systemctl() { echo "inactive"; return 0; }
export -f gh git systemctl
mkdir -p "$scratch/run" "$scratch/secondary" "$scratch/lock"
run_tick() {
    env GITHUB_ACTIONS=true HOME="$scratch" XDG_RUNTIME_DIR="$scratch/run" \
        PI_INTAKE_LOCKDIR="$scratch/lock" \
        PI_INTAKE_RECONCILER_PROM="$scratch/reconciler" \
        PI_INTAKE_GH_RATE_LIMIT_STATE="$scratch/gh-rate-limit.json" \
        PI_INTAKE_GH_SECONDARY_STATE_DIR="$scratch/secondary" \
        PI_INTAKE_ISSUE_STATE_DIR="$scratch/pi-issues" \
        SEAT_LIB="$stubs" PRECEDENCE_BAND_LIB="$stubs" PRIOR_ART_CLAIM_CHECK="$prior_art_stub" \
        FLEET_ISSUE_REPO="Nishfleet/fleet-ops" PI_INTAKE_DEBOUNCE_SEC=3 \
        bash "$tick" fleet-ops 2>&1
}
stamp="$scratch/lock/fleet-ops.last-tick"
# 4a. no stamp: runs at once and leaves a stamp
t0=$(date +%s); out=$(run_tick) && rc=0 || rc=$?
(( rc == 0 )) || fail "tick with no stamp must exit 0, got rc=$rc: $out"
if grep -q 'coalescing' <<<"$out"; then fail "tick with no stamp must not debounce: $out"; fi
[[ -f "$stamp" ]] || fail "tick must leave $stamp on exit (EXIT trap)"
ok "no stamp: tick runs at once ($(( $(date +%s) - t0 ))s) and stamps its finish"
# 4b. fresh stamp: sleeps out the window, then runs (never skips)
touch "$stamp"; before=$(stat -c %Y "$stamp")
t0=$(date +%s); out=$(run_tick) && rc=0 || rc=$?
(( rc == 0 )) || fail "coalesced tick must exit 0, got rc=$rc: $out"
grep -q 'coalescing' <<<"$out" || fail "tick inside the debounce window must announce coalescing: $out"
held=$(( $(date +%s) - t0 ))
(( held >= 2 )) || fail "tick inside the window must sleep out the remainder (>= 2s of a 3s window), took ${held}s"
(( $(stat -c %Y "$stamp") >= before )) || fail "coalesced tick must refresh the stamp"
grep -q 'no agent-ready\|ready=0\|nothing to claim\|no ready' <<<"$out" || true
ok "fresh stamp: tick coalesces (slept ${held}s of a 3s window) and still runs"
# 4c. stale stamp: runs at once
touch -d '-30 seconds' "$stamp"
out=$(run_tick) && rc=0 || rc=$?
(( rc == 0 )) || fail "tick with a stale stamp must exit 0: $out"
if grep -q 'coalescing' <<<"$out"; then fail "stale stamp (30s > 3s window) must not debounce: $out"; fi
ok "stale stamp: tick runs at once"
echo "pi-intake-topup: all checks passed"
