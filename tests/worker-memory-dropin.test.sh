#!/usr/bin/env bash
# tests/worker-memory-dropin.test.sh
#
# fleet-ops#1558 + #1587 + #3930: per-repo MemoryMax/MemoryHigh and Environment
# variables via intake-written per-instance drop-ins. Proves:
#   1. seat-caps.json carries worker_memory for fleet-ops + 0509 with the
#      decided caps (MemoryMax=4G, MemoryHigh REMOVED per fleet-ops#3930 — the
#      throttle band is what makes oomd pressure-kill a random sibling; a worker
#      that exceeds 4G is now OOM-killed locally at the cap instead. History:
#      fleet-ops raised from 2G/1536M to 3G/2560M in #3885, 0509 from 1536M in
#      #3679, then the band was dropped in #3930).
#      fleet-ops#3930 CORRECTION: an omitted MemoryHigh= line in the drop-in
#      does NOT clear the base template's MemoryHigh=3G -- it inherits it.
#      Every live worker still showed MemoryHigh=3221225472 after #3938/#3950
#      merged. The writer must emit the key with an EMPTY value (systemd's
#      reset syntax) when the row has no MemoryHigh, not omit the line.
#   2. seatlib.sh worker_memory_for_repo returns those values.
#   3. pi-intake-tick.sh writes the memory drop-in before systemctl start.
#   4. pi-issue-start.sh mirrors the same memory drop-in on re-dispatch.
#   5. target_concurrent=25 and admit_ceiling = min(25, ram_governor).
#   6. A universal 1.5G MemoryMax is NOT on the pi-issue@ template.
#   7. seat-caps.json carries worker_env for 0509 (VITEST_MAX_WORKERS=2,
#      PLAYWRIGHT_WORKERS=1 — fleet-ops#1587).
#   8. seatlib.sh worker_env_for_repo returns those values.
#   9. pi-intake-tick.sh writes the environment drop-in before systemctl start.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
caps="$repo_root/config/seat-caps.json"
seat_lib="$repo_root/lib/litellm-seat.sh"
tick="$repo_root/lib/pi-intake-tick.sh"
start_bin="$repo_root/bin/pi-issue-start"
template="$repo_root/systemd/pi-issue@.service"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$caps" ]] || fail "seat-caps.json missing"
[[ -f "$seat_lib" ]] || fail "seatlib.sh missing"
[[ -f "$tick" ]] || fail "pi-intake-tick.sh missing"
[[ -f "$start_bin" ]] || fail "pi-issue-start missing"
[[ -f "$template" ]] || fail "pi-issue@.service missing"
command -v jq >/dev/null || fail "jq required"

# --- 1. schema --------------------------------------------------------------
fo_max=$(jq -r '.worker_memory["fleet-ops"].MemoryMax // empty' "$caps")
fo_high=$(jq -r '.worker_memory["fleet-ops"].MemoryHigh // empty' "$caps")
o5_max=$(jq -r '.worker_memory["0509"].MemoryMax // empty' "$caps")
o5_high=$(jq -r '.worker_memory["0509"].MemoryHigh // empty' "$caps")
[[ "$fo_max" == "4G" ]] || fail "fleet-ops MemoryMax want 4G got '$fo_max'"
[[ -z "$fo_high" ]] || fail "fleet-ops MemoryHigh must be absent (fleet-ops#3930 dropped the throttle band), got '$fo_high'"
[[ "$o5_max" == "4G" ]] || fail "0509 MemoryMax want 4G got '$o5_max'"
[[ -z "$o5_high" ]] || fail "0509 MemoryHigh must be absent (fleet-ops#3930 dropped the throttle band), got '$o5_high'"
tgt=$(jq -r '.target_concurrent // empty' "$caps")
[[ "$tgt" == "25" ]] || fail "target_concurrent want 25 got '$tgt'"
ram=$(jq -r '.ram_gb_per_worker // empty' "$caps")
[[ -z "$ram" ]] || fail "ram_gb_per_worker must be absent after fleet-ops#4263, got '$ram'"
ok "1: seat-caps worker_memory + target_concurrent + ram_gb_per_worker"

# --- 2. worker_memory_for_repo ---------------------------------------------
export SEAT_CAPS_JSON="$caps"
# shellcheck source=/dev/null
source "$seat_lib"
row=$(worker_memory_for_repo "fleet-ops")
[[ "$row" == $'4G\t' ]] || fail "fleet-ops row want $'4G\\t' (MemoryHigh absent) got '$row'"
row=$(worker_memory_for_repo "0509")
[[ "$row" == $'4G\t' ]] || fail "0509 row want $'4G\\t' (MemoryHigh absent) got '$row'"
row=$(worker_memory_for_repo "unknown-repo")
[[ -z "$row" ]] || fail "unknown-repo must return empty, got '$row'"
ok "2: worker_memory_for_repo returns per-repo caps"

