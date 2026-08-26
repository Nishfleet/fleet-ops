#!/usr/bin/env bash
# tests/fleet-cline-glm53-canary.test.sh
#
# Proves the ClinePass GLM 5.3 flash canary (fleet-ops#462) offline:
#   1. Clean: cline has DS4 flash + MiniMax M3 only, catalog matches -> OK, no file.
#   2. Billing prefix: glm-5.3-flash (no cline-pass/) allowlisted -> exit 1, LOUD, auto-files.
#   3. Non-flash: cline-pass/glm-5.3 allowlisted as if it were free flash -> exit 1.
#   4. Unproven: cline-pass/glm-5.3-flash allowlisted, catalog 404 -> exit 1.
#   5. Catalog grows cline-pass/glm-5.3-flash, not allowlisted -> exit 0, files prove+wire.
#   6. glm-5.2 / openrouter z-ai/glm-5.3-flash are not this lane.
#   7. Wired + in catalog + missing models.json entry -> exit 1.
#   8. Wired + in catalog + in models.json -> OK.
#   9. Dedup: open issue already carrying the marker -> no second create.
#  10. pi missing and no fixture -> exit 1 (watcher broken).
#  11. Production seat-caps has no GLM 5.3 family slug on cline.
#  12. Heartbeat-tier1 wires the canary, fail-loud, MANIFEST installs it.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-cline-glm53-canary"
tier1="$repo_root/bin/fleet-heartbeat-tier1"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$tier1" ]] || fail "missing: $tier1"

scratch="$(mktemp -d -t cline-glm53-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
triage="$scratch/triage.md"
: >"$triage"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export FLEET_CLINE_GLM53_REPO="Nishfleet/fleet-ops"
export FLEET_CLINE_GLM53_FILE=1

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
write_catalog() { cat >"$scratch/catalog.tsv"; }
write_models() { cat >"$scratch/models.json"; }

base_caps() {
  write_caps <<'JSON'
{
  "providers": {
    "cline": {
      "cap": 2,
      "class": "prepaid-quota",
      "models": {
        "cline-pass/minimax-m3": 2,
        "cline-pass/deepseek-v4-flash": 2
      }
    }
  }
}
JSON
}

base_catalog() {
  write_catalog <<'TSV'
cline               cline-pass/deepseek-v4-flash                        131.1K   16.4K    no        no
cline               cline-pass/minimax-m3                               200K     32K      no        no
openrouter          z-ai/glm-5.3                                        1.0M     131.1K   yes       no
TSV
}

base_models() {
  write_models <<'JSON'
{
  "providers": {
    "cline": {
      "models": [
        { "id": "cline-pass/deepseek-v4-flash" },
        { "id": "cline-pass/minimax-m3" }
      ]
    }
  }
}
JSON
}

run_canary() {
  set +e
  env_out=$(
    SEAT_CAPS_JSON="$scratch/seat-caps.json" \
    FLEET_CLINE_GLM53_CATALOG="$scratch/catalog.tsv" \
    FLEET_CLINE_GLM53_MODELS_JSON="$scratch/models.json" \
    FLEET_OPS_REPO="$scratch" \
    "$bin" 2>&1
  )
  env_rc=$?
  set -e
}

# --- 1. clean --------------------------------------------------------------
: >"$gh_log"; : >"$triage"
base_caps; base_catalog; base_models
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario1: clean must exit 0, got rc=$env_rc ($env_out)"
grep -q 'CLINE-GLM53-OK' <<<"$env_out" || fail "scenario1: must log OK ($env_out)"
if grep -q 'issue create' "$gh_log"; then
  fail "scenario1: must not file (gh=$(cat "$gh_log"))"
fi
ok "scenario1: clean parked state is green, no file"

# --- 2. billing prefix -----------------------------------------------------
: >"$gh_log"; : >"$triage"
write_caps <<'JSON'
{
  "providers": {
    "cline": {
      "models": {
        "glm-5.3-flash": 2,
        "cline-pass/deepseek-v4-flash": 2
      }
    }
  }
}
JSON
base_catalog; base_models
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario2: billing prefix must exit 1, got rc=$env_rc ($env_out)"
grep -q 'CLINE-GLM53-VIOLATION' <<<"$env_out" || fail "scenario2: must LOUD ($env_out)"
grep -q 'issue create' "$gh_log" || fail "scenario2: must auto-file (gh=$(cat "$gh_log"))"
ok "scenario2: billing GLM 5.3 flash without cline-pass/ fails loud and files"

