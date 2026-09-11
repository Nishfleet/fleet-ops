#!/usr/bin/env bash
# tests/openrouter-free-retired-corpse.test.sh
#
# fleet-ops#5274: OpenRouter retired the free tier of minimax-m3:free and
# glm-5.2:free. The upstream body is HTTP 404 {"message":"This model is
# unavailable for free. The paid version is available now - use this slug
# instead: ..."} — a PERMANENT retirement (the slug is gone from
# /api/v1/models), but pi-issue-run booked it error_class=unknown, benched
# 300s, and the corpse seat was re-offered every restart (pi-issue@0509-2724
# reclaimed 8 times).
#
# What we prove:
#   1. The REAL config/seat-caps.json corpses both slugs: cap=0 +
#      intentional_cap_zero=corpse + a dated reason quoting the 404 (the
#      issue's jq acceptance).
#   2. The REAL config/seat-caps.json registers the free_retired_corpse
#      error class with matcher is_openrouter_free_retired_error, writer
#      mark_seat_free_retired_corpse, and trigger_order 1 (BEFORE the
#      quota/overload benches).
#   3. The matcher matches the exact live 404 tail (out-channel and
#      err-channel), and rejects: a bare 404 without the phrase, a 503
#      overload body, and a quota body.
#   4. classify_death_error classifies the live tail as
#      openrouter_free_retired (not unknown).
#   5. _dispatch_lane_faults on the live tail fires the corpse writer: the
#      ledger is parked (seat_dead=true, health_class=parked) with
#      last_error_class=openrouter_free_retired and a bench_reason quoting
#      "unavailable for free" — NOT a 300s bench.
#
# Runs entirely offline: stubbed caps/models, hermetic ledger dir, no
# network, no systemd.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/seat-lib.sh"
real_caps="$repo_root/config/seat-caps.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "seat-lib.sh not found: $lib"
[[ -f "$real_caps" ]] || fail "seat-caps.json not found: $real_caps"
command -v jq >/dev/null || fail "jq required"

scratch="$(mktemp -d -t openrouter-retired.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
export SEAT_LIVE_QUOTA_PROM="$scratch/no-live-quota.prom"
export SEAT_LIVE_PREPAID_PROM="$scratch/no-live-prepaid.prom"
export PI_SEAT_LIB_CHECK_SYSTEMD=0

LEDGER="$scratch/ledger"
mkdir -p "$LEDGER"
export PI_SEAT_HEALTH_LEDGER_DIR="$LEDGER"

# --- 1. real caps: both slugs are corpses at cap 0 -------------------------
c1=$(jq -r '.providers.openrouter.models["minimax/minimax-m3:free"].cap' "$real_caps")
c2=$(jq -r '.providers.openrouter.models["z-ai/glm-5.2:free"].cap' "$real_caps")
[[ "$c1" == "0" && "$c2" == "0" ]] \
  || fail "real caps: both retired slugs must be cap 0 (got '$c1' and '$c2')"
for slug in "minimax/minimax-m3:free" "z-ai/glm-5.2:free"; do
    icz=$(jq -r ".providers.openrouter.models[\"$slug\"].intentional_cap_zero" "$real_caps")
    [[ "$icz" == "corpse" ]] || fail "real caps: $slug intentional_cap_zero must be 'corpse', got '$icz'"
    reason=$(jq -r ".providers.openrouter.models[\"$slug\"].reason" "$real_caps")
    grep -q "unavailable for free" <<<"$reason" \
      || fail "real caps: $slug reason must quote the 404 body"
    grep -q "2026-09-11" <<<"$reason" \
      || fail "real caps: $slug reason must be dated (2026-09-11)"
done
ok "real caps: minimax/minimax-m3:free and z-ai/glm-5.2:free are cap-0 corpses with a dated 404 reason"

# Do NOT wire the paid siblings (fleet-ops#545): neither paid slug may gain a
# new paid-class seat row in the same change.
paid1=$(jq -r '.providers.openrouter.models["minimax/minimax-m3"] // empty' "$real_caps")
paid2=$(jq -r '.providers.openrouter.models["z-ai/glm-5.2"] // empty' "$real_caps")
[[ -z "$paid1" && -z "$paid2" ]] \
  || fail "fleet-ops#545: paid siblings must not be wired (got minimax/minimax-m3 and/or z-ai/glm-5.2 rows)"
ok "fleet-ops#545: paid siblings minimax/minimax-m3 and z-ai/glm-5.2 are NOT wired"

# --- 2. real caps: the free_retired_corpse class is registered first -------
m=$(jq -r '.error_classes.free_retired_corpse.matcher' "$real_caps")
w=$(jq -r '.error_classes.free_retired_corpse.writer' "$real_caps")
o=$(jq -r '.error_classes.free_retired_corpse.trigger_order' "$real_caps")
[[ "$m" == "is_openrouter_free_retired_error" ]] || fail "registry: matcher is '$m'"
[[ "$w" == "mark_seat_free_retired_corpse" ]] || fail "registry: writer is '$w'"
[[ "$o" == "1" ]] || fail "registry: trigger_order must be 1 (before quota_bench=2/overload_bench=3), got '$o'"
oq=$(jq -r '.error_classes.quota_bench.trigger_order' "$real_caps")
oo=$(jq -r '.error_classes.overload_bench.trigger_order' "$real_caps")
(( o < oq && o < oo )) || fail "registry: free_retired_corpse must sort before quota($oq)/overload($oo)"
ok "registry: free_retired_corpse registered (matcher is_openrouter_free_retired_error, writer mark_seat_free_retired_corpse, trigger_order=1)"

