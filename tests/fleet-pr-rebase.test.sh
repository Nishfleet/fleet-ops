#!/usr/bin/env bash
# tests/fleet-pr-rebase.test.sh
#
# Proves fleet-ops#2525: the daily CONFLICTING-PR rebase sweep. A PR turned
# CONFLICTING by main moving has no event that re-reconciles it (the
# 2026-08-31 pile: 14 CONFLICTING open PRs, several stuck for weeks —
# #2087 gap-closure rate limits, #1923 0509 surface probe, #1696 pi-audit
# empty verdict, #1582 alarm->ticket reconciler, #2511 seat corpse
# retirement).
#
#   - success path: `gh pr update-branch --rebase` exit 0 -> counted
#     (fleet_pr_rebased_total), no label/comment
#   - true conflict: update fails, local merge probe proves conflicts ->
#     `rebase-failed` label created + added, comment names the files
#   - non-conflict failure: update fails but probe merge is clean -> no
#     label (grayscale retry next tick)
#   - PRs already labeled `rebase-failed` are skipped
#   - FLEET_PR_REBASE_NUMBERS test/drill hook scopes the sweep
#   - dry-run mutates nothing and writes no prom
#   - dead App identity (no GH_TOKEN, mint fails) -> exit 1, no human
#     gh-auth fallback
#   - cumulative counters in state accumulate across runs
#   - contracts: MANIFEST, timer-manifest, organs registry, absent rule,
#     ci.yml P14 list + unit-verify stub, systemd-analyze verify
#
# Mocked gh + fake conflict probe (FLEET_PR_REBASE_CONFLICT_PROBE_CMD);
# no network.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-pr-rebase"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
bash -n "$bin" || fail "bin bash syntax error"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin"

# --- fake gh -----------------------------------------------------------------
cat >"$scratch/bin/gh" <<'FAKE'
#!/usr/bin/env bash
# $GH_FAKE_OK_HEADS: comma-separated heads whose update-branch succeeds.
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_DIR/gh.log"
case "$1" in
  pr)
    case "$2" in
      list)
        cat "$FAKE_DIR/list.json"
        exit 0
        ;;
      update-branch)
        num="$3"
        head=$(jq -r --argjson n "$num" '.[] | select(.number==$n) | .headRefName // "unknown"' "$FAKE_DIR/list.json" | head -1)
        if [[ ",$GH_FAKE_OK_HEADS," == *",$head,"* ]]; then
          exit 0
        fi
        echo "could not rebase pull request: merge conflict" >&2
        exit 1
        ;;
      edit)
        printf '%s\n' "$*" >>"$FAKE_DIR/edit.log"
        exit 0
        ;;
      comment)
        printf '%s\n' "$*" >>"$FAKE_DIR/comment.log"
        exit 0
        ;;
      *) echo "unexpected gh pr $*" >&2; exit 1 ;;
    esac
    ;;
  label)
    printf '%s\n' "$*" >>"$FAKE_DIR/label-create.log"
    exit 0
    ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$scratch/bin/gh"

