#!/usr/bin/env bash
# tests/pi-issue-run-tried-reset.test.sh
#
# Proves the 2026-08-26 fleet-ops-32 stuck-loop fix: when every allowlisted
# seat has been tried and pick_seat returns empty, pi-issue-run MUST reset the
# tried-seats file before exiting 1, so the next systemd Restart retries the
# full pool (seats that have recovered become eligible again; seats still in
# backoff stay gated by the seat-health ledger's usable_at).
#
# Before the fix, the tried-seats file was NEVER cleared. A worker that burned
# through every capable seat once could never pick a seat again: every restart
# found the same stale exhausted list and exited 1 in <1s — an infinite loop
# that produced no work and never recovered even after seats healed.
#
# Also proves the success path resets the file, so a later re-trigger of the
# same issue (intake re-claim -> pi-issue-start) starts with the full pool
# instead of the stale list of seats that failed before the one that worked.
#
# Runs entirely offline: stubbed models.json, seat-caps.json, ledger dir, a
# pi stub, and PI_ISSUES_DIR redirected into scratch. No live state dir, no
# network, no systemd.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# --- scratch environment --------------------------------------------------
scratch="$(mktemp -d -t pi-issue-tried-reset.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
export HOME="$scratch/home"
mkdir -p "$HOME"

# P14 (fleet-ops#549): the worker App creds file must exist and mint before
# pi runs. This test is about tried-seats rotation, not identity — stub a
# working App identity so the run reaches pi.
mkdir -p "$HOME/.config/fleet-worker"
: >"$HOME/.config/fleet-worker/nishfleet-worker.env"
chmod 600 "$HOME/.config/fleet-worker/nishfleet-worker.env"
stub_bin="$scratch/stub-bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/worker-token" <<'STUB'
#!/usr/bin/env bash
printf 'export GH_TOKEN=fake-test-token-cccccccccccccccc\n'
exit 0
STUB
chmod +x "$stub_bin/worker-token"
export WORKER_TOKEN_BIN="$stub_bin/worker-token"
export PATH="$stub_bin:$PATH"

STATE_DIR="$scratch/state"
mkdir -p "$STATE_DIR/attempts" "$STATE_DIR/active-seats"
ISSUES_DIR="$scratch/issues"
mkdir -p "$ISSUES_DIR"
LEDGER="$scratch/ledger"
mkdir -p "$LEDGER"

export PI_PACKET_STATE="$STATE_DIR"
export PI_SEAT_HEALTH_LEDGER_DIR="$LEDGER"
export PI_ISSUES_DIR="$ISSUES_DIR"
export PI_BIN="$scratch/pi-stub"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export PI_MODELS_JSON="$scratch/models.json"
export PI_PACKET_SEAT_LIB="$repo_root/lib/seat-lib.sh"

# --- stub inputs ----------------------------------------------------------
# Two capable subscription seats so need_capable=1 (heavy packet) still has a
# pool to exhaust.
cat >"$PI_MODELS_JSON" <<'JSON'
{
  "providers": {
    "devin": {
      "models": [
        { "id": "glm-5-2", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 },
        { "id": "swe-1-7", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 }
      ]
    }
  }
}
JSON

cat >"$SEAT_CAPS_JSON" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": [],
  "providers": {
    "devin": { "cap": 4, "class": "subscription", "models": { "glm-5-2": 4, "swe-1-7": 4 } }
  }
}
JSON

# pi stub: not reached in the all-walled case (pick_seat returns empty before
# pi is invoked). For the success-path case it must emit >= OUT_MIN bytes.
cat >"$PI_BIN" <<'SH'
#!/usr/bin/env bash
echo "PR https://example.com/pr/1 — worked"
SH
chmod +x "$PI_BIN"

write_ledger() {
  local p="$1" m="$2" hc="$3" usable="$4" observed="$5"
  local f
  f=$(printf '%s/%s__%s.json\n' "$LEDGER" "${p//[^A-Za-z0-9._-]/_}" "${m//[^A-Za-z0-9._-]/_}")
  jq -n \
    --arg p "$p" --arg m "$m" --arg hc "$hc" --arg usable "$usable" --arg observed "$observed" \
    '{provider:$p, model:$m, http_status:429, retry_after:null,
      health_class:$hc, retryable:true, seat_dead:false, poison_ladder:false,
      observed_at:$observed, source:"provider_fetch", usable_at:$usable}' >"$f"
}

now_iso()    { date -u +%Y-%m-%dT%H:%M:%S.000Z; }
future_iso() { date -u -d "+1 hour" +%Y-%m-%dT%H:%M:%S.000Z; }

# A heavy packet (>8192 B) so task_weight returns "heavy" and need_capable=1.
pkt="$ISSUES_DIR/test-inst.in"
python3 - <<'PY' >"$pkt"
import sys
s = "Implement the declarative intake-repos reconciler. "
s += "This is a heavy design-and-implementation task requiring a capable seat. " * 200
sys.stdout.write(s)
PY
[[ $(wc -c <"$pkt") -ge 8192 ]] || fail "packet must be >=8192 B for heavy weight"

inst="test-inst"

# --- invariant 1: all seats walled + pre-tried -> exit 1 AND tried_file reset -
# Wall both seats with a future usable_at, and pre-populate the tried file with
# both — the exact state of fleet-ops-32 at 21:18Z (every capable seat tried,
# all failed, list never cleared).
obs=$(now_iso); usable=$(future_iso)
write_ledger devin glm-5-2 rate_limited "$usable" "$obs"
write_ledger devin swe-1-7 rate_limited "$usable" "$obs"

tried="$STATE_DIR/attempts/pi-issue-${inst}.tried-seats"
printf 'devin/glm-5-2\ndevin/swe-1-7\n' >"$tried"
[[ -s "$tried" ]] || fail "precondition: tried_file must be non-empty"

set +e
bash "$repo_root/bin/pi-issue-run" "$inst" >/dev/null 2>&1
rc=$?
set -e

[[ "$rc" == 1 ]] \
  || fail "all seats walled: pi-issue-run exited $rc, expected 1 (no seat available)"
[[ ! -s "$tried" ]] \
  || fail "all seats walled: tried_file was NOT reset (still has $(wc -l <"$tried") line(s)) — the stuck loop is not fixed"
ok "all seats walled -> pi-issue-run exits 1 AND resets tried_file (next restart retries the full pool)"

# --- invariant 2: success path resets the tried file -----------------------
# Un-wall one seat so pick_seat can route to it, and make the pi stub succeed
# with enough output. Pre-populate tried_file with a stale failed seat; after a
# successful run it must be cleared so a future re-trigger starts fresh.
rm -f "$LEDGER"/*
cat >"$PI_BIN" <<'SH'
#!/usr/bin/env bash
echo "PR https://example.com/pr/2 — worked, real output line"
SH
chmod +x "$PI_BIN"

printf 'devin/glm-5-2\n' >"$tried"
[[ -s "$tried" ]] || fail "precondition: tried_file must be non-empty before success run"

set +e
bash "$repo_root/bin/pi-issue-run" "$inst" >/dev/null 2>&1
rc=$?
set -e

[[ "$rc" == 0 ]] \
  || fail "healthy seat + succeeding pi: pi-issue-run exited $rc, expected 0"
[[ ! -s "$tried" ]] \
  || fail "success path: tried_file was NOT reset (still has $(wc -l <"$tried") line(s)) — a re-trigger would start with a stale restricted pool"
ok "success -> pi-issue-run exits 0 AND resets tried_file (future re-trigger starts with the full pool)"

ok "pi-issue-run tried-seats reset: exhausted pool and success both clear the rotation list"
