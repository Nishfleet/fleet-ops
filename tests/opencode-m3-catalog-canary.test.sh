#!/usr/bin/env bash
# tests/opencode-m3-catalog-canary.test.sh
#
# Proves the OpenCode MiniMax M3 catalog canary (fleet-ops#435) offline:
#   1. Catalog with hy3-free + billing minimax-m3, seat-caps hy3-free only
#      -> exit 0, OK, no file.
#   2. seat-caps allowlists billing minimax-m3 -> exit 1, LOUD, auto-files.
#   3. Catalog grows minimax-m3-free, not allowlisted -> exit 0, files
#      free-slug-available (discovery must not fail the heartbeat).
#   4. Billing-only catalog (minimax-m3, no -free) -> quiet, no file.
#   5. minimax-m2.7 in catalog is not MiniMax M3.
#   6. Dedup: open issue already carrying the marker -> no second create.
#   7. Production seat-caps has no billing MiniMax M3 on opencode.
#   8. Heartbeat-tier1 wires the canary and propagates a billing fail-loud.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/opencode-m3-catalog-canary"
tier1="$repo_root/bin/fleet-heartbeat-tier1"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$tier1" ]] || fail "missing: $tier1"

scratch="$(mktemp -d -t opencode-m3-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
triage="$scratch/triage.md"
: >"$triage"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export FLEET_OPENCODE_M3_CANARY_REPO="Nishfleet/fleet-ops"
export FLEET_OPENCODE_M3_CANARY_FILE=1

gh_log="$scratch/gh.log"
gh_fake="$scratch/gh"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
case "$*" in
  *"issue list"*)
    if [[ -f "${GH_OPEN_ISSUES:-/dev/null}" ]]; then
      cat "${GH_OPEN_ISSUES}"
    else
      echo '[]'
    fi
    exit 0
    ;;
  *"issue create"*)
    echo "https://github.com/Nishfleet/fleet-ops/issues/999"
    exit 0
    ;;
  *"issue close"*)
    num=$(printf '%s' "$*" | sed -nE 's/.*issue close[[:space:]]+([0-9]+).*/\1/p')
    if [[ -n "$num" ]]; then
      if [[ -f "${GH_CLOSED_ISSUES:-/dev/null}" ]]; then
        printf '%s\n' "$num" >>"${GH_CLOSED_ISSUES}"
      fi
      if [[ -n "${GH_OPEN_ISSUES:-}" && -f "${GH_OPEN_ISSUES}" ]]; then
        if command -v jq >/dev/null 2>&1; then
          tmp="${GH_OPEN_ISSUES}.tmp"
          jq --argjson n "$num" '[.[] | select(.number != $n)]' \
              "${GH_OPEN_ISSUES}" >"$tmp" 2>/dev/null \
              && mv "$tmp" "${GH_OPEN_ISSUES}" || true
        fi
      fi
    fi
    echo "https://github.com/Nishfleet/fleet-ops/issues/$num"
    exit 0
    ;;
esac
exit 0
FAKE
chmod +x "$gh_fake"
export GH="$gh_fake"
export GH_LOG="$gh_log"
export PATH="$scratch:$PATH"

write_caps() {
  cat >"$scratch/seat-caps.json"
}
write_catalog() {
  cat >"$scratch/catalog.json"
}

run_canary() {
  set +e
  env_out=$(
    SEAT_CAPS_JSON="$scratch/seat-caps.json" \
    OPENCODE_CATALOG_JSON="$scratch/catalog.json" \
    FLEET_OPS_REPO="$scratch" \
    "$bin" 2>&1
  )
  env_rc=$?
  set -e
}

