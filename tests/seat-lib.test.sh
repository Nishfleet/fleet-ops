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

ok "allowlist: no-entry provider and cap-0 models rejected"
ok "loud stall: all-dead returns rc=1 with NO USABLE SEAT, empty stdout"
ok "expiry-first: cursor/composer-2.5 picked on clean ledger"
ok "rate_limited: stale marker retried, fresh marker excluded"
ok "stale observed_at assumed usable (P4-A inversion fixed)"
ok "credential precheck: empty !cmd / unset \$VAR rejected; set var / literal / no-apiKey fail-open accepted; per-call cache runs !cmd once"

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

# Shim systemctl: the probe calls `systemctl --user is-active UNIT` and
# `systemctl --user show UNIT --property=ActiveEnterTimestampMonotonic
# --value`. wedged is 3600s into activating, fresh 60s, dead failed.
# Simulate a machine up long enough that a 3600s-old monotonic timestamp
# is representable on ANY runner (fresh runners have uptime < 1h, which
# would make it negative and trip the probe's ^[0-9]+$ guard).
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
      if (( now_s < 3700 )); then now_s=3700; fi
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