# --- 3. non-flash glm-5.3 --------------------------------------------------
: >"$gh_log"; : >"$triage"
write_caps <<'JSON'
{
  "providers": {
    "cline": {
      "models": {
        "cline-pass/glm-5.3": 2,
        "cline-pass/deepseek-v4-flash": 2
      }
    }
  }
}
JSON
base_catalog; base_models
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario3: non-flash must exit 1, got rc=$env_rc ($env_out)"
grep -q 'non-flash' <<<"$env_out" || fail "scenario3: must name non-flash ($env_out)"
grep -q 'issue create' "$gh_log" || fail "scenario3: must auto-file"
ok "scenario3: non-flash cline-pass/glm-5.3 fails loud"

# --- 4. unproven guessed 404 ----------------------------------------------
: >"$gh_log"; : >"$triage"
write_caps <<'JSON'
{
  "providers": {
    "cline": {
      "models": {
        "cline-pass/glm-5.3-flash": 2,
        "cline-pass/deepseek-v4-flash": 2
      }
    }
  }
}
JSON
base_catalog; base_models
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario4: unproven must exit 1, got rc=$env_rc ($env_out)"
grep -q 'unproven' <<<"$env_out" || fail "scenario4: must name unproven ($env_out)"
grep -q 'issue create' "$gh_log" || fail "scenario4: must auto-file"
ok "scenario4: guessed 404 slug allowlisted fails loud"

# --- 5. catalog grows free-form flash, not wired ---------------------------
: >"$gh_log"; : >"$triage"
base_caps; base_models
write_catalog <<'TSV'
cline               cline-pass/deepseek-v4-flash                        131.1K
cline               cline-pass/minimax-m3                               200K
cline               cline-pass/glm-5.3-flash                            1.0M
TSV
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario5: discovery must exit 0 (not starve the tick), got rc=$env_rc ($env_out)"
grep -q 'CLINE-GLM53-AVAILABLE' <<<"$env_out" || fail "scenario5: must log AVAILABLE ($env_out)"
grep -q 'issue create' "$gh_log" || fail "scenario5: must file prove+wire"
grep -q 'flash-slug-available' "$gh_log" || true
ok "scenario5: unwired catalog flash slug files prove+wire, tick stays green"

# --- 6. glm-5.2 and openrouter flash are not this lane ---------------------
: >"$gh_log"; : >"$triage"
base_caps; base_models
write_catalog <<'TSV'
cline               cline-pass/deepseek-v4-flash                        131.1K
cline               cline-pass/glm-5.2                                  200K
openrouter          z-ai/glm-5.3-flash                                  1.0M
TSV
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario6: unrelated slugs must stay green, got rc=$env_rc ($env_out)"
if grep -q 'issue create' "$gh_log"; then
  fail "scenario6: must not file for glm-5.2 or openrouter flash (gh=$(cat "$gh_log"))"
fi
ok "scenario6: glm-5.2 and openrouter glm-5.3-flash are ignored"

# --- 7. wired + in catalog, missing models.json ----------------------------
: >"$gh_log"; : >"$triage"
write_caps <<'JSON'
{
  "providers": {
    "cline": {
      "models": {
        "cline-pass/glm-5.3-flash": 2,
        "cline-pass/deepseek-v4-flash": 2
      }
    }
  }
}
JSON
write_catalog <<'TSV'
cline               cline-pass/deepseek-v4-flash                        131.1K
cline               cline-pass/glm-5.3-flash                            1.0M
TSV
base_models
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario7: missing models.json entry must exit 1, got rc=$env_rc ($env_out)"
grep -q 'models.json' <<<"$env_out" || fail "scenario7: must name models.json ($env_out)"
ok "scenario7: allowlisted flash missing from models.json fails loud"