# --- 1. known-good: hy3-free wired, billing m3 in catalog, not allowlisted --
: >"$gh_log"
: >"$triage"
write_caps <<'JSON'
{ "providers": { "opencode": { "cap": 1, "class": "free", "models": { "hy3-free": 1 } } } }
JSON
write_catalog <<'JSON'
["hy3-free", "minimax-m3", "minimax-m2.7"]
JSON
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario1: expected rc=0, got $env_rc ($env_out)"
grep -q 'OPENCODE-M3-OK' "$triage" || fail "scenario1: missing OK line"
! grep -q 'issue create' "$gh_log" || fail "scenario1: must not file on the known fail-closed state"
ok "scenario1: billing m3 in catalog, not allowlisted, is quiet"

# --- 2. billing slug allowlisted -> scream + file ---------------------------
: >"$gh_log"
: >"$triage"
write_caps <<'JSON'
{ "providers": { "opencode": { "cap": 1, "class": "free", "models": { "minimax-m3": 1 } } } }
JSON
write_catalog <<'JSON'
["minimax-m3"]
JSON
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario2: expected rc=1, got $env_rc ($env_out)"
grep -q 'OPENCODE-M3-VIOLATION' "$triage" || fail "scenario2: missing VIOLATION"
grep -q 'billing MiniMax M3 slug allowlisted' "$triage" || fail "scenario2: must name the billing slug"
grep -q 'issue create' "$gh_log" || fail "scenario2: must auto-file"
grep -q 'minimax-m3' "$gh_log" || fail "scenario2: filed title must name the slug"
ok "scenario2: billing MiniMax M3 allowlisted screams and auto-files"

# --- 3. free slug appears, not wired -> file, tick stays green --------------
: >"$gh_log"
: >"$triage"
write_caps <<'JSON'
{ "providers": { "opencode": { "cap": 1, "class": "free", "models": { "hy3-free": 1 } } } }
JSON
write_catalog <<'JSON'
["hy3-free", "minimax-m3-free"]
JSON
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario3: discovery must not fail the tick, got $env_rc ($env_out)"
grep -q 'OPENCODE-M3-FREE-AVAILABLE' "$triage" || fail "scenario3: missing FREE-AVAILABLE"
grep -q 'minimax-m3-free' "$triage" || fail "scenario3: must name the free slug"
grep -q 'issue create' "$gh_log" || fail "scenario3: must auto-file"
grep -q 'minimax-m3-free' "$gh_log" || fail "scenario3: filed title must name the slug"
ok "scenario3: free slug appearing auto-files and keeps the tick green"

# --- 4. billing-only catalog is not a discovery -----------------------------
: >"$gh_log"
: >"$triage"
write_caps <<'JSON'
{ "providers": { "opencode": { "cap": 1, "class": "free", "models": { "hy3-free": 1 } } } }
JSON
write_catalog <<'JSON'
{"data":[{"id":"hy3-free"},{"id":"minimax-m3"},{"id":"MiniMax-M3"}]}
JSON
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario4: expected rc=0, got $env_rc ($env_out)"
! grep -q 'OPENCODE-M3-FREE-AVAILABLE' "$triage" || fail "scenario4: billing ids must not look free"
! grep -q 'issue create' "$gh_log" || fail "scenario4: must not file to wire a billing slug"
ok "scenario4: billing-only catalog does not auto-file a wire ticket"

# --- 5. M2.7 is not M3 ------------------------------------------------------
: >"$gh_log"
: >"$triage"
write_caps <<'JSON'
{ "providers": { "opencode": { "cap": 1, "class": "free", "models": { "minimax-m2.7": 1 } } } }
JSON
write_catalog <<'JSON'
["minimax-m2.7", "minimax-m2.5"]
JSON
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario5: expected rc=0, got $env_rc ($env_out)"
! grep -q 'OPENCODE-M3-VIOLATION' "$triage" || fail "scenario5: m2.7 must not trip the M3 billing gate"
! grep -q 'issue create' "$gh_log" || fail "scenario5: must not file"
ok "scenario5: minimax-m2.7 is not MiniMax M3"

