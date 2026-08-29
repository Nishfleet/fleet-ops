#!/usr/bin/env bash
# tests/paid-flash-canary.test.sh
#
# Proves the parked-flash watcher (fleet-ops#436) offline:
#   1. Qwen 3.8 flash absent -> exit 0, PARKED line, no filing.
#   2. Qwen 3.8 flash appears -> exit 0, TRANSITION, auto-files (title + marker).
#   3. Dedup: an open issue already carrying the marker -> no second create.
#   4. pi missing -> exit 1, WATCHER-BROKEN (fail loud, never silent).
#   5. Heartbeat-tier1 wires the canary and propagates a broken-watcher exit.
#   6. GLM 5.3 flash no longer watched: it is wired free on cline (#1739) and
#      the paid-lane question is resolved (#384 — DeepSeek V4 flash is
#      cheaper+best), so a GLM 5.3 flash slug in the catalog must NOT file.
#
# The parked state is expected, so absence is exit 0 (not a violation). The
# canary files on the transition only.
#
# test-removal-justified: the prior GLM 5.3 flash transition scenarios (old
# 2 + 4) were dropped because #384 removed the glm-5.3-flash watch row —
# GLM 5.3 flash is wired free on cline (fleet-ops#1739) and as a paid
# openrouter/zenmux lane it loses to DeepSeek V4 flash on price, so no paid
# lane is needed and the canary must not file a revisit for it (would re-file
# the resolved #1749). Scenario 6 below pins the no-fire invariant.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-paid-flash-canary"
tier1="$repo_root/bin/fleet-heartbeat-tier1"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$tier1" ]] || fail "missing: $tier1"

scratch="$(mktemp -d -t paid-flash-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
triage="$scratch/triage.md"
: >"$triage"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export FLEET_PAID_FLASH_REPO="Nishfleet/fleet-ops"
export FLEET_PAID_FLASH_FILE=1

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

write_catalog() {
  cat >"$scratch/catalog.txt"
}

run_canary() {
  set +e
  env_out=$(
    FLEET_PAID_FLASH_MODELS_JSON="$scratch/catalog.txt" \
    FLEET_OPS_REPO="$scratch" \
    "$bin" 2>&1
  )
  env_rc=$?
  set -e
}

# --- 1. Qwen 3.8 flash absent -> parked, quiet ------------------------------
: >"$gh_log"
: >"$triage"
write_catalog <<'TXT'
EXTLOAD-OK extension=packet-verdict mode=print-safe
provider            model                                               context  max-out  thinking  images
openrouter          z-ai/glm-5.3                                        1.0M     131.1K   yes       no
openrouter          qwen/qwen3.8-27b                                    262.1K   131.1K   yes       yes
openrouter          deepseek/deepseek-v4-flash-0731                     1.3M     32.8K    no        no
cline               z-ai/glm-5.3-flash                                  131.1K   16.4K    no        no
TXT
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario1: expected rc=0, got $env_rc ($env_out)"
grep -q 'PAID-FLASH-PARKED' "$triage" || fail "scenario1: missing PARKED line"
! grep -q 'issue create' "$gh_log" || fail "scenario1: must not file when parked"
# glm-5.3 (non-flash) AND glm-5.3-flash (now wired free, watch removed) must NOT trigger.
! printf '%s\n' "$env_out" | grep -q 'TRANSITION: glm-5.3-flash' \
  || fail "scenario1: glm-5.3-flash must not match (watch row removed — #384)"
ok "scenario1: Qwen absent + GLM 5.3 flash present -> parked, no filing"

# --- 2. Qwen 3.8 flash appears -> transition + file -------------------------
: >"$gh_log"
: >"$triage"
write_catalog <<'TXT'
provider            model                                               context  max-out  thinking  images
openrouter          qwen/qwen3.8-flash                                  1.0M     131.1K   yes       no
TXT
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario2: expected rc=0, got $env_rc ($env_out)"
printf '%s\n' "$env_out" | grep -q 'TRANSITION: qwen-3.8-flash' || fail "scenario2: must log Qwen transition"
grep -q 'PAID-FLASH-AVAILABLE' "$triage" || fail "scenario2: missing AVAILABLE line"
grep -q 'issue create' "$gh_log" || fail "scenario2: must auto-file"
grep -q 'Qwen 3.8 flash now in Pi catalog' "$gh_log" || fail "scenario2: filed title must name Qwen 3.8 flash"
grep -q 'paid-flash-canary: qwen-3.8-flash available' "$gh_log" \
  || fail "scenario2: filed body must carry the dedup marker"
ok "scenario2: Qwen 3.8 flash transition files a revisit ticket"

# --- 3. dedup against an open issue with the marker -------------------------
: >"$gh_log"
: >"$triage"
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n --arg b $'body\npaid-flash-canary: qwen-3.8-flash available\n' \
  '[{number: 42, body: $b}]' >"$GH_OPEN_ISSUES"
write_catalog <<'TXT'
provider            model                                               context  max-out  thinking  images
openrouter          qwen/qwen3.8-flash                                  1.0M     131.1K   yes       no
TXT
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario3: expected rc=0, got $env_rc ($env_out)"
grep -q 'issue create' "$gh_log" && fail "scenario3: must not file a duplicate"
printf '%s\n' "$env_out" | grep -q 'dedup' || fail "scenario3: must log dedup"
ok "scenario3: open issue with marker dedupes"

unset GH_OPEN_ISSUES

# --- 4. pi missing -> fail loud ---------------------------------------------
: >"$gh_log"
: >"$triage"
set +e
broken_out=$(
  unset FLEET_PAID_FLASH_MODELS_JSON
  PI="$scratch/no-such-pi" \
  FLEET_OPS_REPO="$scratch" \
  "$bin" 2>&1
)
broken_rc=$?
set -e
[[ "$broken_rc" == "1" ]] || fail "scenario4: expected rc=1 when pi missing, got $broken_rc ($broken_out)"
grep -q 'PAID-FLASH-WATCHER-BROKEN' "$triage" || fail "scenario4: missing WATCHER-BROKEN line"
ok "scenario4: pi missing fails loud (never silent)"

# --- 5. heartbeat wiring -----------------------------------------------------
grep -F 'fleet-paid-flash-canary' "$tier1" >/dev/null \
  || fail "tier1 must invoke fleet-paid-flash-canary"
grep -F 'paid_flash_canary_rc' "$tier1" >/dev/null \
  || fail "tier1 must capture paid_flash_canary_rc"
grep -F -- 'exit "$paid_flash_canary_rc"' "$tier1" >/dev/null \
  || fail "tier1 must exit non-zero when the paid-flash watcher is broken"
ok "scenario5: heartbeat-tier1 wires the canary and propagates fail-loud"

ok "paid-flash-canary: parked-quiet, qwen-transition-files, dedup, glm-not-watched, broken-fails-loud, heartbeat-wired"
