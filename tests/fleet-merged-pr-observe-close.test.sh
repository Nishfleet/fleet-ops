#!/usr/bin/env bash
# tests/fleet-merged-pr-observe-close.test.sh
#
# fleet-ops#1435: close worker-claimed issues whose merged PR forgot the
# Closes/Fixes/Resolves trailer. Offline. Live gh is stubbed. Proves:
#   1. No matching merged PR -> exit 0, no close.
#   2. Exactly one matching merged PR, no worker, no open PR, OK=1 -> close.
#   3. Same with OK=0 -> no close, would_close counted.
#   4. Live worker -> skip.
#   5. Open claim PR -> skip.
#   6. Multiple matching merged PRs -> LOUD ambiguous, no close.
#   7. Non-closing "Relates to" reference -> skip.
#   8. repo-short reference (fleet-ops#N) in title -> close.
#   9. Missing gh/jq fails loud.
#  10. Dry run -> no mutation, logs.
#  11. Tier1 integration: require_manifest_helper, FLEET_MERGED_PR_CLOSE_OK=1,
#      MANIFEST.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-merged-pr-observe-close"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
manifest="$repo_root/MANIFEST"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -x "$tier1" ]] || fail "not executable: $tier1"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/fixtures" "$scratch/live" "$scratch/log"

# --- fake gh: file-backed ----------------------------------------------------
cat >"$scratch/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
cmd="$1"; shift
case "$cmd" in
  issue)
    sub="$1"; shift
    case "$sub" in
      list)
        repo=""; label=""; json=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -R) repo="$2"; shift 2 ;;
            -l) label="$2"; shift 2 ;;
            --state|--json|--limit) shift 2 ;;
            *) shift ;;
          esac
        done
        f="$FAKE_DIR/fixtures/issues-${label}.json"
        [[ -f "$f" ]] && cat "$f" || echo '[]'
        exit 0
        ;;
      close)
        num=""; body=""; repo=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            [0-9]*) num="$1"; shift ;;
            --body|--comment) body="$2"; shift 2 ;;
            --repo|-R) repo="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        [[ -n "$num" ]] || { echo "no num" >&2; exit 1; }
        printf '%s\n' "CLOSE $repo $num" >>"$FAKE_DIR/close.log"
        printf '%s\n' "$body" >>"$FAKE_DIR/close-comment-${num}.log"
        exit 0
        ;;
      *) echo "unexpected gh issue $*" >&2; exit 1 ;;
    esac
    ;;
  pr)
    sub="$1"; shift
    case "$sub" in
      list)
        repo=""; head=""; state=""; search=""; limit=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -R) repo="$2"; shift 2 ;;
            --head) head="$2"; shift 2 ;;
            --state) state="$2"; shift 2 ;;
            --search) search="$2"; shift 2 ;;
            --limit) limit="$2"; shift 2 ;;
            --json) shift 2 ;;
            *) shift ;;
          esac
        done
        if [ -n "$head" ]; then
          n="${head#claim/issue-}"
          f="$FAKE_DIR/fixtures/open-pr-${n}.json"
          [[ -f "$f" ]] && cat "$f" || echo '[]'
        elif [ "$state" = "merged" ]; then
          cat "$FAKE_DIR/fixtures/merged-prs.json"
        else
          echo '[]'
        fi
        exit 0
        ;;
      *) echo "unexpected gh pr $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected gh $cmd" >&2; exit 1 ;;
esac
FAKE
chmod +x "$scratch/bin/gh"

