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
#   3. A model capped at 0 in the map is rejected even if its provider cap
#      > 0. That block is per-model, not per-provider: a sibling with cap>0
#      stays pickable (fleet-ops#108).
#   4. Healthy allowlisted seats: free lanes first, then prepaid-quota
#      (alternating), then metered. A prepaid seat mislabeled free is a
#      config bug the entitled-vs-wired canary catches (fleet-ops#387).
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

# Offline: live pi-issue@ units must not fill the scratch caps and rotate
# pick_seat into prepaid (fleet-ops#108 / #142 / #509). The wedge-age
# probe below turns this back on with a stubbed systemctl.
export PI_SEAT_LIB_CHECK_SYSTEMD=0

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
    },
    "opencode": {
      "models": [
        { "id": "mimo-v2.5-free", "cost": { "input": 0 } }
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
# fleet-ops#457: isolate from a live quality scoreboard so overlay
# cuts cannot leak into the allowlist contract tests.
export QUALITY_SCOREBOARD_JSON="$scratch/no-quality-scoreboard.json"
export QUALITY_ROUTING_JSON="$scratch/no-quality-routing.json"

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
# Both devin models are cap=0 in the scratch map. pick_seat must skip those
# models (not the whole provider-name prefix) and pick a free lane instead.
# The old `^(devin|groq)` grep plus "devin/groq must never be picked" fail
# text looked like a provider-wide ban, which is how fleet-ops#108 was filed.
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "modelcap0: expected a free-lane pick, got rc=$rc out=$out"
[[ "$out" == "commandcode	deepseek/deepseek-v4-flash" || "$out" == "ollama	deepseek-v4-flash:0731" ]] \
  || fail "modelcap0: expected a free lane, not a cap=0 prepaid model, got: $out"
grep -q "seat devin/glm-5-2 skipped (model cap=0)" "$PI_PACKET_STATE/watch.log" \
  || fail "modelcap0: must log model cap=0 skip for glm-5-2"
grep -q "seat devin/swe-1-7 skipped (model cap=0)" "$PI_PACKET_STATE/watch.log" \
  || fail "modelcap0: must log model cap=0 skip for swe-1-7"

# --- invariant 3b: cap=0 is per-model, not per-provider (fleet-ops#108) ---
# Same provider, one model at 0, sibling at 4. A provider-wide block would
# return rc=1. Ignoring model cap=0 would pick glm-5-2 (listed first).
cat >"$scratch/models-mixedcap.json" <<'JSON'
{
  "providers": {
    "devin": {
      "models": [
        { "id": "glm-5-2", "cost": { "input": 0 } },
        { "id": "swe-1-7", "cost": { "input": 0 } }
      ]
    }
  }
}
JSON
cat >"$scratch/seat-caps-mixedcap.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "providers": {
    "devin": { "cap": 4, "class": "subscription", "models": { "glm-5-2": 0, "swe-1-7": 4 } }
  }
}
JSON
ledger="$scratch/ledger-mixedcap"
mkdir -p "$ledger"
export PI_MODELS_JSON="$scratch/models-mixedcap.json"
export SEAT_CAPS_JSON="$scratch/seat-caps-mixedcap.json"
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger"
export PI_PACKET_STATE="$scratch/state-mixedcap"
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "mixedcap: sibling swe-1-7 must stay pickable when glm-5-2 is cap=0, got rc=$rc out=$out"
[[ "$out" == "devin	swe-1-7" ]] \
  || fail "mixedcap: expected devin/swe-1-7 (the cap>0 sibling), got: $out"
grep -q "seat devin/glm-5-2 skipped (model cap=0)" "$PI_PACKET_STATE/watch.log" \
  || fail "mixedcap: must skip glm-5-2 for model cap=0"
grep -q "seat devin/swe-1-7 skipped (model cap=0)" "$PI_PACKET_STATE/watch.log" \
  && fail "mixedcap: must not skip the cap>0 sibling"
export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"

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

# --- invariant 4: free lanes before prepaid on an empty (usable) ledger ---
# Every allowlisted model has no health file -> usable. commandcode is free;
# cursor/cline are prepaid-quota (subscription alias). Free wins.
ledger="$scratch/ledger-clean"
mkdir -p "$ledger"
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger"
export PI_PACKET_STATE="$scratch/state-clean"
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "clean ledger: expected a pick, got rc=$rc"
[[ "$out" == "commandcode	deepseek/deepseek-v4-flash" || "$out" == "ollama	deepseek-v4-flash:0731" ]] \
  || fail "clean ledger: free-first expected commandcode or ollama, got: $out"

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

# 9b-devin: Devin "message rate limit" + "reset in 35 minutes" (fleet-ops#381).
# Live miss 2026-08-26: is_quota_cap_error required "rate limit exceeded" and
# _parse_reset_window_s required "resets in 35m", so systemd Restart burned
# StartLimitBurst on the same dead seat.
devin_err='Reached overall message rate limit. Please try again later. Your limit will reset in 35 minutes.'
set +e
bash -c 'source "$0"; is_quota_cap_error "$1" "$2"' "$lib" "" "$devin_err" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "is_quota: Devin message rate limit text must match (rc=$rc)"
set +e
parsed=$(bash -c 'source "$0"; _parse_reset_window_s "$1"' "$lib" "$devin_err" 2>/dev/null || true)
set -e
[[ "$parsed" == "2100" ]] || fail "parse: Devin 'reset in 35 minutes' expected 2100, got '${parsed:-<none>}'"
# Writer: the same live text must bench the seat for the advertised window.
devin_ledger="$scratch/ledger-devin-bench"
mkdir -p "$devin_ledger"
export PI_SEAT_HEALTH_LEDGER_DIR="$devin_ledger"
export PI_PACKET_STATE="$scratch/state-devin-bench"
mkdir -p "$PI_PACKET_STATE"
set +e
bash -c 'source "$0"; load_seat_caps; mark_seat_quota_bench "$1" "$2" "$3"' "$lib" "devin" "swe-1-7" "$devin_err" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "writer: Devin mark_seat_quota_bench expected rc=0, got $rc"
devin_lf="$devin_ledger/devin__swe-1-7.json"
[[ -f "$devin_lf" ]] || fail "writer: Devin ledger file not written at $devin_lf"
devin_hc=$(jq -r '.health_class' "$devin_lf")
devin_bw=$(jq -r '.bench_window_s' "$devin_lf")
[[ "$devin_hc" == "quota_bench" ]] || fail "writer: Devin health_class expected quota_bench, got $devin_hc"
[[ "$devin_bw" == "2100" ]] || fail "writer: Devin bench_window_s expected 2100, got $devin_bw"

# 9b-cursor-heavy: cursor composer stays light-only even with a 200k window;
# cursor-grok-4.6-high is the only cursor model admitted as heavy-capable
# (live hot-patch + Nish 2026-08-27 overrule; fleet-ops#381).
cat >"$scratch/models-cursor-heavy.json" <<'JSON'
{
  "providers": {
    "cursor": {
      "models": [
        { "id": "composer-2.5", "cost": { "input": 0 }, "contextWindow": 200000 },
        { "id": "cursor-grok-4.6-high", "cost": { "input": 0 }, "contextWindow": 200000 }
      ]
    },
    "ollama": {
      "models": [
        { "id": "deepseek-v4-flash:0731", "cost": { "input": 0 }, "contextWindow": 200000 }
      ]
    }
  }
}
JSON
set +e
cursor_cap=$(PI_MODELS_JSON="$scratch/models-cursor-heavy.json" bash -c 'source "$0"; enumerate_seats' "$lib" 2>/dev/null || true)
set -e
printf '%s\n' "$cursor_cap" | awk -F '\t' '$1=="cursor" && $2=="composer-2.5" {exit ($4=="0"?0:1)}' \
  || fail "cursor/composer-2.5 must not be heavy-capable via contextWindow (got: $cursor_cap)"
