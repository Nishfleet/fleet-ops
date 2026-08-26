#!/usr/bin/env bash
# tests/seat-lib.test.sh
#
# P15: seat-selection repair — self-tests for lib/seat-lib.sh pick_seat +
# seat_usable against the cap-map ALLOWLIST contract.
#
# What we prove:
#   1. pick_seat NEVER returns a provider/model outside the seat-caps
#      allowlist — not even when every allowlisted seat is dead (the P15
#      "loud stall beats a garbage seat" rule: rc=1, no stdout, loud log).
#   2. A provider with NO cap-map entry is rejected (the allowlist escape
#      that let groq/openai/gpt-oss-20b through on 2026-08-25).
#   3. A model capped at 0 in the map (devin/glm-5-2:0, devin/swe-1-7:0)
#      is rejected even if its provider cap > 0.
#   4. Healthy allowlisted seats are picked in expiry-first order:
#      devin -> cursor -> cline -> free -> metered.
#   5. rate_limited: excluded while marker fresh (<30min) AND usable_at
#      future; RETRIED once the marker ages past 30min or usable_at passes.
#   6. seat_dead=true / credentials_bad / quota_exhausted -> unusable.
#   7. Stale observed_at (>6h) -> usable (the P4-A inversion fix).
#   8. quota_bench (fleet-ops#90): a 429-with-window seats the advertised
#      reset; pick_seat skips until then and fail-opens after; all-benched
#      returns rc=1 (existing no-seat path) without consuming an attempt.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "seat-lib.sh not found: $lib"
command -v jq >/dev/null || fail "jq required"

scratch="$(mktemp -d -t seat-lib-p15.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# A models.json with a deliberately non-allowlisted provider (groq) and a
# non-allowlisted model on an allowlisted provider (ollama/gpt-oss:20b).
cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "ollama": {
      "models": [
        { "id": "deepseek-v4-flash:0731", "cost": { "input": 0 } },
        { "id": "gpt-oss:20b", "cost": { "input": 0 } }
      ]
    },
    "groq": {
      "models": [
        { "id": "openai/gpt-oss-20b", "cost": { "input": 0 } }
      ]
    },
    "devin": {
      "models": [
        { "id": "glm-5-2", "cost": { "input": 0 } },
        { "id": "swe-1-7", "cost": { "input": 0 } }
      ]
    },
    "cursor": {
      "models": [
        { "id": "composer-2.5", "cost": { "input": 0 } },
        { "id": "cursor-grok-4.6-high", "cost": { "input": 0 } }
      ]
    },
    "cline": {
      "models": [
        { "id": "cline-pass/deepseek-v4-flash", "cost": { "input": 0 } },
        { "id": "cline-pass/minimax-m3", "cost": { "input": 0 } }
      ]
    },
    "commandcode": {
      "models": [
        { "id": "deepseek/deepseek-v4-flash", "cost": { "input": 0 } }
      ]
    },
    "minimax": {
      "models": [
        { "id": "MiniMax-M3", "cost": { "input": 0 } }
      ]
    }
  }
}
JSON

# A scratch cap map that is independent of the live fleet config so this
# test does not break every time a cap is tuned (issue #59).  devin has
# provider cap > 0 but both models cap=0, which lets us prove the model-level
# 0 block without depending on the current production values.
cat >"$scratch/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["ollama", "commandcode"],
  "providers": {
    "devin":    { "cap": 4, "class": "subscription", "models": { "glm-5-2": 0, "swe-1-7": 0 } },
    "cursor":   { "cap": 1, "class": "subscription", "models": { "composer-2.5": 1, "cursor-grok-4.6-high": 1 } },
    "cline":    { "cap": 2, "class": "subscription", "models": { "cline-pass/deepseek-v4-flash": 2, "cline-pass/minimax-m3": 2 } },
    "commandcode": { "cap": 2, "class": "free",       "models": { "deepseek/deepseek-v4-flash": 2 } },
    "ollama":   { "cap": 2, "class": "free",       "models": { "deepseek-v4-flash:0731": 2 } },
    "minimax":  { "cap": 2, "class": "metered",    "models": { "MiniMax-M3": 2 } }
  }
}
JSON

export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"

# --- invariant 2: provider with NO cap-map entry is rejected --------------
ledger="$scratch/ledger-noentry"
mkdir -p "$ledger"
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger"
export PI_PACKET_STATE="$scratch/state-noentry"
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "no-entry ledger: expected a pick, got rc=$rc"
if echo "$out" | grep -qE "^(groq|ollama.*gpt-oss)"; then
  fail "no-entry ledger: groq/gpt-oss must never be picked, got: $out"
