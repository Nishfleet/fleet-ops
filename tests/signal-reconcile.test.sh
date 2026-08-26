#!/usr/bin/env bash
# tests/signal-reconcile.test.sh
#
# Proves the detector→queue reconciler + observe-to-close (fleet-ops#362):
#   1. active signal + no open issue      -> file new issue, body carries `signal: <key>`
#   2. active signal + open issue         -> touch daily `signal-checked:` heartbeat comment
#                                          (idempotent for the same UTC date)
#   3. open issue + signal not active now -> close with `signal-cleared:` comment
#                                          (observe-to-close) when the detector ran
#   4. per-target-repo routing: canary -> Nishfleet/fleet-ops;
#                              unit-failed pi-issue@<short>-<N>.service -> Nishfleet/<short>
#   5. cap SIGNAL_RECONCILE_MAX_PER_TICK  -> past the cap, file nothing more and
#                                          write a LOUD [SIGNAL-RECONCILE-CAP] line
#   6. DRY_RUN: prints actions, mutates nothing
#   7. overlap flock: a second concurrent sweep is a no-op
#   8. contracts: tier1 §15 calls it and tees canary into the tick log;
#                MANIFEST installs it; worker prompt forbids `Closes #<N>`
#   9. latest tier1-*.log in TICK_LOG_DIR wins
#  10. canary did not run this tick -> do NOT close canary-keyed issues
#  11. live --state=failed unit with no tick-log loud line still files
#      (the §4 already-in-triage hole)
#
# Entirely offline with a stubbed gh + systemctl and a scratch tier1 tick
# log. Mirrors tests/{claim,blocked}-reconcile.test.sh.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/signal-reconcile"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
canary="$repo_root/bin/fleet-escalation-canary"
manifest="$repo_root/MANIFEST"
worker_prompt="$repo_root/prompts/worker.md"
heartbeat_prompt="$repo_root/prompts/heartbeat.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$tier1" ]] || fail "missing tier1: $tier1"
[[ -f "$canary" ]] || fail "missing canary: $canary"
[[ -f "$manifest" ]] || fail "missing MANIFEST: $manifest"
[[ -f "$worker_prompt" ]] || fail "missing worker prompt: $worker_prompt"
command -v jq >/dev/null 2>&1 || fail "jq missing"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/state" "$scratch/tick-logs" "$scratch/lock" \
         "$scratch/issues" "$scratch/comments"

# --- stubbed gh -------------------------------------------------------------
# File-backed fake gh. Per-repo issue-list lives at
# $FAKE_DIR/issues/<owner>-<name>.json (slash folded to hyphen).
cat >"$scratch/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_DIR/gh.log"
repo_file() {
    local repo="$1"
    printf '%s/issues/%s.json' "$FAKE_DIR" "$(printf '%s' "$repo" | tr '/' '-')"
}
case "$1" in
  issue)
    case "$2" in
      list)
        repo=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            -R) repo="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        f=$(repo_file "$repo")
        if [[ -f "$f" ]]; then
          cat "$f"
        else
          echo '[]'
        fi
        exit 0
        ;;
      create)
        repo=""; title=""; body=""
        shift 2
        while [[ $# -gt 0 ]]; do
          case "$1" in
            -R) repo="$2"; shift 2 ;;
            --title) title="$2"; shift 2 ;;
            --body) body="$2"; shift 2 ;;
            --label) shift 2 ;;
            *) shift ;;
          esac
        done
        printf '%s\n' "$repo|$title|$body" >>"$FAKE_DIR/creates.log"
        printf '%s\n' "$repo" >>"$FAKE_DIR/create_count.log"
        f=$(repo_file "$repo")
        list_json=$(cat "$f" 2>/dev/null || echo '[]')
        next_n=$(printf '%s' "$list_json" | jq -r 'if length==0 then 1 else (. | map(.number) | max) + 1 end')
        tmp=$(mktemp)
        printf '%s' "$list_json" | jq --arg n "$next_n" --arg b "$body" \
            '. + [{number: ($n|tonumber), body:$b, state:"open"}]' >"$tmp"
        mv "$tmp" "$f"
        printf 'https://github.com/%s/issues/%s\n' "$repo" "$next_n"
        exit 0
        ;;
      comment)
        num="$3"; body=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --body) body="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        printf '%s\n' "$body" >>"$FAKE_DIR/comments/${num}.log"
        exit 0
        ;;
      close)
        num="$3"; repo=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            -R) repo="$2"; shift 2 ;;
            --comment) shift 2 ;;
            *) shift ;;
          esac
        done
        printf '%s\n' "$num|$repo" >>"$FAKE_DIR/closes.log"
        if [ -n "$repo" ]; then
          f=$(repo_file "$repo")
          if [ -f "$f" ]; then
            tmp=$(mktemp)
            jq --argjson n "$num" 'map(select(.number != $n))' <"$f" >"$tmp"
            mv "$tmp" "$f"
          fi
        fi
        exit 0
        ;;
      *) echo "unexpected gh issue $*" >&2; exit 1 ;;
    esac
    ;;
  api)
    path="$2"
    case "$path" in
      repos/*/issues/*/comments*)
        num=$(printf '%s' "$path" | sed -nE 's@^repos/[^/]+/[^/]+/issues/([0-9]+)/comments.*@\1@p')
        logf="$FAKE_DIR/comments/${num}.log"
        if [[ -f "$logf" ]]; then
          python3 - "$logf" <<'PY'
