#!/usr/bin/env bash
# tests/fleet-max-speed.test.sh
#
# sr-max-speed invariant (fleet-ops#516): only money, safety, and hardware
# may slow work down. Artificial limiters (sleep-as-throttle, banned
# phrases, concurrency=1) are LOUD [ARTIFICIAL-LIMITER] that auto-file.
#
# What we prove:
#   1. Clean fixture (no limiters) -> exit 0, MAX-SPEED-OK.
#   2. `sleep 30` in bin/ without LEGAL-BRAKE -> exit 1.
#   3. Same sleep with LEGAL-BRAKE: hardware above -> exit 0.
#   4. "deliberately conservative" phrase -> exit 1.
#   5. MAX_JOBS=1 -> exit 1.
#   6. Auto-file: gh mock creates an issue with the signal key, deduped
#      on a second run.
#   7. Live checkout is clean (inner-loop run of the deliverable).
#   8. CI host lock: this file listed in ci.yml OR invoked from
#      tests/rule-enforcement.test.sh (workers cannot edit workflows).
#   9. Matrix lock: sr-max-speed stays `enforced` with this detector named.
#  10. Heartbeat + MANIFEST wiring.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-max-speed"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$bin" ]] || fail "fleet-max-speed not found: $bin"
[[ -x "$bin" ]] || fail "fleet-max-speed not executable: $bin"
command -v jq >/dev/null || fail "jq required"
command -v python3 >/dev/null || fail "python3 required"

scratch="$(mktemp -d -t maxspeed.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

