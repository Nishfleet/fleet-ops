#!/usr/bin/env bash
# tests/fleet-free-roster-canary.test.sh
#
# Proves the free-model roster canary (fleet-ops#518) offline:
#   1. Clean: free provider wired, free slug in catalog + allowlist -> OK, no file.
#   2. Ollama carve-out: non-deepseek-v4-flash model in ollama.models -> exit 1,
#      LOUD, auto-files. ollama catalog is never polled.
#   3. Ollama carve-out: deepseek-v4-flash:0731 allowlisted -> clean (gate passes).
#   4. Penny-for-speed: free provider cap>0 with models, missing from
#      free_providers_in_order -> exit 1, LOUD, auto-files.
#   5. New free slug in catalog, not wired -> exit 0, files audition+wire
#      (discovery must not fail the heartbeat).
#   6. Billing slug (no -free / no *-pass/) in catalog is not a discovery.
#   7. Stale wired free slug gone from catalog -> exit 0, files bench.
#   8. Per-tick file cap throttles filings.
#   9. Dedup: open issue already carrying the marker -> no second create.
#  10. pi missing -> exit 1 (watcher broken, fail loud).
#  11. Production seat-caps: ollama allowlist is deepseek-v4-flash only; every
#      cap>0 free provider with models is in free_providers_in_order.
#  12. Heartbeat-tier1 wires the canary and propagates a gate fail-loud.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-free-roster-canary"
tier1="$repo_root/bin/fleet-heartbeat-tier1"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$tier1" ]] || fail "missing: $tier1"

scratch="$(mktemp -d -t free-roster-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
triage="$scratch/triage.md"
: >"$triage"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export FLEET_FREE_ROSTER_REPO="Nishfleet/fleet-ops"
export FLEET_FREE_ROSTER_FILE=1

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

pi_fake="$scratch/pi"
cat >"$pi_fake" <<'PIFAKE'
#!/usr/bin/env bash
if [[ "$*" == *"--list-models"* ]]; then
  # Tests supply the catalog as a fixture; a stray --list-models is an error.
  exit 1
fi
provider=""
model=""
while (( $# )); do
  case "$1" in
    --provider) provider="$2"; shift 2 ;;
    --model)    model="$2";    shift 2 ;;
    *)          shift ;;
  esac
done
if [[ ":${FLEET_FREE_ROSTER_PROBE_FAIL:-}:" == *":$provider/$model:"* ]]; then
  printf '500: {"type":"error","message":"Internal server error"}\n'
  printf 'PACKET-VERDICT tools=0 class=no-tools\n'
  exit 1
fi
printf 'PONG received.\n'
printf 'PACKET-VERDICT tools=0 class=no-tools\n'
exit 0
PIFAKE
chmod +x "$pi_fake"
export PI="$pi_fake"

write_caps()   { cat >"$scratch/seat-caps.json"; }
write_entitled() { cat >"$scratch/entitled-seats.json"; }
write_catalog() { cat >"$scratch/catalog.tsv"; }

run_canary() {
  set +e
  env_out=$(
    FLEET_ENTITLED_SEATS_JSON="$scratch/entitled-seats.json" \
    SEAT_CAPS_JSON="$scratch/seat-caps.json" \
    FLEET_FREE_ROSTER_CATALOG_JSON="$scratch/catalog.tsv" \
    FLEET_FREE_ROSTER_PROBE_TIMEOUT=5 \
    FLEET_OPS_REPO="$scratch" \
    FLEET_FREE_ROSTER_OBSERVE_TO_CLOSE="${FLEET_FREE_ROSTER_OBSERVE_TO_CLOSE:-0}" \
    FLEET_FREE_ROSTER_OBSERVE_SENTINEL="${FLEET_FREE_ROSTER_OBSERVE_SENTINEL:-$scratch/no-such-sentinel}" \
    "$bin" 2>&1
  )
  env_rc=$?
  set -e
}

# Helper: create a fresh sentinel file for opt-in tests. Tests that exercise
# the close path touch this; the canary refuses to close if the sentinel is
# missing or stale. This mirrors the production-heartbeat behavior.
touch_sentinel() {
    sentinel_path="${FLEET_FREE_ROSTER_OBSERVE_SENTINEL:-$scratch/fleet-free-roster-trusted}"
    mkdir -p "$(dirname "$sentinel_path")" 2>/dev/null || true
    : >"$sentinel_path"
    export FLEET_FREE_ROSTER_OBSERVE_SENTINEL="$sentinel_path"
}

# A minimal entitled inventory used by most scenarios. The canary derives
# free providers from seat-caps class, not the inventory, but loads the
# inventory for the missing-file guard.
base_entitled() {
  write_entitled <<'JSON'
{ "seats": [ { "id": "opencode", "class": "free" }, { "id": "ollama", "class": "prepaid-quota" } ] }
JSON
}

# --- 1. clean: wired free slug in catalog + allowlist -> OK, no file -------
: >"$gh_log"; : >"$triage"
base_entitled
write_caps <<'JSON'
{ "free_providers_in_order": ["opencode"],
  "providers": { "opencode": { "cap": 1, "class": "free", "models": { "hy3-free": 1 } } } }
JSON
write_catalog <<'TSV'
opencode	hy3-free
opencode	minimax-m3
TSV
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario1: expected rc=0, got $env_rc ($env_out)"
grep -q 'FREE-ROSTER-OK' "$triage" || fail "scenario1: missing OK line"
! grep -q 'issue create' "$gh_log" || fail "scenario1: must not file on the clean state"
ok "scenario1: wired free slug in catalog is quiet"

# --- 2. Ollama carve-out: non-ds-v4-flash allowlisted -> scream + file -----
: >"$gh_log"; : >"$triage"
base_entitled
write_caps <<'JSON'
{ "free_providers_in_order": [],
  "providers": { "ollama": { "cap": 4, "class": "prepaid-quota", "models": { "kimi-k2.7-code": 1 } } } }
JSON
write_catalog <<'TSV'
ollama	kimi-k2.7-code
ollama	deepseek-v4-flash:0731
TSV
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario2: expected rc=1, got $env_rc ($env_out)"
grep -q 'FREE-ROSTER-VIOLATION' "$triage" || fail "scenario2: missing VIOLATION"
grep -q 'Ollama carve-out' "$triage" || fail "scenario2: must name the carve-out"
grep -q 'kimi-k2.7-code' "$triage" || fail "scenario2: must name the banned slug"
grep -q 'issue create' "$gh_log" || fail "scenario2: must auto-file"
grep -q 'kimi-k2.7-code' "$gh_log" || fail "scenario2: filed title must name the slug"
ok "scenario2: non-ds-v4-flash on ollama screams and auto-files"

# --- 3. Ollama carve-out: deepseek-v4-flash:0731 allowlisted -> clean -----
: >"$gh_log"; : >"$triage"
base_entitled
write_caps <<'JSON'
{ "free_providers_in_order": [],
  "providers": { "ollama": { "cap": 4, "class": "prepaid-quota", "models": { "deepseek-v4-flash:0731": 4 } } } }
