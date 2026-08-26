#!/usr/bin/env bash
# tests/pi-issue-run-defensive-mkdir.test.sh
#
# fleet-ops#63 / #122: $ATTEMPTS_DIR was wiped from under running workers
# (race with a concurrent worker, tmpfiles.d rule, external cleanup).
# The startup `mkdir -p` is not enough — recreate inline before the
# tried-seats append. This test proves the inline mkdir is wired up and
# that a mid-run wipe does not strand the worker in crash-loop.
#
# Runs fully offline (fleet-ops#142): scratch PI_PACKET_STATE / PI_ISSUES_DIR,
# PI_SEAT_LIB_CHECK_SYSTEMD=0, and a poisoned systemctl stub that would fill
# the test seat if listing were still consulted. Stub `pi` so the script
# exits cleanly while we test the mkdir behavior.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/pi-issue-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch="$(mktemp -d -t pi-issue-run-mkdir.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# --- scratch environment ---------------------------------------------------
export HOME="$scratch/home"
mkdir -p "$HOME"

STATE_DIR="$scratch/state"
mkdir -p "$STATE_DIR/attempts" "$STATE_DIR/active-seats"
LEDGER="$scratch/ledger"
mkdir -p "$LEDGER"
ISSUES_DIR="$scratch/issues"
mkdir -p "$ISSUES_DIR"

export PI_PACKET_STATE="$STATE_DIR"
export PI_SEAT_HEALTH_LEDGER_DIR="$LEDGER"
export PI_ISSUES_DIR="$ISSUES_DIR"
export PI_PACKET_SEAT_LIB="$repo_root/lib/seat-lib.sh"
export PI_SEAT_LIB_CHECK_SYSTEMD=0
export XDG_RUNTIME_DIR="$scratch/xdg"
mkdir -p "$XDG_RUNTIME_DIR"

stub_bin="$scratch/stub-bin"
mkdir -p "$stub_bin"

# Stub `pi`: any invocation is a success with a stdout large enough to
# pass the no-op-detection 20-byte threshold (pi-issue-run treats
# <20B output as a no-op and re-seats; we want a real success exit so
# the script's mkdir + tried-seats write has happened by the time we
# inspect state).
cat >"$stub_bin/pi" <<'STUB'
#!/usr/bin/env bash
# Pretend we did real work — emit a success line that's safely above
# the 20-byte no-op threshold (https://github.com/Nishfleet/fleet-ops/pull/99).
printf 'OK https://github.com/Nishfleet/fleet-ops/pull/9999\n'
exit 0
STUB
chmod +x "$stub_bin/pi"
export PI_BIN="$stub_bin/pi"

# Stub `gh`: never invoked by this test, but worker-token and tier1 paths
# may probe. Make it a no-op.
cat >"$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$stub_bin/gh"

# Stub `worker-token`: never invoked.
cat >"$stub_bin/worker-token" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$stub_bin/worker-token"

# Poisoned systemctl: if pick_seat still lists live units, this reports the
# test seat as fully occupied (cap=1 below) and the run fails with an empty
# pick. That is the fleet-ops#142 class, caught here instead of on a busy host.
cat >"$stub_bin/systemctl" <<'STUB'
#!/usr/bin/env bash
args=" $* "
if [[ "$args" == *" list-units "* ]]; then
  printf 'pi-issue@live-bleed.service loaded activating start poison\n'
  exit 0
fi
if [[ "$args" == *" show "* ]] && [[ "$args" == *"ExecStart"* ]]; then
  printf '/bin/sh -c --provider devin --model swe-1-7\n'
  exit 0
fi
exit 0
STUB
chmod +x "$stub_bin/systemctl"

export PATH="$stub_bin:/usr/local/bin:/usr/bin:/bin"

# --- stub inputs -----------------------------------------------------------
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export PI_MODELS_JSON="$scratch/models.json"

cat >"$SEAT_CAPS_JSON" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": [],
  "providers": {
    "devin": {
      "cap": 1,
      "class": "subscription",
      "models": { "swe-1-7": 1 }
    }
  }
}
JSON

cat >"$PI_MODELS_JSON" <<'JSON'
{
  "providers": {
    "devin": {
      "models": [
        { "id": "swe-1-7", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 }
      ]
    }
  }
}
JSON

# Pre-create the issues state dir + a packet so the script proceeds.
echo 'noop' > "$ISSUES_DIR/pi-issue-mkdir-test.in"

ATTEMPTS_PATH="$STATE_DIR/attempts"

# --- Lock: the poison stub must actually fill the cap when listing is on ---
# Without this, a broken stub would make the #142 isolation look green
# while still depending on the host's live unit table.
bleed=$(
  exec 2>"$scratch/lock.err"
  export PI_SEAT_LIB_CHECK_SYSTEMD=1
  # shellcheck disable=SC1091
  source "$repo_root/lib/seat-lib.sh"
  pick_seat "" "" 0 "" || true
)
[[ -z "$bleed" ]] \
  || fail "poison stub did not fill the cap under PI_SEAT_LIB_CHECK_SYSTEMD=1 (got '$bleed'); the #142 lock is inert"