fi
grep -qE "provider (groq not in cap-map allowlist|cap=0)" "$PI_PACKET_STATE/watch.log" \
  || fail "no-entry ledger: groq must be rejected (cap=0 or allowlist)"

# --- invariant 2b: provider with NO cap-map entry at all is rejected ------
# The true P15 escape: a provider in models.json but with NO seat-caps entry
# (e.g. a newly added provider) previously fell through the allowlist as
# "free" and could be picked. Prove it is now rejected with the allowlist
# message.
cat >"$scratch/models-nogrok.json" <<'JSON'
{
  "providers": {
    "ollama": {
      "models": [
        { "id": "deepseek-v4-flash:0731", "cost": { "input": 0 } }
      ]
    },
    "notacredentialedprovider": {
      "models": [
        { "id": "made-up-model", "cost": { "input": 0 } }
      ]
    }
  }
}
JSON
ledger="$scratch/ledger-noentry2"
mkdir -p "$ledger"
export PI_MODELS_JSON="$scratch/models-nogrok.json"
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger"
export PI_PACKET_STATE="$scratch/state-noentry2"
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "no-entry2 ledger: expected a pick, got rc=$rc"
if echo "$out" | grep -q "notacredentialedprovider"; then
  fail "no-entry2 ledger: provider with no cap entry must never be picked, got: $out"
fi
grep -q "provider notacredentialedprovider not in cap-map allowlist" "$PI_PACKET_STATE/watch.log" \
  || fail "no-entry2 ledger: must log the allowlist rejection for a provider with no entry"
export PI_MODELS_JSON="$scratch/models.json"

# --- invariant 3: model capped at 0 rejected even with provider cap > 0 ---
ledger="$scratch/ledger-modelcap0"
mkdir -p "$ledger"
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger"
export PI_PACKET_STATE="$scratch/state-modelcap0"
# devin has provider cap=4 but both models cap=0; prove the model-level 0 also blocks.
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "modelcap0 ledger: expected a pick, got rc=$rc"
if echo "$out" | grep -qE "^(devin|groq)"; then
  fail "modelcap0 ledger: devin/groq must never be picked, got: $out"
fi
grep -q "cap=0" "$PI_PACKET_STATE/watch.log" \
  || fail "modelcap0 ledger: devin must be rejected (cap=0)"

# --- invariant 1: ALL DEAD -> loud stall, rc=1, no stdout -----------------
ledger="$scratch/ledger-alldead"
mkdir -p "$ledger"
fresh_obs=$(date -u -d '60 seconds ago' +%Y-%m-%dT%H:%M:%SZ)
for f in \
  devin__glm-5-2.json devin__swe-1-7.json \
  cursor__composer-2.5.json cursor__cursor-grok-4.6-high.json \
  cline__cline-pass_deepseek-v4-flash.json cline__cline-pass_minimax-m3.json \
  commandcode__deepseek_deepseek-v4-flash.json minimax__MiniMax-M3.json \
  ollama__deepseek-v4-flash_0731.json; do
  jq -n --arg obs "$fresh_obs" '{health_class:"credentials_bad",seat_dead:true,observed_at:$obs}' > "$ledger/$f"
done
export PI_PACKET_STATE="$scratch/state-alldead"
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger"
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "all-dead: expected rc=1 (loud stall), got rc=$rc"
[[ -z "$out" ]] || fail "all-dead: must print nothing to stdout, got: $out"
grep -q "NO USABLE SEAT" "$PI_PACKET_STATE/watch.log" \
  || fail "all-dead: must log the loud NO USABLE SEAT line"

# --- invariant 4: expiry-first order on an empty (usable) ledger ----------
# Every allowlisted model has no health file -> usable. devin is cap 0, so
# the first usable seat in order is cursor/composer-2.5 (cursor before cline,
# free tier after cline).
ledger="$scratch/ledger-clean"
mkdir -p "$ledger"
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger"
export PI_PACKET_STATE="$scratch/state-clean"
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "clean ledger: expected a pick, got rc=$rc"
[[ "$out" == "cursor	composer-2.5" ]] \
  || fail "clean ledger: expiry-first expected cursor/composer-2.5, got: $out"