printf '%s\n' "$cursor_cap" | awk -F '\t' '$1=="cursor" && $2=="cursor-grok-4.6-high" {exit ($4=="1"?0:1)}' \
  || fail "cursor/cursor-grok-4.6-high must be heavy-capable (got: $cursor_cap)"
printf '%s\n' "$cursor_cap" | awk -F '\t' '$1=="ollama" && $2=="deepseek-v4-flash:0731" {exit ($4=="1"?0:1)}' \
  || fail "non-cursor 200k window must stay heavy-capable (got: $cursor_cap)"

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

# 9f-mimo: fleet-ops#650 / #661 — mimo-v2.5-free FreeUsageLimitError (HTTP 429,
# no reset window in body). With quota_bench_default_s=900 on the opencode
# provider, mark_seat_quota_bench must write a 900s bench marker (rc=0) so
# pick_seat skips the seat instead of fail-opening and re-picking it 20 min
# later (the summoning trip). The live text matches is_quota_cap_error's
# 'rate limit exceeded' branch.
mimo_ledger="$scratch/ledger-mimo"
mkdir -p "$mimo_ledger"
export PI_SEAT_HEALTH_LEDGER_DIR="$mimo_ledger"
# Scratch cap map variant that mirrors the production opencode entry with
# the new quota_bench_default_s. We source seat-lib fresh against it so the
# load_seat_caps cache picks it up.
cat >"$scratch/seat-caps-mimo.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["opencode"],
  "providers": {
    "opencode": { "cap": 1, "class": "free", "quota_bench_default_s": 900, "models": { "mimo-v2.5-free": 1 } }
  }
}
JSON
SEAT_CAPS_JSON_MIMO="$scratch/seat-caps-mimo.json"
export PI_PACKET_STATE="$scratch/state-bench-mimo"
set +e
SEAT_CAPS_JSON="$SEAT_CAPS_JSON_MIMO" bash -c 'source "$0"; load_seat_caps; mark_seat_quota_bench "$1" "$2" "$3"' \
    "$lib" "opencode" "mimo-v2.5-free" \
    '429: {"type":"FreeUsageLimitError","message":"Error from provider (Console): Rate limit exceeded. Please try again later."}' \
    >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "mimo-bench: opencode (has default 900) expected rc=0, got $rc"
# Marker must exist with health_class=quota_bench and bench_window_s=900
# (not the 0/fail-open path). The summoning trip is the writer that did NOT
# write this file before fleet-ops#650/661.
[[ -f "$mimo_ledger/opencode__mimo-v2.5-free.json" ]] \
  || fail "mimo-bench: opencode/mimo-v2.5-free marker MUST be written (the summoning trip was the missing marker)"
bw=$(jq -r '.bench_window_s' "$mimo_ledger/opencode__mimo-v2.5-free.json" 2>/dev/null)
hc=$(jq -r '.health_class' "$mimo_ledger/opencode__mimo-v2.5-free.json" 2>/dev/null)
[[ "$bw" == "900" ]] || fail "mimo-bench: opencode bench_window_s expected 900, got '$bw'"
[[ "$hc" == "quota_bench" ]] || fail "mimo-bench: opencode health_class expected quota_bench, got '$hc'"
# pick_seat must now skip the seat (rc=1 NO USABLE SEAT) — this is what was
# MISSING on 2026-08-27 02:17Z + 02:37Z: the writer failed open so the seat
# was re-picked, hit the same 429, and summoned the auditor twice in 20 min.
export PI_PACKET_STATE="$scratch/state-bench-mimo-pick"
rm -f "$scratch/tried-mimo.txt"
set +e
out=$(SEAT_CAPS_JSON="$SEAT_CAPS_JSON_MIMO" \
      PI_SEAT_HEALTH_LEDGER_DIR="$mimo_ledger" \
      PI_PACKET_STATE="$scratch/state-bench-mimo-pick" \
      PI_MODELS_JSON="$scratch/models.json" \
  bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0 "$1"' "$lib" "$scratch/tried-mimo.txt" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "mimo-bench: pick_seat after bench must rc=1 (NO USABLE SEAT), got rc=$rc out='$out"
grep -q "opencode/mimo-v2.5-free: benched until" "$PI_PACKET_STATE/watch.log" \
  || fail "mimo-bench: pick_seat must log 'opencode/mimo-v2.5-free: benched until' skip line (log tail: $(tail -3 "$PI_PACKET_STATE/watch.log"))"
# Restore the canonical scratch ledger for any later sections.
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger"

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
ok "mixedcap: glm-5-2 cap=0 does not block sibling swe-1-7 on the same provider"
ok "loud stall: all-dead returns rc=1 with NO USABLE SEAT, empty stdout"
ok "free-first: free lane picked ahead of prepaid on a clean ledger"
ok "rate_limited: stale marker retried, fresh marker excluded"
ok "stale observed_at assumed usable (P4-A inversion fixed)"
ok "credential precheck: empty !cmd / unset \$VAR rejected; set var / literal / no-apiKey fail-open accepted; per-call cache runs !cmd once"
ok "quota_bench: parser handles 'resets in Nd Nh' / 'retry after N' / no-window; is_quota_cap_error matches hard caps, rejects transient 429"
ok "quota_bench: Devin 'message rate limit' / 'reset in 35 minutes' benches swe-1-7 for 2100s (fleet-ops#381)"
ok "enumerate_seats: cursor composer excluded from heavy; cursor-grok-4.6-high re-admitted (fleet-ops#381)"
ok "quota_bench: writer parses window -> bench_until future -> seat_usable skips with 'benched until' log"
ok "quota_bench: pick_seat skips benched seats; all-benched -> rc=1 NO USABLE SEAT (no attempt consumed); expired bench_until -> fail-open pick"
ok "quota_bench: stale observed_at (>6h) with future bench_until still skipped (weekly cap outlives STALE_SECS)"
ok "quota_bench: opencode/mimo-v2.5-free FreeUsageLimitError (no window) benches 900s via provider default; pick_seat skips (fleet-ops#650/661)"

# --- fleet-ops#652 hot-patch: 503 / upstream-overload bench ----------------
# commandcode/minimax-m3-free returned 35 of 200+ tool calls as 503
# "Upstream model provider is temporarily unavailable" in the first 20 min of
# the worker run 2026-08-27T02:17:01Z (AUDITOR-LOG 2026-08-27T03:08Z block).
# is_quota_cap_error did NOT match (no quota/cap keyword in the body), so
# the seat was never benched and pick_seat re-offered the same seat to every
# subsequent worker. The fix: a separate matcher (is_overload_error) + a
# separate writer (mark_seat_overload_bench) + a per-provider default
# (503_bench_default_s, falls back to overload_bench_default_s). All three
# must compose: matcher triggers, writer writes the marker with the
# 600s default, pick_seat skips the seat until bench_until.
#
# 9h-1: is_overload_error detects the live 503 body.
set +e
bash -c 'source "$0"; is_overload_error "$1" "$2"' "$lib" \
    'errorMessage' \
    '503: Upstream model provider is temporarily unavailable.' >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "is_overload: commandcode 503 body must match (rc=$rc)"
# Co-occurrence: a transient 200 with a log line mentioning 'temporarily' is NOT overload.
set +e
bash -c 'source "$0"; is_overload_error "$1" "$2"' "$lib" \
    'temporarily unavailable' \
    '' >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" != "0" ]] || fail "is_overload: 'temporarily unavailable' without 'upstream' must NOT match (co-occurrence guard)"
# Retry-After form (HTTP 503 with explicit window) matches even without 'upstream'.
set +e
bash -c 'source "$0"; is_overload_error "$1" "$2"' "$lib" \
    '' \
    $'HTTP/1.1 503 Service Unavailable\nRetry-After: 30' >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "is_overload: '503 Service Unavailable + Retry-After' must match (rc=$rc)"
# Disjoint from quota/cap: a quota/cap 429 with no upstream word must NOT trigger overload.
set +e
bash -c 'source "$0"; is_overload_error "$1" "$2"' "$lib" \
    '' \
    'INFERENCE_CAP_ERROR: weekly Clinepass limit. The limit resets in 1d 11h' >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" != "0" ]] || fail "is_overload: ClinePass weekly cap text must NOT match (quota path owns it)"
# Empty body: no.
set +e
bash -c 'source "$0"; is_overload_error "$1" "$2"' "$lib" "" "" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" != "0" ]] || fail "is_overload: empty input must NOT match"

# 9h-2: writer uses the 503_bench_default_s (alias overload_bench_default_s)
# when the body has no Retry-After. The summoning-trip fault was the writer
# failing open; this test guarantees the bench actually lands.
cc_ledger="$scratch/ledger-cc-overload"
mkdir -p "$cc_ledger"
cat >"$scratch/seat-caps-cc.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["commandcode"],
  "providers": {
    "commandcode": {
      "cap": 2,
      "class": "free",
      "503_bench_default_s": 600,
      "models": {
        "deepseek/deepseek-v4-flash": 2,
        "minimax/minimax-m3-free": 1
      }
    }
  }
}
JSON
export PI_SEAT_HEALTH_LEDGER_DIR="$cc_ledger"
export PI_PACKET_STATE="$scratch/state-cc-overload"
# Fresh models.json with the commandcode minimax-m3-free row matching seat-caps.
cat >"$scratch/models-cc.json" <<'JSON'
{
  "providers": {
    "commandcode": {
      "models": [
        { "id": "deepseek/deepseek-v4-flash", "cost": { "input": 0 } },
        { "id": "minimax/minimax-m3-free",    "cost": { "input": 0 } }
      ]
    }
  }
}
JSON
export PI_MODELS_JSON="$scratch/models-cc.json"
set +e
SEAT_CAPS_JSON="$scratch/seat-caps-cc.json" \
bash -c 'source "$0"; load_seat_caps; mark_seat_overload_bench "$1" "$2" "$3"' \
    "$lib" "commandcode" "minimax/minimax-m3-free" \
    'errorMessage: 503: Upstream model provider is temporarily unavailable.' \
    >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "overload-writer: commandcode 503 body must write marker (rc=$rc) — was the summoning-trip fault"