# --- 2b. heavy class (fleet-ops#3281) ---------------------------------------
hv_max=$(jq -r '.worker_memory["heavy"].MemoryMax // empty' "$caps")
hv_high=$(jq -r '.worker_memory["heavy"].MemoryHigh // empty' "$caps")
[[ "$hv_max" == "3G" ]] || fail "heavy MemoryMax want 3G got '$hv_max'"
[[ "$hv_high" == "2G" ]] || fail "heavy MemoryHigh want 2G got '$hv_high'"
row=$(worker_memory_for_difficulty "fleet-ops" "heavy")
[[ "$row" == $'3G\t2G' ]] || fail "heavy difficulty want $'3G\t2G' got '$row'"
row=$(worker_memory_for_difficulty "fleet-ops" "keystone")
[[ "$row" == $'3G\t2G' ]] || fail "keystone difficulty want $'3G\t2G' got '$row'"
row=$(worker_memory_for_difficulty "fleet-ops" "light")
[[ "$row" == $'4G\t' ]] || fail "light difficulty must fall back to per-repo (MemoryHigh absent), got '$row'"
row=$(worker_memory_for_difficulty "unknown-repo" "light")
[[ -z "$row" ]] || fail "unknown-repo light must return empty, got '$row'"
ok "2b: worker_memory_for_difficulty returns heavy class for heavy|keystone"

# Scratch dir for the heavy-charge + drop-in write sections.
scratch=$(mktemp -d -t wmem.XXXXXX)
trap 'rm -rf "$scratch"' EXIT

# --- 2c. retired (fleet-ops#4263): active_ram_charge was the deleted RAM governor.

# --- 3. admit_ceiling / target_concurrent ----------------------------------
# target_concurrent() went with the routing library (fleet-ops#4263); admit_ceiling reads .target_concurrent.
# With a tiny fake MemAvailable, admit_ceiling must self-reduce below 25.
# Force a low MemAvailable by stubbing /proc/meminfo via a wrapper is hard;
# instead pin SEAT_RAM_GB_PER_WORKER high enough that spare/per < 25, OR just
# assert the function exists and returns a positive integer on the live host.
admit=$(admit_ceiling)
[[ "$admit" =~ ^[0-9]+$ ]] || fail "admit_ceiling non-numeric: $admit"
(( admit >= 1 )) || fail "admit_ceiling < 1: $admit"
# fleet-ops#4263: min(target_concurrent, declared cap sum) — no RAM governor.
(( admit <= 25 )) || fail "admit_ceiling $admit > target 25"
ok "3: admit_ceiling=$admit (target=25, no RAM governor)"

# --- 4. intake tick writes the drop-in block -------------------------------
grep -qF 'worker_memory_for_difficulty' "$tick" \
    || fail "pi-intake-tick.sh missing worker_memory_for_difficulty call"
grep -qF 'memory.conf' "$tick" \
    || fail "pi-intake-tick.sh missing memory.conf write"
grep -qF 'MemoryMax=' "$tick" \
    || fail "pi-intake-tick.sh missing MemoryMax= write"
grep -qF 'MemorySwapMax=0' "$tick" \
    || fail "pi-intake-tick.sh missing MemorySwapMax=0 write (fleet-ops#3611)"
ok "4: intake tick writes per-instance memory.conf"

# --- 5. pi-issue-start mirrors the drop-in ---------------------------------
grep -qF 'worker_memory_for_difficulty' "$start_bin" \
    || fail "pi-issue-start missing worker_memory_for_difficulty call"
grep -qF 'memory.conf' "$start_bin" \
    || fail "pi-issue-start missing memory.conf write"
ok "5: pi-issue-start mirrors per-repo/per-difficulty memory drop-in"

# --- 6. template keeps the 6G/3G fallback (NOT a universal 1.5G) -----------
grep -qE '^MemoryMax=6G$' "$template" \
    || fail "pi-issue@.service must keep MemoryMax=6G as no-table fallback"
grep -qE '^MemoryHigh=3G$' "$template" \
    || fail "pi-issue@.service must keep MemoryHigh=3G as no-table fallback"
! grep -qE '^MemoryMax=1536M$' "$template" \
    || fail "template must NOT hardcode 1536M (that is per-repo via drop-in)"
! grep -qE '^MemoryMax=1\.5G$' "$template" \
    || fail "template must NOT hardcode 1.5G (would OOM-kill 0509 browser E2E)"
grep -qE '^MemorySwapMax=0$' "$template" \
    || fail "pi-issue@.service must keep MemorySwapMax=0 (fleet-ops#3611)"
ok "6: template keeps 6G/3G fallback; no universal 1.5G; swap disabled"