# --- invariant 5: rate_limited retry vs exclusion --------------------------
now=$(date -u +%s)
ledger="$scratch/ledger-rate"
mkdir -p "$ledger"
# cline ds-flash: marker 40 min old, usable_at 30 min ago -> RETRY (usable)
old_obs=$(date -u -d "@$((now-2400))" +%Y-%m-%dT%H:%M:%SZ)
old_use=$(date -u -d "@$((now-1800))" +%Y-%m-%dT%H:%M:%SZ)
# minimax: marker fresh, usable_at future -> EXCLUDED
fresh_obs=$(date -u -d "@$((now-60))" +%Y-%m-%dT%H:%M:%SZ)
fresh_use=$(date -u -d "@$((now+300))" +%Y-%m-%dT%H:%M:%SZ)
jq -n --arg obs "$old_obs" --arg use "$old_use" \
  '{health_class:"rate_limited",seat_dead:false,observed_at:$obs,usable_at:$use}' \
  > "$ledger/cline__cline-pass_deepseek-v4-flash.json"
jq -n --arg obs "$fresh_obs" --arg use "$fresh_use" \
  '{health_class:"rate_limited",seat_dead:false,observed_at:$obs,usable_at:$use}' \
  > "$ledger/cline__cline-pass_minimax-m3.json"
export PI_PACKET_STATE="$scratch/state-rate"
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger"
# Force the ladder to reach cline by trying the earlier seats.
printf "cursor/composer-2.5\ncursor/cursor-grok-4.6-high\nollama/deepseek-v4-flash:0731\ncommandcode/deepseek/deepseek-v4-flash\nminimax/MiniMax-M3\n" > "$scratch/tried.txt"
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0 "$1"' "$lib" "$scratch/tried.txt" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "rate-ledger: expected a pick (retry), got rc=$rc"
[[ "$out" == "cline	cline-pass/deepseek-v4-flash" ]] \
  || fail "rate-ledger: expected cline ds-flash retry, got: $out"
grep -q "retrying after rate_limited" "$PI_PACKET_STATE/watch.log" \
  || fail "rate-ledger: must log the retrying-after-rate_limited line"
grep -q "UNUSABLE (rate_limited until" "$PI_PACKET_STATE/watch.log" \
  || fail "rate-ledger: minimax fresh-RL must stay excluded"

# --- invariant 6/7: dead / credentials_bad / stale-observed ----------------
# (7) stale observed_at -> usable: cursor marker from yesterday
ledger="$scratch/ledger-stale"
mkdir -p "$ledger"
jq -n --arg obs "2026-08-24T00:00:00Z" \
  '{health_class:"healthy",seat_dead:false,observed_at:$obs}' \
  > "$ledger/cursor__composer-2.5.json"
export PI_PACKET_STATE="$scratch/state-stale"
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger"
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "stale ledger: expected a pick, got rc=$rc"
grep -q "stale >21600s) — assuming usable" "$PI_PACKET_STATE/watch.log" \
  || fail "stale ledger: stale seat must be assumed usable"