cc_lf="$cc_ledger/commandcode__minimax_minimax-m3-free.json"
[[ -f "$cc_lf" ]] || fail "overload-writer: ledger file not written at $cc_lf"
hc=$(jq -r '.health_class' "$cc_lf")
bw=$(jq -r '.bench_window_s' "$cc_lf")
fm=$(jq -r '.failure_mode' "$cc_lf")
hs=$(jq -r '.http_status' "$cc_lf")
[[ "$hc" == "overload_bench" ]] || fail "overload-writer: health_class expected overload_bench, got '$hc'"
[[ "$bw" == "600" ]] || fail "overload-writer: bench_window_s expected 600 (503_bench_default_s), got '$bw'"
[[ "$fm" == "overload_503" ]] || fail "overload-writer: failure_mode expected overload_503, got '$fm'"
[[ "$hs" == "503" ]] || fail "overload-writer: http_status expected 503, got '$hs'"
# bench_until must be in the future (now + 600s, +/- 5s for clock drift).
bu=$(jq -r '.bench_until' "$cc_lf")
bu_s=$(date -u -d "$bu" +%s 2>/dev/null || echo 0)
now_s=$(date -u +%s)
delta=$((bu_s - now_s))
(( delta > 590 && delta < 610 )) || fail "overload-writer: bench_until delta expected ~600s, got ${delta}s (bench_until=$bu)"

# 9h-3: writer uses a parsed Retry-After when the body has one, not the
# 600s default. Confirms the writer actually consults the body first.
cat >"$scratch/seat-caps-cc-short.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["commandcode"],
  "providers": {
    "commandcode": {
      "cap": 2,
      "class": "free",
      "503_bench_default_s": 600,
      "models": { "minimax/minimax-m3-free": 1 }
    }
  }
}
JSON
rm -f "$cc_ledger/commandcode__minimax_minimax-m3-free.json"
set +e
SEAT_CAPS_JSON="$scratch/seat-caps-cc-short.json" \
bash -c 'source "$0"; load_seat_caps; mark_seat_overload_bench "$1" "$2" "$3"' \
    "$lib" "commandcode" "minimax/minimax-m3-free" \
    $'HTTP/1.1 503 Service Unavailable\nRetry-After: 45\n\nUpstream model provider is temporarily unavailable.' \
    >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "overload-writer-retry-after: expected rc=0, got $rc"
bw2=$(jq -r '.bench_window_s' "$cc_ledger/commandcode__minimax_minimax-m3-free.json")
[[ "$bw2" == "45" ]] || fail "overload-writer-retry-after: bench_window_s expected 45 (parsed Retry-After), got '$bw2'"

# 9h-4: writer fails open (no marker) when no Retry-After AND no provider
# default — the same fail-open contract as mark_seat_quota_bench. Without
# a default, pick_seat would re-offer the seat, so the operator MUST set
# 503_bench_default_s for any provider that is observed to 503-storm.
cat >"$scratch/seat-caps-cc-nodefault.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["commandcode"],
  "providers": {
    "commandcode": {
      "cap": 2,
      "class": "free",
      "models": { "minimax/minimax-m3-free": 1 }
    }
  }
}
JSON
rm -f "$cc_ledger/commandcode__minimax_minimax-m3-free.json"
set +e
SEAT_CAPS_JSON="$scratch/seat-caps-cc-nodefault.json" \
bash -c 'source "$0"; load_seat_caps; mark_seat_overload_bench "$1" "$2" "$3"' \
    "$lib" "commandcode" "minimax/minimax-m3-free" \
    'errorMessage: 503: Upstream model provider is temporarily unavailable.' \
    >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "overload-fail-open: commandcode without 503_bench_default_s must rc=1 (fail-open), got $rc"
[[ -f "$cc_ledger/commandcode__minimax_minimax-m3-free.json" ]] \
  && fail "overload-fail-open: no marker must be written without a default" || true
grep -q "overload-bench: commandcode/minimax/minimax-m3-free NOT benched" "$PI_PACKET_STATE/watch.log" \
  || fail "overload-fail-open: must log the NOT-benched line"

# 9h-5: pick_seat must skip the seat when the overload marker is fresh AND
# bench_until is in the future. The summoning-trip fault was that no marker
# was written; this proves the marker DOES make pick_seat route around the
# storming seat. Mirror the 9f-mimo pick_seat check.
# Use a scratch cap with ONLY the benched model so the test exercises the
# NO-USABLE-SEAT path (the seat-caps-cc.json has both models, so pick_seat
# would correctly fall through to the other one — that is NOT the fault we
# are testing for).
cat >"$scratch/seat-caps-cc-only.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["commandcode"],
  "providers": {
    "commandcode": {
      "cap": 1,
      "class": "free",
      "503_bench_default_s": 600,
      "models": { "minimax/minimax-m3-free": 1 }
    }
  }
}
JSON
cc_ledger_only="$scratch/ledger-cc-only"
mkdir -p "$cc_ledger_only"
rm -f "$cc_ledger_only/commandcode__minimax_minimax-m3-free.json"
set +e
SEAT_CAPS_JSON="$scratch/seat-caps-cc-only.json" \
PI_SEAT_HEALTH_LEDGER_DIR="$cc_ledger_only" \
bash -c 'source "$0"; load_seat_caps; mark_seat_overload_bench "$1" "$2" "$3"' \
    "$lib" "commandcode" "minimax/minimax-m3-free" \
    'errorMessage: 503: Upstream model provider is temporarily unavailable.' \
    >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "pick-after-overload: marker must be written, got rc=$rc"