# --- fake systemctl: live iff marker file exists ---------------------------
cat >"$scratch/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
shift  # --user
case "$1" in
  list-units)
    shift
    pattern=""
    want=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --state=*) IFS=',' read -ra want <<<"${1#--state=}"; shift ;;
        --state) IFS=',' read -ra want <<<"$2"; shift 2 ;;
        --no-legend|--type=service) shift ;;
        --*) shift ;;
        *) pattern="$1"; shift ;;
      esac
    done
    if [ -n "$pattern" ] && [ -f "$FAKE_DIR/live/$pattern" ]; then
      printf '%s loaded active running\tfake\n' "$pattern"
    fi
    # Global running list.
    if [ -z "$pattern" ]; then
      for f in "$FAKE_DIR/live"/pi-issue@* "$FAKE_DIR/live"/fable-p*; do
        [ -f "$f" ] || continue
        u=$(basename "$f")
        printf '%s loaded active running\tfake\n' "$u"
      done
    fi
    exit 0
    ;;
  show)
    unit=""; prop=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --property) prop="$2"; shift 2 ;;
        --value) shift ;;
        *) unit="$1"; shift ;;
      esac
    done
    if [ "$prop" = "SubState" ]; then
      cat "$FAKE_DIR/live/$unit" 2>/dev/null || echo running
    fi
    exit 0
    ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$scratch/bin/systemctl"

export PATH="$scratch/bin:$PATH"
export FAKE_DIR="$scratch"
export SYSTEMCTL="$scratch/bin/systemctl"
export MERGED_PR_CLOSE_LOCKDIR="$scratch/lock"
export MERGED_PR_CLOSE_TRIAGE="$scratch/triage"
export MERGED_PR_CLOSE_REPOS="Nishfleet/fleet-ops"

REPO="Nishfleet/fleet-ops"
mkdir -p "$scratch/fixtures"

write_merged() { cat >"$scratch/fixtures/merged-prs.json"; }
write_issues() { cat >"$scratch/fixtures/issues-agent-in-progress.json"; }

# --- 1. no matching merged PR ------------------------------------------------
write_issues <<'JSON'
[{"number":100,"title":"orphan"}]
JSON
write_merged <<'JSON'
[]
JSON
out=$("$bin" 2>"$scratch/err1.txt")
grep -q 'no open agent-in-progress issues\|no merged PRs\|sweep done' "$scratch/err1.txt" \
  || fail "case 1 should log a clean sweep, got: $(cat "$scratch/err1.txt")"
[[ ! -f "$scratch/close.log" ]] || fail "case 1 should not close"
ok "case 1: no matching merged PR -> no close"

# --- 2. one matching merged PR -> close with OK=1 --------------------------
: >"$scratch/close.log"
write_merged <<'JSON'
[{"number":900,"title":"feat: disaster recovery (fleet-ops#1135)","body":"Implements #1135.","url":"https://github.com/Nishfleet/fleet-ops/pull/900","mergedAt":"2026-08-28T00:22:21Z","headRefName":"claim/issue-1135"}]
JSON
write_issues <<'JSON'
[{"number":1135,"title":"disaster recovery"}]
JSON
echo '[]' >"$scratch/fixtures/open-pr-1135.json"
out=$(FLEET_MERGED_PR_CLOSE_OK=1 "$bin" 2>"$scratch/err2.txt")
grep -q 'closed=1' "$scratch/err2.txt" \
  || fail "case 2 should close 1, got: $(cat "$scratch/err2.txt")"
[[ -f "$scratch/close.log" ]] || fail "case 2 must call gh issue close"
grep -q 'CLOSE Nishfleet/fleet-ops 1135' "$scratch/close.log" \
  || fail "case 2 close log wrong: $(cat "$scratch/close.log")"
grep -q 'https://github.com/Nishfleet/fleet-ops/pull/900' "$scratch/close-comment-1135.log" \
  || fail "case 2 close comment must cite merged PR"
grep -q 'no live worker or open PR was found' "$scratch/close-comment-1135.log" \
  || fail "case 2 close comment must cite verification"
ok "case 2: one matching merged PR, OK=1 -> close"

# --- 3. OK=0 -> would close but not close -----------------------------------
: >"$scratch/close.log"
write_merged <<'JSON'
[{"number":901,"title":"fix: widget (fleet-ops#100)","body":"","url":"https://github.com/Nishfleet/fleet-ops/pull/901","mergedAt":"2026-08-28T00:00:00Z","headRefName":"claim/issue-100"}]
JSON
write_issues <<'JSON'
[{"number":100,"title":"widget"}]
JSON
echo '[]' >"$scratch/fixtures/open-pr-100.json"
out=$("$bin" 2>"$scratch/err3.txt")
grep -q 'would_close=1' "$scratch/err3.txt" \
  || fail "case 3 should would_close=1, got: $(cat "$scratch/err3.txt")"
