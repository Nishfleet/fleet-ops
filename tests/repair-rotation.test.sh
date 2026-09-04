#!/usr/bin/env bash
# tests/repair-rotation.test.sh
#
# Proves the mechanical core of the intake/scout repair rotation (#27):
# when the hardcoded tick seat (minimax/MiniMax-M3) is walled by a 429 / quota,
# pick_seat returns a DIFFERENT usable seat so the repair agent can re-run the
# tick on it instead of leaving the unit failed.
#
# fleet-ops#3324 (PR #3371) changed the all-walled path: a recoverable bench
# (rate_limited / transient_fault / empty_run / overload_bench) is fail-opened
# onto the shortest remaining untried seat instead of stalling. Empty + exit 1
# is now the money-wall signal (402 / quota_exhausted / corpse /
# credentials_bad), which is what the repair prompts treat as genuine
# escalation. This test locked the pre-#3324 stall and redded main the moment
# #3371 landed (P14 "all seats walled: pick_seat returned 0, expected 1").
#
# Runs entirely offline: stubbed models.json, seat-caps.json, and ledger dir.
# No pi, no systemd, no network.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# --- scratch environment --------------------------------------------------
scratch="$(mktemp -d -t repair-rotation.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
export HOME="$scratch/home"
mkdir -p "$HOME"

STATE_DIR="$scratch/state"
mkdir -p "$STATE_DIR/attempts" "$STATE_DIR/active-seats"
LEDGER="$scratch/ledger"
mkdir -p "$LEDGER"

export PI_PACKET_STATE="$STATE_DIR"
export PI_SEAT_HEALTH_LEDGER_DIR="$LEDGER"
export PI_BIN="$scratch/pi-stub"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export PI_MODELS_JSON="$scratch/models.json"
export PI_SEAT_NOUSABLE_COOLDOWN_S=0
export PI_SEAT_CREDENTIAL_PRECHECK=0
export PI_SEAT_LIB_CHECK_SYSTEMD=0

# --- stub inputs ----------------------------------------------------------
# A minimal models.json with two providers: the walled metered seat and a
# healthy subscription seat. enumerate_seats reads .providers[].models[].
cat >"$PI_MODELS_JSON" <<'JSON'
{
  "providers": {
    "minimax": {
      "models": [
        { "id": "MiniMax-M3", "cost": { "input": 0.30 }, "reasoning": false, "contextWindow": 200000 }
      ]
    },
    "devin": {
      "models": [
        { "id": "swe-1-7", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 }
      ]
    }
  }
}
JSON

# Cap map: minimax is metered (tried last), devin is subscription (tried first).
cat >"$SEAT_CAPS_JSON" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": [],
  "providers": {
    "devin":    { "cap": 4, "class": "subscription", "models": { "swe-1-7": 4 } },
    "minimax":  { "cap": 2, "class": "metered",      "models": { "MiniMax-M3": 2 } }
  }
}
JSON

# A no-op pi stub (never invoked by pick_seat, but seat-lib references PI_BIN).
: >"$PI_BIN"; chmod +x "$PI_BIN"

# --- helper: write a per-seat health ledger entry -------------------------
# Mirrors the SeatLedgerEntry shape seat-health.ts writes. $1=provider $2=model
# $3=health_class $4=usable_at(ISO|empty) $5=observed_at(ISO|empty)
write_ledger() {
  local p="$1" m="$2" hc="$3" usable="$4" observed="$5"
  local f
  f=$(printf '%s/%s__%s.json\n' "$LEDGER" "${p//[^A-Za-z0-9._-]/_}" "${m//[^A-Za-z0-9._-]/_}")
  jq -n \
    --arg p "$p" --arg m "$m" \
    --arg hc "$hc" \
    --arg usable "$usable" \
    --arg observed "$observed" \
    '{provider:$p, model:$m, http_status:429, retry_after:null,
      health_class:$hc, retryable:true, seat_dead:false, poison_ladder:false,
      observed_at:$observed, source:"provider_fetch", usable_at:$usable}' >"$f"
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%S.000Z; }
future_iso() { date -u -d "+1 hour" +%Y-%m-%dT%H:%M:%S.000Z; }