export PI_PACKET_STATE="$scratch/state-cc-overload-pick"
rm -f "$scratch/tried-cc.txt"
set +e
out=$(SEAT_CAPS_JSON="$scratch/seat-caps-cc-only.json" \
      PI_SEAT_HEALTH_LEDGER_DIR="$cc_ledger_only" \
      PI_PACKET_STATE="$scratch/state-cc-overload-pick" \
      PI_MODELS_JSON="$scratch/models-cc.json" \
  bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0 "$1"' "$lib" "$scratch/tried-cc.txt" 2>/dev/null)
rc=$?
set -e
# Only the benched commandcode/minimax-m3-free is allowlisted, so an
# ALL-benched commandcode returns rc=1 NO USABLE SEAT. The acceptance
# criterion is: pick_seat does NOT return the benched commandcode row.
[[ "$rc" == "1" ]] || fail "pick-after-overload: pick_seat must rc=1 (only seat benched), got rc=$rc out='$out'"
grep -q "commandcode/minimax/minimax-m3-free: benched until" "$PI_PACKET_STATE/watch.log" \
  || fail "pick-after-overload: must log the 'benched until' skip line (log tail: $(tail -3 "$PI_PACKET_STATE/watch.log"))"
[[ -z "$out" ]] || fail "pick-after-overload: stdout must be empty (no seat), got '$out'"
# Distinct from quota path: the skip line mentions the overload bench class
# (the auditor distinguishes them via health_class=overload_bench). The
# writer logs 'overload-bench: benched ...' (dash) in PI_PACKET_STATE; the
# seat_usable reader logs 'benched until ... (overload_bench)' (underscore)
# in the pick_seat PI_PACKET_STATE. Accept either, but NOT 'quota_bench' or
# 'quota-bench:' — those would be the wrong class.
grep -q "overload-bench:\|(overload_bench)" "$PI_PACKET_STATE/watch.log" \
  || fail "pick-after-overload: must mention overload class (not quota); log tail: $(tail -5 "$PI_PACKET_STATE/watch.log")"
# Sanity: the quota class is NOT in this log (otherwise the bench class is
# being mis-typed and the post-mortem rollup would be wrong).
grep -q "quota-bench:\|(quota_bench)" "$PI_PACKET_STATE/watch.log" \
  && fail "pick-after-overload: log must NOT mention quota class (would mis-classify the bench) — log tail: $(tail -5 "$PI_PACKET_STATE/watch.log")" || true

# 9h-6: 503_bench_default_s field name. The live seat-caps.json uses the
# 503_bench_default_s key; the alias overload_bench_default_s is also
# accepted (the load loop tries the semantic name first, then the legacy
# 503 name). Use the 503 key explicitly to prove the live config shape
# is loaded — the structural-fix issue relies on this contract.
default_s=$(SEAT_CAPS_JSON="$scratch/seat-caps-cc.json" \
    bash -c 'source "$0"; load_seat_caps; provider_overload_bench_default "$1"' \
    "$lib" "commandcode" 2>/dev/null)
[[ "$default_s" == "600" ]] || fail "field-name-503: provider_overload_bench_default expected 600 (from 503_bench_default_s), got '$default_s'"
# Both key names work.
cat >"$scratch/seat-caps-cc-alias.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["commandcode"],
  "providers": {
    "commandcode": {
      "cap": 2,
      "class": "free",
      "overload_bench_default_s": 600,
      "models": { "minimax/minimax-m3-free": 1 }
    }
  }
}
JSON
default_s2=$(SEAT_CAPS_JSON="$scratch/seat-caps-cc-alias.json" \
    bash -c 'source "$0"; load_seat_caps; provider_overload_bench_default "$1"' \
    "$lib" "commandcode" 2>/dev/null)
[[ "$default_s2" == "600" ]] || fail "field-name-alias: overload_bench_default_s must also be accepted, got '$default_s2'"

# 9h-7: distinguishability from quota_bench. A seat with a quota_bench
# marker (from a prior 429) and a seat with an overload_bench marker
# (from a 503) both block pick_seat, but the failure_mode / health_class
# fields tell the auditor which to roll up. This is a structural
# invariant the post-mortem tooling depends on.
quota_scratch_ledger="$scratch/ledger-quota-disjoint"
mkdir -p "$quota_scratch_ledger"
# Re-write the overload marker to a clean ledger for 9h-7 (the 9h-2/9h-3
# writes to $cc_ledger are still on disk, but 9h-4 rm-f'd the same path
# while exercising the fail-open contract — re-write into a fresh ledger
# so the assert below is hermetic).
overload_scratch_ledger="$scratch/ledger-overload-disjoint"
mkdir -p "$overload_scratch_ledger"
SEAT_CAPS_JSON="$scratch/seat-caps-cc.json" \
PI_SEAT_HEALTH_LEDGER_DIR="$overload_scratch_ledger" \
PI_PACKET_STATE="$scratch/state-overload-disjoint" \
bash -c 'source "$0"; load_seat_caps; mark_seat_overload_bench "$1" "$2" "$3"' \
    "$lib" "commandcode" "minimax/minimax-m3-free" \
    'errorMessage: 503: Upstream model provider is temporarily unavailable.' >/dev/null 2>&1 || true
SEAT_CAPS_JSON="$scratch/seat-caps-cc.json" \
PI_SEAT_HEALTH_LEDGER_DIR="$quota_scratch_ledger" \
PI_PACKET_STATE="$scratch/state-quota-disjoint" \
bash -c 'source "$0"; load_seat_caps; mark_seat_quota_bench "$1" "$2" "$3"' \
    "$lib" "cline" "cline-pass/deepseek-v4-flash" \
    'INFERENCE_CAP_ERROR: weekly Clinepass limit. The limit resets in 1d 11h' >/dev/null 2>&1 || true
quota_hc=$(jq -r '.health_class' "$quota_scratch_ledger/cline__cline-pass_deepseek-v4-flash.json" 2>/dev/null || echo "")
quota_fm=$(jq -r '.failure_mode' "$quota_scratch_ledger/cline__cline-pass_deepseek-v4-flash.json" 2>/dev/null || echo "")
overload_hc=$(jq -r '.health_class' "$overload_scratch_ledger/commandcode__minimax_minimax-m3-free.json" 2>/dev/null || echo "")
overload_fm=$(jq -r '.failure_mode' "$overload_scratch_ledger/commandcode__minimax_minimax-m3-free.json" 2>/dev/null || echo "")
[[ "$quota_hc" == "quota_bench" && "$quota_fm" == "quota_cap" ]] \
  || fail "distinguishability: quota path must write health_class=quota_bench / failure_mode=quota_cap (got $quota_hc / $quota_fm)"
[[ "$overload_hc" == "overload_bench" && "$overload_fm" == "overload_503" ]] \
  || fail "distinguishability: overload path must write health_class=overload_bench / failure_mode=overload_503 (got $overload_hc / $overload_fm)"

