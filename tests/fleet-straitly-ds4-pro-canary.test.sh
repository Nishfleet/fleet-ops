#!/usr/bin/env bash
# tests/fleet-straitly-ds4-pro-canary.test.sh
#
# Proves the straitly ds4-pro worker-rotation canary (fleet-ops#546) offline:
#   1. Clean: only deepseek/deepseek-v4-pro on straitly, cap<=2, metered,
#      models.json + catalog proven, no active worker -> exit 0, OK.
#   2. Missing straitly provider -> exit 1, LOUD.
#   3. Class not metered -> exit 1.
#   4. Provider cap > 2 -> exit 1.
#   5. Model cap > 2 -> exit 1.
#   6. Empty model allowlist -> exit 1.
#   7. Unapproved model allowlisted (Sol/qwen) -> exit 1.
#   8. deepseek/deepseek-v4-pro double-wired on another provider -> exit 1.
#   9. models.json missing the slug -> exit 1.
#  10. Catalog fixture missing the slug -> exit 1.
#  11. Active straitly worker is present but the canary files NOTHING
#      (fleet-ops#1338 regression: meter-check ticket must not be auto-filed).
#  12. Production seat-caps is clean.
#  13. Heartbeat-tier1 wires the canary and propagates a fail-loud.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-straitly-ds4-pro-canary"
tier1="$repo_root/bin/fleet-heartbeat-tier1"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$tier1" ]] || fail "missing: $tier1"

scratch="$(mktemp -d -t straitly-ds4pro-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
triage="$scratch/triage.md"
: >"$triage"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export FLEET_STRAITLY_DS4PRO_REPO="Nishfleet/fleet-ops"
export FLEET_STRAITLY_DS4PRO_FILE=1

mkdir -p "$scratch/active-seats"
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
write_models() { cat >"$scratch/models.json"; }
write_catalog() { cat >"$scratch/catalog.tsv"; }

base_caps() {
  write_caps <<'JSON'
{
  "providers": {
    "straitly": {
      "cap": 2,
      "class": "metered",
      "models": {
        "deepseek/deepseek-v4-pro": 2
      }
    }
  }
}
JSON
}

base_models() {
  write_models <<'JSON'
{
  "providers": {
    "straitly": {
      "models": [
        { "id": "deepseek/deepseek-v4-pro" }
      ]
    }
  }
}
JSON
}

base_catalog() {
  write_catalog <<'TSV'
provider            model                                               context  max-out  thinking  images
straitly            deepseek/deepseek-v4-pro                            350K     32.8K    yes       yes
straitly            gpt-5.6-sol                                         1.1M     32K      yes       yes
straitly            qwen/qwen3.8-max                                    350K     32.8K    yes       yes
TSV
}

run_canary() {
  set +e
  env_out=$(
    SEAT_CAPS_JSON="$scratch/seat-caps.json" \
    FLEET_STRAITLY_DS4PRO_MODELS_JSON="$scratch/models.json" \
    FLEET_STRAITLY_DS4PRO_CATALOG="$scratch/catalog.tsv" \
    FLEET_OPS_REPO="$scratch" \
    "$bin" 2>&1
  )
  env_rc=$?
  set -e
}

# --- 1. clean ----------------------------------------------------------------
: >"$gh_log"; : >"$triage"
base_caps; base_models; base_catalog
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario1: clean must exit 0, got rc=$env_rc ($env_out)"
grep -q 'STRAITLY-DS4PRO-OK' <<<"$env_out" || fail "scenario1: must log OK ($env_out)"
if grep -q 'issue create' "$gh_log"; then
  fail "scenario1: must not file (gh=$(cat "$gh_log"))"
fi
ok "scenario1: clean state is green, no file"

# --- 2. missing straitly provider --------------------------------------------
: >"$gh_log"; : >"$triage"
write_caps <<'JSON'
{ "providers": { "ollama": { "cap": 4, "class": "prepaid-quota", "models": { "deepseek-v4-flash:0731": 4 } } } }
JSON
base_models; base_catalog
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario2: missing straitly must exit 1, got rc=$env_rc ($env_out)"
grep -q 'STRAITLY-DS4PRO-VIOLATION' <<<"$env_out" || fail "scenario2: must LOUD ($env_out)"
grep -q 'issue create' "$gh_log" || fail "scenario2: must auto-file"
ok "scenario2: missing straitly provider fails loud and files"