[[ ! -s "$scratch/close.log" ]] || fail "case 3 must not close"
ok "case 3: OK=0 -> would close but not close"

# --- 4. live worker -> skip --------------------------------------------------
: >"$scratch/close.log"
touch "$scratch/live/pi-issue@fleet-ops-200.service"
write_merged <<'JSON'
[{"number":902,"title":"fix: live (fleet-ops#200)","body":"","url":"https://github.com/Nishfleet/fleet-ops/pull/902","mergedAt":"2026-08-28T00:00:00Z","headRefName":"claim/issue-200"}]
JSON
write_issues <<'JSON'
[{"number":200,"title":"live"}]
JSON
echo '[]' >"$scratch/fixtures/open-pr-200.json"
out=$(FLEET_MERGED_PR_CLOSE_OK=1 "$bin" 2>"$scratch/err4.txt")
grep -q 'skipped_live=1' "$scratch/err4.txt" \
  || fail "case 4 should skip live worker, got: $(cat "$scratch/err4.txt")"
[[ ! -s "$scratch/close.log" ]] || fail "case 4 must not close"
rm -f "$scratch/live/pi-issue@fleet-ops-200.service"
ok "case 4: live worker -> skip"

# --- 5. open claim PR -> skip ------------------------------------------------
: >"$scratch/close.log"
write_merged <<'JSON'
[{"number":903,"title":"fix: open (fleet-ops#300)","body":"","url":"https://github.com/Nishfleet/fleet-ops/pull/903","mergedAt":"2026-08-28T00:00:00Z","headRefName":"claim/issue-300"}]
JSON
write_issues <<'JSON'
[{"number":300,"title":"open"}]
JSON
cat >"$scratch/fixtures/open-pr-300.json" <<'JSON'
[{"number":999}]
JSON
out=$(FLEET_MERGED_PR_CLOSE_OK=1 "$bin" 2>"$scratch/err5.txt")
grep -q 'skipped_pr=1' "$scratch/err5.txt" \
  || fail "case 5 should skip open PR, got: $(cat "$scratch/err5.txt")"
[[ ! -s "$scratch/close.log" ]] || fail "case 5 must not close"
ok "case 5: open claim PR -> skip"

# --- 6. multiple merged PRs reference -> ambiguous, LOUD --------------------
: >"$scratch/close.log"
write_merged <<'JSON'
[{"number":904,"title":"fix: a (fleet-ops#400)","body":"","url":"https://github.com/Nishfleet/fleet-ops/pull/904","mergedAt":"2026-08-28T00:00:00Z","headRefName":"claim/issue-400"},
 {"number":905,"title":"fix: b (fleet-ops#400)","body":"","url":"https://github.com/Nishfleet/fleet-ops/pull/905","mergedAt":"2026-08-28T00:00:00Z","headRefName":"claim/issue-400"}]
JSON
write_issues <<'JSON'
[{"number":400,"title":"ambiguous"}]
JSON
echo '[]' >"$scratch/fixtures/open-pr-400.json"
out=$(FLEET_MERGED_PR_CLOSE_OK=1 "$bin" 2>"$scratch/err6.txt")
grep -q 'ambiguous=1' "$scratch/err6.txt" \
  || fail "case 6 should be ambiguous, got: $(cat "$scratch/err6.txt")"
grep -q 'MERGED-PR-CLOSE-AMBIGUOUS' "$scratch/triage" \
  || fail "case 6 must write a LOUD triage line"
[[ ! -s "$scratch/close.log" ]] || fail "case 6 must not close"
ok "case 6: multiple merged PRs -> ambiguous and LOUD"