# --- invariant 8: credential precheck (fleet-ops#36) -----------------------
# An allowlisted provider (cap>0, model cap>0) is STILL rejected when its
# apiKey resolves to empty — defence in depth on top of the cap map. Prove:
#   8a. "!cmd" with empty stdout  -> rejected (the groq/openrouter 2026-08-25
#       "No API key found" shape: a credential command that yields nothing).
#   8b. "$VAR" with the var UNSET  -> rejected.
#   8c. "!cmd" with non-empty stdout -> accepted.
#   8d. "$VAR" with the var SET    -> accepted.
#   8e. literal apiKey             -> accepted.
#   8f. NO apiKey field            -> fail OPEN (accepted) — OAuth/test fixtures
#       are not bricked; the reactive ledger is the backstop.
#   8g. per-call cache: a provider with TWO models runs its "!cmd" ONCE.
cred_scratch="$(mktemp -d -t seat-lib-cred.XXXXXX)"
# A "!cmd" with a side effect so we can count how many times it ran.
cred_counter="$cred_scratch/counter"
export cred_counter
: >"$cred_counter"
cat >"$cred_scratch/models.json" <<JSON
{
  "providers": {
    "badcmd":  { "apiKey": "!printf ''",            "models": [ { "id": "m", "cost": { "input": 0 } } ] },
    "badvar":  { "apiKey": "\$MISSING_VAR_CRED",    "models": [ { "id": "m", "cost": { "input": 0 } } ] },
    "goodcmd": { "apiKey": "!echo secretkey",       "models": [ { "id": "m", "cost": { "input": 0 } } ] },
    "goodvar": { "apiKey": "\$GOOD_VAR_CRED",       "models": [ { "id": "m", "cost": { "input": 0 } } ] },
    "literal": { "apiKey": "sk-literal-123",        "models": [ { "id": "m", "cost": { "input": 0 } } ] },
    "nokey":   {                                     "models": [ { "id": "m", "cost": { "input": 0 } } ] },
    "twomodel":{ "apiKey": "!printf x >>$cred_counter; echo k", "models": [ { "id": "a", "cost": { "input": 0 } }, { "id": "b", "cost": { "input": 0 } } ] }
  }
}
JSON
cat >"$cred_scratch/seat-caps.json" <<'JSON'
{
  "free_providers_in_order": ["badcmd","badvar","goodcmd","goodvar","literal","nokey","twomodel"],
  "providers": {
    "badcmd":   { "cap": 2, "class": "free", "models": { "m": 2 } },
    "badvar":   { "cap": 2, "class": "free", "models": { "m": 2 } },
    "goodcmd":  { "cap": 2, "class": "free", "models": { "m": 2 } },
    "goodvar":  { "cap": 2, "class": "free", "models": { "m": 2 } },
    "literal":  { "cap": 2, "class": "free", "models": { "m": 2 } },
    "nokey":    { "cap": 2, "class": "free", "models": { "m": 2 } },
    "twomodel": { "cap": 2, "class": "free", "models": { "a": 2, "b": 2 } }
  }
}
JSON
ledger="$cred_scratch/ledger"
mkdir -p "$ledger"
export PI_MODELS_JSON="$cred_scratch/models.json"
export SEAT_CAPS_JSON="$cred_scratch/seat-caps.json"
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger"
export PI_PACKET_STATE="$cred_scratch/state"
export GOOD_VAR_CRED="set-value"
unset MISSING_VAR_CRED
# 8a/8b/8c: badcmd and badvar are first in free order and must be skipped;
# goodcmd is the first allowlisted seat WITH a credential, so it is picked.
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "cred: expected a pick, got rc=$rc"
[[ "$out" == "goodcmd	m" ]] \
  || fail "cred: badcmd/badvar must be skipped, expected goodcmd/m, got: $out"
grep -q "credential precheck: badcmd rejected" "$PI_PACKET_STATE/watch.log" \
  || fail "cred: badcmd (!cmd empty) must be rejected by the precheck"
grep -q "credential precheck: badvar rejected" "$PI_PACKET_STATE/watch.log" \
  || fail "cred: badvar (\$VAR unset) must be rejected by the precheck"

# 8d/8e/8f: with goodcmd excluded, the next credentialed seat is goodvar;
# then literal; then nokey (fail-open). Prove the fail-open path: a provider
# with NO apiKey field is still a candidate.
printf "goodcmd/m\n" >"$cred_scratch/tried.txt"
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0 "$1"' "$lib" "$cred_scratch/tried.txt" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "cred2: expected a pick, got rc=$rc"
[[ "$out" == "goodvar	m" ]] \
  || fail "cred2: expected goodvar/m (set var), got: $out"
grep -q "credential precheck: nokey has no apiKey field" "$PI_PACKET_STATE/watch.log" \
  || fail "cred2: nokey (no apiKey field) must fail OPEN and log the skip"

# 8g: per-call cache. twomodel has two models (a, b) but its "!cmd" side
# effect (append 'x' to $cred_counter) must fire ONCE per pick_seat pass.
: >"$cred_counter"
# Exclude every provider that sorts before twomodel so twomodel is reached.
printf "badcmd/m\nbadvar/m\ngoodcmd/m\ngoodvar/m\nliteral/m\nnokey/m\n" >"$cred_scratch/tried2.txt"
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0 "$1"' "$lib" "$cred_scratch/tried2.txt" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "cred-cache: expected a pick, got rc=$rc"
[[ "$out" == "twomodel	a" ]] \
  || fail "cred-cache: expected twomodel/a, got: $out"