# --- 6. dedup against an open issue with the marker -------------------------
: >"$gh_log"
: >"$triage"
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n --arg b $'body\nopencode-m3-catalog-canary: billing-wired minimax-m3\n' \
  '[{number: 42, body: $b}]' >"$GH_OPEN_ISSUES"
write_caps <<'JSON'
{ "providers": { "opencode": { "cap": 1, "class": "free", "models": { "minimax-m3": 1 } } } }
JSON
write_catalog <<'JSON'
["minimax-m3"]
JSON
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario6: expected rc=1, got $env_rc ($env_out)"
grep -q 'issue create' "$gh_log" && fail "scenario6: must not file a duplicate"
ok "scenario6: open issue with marker dedupes"

unset GH_OPEN_ISSUES

# --- 7. production seat-caps has no billing M3 on opencode ------------------
: >"$gh_log"
: >"$triage"
prod_catalog="$scratch/prod-catalog.json"
printf '%s\n' '["hy3-free","minimax-m3"]' >"$prod_catalog"
set +e
prod_out=$(
  SEAT_CAPS_JSON="$repo_root/config/seat-caps.json" \
  OPENCODE_CATALOG_JSON="$prod_catalog" \
  FLEET_OPS_REPO="$repo_root" \
  FLEET_OPENCODE_M3_CANARY_FILE=0 \
  "$bin" 2>&1
)
prod_rc=$?
set -e
[[ "$prod_rc" == "0" ]] || fail "scenario7: production opencode allowlist must not include billing MiniMax M3, got rc=$prod_rc ($prod_out)"
if jq -r '.providers.opencode.models // {} | keys[]' "$repo_root/config/seat-caps.json" \
    | grep -qiE '(^|/)minimax-m3(-|$)'; then
  while IFS= read -r k; do
    lk="${k,,}"
    if [[ "$lk" =~ (^|/)minimax-m3(-|$) ]] && [[ "$lk" != *-free ]] && [[ "$lk" != *"-pass/"* ]]; then
      fail "scenario7: production seat-caps allowlists billing MiniMax M3: $k"
    fi
  done < <(jq -r '.providers.opencode.models // {} | keys[]' "$repo_root/config/seat-caps.json")
fi
ok "scenario7: production seat-caps does not allowlist billing OpenCode MiniMax M3"

# --- 8. heartbeat wiring ----------------------------------------------------
grep -F 'opencode-m3-catalog-canary' "$tier1" >/dev/null \
  || fail "tier1 must invoke opencode-m3-catalog-canary"
grep -F 'opencode_m3_canary_rc' "$tier1" >/dev/null \
  || fail "tier1 must capture opencode_m3_canary_rc"
grep -q '_propagate_crash opencode_m3_canary_rc' "$tier1" \
  || fail "tier1 must use _propagate_crash for opencode_m3_canary_rc (alarm-vs-failure separation)"
grep -q 'bin/opencode-m3-catalog-canary' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/opencode-m3-catalog-canary"
ok "scenario8: heartbeat-tier1 wires the canary, uses _propagate_crash (alarm-vs-failure separation), MANIFEST installs it"

write_cc_catalog() {
  cat >"$scratch/cc-catalog.json"
}

# write_models_zero — empty stub models.json (the canary's bills-wired
# gate only fires when the slug is found with a non-zero cost). Scenarios
# 9, 10, 14, 15, 16, 17, 19 use this so they are independent of a stale
# models.json from scenarios 11/18.
write_models_zero() {
  cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "commandcode": { "models": [] }
  }
}
JSON
}

run_cc_canary() {
  set +e
  env_out=$(
    SEAT_CAPS_JSON="$scratch/seat-caps.json" \
    OPENCODE_CATALOG_JSON="$scratch/catalog.json" \
    COMMANDCODE_CATALOG_JSON="$scratch/cc-catalog.json" \
    FLEET_M3_MODELS_JSON="${FLEET_M3_MODELS_JSON:-$scratch/models.json}" \
    FLEET_OPS_REPO="$scratch" \
    "$bin" 2>&1
  )
  env_rc=$?
  set -e
}

