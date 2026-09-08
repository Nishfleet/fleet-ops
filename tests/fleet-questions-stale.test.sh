#!/usr/bin/env bash
# tests/fleet-questions-stale.test.sh
#
# fleet-ops#4562 (accept 5): the stale-question detector fails loud when an
# issue labelled `question` + `priority` has no `decision-resolved:` comment
# after 24h — counting it on the `questions:` line (stale=<n>) and
# auto-filing ONE `agent-ready` fix issue per stale question, deduped by
# issue number.
#
# Mirrors tests/fleet-questions-line.test.sh (fake gh + fixtures).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/fleet-questions.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "lib/fleet-questions.sh not found"
command -v jq >/dev/null 2>&1 || fail "jq required"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Fixture: one stale question+priority (old, no verdict), one question+priority
# WITH a decision-resolved comment, one fresh question+priority (<24h), one
# plain question (no priority — out of scope).
fresh_iso="$(date -u -d '-1 hour' +%FT%TZ)"
cat >"$tmp/list.json" <<J
[{"number":10,"title":"stale direction","createdAt":"2026-09-01T10:00:00Z","labels":[{"name":"question"},{"name":"priority"}]},
 {"number":11,"title":"resolved","createdAt":"2026-09-01T10:00:00Z","labels":[{"name":"question"},{"name":"priority"}]},
 {"number":12,"title":"fresh","createdAt":"$fresh_iso","labels":[{"name":"question"},{"name":"priority"}]},
 {"number":13,"title":"no priority","createdAt":"2026-09-01T10:00:00Z","labels":[{"name":"question"}]}]
J

# fake gh: `list` -> fixture; `view 11` -> has decision-resolved comment;
# issue create -> recorded, prints a URL.
cat >"$tmp/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GLOG"
for i in "$@"; do
  if [ "$i" = "list" ]; then cat "$QFI"; exit 0; fi
  if [ "$i" = "11" ]; then
    printf '%s\n' '{"comments":[{"body":"decision-resolved: option 2, signups/week"}]}'; exit 0
  fi
done
printf '%s\n' "${CREATE_URL:-https://github.com/Nishfleet/demo/issues/99}"
exit 0
GH
chmod +x "$tmp/gh"
: > "$tmp/ghlog"; : > "$tmp/seen"

source_lib() {
  QFI="$tmp/list.json" GLOG="$tmp/ghlog" FLEET_QUESTION_GH="$tmp/gh" \
    FLEET_QUESTION_REPOS="demo" FLEET_QUESTION_AUTOFILE="${FA:-1}" \
    FLEET_QUESTION_STALE_STATE="$tmp/seen" \
    bash -c 'source "$0"; fq_stale_detector' "$lib"
}

# --- 1. exactly the stale one is counted (10; 11 has a verdict, 12 fresh, 13 no priority)
n="$(source_lib)"
[[ "$n" = "1" ]] || fail "stale count should be 1 (only #10), got: $n"
ok "stale=1: verdict-less question+priority older than 24h is counted"

# --- 2. auto-files ONE agent-ready issue naming the stale question
grep -q 'issue create' "$tmp/ghlog" || fail "detector did not auto-file"
grep -q -- '--label agent-ready' "$tmp/ghlog" || fail "auto-filed issue is not agent-ready"
grep -q 'Nishfleet/demo#10' "$tmp/ghlog" || fail "auto-filed issue does not name the stale question"
grep -q 'decision-resolved' "$tmp/ghlog" || fail "auto-filed issue does not require a decision-resolved comment"
ok "auto-filed one agent-ready fix issue naming demo#10"

# --- 3. dedupe: second run files nothing, count stays 1 (still no verdict)
before="$(grep -c 'issue create' "$tmp/ghlog" || true)"
n2="$(source_lib)"
after="$(grep -c 'issue create' "$tmp/ghlog" || true)"
[[ "$n2" = "1" ]] || fail "second-run stale count should stay 1, got: $n2"
[[ "$after" = "$before" ]] || fail "second run filed again (not deduped)"
ok "deduped by issue number: second run files nothing"

# --- 4. resolved questions are never stale: #11 alone -> stale=0, no filing
cat >"$tmp/list2.json" <<'J'
[{"number":11,"title":"resolved","createdAt":"2026-09-01T10:00:00Z","labels":[{"name":"question"},{"name":"priority"}]}]
J
before="$(grep -c 'issue create' "$tmp/ghlog" || true)"
QFI="$tmp/list2.json" GLOG="$tmp/ghlog" FLEET_QUESTION_GH="$tmp/gh" \
  FLEET_QUESTION_REPOS="demo" FLEET_QUESTION_STALE_STATE="$tmp/seen" \
  bash -c 'source "$0"; printf "%s" "$(fq_stale_detector)"' "$lib" > "$tmp/n3"
grep -q '^0$' "$tmp/n3" || fail "resolved question counted as stale"
after="$(grep -c 'issue create' "$tmp/ghlog" || true)"
[[ "$after" = "$before" ]] || fail "resolved question was auto-filed"
ok "a question+priority WITH decision-resolved is never stale"

# --- 5. the questions: line carries stale=<n>
line="$(
  QFI="$tmp/list.json" GLOG="$tmp/ghlog" FLEET_QUESTION_GH="$tmp/gh" \
  FLEET_QUESTION_REPOS="demo" FLEET_QUESTION_SOURCES="$tmp/empty-sources" \
  FLEET_QUESTION_STATE="$tmp/seen-unfiled" FLEET_QUESTION_STALE_STATE="$tmp/seen" \
  bash -c 'source "$0"; fleet_questions_line' "$lib"
)"
case "$line" in
  *"stale=1"*) : ;;
  *) fail "questions line missing stale=1; got: $line" ;;
esac
ok "questions line carries stale=: $line"

echo "all stale-question detector checks passed"