count=$(wc -c <"$cred_counter"); count=${count//[^0-9]/}
[[ "$count" == "1" ]] \
  || fail "cred-cache: twomodel !cmd must run ONCE (cache), ran ${count:-0} times"

# Restore the fixtures the earlier invariants used, in case anything after
# this re-sources the lib (defensive; nothing does today).
export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"

# --- fleet-ops#90: quota/cap bench -----------------------------------------
# A hard-capped seat (ClinePass weekly cap, devin 15-min 429) must be benched
# for its advertised reset window and skipped by pick_seat until that window
# expires; after it expires the seat is offered again (fail-open). A worker
# whose every allowlisted seat is benched exits via the existing no-seat path
# (rc=1, NO USABLE SEAT) without consuming an attempt on a benched seat.
#
# The scratch cap map (lines 88-101) has cline (cap 2, both models cap 2) and
# devin (cap 4, both models cap 0). Add quota_bench_default_s to cline so the
# writer-fallback invariant can run against the same fixtures.
cat >"$scratch/seat-caps-bench.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["ollama", "commandcode"],
  "providers": {
    "devin":    { "cap": 4, "class": "subscription", "quota_bench_default_s": 900, "models": { "glm-5-2": 0, "swe-1-7": 0 } },
    "cursor":   { "cap": 1, "class": "subscription", "models": { "composer-2.5": 1, "cursor-grok-4.6-high": 1 } },
    "cline":    { "cap": 2, "class": "subscription", "quota_bench_default_s": 604800, "models": { "cline-pass/deepseek-v4-flash": 2, "cline-pass/minimax-m3": 2 } },
    "commandcode": { "cap": 2, "class": "free",       "models": { "deepseek/deepseek-v4-flash": 2 } },
    "ollama":   { "cap": 2, "class": "free",       "models": { "deepseek-v4-flash:0731": 2 } },
    "minimax":  { "cap": 2, "class": "metered",    "models": { "MiniMax-M3": 2 } }
  }
}
JSON
export SEAT_CAPS_JSON="$scratch/seat-caps-bench.json"

# 9a: _parse_reset_window_s handles every documented format.
set +e
w=$(bash -c 'source "$0"; _parse_reset_window_s "$1"' "$lib" "INFERENCE_CAP_ERROR: weekly Clinepass limit. The limit resets in 1d 11h" 2>/dev/null)
set -e
[[ "$w" == "126000" ]] || fail "parse: 'resets in 1d 11h' expected 126000, got ${w:-<none>}"
set +e
w=$(bash -c 'source "$0"; _parse_reset_window_s "$1"' "$lib" "quota exceeded, resets in 2h 30m" 2>/dev/null)
set -e
[[ "$w" == "9000" ]] || fail "parse: 'resets in 2h 30m' expected 9000, got ${w:-<none>}"
set +e
w=$(bash -c 'source "$0"; _parse_reset_window_s "$1"' "$lib" "429 Too Many Requests retry-after: 45" 2>/dev/null)
set -e
[[ "$w" == "45" ]] || fail "parse: 'retry-after: 45' expected 45, got ${w:-<none>}"
set +e
w=$(bash -c 'source "$0"; _parse_reset_window_s "$1"' "$lib" "rate limit exceeded, retry after 120" 2>/dev/null)
set -e
[[ "$w" == "120" ]] || fail "parse: 'retry after 120' expected 120, got ${w:-<none>}"
set +e
w=$(bash -c 'source "$0"; _parse_reset_window_s "$1"' "$lib" "weekly Clinepass limit, no window here" 2>/dev/null)
set -e
[[ -z "$w" ]] || fail "parse: no-window text must return empty, got $w"

# 9b: is_quota_cap_error detects hard-cap walls, rejects transient 429s.
set +e
bash -c 'source "$0"; is_quota_cap_error "$1" "$2"' "$lib" "INFERENCE_CAP_ERROR: weekly Clinepass limit. The limit resets in 1d 11h" "" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "is_quota: ClinePass weekly cap text must match (rc=$rc)"
set +e
bash -c 'source "$0"; is_quota_cap_error "$1" "$2"' "$lib" "" "quota exceeded, resets in 2h" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "is_quota: 'quota exceeded resets in 2h' must match (rc=$rc)"
set +e
bash -c 'source "$0"; is_quota_cap_error "$1" "$2"' "$lib" "" "INFERENCE_CAP_ERROR: daily limit reached" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "is_quota: 'daily limit' (periodic cap, no window) must match -> default fallback (rc=$rc)"
# 'out of credits' with NO reset window is permanent exhaustion (the reactive
# quota_exhausted ledger block handles it), not a periodic cap with a default,
# so the wrapper must NOT bench it.
set +e
bash -c 'source "$0"; is_quota_cap_error "$1" "$2"' "$lib" "" "out of credits, plan limit reached" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" != "0" ]] || fail "is_quota: 'out of credits' with no reset window must NOT match (permanent exhaustion -> reactive ledger)"
set +e
bash -c 'source "$0"; is_quota_cap_error "$1" "$2"' "$lib" "429 Too Many Requests retry-after: 30" "" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" != "0" ]] || fail "is_quota: a transient 429 with no quota keyword must NOT match"
set +e
bash -c 'source "$0"; is_quota_cap_error "$1" "$2"' "$lib" "" "" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" != "0" ]] || fail "is_quota: empty input must NOT match"