# --- 9. CommandCode billing slug allowlisted -> scream + file --------------
: >"$gh_log"
: >"$triage"
write_caps <<'JSON'
{
  "providers": {
    "opencode": { "cap": 1, "class": "free", "models": { "hy3-free": 1 } },
    "commandcode": { "cap": 2, "class": "free", "models": { "minimax/minimax-m3": 2 } }
  }
}
JSON
write_catalog <<'JSON'
["hy3-free"]
JSON
write_cc_catalog <<'JSON'
["minimax/minimax-m3"]
JSON
: >"$scratch/models.json"
run_cc_canary
[[ "$env_rc" == "1" ]] || fail "scenario9: expected rc=1, got $env_rc ($env_out)"
grep -q 'COMMANDCODE-M3-VIOLATION' "$triage" || fail "scenario9: missing COMMANDCODE violation"
grep -q 'commandcode-billing-wired' "$gh_log" || fail "scenario9: filed body must carry commandcode billing marker"
ok "scenario9: CommandCode billing MiniMax M3 allowlisted screams and auto-files"

# --- 10. CommandCode free slug appears, not wired -> file, tick green ------
: >"$gh_log"
: >"$triage"
write_caps <<'JSON'
{
  "providers": {
    "opencode": { "cap": 1, "class": "free", "models": { "hy3-free": 1 } },
    "commandcode": { "cap": 2, "class": "free", "models": { "deepseek/deepseek-v4-flash": 2 } }
  }
}
JSON
write_catalog <<'JSON'
["hy3-free"]
JSON
write_cc_catalog <<'JSON'
["deepseek/deepseek-v4-flash", "minimax/minimax-m3-free"]
JSON
run_cc_canary
[[ "$env_rc" == "0" ]] || fail "scenario10: discovery must not fail the tick, got $env_rc ($env_out)"
grep -q 'COMMANDCODE-M3-FREE-AVAILABLE' "$triage" || fail "scenario10: missing FREE-AVAILABLE"
grep -q 'minimax/minimax-m3-free' "$triage" || fail "scenario10: must name the free slug"
grep -q 'issue create' "$gh_log" || fail "scenario10: must auto-file"
grep -q 'commandcode-free-slug-available' "$gh_log" || fail "scenario10: filed body must carry commandcode discovery marker"
ok "scenario10: CommandCode free slug appearing auto-files and keeps the tick green"

# --- 11. CommandCode free-form slug with non-zero models.json cost ----------
: >"$gh_log"
: >"$triage"
write_caps <<'JSON'
{
  "providers": {
    "opencode": { "cap": 1, "class": "free", "models": { "hy3-free": 1 } },
    "commandcode": { "cap": 2, "class": "free", "models": { "minimax/minimax-m3-free": 2 } }
  }
}
JSON
write_catalog <<'JSON'
["hy3-free"]
JSON
write_cc_catalog <<'JSON'
["minimax/minimax-m3-free"]
JSON
cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "commandcode": {
      "models": [
        { "id": "minimax/minimax-m3-free", "cost": { "input": 0.3, "output": 1.2 } }
      ]
    }
  }
}
JSON
run_cc_canary
[[ "$env_rc" == "1" ]] || fail "scenario11: billed free-form slug must exit 1, got $env_rc ($env_out)"
grep -q 'COMMANDCODE-M3-VIOLATION' "$triage" || fail "scenario11: missing COMMANDCODE violation"
grep -q 'models.json cost is non-zero' "$triage" || fail "scenario11: must name the cost gate"
grep -q 'commandcode-bills-wired' "$gh_log" || fail "scenario11: filed body must carry bills-wired marker"
ok "scenario11: CommandCode free-form slug with non-zero cost fails closed"

