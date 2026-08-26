#!/usr/bin/env bash
# tests/entitled-wired-canary.test.sh
#
# Proves the entitled-vs-wired canary (fleet-ops#387, #437) offline:
#   1. Matching inventory + seat-caps (dated cap=0) -> exit 0, OK line.
#   2. Fixture entitlement with no seat-caps row -> exit 1, LOUD, auto-files.
#   3. cap=0 without a dated reason -> exit 1, files cap0-no-reason.
#   4. prepaid-quota entitlement labelled free -> exit 1, files class-mismatch.
#   5. Dedup: an open issue already carrying the marker -> no second create.
#   6. Production inventory + production seat-caps are currently clean.
#   7. Heartbeat-tier1 wires the canary and propagates a non-zero exit.
#   8. cap>0 free/prepaid with an empty models map -> exit 1, files empty-models
#      (fleet-ops#437: hetzner was listed for routing but pick_seat skipped
#      every live slug).
#   9. cap>0 metered with an empty models map stays quiet (allowlist owned
#      by fleet-ops#384).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-entitled-wired-canary"
tier1="$repo_root/bin/fleet-heartbeat-tier1"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$tier1" ]] || fail "missing: $tier1"

scratch="$(mktemp -d -t entitled-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
triage="$scratch/triage.md"
: >"$triage"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export FLEET_ENTITLED_CANARY_REPO="Nishfleet/fleet-ops"
export FLEET_ENTITLED_CANARY_FILE=1

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

write_inventory() {
  cat >"$scratch/entitled.json"
}
write_caps() {
  cat >"$scratch/seat-caps.json"
}

run_canary() {
  set +e
  env_out=$(
    FLEET_ENTITLED_SEATS_JSON="$scratch/entitled.json" \
    SEAT_CAPS_JSON="$scratch/seat-caps.json" \
    FLEET_OPS_REPO="$scratch" \
    "$bin" 2>&1
  )
  env_rc=$?
  set -e
}

# --- 1. clean match ----------------------------------------------------------
: >"$gh_log"
: >"$triage"
write_inventory <<'JSON'
{ "seats": [ { "id": "ollama", "class": "prepaid-quota" } ] }
JSON
write_caps <<'JSON'
{ "providers": { "ollama": { "cap": 4, "class": "prepaid-quota", "models": { "deepseek-v4-flash:0731": 4 } } } }
JSON
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario1: expected rc=0, got $env_rc ($env_out)"
grep -q 'ENTITLED-WIRED-OK' "$triage" || fail "scenario1: missing OK line"
! grep -q 'issue create' "$gh_log" || fail "scenario1: must not file on a clean map"
ok "scenario1: matching inventory is quiet"

# --- 2. missing row -> scream + file ----------------------------------------
: >"$gh_log"
: >"$triage"
write_inventory <<'JSON'
{ "seats": [ { "id": "ghost-lane", "class": "free" } ] }
JSON
write_caps <<'JSON'
{ "providers": { "ollama": { "cap": 4, "class": "prepaid-quota" } } }
JSON
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario2: expected rc=1, got $env_rc ($env_out)"
grep -q 'ENTITLED-WIRED-VIOLATION' "$triage" || fail "scenario2: missing VIOLATION"
grep -q 'ghost-lane has no seat-caps row' "$triage" || fail "scenario2: must name the missing seat"
grep -q 'issue create' "$gh_log" || fail "scenario2: must auto-file"
grep -q 'ghost-lane has no seat-caps row' "$gh_log" || fail "scenario2: filed title must name the seat"
ok "scenario2: fixture entitlement with no row screams and auto-files"

# --- 3. cap=0 without dated reason ------------------------------------------
: >"$gh_log"
: >"$triage"
write_inventory <<'JSON'
{ "seats": [ { "id": "grok", "class": "prepaid-quota" } ] }
JSON
write_caps <<'JSON'
{ "providers": { "grok": { "cap": 0, "class": "prepaid-quota" } } }
JSON
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario3: expected rc=1, got $env_rc ($env_out)"
grep -q 'cap=0 without a dated reason' "$triage" || fail "scenario3: must name the undated cap=0"
grep -q 'issue create' "$gh_log" || fail "scenario3: must auto-file"
ok "scenario3: cap=0 without dated reason screams and files"