# Restore the canonical scratch cap map and ledger for any later sections.
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export PI_MODELS_JSON="$scratch/models.json"

ok "overload_bench: is_overload_error matches commandcode 503 + Retry-After; rejects co-occurrence / quota text / empty"
ok "overload_bench: writer uses 503_bench_default_s=600 when body has no Retry-After; bench_until ~now+600s; failure_mode=overload_503"
ok "overload_bench: writer prefers parsed Retry-After (45s) over provider default (600s)"
ok "overload_bench: writer fails open (rc=1, no marker) when no Retry-After and no 503_bench_default_s"
ok "overload_bench: pick_seat skips a benched commandcode/minimax-m3-free; rc=1 NO USABLE SEAT; logs 'benched until' + 'overload-bench:'"
ok "overload_bench: 503_bench_default_s AND overload_bench_default_s are both accepted as field names"
ok "overload_bench: distinct from quota_bench (health_class / failure_mode) for post-mortem rollup (fleet-ops#652)"

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
# `systemctl --user show UNIT --property=ExecMainStartTimestampMonotonic
# --value` (fleet-ops#993: ActiveEnterTimestampMonotonic is 0 for every
# activating oneshot, so the wedge age is read from ExecMainStart).
# wedged is 3600s into running, fresh 60s, dead failed, trap 0/3600s:
# ActiveEnter-style 0 (the pre-#993 bug) but a real ExecMainStart of 3600s
# -> the #993 regression must NOT be reaped.
systemctl() {
  [[ "$1" == "--user" ]] && shift
  case "$1" in
    is-active)
      case "$2" in
        pi-issue@wedged.service) echo activating ;;
        pi-issue@fresh.service) echo activating ;;
        pi-issue@trap.service) echo activating ;;
        pi-issue@dead.service) echo failed ;;
        *) echo inactive ;;
      esac ;;
    show)
      now_s=$(awk '{print int($1)}' /proc/uptime)
      case "$2" in
        pi-issue@wedged.service) echo "$(( (now_s - 3600) * 1000000 ))" ;;
        pi-issue@fresh.service) echo "$(( (now_s - 60) * 1000000 ))" ;;
        pi-issue@trap.service) echo "$(( (now_s - 1200) * 1000000 ))" ;;
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

# fleet-ops#993 regression: a live activating oneshot has
# ActiveEnterTimestampMonotonic=0 (systemd only stamps it on start
# completion) while ExecMainStartTimestampMonotonic is nonzero. The
# pre-fix probe read ActiveEnter=0 as age = uptime - 0 = 1.4M s and
# reaped EVERY live seat. The trap unit simulates exactly that: 1200s
# ExecMainStart (a legitimately long 20-min run, under the 3300s wedge
# bound), which read as 0 under the old probe. It must stay live.
# shellcheck disable=SC2034
jq -n '{unit:"pi-issue-trap"}' > "$PI_PACKET_STATE/active-seats/pi-issue-trap.json"
set +e
live=$(bash -c 'source "$1"; _seat_live_registry_files' _ "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "#993 regression: _seat_live_registry_files failed rc=$rc"
echo "$live" | grep -q 'pi-issue-trap.json' \
  || fail "#993 regression: ExecMainStart-set activating unit must stay live, got: $live"
ok "#993 regression: ActiveEnter=0 + ExecMainStart set -> live, not reaped"

# Later pick_seat cases are offline again. The stubbed systemctl above would
# also isolate them, but the default must stay 0 so a future edit that drops
# the stub cannot re-bleed live units into scratch caps (fleet-ops#108).
export PI_SEAT_LIB_CHECK_SYSTEMD=0

# --- fleet-ops#387: prepaid lanes alternate instead of stacking ------------
cat >"$scratch/models-rr.json" <<'JSON'
{
  "providers": {
    "alpha": { "models": [ { "id": "a", "cost": { "input": 0 } } ] },
    "beta":  { "models": [ { "id": "b", "cost": { "input": 0 } } ] }
  }
}
JSON
cat >"$scratch/seat-caps-rr.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "prepaid_providers_in_order": ["alpha", "beta"],
  "providers": {
    "alpha": { "cap": 4, "class": "prepaid-quota", "quota_window": "weekly", "weekly_budget": 10, "models": { "a": 4 } },
    "beta":  { "cap": 4, "class": "prepaid-quota", "quota_window": "weekly", "weekly_budget": 10, "models": { "b": 4 } }
  }
}
JSON
ledger="$scratch/ledger-rr"
mkdir -p "$ledger"
export PI_MODELS_JSON="$scratch/models-rr.json"
export SEAT_CAPS_JSON="$scratch/seat-caps-rr.json"
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger"
export PI_PACKET_STATE="$scratch/state-rr"
mkdir -p "$PI_PACKET_STATE"
rm -f "$PI_PACKET_STATE/prepaid-rr.idx"
rm -rf "$PI_PACKET_STATE/prepaid-usage"
got=""
for i in 1 2 3 4; do
  set +e
  one=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0' "$lib" 2>/dev/null)
  set -e
  got="${got}${one}"$'\n'
done
alpha_n=$(printf '%s' "$got" | grep -c '^alpha' || true)
beta_n=$(printf '%s' "$got" | grep -c '^beta' || true)
[[ "$alpha_n" == "2" && "$beta_n" == "2" ]] \
  || fail "prepaid RR: 4 picks across two live prepaid lanes must split 2/2, got alpha=$alpha_n beta=$beta_n picks=$got"
# Consecutive picks must not be the same provider (never-stack).
prev=""
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  p="${line%%	*}"
  if [[ -n "$prev" && "$p" == "$prev" ]]; then
    fail "prepaid RR: consecutive picks stacked on $p (got: $got)"
  fi
  prev="$p"
done <<< "$got"
ok "prepaid RR: two fixture prepaid lanes, 4 packets, distribution alternates 2/2"

# --- fleet-ops#387: weekly pacing backs off before exhaustion --------------
export PI_PACKET_STATE="$scratch/state-pace"
mkdir -p "$PI_PACKET_STATE/prepaid-usage"
rm -f "$PI_PACKET_STATE/prepaid-rr.idx"
week=$(date -u +%G-W%V)
# alpha already at 80% of weekly_budget=10 (thresh=8) -> paced; beta under.
jq -nc --arg w "$week" --argjson c 8 '{week:$w,count:$c}' \
  > "$PI_PACKET_STATE/prepaid-usage/alpha.json"
jq -nc --arg w "$week" --argjson c 0 '{week:$w,count:$c}' \
  > "$PI_PACKET_STATE/prepaid-usage/beta.json"
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0' "$lib" 2>/dev/null)
set -e
[[ "$out" == "beta	b" ]] \
  || fail "weekly pace: alpha at 80% of budget must be skipped in favour of beta, got: $out"
ok "weekly pace: prepaid seat at 80% of weekly_budget is skipped while another prepaid is live"

