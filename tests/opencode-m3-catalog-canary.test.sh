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
grep -F -- 'exit "$opencode_m3_canary_rc"' "$tier1" >/dev/null \
  || fail "tier1 must exit non-zero when the billing gate fails loud"
grep -q 'bin/opencode-m3-catalog-canary' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/opencode-m3-catalog-canary"
ok "scenario8: heartbeat-tier1 wires the canary, fail-loud on billing, MANIFEST installs it"

write_cc_catalog() {
  cat >"$scratch/cc-catalog.json"
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

ok "opencode-m3-catalog-canary: billing gate, free-slug detector, m2.7 ignore, dedup, production clean, commandcode fail-closed"