# 9b-devin: Devin "message rate limit" + "reset in 35 minutes" (fleet-ops#358/#381).
devin_err='Reached overall message rate limit. Please try again later. Your limit will reset in 35 minutes.'
set +e
bash -c 'source "$0"; is_quota_cap_error "$1" "$2"' "$lib" "" "$devin_err" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "is_quota: Devin message rate limit text must match (rc=$rc)"
parsed=$(bash -c 'source "$0"; _parse_reset_window_s "$1"' "$lib" "$devin_err" 2>/dev/null || true)
[[ "$parsed" == "2100" ]] || fail "parse: Devin 'reset in 35 minutes' expected 2100, got '$parsed'"

# 9c: mark_seat_quota_bench parses the window and writes bench_until in the
# future; seat_usable then skips the seat.
ledger="$scratch/ledger-bench"
mkdir -p "$ledger"
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger"
export PI_PACKET_STATE="$scratch/state-bench"
fresh_obs=$(date -u -d '60 seconds ago' +%Y-%m-%dT%H:%M:%SZ)
# Write the marker directly from the error text (the wrapper's path).
bench_text="INFERENCE_CAP_ERROR: weekly Clinepass limit. The limit resets in 1d 11h"
set +e
bash -c 'source "$0"; load_seat_caps; mark_seat_quota_bench "$1" "$2" "$3"' "$lib" "cline" "cline-pass/deepseek-v4-flash" "$bench_text" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "writer: mark_seat_quota_bench expected rc=0, got $rc"
lf="$ledger/cline__cline-pass_deepseek-v4-flash.json"
[[ -f "$lf" ]] || fail "writer: ledger file not written at $lf"
hc=$(jq -r '.health_class' "$lf")
bu=$(jq -r '.bench_until' "$lf")
bw=$(jq -r '.bench_window_s' "$lf")
[[ "$hc" == "quota_bench" ]] || fail "writer: health_class expected quota_bench, got $hc"
[[ "$bw" == "126000" ]] || fail "writer: bench_window_s expected 126000, got $bw"
# bench_until must be ~now+126000s (within 5s slack for the call).
now_s=$(date -u +%s); bu_s=$(date -u -d "$bu" +%s 2>/dev/null || echo 0)
(( bu_s > now_s + 125995 && bu_s < now_s + 126005 )) \
  || fail "writer: bench_until expected ~now+126000s, got $bu (delta $((bu_s - now_s)))"
# seat_usable must skip it (benched, future).
set +e
bash -c 'source "$0"; seat_usable "$1" "$2"' "$lib" "cline" "cline-pass/deepseek-v4-flash" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" != "0" ]] || fail "writer: benched seat (future bench_until) must be UNUSABLE, seat_usable returned 0"
grep -q "benched until $bu" "$PI_PACKET_STATE/watch.log" \
  || fail "writer: must log 'benched until <ts>' for a skipped benched seat"

# 9d: pick_seat skips a benched seat and falls through; with ALL allowlisted
# seats benched or tried, it returns rc=1 (NO USABLE SEAT) without consuming
# an attempt on a benched seat.
now=$(date -u +%s)
future_bu=$(date -u -d "@$((now + 3600))" +%Y-%m-%dT%H:%M:%SZ)
# Bench BOTH cline models with a fresh observed_at and a future bench_until.
for f in cline__cline-pass_deepseek-v4-flash.json cline__cline-pass_minimax-m3.json; do
  jq -n --arg obs "$fresh_obs" --arg bu "$future_bu" \
    '{health_class:"quota_bench",seat_dead:false,observed_at:$obs,bench_until:$bu}' \
    > "$ledger/$f"
done
export PI_PACKET_STATE="$scratch/state-bench-pick"
# Try every non-cline allowlisted seat so the ladder reaches cline and finds
# both cline models benched -> no seat -> rc=1.
printf "cursor/composer-2.5\ncursor/cursor-grok-4.6-high\nollama/deepseek-v4-flash:0731\ncommandcode/deepseek/deepseek-v4-flash\nminimax/MiniMax-M3\n" > "$scratch/tried-bench.txt"
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0 "$1"' "$lib" "$scratch/tried-bench.txt" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "bench-pick: all-benched expected rc=1 (no-seat path), got rc=$rc out=$out"
[[ -z "$out" ]] || fail "bench-pick: must print nothing to stdout, got: $out"
grep -q "NO USABLE SEAT" "$PI_PACKET_STATE/watch.log" \
  || fail "bench-pick: must log NO USABLE SEAT (no attempt consumed on a benched seat)"
