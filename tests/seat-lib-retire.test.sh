#!/usr/bin/env bash
# tests/seat-lib-retire.test.sh
#
# fleet-ops#3669: corpse retirement must leave the seat UNPICKABLE. The
# corpse-retirement caller (bin/fleet-seat-comeback-release) physically MOVES
# a terminal corpse ledger out of the live roster into a dated
# seats-corpse-retired-<UTC-ts>/ audit dir. Before this fix the move left NO
# ledger in the live roster, so seat_usable fell through to the
# "NO HEALTH DATA (no ledger file) — assuming usable" fail-open and pick_seat
# re-picked the deliberately-retired dead seat (hetzner burned 2 claims in
# 6 min, 2026-09-05).
#
# Two fences now keep a retired seat off the ladder:
#   (a) write_parked_ledger leaves a seat_dead=true / health_class=parked /
#       usable_at far-future ledger in the live roster (the retire caller
#       reuses it);
#   (b) seat_usable's no-ledger fail-open refuses a seat that has a
#       corpse-retired copy from the last 7 days (the read-side fence for
#       seats retired before the writer existed).
#
# What we prove:
#   1. ledger at count>=20 -> retire (move + write_parked_ledger) ->
#      pick_seat refuses the seat (rc=1, NO USABLE SEAT, log names the park).
#   2. a parked ledger makes seat_usable UNUSABLE with a log line naming the
#      park.
#   3. a seat with no ledger and no corpse copy is still assumed usable
#      (the fail-open contract is intact).
#   4. a seat with no live ledger but a corpse-retired copy from the last
#      7 days is UNUSABLE (read-side fence).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "seat-lib.sh not found: $lib"
command -v jq >/dev/null || fail "jq required"

scratch="$(mktemp -d -t seat-lib-retire.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export PI_SEAT_LIB_CHECK_SYSTEMD=0
export PI_SEAT_NOUSABLE_COOLDOWN_S=0

# A single free seat so pick_seat's verdict is unambiguous: either it picks
# hetzner/Qwen/Qwen3.6-35B-A3B-FP8 or it stalls (rc=1, NO USABLE SEAT).
cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "hetzner": {
      "models": [
        { "id": "Qwen/Qwen3.6-35B-A3B-FP8", "cost": { "input": 0 } }
      ]
    }
  }
}
JSON

cat >"$scratch/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["hetzner"],
  "providers": {
    "hetzner": { "cap": 1, "class": "free", "models": { "Qwen/Qwen3.6-35B-A3B-FP8": 1 } }
  }
}
JSON

export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export QUALITY_SCOREBOARD_JSON="$scratch/no-quality-scoreboard.json"
export QUALITY_ROUTING_JSON="$scratch/no-quality-routing.json"

# --- 1. no ledger + no corpse copy -> still assumed usable (fail-open) -----
ledger="$scratch/live-clean"
mkdir -p "$ledger"
export PI_PACKET_STATE="$scratch/state-clean"
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger"
# seat_usable directly: no ledger + no corpse copy -> usable (0).
set +e
out=$(bash -c 'source "$0"; seat_usable "hetzner" "Qwen/Qwen3.6-35B-A3B-FP8"' "$lib" 2>&1)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "clean: seat_usable must be usable (no ledger, no corpse copy), got rc=$rc"
grep -q "NO HEALTH DATA" <<<"$out" \
  || fail "clean: no-ledger seat must log the NO HEALTH DATA fail-open line, got: $out"
# pick_seat end-to-end: it picks the seat.
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "clean: expected a pick (no ledger, no corpse copy), got rc=$rc"
echo "$out" | grep -q "hetzner" || fail "clean: expected hetzner pick, got: $out"
ok "1: no ledger + no corpse copy still assumed usable (fail-open intact)"