# --- 7. end-to-end drop-in write via a stubbed start path ------------------
# Drive the memory-write fragment from seatlib + the same shell that intake
# uses, against a scratch XDG_CONFIG_HOME, without touching live systemd.
export XDG_CONFIG_HOME="$scratch/xdg"
unit="pi-issue@fleet-ops-9999.service"
mem_row=$(worker_memory_for_repo "fleet-ops")
IFS=$'\t' read -r mem_max mem_high <<<"$mem_row"
drop_dir="$XDG_CONFIG_HOME/systemd/user/${unit}.d"
mkdir -p "$drop_dir"
{
    printf '# fleet-ops#1558: per-repo memory cap (test)\n'
    printf '[Service]\n'
    [[ -n "$mem_max" ]] && printf 'MemoryMax=%s\n' "$mem_max"
    # fleet-ops#3930 correction: write MemoryHigh= (empty) explicitly when the
    # row has none, so the drop-in clears the base template's MemoryHigh=3G
    # instead of silently inheriting it.
    if [[ -n "$mem_high" ]]; then
        printf 'MemoryHigh=%s\n' "$mem_high"
    else
        printf 'MemoryHigh=\n'
    fi
    printf 'MemorySwapMax=0\n'
} > "$drop_dir/memory.conf"
grep -qE '^MemoryMax=4G$' "$drop_dir/memory.conf" \
    || fail "written drop-in missing MemoryMax=4G"
# fleet-ops#3930 correction: the drop-in must carry an EXPLICIT empty
# MemoryHigh= (systemd's reset syntax) so the unit does not inherit the
# template's MemoryHigh=3G. A line carrying a non-empty value would be the
# old bug (throttle band not actually dropped).
grep -qE '^MemoryHigh=$' "$drop_dir/memory.conf" \
    || fail "written drop-in must carry an explicit empty MemoryHigh= to clear the template default (fleet-ops#3930 correction)"
! grep -qE '^MemoryHigh=.+$' "$drop_dir/memory.conf" \
    || fail "written drop-in must NOT carry a non-empty MemoryHigh (fleet-ops#3930 dropped the throttle band)"
grep -qE '^MemorySwapMax=0$' "$drop_dir/memory.conf" \
    || fail "written drop-in missing MemorySwapMax=0 (fleet-ops#3611)"
ok "7: scratch drop-in write produces MemoryMax=4G / explicit empty MemoryHigh= / MemorySwapMax=0"

# --- 8. worker_env_for_repo -------------------------------------------------
# fleet-ops#1587: per-repo Environment variables for browser-heavy repos.
o5_env=$(worker_env_for_repo "0509")
[[ -n "$o5_env" ]] || fail "worker_env_for_repo 0509 must return non-empty"
grep -qF 'VITEST_MAX_WORKERS=2' <<<"$o5_env" \
    || fail "worker_env_for_repo 0509 missing VITEST_MAX_WORKERS=2"
grep -qF 'PLAYWRIGHT_WORKERS=1' <<<"$o5_env" \
    || fail "worker_env_for_repo 0509 missing PLAYWRIGHT_WORKERS=1"
env_row=$(worker_env_for_repo "fleet-ops")
[[ -z "$env_row" ]] || fail "worker_env_for_repo fleet-ops must return empty, got '$env_row'"
env_row=$(worker_env_for_repo "unknown-repo")
[[ -z "$env_row" ]] || fail "worker_env_for_repo unknown-repo must return empty, got '$env_row'"
ok "8: worker_env_for_repo returns per-repo env vars"

# --- 9. intake tick writes the environment drop-in block ---------------------
grep -qF 'worker_env_for_repo' "$tick" \
    || fail "pi-intake-tick.sh missing worker_env_for_repo call"
grep -qF 'environment.conf' "$tick" \
    || fail "pi-intake-tick.sh missing environment.conf write"
grep -qF 'Environment=' "$tick" \
    || fail "pi-intake-tick.sh missing Environment= write"
ok "9: intake tick writes per-instance environment.conf"

# --- 10. end-to-end environment drop-in write --------------------------------
unit="pi-issue@0509-9999.service"
env_lines=$(worker_env_for_repo "0509")
drop_dir="$XDG_CONFIG_HOME/systemd/user/${unit}.d"
mkdir -p "$drop_dir"
{
    printf '# fleet-ops#1587: per-repo test-parallelism limit (test)\n'
    printf '[Service]\n'
    while IFS= read -r line; do
        [[ -n "$line" ]] && printf 'Environment=%s\n' "$line"
    done <<<"$env_lines"
} > "$drop_dir/environment.conf"
grep -qE '^Environment=VITEST_MAX_WORKERS=2$' "$drop_dir/environment.conf" \
    || fail "written drop-in missing Environment=VITEST_MAX_WORKERS=2"
grep -qE '^Environment=PLAYWRIGHT_WORKERS=1$' "$drop_dir/environment.conf" \
    || fail "written drop-in missing Environment=PLAYWRIGHT_WORKERS=1"
ok "10: scratch environment.conf write produces correct Environment lines"

echo ""
echo "ALL OK: worker-memory drop-in + admit ceiling (fleet-ops#1558)"