import json, sys
lines = open(sys.argv[1]).read().splitlines()
out = [{"id": i + 1, "body": line, "created_at": "2026-08-26T00:00:00Z"}
       for i, line in enumerate(lines)]
print(json.dumps(out))
PY
        else
          echo '[]'
        fi
        exit 0
        ;;
      *) echo "[]"; exit 0 ;;
    esac
    ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$scratch/bin/gh"

# --- stubbed systemctl: empty failed set unless $FAKE_DIR/failed-units exists
cat >"$scratch/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
failed=0
for a in "$@"; do
  case "$a" in
    --state=failed) failed=1 ;;
  esac
done
if [[ "$failed" == "1" && -f "$FAKE_DIR/failed-units" ]]; then
  while IFS= read -r u; do
    [[ -n "$u" ]] && printf '%s loaded failed failed -\n' "$u"
  done < "$FAKE_DIR/failed-units"
fi
exit 0
FAKE
chmod +x "$scratch/bin/systemctl"

export PATH="$scratch/bin:$PATH"
export FAKE_DIR="$scratch"
export SYSTEMCTL="$scratch/bin/systemctl"

NOW_ISO="2026-08-26T16:30:00Z"
write_tick_log() {
    local f="$1"; shift
    {
        printf '[%s] [fleet-heartbeat-tier1] tick start\n' "$NOW_ISO"
        for line in "$@"; do
            [ -z "$line" ] && continue
            printf '[%s] %s\n' "$NOW_ISO" "$line"
        done
        printf '[%s] [fleet-heartbeat-tier1] tier 1 complete\n' "$NOW_ISO"
    } >"$f"
}