ok "poison stub fills cap when systemd listing is on (fleet-ops#142 lock is live)"

# --- Case 1: normal run — tries file is written, attempts dir survives -----
set +e
"$bin" pi-issue-mkdir-test 2>"$scratch/err.log"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "normal run should succeed, got rc=$rc: $(cat "$scratch/err.log")"
[[ -d "$ATTEMPTS_PATH" ]] || fail "normal run: attempts dir not created at $ATTEMPTS_PATH"
tries="$ATTEMPTS_PATH/pi-issue-pi-issue-mkdir-test.tried-seats"
[[ -f "$tries" ]] || fail "normal run: tried-seats file not created at $tries"
# Reset-on-success (fleet-ops#131) clears the file after a successful run,
# so the file may be empty here. Its existence proves the inline write happened.
ok "normal run writes tried-seats and keeps attempts dir"

# --- Case 2: wipe the attempts dir between runs; the inline mkdir in the
# script (before the append) recreates it. We simulate the wipe + retry
# by deleting $ATTEMPTS_PATH right before invoking the script again, and
# confirming the second run still succeeds and recreates the dir.
rm -rf "$ATTEMPTS_PATH"
[[ -d "$ATTEMPTS_PATH" ]] && fail "setup: wipe failed"
set +e
"$bin" pi-issue-mkdir-test 2>"$scratch/err2.log"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "wipe+retry should still succeed (inline mkdir), got rc=$rc: $(cat "$scratch/err2.log")"
[[ -d "$ATTEMPTS_PATH" ]] || fail "wipe+retry: attempts dir was not recreated"
[[ -f "$tries" ]] || fail "wipe+retry: tried-seats file was not recreated"
ok "attempts dir recreated after external wipe (fleet-ops#63 root cause)"

# --- Case 3: the defensive mkdir must be near the write, not just at
# startup. Grep the script for the inline mkdir immediately preceding
# the tried-seats append. Catches future refactors that move the mkdir
# back to startup-only.
startup_mkdir=$(grep -n '^mkdir -p "\$ATTEMPTS_DIR"' "$bin" || true)
append_line=$(grep -nF "printf '%s/%s\\n' \"\$np\" \"\$nm\" >>\"\$tried_file\"" "$bin" || true)
[[ -n "$startup_mkdir" ]] || fail "pi-issue-run missing startup mkdir -p \$ATTEMPTS_DIR"
[[ -n "$append_line" ]] || fail "pi-issue-run missing tried-seats append"
# Find any defensive mkdir that precedes the append.
inline=$(awk '/^# Defensive recreate/ { flag=1; next } flag && /^mkdir -p "\$ATTEMPTS_DIR"/ { print NR; exit }' "$bin")
[[ -n "$inline" ]] || fail "pi-issue-run missing defensive inline mkdir -p \$ATTEMPTS_DIR (between seat pick and tried-seats append)"
ok "inline defensive mkdir is wired between seat pick and tried-seats append"

# --- Case 4 (P15): hang watchdog — a pi that never finalizes must be
# killed by the wrapper's timeout, logged, and surfaced as rc!=0 so
# systemd re-seats. This is the fleet-ops#83 wedge: pi does tool work
# then hangs in ep_poll; previously the wrapper waited forever and the
# unit sat in `activating` until TimeoutStartSec (45 min), holding its
# seat and starving pick_seat. The wrapper must bound the run itself.
stub_hang="$scratch/stub-hang"
mkdir -p "$stub_hang"
cat >"$stub_hang/pi" <<'STUB'
#!/usr/bin/env bash
# Simulate the wedge: never produce output, never exit (pi's finalize hang).
sleep 300
STUB
chmod +x "$stub_hang/pi"

# A tiny timeout so the test doesn't wait 42 minutes. The err file must
# carry the watchdog marker so seat-health/pick_seat can distinguish a
# hang from a spawn ETIMEDOUT.
export PI_HANG_TIMEOUT_S=2
export PI_BIN="$stub_hang/pi"
# Fresh instance so pick_seat still has a seat to route to (the tried-seats
# file from cases 1-3 already excluded devin/swe-1-7).
HANG_INST="pi-issue-mkdir-hang"
echo noop > "$ISSUES_DIR/$HANG_INST.in"
set +e
timeout 30 "$bin" "$HANG_INST" 2>"$scratch/err3.log"
rc=$?
set -e
[[ "$rc" != "0" ]] || fail "P15: hung pi should exit non-zero, got rc=$rc"
# The marker lands in the unit err file (the wrapper appends it there for
# seat-health/pick_seat to distinguish a hang from a spawn ETIMEDOUT).
HANG_ERR="$ISSUES_DIR/$HANG_INST.err"
grep -q "PI HANG WATCHDOG" "$HANG_ERR" || fail "P15: unit err file missing PI HANG WATCHDOG marker: $(cat "$HANG_ERR")"
ok "P15: hung pi killed by wrapper watchdog (PI_HANG_TIMEOUT_S), marker written, rc!=0"
