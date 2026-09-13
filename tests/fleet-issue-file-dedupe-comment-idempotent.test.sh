#!/usr/bin/env bash
# tests/fleet-issue-file-dedupe-comment-idempotent.test.sh
#
# fleet-ops#5496: the file-time duplicate branch posted comment_body() on
# EVERY dedupe hit with no memory of prior comments; the blind-audit
# backfill piled 675+ identical dedupe comments on fleet-ops#5464. The fix:
# skip the comment when the canonical issue already carries an issue-file
# dedupe comment covering this (source repo, title) filing.
#
# Proves, offline with a fake gh:
#   1. A re-run of a dedupe-heavy batch adds 0 new comments to the canonical.
#   2. A genuinely new duplicate (different title) still comments once.
#   3. The dedupe link still counts as action="commented" in the JSON.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/issue-file.py"
bin="$repo_root/bin/fleet-issue-file"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
[[ -f "$bin" ]] || fail "missing $bin"
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$lib" \
  || fail "issue-file.py failed to parse"

scratch=$(mktemp -d -t file-dedupe-idem.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM

mkdir -p "$scratch/fakebin"
cat >"$scratch/fakebin/gh" <<'GH'
#!/usr/bin/env bash
case "$1" in
  issue)
    case "$2" in
      list)    if [[ -f "${GH_OPEN_JSON:-/dev/null}" ]]; then cat "${GH_OPEN_JSON}"; else printf '[]\n'; fi ;;
      comment) echo "commented $3" >>"${GH_COMMENTED:-/dev/null}" ;;
      view)
        if [[ -f "${GH_COMMENT_FIXTURE:-/dev/null}" ]]; then cat "${GH_COMMENT_FIXTURE}"; else printf '{"comments":[]}\n'; fi
        ;;
    esac
    ;;
esac
exit 0
GH
chmod +x "$scratch/fakebin/gh"

export GH="$scratch/fakebin/gh"
export GH_COMMENTED="$scratch/commented"
export GH_OPEN_JSON="$scratch/gh-open.json"
: >"$scratch/commented"

cat >"$scratch/gh-open.json" <<'JSON'
[
  {"number":5464,"repository":"Nishfleet/fleet-ops","title":"STOP-REASON cascade fleet-blind-audit-backfill-capfix exit 1","body":".Exactly -------- STOP-REASON cascade.Exactly -------- STOP-REASON cascade.Exactly -------- backfill worker capfix exited 1.","url":"u5464","labels":["agent-in-progress"]}
]
JSON

title="STOP-REASON cascade fleet-blind-audit-backfill-capfix exit 1"
body="Exactly -------- STOP-REASON cascade.Exactly -------- STOP-REASON cascade.Exactly -------- backfill worker capfix exited 1. STOP."

# --- 1. Canonical already carries the dedupe comment -> 0 new comments ------
cat >"$scratch/comments.json" <<'JSON'
{"comments":[
  {"body":"Same-problem duplicate suppressed by the fleet-ops#1212 filing gate (score=0.95).\n\nWould have filed in `Nishfleet/fleet-ops`:\n\n**STOP-REASON cascade fleet-blind-audit-backfill-capfix exit 1**\n\nExactly -------- STOP-REASON cascade."}
]}
JSON
export GH_COMMENT_FIXTURE="$scratch/comments.json"

"$bin" file --repo Nishfleet/fleet-ops --title "$title" --body "$body" --json >"$scratch/out1.json" 2>"$scratch/err1" \
  || fail "file run 1 exited nonzero"
python3 -c "import json,sys; d=json.load(open('$scratch/out1.json')); exit(0 if d['action']=='commented' else 1)" \
  || fail "run 1 action should still be commented"
n1=$(grep -c . "$GH_COMMENTED" || true)
[[ "$n1" -eq 0 ]] || fail "expected 0 new comments on re-run, got $n1"
grep -q "already commented" "$scratch/err1" || fail "missing skip note on stderr"
ok "run 2 (re-run): 0 new comments, action=commented honored without re-posting"

# Legacy body WITHOUT the marker text but WITH title still recognized.
cat >"$scratch/comments.json" <<'JSON'
{"comments":[
  {"body":"dedupe note\n\nWould have filed in `Nishfleet/fleet-ops`:\n\n**STOP-REASON cascade fleet-blind-audit-backfill-capfix exit 1**\n\nsome excerpt"}
]}
JSON
: >"$GH_COMMENTED"
"$bin" file --repo Nishfleet/fleet-ops --title "$title" --body "$body" --json >/dev/null 2>&1 \
  || fail "file run (legacy comments) exited nonzero"
[[ ! -s "$GH_COMMENTED" ]] || fail "legacy dedupe comment body should have suppressed the re-post"
ok "legacy comment body (no marker) also suppresses"

# --- 2. Genuinely new duplicate still comments once --------------------------
cat >"$scratch/comments.json" <<'JSON'
{"comments":[]}
JSON
: >"$GH_COMMENTED"
"$bin" file --repo Nishfleet/fleet-ops --title "$title" --body "$body" --json >"$scratch/out3.json" 2>"$scratch/err3" \
  || fail "file run 3 exited nonzero"
n3=$(grep -c . "$GH_COMMENTED" || true)
[[ "$n3" -eq 1 ]] || fail "expected exactly 1 comment for a new duplicate, got $n3"
ok "genuinely new duplicate comments exactly once"

echo "file-dedupe-comment-idempotent: all checks passed"