# --- 12. production seat-caps has no billing M3 on commandcode -------------
: >"$gh_log"
: >"$triage"
if jq -r '.providers.commandcode.models // {} | keys[]' "$repo_root/config/seat-caps.json" \
    | grep -qiE '(^|/)minimax-m3(-|$)'; then
  while IFS= read -r k; do
    lk="${k,,}"
    if [[ "$lk" =~ (^|/)minimax-m3(-|$) ]] && [[ "$lk" != *-free ]] && [[ "$lk" != *"-pass/"* ]]; then
      fail "scenario12: production seat-caps allowlists billing MiniMax M3 on commandcode: $k"
    fi
  done < <(jq -r '.providers.commandcode.models // {} | keys[]' "$repo_root/config/seat-caps.json")
fi
printf '%s\n' '["deepseek/deepseek-v4-flash"]' >"$scratch/cc-prod.json"
prod_cc_out=$(
  SEAT_CAPS_JSON="$repo_root/config/seat-caps.json" \
  OPENCODE_CATALOG_JSON="$prod_catalog" \
  COMMANDCODE_CATALOG_JSON="$scratch/cc-prod.json" \
  FLEET_OPS_REPO="$repo_root" \
  FLEET_OPENCODE_M3_CANARY_FILE=0 \
  "$bin" 2>&1
) || fail "scenario12: production commandcode parked state must exit 0 ($prod_cc_out)"
grep -q 'OPENCODE-M3-OK' <<<"$prod_cc_out" || fail "scenario12: production must log OK ($prod_cc_out)"
ok "scenario12: production seat-caps does not allowlist billing CommandCode MiniMax M3"

# --- 13. matrix row is enforced --------------------------------------------
jq -e '.rules[] | select(.id == "led-worker-lane-refresh" and .status == "enforced")' \
  "$repo_root/config/rule-enforcement.json" >/dev/null \
  || fail "scenario13: led-worker-lane-refresh must be status=enforced"
ok "scenario13: led-worker-lane-refresh is enforced in the rule matrix"

# --- 14. observe-to-close: commandcode free-slug-available clears ---------
# The canary auto-filed this when the slug was unwired; the slug is now
# wired (live spawn + meter check passed). The stale issue must close
# (fleet-ops#687).
: >"$gh_log"
: >"$triage"
: >"$scratch/closed.log"
write_models_zero
export GH_CLOSED_ISSUES="$scratch/closed.log"
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n --arg b $'body\nopencode-m3-catalog-canary: commandcode-free-slug-available minimax/minimax-m3-free\n' \
  '[{number: 687, body: $b}]' >"$GH_OPEN_ISSUES"
write_caps <<'JSON'
{
  "providers": {
    "opencode": { "cap": 1, "class": "free", "models": { "hy3-free": 1 } },
    "commandcode": { "cap": 2, "class": "free", "models": { "deepseek/deepseek-v4-flash": 2, "minimax/minimax-m3-free": 1 } }
  }
}
JSON
write_catalog <<'JSON'
["hy3-free"]
JSON
write_cc_catalog <<'JSON'
["deepseek/deepseek-v4-flash", "minimax/minimax-m3-free"]
JSON
run_cc_canary
[[ "$env_rc" == "0" ]] || fail "scenario14: clean tick must stay rc=0, got $env_rc ($env_out)"
grep -q 'observe-to-close: CLOSED issue #687' <<<"$env_out" \
  || fail "scenario14: must close #687 (the wired-free case), env_out=$env_out"
grep -q 'issue close 687' "$gh_log" \
  || fail "scenario14: gh must receive close 687, gh_log=$gh_log"
grep -q '^687$' "$scratch/closed.log" \
  || fail "scenario14: closed issue ledger must record 687 (got $(cat "$scratch/closed.log"))"
! grep -q 'issue create' "$gh_log" \
  || fail "scenario14: must not re-file an already-closed issue"
ok "scenario14: commandcode free-slug-available clears when wired, closes the stale issue"

