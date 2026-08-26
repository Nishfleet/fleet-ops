#!/usr/bin/env bash
# tests/fleet-nothing-half-done.test.sh
#
# fleet-ops#528: worktree/PR orphan canary + QUESTIONS.md nag.
# Offline. Live gh/hermes/systemctl are stubbed. Proves:
#   1. Clean idle worktree on main -> exit 0, NOTHING-HALF-DONE-OK.
#   2. Dirty idle worktree, no live unit -> exit 1, HALF-DONE-worktree.
#   3. Dirty but recent mtime -> exit 0.
#   4. Dirty idle with a matching live unit -> exit 0.
#   5. Unpushed feature-branch idle -> exit 1.
#   6. Green unmerged PR >24h, auto-merge off -> exit 1.
#   7. Draft / already auto-merging / young PR -> exit 0.
#   8. OPEN question with no nag -> QUESTION-NAG, telegram stub succeeds.
#   9. OPEN question already naged inside the window -> exit 0.
#  10. HOLD until tomorrow skipped; expired HOLD nags.
#  11. Auto-file with signal key, deduped on a second run (exit 0).
#  12. Missing helper fails loud.
#  13. Contracts: heartbeat wiring, MANIFEST, nested CI host.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-nothing-half-done"
lib="$repo_root/lib/nothing-half-done.py"
tier1="$repo_root/bin/fleet-heartbeat-tier1"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || { chmod +x "$bin" 2>/dev/null || true; }
[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"
command -v git >/dev/null 2>&1 || fail "git missing"

scratch="$(mktemp -d -t nothing-half-done.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

trees="$scratch/worktrees"
mkdir -p "$trees" "$scratch/gh-issues" "$scratch/bin"
: >"$scratch/live-units.txt"
: >"$scratch/prs.json"
printf '[]' >"$scratch/prs.json"
printf '%s\n' '# QUESTIONS' >"$scratch/QUESTIONS.md"
printf '%s\n' '| Asked | Question | Asked-by | Status |' >>"$scratch/QUESTIONS.md"
printf '%s\n' '|---|---|---|---|' >>"$scratch/QUESTIONS.md"

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
            --repo|-R) shift 2 ;;
            *) shift ;;
          esac
        done
        n=$(find "$store" -maxdepth 1 -name 'issue-*.body' | wc -l)
        f="$store/issue-$((n+1)).body"
        printf '%s\n' "$title" > "$f"
        printf '%s\n' "$body" >> "$f"
        echo "https://github.com/Nishfleet/fleet-ops/issues/9999"
        ;;
      list)
        printf '[\n'
        first=1
        n=0
        for f in "$store"/*.body; do
          [ -f "$f" ] || continue
          n=$((n+1))
          body=$(tail -n +2 "$f")
          if [ "$first" = 1 ]; then first=0; else printf ',\n'; fi
          printf '{"number":%s,"title":"","body":%s}' "$n" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$body")"
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

cat >"$scratch/hermes" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
echo "hermes-ok $*" >> "${HERMES_LOG:?}"
exit 0
FAKE
chmod +x "$scratch/hermes"

cat >"$scratch/hermes-fail" <<'FAKE'
#!/usr/bin/env bash
exit 1
FAKE
chmod +x "$scratch/hermes-fail"

cat >"$scratch/notify-fail" <<'FAKE'
#!/usr/bin/env bash
exit 1
FAKE
chmod +x "$scratch/notify-fail"

make_repo() {
  local dest="$1"
  local branch="${2:-main}"
  mkdir -p "$dest"
  git -C "$dest" init -b "$branch" >/dev/null 2>&1
  git -C "$dest" config user.email "worker@example.test"
  git -C "$dest" config user.name "worker"
  printf 'ok\n' >"$dest/README"
  git -C "$dest" add README
  git -C "$dest" commit -m "init" >/dev/null
}

stamp_idle() {
  local dest="$1"
  find "$dest" -not -path '*/.git/*' -exec touch -d "2026-08-25T00:00:00Z" {} +
  touch -d "2026-08-25T00:00:00Z" "$dest"
}

run_bin() {
  local file_issues="${1:-0}"
  set +e
  FLEET_NOTHING_HALF_DONE_WORKTREES="$trees" \
  FLEET_NOTHING_HALF_DONE_LIB="$lib" \
  FLEET_NOTHING_HALF_DONE_QUESTIONS="$scratch/QUESTIONS.md" \
  FLEET_NOTHING_HALF_DONE_NAG_STATE="$scratch/nag.json" \
  FLEET_NOTHING_HALF_DONE_LIVE_UNITS="$scratch/live-units.txt" \
  FLEET_NOTHING_HALF_DONE_PRS_FILE="$scratch/prs.json" \
  FLEET_NOTHING_HALF_DONE_IDLE_HOURS="24" \
  FLEET_NOTHING_HALF_DONE_NAG_HOURS="24" \
  FLEET_NOTHING_HALF_DONE_NOW="2026-08-27T00:10:00Z" \
  FLEET_NOTHING_HALF_DONE_FILE_ISSUES="$file_issues" \
  FLEET_NOTHING_HALF_DONE_ISSUE_REPO="Nishfleet/fleet-ops" \
  FLEET_NOTHING_HALF_DONE_SCAN_PRS=1 \
  GH="$scratch/gh" \
  GH_MOCK_STORE="$scratch/gh-issues" \
  HERMES="$scratch/hermes" \
  HERMES_LOG="$scratch/hermes.log" \
  NOTIFY_EMAIL="$scratch/notify-fail" \
  FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
    "$bin" >/dev/null 2>"$scratch/err.log"
  local rc=$?
  set -e
  echo "$rc"
}

# --- 1. clean idle on main --------------------------------------------------
make_repo "$trees/clean-main" main
stamp_idle "$trees/clean-main"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "clean idle main should exit 0 (got $rc) $(cat "$scratch/err.log")"
grep -q "NOTHING-HALF-DONE-OK" "$scratch/err.log" || fail "clean missing OK line"
ok "clean idle main exits 0"
rm -rf "$trees/clean-main"

# --- 2. dirty idle, no live unit --------------------------------------------
make_repo "$trees/issue-fleet-ops-1" main
printf 'dirty\n' >>"$trees/issue-fleet-ops-1/README"
stamp_idle "$trees/issue-fleet-ops-1"
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "dirty idle should exit 1 (got $rc) $(cat "$scratch/err.log")"
grep -q "HALF-DONE-worktree" "$scratch/err.log" || fail "missing HALF-DONE-worktree loud line"
ok "dirty idle worktree is flagged"
rm -rf "$trees/issue-fleet-ops-1"

# --- 3. dirty but recent ----------------------------------------------------
make_repo "$trees/issue-fleet-ops-2" main
printf 'dirty\n' >>"$trees/issue-fleet-ops-2/README"
touch -d "2026-08-27T00:00:00Z" "$trees/issue-fleet-ops-2/README"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "recent dirty should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "recent dirty worktree is ignored"
rm -rf "$trees/issue-fleet-ops-2"

# --- 4. dirty idle held by a live unit --------------------------------------
make_repo "$trees/issue-fleet-ops-528" main
printf 'dirty\n' >>"$trees/issue-fleet-ops-528/README"
stamp_idle "$trees/issue-fleet-ops-528"
printf '%s\n' 'pi-issue@fleet-ops-528.service' >"$scratch/live-units.txt"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "live unit should skip (got $rc) $(cat "$scratch/err.log")"
ok "live unit holds the dirty worktree"
: >"$scratch/live-units.txt"
rm -rf "$trees/issue-fleet-ops-528"

# --- 5. unpushed feature branch idle ----------------------------------------
make_repo "$trees/issue-fleet-ops-3" "claim/issue-3"
stamp_idle "$trees/issue-fleet-ops-3"
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "unpushed idle should exit 1 (got $rc) $(cat "$scratch/err.log")"
grep -q "unpushed" "$scratch/err.log" || fail "missing unpushed reason $(cat "$scratch/err.log")"
ok "unpushed idle feature branch is flagged"
rm -rf "$trees/issue-fleet-ops-3"

# --- 6. green unmerged PR ---------------------------------------------------
cat >"$scratch/prs.json" <<'JSON'
[{"number":42,"title":"land me","url":"https://github.com/Nishfleet/fleet-ops/pull/42","createdAt":"2026-08-25T00:00:00Z","isDraft":false,"mergeable":"MERGEABLE","autoMergeRequest":null,"repository":"Nishfleet/fleet-ops"}]
JSON
rc=$(run_bin 0)
[[ "$rc" == "1" ]] || fail "green unmerged PR should exit 1 (got $rc) $(cat "$scratch/err.log")"
grep -q "HALF-DONE-pr" "$scratch/err.log" || fail "missing HALF-DONE-pr"
ok "green unmerged PR without auto-merge is flagged"
printf '[]' >"$scratch/prs.json"

# --- 7. draft / auto-merging / young PR -------------------------------------
cat >"$scratch/prs.json" <<'JSON'
[
  {"number":1,"title":"draft","url":"u","createdAt":"2026-08-20T00:00:00Z","isDraft":true,"mergeable":"MERGEABLE","autoMergeRequest":null,"repository":"Nishfleet/fleet-ops"},
  {"number":2,"title":"armed","url":"u","createdAt":"2026-08-20T00:00:00Z","isDraft":false,"mergeable":"MERGEABLE","autoMergeRequest":{"enabledAt":"x"},"repository":"Nishfleet/fleet-ops"},
  {"number":3,"title":"young","url":"u","createdAt":"2026-08-27T00:00:00Z","isDraft":false,"mergeable":"MERGEABLE","autoMergeRequest":null,"repository":"Nishfleet/fleet-ops"},
  {"number":4,"title":"red","url":"u","createdAt":"2026-08-20T00:00:00Z","isDraft":false,"mergeable":"CONFLICTING","autoMergeRequest":null,"repository":"Nishfleet/fleet-ops"}
]
JSON
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "non-orphan PRs should exit 0 (got $rc) $(cat "$scratch/err.log")"
ok "draft, armed, young, and conflicting PRs are ignored"
printf '[]' >"$scratch/prs.json"

# --- 8. OPEN question nags via telegram -------------------------------------
: >"$scratch/hermes.log"
printf '%s\n' '| 2026-08-20 | Create the token | worker | OPEN |' >>"$scratch/QUESTIONS.md"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "successful nag should exit 0 (got $rc) $(cat "$scratch/err.log")"
grep -q "QUESTION-NAG" "$scratch/err.log" || fail "missing QUESTION-NAG"
grep -q "hermes-ok" "$scratch/hermes.log" || fail "telegram stub was not called"
ok "OPEN question is naged over telegram"
# Strip the OPEN row for later cases that rebuild the ledger.
printf '%s\n' '# QUESTIONS' >"$scratch/QUESTIONS.md"
printf '%s\n' '| Asked | Question | Asked-by | Status |' >>"$scratch/QUESTIONS.md"
printf '%s\n' '|---|---|---|---|' >>"$scratch/QUESTIONS.md"

# --- 9. already naged inside the window -------------------------------------
printf '%s\n' '| 2026-08-20 | Create the token | worker | OPEN |' >>"$scratch/QUESTIONS.md"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "recent nag should exit 0 (got $rc) $(cat "$scratch/err.log")"
if grep -q "QUESTION-NAG" "$scratch/err.log"; then
  fail "recent nag should not re-ask $(cat "$scratch/err.log")"
fi
ok "question already naged in-window is skipped"
printf '%s\n' '# QUESTIONS' >"$scratch/QUESTIONS.md"
printf '%s\n' '| Asked | Question | Asked-by | Status |' >>"$scratch/QUESTIONS.md"
printf '%s\n' '|---|---|---|---|' >>"$scratch/QUESTIONS.md"
rm -f "$scratch/nag.json"

# --- 10. HOLD until tomorrow skipped; expired HOLD nags ---------------------
printf '%s\n' '| 2026-08-20 | Future hold | worker | HOLD until=2026-08-28 |' >>"$scratch/QUESTIONS.md"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "future HOLD should exit 0 (got $rc) $(cat "$scratch/err.log")"
if grep -q "QUESTION-NAG" "$scratch/err.log"; then
  fail "future HOLD must not nag"
fi
ok "HOLD until tomorrow is skipped"
printf '%s\n' '| 2026-08-20 | Expired hold | worker | HOLD until=2026-08-26 |' >>"$scratch/QUESTIONS.md"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "expired HOLD nag should exit 0 (got $rc) $(cat "$scratch/err.log")"
grep -q "QUESTION-NAG" "$scratch/err.log" || fail "expired HOLD must nag"
ok "expired HOLD is naged"
printf '%s\n' '# QUESTIONS' >"$scratch/QUESTIONS.md"
printf '%s\n' '| Asked | Question | Asked-by | Status |' >>"$scratch/QUESTIONS.md"
printf '%s\n' '|---|---|---|---|' >>"$scratch/QUESTIONS.md"
rm -f "$scratch/nag.json"

# --- 11. auto-file + dedupe -------------------------------------------------
make_repo "$trees/issue-fleet-ops-9" main
printf 'dirty\n' >>"$trees/issue-fleet-ops-9/README"
stamp_idle "$trees/issue-fleet-ops-9"
set +e
FLEET_NOTHING_HALF_DONE_WORKTREES="$trees" \
FLEET_NOTHING_HALF_DONE_LIB="$lib" \
FLEET_NOTHING_HALF_DONE_QUESTIONS="$scratch/QUESTIONS.md" \
FLEET_NOTHING_HALF_DONE_NAG_STATE="$scratch/nag.json" \
FLEET_NOTHING_HALF_DONE_LIVE_UNITS="$scratch/live-units.txt" \
FLEET_NOTHING_HALF_DONE_PRS_FILE="$scratch/prs.json" \
FLEET_NOTHING_HALF_DONE_IDLE_HOURS="24" \
FLEET_NOTHING_HALF_DONE_NOW="2026-08-27T00:10:00Z" \
FLEET_NOTHING_HALF_DONE_FILE_ISSUES=1 \
FLEET_NOTHING_HALF_DONE_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$scratch/gh-issues" \
HERMES="$scratch/hermes" \
HERMES_LOG="$scratch/hermes.log" \
NOTIFY_EMAIL="$scratch/notify-fail" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err2.log"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "first auto-file run should exit 0 after filing (got $rc) $(cat "$scratch/err2.log")"
grep -q "FILED" "$scratch/err2.log" || { cat "$scratch/err2.log"; fail "auto-file did not file an issue"; }
grep -rq "signal: nothing-half-done/" "$scratch/gh-issues" || fail "filed issue body missing signal key"
ok "auto-file creates an issue with the signal key"

set +e
FLEET_NOTHING_HALF_DONE_WORKTREES="$trees" \
FLEET_NOTHING_HALF_DONE_LIB="$lib" \
FLEET_NOTHING_HALF_DONE_QUESTIONS="$scratch/QUESTIONS.md" \
FLEET_NOTHING_HALF_DONE_NAG_STATE="$scratch/nag.json" \
FLEET_NOTHING_HALF_DONE_LIVE_UNITS="$scratch/live-units.txt" \
FLEET_NOTHING_HALF_DONE_PRS_FILE="$scratch/prs.json" \
FLEET_NOTHING_HALF_DONE_IDLE_HOURS="24" \
FLEET_NOTHING_HALF_DONE_NOW="2026-08-27T00:10:00Z" \
FLEET_NOTHING_HALF_DONE_FILE_ISSUES=1 \
FLEET_NOTHING_HALF_DONE_ISSUE_REPO="Nishfleet/fleet-ops" \
GH="$scratch/gh" \
GH_MOCK_STORE="$scratch/gh-issues" \
HERMES="$scratch/hermes" \
HERMES_LOG="$scratch/hermes.log" \
NOTIFY_EMAIL="$scratch/notify-fail" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err3.log"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "deduped run should exit 0 (got $rc) $(cat "$scratch/err3.log")"
grep -q "deduped" "$scratch/err3.log" || fail "second run did not dedupe $(cat "$scratch/err3.log")"
grep -rl "signal: nothing-half-done/" "$scratch/gh-issues" | wc -l | grep -q "^1$" \
  || fail "signal key filed more than once (dedupe broken)"
ok "auto-file dedupes and the next tick stays green"
rm -rf "$trees/issue-fleet-ops-9"

# --- 12. missing helper fails loud ------------------------------------------
set +e
FLEET_NOTHING_HALF_DONE_LIB="$scratch/no-such.py" \
FLEET_NOTHING_HALF_DONE_FILE_ISSUES=0 \
FLEET_NOTHING_HALF_DONE_WORKTREES="$trees" \
FLEET_NOTHING_HALF_DONE_QUESTIONS="$scratch/QUESTIONS.md" \
FLEET_NOTHING_HALF_DONE_LIVE_UNITS="$scratch/live-units.txt" \
FLEET_NOTHING_HALF_DONE_PRS_FILE="$scratch/prs.json" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err4.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "missing helper should exit 1 (got $rc)"
grep -q "NOTHING-HALF-DONE-BROKEN" "$scratch/err4.log" || fail "missing helper must be LOUD"
ok "missing helper fails loud"

# --- 13. contracts ----------------------------------------------------------
grep -q 'fleet-nothing-half-done' "$tier1" \
  || fail "fleet-heartbeat-tier1 must invoke fleet-nothing-half-done"
grep -q 'nothing_half_done_rc' "$tier1" \
  || fail "fleet-heartbeat-tier1 must propagate nothing_half_done_rc"
grep -q 'bin/fleet-nothing-half-done' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/fleet-nothing-half-done"
grep -q 'lib/nothing-half-done.py' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install lib/nothing-half-done.py"
grep -Fq 'bash "$here/fleet-nothing-half-done.test.sh"' "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "contracts: heartbeat-tier1, MANIFEST, nested CI host"

echo "OK: fleet-nothing-half-done: worktree/PR orphan canary + question nag"