# --- source the real seat-lib (the install symlink target) ----------------
SEAT_LIB="$repo_root/lib/seat-lib.sh"
[[ -f "$SEAT_LIB" ]] || fail "seat-lib.sh not found: $SEAT_LIB"
# shellcheck source=../lib/seat-lib.sh
source "$SEAT_LIB"

# --- invariant 1: walled minimax -> pick_seat rotates to devin -------------
# Mark minimax/MiniMax-M3 as rate_limited with a fresh observed_at and a
# usable_at one hour in the future — exactly the 429 quota wall from #27.
obs=$(now_iso); usable=$(future_iso)
write_ledger minimax MiniMax-M3 rate_limited "$usable" "$obs"

# The repair prompt excludes the walled seat by passing it as the failed pair
# AND as a one-line tried file. Reproduce that exact call.
tried="$STATE_DIR/tried-walled"
printf 'minimax/MiniMax-M3\n' >"$tried"

set +e
seat=$(pick_seat minimax MiniMax-M3 0 "$tried")
rc=$?
set -e
[[ "$rc" == 0 ]] || fail "pick_seat returned $rc with a healthy devin seat available — expected rotation, got no seat"
[[ -n "$seat" ]] || fail "pick_seat returned empty with a healthy devin seat available — expected rotation"

np=$(printf '%s' "$seat" | cut -f1)
nm=$(printf '%s' "$seat" | cut -f2)
[[ "$np" != "minimax" || "$nm" != "MiniMax-M3" ]] \
  || fail "pick_seat returned the walled seat itself ($np/$nm) — rotation did not exclude it"
[[ "$np" == "devin" && "$nm" == "swe-1-7" ]] \
  || fail "pick_seat rotated to $np/$nm, expected devin/swe-1-7 (the only other allowlisted seat)"
ok "walled minimax/MiniMax-M3 -> pick_seat rotated to devin/swe-1-7"

# --- invariant 2: every remaining recoverable bench is fail-opened (#3324) ---
# Wall devin too. Both allowlisted seats are now rate_limited with future
# resets. pick_seat must NOT stall: the floor fail-opens the shortest
# remaining recoverable bench that is not in the tried file. minimax is
# excluded by tried, so the floor returns devin/swe-1-7 and logs the
# seat-floor line. Empty+exit 1 is reserved for a money wall (invariant 2b).
write_ledger devin swe-1-7 rate_limited "$usable" "$obs"

set +e
seat=$(pick_seat minimax MiniMax-M3 0 "$tried" 2>"$STATE_DIR/floor.err")
rc=$?
set -e
[[ "$rc" == 0 ]] || fail "all recoverable benches walled: pick_seat returned $rc, expected 0 (seat-floor fail-open, fleet-ops#3324)"
[[ -n "$seat" ]] || fail "all recoverable benches walled: pick_seat returned empty, expected the shortest remaining recoverable bench"
np=$(printf '%s' "$seat" | cut -f1)
nm=$(printf '%s' "$seat" | cut -f2)
[[ "$np" == "devin" && "$nm" == "swe-1-7" ]] \
  || fail "fail-open returned $np/$nm, expected devin/swe-1-7 (the only untried recoverable bench; minimax is in the tried file)"
grep -q "seat-floor: fail-open devin/swe-1-7" "$STATE_DIR/floor.err" \
  || fail "fail-open must log 'seat-floor: fail-open devin/swe-1-7 (bench had <n>s left)'; err=$(cat "$STATE_DIR/floor.err")"
ok "every recoverable bench walled -> pick_seat fail-opens shortest remaining untried bench (fleet-ops#3324)"

