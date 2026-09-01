#!/usr/bin/env bash
# tests/seat-wall-reset-horizon.test.sh
#
# fleet-ops#2563: seat cline/cline-pass/minimax-m3 was walled for 19 days.
# Live ledger evidence (2026-09-01T14:05:10Z, agent-state/lanes/seats/
# cline__cline-pass_minimax-m3.json):
#
#   { "http_status": 402, "retry_after": 1530000,
#     "usable_at": "2026-09-19T07:05:10.864Z",
#     "consecutive_failure_count": 10, "source": "cli_spawn" }
#
# 1530000s is 17.7 days. It was NOT computed from the failure count: the
# escalating backoff (_escalated_backoff) caps at SPAWN_FAIL_BACKOFF_CAP_S=1h
# and the failure-ceiling park is 24h and needs count >= 20, so with count 6-10
# NOTHING in the fleet bounded the wall — the vendor's own Retry-After was
# honoured verbatim. cline's seat-caps.json row declares
# quota_window: "weekly", so a 19-day wall freezes the seat for nearly three
# whole reset cycles.
#
# The fix (lib/seat-lib.sh) gives the already-declared `quota_window` a second
# consumer instead of adding a new config key:
#   - provider_wall_ceiling_s <provider> -> the reset horizon in seconds
#     (hourly/daily/weekly/monthly; absent -> 0 = no ceiling, legacy behaviour).
#   - mark_seat_quota_bench caps a parsed vendor window at that horizon
#     (write side, bash-written markers).
#   - seat_usable caps an honoured quota_bench bench_until at
#     observed_at + horizon (read side — the live marker was written by the
#     OUT-OF-REPO seat-health extension, which the write-side cap cannot reach;
#     same fence shape as the fleet-ops#2288 transient_fault park).
# The cap is a re-probe cadence, not a claim the quota reset: seat_usable
# fail-opens at the horizon and the probe either works or re-benches.
#
# Invariants:
#   H1  provider_wall_ceiling_s maps weekly -> 604800, daily -> 86400,
#       hourly -> 3600, monthly -> 2678400.
#   H2  a provider with no quota_window -> 0 (no ceiling; legacy behaviour).
#   H3  write side: a 19-day "resets in 19d 2h" text on a weekly provider is
#       benched for at most 604800s (the live regression).
#   H4  write side: a window INSIDE the horizon is untouched.
#   H5  write side: a provider with no quota_window keeps the long window
#       (no ceiling — nothing regresses for unconfigured providers).
#   H6  read side: an extension-written quota_bench ledger with the live
#       19-day bench_until is UNUSABLE now but USABLE once the horizon
#       passes (the wall no longer outlives the reset cycle).
#   H7  read side: a bench_until inside the horizon still holds the seat.
#   H8  read side: no quota_window -> the 19-day wall is honoured verbatim
#       (the cap never fires where it is not configured).
#   H9  the cap never WIDENS a wall.
#
# Runs entirely offline: scratch ledger, scratch state, no network, no systemd.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
seat_lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch="$(mktemp -d -t seat-wall-horizon.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
STATE_DIR="$scratch/state"
mkdir -p "$STATE_DIR/attempts" "$STATE_DIR/active-seats"
LEDGER="$scratch/ledger"
mkdir -p "$LEDGER"
export PI_PACKET_STATE="$STATE_DIR"
export PI_SEAT_HEALTH_LEDGER_DIR="$LEDGER"
export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export SEAT_FAILURE_CEILING_PROM="$scratch/fleet-seat-failure-ceiling.prom"
export XDG_RUNTIME_DIR="$scratch/xdg"
export PI_SEAT_LIB_CHECK_SYSTEMD=0
mkdir -p "$XDG_RUNTIME_DIR"

cat >"$PI_MODELS_JSON" <<'JSON'
{
  "providers": {
    "cline": { "models": [ { "id": "cline-pass/minimax-m3" } ] },
    "nowindow": { "models": [ { "id": "m1" } ] },
    "hourlyp": { "models": [ { "id": "m1" } ] },
    "dailyp": { "models": [ { "id": "m1" } ] },
    "monthlyp": { "models": [ { "id": "m1" } ] }
  }
}
JSON