# --- offline stubs for the lib-level dispatch tests ------------------------
cat >"$scratch/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["openrouter"],
  "providers": {
    "openrouter": {
      "cap": 2, "class": "free",
      "models": {"z-ai/glm-5.2:free": 0}
    }
  },
  "error_classes": {
    "free_retired_corpse": {
      "matcher": "is_openrouter_free_retired_error",
      "writer": "mark_seat_free_retired_corpse",
      "trigger_order": 1,
      "description": "fleet-ops#5274 permanent corpse."
    },
    "quota_bench": {
      "matcher": "is_quota_cap_error",
      "writer": "mark_seat_quota_bench",
      "default_window_s_seconds": "quota_bench_default_s",
      "trigger_order": 2,
      "description": "Hard cap / quota wall."
    },
    "overload_bench": {
      "matcher": "is_overload_error",
      "writer": "mark_seat_overload_bench",
      "default_window_s_seconds": "503_bench_default_s",
      "trigger_order": 3,
      "description": "503 / upstream-overload storm."
    }
  }
}
JSON
export SEAT_CAPS_JSON="$scratch/seat-caps.json"

cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "openrouter": {
      "models": [
        { "id": "z-ai/glm-5.2:free", "cost": { "input": 0 } }
      ]
    }
  }
}
JSON
export PI_MODELS_JSON="$scratch/models.json"

# --- 3. matcher: exact live tails match; neighbours do not -----------------
# The exact tail from /home/nish/.local/state/pi-issues/ARCHIVED-0509-2724.err-*
# (fleet-ops#5274 evidence), as pi surfaces it on stdout and stderr.
tail_out='404: {"message":"This model is unavailable for free. The paid version is available now - use this slug instead: z-ai/glm-5.2"}'
tail_err='session-error: API error: 404: {"message":"This model is unavailable for free. The paid version is available now - use this slug instead: minimax/minimax-m3"}'

set +e
bash -c 'source "$0"; is_openrouter_free_retired_error "$1" ""' "$lib" "$tail_out" >/dev/null 2>&1
rc=$?
[[ "$rc" == "0" ]] || fail "matcher: exact stdout tail must match (rc=$rc)"
bash -c 'source "$0"; is_openrouter_free_retired_error "" "$1"' "$lib" "$tail_err" >/dev/null 2>&1
rc=$?
[[ "$rc" == "0" ]] || fail "matcher: exact stderr (session-error) tail must match (rc=$rc)"

bash -c 'source "$0"; is_openrouter_free_retired_error "$1" ""' "$lib" "404: not found" >/dev/null 2>&1
rc=$?
[[ "$rc" != "0" ]] || fail "matcher: bare 404 without 'unavailable for free' must NOT match"
bash -c 'source "$0"; is_openrouter_free_retired_error "$1" ""' "$lib" "503: Upstream model provider is temporarily unavailable" >/dev/null 2>&1
rc=$?
[[ "$rc" != "0" ]] || fail "matcher: 503 overload body must NOT match"
bash -c 'source "$0"; is_openrouter_free_retired_error "$1" ""' "$lib" "INFERENCE_CAP_ERROR: weekly Clinepass limit" >/dev/null 2>&1
rc=$?
[[ "$rc" != "0" ]] || fail "matcher: quota body must NOT match"
ok "matcher: live 404 unavailable-for-free tails match; bare 404 / 503 / quota bodies rejected"

# --- 4. classify_death_error names the class -------------------------------
printf '%s\n' "$tail_err" >"$scratch/err.txt"
cls=$(bash -c 'source "$0"; classify_death_error "" "$1" ""' "$lib" "$scratch/err.txt" 2>/dev/null | head -n1)
[[ "$cls" == "openrouter_free_retired" ]] \
  || fail "classify_death_error: expected openrouter_free_retired, got '$cls'"
ok "classify_death_error: live tail classifies as openrouter_free_retired (not unknown)"

# --- 5. dispatch: the corpse writer parks the seat permanently -------------
rm -f "$LEDGER"/*.json 2>/dev/null || true
set +e
bash -c 'source "$0"; load_seat_caps; _dispatch_lane_faults "$1" "$2" "$3" "$4"' \
    "$lib" "openrouter" "z-ai/glm-5.2:free" "$tail_out" "$tail_err" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "dispatch: live tail must match and return rc=0 (got $rc)"
ledger_file="$LEDGER/openrouter__z-ai_glm-5.2_free.json"
[[ -f "$ledger_file" ]] || fail "dispatch: corpse writer did not create ledger at $ledger_file"
hc=$(jq -r '.health_class' "$ledger_file")
[[ "$hc" == "parked" ]] || fail "dispatch: corpse ledger health_class must be parked, got '$hc'"
dead=$(jq -r '.seat_dead' "$ledger_file")
[[ "$dead" == "true" ]] || fail "dispatch: corpse ledger must be seat_dead=true, got '$dead'"
lecls=$(jq -r '.last_error_class' "$ledger_file")
[[ "$lecls" == "openrouter_free_retired" ]] \
  || fail "dispatch: ledger last_error_class must be openrouter_free_retired, got '$lecls'"
br=$(jq -r '.bench_reason' "$ledger_file")
grep -q "unavailable for free" <<<"$br" \
  || fail "dispatch: bench_reason must record the 404 literal, got '$br'"
usable=$(jq -r '.usable_at' "$ledger_file")
[[ -n "$usable" && "$usable" != "null" ]] || fail "dispatch: corpse ledger must carry a far-future usable_at"
ok "dispatch: live tail -> terminal parked corpse (seat_dead=true, class=openrouter_free_retired, bench_reason quotes the 404) — never error_class=unknown + 300s bench"

ok "fleet-ops#5274 closure: OpenRouter 404 unavailable-for-free is classified as a permanent corpse (cap 0 + parked ledger), not unknown/300s; the free openrouter lane keeps its live seats"