JSON
write_catalog <<'TSV'
ollama	deepseek-v4-flash:0731
TSV
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario3: expected rc=0, got $env_rc ($env_out)"
grep -q 'FREE-ROSTER-OK' "$triage" || fail "scenario3: ds-v4-flash allowlist must be clean"
ok "scenario3: deepseek-v4-flash on ollama passes the carve-out gate"

# --- 4. penny-for-speed: free provider missing from order -> scream -------
: >"$gh_log"; : >"$triage"
base_entitled
write_caps <<'JSON'
{ "free_providers_in_order": [],
  "providers": { "opencode": { "cap": 1, "class": "free", "models": { "hy3-free": 1 } } } }
JSON
write_catalog <<'TSV'
opencode	hy3-free
TSV
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario4: expected rc=1, got $env_rc ($env_out)"
grep -q 'penny-for-speed' "$triage" || fail "scenario4: missing penny-for-speed"
grep -q 'opencode' "$triage" || fail "scenario4: must name the provider"
grep -q 'issue create' "$gh_log" || fail "scenario4: must auto-file"
ok "scenario4: free provider missing from free_providers_in_order screams"

# --- 5. new free slug in catalog, not wired -> file, tick stays green ------
: >"$gh_log"; : >"$triage"
base_entitled
write_caps <<'JSON'
{ "free_providers_in_order": ["opencode"],
  "providers": { "opencode": { "cap": 1, "class": "free", "models": { "hy3-free": 1 } } } }
JSON
write_catalog <<'TSV'
opencode	hy3-free
opencode	mimo-v2.5-free
TSV
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario5: discovery must not fail the tick, got $env_rc ($env_out)"
grep -q 'FREE-ROSTER-AVAILABLE' "$triage" || fail "scenario5: missing FREE-AVAILABLE"
grep -q 'mimo-v2.5-free' "$triage" || fail "scenario5: must name the free slug"
grep -q 'issue create' "$gh_log" || fail "scenario5: must auto-file"
grep -q 'mimo-v2.5-free' "$gh_log" || fail "scenario5: filed title must name the slug"
ok "scenario5: new free slug auto-files and keeps the tick green"

# --- 6. billing slug (no -free / no *-pass/) is not a discovery -----------
: >"$gh_log"; : >"$triage"
base_entitled
write_caps <<'JSON'
{ "free_providers_in_order": ["opencode"],
  "providers": { "opencode": { "cap": 1, "class": "free", "models": { "hy3-free": 1 } } } }
JSON
write_catalog <<'TSV'
opencode	hy3-free
opencode	minimax-m3
opencode	claude-opus-5
TSV
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario6: expected rc=0, got $env_rc ($env_out)"
! grep -q 'FREE-ROSTER-AVAILABLE' "$triage" || fail "scenario6: billing ids must not look free"
! grep -q 'issue create' "$gh_log" || fail "scenario6: must not file to wire a billing slug"
ok "scenario6: billing-only catalog does not auto-file a wire ticket"

# --- 7. stale wired free slug gone from catalog -> file bench -------------
: >"$gh_log"; : >"$triage"
base_entitled
write_caps <<'JSON'
{ "free_providers_in_order": ["opencode"],
  "providers": { "opencode": { "cap": 1, "class": "free", "models": { "hy3-free": 1 } } } }
JSON
write_catalog <<'TSV'
opencode	minimax-m3
TSV
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario7: expected rc=0, got $env_rc ($env_out)"
grep -q 'FREE-ROSTER-STALE' "$triage" || fail "scenario7: missing STALE"
grep -q 'hy3-free' "$triage" || fail "scenario7: must name the stale slug"
grep -q 'issue create' "$gh_log" || fail "scenario7: must auto-file bench"
ok "scenario7: stale wired free slug auto-files a bench ticket"

# --- 8. per-tick file cap throttles filings -------------------------------
: >"$gh_log"; : >"$triage"
base_entitled
write_caps <<'JSON'
{ "free_providers_in_order": ["opencode"],
  "providers": { "opencode": { "cap": 1, "class": "free", "models": {} } } }
JSON
write_catalog <<'TSV'
opencode	a-free
opencode	b-free
opencode	c-free
opencode	d-free
opencode	e-free
opencode	f-free
TSV
FLEET_FREE_ROSTER_CAP=2 run_canary
[[ "$env_rc" == "0" ]] || fail "scenario8: expected rc=0, got $env_rc ($env_out)"
created=$(grep -c 'issue create' "$gh_log" || true)
[[ "$created" == "2" ]] || fail "scenario8: cap=2 must file exactly 2, got $created"
grep -q 'cap reached' <<<"$env_out" || fail "scenario8: must log deferral"
ok "scenario8: per-tick file cap throttles filings to 2"

# --- 9. dedup against an open issue with the marker -----------------------
: >"$gh_log"; : >"$triage"
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n --arg b $'body\nfree-roster-canary: opencode:mimo-v2.5-free free-slug-available\n' \
  '[{number: 42, body: $b}]' >"$GH_OPEN_ISSUES"
base_entitled
write_caps <<'JSON'
{ "free_providers_in_order": ["opencode"],
  "providers": { "opencode": { "cap": 1, "class": "free", "models": { "hy3-free": 1 } } } }
JSON
write_catalog <<'TSV'
opencode	hy3-free
opencode	mimo-v2.5-free
TSV
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario9: expected rc=0, got $env_rc ($env_out)"
grep -q 'issue create' "$gh_log" && fail "scenario9: must not file a duplicate"
ok "scenario9: open issue with marker dedupes"
unset GH_OPEN_ISSUES

# --- 18. unservable new free slug is not filed ----------------------------
# fleet-ops#760: the canary must not file an audition+wire ticket when the
# servability probe (pi --print) returns a provider/transport failure.
: >"$gh_log"; : >"$triage"
base_entitled
write_caps <<'JSON'
{ "free_providers_in_order": ["opencode"],
  "providers": { "opencode": { "cap": 1, "class": "free", "models": { "hy3-free": 1 } } } }
JSON
write_catalog <<'TSV'
opencode	hy3-free
opencode	broken-v1-free
TSV
FLEET_FREE_ROSTER_PROBE_FAIL="opencode/broken-v1-free" run_canary
[[ "$env_rc" == "0" ]] || fail "scenario18: expected rc=0, got $env_rc ($env_out)"
! grep -q 'issue create' "$gh_log" || fail "scenario18: must not file for unservable slug"
! grep -q 'FREE-ROSTER-AVAILABLE' "$triage" || fail "scenario18: must not mark unservable slug available"
grep -q 'broken-v1-free.*not servable' <<<"$env_out" || fail "scenario18: must log the skipped slug (got: $env_out)"
ok "scenario18: unservable free slug is skipped"

# --- 10. pi missing -> exit 1 (watcher broken) ----------------------------
: >"$gh_log"; : >"$triage"
base_entitled
write_caps <<'JSON'
{ "free_providers_in_order": ["opencode"],
  "providers": { "opencode": { "cap": 1, "class": "free", "models": { "hy3-free": 1 } } } }
