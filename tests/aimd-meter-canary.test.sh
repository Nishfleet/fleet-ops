#!/usr/bin/env bash
# tests/aimd-meter-canary.test.sh
#
# Proves the leftover-AIMD-meter canary (fleet-ops#424) offline:
#   1. AIMD reader present, no leftover log -> exit 0, OK line.
#   2. AIMD reader gone + leftover audit log -> exit 1, LOUD, auto-files
#      (the class drill: code vanished, meter remains).
#   3. AIMD present + backoff-only leftover log -> archives to *.pre-424, exit 0.
#   4. Dedup: an open issue already carrying the marker -> no second create.
#   5. Production seat-lib.sh currently has the AIMD reader.
#   6. Heartbeat-tier1 wires the canary and propagates a non-zero exit.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-aimd-meter-canary"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$tier1" ]] || fail "missing: $tier1"
[[ -f "$lib" ]] || fail "missing: $lib"

scratch="$(mktemp -d -t aimd-meter-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
triage="$scratch/triage.md"
: >"$triage"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export FLEET_AIMD_CANARY_REPO="Nishfleet/fleet-ops"
export FLEET_AIMD_CANARY_FILE=1

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

# fleet-ops#1212: live canary files via fleet-issue-file, which ends up
# calling `gh issue create`. Point ISSUE_FILE at a shim that logs the
# same way the GH fake does so scenario 2/4 can assert create vs dedup.
issue_file="$scratch/fleet-issue-file"
cat >"$issue_file" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
echo "https://github.com/Nishfleet/fleet-ops/issues/999"
exit 0
FAKE
chmod +x "$issue_file"
export FLEET_ISSUE_FILE="$issue_file"

write_lib() {
  cat >"$scratch/seat-lib.sh"
}

run_canary() {
  set +e
  env_out=$(
    FLEET_AIMD_SEAT_LIB="$scratch/seat-lib.sh" \
    LEARNED_CAPS_AUDIT="$scratch/learned-caps-audit.log" \
    LEARNED_CAPS_JSON="$scratch/learned-caps.json" \
    FLEET_AIMD_ADOPT_STAMP="$scratch/adopted.stamp" \
    FLEET_OPS_REPO="$scratch" \
    "$bin" 2>&1
  )
  env_rc=$?
  set -e
}

# --- 1. AIMD present, no leftover -------------------------------------------
: >"$gh_log"
: >"$triage"
rm -f "$scratch/learned-caps-audit.log" "$scratch/learned-caps.json" "$scratch/adopted.stamp"
write_lib <<'SH'
# fake seat-lib with AIMD symbols
_aimd_probe_admitted() { return 0; }
effective_provider_cap() { echo 1; }
_record_learned_cap() { return 0; }
SH
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario1: expected rc=0, got $env_rc ($env_out)"
grep -q 'AIMD-METER-OK' "$triage" || fail "scenario1: missing OK line ($env_out)"
! grep -q 'issue create' "$gh_log" || fail "scenario1: must not file on a live reader"
ok "scenario1: AIMD reader present, no leftover, quiet"

# --- 2. AIMD gone + leftover log -> scream + file (the class drill) ---------
: >"$gh_log"
: >"$triage"
rm -f "$scratch/adopted.stamp"
write_lib <<'SH'
# seat-lib after auto-revert: no AIMD
provider_cap() { echo 2; }
SH
printf '[2026-08-26T09:36:02Z] aimd cline: learned_cap=1 result=backoff bench_until=2026-08-27T08:00:00.000Z\n' \
  >"$scratch/learned-caps-audit.log"
echo '{"providers":{"cline":{"learned_cap":1,"last_result":"backoff"}}}' \
  >"$scratch/learned-caps.json"
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario2: expected rc=1, got $env_rc ($env_out)"
grep -q 'AIMD-METER-ORPHAN' "$triage" || fail "scenario2: missing ORPHAN ($env_out)"
grep -qE 'issue create|^file ' "$gh_log" || fail "scenario2: must auto-file ($gh_log)"
ok "scenario2: leftover meter with no reader screams and auto-files"