# --- fleet-ops#437: empty models map skips the live hetzner slug -----------
# Isolated fixtures so later cap-map edits cannot silently drop this case.
mkdir -p "$scratch/437"
cat >"$scratch/437/models.json" <<'JSON'
{
  "providers": {
    "hetzner": {
      "models": [
        { "id": "Qwen/Qwen3.6-35B-A3B-FP8", "cost": { "input": 0 } }
      ]
    },
    "commandcode": {
      "models": [
        { "id": "deepseek/deepseek-v4-flash", "cost": { "input": 0 } }
      ]
    }
  }
}
JSON
cat >"$scratch/437/caps-empty.json" <<'JSON'
{
  "ram_gb_per_worker": 0.75,
  "free_providers_in_order": ["hetzner", "commandcode"],
  "providers": {
    "hetzner": { "cap": 2, "class": "free" },
    "commandcode": { "cap": 2, "class": "free", "models": { "deepseek/deepseek-v4-flash": 2 } }
  }
}
JSON
cat >"$scratch/437/caps-listed.json" <<'JSON'
{
  "ram_gb_per_worker": 0.75,
  "free_providers_in_order": ["hetzner"],
  "providers": {
    "hetzner": { "cap": 2, "class": "free", "models": { "Qwen/Qwen3.6-35B-A3B-FP8": 2 } }
  }
}
JSON
export PI_MODELS_JSON="$scratch/437/models.json"
export SEAT_CAPS_JSON="$scratch/437/caps-empty.json"
export PI_SEAT_HEALTH_LEDGER_DIR="$scratch/437/ledger-empty"
export PI_PACKET_STATE="$scratch/437/state-empty"
mkdir -p "$PI_SEAT_HEALTH_LEDGER_DIR" "$PI_PACKET_STATE"
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "437-empty: expected a fallback pick, got rc=$rc"
if echo "$out" | grep -q '^hetzner'; then
  fail "437-empty: hetzner must not be picked with an empty models map, got: $out"
fi
grep -q "not in cap-map allowlist for hetzner" "$PI_PACKET_STATE/watch.log" \
  || fail "437-empty: must log the allowlist skip for the live Qwen slug"
ok "437-empty: cap=2 hetzner with no models map skips Qwen/Qwen3.6-35B-A3B-FP8"

export SEAT_CAPS_JSON="$scratch/437/caps-listed.json"
export PI_SEAT_HEALTH_LEDGER_DIR="$scratch/437/ledger-listed"
export PI_PACKET_STATE="$scratch/437/state-listed"
mkdir -p "$PI_SEAT_HEALTH_LEDGER_DIR" "$PI_PACKET_STATE"
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "437-listed: expected a pick, got rc=$rc"
[[ "$out" == "hetzner	Qwen/Qwen3.6-35B-A3B-FP8" ]] \
  || fail "437-listed: expected hetzner/Qwen slug, got: $out"
ok "437-listed: allowlisted Qwen/Qwen3.6-35B-A3B-FP8 is pickable"

# fleet-ops#640: allowlisted opencode/mimo-v2.5-free is pickable, including
# as failover when hy3-free is already tried. Isolated fixture so live
# seat-caps cannot leak.
mkdir -p "$scratch/640"
cat >"$scratch/640/models.json" <<'JSON'
{
  "providers": {
    "opencode": {
      "models": [
        { "id": "hy3-free", "cost": { "input": 0 }, "contextWindow": 131072 },
        { "id": "mimo-v2.5-free", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 }
      ]
    }
  }
}
JSON
cat >"$scratch/640/caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["opencode"],
  "providers": {
    "opencode": {
      "cap": 1,
      "class": "free",
      "models": { "hy3-free": 1, "mimo-v2.5-free": 1 }
    }
  }
}
JSON
export PI_MODELS_JSON="$scratch/640/models.json"
export SEAT_CAPS_JSON="$scratch/640/caps.json"
export PI_SEAT_HEALTH_LEDGER_DIR="$scratch/640/ledger"
export PI_PACKET_STATE="$scratch/640/state"
export PI_SEAT_CREDENTIAL_PRECHECK=0
mkdir -p "$PI_SEAT_HEALTH_LEDGER_DIR" "$PI_PACKET_STATE"
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "640-first: expected a pick, got rc=$rc"
[[ "$out" == "opencode	hy3-free" ]] \
  || fail "640-first: expected hy3-free first (models.json order), got: $out"
ok "640-first: hy3-free stays the first opencode pick"

printf 'opencode/hy3-free\n' >"$scratch/640/tried"
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0 "$1"' "$lib" "$scratch/640/tried" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "640-failover: expected a pick, got rc=$rc"
[[ "$out" == "opencode	mimo-v2.5-free" ]] \
  || fail "640-failover: expected mimo-v2.5-free when hy3-free is tried, got: $out"
ok "640-failover: allowlisted mimo-v2.5-free is pickable"

set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 1 "$1"' "$lib" "$scratch/640/tried" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "640-heavy: expected a heavy pick, got rc=$rc"
[[ "$out" == "opencode	mimo-v2.5-free" ]] \
  || fail "640-heavy: mimo-v2.5-free must be heavy-capable, got: $out"
ok "640-heavy: mimo-v2.5-free is pickable for heavy work"

# fleet-ops#910: allowlisted opencode/nemotron-3-ultra-free is pickable as
# failover when hy3-free and mimo-v2.5-free are already tried, and is
# heavy-capable (reasoning + 1M context). Isolated fixture.
mkdir -p "$scratch/910"
cat >"$scratch/910/models.json" <<'JSON'
{
  "providers": {
    "opencode": {
      "models": [
        { "id": "hy3-free", "cost": { "input": 0 }, "contextWindow": 131072 },
        { "id": "mimo-v2.5-free", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 },
        { "id": "nemotron-3-ultra-free", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 1000000 },
        { "id": "nemotron-3-ultra", "cost": { "input": 0.4 }, "reasoning": true, "contextWindow": 1000000 }
      ]
    }
  }
}
JSON
cat >"$scratch/910/caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["opencode"],
  "providers": {
    "opencode": {
      "cap": 1,
      "class": "free",
      "models": { "hy3-free": 1, "mimo-v2.5-free": 1, "nemotron-3-ultra-free": 1 }
    }
  }
}
JSON
export PI_MODELS_JSON="$scratch/910/models.json"
export SEAT_CAPS_JSON="$scratch/910/caps.json"
export PI_SEAT_HEALTH_LEDGER_DIR="$scratch/910/ledger"
export PI_PACKET_STATE="$scratch/910/state"
export PI_SEAT_CREDENTIAL_PRECHECK=0
mkdir -p "$PI_SEAT_HEALTH_LEDGER_DIR" "$PI_PACKET_STATE"
printf 'opencode/hy3-free\nopencode/mimo-v2.5-free\n' >"$scratch/910/tried"
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0 "$1"' "$lib" "$scratch/910/tried" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "910-failover: expected a pick, got rc=$rc"
[[ "$out" == "opencode	nemotron-3-ultra-free" ]] \
  || fail "910-failover: expected nemotron-3-ultra-free when hy3 and mimo are tried, got: $out"
if echo "$out" | grep -qxF 'opencode	nemotron-3-ultra'; then
  fail "910-failover: billing sibling nemotron-3-ultra must not be picked"
fi
ok "910-failover: allowlisted nemotron-3-ultra-free is pickable; billing sibling is not"

set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 1 "$1"' "$lib" "$scratch/910/tried" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "910-heavy: expected a heavy pick, got rc=$rc"
[[ "$out" == "opencode	nemotron-3-ultra-free" ]] \
  || fail "910-heavy: nemotron-3-ultra-free must be heavy-capable, got: $out"
ok "910-heavy: nemotron-3-ultra-free is pickable for heavy work"

unset PI_SEAT_CREDENTIAL_PRECHECK