JSON
: >"$scratch/catalog.tsv"   # no fixture -> canary calls pi
set +e
env_out=$(
  FLEET_ENTITLED_SEATS_JSON="$scratch/entitled-seats.json" \
  SEAT_CAPS_JSON="$scratch/seat-caps.json" \
  FLEET_OPS_REPO="$scratch" \
  PI="$scratch/no-such-pi" \
  "$bin" 2>&1
)
env_rc=$?
set -e
[[ "$env_rc" == "1" ]] || fail "scenario10: expected rc=1 on pi missing, got $env_rc ($env_out)"
grep -q 'FREE-ROSTER-WATCHER-BROKEN' "$triage" || fail "scenario10: missing WATCHER-BROKEN"
ok "scenario10: pi missing fails loud"

# --- 11. production seat-caps: ollama deepseek-v4-flash only; free order --
: >"$gh_log"; : >"$triage"
# Catalog fixture derived from the PRODUCTION seat-caps free allowlists
# (commandcode/hetzner/opencode/orcarouter). The canary's roster watch calls
# `pi --list-models`, which does not exist on hosted CI — so this scenario
# feeds the same `FLEET_FREE_ROSTER_CATALOG_JSON` stub the dev scenarios use.
# The fixture must mirror production exactly: any free slug that is wired
# (in the allowlist) must appear, and nothing else may be wired.
prod_catalog="$scratch/catalog-prod.tsv"
jq -r '.providers | to_entries[] | select((.value|type)=="object") | select(.value.class=="free") | .key as $k | (.value.models // {}) | keys[] | "\($k)\t\(.)"' \
  "$repo_root/config/seat-caps.json" > "$prod_catalog"
set +e
prod_out=$(
  FLEET_ENTITLED_SEATS_JSON="$repo_root/config/entitled-seats.json" \
  SEAT_CAPS_JSON="$repo_root/config/seat-caps.json" \
  FLEET_FREE_ROSTER_CATALOG_JSON="$prod_catalog" \
  FLEET_OPS_REPO="$repo_root" \
  FLEET_FREE_ROSTER_FILE=0 \
  "$bin" 2>&1
)
prod_rc=$?
set -e
[[ "$prod_rc" == "0" ]] || fail "scenario11: production gates must be clean, got rc=$prod_rc ($prod_out)"
# ollama allowlist is deepseek-v4-flash only
while IFS= read -r k; do
    lk="${k,,}"
    if [[ ! "$lk" =~ deepseek.*v4.*flash ]]; then
        fail "scenario11: production ollama allowlists non-ds-v4-flash: $k"
    fi
done < <(jq -r '.providers.ollama.models // {} | keys[]' "$repo_root/config/seat-caps.json")
# every cap>0 free provider with models is in free_providers_in_order
while IFS=$'\t' read -r pid pclass pcap mcount; do
    [[ "$mcount" =~ ^[1-9][0-9]*$ ]] || continue
    jq -e --arg id "$pid" '.free_providers_in_order | index($id)' \
        "$repo_root/config/seat-caps.json" >/dev/null \
      || fail "scenario11: production free provider $pid missing from free_providers_in_order"