# --- 8. fully proven wired -------------------------------------------------
: >"$gh_log"; : >"$triage"
write_caps <<'JSON'
{
  "providers": {
    "cline": {
      "models": {
        "cline-pass/glm-5.3-flash": 2,
        "cline-pass/deepseek-v4-flash": 2
      }
    }
  }
}
JSON
write_catalog <<'TSV'
cline               cline-pass/deepseek-v4-flash                        131.1K
cline               cline-pass/glm-5.3-flash                            1.0M
TSV
write_models <<'JSON'
{
  "providers": {
    "cline": {
      "models": [
        { "id": "cline-pass/deepseek-v4-flash" },
        { "id": "cline-pass/glm-5.3-flash" }
      ]
    }
  }
}
JSON
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario8: proven wired must exit 0, got rc=$env_rc ($env_out)"
if grep -q 'issue create' "$gh_log"; then
  fail "scenario8: must not file when already wired (gh=$(cat "$gh_log"))"
fi
ok "scenario8: proven wired flash slug is green"

# --- 9. dedup --------------------------------------------------------------
: >"$gh_log"; : >"$triage"
base_caps; base_models
write_catalog <<'TSV'
cline               cline-pass/deepseek-v4-flash                        131.1K
cline               cline-pass/glm-5.3-flash                            1.0M
TSV
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n --arg b $'body\nfleet-cline-glm53-canary: flash-slug-available cline-pass/glm-5.3-flash\n' \
  '[{number: 77, body: $b}]' >"$GH_OPEN_ISSUES"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario9: dedup must stay exit 0, got rc=$env_rc ($env_out)"
if grep -q 'issue create' "$gh_log"; then
  fail "scenario9: must not create a second issue (gh=$(cat "$gh_log"))"
fi
grep -q 'dedup:' <<<"$env_out" || fail "scenario9: must log dedup ($env_out)"
ok "scenario9: open marker is not filed twice"
unset GH_OPEN_ISSUES

# --- 10. pi missing, no fixture --------------------------------------------
: >"$gh_log"; : >"$triage"
base_caps; base_models
set +e
broken_out=$(
  SEAT_CAPS_JSON="$scratch/seat-caps.json" \
  FLEET_CLINE_GLM53_MODELS_JSON="$scratch/models.json" \
  FLEET_OPS_REPO="$scratch" \
  PI="$scratch/no-such-pi" \
  "$bin" 2>&1
)
broken_rc=$?
set -e
[[ "$broken_rc" == "1" ]] || fail "scenario10: missing pi must exit 1, got rc=$broken_rc ($broken_out)"
grep -q 'WATCHER-BROKEN' <<<"$broken_out" || fail "scenario10: must LOUD watcher-broken ($broken_out)"
ok "scenario10: broken watch fails loud"

# --- 11. production seat-caps ----------------------------------------------
: >"$gh_log"; : >"$triage"
base_catalog; base_models
if jq -r '.providers.cline.models // {} | keys[]' "$repo_root/config/seat-caps.json" \
    | grep -qiE 'glm-5[.-]3'; then
  fail "scenario11: production seat-caps still allowlists a GLM 5.3 family slug on cline"
fi
prod_out=$(
  SEAT_CAPS_JSON="$repo_root/config/seat-caps.json" \
  FLEET_CLINE_GLM53_CATALOG="$scratch/catalog.tsv" \
  FLEET_CLINE_GLM53_MODELS_JSON="$scratch/models.json" \
  FLEET_OPS_REPO="$repo_root" \
  FLEET_CLINE_GLM53_FILE=0 \
  "$bin" 2>&1
) || fail "scenario11: production parked state must exit 0 ($prod_out)"
grep -q 'CLINE-GLM53-OK' <<<"$prod_out" || fail "scenario11: production must log OK ($prod_out)"
ok "scenario11: production seat-caps has no GLM 5.3 family slug on cline"

# --- 12. heartbeat wiring --------------------------------------------------
grep -F 'fleet-cline-glm53-canary' "$tier1" >/dev/null \
  || fail "tier1 must invoke fleet-cline-glm53-canary"
grep -F 'cline_glm53_canary_rc' "$tier1" >/dev/null \
  || fail "tier1 must capture cline_glm53_canary_rc"
grep -F -- 'exit "$cline_glm53_canary_rc"' "$tier1" >/dev/null \
  || fail "tier1 must exit non-zero when the ClinePass GLM 5.3 flash gate fails loud"
grep -q 'bin/fleet-cline-glm53-canary' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/fleet-cline-glm53-canary"
ok "scenario12: heartbeat-tier1 wires the canary, fail-loud, MANIFEST installs it"

ok "fleet-cline-glm53-canary: billing, non-flash, unproven, discovery, ignore, models.json, dedup, broken watch, prod clean"