# cline mirrors the production row: class prepaid-quota, quota_window weekly,
# quota_bench_default_s 604800. `nowindow` is the control (no quota_window).
cat >"$SEAT_CAPS_JSON" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["nowindow"],
  "providers": {
    "cline": {
      "cap": 2,
      "class": "prepaid-quota",
      "quota_window": "weekly",
      "quota_bench_default_s": 604800,
      "models": { "cline-pass/minimax-m3": 2 }
    },
    "nowindow": { "cap": 1, "class": "free", "quota_bench_default_s": 900, "models": { "m1": 1 } },
    "hourlyp": { "cap": 1, "class": "free", "quota_window": "hourly", "models": { "m1": 1 } },
    "dailyp": { "cap": 1, "class": "free", "quota_window": "daily", "models": { "m1": 1 } },
    "monthlyp": { "cap": 1, "class": "free", "quota_window": "monthly", "models": { "m1": 1 } }
  }
}
JSON

# shellcheck disable=SC1091
source "$seat_lib"
load_seat_caps

WEEK=604800

ledger_file() {
    local p="$1" m="$2"
    printf '%s/%s__%s.json' "$LEDGER" \
        "${p//[^A-Za-z0-9._-]/_}" "${m//[^A-Za-z0-9._-]/_}"
}

iso_at() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# ---------------------------------------------------------------- H1 / H2
for pair in "hourlyp 3600" "dailyp 86400" "cline $WEEK" "monthlyp 2678400"; do
    set -- $pair
    got=$(provider_wall_ceiling_s "$1")
    [[ "$got" == "$2" ]] || fail "H1: provider_wall_ceiling_s $1 expected $2, got '$got'"
done
ok "H1 quota_window maps to the reset horizon (hourly/daily/weekly/monthly)"

got=$(provider_wall_ceiling_s nowindow)
[[ "$got" == "0" ]] || fail "H2: provider with no quota_window must have no ceiling, got '$got'"
got=$(provider_wall_ceiling_s does-not-exist)
[[ "$got" == "0" ]] || fail "H2: unknown provider must have no ceiling, got '$got'"
ok "H2 no quota_window -> no ceiling (legacy behaviour preserved)"

# ---------------------------------------------------------------- H3
# The live shape: a vendor-claimed 19-day reset on a weekly-resetting seat.
rm -f "$(ledger_file cline cline-pass/minimax-m3)"
mark_seat_quota_bench cline "cline-pass/minimax-m3" \
    "HTTP 402 quota exhausted: weekly Clinepass limit reached, resets in 19d 2h" \
    >/dev/null 2>&1 || fail "H3: mark_seat_quota_bench returned non-zero"
f=$(ledger_file cline cline-pass/minimax-m3)
[[ -f "$f" ]] || fail "H3: no ledger written at $f"
bu=$(jq -r '.bench_until' "$f")
obs=$(jq -r '.observed_at' "$f")
span=$(( $(date -u -d "$bu" +%s) - $(date -u -d "$obs" +%s) ))
(( span <= WEEK )) || fail "H3: 19d window benched for ${span}s, must be capped at ${WEEK}s"
(( span >= WEEK - 5 )) || fail "H3: expected the window capped AT the horizon (~${WEEK}s), got ${span}s"
ok "H3 write side: 19-day vendor window capped at the weekly reset horizon (${span}s)"

# ---------------------------------------------------------------- H4
rm -f "$f"
mark_seat_quota_bench cline "cline-pass/minimax-m3" \
    "HTTP 429 weekly Clinepass limit reached, resets in 2h 30m" >/dev/null 2>&1 \
    || fail "H4: mark_seat_quota_bench returned non-zero"
bu=$(jq -r '.bench_until' "$f"); obs=$(jq -r '.observed_at' "$f")
span=$(( $(date -u -d "$bu" +%s) - $(date -u -d "$obs" +%s) ))
(( span >= 8995 && span <= 9005 )) || fail "H4: 2h30m window must survive untouched, got ${span}s"
ok "H4 write side: a window inside the horizon is untouched (${span}s)"

