#!/usr/bin/env bash
# tests/pi-intake-tick-spawn-stagger.test.sh
#
# fleet-ops#3784: systemd-oomd kills pi-issue@ units in bursts at tick time
# because a cohort of 6-9 units starts together and their clone+npm+pi
# startup peaks overlap, spiking app-pi-issue.slice to ~12.5 GB (78% of
# 16 GB) and tripping oomd's 80% PSI for >1min. The durable fix is a
# config value `spawn_stagger_s` that sleeps a few seconds between
# `systemctl start --no-block` calls so startup peaks do not coincide.
#
# Proves:
#   1. config/seat-caps.json carries spawn_stagger_s as a non-negative int.
#   2. load_seat_caps() loads it into SEAT_SPAWN_STAGGER_S (default 0).
#   3. lib/pi-intake-tick.sh applies the stagger: a sleep of
#      SEAT_SPAWN_STAGGER_S after a verified `claimed+spawned`.
#   4. The tick sources seatlib.sh so SEAT_SPAWN_STAGGER_S is in scope.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
caps="$repo_root/config/seat-caps.json"
seat_lib="$repo_root/lib/litellm-seat.sh"
tick="$repo_root/lib/pi-intake-tick.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$caps" ]] || fail "seat-caps.json missing"
[[ -f "$seat_lib" ]] || fail "seatlib.sh missing"
[[ -f "$tick" ]] || fail "pi-intake-tick.sh missing"
command -v jq >/dev/null || fail "jq required"

# --- 1. config carries spawn_stagger_s as a non-negative int ----------------
stagger_cfg=$(jq -r '.spawn_stagger_s // empty' "$caps")
[[ -n "$stagger_cfg" ]] || fail "seat-caps.json must carry spawn_stagger_s (fleet-ops#3784)"
[[ "$stagger_cfg" =~ ^[0-9]+$ ]] || fail "spawn_stagger_s must be a non-negative int, got '$stagger_cfg'"
ok "1: seat-caps.json spawn_stagger_s=$stagger_cfg (non-negative int)"

# --- 2. load_seat_caps loads it into SEAT_SPAWN_STAGGER_S -------------------
# Source the lib in a subshell with the repo caps file and read the loaded
# value. Default must be 0 when the key is absent.
loaded=$(SEAT_CAPS_JSON="$caps" bash -c 'source "$0"; _seat_caps_loaded=0; load_seat_caps; echo "$SEAT_SPAWN_STAGGER_S"' "$seat_lib")
[[ "$loaded" == "$stagger_cfg" ]] || fail "load_seat_caps SEAT_SPAWN_STAGGER_S want '$stagger_cfg' got '$loaded'"
ok "2: load_seat_caps loads SEAT_SPAWN_STAGGER_S=$loaded"

# Default 0 when the key is absent (a caps file without the key must not
# stagger). Write a scratch caps file without spawn_stagger_s.
scratch="$(mktemp -d -t spawn-stagger-test.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
jq 'del(.spawn_stagger_s)' "$caps" > "$scratch/no-stagger.json"
default=$(SEAT_CAPS_JSON="$scratch/no-stagger.json" bash -c 'source "$0"; _seat_caps_loaded=0; load_seat_caps; echo "$SEAT_SPAWN_STAGGER_S"' "$seat_lib")
[[ "$default" == "0" ]] || fail "SEAT_SPAWN_STAGGER_S default want 0 got '$default'"
ok "2b: SEAT_SPAWN_STAGGER_S defaults to 0 when spawn_stagger_s absent"

# --- 3. tick applies the stagger after a verified spawn ---------------------
grep -qF 'claimed+spawned' "$tick" \
    || fail "tick must log claimed+spawned"
grep -qF 'SEAT_SPAWN_STAGGER_S > 0' "$tick" \
    || fail "tick must gate the stagger on SEAT_SPAWN_STAGGER_S > 0"
grep -qF 'sleep "$SEAT_SPAWN_STAGGER_S"' "$tick" \
    || fail "tick must sleep SEAT_SPAWN_STAGGER_S between spawns"
# The sleep must come AFTER the claimed+spawned echo (i.e. after a verified
# spawn), not before it — so a skipped issue never sleeps.
spawn_line=$(grep -nF 'claimed+spawned' "$tick" | head -1 | cut -d: -f1)
sleep_line=$(grep -nF 'sleep "$SEAT_SPAWN_STAGGER_S"' "$tick" | head -1 | cut -d: -f1)
(( sleep_line > spawn_line )) || fail "stagger sleep (line $sleep_line) must come after claimed+spawned (line $spawn_line)"
ok "3: tick sleeps SEAT_SPAWN_STAGGER_S after a verified spawn (sleep line $sleep_line > spawn line $spawn_line)"

# --- 4. tick sources seatlib.sh so the variable is in scope ----------------
grep -qE '^\. "\$SEAT_LIB"|^\. "\$seat_lib"|source .*seatlib' "$tick" \
    || fail "tick must source seatlib.sh (SEAT_SPAWN_STAGGER_S scope)"
ok "4: tick sources seatlib.sh (SEAT_SPAWN_STAGGER_S in scope)"

# --- 5. parent-shell load so SEAT_SPAWN_STAGGER_S reaches the claim loop ----
# fleet-ops#3861: a load inside $() dies with the subshell. Every seat-state
# read call site in the tick is a command substitution, so the configured
# spawn_stagger_s silently fell back to the default 0 and the cohort
# stagger #3784 targeted was inert. At least one BARE (non-subshell)
# load_seat_caps statement must exist in the tick's parent shell BEFORE the
# stagger sleep line, so SEAT_SPAWN_STAGGER_S is in scope when the claim
# actually sleeps.
parent_load=$(grep -nE '^[[:space:]]*load_seat_caps([[:space:]]|\|)' "$tick" | head -1 | cut -d: -f1)
[[ -n "$parent_load" ]] \
    || fail "tick must call load_seat_caps in the PARENT shell (a bare statement, not a \$() subshell) — fleet-ops#3861"
sleep_line2=$(grep -nF 'sleep "$SEAT_SPAWN_STAGGER_S"' "$tick" | head -1 | cut -d: -f1)
(( parent_load < sleep_line2 )) \
    || fail "parent load_seat_caps (line $parent_load) must precede the stagger sleep (line $sleep_line2)"
ok "5: tick loads caps in the parent shell (line $parent_load) before the stagger sleep (line $sleep_line2)"

# --- 6. tick logs the stagger value actually slept --------------------------
# fleet-ops#3861: "verify with a claim tick that logs the stagger value
# actually slept" — the stagger must be observable in the tick output, not
# just slept silently.
grep -qF 'spawn stagger ${SEAT_SPAWN_STAGGER_S}s' "$tick" \
    || fail "tick must log the SEAT_SPAWN_STAGGER_S value it sleeps (fleet-ops#3861)"
ok "6: tick logs the stagger value it sleeps"

echo
echo "ALL OK: pi-intake-tick spawn stagger (fleet-ops#3784)"