gh_store="$scratch/gh-issues"
mkdir -p "$gh_store"
cat >"$scratch/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
store="${GH_MOCK_STORE:?}"
cmd="$1"; shift
case "$cmd" in
  issue)
    sub="$1"; shift
    case "$sub" in
      create)
        title=""; body=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --title) title="$2"; shift 2 ;;
            --body) body="$2"; shift 2 ;;
            --repo) shift 2 ;;
            *) shift ;;
          esac
        done
        n=$(ls "$store" | wc -l)
        f="$store/issue-$((n+1)).body"
        printf '%s\n' "$title" > "$f"
        printf '%s\n' "$body" >> "$f"
        echo "https://github.com/Nishfleet/fleet-ops/issues/9999"
        ;;
      list)
        printf '[\n'
        first=1
        for f in "$store"/*.body; do
          [ -f "$f" ] || continue
          body=$(tail -n +2 "$f")
          if [ "$first" = 1 ]; then first=0; else printf ',\n'; fi
          printf '{"number":1,"title":"","body":%s}' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$body")"
        done
        printf '\n]\n'
        ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$scratch/gh"

fixture_root="$scratch/repo"
mkdir -p "$fixture_root/bin" "$fixture_root/lib"
printf '%s\n' '#!/usr/bin/env bash' 'echo ok' >"$fixture_root/bin/clean.sh"

run_bin() {
  set +e
  FLEET_MAX_SPEED_ROOT="$fixture_root" \
  FLEET_MAX_SPEED_SLEEP_SECS="5" \
  FLEET_MAX_SPEED_FILE_ISSUES="${1:-0}" \
  GH="$scratch/gh" \
  GH_MOCK_STORE="$gh_store" \
  FLEET_MAX_SPEED_ISSUE_REPO="Nishfleet/fleet-ops" \
  FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
    "$bin" >/dev/null 2>"$scratch/err.log"
  local rc=$?
  set -e
  echo "$rc"
}

# --- 1. clean fixture -------------------------------------------------------
: >"$scratch/triage.md"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || { cat "$scratch/err.log"; fail "clean fixture should exit 0 (got $rc)"; }
grep -q "MAX-SPEED-OK" "$scratch/err.log" || fail "clean fixture missing OK line"
ok "clean fixture exits 0 with MAX-SPEED-OK"

# --- 2. sleep 30 without brake ----------------------------------------------
printf '%s\n' '#!/usr/bin/env bash' 'sleep 30' 'echo after' >"$fixture_root/bin/slow.sh"
: >"$scratch/triage.md"
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "sleep 30 without LEGAL-BRAKE should exit 1 (got $rc)"
grep -q "ARTIFICIAL-LIMITER" "$scratch/err.log" || fail "missing ARTIFICIAL-LIMITER loud line"
grep -q "sleep 30" "$scratch/err.log" || fail "missing sleep 30 mention"
ok "sleep 30 without LEGAL-BRAKE is flagged"

# --- 3. same sleep with LEGAL-BRAKE -----------------------------------------
printf '%s\n' '#!/usr/bin/env bash' \
  '# LEGAL-BRAKE: hardware — wait for oomd to reap the hog' \
  'sleep 30' >"$fixture_root/bin/slow.sh"
: >"$scratch/triage.md"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || { cat "$scratch/err.log"; fail "LEGAL-BRAKE sleep 30 should exit 0 (got $rc)"; }
ok "LEGAL-BRAKE: hardware above sleep 30 is allowed"

rm -f "$fixture_root/bin/slow.sh"

# --- 4. banned phrase -------------------------------------------------------
printf '%s\n' '#!/usr/bin/env bash' '# deliberately conservative throttle' 'true' \
  >"$fixture_root/bin/polite.sh"
: >"$scratch/triage.md"
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "banned phrase should exit 1 (got $rc)"
grep -q "deliberately conservative" "$scratch/err.log" || fail "missing phrase mention"
ok "deliberately conservative phrase is flagged"
rm -f "$fixture_root/bin/polite.sh"

# --- 5. MAX_JOBS=1 ----------------------------------------------------------
printf '%s\n' '#!/usr/bin/env bash' 'MAX_JOBS=1' 'xargs -P "$MAX_JOBS"' \
  >"$fixture_root/bin/serial.sh"
: >"$scratch/triage.md"
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "MAX_JOBS=1 should exit 1 (got $rc)"
grep -q "concurrency" "$scratch/err.log" || grep -q "MAX_JOBS=1" "$scratch/err.log" \
  || fail "missing concurrency finding"
ok "MAX_JOBS=1 is flagged"
rm -f "$fixture_root/bin/serial.sh"

# --- 6. auto-file + dedupe --------------------------------------------------
printf '%s\n' '#!/usr/bin/env bash' 'sleep 60' >"$fixture_root/bin/slow.sh"
: >"$scratch/triage.md"
set +e
FLEET_MAX_SPEED_ROOT="$fixture_root" \
FLEET_MAX_SPEED_SLEEP_SECS="5" \
FLEET_MAX_SPEED_FILE_ISSUES=1 \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_MAX_SPEED_ISSUE_REPO="Nishfleet/fleet-ops" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err2.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "auto-file run should exit 1 (got $rc)"
grep -q "FILED" "$scratch/err2.log" || { cat "$scratch/err2.log"; fail "auto-file did not file an issue"; }
grep -rq "signal: max-speed/" "$scratch/gh-issues" || fail "filed issue body missing signal key"
ok "auto-file creates an issue with the signal key"

set +e
FLEET_MAX_SPEED_ROOT="$fixture_root" \
FLEET_MAX_SPEED_SLEEP_SECS="5" \
FLEET_MAX_SPEED_FILE_ISSUES=1 \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_MAX_SPEED_ISSUE_REPO="Nishfleet/fleet-ops" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err3.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "second auto-file run should still exit 1 (got $rc)"
grep -q "deduped" "$scratch/err3.log" || fail "second run did not dedupe"
grep -rl "signal: max-speed/" "$scratch/gh-issues" | wc -l | grep -q "^1$" \
  || fail "signal key filed more than once (dedupe broken)"
ok "auto-file dedupes the signal key on a second run"
rm -f "$fixture_root/bin/slow.sh"

# --- 7. live checkout is clean ----------------------------------------------
set +e
FLEET_MAX_SPEED_ROOT="$repo_root" \
FLEET_MAX_SPEED_SLEEP_SECS="5" \
FLEET_MAX_SPEED_FILE_ISSUES=0 \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage-live.md" \
  "$bin" >/dev/null 2>"$scratch/live.err"
live_rc=$?
set -e
[[ "$live_rc" == "0" ]] || { cat "$scratch/live.err"; fail "live checkout must be clean (got $live_rc)"; }
grep -q "MAX-SPEED-OK" "$scratch/live.err" || fail "live scan missing MAX-SPEED-OK"
ok "live checkout has no unannotated artificial limiters"

# --- 8. CI host lock (workers cannot edit .github/workflows) ----------------
ci_yml="$repo_root/.github/workflows/ci.yml"
listed=0
hosted=0
grep -Fq 'bash tests/fleet-max-speed.test.sh' "$ci_yml" && listed=1
grep -Fq 'bash "$here/fleet-max-speed.test.sh"' "$repo_root/tests/rule-enforcement.test.sh" && hosted=1
if [[ "$listed" -eq 0 && "$hosted" -eq 0 ]]; then
  fail "fleet-max-speed.test.sh has no CI host (fleet-ops#516): list it in ci.yml or invoke it from rule-enforcement.test.sh"
fi
ok "CI host exists (ci.yml listed=$listed rule-enforcement hosted=$hosted)"

# --- 9. matrix lock ---------------------------------------------------------
matrix="$repo_root/config/rule-enforcement.json"
status=$(jq -r '.rules[] | select(.id=="sr-max-speed") | .status' "$matrix")
[[ "$status" == "enforced" ]] || fail "sr-max-speed status must be enforced, got $status"
proof=$(jq -r '.rules[] | select(.id=="sr-max-speed") | .proof' "$matrix")
grep -q 'bin/fleet-max-speed' <<<"$proof" || fail "sr-max-speed proof must name bin/fleet-max-speed"
ok "sr-max-speed stays enforced with this detector named in proof"

# --- 10. heartbeat + MANIFEST wiring ----------------------------------------
grep -q 'FLEET_MAX_SPEED' "$repo_root/bin/fleet-heartbeat-tier1" \
  || fail "fleet-heartbeat-tier1 must invoke fleet-max-speed"
grep -q 'fleet-max-speed' "$repo_root/bin/fleet-heartbeat-tier1" \
  || fail "fleet-heartbeat-tier1 must name fleet-max-speed"
grep -Fq 'bin/fleet-max-speed /home/nish/.local/bin/fleet-max-speed' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/fleet-max-speed"
ok "heartbeat tier1 and MANIFEST wire the detector"

echo "OK: fleet-max-speed: limiter hunt, LEGAL-BRAKE, loud fail, auto-file dedupe, live clean"