reset_world() {
    rm -f "$scratch"/creates.log "$scratch"/closes.log \
          "$scratch"/create_count.log \
          "$scratch"/comments/*.log "$scratch"/gh.log \
          "$scratch"/failed-units "$scratch"/triage.md
    : >"$scratch/creates.log"
    : >"$scratch/closes.log"
    : >"$scratch/create_count.log"
    echo '[]' >"$scratch/issues/Nishfleet-fleet-ops.json"
    echo '[]' >"$scratch/issues/Nishfleet-0509.json"
    mkdir -p "$scratch/comments"
}

seed_issue_with_signal() {
    local repo="$1" num="$2" key="$3"; shift 3
    local body
    body=$(printf 'signal: %s\n%s' "$key" "$*")
    local f="$scratch/issues/${repo}.json"
    local cur
    cur=$(cat "$f" 2>/dev/null || echo '[]')
    tmp=$(mktemp)
    jq --argjson n "$num" --arg b "$body" \
        '. + [{number:$n, state:"open", body:$b}]' \
        <<<"$cur" >"$tmp"
    mv "$tmp" "$f"
}

export SIGNAL_RECONCILE_TICK_LOG_DIR="$scratch/tick-logs"
export SIGNAL_RECONCILE_STATE="$scratch/state/state.json"
export SIGNAL_RECONCILE_TRIAGE="$scratch/triage.md"
export SIGNAL_RECONCILE_LOCKDIR="$scratch/lock"
export SIGNAL_RECONCILE_NOW="$NOW_ISO"
export SIGNAL_RECONCILE_REPOS=$'Nishfleet/fleet-ops\nNishfleet/0509'
export SIGNAL_RECONCILE_GH="gh"
export GH="gh"
unset SIGNAL_RECONCILE_TICK_LOG
unset SIGNAL_RECONCILE_DRY_RUN
unset SIGNAL_RECONCILE_MAX_PER_TICK

run_reconcile() {
    set +e
    env_out=$("$bin" 2>"$scratch/err.log")
    env_rc=$?
    set -e
    # Touch env_out so shellcheck does not flag it; the value is for humans
    # who want to see the script's summary line ("signal-reconcile active=...")
    # on a failure.
    : "${env_out:=}"
}

created_count() {
    if [ -f "$scratch/create_count.log" ]; then
        wc -l <"$scratch/create_count.log" | tr -d ' '
    else
        echo 0
    fi
}

# ============================================================================
# 1. Active signal with NO open issue -> file new issue
# ============================================================================
reset_world
tick="$scratch/tick-logs/tier1-20260826T163000Z.log"
write_tick_log "$tick" \
    "[fleet-escalation-canary] LOUD [ESCALATION-CANARY-PENDING] signal=escalation-canary/step8/red-check-senior-auditor red-check -> senior-auditor bridge not wired (#152)"

run_reconcile
[[ "$env_rc" == 0 ]] || fail "case1: rc=$env_rc: $(cat "$scratch/err.log")"
n=$(created_count)
[[ "$n" == "1" ]] || fail "case1: expected 1 create, got $n: $(cat "$scratch/creates.log")"
grep -q 'Nishfleet/fleet-ops' "$scratch/creates.log" || fail "case1: filed in wrong repo: $(cat "$scratch/creates.log")"
grep -q 'signal: escalation-canary/step8/red-check-senior-auditor' "$scratch/creates.log" \
    || fail "case1: body missing signal: line"
ok "case1: active signal + no open issue -> filed in fleet-ops with signal: key in body"

# ============================================================================
# 2. Active signal with EXISTING open issue -> touch daily heartbeat comment
# ============================================================================
reset_world
seed_issue_with_signal "Nishfleet-fleet-ops" 99 "escalation-canary/step8/red-check-senior-auditor" "prior body"
write_tick_log "$tick" \
    "[fleet-escalation-canary] LOUD [ESCALATION-CANARY-PENDING] signal=escalation-canary/step8/red-check-senior-auditor red-check bridge not wired"

run_reconcile
[[ "$env_rc" == 0 ]] || fail "case2: rc=$env_rc: $(cat "$scratch/err.log")"
n=$(created_count)
[[ "$n" == "0" ]] || fail "case2: must NOT file when open issue exists (got $n creates)"
[[ -s "$scratch/comments/99.log" ]] || fail "case2: no signal-checked comment posted"
grep -q "signal-checked: 2026-08-26 still-active" "$scratch/comments/99.log" \
    || fail "case2: comment missing signal-checked marker"
ok "case2: active signal + open issue -> daily heartbeat comment posted"

n_before=$(wc -l <"$scratch/comments/99.log")
run_reconcile
[[ "$env_rc" == 0 ]] || fail "case2b: rc=$env_rc"
n_after=$(wc -l <"$scratch/comments/99.log")
[[ "$n_before" == "$n_after" ]] || fail "case2b: idempotent fail: $n_before -> $n_after"
ok "case2b: same-date daily comment is idempotent"

# ============================================================================
# 3. Observe-to-close: open issue + detector green this tick -> close
# ============================================================================
reset_world
seed_issue_with_signal "Nishfleet-fleet-ops" 50 "escalation-canary/step8/red-check-senior-auditor" "prior"
write_tick_log "$tick" \
    "[fleet-escalation-canary] LOUD [ESCALATION-CANARY-OK] two-plane invariant holds: VPS services + pi runners covered; GitHub coverage layers wired; pending=0"

run_reconcile
[[ "$env_rc" == 0 ]] || fail "case3: rc=$env_rc: $(cat "$scratch/err.log")"
grep -q '^50|' "$scratch/closes.log" || fail "case3: did not close #50: $(cat "$scratch/closes.log")"
grep -q 'signal-cleared' "$scratch/comments/50.log" \
    || fail "case3: closing comment missing signal-cleared: $(cat "$scratch/comments/50.log")"
ok "case3: open signal-keyed issue with detector green -> closed with signal-cleared comment"

# ============================================================================
# 4. Per-target-repo routing: unit-failed -> Nishfleet/<short>
# ============================================================================
reset_world
write_tick_log "$tick" \
    "LOUD [LLM-DEAD] unit=pi-issue@0509-42.service provider=devin model=glm-5-2 class=llm-dead excerpt=probe-failed"

run_reconcile
[[ "$env_rc" == 0 ]] || fail "case4: rc=$env_rc: $(cat "$scratch/err.log")"
grep -q 'Nishfleet/0509' "$scratch/creates.log" \
    || fail "case4: unit-failed signal must route to Nishfleet/0509: $(cat "$scratch/creates.log")"
grep -q 'signal: unit-failed/pi-issue@0509-42.service' "$scratch/creates.log" \
    || fail "case4: body missing per-unit signal key: $(cat "$scratch/creates.log")"
ok "case4: unit-failed pi-issue@0509-42.service -> filed in Nishfleet/0509 with per-unit key"

# ============================================================================
# 5. Cap: SIGNAL_RECONCILE_MAX_PER_TICK enforced, with LOUD cap-hit line
# ============================================================================
reset_world
{
    for i in 1 2 3 4 5 6 7; do
        printf '[%s] [fleet-escalation-canary] LOUD [ESCALATION-CANARY-PENDING] signal=escalation-canary/step8/scenario-%s red-check bridge\n' "$NOW_ISO" "$i"
    done
} >"$tick"

export SIGNAL_RECONCILE_MAX_PER_TICK="3"
run_reconcile
[[ "$env_rc" == 0 ]] || fail "case5: rc=$env_rc: $(cat "$scratch/err.log")"
n=$(created_count)
[[ "$n" == "3" ]] || fail "case5: cap=3 must allow exactly 3 creates, got $n"
grep -q 'SIGNAL-RECONCILE-CAP' "$scratch/triage.md" \
    || fail "case5: triage must contain LOUD [SIGNAL-RECONCILE-CAP] line: $(cat "$scratch/triage.md")"
unset SIGNAL_RECONCILE_MAX_PER_TICK
ok "case5: cap enforced, LOUD cap-hit line written, no spam past the cap"

# ============================================================================
# 6. DRY_RUN: prints actions, mutates nothing
# ============================================================================
reset_world
write_tick_log "$tick" \
    "[fleet-escalation-canary] LOUD [ESCALATION-CANARY-PENDING] signal=escalation-canary/step8/red-check-senior-auditor red-check bridge"

export SIGNAL_RECONCILE_DRY_RUN=1
run_reconcile
[[ "$env_rc" == 0 ]] || fail "case6: rc=$env_rc"
n=$(created_count)
[[ "$n" == "0" ]] || fail "case6: DRY must NOT create, got $n creates"
grep -q "DRY file" "$scratch/err.log" || fail "case6: dry-run log missing DRY file marker"
unset SIGNAL_RECONCILE_DRY_RUN
ok "case6: DRY_RUN prints and mutates nothing"

# ============================================================================
# 7. Overlap: a held flock -> second sweep is a no-op
# ============================================================================
reset_world
write_tick_log "$tick" \
    "[fleet-escalation-canary] LOUD [ESCALATION-CANARY-PENDING] signal=escalation-canary/step8/red-check-senior-auditor red-check bridge"

export SIGNAL_RECONCILE_LOCKDIR="$scratch/lock-overlap"
mkdir -p "$SIGNAL_RECONCILE_LOCKDIR"
exec 9>"$SIGNAL_RECONCILE_LOCKDIR/sweep.lock"
flock -n 9 || fail "could not hold overlap lock"
set +e
out=$("$bin" 2>"$scratch/err.log")
ov_rc=$?
set -e
exec 9>&-
[[ "$ov_rc" == 0 ]] || fail "case7: overlap must exit 0, got $ov_rc"
printf '%s\n' "$out" | grep -q 'no-op' || fail "case7: overlap must print no-op, got: $out"
export SIGNAL_RECONCILE_LOCKDIR="$scratch/lock"
ok "case7: overlapping sweep is a no-op"

# ============================================================================
# 8. Tier1 wiring + MANIFEST + worker prompt + canary signal= contract
# ============================================================================
grep -q 'signal-reconcile' "$tier1" || fail "tier1 must reference signal-reconcile"
grep -q 'SIGNAL_RECONCILE_TICK_LOG="$TICK_LOG"' "$tier1" \
    || fail "tier1 must pass SIGNAL_RECONCILE_TICK_LOG to signal-reconcile"
# Canary stderr must land in THIS tick log, otherwise observe-to-close is
# blind (triage is append-only history) and would either never file or
# close everything on a green-looking empty log.
grep -q 'canary_out=' "$tier1" || fail "tier1 must capture canary stdout/stderr into a variable"
grep -q 'printf.*canary_out.*>&3' "$tier1" \
    || fail "tier1 must tee captured canary output into TICK_LOG (fd 3)"
grep -q 'bin/signal-reconcile' "$manifest" \
    || fail "MANIFEST must install bin/signal-reconcile"
grep -q 'Refs #' "$worker_prompt" \
    || fail "worker.md must document the signal-keyed-issue PR contract (Refs #<N>)"
grep -q 'signal-reconcile' "$worker_prompt" \
    || fail "worker.md must reference signal-reconcile by name"
grep -qE 'Closes #<N>|Fixes #<N>|Resolves #<N>' "$worker_prompt" \
    || fail "worker.md must mention Closes/Fixes/Resolves as forbidden for signal-keyed issues"
grep -q 'signal-reconcile' "$heartbeat_prompt" \
    || fail "heartbeat.md must tell the LLM tick not to redo signal-reconcile"
grep -q 'signal=escalation-canary/step8/red-check-senior-auditor' "$canary" \
    || fail "canary PENDING/VIOLATION lines must carry a stable signal= key"
ok "case8: contracts wired (tier1 capture+call, MANIFEST, worker.md, heartbeat.md, canary signal=)"

# ============================================================================
# 9. Tick log fallback: most recent tier1-*.log in TICK_LOG_DIR is used
# ============================================================================
reset_world
older="$scratch/tick-logs/tier1-20260826T100000Z.log"
write_tick_log "$older" \
    "[fleet-escalation-canary] LOUD [ESCALATION-CANARY-PENDING] signal=escalation-canary/step8/red-check-senior-auditor red-check bridge"
newer="$scratch/tick-logs/tier1-20260826T163000Z.log"
write_tick_log "$newer" \
    "[fleet-escalation-canary] LOUD [ESCALATION-CANARY-OK] two-plane invariant holds: pending=0"

unset SIGNAL_RECONCILE_TICK_LOG
run_reconcile
[[ "$env_rc" == 0 ]] || fail "case9: rc=$env_rc"
n=$(created_count)
[[ "$n" == "0" ]] || fail "case9: must pick the newer tick log (no pending) -> 0 files, got $n"
ok "case9: latest tier1 tick log wins (newer OK -> no auto-file)"

# ============================================================================
# 10. Canary did not run this tick -> do NOT close canary-keyed issues
# ============================================================================
reset_world
seed_issue_with_signal "Nishfleet-fleet-ops" 77 "escalation-canary/step8/red-check-senior-auditor" "prior"
write_tick_log "$tick" \
    "[fleet-heartbeat-tier1] 14. escalation-coverage canary missing — skip"

run_reconcile
[[ "$env_rc" == 0 ]] || fail "case10: rc=$env_rc: $(cat "$scratch/err.log")"
[[ ! -s "$scratch/closes.log" ]] || fail "case10: must NOT close when canary did not run: $(cat "$scratch/closes.log")"
ok "case10: canary skipped this tick -> canary-keyed issue stays open"

# ============================================================================
# 11. Live --state=failed unit with no tick-log loud line still files
#     (the §4 already_in_triage hole: later ticks stop re-louding)
# ============================================================================
reset_world
write_tick_log "$tick" \
    "[fleet-escalation-canary] LOUD [ESCALATION-CANARY-OK] two-plane invariant holds: pending=0"
printf '%s\n' "pi-issue@0509-7.service" >"$scratch/failed-units"

run_reconcile
[[ "$env_rc" == 0 ]] || fail "case11: rc=$env_rc: $(cat "$scratch/err.log")"
grep -q 'Nishfleet/0509' "$scratch/creates.log" \
    || fail "case11: live failed unit must file even without a tick-log loud line: $(cat "$scratch/creates.log")"
grep -q 'signal: unit-failed/pi-issue@0509-7.service' "$scratch/creates.log" \
    || fail "case11: body missing per-unit signal key: $(cat "$scratch/creates.log")"
ok "case11: live --state=failed unit with no tick-log loud line still files"

echo "all signal-reconcile cases passed"