# --- 15. observe-to-close: opencode free-slug-available clears -------------
: >"$gh_log"
: >"$triage"
: >"$scratch/closed.log"
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n --arg b $'body\nopencode-m3-catalog-canary: free-slug-available hy3-free\n' \
  '[{number: 615, body: $b}]' >"$GH_OPEN_ISSUES"
write_caps <<'JSON'
{ "providers": { "opencode": { "cap": 1, "class": "free", "models": { "hy3-free": 1 } } } }
JSON
write_catalog <<'JSON'
["hy3-free"]
JSON
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario15: clean tick must stay rc=0, got $env_rc ($env_out)"
grep -q 'observe-to-close: CLOSED issue #615' <<<"$env_out" \
  || fail "scenario15: must close #615 (the wired opencode free case), env_out=$env_out"
grep -q 'issue close 615' "$gh_log" \
  || fail "scenario15: gh must receive close 615, gh_log=$gh_log"
grep -q '^615$' "$scratch/closed.log" \
  || fail "scenario15: closed issue ledger must record 615"
ok "scenario15: opencode free-slug-available clears when wired, closes the stale issue"

# --- 16. observe-to-close: commandcode billing-wired clears when slug removed
: >"$gh_log"
: >"$triage"
: >"$scratch/closed.log"
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n --arg b $'body\nopencode-m3-catalog-canary: commandcode-billing-wired minimax/minimax-m3\n' \
  '[{number: 616, body: $b}]' >"$GH_OPEN_ISSUES"
write_caps <<'JSON'
{
  "providers": {
    "opencode": { "cap": 1, "class": "free", "models": { "hy3-free": 1 } },
    "commandcode": { "cap": 2, "class": "free", "models": { "deepseek/deepseek-v4-flash": 2 } }
  }
}
JSON
write_catalog <<'JSON'
["hy3-free"]
JSON
write_cc_catalog <<'JSON'
["deepseek/deepseek-v4-flash"]
JSON
run_cc_canary
[[ "$env_rc" == "0" ]] || fail "scenario16: clean tick must stay rc=0, got $env_rc ($env_out)"
grep -q 'observe-to-close: CLOSED issue #616' <<<"$env_out" \
  || fail "scenario16: must close #616 (the unwired-billing case), env_out=$env_out"
grep -q 'issue close 616' "$gh_log" \
  || fail "scenario16: gh must receive close 616, gh_log=$gh_log"
grep -q '^616$' "$scratch/closed.log" \
  || fail "scenario16: closed issue ledger must record 616"
ok "scenario16: commandcode billing-wired clears when slug removed from seat-caps"

# --- 17. observe-to-close: signal STILL active -> keep the issue open ------
# A free-slug-available issue is still in catalog AND not wired. The canary
# must NOT close it. The discover path also re-fires the loud (no new file
# because dedup).
: >"$gh_log"
: >"$triage"
: >"$scratch/closed.log"
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n --arg b $'body\nopencode-m3-catalog-canary: commandcode-free-slug-available minimax/minimax-m3-free\n' \
  '[{number: 687, body: $b}]' >"$GH_OPEN_ISSUES"
write_caps <<'JSON'
{
  "providers": {
    "opencode": { "cap": 1, "class": "free", "models": { "hy3-free": 1 } },
    "commandcode": { "cap": 2, "class": "free", "models": { "deepseek/deepseek-v4-flash": 2 } }
  }
}
JSON
write_catalog <<'JSON'
["hy3-free"]
JSON
write_cc_catalog <<'JSON'
["deepseek/deepseek-v4-flash", "minimax/minimax-m3-free"]
JSON
run_cc_canary
[[ "$env_rc" == "0" ]] || fail "scenario17: discovery tick must stay rc=0, got $env_rc ($env_out)"
! grep -q 'observe-to-close: CLOSED issue #687' <<<"$env_out" \
  || fail "scenario17: must NOT close #687 while the signal is still active"
! grep -q '^687$' "$scratch/closed.log" \
  || fail "scenario17: must not record 687 in the close ledger"