# --- invariant 2b: money wall still stalls (empty + exit 1) -----------------
# Same two-seat ladder, both quota_exhausted. The floor must never lift a
# 402 / quota_exhausted wall — that is the genuine fail-loud escalation
# the repair prompts still route to.
write_ledger minimax MiniMax-M3 quota_exhausted "$usable" "$obs"
write_ledger devin swe-1-7 quota_exhausted "$usable" "$obs"

set +e
seat=$(pick_seat minimax MiniMax-M3 0 "$tried" 2>"$STATE_DIR/money.err")
rc=$?
set -e
[[ "$rc" == 1 ]] || fail "money wall: pick_seat returned $rc, expected 1 (never fail-open a 402)"
[[ -z "$seat" ]] || fail "money wall: pick_seat returned '$seat', expected empty"
grep -q "NO USABLE SEAT" "$STATE_DIR/money.err" \
  || fail "money wall must log NO USABLE SEAT; err=$(cat "$STATE_DIR/money.err")"
grep -q "seat-floor: fail-open" "$STATE_DIR/money.err" \
  && fail "money wall must NOT log seat-floor fail-open; err=$(cat "$STATE_DIR/money.err")"
ok "quota_exhausted money wall still stalls empty + exit 1 (genuine escalation)"

# --- invariant 3: the prompts instruct the agent to use this exact call -----
# Guard against the prompt drift that caused #27 in the first place: the
# repair prompt MUST tell the agent to classify a 429 as a lane fault and
# rotate via pick_seat, never as a billing decision.
for p in prompts/intake-repair.md prompts/scout-repair.md; do
  f="$repo_root/$p"
  [[ -f "$f" ]] || fail "$p missing"
  grep -q 'LANE FAULT, never a billing decision' "$f" \
    || fail "$p must classify a 429 as a LANE FAULT, not a billing decision"
  grep -qi 'pick_seat' "$f" \
    || fail "$p must instruct the agent to rotate via pick_seat"
  grep -qi 'never on the vendor'\''s error prose\|NEVER on the vendor' "$f" \
    || fail "$p must forbid classifying from the vendor error prose"
  grep -qi 'fail LOUD\|fail loud' "$f" \
    || fail "$p must specify the money-wall / unrecoverable case fails loud, not quiet"
  grep -qi 'fail-open\|fleet-ops#3324' "$f" \
    || fail "$p must name the #3324 fail-open so a recoverable 429 is not escalated as empty"
done
ok "intake-repair.md and scout-repair.md classify 429 as a lane fault and rotate"

# --- invariant 4: scout-repair clears a wedged unit before restart ----------
# fleet-ops#3078: a scout whose pi process hung stays in `activating (start)`.
# `systemctl start` on an already-activating unit blocks indefinitely, dead-
# locking the repair unit. The scout-repair prompt MUST check for and stop a
# wedged unit before calling `systemctl start`, and MUST wrap the start in a
# timeout so a future wedge cannot deadlock the repair unit.
f="$repo_root/prompts/scout-repair.md"
grep -qi 'is-active.*pi-scout@' "$f" \
  || fail "scout-repair.md must check is-active before systemctl start (fleet-ops#3078 wedge deadlock)"
grep -qi 'systemctl.*stop.*pi-scout@' "$f" \
  || fail "scout-repair.md must stop a wedged unit before restarting (fleet-ops#3078)"
grep -qi 'timeout.*systemctl.*start.*pi-scout@' "$f" \
  || fail "scout-repair.md must wrap systemctl start in a timeout (fleet-ops#3078 deadlock prevention)"
grep -qi 'activating' "$f" \
  || fail "scout-repair.md must name the activating state as the wedge signal (fleet-ops#3078)"
ok "scout-repair.md clears a wedged unit and wraps start in a timeout (fleet-ops#3078)"

# fleet-ops#138: the intake-repair wrapper also routes through pick_seat.
# The worker GitHub App cannot add a workflow step, so this test rides
# along inside the already-wired repair-rotation job.
bash "$here/pi-intake-repair-run.test.sh"

ok "repair rotation: 429 rotates to a healthy seat; recoverable all-walled fail-opens; money wall fails loud"