# --- 4. prepaid labelled free -----------------------------------------------
: >"$gh_log"
: >"$triage"
write_inventory <<'JSON'
{ "seats": [ { "id": "ollama", "class": "prepaid-quota" } ] }
JSON
write_caps <<'JSON'
{ "providers": { "ollama": { "cap": 4, "class": "free", "models": { "deepseek-v4-flash:0731": 4 } } } }
JSON
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario4: expected rc=1, got $env_rc ($env_out)"
grep -q 'mislabeled' "$triage" || fail "scenario4: must flag the class mismatch"
grep -q 'issue create' "$gh_log" || fail "scenario4: must auto-file"
ok "scenario4: prepaid labelled free screams and files"

# --- 5. dedup against an open issue with the marker -------------------------
: >"$gh_log"
: >"$triage"
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n --arg b $'body\nentitled-wired-canary: ghost-lane missing-row\n' \
  '[{number: 42, body: $b}]' >"$GH_OPEN_ISSUES"
write_inventory <<'JSON'
{ "seats": [ { "id": "ghost-lane", "class": "free" } ] }
JSON
write_caps <<'JSON'
{ "providers": { "ollama": { "cap": 4, "class": "prepaid-quota" } } }
JSON
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario5: expected rc=1, got $env_rc ($env_out)"
grep -q 'issue create' "$gh_log" && fail "scenario5: must not file a duplicate"
ok "scenario5: open issue with marker dedupes"

unset GH_OPEN_ISSUES

# --- 6. production files currently match ------------------------------------
: >"$gh_log"
: >"$triage"
set +e
prod_out=$(
  FLEET_ENTITLED_SEATS_JSON="$repo_root/config/entitled-seats.json" \
  SEAT_CAPS_JSON="$repo_root/config/seat-caps.json" \
  FLEET_OPS_REPO="$repo_root" \
  FLEET_ENTITLED_CANARY_FILE=0 \
  "$bin" 2>&1
)
prod_rc=$?
set -e
[[ "$prod_rc" == "0" ]] || fail "scenario6: production inventory vs seat-caps must be clean, got rc=$prod_rc ($prod_out)"
ok "scenario6: production entitled-seats.json matches seat-caps.json"

# --- 7. heartbeat wiring -----------------------------------------------------
grep -F 'fleet-entitled-wired-canary' "$tier1" >/dev/null \
  || fail "tier1 must invoke fleet-entitled-wired-canary"
grep -F 'entitled_canary_rc' "$tier1" >/dev/null \
  || fail "tier1 must capture entitled_canary_rc"
grep -F -- 'exit "$entitled_canary_rc"' "$tier1" >/dev/null \
  || fail "tier1 must exit non-zero when the entitled-vs-wired canary fails loud"
ok "scenario7: heartbeat-tier1 wires the canary and propagates fail-loud"

# --- 8. cap>0 free lane with empty models map (fleet-ops#437) --------------
: >"$gh_log"
: >"$triage"
write_inventory <<'JSON'
{ "seats": [ { "id": "hetzner", "class": "free" } ] }
JSON
write_caps <<'JSON'
{ "providers": { "hetzner": { "cap": 2, "class": "free" } } }
JSON
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario8: expected rc=1, got $env_rc ($env_out)"
grep -q 'empty model allowlist' "$triage" || fail "scenario8: must name the empty allowlist"
grep -q 'issue create' "$gh_log" || fail "scenario8: must auto-file"
grep -q 'empty model allowlist' "$gh_log" || fail "scenario8: filed title must name the empty allowlist"
ok "scenario8: cap>0 free lane with empty models map screams and auto-files"

# --- 9. metered cap>0 empty models is #384, not this canary ----------------
: >"$gh_log"
: >"$triage"
write_inventory <<'JSON'
{ "seats": [ { "id": "zenmux", "class": "metered" } ] }
JSON
write_caps <<'JSON'
{ "providers": { "zenmux": { "cap": 2, "class": "metered" } } }
JSON
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario9: metered empty models must stay quiet, got rc=$env_rc ($env_out)"
grep -q 'issue create' "$gh_log" && fail "scenario9: must not file on a metered empty map"
ok "scenario9: metered cap>0 empty models stays quiet (fleet-ops#384)"

# Production lock: the live Qwen slug is allowlisted so pick_seat can pick it.
jq -e '.providers.hetzner.cap > 0 and .providers.hetzner.models["Qwen/Qwen3.6-35B-A3B-FP8"] != null' \
  "$repo_root/config/seat-caps.json" >/dev/null \
  || fail "production lock: hetzner must allowlist Qwen/Qwen3.6-35B-A3B-FP8"

ok "entitled-wired-canary: missing row, undated cap=0, class mismatch, empty-models, dedup, production clean"