# ---------------------------------------------------------------- H5
nf=$(ledger_file nowindow m1)
rm -f "$nf"
mark_seat_quota_bench nowindow m1 \
    "HTTP 429 usage limit reached, resets in 19d 2h" >/dev/null 2>&1 \
    || fail "H5: mark_seat_quota_bench returned non-zero"
bu=$(jq -r '.bench_until' "$nf"); obs=$(jq -r '.observed_at' "$nf")
span=$(( $(date -u -d "$bu" +%s) - $(date -u -d "$obs" +%s) ))
(( span > WEEK )) || fail "H5: unconfigured provider must keep the long window, got ${span}s"
ok "H5 write side: no quota_window -> the long window is kept (${span}s)"

# ---------------------------------------------------------------- H6
# An extension-written marker (the write-side cap cannot reach it): observed
# now, bench_until 19 days out. Held now, released once the horizon passes.
now_s=$(date -u +%s)
write_ext_ledger() {
    local p="$1" m="$2" obs_s="$3" bench_s="$4"
    jq -n --arg p "$p" --arg m "$m" --arg o "$(iso_at "$obs_s")" --arg b "$(iso_at "$bench_s")" \
        '{provider:$p, model:$m, health_class:"quota_bench", seat_dead:false,
          observed_at:$o, usable_at:$b, bench_until:$b, source:"cli_spawn",
          failure_mode:"quota_cap", consecutive_failure_count:6}' \
        >"$(ledger_file "$p" "$m")"
}

write_ext_ledger cline "cline-pass/minimax-m3" "$now_s" $(( now_s + 19 * 86400 ))
if seat_usable cline "cline-pass/minimax-m3" >/dev/null 2>&1; then
    fail "H6: a seat inside the reset horizon must still be unusable"
fi
# Same 19-day wall, but the marker was observed one horizon + 1h ago: the
# capped wall (observed + 1 week) has passed, so the seat must be re-probed.
write_ext_ledger cline "cline-pass/minimax-m3" $(( now_s - WEEK - 3600 )) $(( now_s + 12 * 86400 ))
seat_usable cline "cline-pass/minimax-m3" >/dev/null 2>&1 \
    || fail "H6: past the reset horizon the 19-day wall must fail open (re-probe)"
ok "H6 read side: extension-written 19-day wall held now, released at the horizon"

# ---------------------------------------------------------------- H7
write_ext_ledger cline "cline-pass/minimax-m3" "$now_s" $(( now_s + 3600 ))
if seat_usable cline "cline-pass/minimax-m3" >/dev/null 2>&1; then
    fail "H7: a bench_until inside the horizon must still hold the seat"
fi
ok "H7 read side: a short bench_until still holds the seat"

# ---------------------------------------------------------------- H8
write_ext_ledger nowindow m1 $(( now_s - WEEK - 3600 )) $(( now_s + 12 * 86400 ))
if seat_usable nowindow m1 >/dev/null 2>&1; then
    fail "H8: with no quota_window the 19-day wall must be honoured verbatim"
fi
ok "H8 read side: no quota_window -> long wall honoured verbatim"

# ---------------------------------------------------------------- H9
short=$(iso_at $(( now_s + 60 )))
got=$(_wall_capped_at_horizon cline "$(iso_at "$now_s")" "$short")
[[ "$got" == "$short" ]] || fail "H9: cap widened a short wall ($short -> $got)"
got=$(_wall_capped_at_horizon cline "" "$short")
[[ "$got" == "$short" ]] || fail "H9: empty anchor must not widen a short wall (got $got)"
got=$(_wall_capped_at_horizon cline "$(iso_at "$now_s")" "not-a-timestamp")
[[ "$got" == "not-a-timestamp" ]] || fail "H9: unparseable wall must be echoed unchanged (got $got)"
ok "H9 the cap never widens a wall and is defensive on bad input"

echo "ALL OK: seat wall reset-horizon cap (fleet-ops#2563)"