grep -q "benched until" "$PI_PACKET_STATE/watch.log" \
  || fail "bench-pick: must log 'benched until' for the skipped cline seats"

# 9e: once bench_until passes, the seat is offered again (fail-open).
past_bu=$(date -u -d "@$((now - 60))" +%Y-%m-%dT%H:%M:%SZ)
for f in cline__cline-pass_deepseek-v4-flash.json cline__cline-pass_minimax-m3.json; do
  jq -n --arg obs "$fresh_obs" --arg bu "$past_bu" \
    '{health_class:"quota_bench",seat_dead:false,observed_at:$obs,bench_until:$bu}' \
    > "$ledger/$f"
done
export PI_PACKET_STATE="$scratch/state-bench-expired"
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0 "$1"' "$lib" "$scratch/tried-bench.txt" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "bench-expired: expected a pick (fail-open), got rc=$rc"
[[ "$out" == "cline	cline-pass/deepseek-v4-flash" ]] \
  || fail "bench-expired: expected cline/cline-pass/deepseek-v4-flash (first cline model), got: $out"
grep -q "bench expired" "$PI_PACKET_STATE/watch.log" \
  || fail "bench-expired: must log 'bench expired ... fail-open'"

# 9f: mark_seat_quota_bench falls back to the provider default when the error
# text carries no numeric window; and fails open (no marker) for a provider
# with no default configured.
export PI_PACKET_STATE="$scratch/state-bench-default"
rm -f "$ledger/cline__cline-pass_minimax-m3.json"
set +e
bash -c 'source "$0"; load_seat_caps; mark_seat_quota_bench "$1" "$2" "$3"' "$lib" "cline" "cline-pass/minimax-m3" "INFERENCE_CAP_ERROR: weekly Clinepass limit." >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "default: cline (has default) expected rc=0, got $rc"
bw=$(jq -r '.bench_window_s' "$ledger/cline__cline-pass_minimax-m3.json")
[[ "$bw" == "604800" ]] || fail "default: cline bench_window_s expected 604800, got $bw"
# cursor has NO quota_bench_default_s -> fail open, no marker.
rm -f "$ledger/cursor__composer-2.5.json"
set +e
bash -c 'source "$0"; load_seat_caps; mark_seat_quota_bench "$1" "$2" "$3"' "$lib" "cursor" "composer-2.5" "usage limit hit, no window" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "default: cursor (no default) expected rc=1 (fail-open), got $rc"
[[ -f "$ledger/cursor__composer-2.5.json" ]] \
  && fail "default: cursor (no default) must NOT write a marker" || true
grep -q "quota-bench: cursor/composer-2.5 NOT benched" "$PI_PACKET_STATE/watch.log" \
  || fail "default: cursor fail-open must log the NOT-benched line"

# 9g: bench_until outlives STALE_SECS. A weekly cap's observed_at goes stale
# after 6h, but pick_seat must still skip until bench_until (the advertised
# reset). This is the ClinePass 1d 11h case: without this, the seat is
# re-offered after 6h and burns StartLimitBurst on a guaranteed wall.
stale_obs=$(date -u -d '7 hours ago' +%Y-%m-%dT%H:%M:%SZ)
jq -n --arg obs "$stale_obs" --arg bu "$future_bu" \
  '{health_class:"quota_bench",seat_dead:false,observed_at:$obs,bench_until:$bu}' \
  > "$ledger/cline__cline-pass_deepseek-v4-flash.json"
jq -n --arg obs "$stale_obs" --arg bu "$future_bu" \
  '{health_class:"quota_bench",seat_dead:false,observed_at:$obs,bench_until:$bu}' \
  > "$ledger/cline__cline-pass_minimax-m3.json"
export PI_PACKET_STATE="$scratch/state-bench-stale-obs"
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0 "$1"' "$lib" "$scratch/tried-bench.txt" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "stale-obs-bench: expected rc=1 (still benched despite stale observed_at), got rc=$rc out=$out"
grep -q "benched until" "$PI_PACKET_STATE/watch.log" \
  || fail "stale-obs-bench: must skip on bench_until, not fail-open on stale observed_at"
grep -q "stale >" "$PI_PACKET_STATE/watch.log" \
  && fail "stale-obs-bench: must NOT take the stale-observed_at fail-open path while bench_until is future"

# Restore the canonical scratch cap map so any later re-source is unaffected.
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export PI_MODELS_JSON="$scratch/models.json"