# --- 3. AIMD present + backoff-only leftover -> archive ---------------------
: >"$gh_log"
: >"$triage"
rm -f "$scratch/adopted.stamp"
write_lib <<'SH'
_aimd_probe_admitted() { return 0; }
effective_provider_cap() { echo 1; }
_record_learned_cap() { return 0; }
SH
printf '[2026-08-26T09:36:02Z] aimd cline: learned_cap=1 result=backoff bench_until=2026-08-27T08:00:00.000Z\n' \
  >"$scratch/learned-caps-audit.log"
echo '{"providers":{"cline":{"learned_cap":1,"last_result":"backoff"}}}' \
  >"$scratch/learned-caps.json"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario3: expected rc=0, got $env_rc ($env_out)"
[[ -f "$scratch/learned-caps-audit.log.pre-424" ]] \
  || fail "scenario3: leftover audit must be archived to *.pre-424"
[[ ! -f "$scratch/learned-caps-audit.log" ]] \
  || fail "scenario3: live audit must be moved aside so old backoff is not a live meter"
[[ -f "$scratch/adopted.stamp" ]] || fail "scenario3: adopt stamp must be written"
! grep -qE 'issue create|^file ' "$gh_log" || fail "scenario3: must not file when the reader is back"
ok "scenario3: AIMD present archives backoff-only leftover meter"

# --- 4. Dedup ----------------------------------------------------------------
: >"$gh_log"
: >"$triage"
rm -f "$scratch/adopted.stamp" "$scratch/learned-caps-audit.log.pre-424"
write_lib <<'SH'
provider_cap() { echo 2; }
SH
printf '[2026-08-26T09:36:02Z] aimd cline: learned_cap=1 result=backoff\n' \
  >"$scratch/learned-caps-audit.log"
jq -n --arg b $'body\naimd-meter-canary: orphan-meter\n' \
  '[{number:424, body:$b}]' >"$scratch/open.json"
export GH_OPEN_ISSUES="$scratch/open.json"
run_canary
unset GH_OPEN_ISSUES
[[ "$env_rc" == "1" ]] || fail "scenario4: expected rc=1, got $env_rc ($env_out)"
grep -q 'AIMD-METER-ORPHAN' "$triage" || fail "scenario4: still LOUD on dedup"
! grep -qE 'issue create|^file ' "$gh_log" || fail "scenario4: must not create a second issue"
ok "scenario4: open issue with marker is deduped"

# --- 5. production seat-lib currently has the AIMD reader -------------------
: >"$gh_log"
: >"$triage"
set +e
prod_out=$(
  FLEET_AIMD_SEAT_LIB="$lib" \
  LEARNED_CAPS_AUDIT="$scratch/prod-audit.log" \
  LEARNED_CAPS_JSON="$scratch/prod-learned.json" \
  FLEET_AIMD_ADOPT_STAMP="$scratch/prod.stamp" \
  FLEET_AIMD_CANARY_FILE=0 \
  FLEET_OPS_REPO="$repo_root" \
  "$bin" 2>&1
)
prod_rc=$?
set -e
[[ "$prod_rc" == "0" ]] || fail "scenario5: production seat-lib must have AIMD reader, got rc=$prod_rc ($prod_out)"
ok "scenario5: production lib/seat-lib.sh has the AIMD reader"

# --- 6. heartbeat wiring -----------------------------------------------------
grep -F 'fleet-aimd-meter-canary' "$tier1" >/dev/null \
  || fail "tier1 must invoke fleet-aimd-meter-canary"
grep -F 'aimd_canary_rc' "$tier1" >/dev/null \
  || fail "tier1 must capture aimd_canary_rc"
grep -F -- 'exit "$aimd_canary_rc"' "$tier1" >/dev/null \
  || fail "tier1 must exit non-zero when the AIMD meter canary fails loud"
ok "scenario6: heartbeat-tier1 wires the canary and propagates fail-loud"

ok "aimd-meter-canary: orphan meter, archive, dedup, production reader, heartbeat wiring"