grep -q 'COMMANDCODE-M3-FREE-AVAILABLE' "$triage" \
  || fail "scenario17: must still LOUD the unwired free slug"
ok "scenario17: signal-still-active issue is kept open (no false close)"

# --- 18. observe-to-close: bills-wired clears when models.json cost -> 0 --
: >"$gh_log"
: >"$triage"
: >"$scratch/closed.log"
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n --arg b $'body\nopencode-m3-catalog-canary: commandcode-bills-wired minimax/minimax-m3-free\n' \
  '[{number: 618, body: $b}]' >"$GH_OPEN_ISSUES"
write_caps <<'JSON'
{
  "providers": {
    "opencode": { "cap": 1, "class": "free", "models": { "hy3-free": 1 } },
    "commandcode": { "cap": 2, "class": "free", "models": { "minimax/minimax-m3-free": 2 } }
  }
}
JSON
write_catalog <<'JSON'
["hy3-free"]
JSON
write_cc_catalog <<'JSON'
["minimax/minimax-m3-free"]
JSON
cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "commandcode": {
      "models": [
        { "id": "minimax/minimax-m3-free", "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 } }
      ]
    }
  }
}
JSON
run_cc_canary
[[ "$env_rc" == "0" ]] || fail "scenario18: clean tick must stay rc=0, got $env_rc ($env_out)"
grep -q 'observe-to-close: CLOSED issue #618' <<<"$env_out" \
  || fail "scenario18: must close #618 (cost now zero), env_out=$env_out"
grep -q 'issue close 618' "$gh_log" \
  || fail "scenario18: gh must receive close 618, gh_log=$gh_log"
grep -q '^618$' "$scratch/closed.log" \
  || fail "scenario18: closed issue ledger must record 618"
ok "scenario18: commandcode bills-wired clears when models.json cost is now zero"

# --- 19. observe-to-close: production seat-caps closes #687 ----------------
# This is the live-shaped scenario. The current seat-caps already has
# minimax/minimax-m3-free wired on commandcode (PR #761 / fleet-ops#637).
# Issue #687 (the canary's auto-filed duplicate) should be closed by
# observe-to-close on the next tick.
prod_open="$scratch/prod-open.json"
jq -n --arg b $'body\nopencode-m3-catalog-canary: commandcode-free-slug-available minimax/minimax-m3-free\n' \
  '[{number: 687, body: $b}]' >"$prod_open"
: >"$scratch/closed.log"
printf '%s\n' '["hy3-free"]' >"$scratch/prod-oc.json"
printf '%s\n' '["deepseek/deepseek-v4-flash","minimax/minimax-m3-free"]' >"$scratch/prod-cc.json"
set +e
prod_obs_out=$(
  SEAT_CAPS_JSON="$repo_root/config/seat-caps.json" \
  OPENCODE_CATALOG_JSON="$scratch/prod-oc.json" \
  COMMANDCODE_CATALOG_JSON="$scratch/prod-cc.json" \
  FLEET_OPS_REPO="$repo_root" \
  FLEET_OPENCODE_M3_CANARY_FILE=1 \
  GH_OPEN_ISSUES="$prod_open" \
  GH_CLOSED_ISSUES="$scratch/closed.log" \
  GH="$gh_fake" \
  "$bin" 2>&1
)
prod_obs_rc=$?
set -e
[[ "$prod_obs_rc" == "0" ]] || fail "scenario19: production observe-to-close tick must exit 0, got $prod_obs_rc ($prod_obs_out)"
grep -q 'observe-to-close: CLOSED issue #687' <<<"$prod_obs_out" \
  || fail "scenario19: production tick must close #687 ($prod_obs_out)"
ok "scenario19: production seat-caps closes the stale #687 via observe-to-close"

unset GH_OPEN_ISSUES GH_CLOSED_ISSUES

ok "opencode-m3-catalog-canary: billing gate, free-slug detector, m2.7 ignore, dedup, production clean, commandcode fail-closed, observe-to-close"
