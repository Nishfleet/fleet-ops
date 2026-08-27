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
esac
exit 0
FAKE
chmod +x "$gh_fake"
export GH="$gh_fake"
export GH_LOG="$gh_log"
export PATH="$scratch:$PATH"

write_caps()   { cat >"$scratch/seat-caps.json"; }
write_entitled() { cat >"$scratch/entitled-seats.json"; }
write_catalog() { cat >"$scratch/catalog.tsv"; }

run_canary() {
  set +e
  env_out=$(
    FLEET_ENTITLED_SEATS_JSON="$scratch/entitled-seats.json" \
    SEAT_CAPS_JSON="$scratch/seat-caps.json" \
    FLEET_FREE_ROSTER_CATALOG_JSON="$scratch/catalog.tsv" \
    FLEET_OPS_REPO="$scratch" \
    "$bin" 2>&1
  )
  env_rc=$?
  set -e
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
xpf_cap=$(jq -r '.providers.opencode.models["x-preview-f-free"] // "missing"' \
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

ok "fleet-free-roster-canary: ollama carve-out, penny-for-speed, freshness, stale, cap, dedup, prod clean"