# --- 3. class not metered ----------------------------------------------------
: >"$gh_log"; : >"$triage"
write_caps <<'JSON'
{
  "providers": {
    "straitly": { "cap": 2, "class": "free", "models": { "deepseek/deepseek-v4-pro": 2 } }
  }
}
JSON
base_models; base_catalog
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario3: non-metered class must exit 1, got rc=$env_rc ($env_out)"
grep -q 'class' <<<"$env_out" || fail "scenario3: must name class ($env_out)"
grep -q 'issue create' "$gh_log" || fail "scenario3: must auto-file"
ok "scenario3: non-metered straitly class fails loud"

# --- 4. provider cap > 2 -----------------------------------------------------
: >"$gh_log"; : >"$triage"
write_caps <<'JSON'
{
  "providers": {
    "straitly": { "cap": 3, "class": "metered", "models": { "deepseek/deepseek-v4-pro": 2 } }
  }
}
JSON
base_models; base_catalog
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario4: provider cap >2 must exit 1, got rc=$env_rc ($env_out)"
grep -q 'provider cap' <<<"$env_out" || fail "scenario4: must name provider cap ($env_out)"
grep -q 'issue create' "$gh_log" || fail "scenario4: must auto-file"
ok "scenario4: provider cap > 2 fails loud"

# --- 5. model cap > 2 --------------------------------------------------------
: >"$gh_log"; : >"$triage"
write_caps <<'JSON'
{
  "providers": {
    "straitly": { "cap": 2, "class": "metered", "models": { "deepseek/deepseek-v4-pro": 3 } }
  }
}
JSON
base_models; base_catalog
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario5: model cap >2 must exit 1, got rc=$env_rc ($env_out)"
grep -q 'model cap' <<<"$env_out" || fail "scenario5: must name model cap ($env_out)"
grep -q 'issue create' "$gh_log" || fail "scenario5: must auto-file"
ok "scenario5: model cap > 2 fails loud"

# --- 6. empty model allowlist ------------------------------------------------
: >"$gh_log"; : >"$triage"
write_caps <<'JSON'
{
  "providers": {
    "straitly": { "cap": 2, "class": "metered" }
  }
}
JSON
base_models; base_catalog
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario6: empty models must exit 1, got rc=$env_rc ($env_out)"
grep -q 'empty model allowlist' <<<"$env_out" || fail "scenario6: must name empty models ($env_out)"
grep -q 'issue create' "$gh_log" || fail "scenario6: must auto-file"
ok "scenario6: empty straitly model allowlist fails loud"

# --- 7. unapproved model allowlisted -----------------------------------------
: >"$gh_log"; : >"$triage"
write_caps <<'JSON'
{
  "providers": {
    "straitly": { "cap": 2, "class": "metered", "models": { "deepseek/deepseek-v4-pro": 2, "gpt-5.6-sol": 1, "qwen/qwen3.8-max": 1 } }
  }
}
JSON
base_models; base_catalog
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario7: unapproved models must exit 1, got rc=$env_rc ($env_out)"
grep -q 'unapproved' <<<"$env_out" || fail "scenario7: must name unapproved ($env_out)"
grep -q 'issue create' "$gh_log" || fail "scenario7: must auto-file"
ok "scenario7: Sol and qwen allowlisted on straitly fail loud"

# --- 8. double-wire on another provider --------------------------------------
: >"$gh_log"; : >"$triage"
write_caps <<'JSON'
{
  "providers": {
    "straitly": { "cap": 2, "class": "metered", "models": { "deepseek/deepseek-v4-pro": 2 } },
    "openrouter": { "cap": 2, "class": "metered", "models": { "deepseek/deepseek-v4-pro": 2 } }
  }
}
JSON
base_models; base_catalog
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario8: double-wire must exit 1, got rc=$env_rc ($env_out)"
grep -q 'double-wire' <<<"$env_out" || fail "scenario8: must name double-wire ($env_out)"
grep -q 'issue create' "$gh_log" || fail "scenario8: must auto-file"
ok "scenario8: deepseek/deepseek-v4-pro on a second provider fails loud"

# --- 9. models.json missing the slug -----------------------------------------
: >"$gh_log"; : >"$triage"
base_caps; base_catalog
write_models <<'JSON'
{ "providers": { "straitly": { "models": [ { "id": "gpt-5.6-sol" } ] } } }
JSON
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario9: missing models.json entry must exit 1, got rc=$env_rc ($env_out)"
grep -q 'models.json' <<<"$env_out" || fail "scenario9: must name models.json ($env_out)"
grep -q 'issue create' "$gh_log" || fail "scenario9: must auto-file"
ok "scenario9: allowlisted slug missing from models.json fails loud"