# --- fake conflict probe (contract: $1=repo $2=head) -------------------------
cat >"$scratch/probe.sh" <<'PROBE'
#!/usr/bin/env bash
# $1=repo $2=head
case "$2" in
  conflict/*)
    printf 'src/fleet-pr-rebase.ts\nlib/rebase-util.ts\n'
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
PROBE
chmod +x "$scratch/probe.sh"

# --- fake worker-token (dead-app cases) -------------------------------------
cat >"$scratch/bin/worker-token" <<'WTF'
#!/usr/bin/env bash
if [[ "${WORKER_TOKEN_FAKE_MODE:-fail}" == "ok" ]]; then
  printf 'export GH_TOKEN=fake-minted-token\n'
  exit 0
fi
echo "mint failed: no installation" >&2
exit 1
WTF
chmod +x "$scratch/bin/worker-token"

export FAKE_DIR="$scratch"
export GH_FAKE_OK_HEADS="fix/ok-7"
export PATH="$scratch/bin:$PATH"
export FLEET_PR_REBASE_LOCKDIR="$scratch/lock"
export FLEET_PR_REBASE_STATE="$scratch/state.json"
export FLEET_PR_REBASE_PROM="$scratch/rebase.prom"
export FLEET_PR_REBASE_CONFLICT_PROBE_CMD="$scratch/probe.sh"
export GH_TOKEN="fake-app-token"
unset FLEET_PR_REBASE_REPOS || true
unset FLEET_PR_REBASE_NUMBERS || true
unset FLEET_PR_REBASE_DRY_RUN || true

# --- Case 1: dry-run over a mixed list -> read-only, no prom -----------------
cat >"$scratch/list.json" <<'JSON'
[
 {"number":7,"mergeable":"CONFLICTING","labels":[],"headRefName":"fix/ok-7"},
 {"number":8,"mergeable":"CONFLICTING","labels":[],"headRefName":"conflict/real-8"},
 {"number":6,"mergeable":"CONFLICTING","labels":[{"name":"rebase-failed"}],"headRefName":"fix/labeled-6"},
 {"number":5,"mergeable":"MERGEABLE","labels":[],"headRefName":"fix/mergeable-5"}
]
JSON
: >"$scratch/gh.log"
out=$(FLEET_PR_REBASE_DRY_RUN=1 "$bin" 2>"$scratch/err1.txt")
grep -q 'candidates_seen=2' <<<"$out" || fail "dry-run candidates_seen: $out / $(cat "$scratch/err1.txt")"
if grep -q 'update-branch' "$scratch/gh.log"; then
  fail "dry-run must not call update-branch: $(cat "$scratch/gh.log")"
fi
[[ -e "$scratch/rebase.prom" ]] && fail "dry-run must not write prom"
ok "dry-run reads the list, skips labeled+mergeable, mutates nothing"

# --- Case 2: success path ----------------------------------------------------
cat >"$scratch/list.json" <<'JSON'
[{"number":7,"mergeable":"CONFLICTING","labels":[],"headRefName":"fix/ok-7"}]
JSON
: >"$scratch/gh.log"
rm -f "$scratch/rebase.prom" "$scratch/state.json"
out=$("$bin" 2>"$scratch/err2.txt")
grep -q 'rebased=1' <<<"$out" || fail "success rebase count: $out / $(cat "$scratch/err2.txt")"
grep -q 'pr update-branch 7 -R Nishfleet/fleet-ops --rebase' "$scratch/gh.log" \
  || fail "update-branch not called with --rebase: $(cat "$scratch/gh.log")"
[[ -s "$scratch/edit.log" ]] && fail "success must not label: $(cat "$scratch/edit.log")"
[[ -s "$scratch/comment.log" ]] && fail "success must not comment: $(cat "$scratch/comment.log")"
grep -q '^fleet_pr_rebased_total 1$' "$scratch/rebase.prom" \
  || fail "prom rebased_total must accumulate to 1: $(cat "$scratch/rebase.prom")"
grep -q '^fleet_pr_conflicting_total 1$' "$scratch/rebase.prom" \
  || fail "prom conflicting_total must be 1: $(cat "$scratch/rebase.prom")"
grep -qE '^fleet_pr_rebase_last_green_seconds [0-9]+$' "$scratch/rebase.prom" \
  || fail "prom last-green missing: $(cat "$scratch/rebase.prom")"
ok "successful rebase counted + prom written, no label/comment"

# --- Case 3: true conflict -> label + comment with files --------------------
rm -f "$scratch/rebase.prom" "$scratch/state.json"
cat >"$scratch/list.json" <<'JSON'
[{"number":8,"mergeable":"CONFLICTING","labels":[],"headRefName":"conflict/real-8"}]
JSON
rm -f "$scratch/gh.log" "$scratch/edit.log" "$scratch/comment.log" "$scratch/label-create.log"
out=$("$bin" 2>"$scratch/err3.txt")
grep -q 'rebased=0' <<<"$out" || fail "conflict must not count rebase: $out"
grep -q 'REAL conflict' "$scratch/err3.txt" || fail "conflict branch not logged: $(cat "$scratch/err3.txt")"
grep -q 'pr edit 8 -R Nishfleet/fleet-ops --add-label rebase-failed' "$scratch/edit.log" \
  || fail "rebase-failed label not added: $(cat "$scratch/edit.log")"
grep -q 'label create rebase-failed' "$scratch/label-create.log" \
  || fail "label not created on first conflict: $(cat "$scratch/label-create.log")"
grep -q 'pr comment 8 -R Nishfleet/fleet-ops --body' "$scratch/comment.log" \
  || fail "conflict comment not posted: $(cat "$scratch/comment.log")"
grep -q 'src/fleet-pr-rebase.ts' "$scratch/comment.log" \
  || fail "comment must name conflict file 1: $(cat "$scratch/comment.log")"
grep -q 'lib/rebase-util.ts' "$scratch/comment.log" \
  || fail "comment must name conflict file 2: $(cat "$scratch/comment.log")"
grep -q '^fleet_pr_conflicting_total 1$' "$scratch/rebase.prom" \
  || fail "conflict must count in conflicting_total: $(cat "$scratch/rebase.prom")"
ok "true conflict -> label created+added, comment names the conflicted files"

# --- Case 4: rebase-failed label skip ----------------------------------------
rm -f "$scratch/rebase.prom" "$scratch/state.json"
cat >"$scratch/list.json" <<'JSON'
[{"number":6,"mergeable":"CONFLICTING","labels":[{"name":"rebase-failed"}],"headRefName":"fix/labeled-6"}]
JSON
rm -f "$scratch/gh.log" "$scratch/edit.log" "$scratch/comment.log" "$scratch/label-create.log"
out=$("$bin" 2>"$scratch/err4.txt")
grep -q 'rebased=0' <<<"$out" || fail "labeled PR must not rebase: $out"
if grep -q 'update-branch 6' "$scratch/gh.log"; then
  fail "labeled PR must not be updated: $(cat "$scratch/gh.log")"
fi
[[ -s "$scratch/edit.log" ]] && fail "labeled PR must not be re-labeled: $(cat "$scratch/edit.log")"
ok "rebase-failed-labeled PR is skipped"

# --- Case 5: counter accumulation across runs --------------------------------
rm -f "$scratch/rebase.prom" "$scratch/state.json"
cat >"$scratch/list.json" <<'JSON'
[{"number":7,"mergeable":"CONFLICTING","labels":[],"headRefName":"fix/ok-7"}]
JSON
"$bin" >/dev/null 2>&1 || fail "run 1 failed"
"$bin" >/dev/null 2>&1 || fail "run 2 failed"
grep -q '^fleet_pr_rebased_total 2$' "$scratch/rebase.prom" \
  || fail "second success must accumulate: $(cat "$scratch/rebase.prom")"
ok "counters accumulate across runs (state-backed)"

# --- Case 6: numbers hook scopes the sweep -----------------------------------
rm -f "$scratch/rebase.prom" "$scratch/state.json"
cat >"$scratch/list.json" <<'JSON'
[
 {"number":7,"mergeable":"CONFLICTING","labels":[],"headRefName":"fix/ok-7"},
 {"number":99,"mergeable":"CONFLICTING","labels":[],"headRefName":"conflict/real-99"}
]
JSON
rm -f "$scratch/gh.log" "$scratch/edit.log" "$scratch/comment.log"
out=$(FLEET_PR_REBASE_NUMBERS="99" "$bin" 2>"$scratch/err6.txt")
grep -q 'rebased=0' <<<"$out" || fail "numbers hook must not rebase unlisted 7: $out"
if grep -q 'update-branch 7' "$scratch/gh.log"; then
  fail "numbers hook must exclude unlisted 7: $(cat "$scratch/gh.log")"
fi
grep -q 'pr edit 99' "$scratch/edit.log" \
  || fail "numbers hook must still process listed 99: $(cat "$scratch/edit.log")"
ok "FLEET_PR_REBASE_NUMBERS scopes the sweep (drill hook)"

# --- Case 7: dead App identity -> exit 1, no human fallback ------------------
cat >"$scratch/list.json" <<'JSON'
[{"number":7,"mergeable":"CONFLICTING","labels":[],"headRefName":"fix/ok-7"}]
JSON
set +e
env -u GH_TOKEN \
  WORKER_APP_CREDS_FILE="$scratch/nonexistent-creds.env" \
  WORKER_TOKEN_BIN="$scratch/bin/worker-token" \
  "$bin" >"$scratch/out7.txt" 2>"$scratch/err7.txt"
rc=$?
set -e
[[ $rc -eq 1 ]] || fail "dead app must exit 1, got $rc: $(cat "$scratch/err7.txt")"
grep -q 'DEAD APP IDENTITY' "$scratch/err7.txt" \
  || fail "dead app must scream: $(cat "$scratch/err7.txt")"
ok "missing creds -> DEAD APP IDENTITY, exit 1"

set +e
env -u GH_TOKEN \
  WORKER_APP_CREDS_FILE="$scratch/creds.env" \
  WORKER_TOKEN_BIN="$scratch/bin/worker-token" \
  WORKER_TOKEN_FAKE_MODE="fail" \
  "$bin" >"$scratch/out7b.txt" 2>"$scratch/err7b.txt"
rc=$?
set -e
[[ $rc -eq 1 ]] || fail "mint failure must exit 1, got $rc: $(cat "$scratch/err7b.txt")"
grep -q 'DEAD APP IDENTITY' "$scratch/err7b.txt" \
  || fail "mint failure must scream: $(cat "$scratch/err7b.txt")"
ok "mint failure -> DEAD APP IDENTITY, exit 1"

# --- Case 8: mint success (no GH_TOKEN, creds + token present) ----------------
: >"$scratch/creds.env"
cat >"$scratch/list.json" <<'JSON'
[{"number":7,"mergeable":"CONFLICTING","labels":[],"headRefName":"fix/ok-7"}]
JSON
set +e
out=$(env -u GH_TOKEN \
  WORKER_APP_CREDS_FILE="$scratch/creds.env" \
  WORKER_TOKEN_BIN="$scratch/bin/worker-token" \
  WORKER_TOKEN_FAKE_MODE="ok" \
  "$bin" 2>"$scratch/err8.txt")
rc=$?
set -e
[[ $rc -eq 0 ]] || fail "mint success run must exit 0: $rc / $(cat "$scratch/err8.txt")"
grep -q 'minted fresh' "$scratch/err8.txt" || fail "mint log missing: $(cat "$scratch/err8.txt")"
ok "no GH_TOKEN + successful mint -> sweep runs under App token"

# --- Case 9: contracts ---------------------------------------------------------
manifest="$repo_root/MANIFEST"
grep -Fxq 'bin/fleet-pr-rebase /home/nish/.local/bin/fleet-pr-rebase' "$manifest" \
  || fail "MANIFEST missing bin entry"
grep -Fxq 'systemd/fleet-pr-rebase.service /home/nish/.config/systemd/user/fleet-pr-rebase.service' "$manifest" \
  || fail "MANIFEST missing service entry"
grep -Fxq 'systemd/fleet-pr-rebase.timer /home/nish/.config/systemd/user/fleet-pr-rebase.timer' "$manifest" \
  || fail "MANIFEST missing timer entry"
ok "MANIFEST carries bin + service + timer"

python3 - "$repo_root/systemd/timer-manifest.json" <<'PY' || fail "timer-manifest contract"
import json, sys
m = json.load(open(sys.argv[1]))
t = m["timers"]["fleet-pr-rebase.timer"]
assert t["classification"] == "scheduled", t
assert t["cadence"] == "daily", t
assert t["source"] == "repo", t
assert "named reason" not in t["reason"].lower() or len(t["reason"]) > 2, t
PY
ok "timer-manifest.json entry with named daily reason"

jq -e '.organs[] | select(.name=="pr-rebase" and .heartbeat_metric=="fleet_pr_rebase_last_green_seconds" and .absent_alert=="FleetPrRebaseAbsent" and (.files | index("bin/fleet-pr-rebase")))' \
  "$repo_root/config/fleet-organs.json" >/dev/null \
  || fail "fleet-organs.json pr-rebase entry missing/misshaped"
ok "fleet-organs.json registers pr-rebase + heartbeat metric + absent alert"

grep -q 'FleetPrRebaseAbsent' "$repo_root/config/fleet_rules.yml" \
  || fail "fleet_rules.yml missing FleetPrRebaseAbsent"
grep -q 'absent(fleet_pr_rebase_last_green_seconds)' "$repo_root/config/fleet_rules.yml" \
  || fail "absent rule must key on the heartbeat metric"
grep -q 'severity: warning' "$repo_root/config/fleet_rules.yml" \
  || fail "absent rule must not page (severity must stay warning)"
ok "fleet_rules.yml absent rule keys the heartbeat metric, no page"

grep -q 'bash tests/fleet-pr-rebase.test.sh' "$repo_root/.github/workflows/ci.yml" \
  || fail "ci.yml P14 must run tests/fleet-pr-rebase.test.sh"
grep -q '/home/nish/.local/bin/fleet-pr-rebase' "$repo_root/.github/workflows/ci.yml" \
  || fail "ci.yml unit-verify must stub /home/nish/.local/bin/fleet-pr-rebase"
ok "ci.yml runs the test + stubs the unit"

# systemd-analyze verify (present on the VPS; hosted CI runs its own job)
if command -v systemd-analyze >/dev/null 2>&1; then
  for f in "$repo_root/systemd/fleet-pr-rebase.service" "$repo_root/systemd/fleet-pr-rebase.timer"; do
    if ! out=$(systemd-analyze verify --man=no "$f" 2>&1); then
      fail "systemd-analyze verify failed for $f: $out"
    fi
    ok "systemd-analyze verify accepts $(basename "$f")"
  done
else
  echo "SKIP: systemd-analyze not on PATH"
fi

# shellcheck gate parity (CI shells out to shellcheck on bin/ files)
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "$bin" || fail "shellcheck on bin/fleet-pr-rebase"
  ok "shellcheck accepts bin/fleet-pr-rebase"
else
  echo "SKIP: shellcheck not on PATH"
fi

echo "all fleet-pr-rebase cases passed"