done < <(jq -r '
    .providers | to_entries[] | .key as $k | .value as $v
    | [$k,
       (if ($v|type)=="number" then "free" else ($v.class // "free") end),
       (if ($v|type)=="number" then $v else ($v.cap // 0) end),
       (if ($v|type)=="object" and ($v.models|type)=="object" then ($v.models|length) else 0 end)]
    | @tsv
' "$repo_root/config/seat-caps.json" | awk -F'\t' '$2=="free"')
ok "scenario11: production seat-caps passes both gates"

# --- 12. heartbeat wiring --------------------------------------------------
grep -F 'fleet-free-roster-canary' "$tier1" >/dev/null \
  || fail "tier1 must invoke fleet-free-roster-canary"
grep -F 'free_roster_canary_rc' "$tier1" >/dev/null \
  || fail "tier1 must capture free_roster_canary_rc"
grep -F -- 'exit "$free_roster_canary_rc"' "$tier1" >/dev/null \
  || fail "tier1 must exit non-zero when a roster gate fails loud"
grep -q 'bin/fleet-free-roster-canary' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/fleet-free-roster-canary"
ok "scenario12: heartbeat-tier1 wires the canary, fail-loud on gate, MANIFEST installs it"

# --- 13. production lock: mimo-v2.5-free stay-wired (fleet-ops#640) ---------
# The class prevention for "auditioned free slug silently dropped": a later
# PR that removes mimo-v2.5-free from the allowlist without a dated bench
# reason fails this lock. Billing slugs (mimo-v2.5, xiaomi/mimo-v2.5) must
# not ride in on the free row.
jq -e '.providers.opencode.models["mimo-v2.5-free"] > 0' \
    "$repo_root/config/seat-caps.json" >/dev/null \
  || fail "scenario13: production seat-caps must allowlist opencode/mimo-v2.5-free (fleet-ops#640)"
while IFS= read -r k; do
  lk="${k,,}"
  if [[ "$lk" == *mimo* ]] && [[ "$lk" != "mimo-v2.5-free" ]]; then
    fail "scenario13: production opencode allowlists a non-free mimo slug: $k"
  fi
done < <(jq -r '.providers.opencode.models // {} | keys[]' "$repo_root/config/seat-caps.json")
ok "scenario13: production seat-caps keep mimo-v2.5-free and no billing mimo slug"

# --- 14. production lock: x-preview-f-free stay-benched (fleet-ops#811) ----
# The class prevention for "auditioned free slug silently unwired after a
# failed live spawn": a later PR that removes the cap=0 row or the dated
# reason without a passing re-audition fails this lock. The cap=0 row is
# required so the canary stops re-filing "free-slug-available" on every
# tick while the slug sits in the catalog but the API rejects it.
# fleet-ops#1432: cap values can be a plain number (legacy) or an
# object {"cap": N, "intentional_cap_zero": "..."}. Extract .cap
# from the object form, or use the value as-is for the scalar form.
xpf_cap=$(jq -r '(.providers.opencode.models["x-preview-f-free"] // "missing") | if type == "object" then .cap else . end' \
    "$repo_root/config/seat-caps.json")
if [[ "$xpf_cap" == "missing" ]]; then
  fail "scenario14: production seat-caps must keep an x-preview-f-free row (cap=0 bench, fleet-ops#811)"
fi
if [[ "$xpf_cap" != "0" ]]; then
  fail "scenario14: production x-preview-f-free must be capped 0 while the API returns 401 (got $xpf_cap, fleet-ops#811)"
fi
# Dated reason field required: the cap=0 row is the bench, the dated reason
# is the audit trail. The reason must cite fleet-ops#811 and the date.
reason=$(jq -r '.providers.opencode._x_preview_f_free // ""' \
    "$repo_root/config/seat-caps.json")
if [[ -z "$reason" ]]; then
  fail "scenario14: production seat-caps must carry _x_preview_f_free dated reason (fleet-ops#811)"
fi
if ! grep -qE 'fleet-ops#811' <<<"$reason"; then
  fail "scenario14: _x_preview_f_free must cite fleet-ops#811 (got: $reason)"
fi
if ! grep -qE '^20[0-9]{2}-[0-9]{2}-[0-9]{2}' <<<"$reason"; then
  fail "scenario14: _x_preview_f_free must start with an ISO date (got: $reason)"
fi
# No billing sibling (x-preview) on the opencode allowlist: free-form is the
# only path; a billing row would be a money lane on a free-class provider.
# Exclude the free-form slug itself (`x-preview-f-free`) and any other
# free-form variant (`x-preview-*-free` / `x-preview-*/...`).
while IFS= read -r k; do
  lk="${k,,}"
  case "$lk" in
    x-preview-f-free|x-preview-*-free|x-preview-*/*) : ;;  # free-form variants allowed
    x-preview|x-preview-*|*/x-preview|*/x-preview-*)
      fail "scenario14: production opencode allowlists a non-free x-preview slug: $k" ;;
  esac
done < <(jq -r '.providers.opencode.models // {} | keys[]' "$repo_root/config/seat-caps.json")
ok "scenario14: production seat-caps keep x-preview-f-free benched at cap=0 with dated reason and no billing sibling"

# --- 15. production lock: nemotron-3.5-lightning-free stay-wired (fleet-ops#911)
# The class prevention for "auditioned free slug silently dropped": a later
# PR that removes nemotron-3.5-lightning-free from the allowlist without a
# dated bench reason fails this lock. Billing slugs (nemotron-3.5-lightning,
# nvidia/nemotron-3.5-lightning) must not ride in on the free row.
jq -e '.providers.opencode.models["nemotron-3.5-lightning-free"] > 0' \
    "$repo_root/config/seat-caps.json" >/dev/null \
  || fail "scenario15: production seat-caps must allowlist opencode/nemotron-3.5-lightning-free (fleet-ops#911)"
reason=$(jq -r '.providers.opencode._comment_nemotron // ""' \
    "$repo_root/config/seat-caps.json")
if [[ -z "$reason" ]]; then
  fail "scenario15: production seat-caps must carry _comment_nemotron dated reason (fleet-ops#911)"
fi
if ! grep -qE 'fleet-ops#911' <<<"$reason"; then
  fail "scenario15: _comment_nemotron must cite fleet-ops#911 (got: $reason)"
fi
if ! grep -qE '^20[0-9]{2}-[0-9]{2}-[0-9]{2}' <<<"$reason"; then
  fail "scenario15: _comment_nemotron must start with an ISO date (got: $reason)"
fi
# No billing sibling on the opencode allowlist: free-form is the only path.
# Exclude the free-form slug itself and any other free-form variant.
while IFS= read -r k; do
  lk="${k,,}"
  case "$lk" in
    nemotron-3.5-lightning-free|nemotron-*-free|nemotron-*/*) : ;;  # free-form variants allowed
    nemotron-3.5-lightning|nemotron-*|*/nemotron|*/nemotron-*)
      fail "scenario15: production opencode allowlists a non-free nemotron slug: $k" ;;
  esac
done < <(jq -r '.providers.opencode.models // {} | keys[]' "$repo_root/config/seat-caps.json")
ok "scenario15: production seat-caps keep nemotron-3.5-lightning-free wired with dated reason and no billing sibling"

# --- 16. production lock: nemotron-3-ultra-free stay-wired (fleet-ops#910) --
# The class prevention for "auditioned free slug silently dropped": a later
# PR that removes nemotron-3-ultra-free from the allowlist without a dated
# bench reason fails this lock. Billing slugs (nemotron-3-ultra,
# nvidia/nemotron-3-ultra) must not ride in on the free row.
jq -e '.providers.opencode.models["nemotron-3-ultra-free"] > 0' \
    "$repo_root/config/seat-caps.json" >/dev/null \
  || fail "scenario16: production seat-caps must allowlist opencode/nemotron-3-ultra-free (fleet-ops#910)"
reason=$(jq -r '.providers.opencode._comment_nemotron_ultra // ""' \
    "$repo_root/config/seat-caps.json")
if [[ -z "$reason" ]]; then
  fail "scenario16: production seat-caps must carry _comment_nemotron_ultra dated reason (fleet-ops#910)"
fi
if ! grep -qE 'fleet-ops#910' <<<"$reason"; then
  fail "scenario16: _comment_nemotron_ultra must cite fleet-ops#910 (got: $reason)"
fi
if ! grep -qE '^20[0-9]{2}-[0-9]{2}-[0-9]{2}' <<<"$reason"; then
  fail "scenario16: _comment_nemotron_ultra must start with an ISO date (got: $reason)"
fi
while IFS= read -r k; do
  lk="${k,,}"
  if [[ "$lk" == *nemotron-3-ultra* ]] && [[ "$lk" != "nemotron-3-ultra-free" ]]; then
    fail "scenario16: production opencode allowlists a non-free nemotron-3-ultra slug: $k"
  fi
done < <(jq -r '.providers.opencode.models // {} | keys[]' "$repo_root/config/seat-caps.json")
ok "scenario16: production seat-caps keep nemotron-3-ultra-free and no billing sibling"

# --- 17. production lock: muse-spark-1.2-contributor-free stay-benched (fleet-ops#1224) --
# The class prevention for "auditioned free slug silently unwired after a
# failed live spawn": a later PR that removes the cap=0 row or the dated
# reason without a passing re-audition fails this lock. The cap=0 row is
# required so the canary stops re-filing "free-slug-available" on every
# tick while the slug sits in the catalog but the API returns HTTP 500.
# fleet-ops#1432: cap values can be a plain number (legacy) or an
# object {"cap": N, "intentional_cap_zero": "..."}. Extract .cap
# from the object form, or use the value as-is for the scalar form.
msf_cap=$(jq -r '(.providers.opencode.models["muse-spark-1.2-contributor-free"] // "missing") | if type == "object" then .cap else . end' \
    "$repo_root/config/seat-caps.json")
if [[ "$msf_cap" == "missing" ]]; then
  fail "scenario17: production seat-caps must keep a muse-spark-1.2-contributor-free row (cap=0 bench, fleet-ops#1224)"
fi
if [[ "$msf_cap" != "0" ]]; then
  fail "scenario17: production muse-spark-1.2-contributor-free must be capped 0 while the API returns HTTP 500 (got $msf_cap, fleet-ops#1224)"
fi
# Dated reason field required: the cap=0 row is the bench, the dated reason
# is the audit trail. The reason must cite fleet-ops#1224 and the date.
reason=$(jq -r '.providers.opencode._muse_spark_contributor_free // ""' \
    "$repo_root/config/seat-caps.json")
if [[ -z "$reason" ]]; then
  fail "scenario17: production seat-caps must carry _muse_spark_contributor_free dated reason (fleet-ops#1224)"
fi
if ! grep -qE 'fleet-ops#1224' <<<"$reason"; then
  fail "scenario17: _muse_spark_contributor_free must cite fleet-ops#1224 (got: $reason)"
fi
if ! grep -qE '^20[0-9]{2}-[0-9]{2}-[0-9]{2}' <<<"$reason"; then
  fail "scenario17: _muse_spark_contributor_free must start with an ISO date (got: $reason)"
fi
# No billing sibling (muse-spark-1.2) on the opencode allowlist: free-form
# is the only path; a billing row would be a money lane on a free-class
# provider. Exclude the free-form slug itself and any other free-form variant.
while IFS= read -r k; do
  lk="${k,,}"
  case "$lk" in
    muse-spark-1.2-contributor-free|muse-spark-*-free|muse-spark-*/*) : ;;  # free-form variants allowed
    muse-spark-*|*/muse-spark|*/muse-spark-*)
      fail "scenario17: production opencode allowlists a non-free muse-spark slug: $k" ;;
  esac
done < <(jq -r '.providers.opencode.models // {} | keys[]' "$repo_root/config/seat-caps.json")
ok "scenario17: production seat-caps keep muse-spark-1.2-contributor-free benched at cap=0 with dated reason and no billing sibling"

# --- 19. production lock: deepseek-v4-flash-free stay-benched (fleet-ops#744) --
# The class prevention for "free slug silently unwired after a failed live
# spawn" specific to #744: the canary's freshness detector 2a
# (free-slug-available) only stops re-filing the ticket while the slug
# remains in the seat-caps allowlist. A later PR that drops the cap=0 row
# (because the API returns HTTP 400) would re-arm the canary to file a
# duplicate on every tick. The cap=0 row + dated reason is the
# production-lock answer. fleet-ops#1432: cap values can be a plain
# number (legacy) or an object {"cap": N, "intentional_cap_zero": "..."}.
dvf_cap=$(jq -r '(.providers.opencode.models["deepseek-v4-flash-free"] // "missing") | if type == "object" then .cap else . end' \
    "$repo_root/config/seat-caps.json")
if [[ "$dvf_cap" == "missing" ]]; then
  fail "scenario19: production seat-caps must keep a deepseek-v4-flash-free row (cap=0 bench, fleet-ops#744)"
fi
if [[ "$dvf_cap" != "0" ]]; then
  fail "scenario19: production deepseek-v4-flash-free must be capped 0 while the API returns HTTP 400 (got $dvf_cap, fleet-ops#744)"
fi
# Dated reason field required: the cap=0 row is the bench, the dated reason
# is the audit trail. The reason must cite fleet-ops#744 and a date.
reason=$(jq -r '.providers.opencode._deepseek_v4_flash_free // ""' \
    "$repo_root/config/seat-caps.json")
if [[ -z "$reason" ]]; then
  fail "scenario19: production seat-caps must carry _deepseek_v4_flash_free dated reason (fleet-ops#744)"
fi
if ! grep -qE 'fleet-ops#744' <<<"$reason"; then
  fail "scenario19: _deepseek_v4_flash_free must cite fleet-ops#744 (got: $reason)"
fi
if ! grep -qE '^20[0-9]{2}-[0-9]{2}-[0-9]{2}' <<<"$reason"; then
  fail "scenario19: _deepseek_v4_flash_free must start with an ISO date (got: $reason)"
fi
# No billing sibling (deepseek-v4-flash, without the -free suffix) on the
# opencode allowlist: free-form is the only path; a billing row would be a
# money lane on a free-class provider. Exclude the free-form slug itself
# and any other free-form variant.
while IFS= read -r k; do
  lk="${k,,}"
  case "$lk" in
    deepseek-v4-flash-free|deepseek-*-free|deepseek-*/*) : ;;  # free-form variants allowed
    deepseek-v4-flash|deepseek-*|*/deepseek|*/deepseek-*)
      fail "scenario19: production opencode allowlists a non-free deepseek slug: $k" ;;
  esac
done < <(jq -r '.providers.opencode.models // {} | keys[]' "$repo_root/config/seat-caps.json")
ok "scenario19: production seat-caps keep deepseek-v4-flash-free benched at cap=0 with dated reason and no billing sibling"

# --- 19b. production lock: commandcode minimax/minimax-m3-free retired (fleet-ops#2700) --
# The provider retired the free MiniMax M3 line (403 FORBIDDEN "The free
# MiniMax M3 and M2.7 models have been retired"), so the seat is a
# credentials_bad corpse (seat_dead=true, no comeback clock). The cap=0 +
# intentional_cap_zero=corpse row is the production lock: it keeps the
# free-roster-canary from re-filing "free-slug-available" on every tick,
# and the seat-lib cap-0 classifier treats corpse as INTENTIONAL (never
# re-audition, fleet-ops#2435) instead of stale. A later PR that removes
# the row or re-raises the cap without a passing re-audition fails here.
m3f_cap=$(jq -r '(.providers.commandcode.models["minimax/minimax-m3-free"] // "missing") | if type == "object" then .cap else . end' \
    "$repo_root/config/seat-caps.json")
if [[ "$m3f_cap" == "missing" ]]; then
  fail "scenario19b: production seat-caps must keep a commandcode minimax/minimax-m3-free row (retired corpse, fleet-ops#2700)"
fi
if [[ "$m3f_cap" != "0" ]]; then
  fail "scenario19b: production commandcode minimax/minimax-m3-free must be capped 0 (provider retired the model, got $m3f_cap, fleet-ops#2700)"
fi
m3f_intent=$(jq -r '(.providers.commandcode.models["minimax/minimax-m3-free"] // "missing") | if type == "object" then (.intentional_cap_zero // "") else "" end' \
    "$repo_root/config/seat-caps.json")
if [[ "$m3f_intent" != "corpse" ]]; then
  fail "scenario19b: commandcode minimax/minimax-m3-free must be intentional_cap_zero=corpse (got '$m3f_intent')"
fi
# Dated reason required: the retire reason must cite fleet-ops#2700 and a date.
reason=$(jq -r '.providers.commandcode._comment_minimax_m3_free // ""' \
    "$repo_root/config/seat-caps.json")
if [[ -z "$reason" ]]; then
  fail "scenario19b: production seat-caps must carry _comment_minimax_m3_free dated reason (fleet-ops#2700)"
fi
if ! grep -qE 'fleet-ops#2700' <<<"$reason"; then
  fail "scenario19b: _comment_minimax_m3_free must cite fleet-ops#2700 (got: $reason)"
fi
if ! grep -qE '^20[0-9]{2}-[0-9]{2}-[0-9]{2}' <<<"$reason"; then
  fail "scenario19b: _comment_minimax_m3_free must start with an ISO date (got: $reason)"
fi
# No billing sibling (minimax/minimax-m3, without the -free suffix) on the
# commandcode allowlist: the free-form slug is the only path; a billing row
# would be a money lane on a free-class provider.
while IFS= read -r k; do
  case "$k" in
    minimax/minimax-m3-free) : ;;  # the retired free-form slug itself
    minimax/*) fail "scenario19b: production commandcode allowlists a non-free minimax slug: $k" ;;
  esac
done < <(jq -r '.providers.commandcode.models // {} | keys[]' "$repo_root/config/seat-caps.json")
ok "scenario19b: production seat-caps keep commandcode minimax/minimax-m3-free retired at cap=0 corpse with dated reason and no billing sibling"

# --- 19c. production lock: opencode hy3-free retired (fleet-ops#2667/#2742) --
# The provider dropped the slug (401 ModelError "Model hy3-free is not
# supported") while a control on the same key still answers, so the seat
# is a credentials_bad corpse (seat_dead=true, no comeback clock). The
# cap=0 + intentional_cap_zero=corpse row is the production lock: it
# keeps the free-roster-canary from re-filing "free-slug-available" on
# every tick, and the seat-lib cap-0 classifier treats corpse as
# INTENTIONAL (never re-audition, fleet-ops#2435) instead of stale. A
# later PR that removes the row or re-raises the cap without a passing
# re-audition fails here. fleet-ops#2742 is a stale duplicate of #2667
# that stayed open because no lock named hy3-free (19b only pins the
# commandcode sibling).
hy3_cap=$(jq -r '(.providers.opencode.models["hy3-free"] // "missing") | if type == "object" then .cap else . end' \
    "$repo_root/config/seat-caps.json")
if [[ "$hy3_cap" == "missing" ]]; then
  fail "scenario19c: production seat-caps must keep an opencode hy3-free row (retired corpse, fleet-ops#2667/#2742)"
fi
if [[ "$hy3_cap" != "0" ]]; then
  fail "scenario19c: production opencode hy3-free must be capped 0 (provider dropped the slug, got $hy3_cap, fleet-ops#2667/#2742)"
fi
hy3_intent=$(jq -r '(.providers.opencode.models["hy3-free"] // "missing") | if type == "object" then (.intentional_cap_zero // "") else "" end' \
    "$repo_root/config/seat-caps.json")
if [[ "$hy3_intent" != "corpse" ]]; then
  fail "scenario19c: opencode hy3-free must be intentional_cap_zero=corpse (got '$hy3_intent')"
fi
# Dated reason required: the retire reason must cite fleet-ops#2667 and a date.
reason=$(jq -r '.providers.opencode._hy3free // ""' \
    "$repo_root/config/seat-caps.json")
if [[ -z "$reason" ]]; then
  fail "scenario19c: production seat-caps must carry _hy3free dated reason (fleet-ops#2667)"
fi
if ! grep -qE 'fleet-ops#2667' <<<"$reason"; then
  fail "scenario19c: _hy3free must cite fleet-ops#2667 (got: $reason)"
fi
if ! grep -qE '^20[0-9]{2}-[0-9]{2}-[0-9]{2}' <<<"$reason"; then
  fail "scenario19c: _hy3free must start with an ISO date (got: $reason)"
fi
# No billing sibling (hy3, without the -free suffix) on the opencode
# allowlist: free-form is the only path; a billing row would be a money
# lane on a free-class provider. Exclude the retired free-form slug itself.
while IFS= read -r k; do
  case "$k" in
    hy3-free) : ;;  # the retired free-form slug itself
    hy3) fail "scenario19c: production opencode allowlists a non-free hy3 slug: $k" ;;
  esac
done < <(jq -r '.providers.opencode.models // {} | keys[]' "$repo_root/config/seat-caps.json")
ok "scenario19c: production seat-caps keep opencode hy3-free retired at cap=0 corpse with dated reason and no billing sibling"

# ===========================================================================
# observe-to-close (fleet-ops#995): stale auto-filed tickets close when the
# signal that filed them clears. The close path is OPT-IN: env=1 AND a fresh
# sentinel. A worker run from a worktree (env unset, no sentinel) can never
# close a real issue. Gate findings are never auto-closed.
# ===========================================================================

# --- 20. observe-to-close: free-slug-available clears when wired -----------
# The canary auto-filed this when the slug was unwired; the slug is now
# allowlisted (cap>0). The stale issue must close (fleet-ops#995).
: >"$gh_log"; : >"$triage"; : >"$scratch/closed.log"
export GH_OPEN_ISSUES="$scratch/open.json"
export GH_CLOSED_ISSUES="$scratch/closed.log"
jq -n --arg b $'body\nfree-roster-canary: opencode:mimo-v2.5-free free-slug-available\n' \
  '[{number: 42, body: $b}]' >"$GH_OPEN_ISSUES"
base_entitled
write_caps <<'JSON'
{ "free_providers_in_order": ["opencode"],
  "providers": { "opencode": { "cap": 1, "class": "free", "models": { "hy3-free": 1, "mimo-v2.5-free": 1 } } } }
JSON
write_catalog <<'TSV'
opencode	hy3-free
opencode	mimo-v2.5-free
TSV
touch_sentinel
FLEET_FREE_ROSTER_OBSERVE_TO_CLOSE=1 run_canary
[[ "$env_rc" == "0" ]] || fail "scenario20: clean tick must stay rc=0, got $env_rc ($env_out)"
grep -q 'observe-to-close: CLOSED issue #42' <<<"$env_out" \
  || fail "scenario20: must close #42 (the wired-free case), env_out=$env_out"
grep -q 'issue close 42' "$gh_log" \
  || fail "scenario20: gh must receive close 42, gh_log=$gh_log"
grep -q '^42$' "$scratch/closed.log" \
  || fail "scenario20: closed issue ledger must record 42 (got $(cat "$scratch/closed.log"))"
ok "scenario20: free-slug-available clears when wired, closes the stale issue"

# --- 21. observe-to-close: free-slug-available clears at cap=0 bench ------
# A wired free slug that fails the audition is benched at cap=0 with a dated
# reason (the fleet-ops#811 / #640 / #910 / #911 lock). The canary's
# auto-filed ticket must clear when the bench row lands so it does not
# re-file on every tick.
: >"$gh_log"; : >"$triage"; : >"$scratch/closed.log"
export GH_OPEN_ISSUES="$scratch/open.json"
export GH_CLOSED_ISSUES="$scratch/closed.log"
jq -n --arg b $'body\nfree-roster-canary: opencode:x-preview-f-free free-slug-available\n' \
  '[{number: 51, body: $b}]' >"$GH_OPEN_ISSUES"
base_entitled
write_caps <<'JSON'
{ "free_providers_in_order": ["opencode"],
  "providers": { "opencode": { "cap": 2, "class": "free", "models": { "hy3-free": 1, "x-preview-f-free": 0 } } } }
JSON
write_catalog <<'TSV'
opencode	hy3-free
opencode	x-preview-f-free
TSV
touch_sentinel
FLEET_FREE_ROSTER_OBSERVE_TO_CLOSE=1 run_canary
[[ "$env_rc" == "0" ]] || fail "scenario21: clean tick must stay rc=0, got $env_rc ($env_out)"
grep -q 'observe-to-close: CLOSED issue #51' <<<"$env_out" \
  || fail "scenario21: must close #51 (the cap=0 bench case), env_out=$env_out"
grep -q '^51$' "$scratch/closed.log" \
  || fail "scenario21: closed issue ledger must record 51 (got $(cat "$scratch/closed.log"))"
ok "scenario21: free-slug-available clears at cap=0 bench (production lock answer)"

# --- 22. observe-to-close: free-slug-available clears when slug leaves catalog
# A free slug that appeared briefly in the catalog and disappeared: the
# stale audition+wire ticket must close so it does not pile up.
: >"$gh_log"; : >"$triage"; : >"$scratch/closed.log"
export GH_OPEN_ISSUES="$scratch/open.json"
export GH_CLOSED_ISSUES="$scratch/closed.log"
jq -n --arg b $'body\nfree-roster-canary: opencode:vanishing-free free-slug-available\n' \
  '[{number: 60, body: $b}]' >"$GH_OPEN_ISSUES"
base_entitled
write_caps <<'JSON'
{ "free_providers_in_order": ["opencode"],
  "providers": { "opencode": { "cap": 1, "class": "free", "models": { "hy3-free": 1 } } } }
JSON
write_catalog <<'TSV'
opencode	hy3-free
TSV
touch_sentinel
FLEET_FREE_ROSTER_OBSERVE_TO_CLOSE=1 run_canary
[[ "$env_rc" == "0" ]] || fail "scenario22: clean tick must stay rc=0, got $env_rc ($env_out)"
grep -q 'observe-to-close: CLOSED issue #60' <<<"$env_out" \
  || fail "scenario22: must close #60 (the gone-from-catalog case), env_out=$env_out"
grep -q '^60$' "$scratch/closed.log" \
  || fail "scenario22: closed issue ledger must record 60 (got $(cat "$scratch/closed.log"))"
ok "scenario22: free-slug-available clears when the slug leaves the catalog"

# --- 23. observe-to-close: stale-slug clears when the slug reappears ------
# A wired free slug that vanished from the catalog and now reappeared: the
# stale bench ticket must close because the original signal (slug gone) has
# cleared.
: >"$gh_log"; : >"$triage"; : >"$scratch/closed.log"
export GH_OPEN_ISSUES="$scratch/open.json"
export GH_CLOSED_ISSUES="$scratch/closed.log"
jq -n --arg b $'body\nfree-roster-canary: opencode:back-free stale-slug\n' \
  '[{number: 70, body: $b}]' >"$GH_OPEN_ISSUES"
base_entitled
write_caps <<'JSON'
{ "free_providers_in_order": ["opencode"],
  "providers": { "opencode": { "cap": 1, "class": "free", "models": { "hy3-free": 1, "back-free": 1 } } } }
JSON
write_catalog <<'TSV'
opencode	hy3-free
opencode	back-free
TSV
touch_sentinel
FLEET_FREE_ROSTER_OBSERVE_TO_CLOSE=1 run_canary
[[ "$env_rc" == "0" ]] || fail "scenario23: clean tick must stay rc=0, got $env_rc ($env_out)"
grep -q 'observe-to-close: CLOSED issue #70' <<<"$env_out" \
  || fail "scenario23: must close #70 (the reappeared case), env_out=$env_out"
grep -q '^70$' "$scratch/closed.log" \
  || fail "scenario23: closed issue ledger must record 70 (got $(cat "$scratch/closed.log"))"
ok "scenario23: stale-slug clears when the slug reappears in the catalog"

# --- 24. observe-to-close: stale-slug clears when removed from allowlist --
# A wired free slug gone from the catalog AND now removed from seat-caps
# (cleanup): the stale bench ticket must close.
: >"$gh_log"; : >"$triage"; : >"$scratch/closed.log"
export GH_OPEN_ISSUES="$scratch/open.json"
export GH_CLOSED_ISSUES="$scratch/closed.log"
jq -n --arg b $'body\nfree-roster-canary: opencode:dropped-free stale-slug\n' \
  '[{number: 80, body: $b}]' >"$GH_OPEN_ISSUES"
base_entitled
write_caps <<'JSON'
{ "free_providers_in_order": ["opencode"],
  "providers": { "opencode": { "cap": 1, "class": "free", "models": { "hy3-free": 1 } } } }
JSON
write_catalog <<'TSV'
opencode	hy3-free
TSV
touch_sentinel
FLEET_FREE_ROSTER_OBSERVE_TO_CLOSE=1 run_canary
[[ "$env_rc" == "0" ]] || fail "scenario24: clean tick must stay rc=0, got $env_rc ($env_out)"
grep -q 'observe-to-close: CLOSED issue #80' <<<"$env_out" \
  || fail "scenario24: must close #80 (the removed-from-allowlist case), env_out=$env_out"
grep -q '^80$' "$scratch/closed.log" \
  || fail "scenario24: closed issue ledger must record 80 (got $(cat "$scratch/closed.log"))"
ok "scenario24: stale-slug clears when the slug is removed from the allowlist"

# --- 25. observe-to-close: signal STILL active -> keep the issue open ------
# A free-slug-available issue is still in catalog AND not wired. The canary
# must NOT close it. The discover path re-fires the loud (no new file because
# dedup against the open issue).
: >"$gh_log"; : >"$triage"; : >"$scratch/closed.log"
export GH_OPEN_ISSUES="$scratch/open.json"
export GH_CLOSED_ISSUES="$scratch/closed.log"
jq -n --arg b $'body\nfree-roster-canary: opencode:still-missing-free free-slug-available\n' \
  '[{number: 90, body: $b}]' >"$GH_OPEN_ISSUES"
base_entitled
write_caps <<'JSON'
{ "free_providers_in_order": ["opencode"],
  "providers": { "opencode": { "cap": 1, "class": "free", "models": { "hy3-free": 1 } } } }
JSON
write_catalog <<'TSV'
opencode	hy3-free
opencode	still-missing-free
TSV
touch_sentinel
FLEET_FREE_ROSTER_OBSERVE_TO_CLOSE=1 run_canary
[[ "$env_rc" == "0" ]] || fail "scenario25: clean tick must stay rc=0, got $env_rc ($env_out)"
! grep -q 'observe-to-close: CLOSED' <<<"$env_out" \
  || fail "scenario25: must NOT close #90 (signal still active), env_out=$env_out"
! grep -q 'issue close' "$gh_log" \
  || fail "scenario25: gh must NOT receive any close, gh_log=$gh_log"
[[ ! -s "$scratch/closed.log" ]] \
  || fail "scenario25: closed ledger must stay empty (got $(cat "$scratch/closed.log"))"
grep -q 'observe-to-close: keep #90' <<<"$env_out" \
  || fail "scenario25: must log keep #90, env_out=$env_out"
ok "scenario25: signal still active keeps the issue open (no close)"

# --- 26. observe-to-close: default-off (env unset) -> no close -------------
# The safety core (fleet-ops#995): a worker run that does NOT set the env
# can never close a real issue, even when a sentinel exists and the signal
# has cleared. This is the guard that prevents the 2026-08-27 breach.
: >"$gh_log"; : >"$triage"; : >"$scratch/closed.log"
export GH_OPEN_ISSUES="$scratch/open.json"
export GH_CLOSED_ISSUES="$scratch/closed.log"
jq -n --arg b $'body\nfree-roster-canary: opencode:mimo-v2.5-free free-slug-available\n' \
  '[{number: 42, body: $b}]' >"$GH_OPEN_ISSUES"
base_entitled
write_caps <<'JSON'
{ "free_providers_in_order": ["opencode"],
  "providers": { "opencode": { "cap": 1, "class": "free", "models": { "hy3-free": 1, "mimo-v2.5-free": 1 } } } }
JSON
write_catalog <<'TSV'
opencode	hy3-free
opencode	mimo-v2.5-free
TSV
touch_sentinel
FLEET_FREE_ROSTER_OBSERVE_TO_CLOSE=0 run_canary
[[ "$env_rc" == "0" ]] || fail "scenario26: clean tick must stay rc=0, got $env_rc ($env_out)"
! grep -q 'observe-to-close: CLOSED' <<<"$env_out" \
  || fail "scenario26: must NOT close when env=0, env_out=$env_out"
! grep -q 'issue close' "$gh_log" \
  || fail "scenario26: gh must NOT receive any close (env=0), gh_log=$gh_log"
grep -q 'observe-to-close: skipped' <<<"$env_out" \
  || fail "scenario26: must log the skip, env_out=$env_out"
ok "scenario26: default-off (env=0) never closes even with a sentinel"

# --- 27. observe-to-close: env=1 but sentinel missing -> no close ----------
# env=1 alone is not sufficient: the sentinel must exist. A worker that
# exports the env manually but cannot create the trusted sentinel file is
# still blocked.
: >"$gh_log"; : >"$triage"; : >"$scratch/closed.log"
export GH_OPEN_ISSUES="$scratch/open.json"
export GH_CLOSED_ISSUES="$scratch/closed.log"
jq -n --arg b $'body\nfree-roster-canary: opencode:mimo-v2.5-free free-slug-available\n' \
  '[{number: 42, body: $b}]' >"$GH_OPEN_ISSUES"
base_entitled
write_caps <<'JSON'
{ "free_providers_in_order": ["opencode"],
  "providers": { "opencode": { "cap": 1, "class": "free", "models": { "hy3-free": 1, "mimo-v2.5-free": 1 } } } }
JSON
write_catalog <<'TSV'
opencode	hy3-free
opencode	mimo-v2.5-free
TSV
export FLEET_FREE_ROSTER_OBSERVE_SENTINEL="$scratch/no-such-sentinel"
FLEET_FREE_ROSTER_OBSERVE_TO_CLOSE=1 run_canary
[[ "$env_rc" == "0" ]] || fail "scenario27: clean tick must stay rc=0, got $env_rc ($env_out)"
! grep -q 'observe-to-close: CLOSED' <<<"$env_out" \
  || fail "scenario27: must NOT close when sentinel missing, env_out=$env_out"
! grep -q 'issue close' "$gh_log" \
  || fail "scenario27: gh must NOT receive any close (sentinel missing), gh_log=$gh_log"
grep -q 'sentinel missing' <<<"$env_out" \
  || fail "scenario27: must log sentinel missing, env_out=$env_out"
ok "scenario27: env=1 but sentinel missing never closes"

# --- 28. observe-to-close: env=1 but sentinel stale -> no close ------------
# A sentinel older than 300s is stale; the close path skips. This stops a
# worker from reusing a sentinel the heartbeat touched on a prior tick.
: >"$gh_log"; : >"$triage"; : >"$scratch/closed.log"
export GH_OPEN_ISSUES="$scratch/open.json"
export GH_CLOSED_ISSUES="$scratch/closed.log"
jq -n --arg b $'body\nfree-roster-canary: opencode:mimo-v2.5-free free-slug-available\n' \
  '[{number: 42, body: $b}]' >"$GH_OPEN_ISSUES"
base_entitled
write_caps <<'JSON'
{ "free_providers_in_order": ["opencode"],
  "providers": { "opencode": { "cap": 1, "class": "free", "models": { "hy3-free": 1, "mimo-v2.5-free": 1 } } } }
JSON
write_catalog <<'TSV'
opencode	hy3-free
opencode	mimo-v2.5-free
TSV
stale_sentinel="$scratch/stale-sentinel"
: >"$stale_sentinel"
touch -d '600 seconds ago' "$stale_sentinel" 2>/dev/null || \
    touch -t 197001010000 "$stale_sentinel"
export FLEET_FREE_ROSTER_OBSERVE_SENTINEL="$stale_sentinel"
FLEET_FREE_ROSTER_OBSERVE_TO_CLOSE=1 run_canary
[[ "$env_rc" == "0" ]] || fail "scenario28: clean tick must stay rc=0, got $env_rc ($env_out)"
! grep -q 'observe-to-close: CLOSED' <<<"$env_out" \
  || fail "scenario28: must NOT close when sentinel stale, env_out=$env_out"
! grep -q 'issue close' "$gh_log" \
  || fail "scenario28: gh must NOT receive any close (sentinel stale), gh_log=$gh_log"
grep -q 'sentinel stale' <<<"$env_out" \
  || fail "scenario28: must log sentinel stale, env_out=$env_out"
ok "scenario28: env=1 but sentinel stale never closes"

# --- 29. observe-to-close: gate findings are NEVER auto-closed -------------
# A carve-out-violation ticket (a class gate finding) must NOT be closed by
# observe-to-close even when env=1 and a fresh sentinel exists. The merged
# PR that fixes the gate is the only close path.
: >"$gh_log"; : >"$triage"; : >"$scratch/closed.log"
export GH_OPEN_ISSUES="$scratch/open.json"
export GH_CLOSED_ISSUES="$scratch/closed.log"
jq -n --arg b $'body\nfree-roster-canary: ollama carve-out-violation\n' \
  '[{number: 100, body: $b}]' >"$GH_OPEN_ISSUES"
base_entitled
write_caps <<'JSON'
{ "free_providers_in_order": [],
  "providers": { "ollama": { "cap": 4, "class": "prepaid-quota", "models": { "deepseek-v4-flash:0731": 4 } } } }
JSON
write_catalog <<'TSV'
ollama	deepseek-v4-flash:0731
TSV
touch_sentinel
FLEET_FREE_ROSTER_OBSERVE_TO_CLOSE=1 run_canary
[[ "$env_rc" == "0" ]] || fail "scenario29: clean tick must stay rc=0, got $env_rc ($env_out)"
! grep -q 'observe-to-close: CLOSED' <<<"$env_out" \
  || fail "scenario29: must NOT close a gate finding, env_out=$env_out"
! grep -q 'issue close' "$gh_log" \
  || fail "scenario29: gh must NOT receive any close (gate finding), gh_log=$gh_log"
grep -q 'observe-to-close: keep #100' <<<"$env_out" \
  || fail "scenario29: must log keep #100, env_out=$env_out"
ok "scenario29: gate findings (carve-out-violation) are never auto-closed"

# --- 30. heartbeat wiring: opt-in env + sentinel refresh (fleet-ops#995) ---
# The production heartbeat is the only trusted caller. It must set the env
# as a per-call argument AND touch the sentinel on the same line. A worker
# run from a worktree cannot inherit the env (it is not exported globally).
grep -q 'FLEET_FREE_ROSTER_OBSERVE_TO_CLOSE=1' "$tier1" \
  || fail "scenario30: tier1 must set FLEET_FREE_ROSTER_OBSERVE_TO_CLOSE=1 per-call"
grep -q 'FLEET_FREE_ROSTER_OBSERVE_SENTINEL' "$tier1" \
  || fail "scenario30: tier1 must pass FLEET_FREE_ROSTER_OBSERVE_SENTINEL per-call"
grep -q 'free_roster_sentinel' "$tier1" \
  || fail "scenario30: tier1 must refresh the sentinel each tick"
grep -q 'touch "$free_roster_sentinel"' "$tier1" \
  || fail "scenario30: tier1 must touch the sentinel file"
ok "scenario30: heartbeat-tier1 wires opt-in env + sentinel refresh for observe-to-close"

unset GH_OPEN_ISSUES GH_CLOSED_ISSUES FLEET_FREE_ROSTER_OBSERVE_TO_CLOSE FLEET_FREE_ROSTER_OBSERVE_SENTINEL

ok "fleet-free-roster-canary: ollama carve-out, penny-for-speed, freshness, stale, cap, dedup, prod clean, deepseek-v4-flash-free bench lock, observe-to-close"