# --- 10. catalog fixture missing the slug ------------------------------------
: >"$gh_log"; : >"$triage"
base_caps; base_models
write_catalog <<'TSV'
provider            model                                               context  max-out  thinking  images
straitly            gpt-5.6-sol                                         1.1M     32K      yes       yes
TSV
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario10: missing catalog slug must exit 1, got rc=$env_rc ($env_out)"
grep -q 'not in Pi' <<<"$env_out" || fail "scenario10: must name unproven ($env_out)"
grep -q 'issue create' "$gh_log" || fail "scenario10: must auto-file"
ok "scenario10: allowlisted slug missing from catalog fails loud"

# --- 11. active straitly worker, missing meter evidence -> no ticket --------
# fleet-ops#1338 regression: the old code auto-filed a meter-check ticket
# whenever an active straitly/ds4-pro worker had no recent meter evidence.
# The public Straitly API exposes no non-admin balance endpoint, so workers
# cannot complete that ticket. The canary must stay green and file NOTHING.
: >"$gh_log"; : >"$triage"
base_caps; base_models; base_catalog
rm -f "$scratch/meter.json"
cat >"$scratch/active-seats/pi-issue-test.json" <<'JSON'
{ "provider": "straitly", "model": "deepseek/deepseek-v4-pro", "unit": "pi-issue-test", "started_at": "2026-08-27T05:00:00Z" }
JSON
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario11: active worker without meter must exit 0, got rc=$env_rc ($env_out)"
grep -q 'STRAITLY-DS4PRO-OK' <<<"$env_out" || fail "scenario11: must log OK ($env_out)"
if grep -q 'issue create' "$gh_log"; then
  fail "scenario11: must NOT auto-file a meter-check ticket (fleet-ops#1338): gh=$(cat "$gh_log")"
fi
if grep -q 'METER-CHECK' <<<"$env_out"; then
  fail "scenario11: must not raise a meter-check loud line ($env_out)"
fi
ok "scenario11: active straitly worker with no meter evidence files nothing (fleet-ops#1338)"

# --- 12. production seat-caps passes -----------------------------------------
: >"$gh_log"; : >"$triage"
base_models
prod_catalog="$scratch/prod-catalog.tsv"
cat >"$prod_catalog" <<'TSV'
provider            model                                               context  max-out  thinking  images
straitly            deepseek/deepseek-v4-pro                            350K     32.8K    yes       yes
TSV
prod_models="$scratch/models.json"
if [[ -f /home/nish/.pi/agent/models.json ]]; then
  prod_models="/home/nish/.pi/agent/models.json"
fi
set +e
prod_out=$(
  SEAT_CAPS_JSON="$repo_root/config/seat-caps.json" \
  FLEET_STRAITLY_DS4PRO_MODELS_JSON="$prod_models" \
  FLEET_STRAITLY_DS4PRO_CATALOG="$prod_catalog" \
  FLEET_STRAITLY_DS4PRO_FILE=0 \
  FLEET_OPS_REPO="$repo_root" \
  "$bin" 2>&1
)
prod_rc=$?
set -e
[[ "$prod_rc" == "0" ]] || fail "scenario12: production seat-caps must be clean, got rc=$prod_rc ($prod_out)"
grep -q 'STRAITLY-DS4PRO-OK' <<<"$prod_out" || fail "scenario12: production must log OK ($prod_out)"
# Production must only allowlist the ds4-pro slug on straitly.
jq -e '.providers.straitly.class == "metered" and .providers.straitly.cap <= 2 and .providers.straitly.models["deepseek/deepseek-v4-pro"] <= 2' \
  "$repo_root/config/seat-caps.json" >/dev/null \
  || fail "scenario12: production straitly is metered with cap<=2"
ok "scenario12: production seat-caps is clean"

# --- 13. heartbeat wiring ----------------------------------------------------
grep -F 'fleet-straitly-ds4-pro-canary' "$tier1" >/dev/null \
  || fail "tier1 must invoke fleet-straitly-ds4-pro-canary"
grep -F 'straitly_canary_rc' "$tier1" >/dev/null \
  || fail "tier1 must capture straitly_canary_rc"
grep -F -- 'exit "$straitly_canary_rc"' "$tier1" >/dev/null \
  || fail "tier1 must exit non-zero when the straitly gate fails loud"
grep -q 'bin/fleet-straitly-ds4-pro-canary' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/fleet-straitly-ds4-pro-canary"
ok "scenario13: heartbeat-tier1 wires the canary, fail-loud, MANIFEST installs it"

ok "fleet-straitly-ds4-pro-canary: missing, class, caps, models, double-wire, models.json, catalog, no-meter-ticket (fleet-ops#1338), production clean"