ok "allowlist: no-entry provider and cap-0 models rejected"
ok "loud stall: all-dead returns rc=1 with NO USABLE SEAT, empty stdout"
ok "expiry-first: cursor/composer-2.5 picked on clean ledger"
ok "rate_limited: stale marker retried, fresh marker excluded"
ok "stale observed_at assumed usable (P4-A inversion fixed)"
ok "credential precheck: empty !cmd / unset \$VAR rejected; set var / literal / no-apiKey fail-open accepted; per-call cache runs !cmd once"
ok "quota_bench: parser handles 'resets in Nd Nh' / 'retry after N' / no-window; is_quota_cap_error matches hard caps, rejects transient 429"
ok "quota_bench: writer parses window -> bench_until future -> seat_usable skips with 'benched until' log"
ok "quota_bench: pick_seat skips benched seats; all-benched -> rc=1 NO USABLE SEAT (no attempt consumed); expired bench_until -> fail-open pick"
ok "quota_bench: stale observed_at (>6h) with future bench_until still skipped (weekly cap outlives STALE_SECS)"

# --- P15 wedge-age liveness probe ----------------------------------------
# A unit stuck in `activating` past PI_SEAT_ACTIVATING_MAX_S is a wedged pi
# (the fleet-ops#83 finalize-hang), not a live worker. The registry entry
# must be reaped so caps free up. A freshly-activating unit (60s) is live.
export PI_PACKET_STATE="$scratch/state-wedge"
export PI_SEAT_LIB_CHECK_SYSTEMD=1
mkdir -p "$PI_PACKET_STATE/active-seats"
jq -n '{unit:"pi-issue-wedged"}' > "$PI_PACKET_STATE/active-seats/pi-issue-wedged.json"
jq -n '{unit:"pi-issue-fresh"}' > "$PI_PACKET_STATE/active-seats/pi-issue-fresh.json"
jq -n '{unit:"pi-issue-dead"}' > "$PI_PACKET_STATE/active-seats/pi-issue-dead.json"

# The probe and the shim both read the clock via
# `awk '{print int($1)}' /proc/uptime`. On a fresh GitHub runner (uptime
# < 1h) a 3600s-old monotonic timestamp is not representable (it would be
# negative and trip the probe's ^[0-9]+$ guard). Floor the simulated
# uptime at 3700s so BOTH the probe's clock and the shim's clock agree on
# any runner: wedged age = 3600s > 3300s max -> reaped, fresh age = 60s
# -> live. Without the shared floor the probe computes wedged age as
# (real uptime - 100)s, which on a fresh runner is < 3300s -> kept -> the
# exact CI failure that auto-reverted #94 and #98.
awk() {
  if [[ "$*" == *'/proc/uptime'* ]] && [[ "$*" == *'print int($1)'* ]]; then
    local real_s
    real_s=$(command awk '{print int($1)}' /proc/uptime)
    if (( real_s < 3700 )); then real_s=3700; fi
    echo "$real_s"
  else
    command awk "$@"
  fi
}
export -f awk

# Shim systemctl: the probe calls `systemctl --user is-active UNIT` and
# `systemctl --user show UNIT --property=ActiveEnterTimestampMonotonic
# --value`. wedged is 3600s into activating, fresh 60s, dead failed.
systemctl() {
  [[ "$1" == "--user" ]] && shift
  case "$1" in
    is-active)
      case "$2" in
        pi-issue@wedged.service) echo activating ;;
        pi-issue@fresh.service) echo activating ;;
        pi-issue@dead.service) echo failed ;;
        *) echo inactive ;;
      esac ;;
    show)
      now_s=$(awk '{print int($1)}' /proc/uptime)
      case "$2" in
        pi-issue@wedged.service) echo "$(( (now_s - 3600) * 1000000 ))" ;;
        pi-issue@fresh.service) echo "$(( (now_s - 60) * 1000000 ))" ;;
        *) echo 0 ;;
      esac ;;
  esac
}
export -f systemctl

set +e
live=$(bash -c 'source "$1"; _seat_live_registry_files' _ "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "wedge probe: _seat_live_registry_files failed rc=$rc"
echo "$live" | grep -q 'pi-issue-fresh.json' \
  || fail "wedge probe: fresh activating unit must stay live, got: $live"
echo "$live" | grep -q 'pi-issue-wedged.json' \
  && fail "wedge probe: 3600s-activating unit must be reaped, got: $live"
grep -q "stuck activating" "$PI_PACKET_STATE/watch.log" \
  || fail "wedge probe: must log the stuck-activating reap"
ok "wedge-age probe: stuck-activating reaped, fresh-activating kept"