# --- 2. ledger at count>=20 -> retire -> pick_seat refuses (log names park) --
ledger="$scratch/live-retired"
mkdir -p "$ledger"
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger"
# A transient_fault ledger past the failure ceiling (count=24 >= 20).
cat > "$ledger/hetzner__Qwen_Qwen3.6-35B-A3B-FP8.json" << 'EOF'
{"provider":"hetzner","model":"Qwen/Qwen3.6-35B-A3B-FP8","http_status":503,"retry_after":null,"health_class":"transient_fault","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-09-05T14:47:00Z","source":"after_provider_response","failure_mode":"overload_bench","usable_at":null,"consecutive_failure_count":24}
EOF
# Retire exactly as bin/fleet-seat-comeback-release does: move the corpse
# ledger into a dated audit dir, then write a parked ledger in the live
# roster via the shared writer.
retdir="$scratch/seats-corpse-retired-$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$retdir"
mv "$ledger/hetzner__Qwen_Qwen3.6-35B-A3B-FP8.json" "$retdir/"
export PI_PACKET_STATE="$scratch/state-retired"
bash -c 'source "$0"; write_parked_ledger "hetzner" "Qwen/Qwen3.6-35B-A3B-FP8" "corpse-retired"' "$lib" >/dev/null 2>&1
[[ -f "$ledger/hetzner__Qwen_Qwen3.6-35B-A3B-FP8.json" ]] \
  || fail "retired: write_parked_ledger must leave a parked ledger in the live roster"
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "retired: pick_seat must refuse the retired seat (rc=1), got rc=$rc"
[[ -z "$out" ]] || fail "retired: pick_seat must print nothing, got: $out"
grep -q "NO USABLE SEAT" "$PI_PACKET_STATE/watch.log" \
  || fail "retired: must log the loud NO USABLE SEAT line"
grep -q "parked" "$PI_PACKET_STATE/watch.log" \
  || fail "retired: log must name the park (health_class=parked)"
ok "2: ledger at count>=20 -> retire -> pick_seat refuses the seat (log names the park)"

# --- 3. parked ledger -> seat_usable UNUSABLE, log names the park ---------
ledger="$scratch/live-parked"
mkdir -p "$ledger"
export PI_PACKET_STATE="$scratch/state-parked"
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger"
set +e
out=$(bash -c 'source "$0"; write_parked_ledger "hetzner" "Qwen/Qwen3.6-35B-A3B-FP8" "corpse-retired"; seat_usable "hetzner" "Qwen/Qwen3.6-35B-A3B-FP8"' "$lib" 2>&1)
rc=$?
set -e
[[ "$rc" != "0" ]] || fail "parked: seat_usable must be UNUSABLE for a parked ledger, got rc=$rc"
grep -q "UNUSABLE" <<<"$out" || fail "parked: seat_usable must log an UNUSABLE line, got: $out"
grep -q "parked" <<<"$out" || fail "parked: seat_usable log must name the park, got: $out"
ok "3: parked ledger -> seat_usable UNUSABLE (log names the park)"

# --- 4. corpse-retired copy within 7 days, no live ledger -> UNUSABLE ------
# The read-side fence: a seat whose corpse ledger was moved away (retired
# before write_parked_ledger existed) must not fall through to the fail-open.
ledger="$scratch/live-fence"
mkdir -p "$ledger"
fence_dir="$scratch/seats-corpse-retired-$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$fence_dir"
cat > "$fence_dir/hetzner__Qwen_Qwen3.6-35B-A3B-FP8.json" << 'EOF'
{"provider":"hetzner","model":"Qwen/Qwen3.6-35B-A3B-FP8","http_status":503,"retry_after":null,"health_class":"corpse","retryable":false,"seat_dead":true,"poison_ladder":false,"observed_at":"2026-09-05T14:47:00Z","source":"after_provider_response","failure_mode":"overload_bench","usable_at":null,"consecutive_failure_count":24}
EOF
export PI_PACKET_STATE="$scratch/state-fence"
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger"
set +e
out=$(bash -c 'source "$0"; seat_usable "hetzner" "Qwen/Qwen3.6-35B-A3B-FP8"' "$lib" 2>&1)
rc=$?
set -e
[[ "$rc" != "0" ]] || fail "fence: corpse-retired copy within 7 days must be UNUSABLE, got rc=$rc"
grep -q "corpse-retired" <<<"$out" || fail "fence: log must name the corpse-retired copy, got: $out"
ok "4: corpse-retired copy within 7 days keeps the seat UNPICKABLE (no fail-open)"