# fleet-ops#911: allowlisted opencode/nemotron-3.5-lightning-free is pickable,
# including as failover once hy3-free and mimo-v2.5-free are tried, and is
# heavy-capable (reasoning=true). Isolated fixture so live seat-caps cannot
# leak. The billing sibling nemotron-3.5-lightning (no -free) is never picked.
mkdir -p "$scratch/911"
cat >"$scratch/911/models.json" <<'JSON'
{
  "providers": {
    "opencode": {
      "models": [
        { "id": "hy3-free", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 190000 },
        { "id": "mimo-v2.5-free", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 },
        { "id": "nemotron-3.5-lightning-free", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 262144 },
        { "id": "nemotron-3.5-lightning", "cost": { "input": 0.1 }, "reasoning": true, "contextWindow": 262144 }
      ]
    }
  }
}
JSON
cat >"$scratch/911/caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["opencode"],
  "providers": {
    "opencode": {
      "cap": 1,
      "class": "free",
      "models": { "hy3-free": 1, "mimo-v2.5-free": 1, "nemotron-3.5-lightning-free": 1 }
    }
  }
}
JSON
export PI_MODELS_JSON="$scratch/911/models.json"
export SEAT_CAPS_JSON="$scratch/911/caps.json"
export PI_SEAT_HEALTH_LEDGER_DIR="$scratch/911/ledger"
export PI_PACKET_STATE="$scratch/911/state"
export PI_SEAT_CREDENTIAL_PRECHECK=0
mkdir -p "$PI_SEAT_HEALTH_LEDGER_DIR" "$PI_PACKET_STATE"
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "911-first: expected a pick, got rc=$rc"
[[ "$out" == "opencode	hy3-free" ]] \
  || fail "911-first: expected hy3-free first (models.json order), got: $out"
ok "911-first: hy3-free stays the first opencode pick"

printf 'opencode/hy3-free\nopencode/mimo-v2.5-free\n' >"$scratch/911/tried"
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0 "$1"' "$lib" "$scratch/911/tried" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "911-failover: expected a pick, got rc=$rc"
[[ "$out" == "opencode	nemotron-3.5-lightning-free" ]] \
  || fail "911-failover: expected nemotron-3.5-lightning-free when hy3-free and mimo-v2.5-free are tried, got: $out"
ok "911-failover: allowlisted nemotron-3.5-lightning-free is pickable"

set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 1 "$1"' "$lib" "$scratch/911/tried" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "911-heavy: expected a heavy pick, got rc=$rc"
[[ "$out" == "opencode	nemotron-3.5-lightning-free" ]] \
  || fail "911-heavy: nemotron-3.5-lightning-free must be heavy-capable, got: $out"
ok "911-heavy: nemotron-3.5-lightning-free is pickable for heavy work"

# The billing sibling nemotron-3.5-lightning (no -free) is in the catalog but
# not in the allowlist, so it is never picked on the free row.
cat >"$scratch/911/caps-free-only.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["opencode"],
  "providers": {
    "opencode": {
      "cap": 1,
      "class": "free",
      "models": { "nemotron-3.5-lightning-free": 1 }
    }
  }
}
JSON
export SEAT_CAPS_JSON="$scratch/911/caps-free-only.json"
export PI_SEAT_HEALTH_LEDGER_DIR="$scratch/911/ledger-billing"
export PI_PACKET_STATE="$scratch/911/state-billing"
mkdir -p "$PI_SEAT_HEALTH_LEDGER_DIR" "$PI_PACKET_STATE"
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "911-billing: expected a pick, got rc=$rc"
[[ "$out" == "opencode	nemotron-3.5-lightning-free" ]] \
  || fail "911-billing: expected the free slug, got: $out"
if echo "$out" | grep -qxF 'opencode	nemotron-3.5-lightning'; then
  fail "911-billing: billing sibling nemotron-3.5-lightning must not be picked, got: $out"
fi
ok "911-billing: billing sibling nemotron-3.5-lightning is not pickable on the free row"

unset PI_SEAT_CREDENTIAL_PRECHECK

# fleet-ops#638: commandcode Laguna free slug is skippable until listed;
# the billing sibling without -free never joins the allowlist.
mkdir -p "$scratch/638"
cat >"$scratch/638/models.json" <<'JSON'
{
  "providers": {
    "commandcode": {
      "models": [
        { "id": "deepseek/deepseek-v4-flash", "cost": { "input": 0 } },
        { "id": "poolside/laguna-s-2.1-free", "cost": { "input": 0 } },
        { "id": "poolside/laguna-s-2.1", "cost": { "input": 0.1 } }
      ]
    }
  }
}
JSON
cat >"$scratch/638/caps-unlisted.json" <<'JSON'
{
  "ram_gb_per_worker": 0.75,
  "free_providers_in_order": ["commandcode"],
  "providers": {
    "commandcode": { "cap": 2, "class": "free", "models": { "deepseek/deepseek-v4-flash": 2 } }
  }
}
JSON
cat >"$scratch/638/caps-listed.json" <<'JSON'
{
  "ram_gb_per_worker": 0.75,
  "free_providers_in_order": ["commandcode"],
  "providers": {
    "commandcode": { "cap": 2, "class": "free", "models": { "poolside/laguna-s-2.1-free": 1 } }
  }
}
JSON
export PI_MODELS_JSON="$scratch/638/models.json"
export SEAT_CAPS_JSON="$scratch/638/caps-unlisted.json"
export PI_SEAT_HEALTH_LEDGER_DIR="$scratch/638/ledger-unlisted"
export PI_PACKET_STATE="$scratch/638/state-unlisted"
mkdir -p "$PI_SEAT_HEALTH_LEDGER_DIR" "$PI_PACKET_STATE"
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "638-unlisted: expected a fallback pick, got rc=$rc"
if echo "$out" | grep -q 'laguna'; then
  fail "638-unlisted: laguna must not be picked until allowlisted, got: $out"
fi
[[ "$out" == "commandcode	deepseek/deepseek-v4-flash" ]] \
  || fail "638-unlisted: expected commandcode/deepseek incumbent, got: $out"
ok "638-unlisted: unwired poolside/laguna-s-2.1-free is not pickable"

export SEAT_CAPS_JSON="$scratch/638/caps-listed.json"
export PI_SEAT_HEALTH_LEDGER_DIR="$scratch/638/ledger-listed"
export PI_PACKET_STATE="$scratch/638/state-listed"
mkdir -p "$PI_SEAT_HEALTH_LEDGER_DIR" "$PI_PACKET_STATE"
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "638-listed: expected a pick, got rc=$rc"
[[ "$out" == "commandcode	poolside/laguna-s-2.1-free" ]] \
  || fail "638-listed: expected commandcode/poolside/laguna-s-2.1-free, got: $out"
if echo "$out" | grep -qxF 'commandcode	poolside/laguna-s-2.1'; then
  fail "638-listed: billing sibling poolside/laguna-s-2.1 must not be picked"
fi
ok "638-listed: allowlisted poolside/laguna-s-2.1-free is pickable; billing sibling is not"
export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"

# fleet-ops#108: this file is already on ci.yml verify-command. Workers cannot
# add a new workflow line (no Workflows permission). Fail here if it is dropped.
grep -Fq 'bash tests/seat-lib.test.sh' "$repo_root/.github/workflows/ci.yml" \
  || fail "ci.yml verify-command must run tests/seat-lib.test.sh (fleet-ops#108)"
ok "ci.yml still invokes this file"

# fleet-ops#500: the degraded-units sibling must stay on P14. Dropping that
# invoke is how a hyphen glob lands green while this file still runs.
# Cross-file lock: this file stays listed independently (#108), so the
# check still fires if seat-lib-degraded.test.sh is removed from verify-command.
grep -Fq 'bash tests/seat-lib-degraded.test.sh' "$repo_root/.github/workflows/ci.yml" \
  || fail "ci.yml verify-command must run tests/seat-lib-degraded.test.sh (fleet-ops#500)"
ok "ci.yml still invokes seat-lib-degraded.test.sh"

# fleet-ops#202: memory.current vs VmRSS mismatch recorder (CI lists this
# file, not ram-metric-compare.test.sh, because workers cannot edit
# .github/workflows).
bash "$here/ram-metric-compare.test.sh" || fail "ram-metric-compare tests failed"