# --- 7. Relates to -> non-closing, skip --------------------------------------
: >"$scratch/close.log"
: >"$scratch/triage"
write_merged <<'JSON'
[{"number":906,"title":"fix: relates (fleet-ops#500)","body":"Relates to #500. This is not the close.","url":"https://github.com/Nishfleet/fleet-ops/pull/906","mergedAt":"2026-08-28T00:00:00Z","headRefName":"claim/issue-500"}]
JSON
write_issues <<'JSON'
[{"number":500,"title":"relates"}]
JSON
echo '[]' >"$scratch/fixtures/open-pr-500.json"
out=$(FLEET_MERGED_PR_CLOSE_OK=1 "$bin" 2>"$scratch/err7.txt")
[[ ! -s "$scratch/close.log" ]] || fail "case 7 must not close on Relates to"
grep -q 'closed=0' "$scratch/err7.txt" \
  || fail "case 7 should close nothing, got: $(cat "$scratch/err7.txt")"
ok "case 7: 'Relates to' reference -> non-closing skip"

# --- 8. repo-short title reference -> close ----------------------------------
: >"$scratch/close.log"
write_merged <<'JSON'
[{"number":907,"title":"feat: do thing (fleet-ops#600)","body":"","url":"https://github.com/Nishfleet/fleet-ops/pull/907","mergedAt":"2026-08-28T00:00:00Z","headRefName":"claim/issue-600"}]
JSON
write_issues <<'JSON'
[{"number":600,"title":"short ref"}]
JSON
echo '[]' >"$scratch/fixtures/open-pr-600.json"
out=$(FLEET_MERGED_PR_CLOSE_OK=1 "$bin" 2>"$scratch/err8.txt")
grep -q 'closed=1' "$scratch/err8.txt" \
  || fail "case 8 should close, got: $(cat "$scratch/err8.txt")"
grep -q 'CLOSE Nishfleet/fleet-ops 600' "$scratch/close.log" \
  || fail "case 8 close log wrong"
ok "case 8: repo-short title reference -> close"

# --- 9. missing gh fails loud ------------------------------------------------
: >"$scratch/close.log"
write_issues '[]'
write_merged '[]'
out=$(PATH="/usr/bin:/bin" "$bin" 2>"$scratch/err9.txt" || true)
grep -q 'FATAL: gh missing' "$scratch/err9.txt" \
  || fail "missing gh should fail loud, got: $(cat "$scratch/err9.txt")"
ok "case 9: missing gh fails loud"

# --- 10. dry run -> no mutation ----------------------------------------------
: >"$scratch/close.log"
write_merged <<'JSON'
[{"number":908,"title":"fix: dry (fleet-ops#700)","body":"","url":"https://github.com/Nishfleet/fleet-ops/pull/908","mergedAt":"2026-08-28T00:00:00Z","headRefName":"claim/issue-700"}]
JSON
write_issues <<'JSON'
[{"number":700,"title":"dry"}]
JSON
echo '[]' >"$scratch/fixtures/open-pr-700.json"
out=$(FLEET_MERGED_PR_CLOSE_OK=1 MERGED_PR_CLOSE_DRY_RUN=1 "$bin" 2>"$scratch/err10.txt")
grep -q 'DRY close' "$scratch/err10.txt" \
  || fail "dry run should log DRY close, got: $(cat "$scratch/err10.txt")"
[[ ! -s "$scratch/close.log" ]] || fail "dry run must not close"
ok "case 10: dry run -> no mutation"

# --- 11. contracts: tier1 wiring, MANIFEST -----------------------------------
grep -q 'MERGED_PR_CLOSE_BIN=' "$tier1" \
  || fail "tier1 must reference MERGED_PR_CLOSE_BIN"
grep -q 'FLEET_MERGED_PR_CLOSE_OK=1' "$tier1" \
  || fail "tier1 must set FLEET_MERGED_PR_CLOSE_OK=1"
grep -q 'merged_pr_close_rc' "$tier1" \
  || fail "tier1 must track merged_pr_close_rc"
grep -q 'fleet-merged-pr-observe-close' "$manifest" \
  || fail "MANIFEST must install fleet-merged-pr-observe-close"
ok "case 11: tier1 wiring and MANIFEST"

echo "OK: fleet-merged-pr-observe-close (fleet-ops#1435)"