# fleet-ops#435: same CI constraint. Lock the OpenCode MiniMax M3 billing
# gate and free-slug detector through this listed file.
bash "$here/opencode-m3-catalog-canary.test.sh" || fail "opencode-m3-catalog-canary tests failed"

# fleet-ops#449 / #216 / #491: bin/ram-measure contract. CI lists this
# file, not ram-measure.test.sh (workers cannot edit .github/workflows).
bash "$here/ram-measure.test.sh" || fail "ram-measure tests failed"

# fleet-ops#457: quality-weighted routing. Same CI constraint.
bash "$here/quality-routing.test.sh" || fail "quality-routing tests failed"
# fleet-ops#457: per-role gate audit. rule-enforcement.test.sh currently
# fails validate-matrix on a pre-existing duplicate-source pair, so this
# file is the listed CI host.
bash "$here/role-quality-gates.test.sh" || fail "role-quality-gates tests failed"
# fleet-ops#515: session-close lint. Same CI constraint (worker token
# cannot add a P14 line in .github/workflows/ci.yml).
bash "$here/fleet-findings-queued.test.sh" || fail "fleet-findings-queued tests failed"
# fleet-ops#514: session-close lint for decisions-ledger re-asks. Same
# CI constraint (worker token cannot add a P14 line in ci.yml).
bash "$here/fleet-decisions-ledger.test.sh" || fail "fleet-decisions-ledger tests failed"
# fleet-ops#535: session-close lint for swallowed non-zero. Same CI
# constraint (worker token cannot add a P14 line in ci.yml).
bash "$here/fleet-failed-command-flagged.test.sh" || fail "fleet-failed-command-flagged tests failed"
# fleet-ops#651: read tool offset beyond end of file is a negative result.
bash "$here/fleet-failed-command-read.test.sh" || fail "fleet-failed-command-read tests failed"
# fleet-ops#953: `read` ENOENT with the live wording
#   ENOENT: no such file or directory, access '<path>'
# (isError=true, details={}, no exit-code line) plus a thinking-only
# recovery turn is a swallowed failure. Distinct from the #651
# "Failed to read ...: No such file or directory" fixture. Same CI
# constraint (worker token cannot add a P14 line in ci.yml).
bash "$here/fleet-failed-command-read-enoent-thinking.test.sh" || fail "fleet-failed-command-read-enoent-thinking tests failed"
# fleet-ops#677: 127 ENOENT downstream of a harness block is a cascade, not
# a swallowed failure. Same CI constraint (worker token cannot add a P14 line).
bash "$here/fleet-failed-command-enoent-block.test.sh" || fail "fleet-failed-command-enoent-block tests failed"
# fleet-ops#698: `gh api` 4xx/5xx walked past is a real swallowed failure.
# Same CI constraint (worker token cannot add a P14 line).
bash "$here/fleet-failed-command-gh-api-404.test.sh" || fail "fleet-failed-command-gh-api-404 tests failed"
# fleet-ops#727: a verification canary script (e.g. `npm run canary:*`,
# `node scripts/*-verification.mjs`) that legitimately exits 1 on a
# failed gate walked past is the same class. Same CI constraint
# (worker token cannot add a P14 line in ci.yml).
bash "$here/fleet-failed-command-canary-script-exit-1.test.sh" || fail "fleet-failed-command-canary-script-exit-1 tests failed"
# fleet-ops#784: `systemctl --user status` of a failed unit (exit 3)
# walked past is the same class. Same CI constraint (worker token cannot
# add a P14 line in ci.yml).
bash "$here/fleet-failed-command-systemctl-status-failed.test.sh" || fail "fleet-failed-command-systemctl-status-failed tests failed"
# fleet-ops#793: a debug script just written with the `write` tool,
# then invoked as `bash /tmp/<script>` (no flags, no pipe), that
# exits 1 with `(no output)  Command exited with code 1`. The
# recovery turn is a toolCall (`bash -x ... | tail ...`) with no
# user-facing text. Same CI constraint.
bash "$here/fleet-failed-command-fresh-debug-script.test.sh" || fail "fleet-failed-command-fresh-debug-script tests failed"
# fleet-ops#765: `cd <path>; git status; git log` against a path that
# is not a git checkout (or does not exist) emits `fatal: not a git
# repository` and exit 128. The next assistant turn is a recovery
# toolCall with no user-facing flag. Same CI constraint.
bash "$here/fleet-failed-command-cd-non-git-repo.test.sh" || fail "fleet-failed-command-cd-non-git-repo tests failed"
# fleet-ops#849: `cd <worktree> && git branch -f <branch> origin/main`
# (or `git push --force-with-lease`) on the very branch the worktree
# has checked out is refused with `fatal: cannot force update the
# branch` (exit 128). The next assistant turn is a recovery toolCall
# with no user-facing flag. Same CI constraint.
bash "$here/fleet-failed-command-git-branch-cannot-force-update.test.sh" || fail "fleet-failed-command-git-branch-cannot-force-update tests failed"
# fleet-ops#951: open-issue dedup must use the already-fetched open issue
# list (open_json), not GitHub's search API (which has an indexing delay
# that caused 7 duplicate filings of the same session). Same CI constraint.
bash "$here/fleet-failed-command-dedup-open-list.test.sh" || fail "fleet-failed-command-dedup-open-list tests failed"
# fleet-ops#956: `edit` 'Could not find the exact text' (stale oldText)
# walked past, with a silent read/grep recovery and a later thinking-only
# note that the file was different, is the same class. Same CI constraint.
bash "$here/fleet-failed-command-edit-unmatch.test.sh" || fail "fleet-failed-command-edit-unmatch tests failed"
# fleet-ops#486: heartbeat wrapper rc capture. Same CI constraint.
bash "$here/fleet-heartbeat-rc-propagation.test.sh" || fail "fleet-heartbeat-rc-propagation tests failed"
# fleet-ops#653: same `if ! cmd; then rc=$?` class in siterep-deploy-rollback.
# Same CI constraint (worker token cannot add a P14 line).
bash "$here/siterep-deploy-rollback-rc-propagation.test.sh" || fail "siterep-deploy-rollback-rc-propagation tests failed"

# fleet-ops#497: gate-integrity fixtures. CI lists this file, not the
# gate-integrity tests, because workers cannot edit .github/workflows.
bash "$here/gate-integrity.test.sh" || fail "gate-integrity tests failed"
bash "$here/gate-integrity-config.test.sh" || fail "gate-integrity config tests failed"
# fleet-ops#497: gate-integrity reusable shape. Same CI constraint.
bash "$here/gate-integrity-reusable.test.sh" || fail "gate-integrity reusable tests failed"
# fleet-ops#828: lock the parked reusable's raw-comments contract (the
# 0509#1273 shape: a multi-line attest comment is honoured iff a
# `{marker}: {40-hex}` line appears anywhere in its body, not only when
# the whole body equals that string). Same CI constraint.
bash "$here/gate-integrity-reusable-828.test.sh" || fail "gate-integrity reusable 828 tests failed"

# fleet-ops#703: lock the orcarouter sr-never-vibes citation. Workers
# cannot add a P14 line in .github/workflows/ci.yml; this file is the
# listed CI host.
bash "$here/seat-caps-citation.test.sh" || fail "seat-caps-citation tests failed"

# fleet-ops#819: cancelled-while-queued detector. Workers cannot add a
# P14 line in .github/workflows/ci.yml; this file is the listed CI
# host for the new detector drill.
bash "$here/cancelled-while-queued-detector.test.sh" || fail "cancelled-while-queued-detector tests failed"

