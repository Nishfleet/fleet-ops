#!/usr/bin/env bash
# tests/fleet-questions-line.test.sh
#
# fleet-ops#4476 (part 3): measure.sh prints the `questions:` header line the
# judge/fable-check consume, and its unfiled detector turns out-of-store
# question-like lines into fault lines + auto-filed `question` issues.
#
# Acceptance (the issue):
#   1. `bash measure.sh | grep -E '^questions:'` prints the four fields
#      for-nish= oldest= in-conference= unfiled=.
#   2. a fixture source containing an unfiled "Nish, should we…?" line yields
#      unfiled=1 AND an auto-filed `question` issue quoting the source.
#   3. counts are real (gate-confirmed vs in-conference vs age), never
#      fabricated; a second run dedupes unfiled to 0.
#
# Hosted from tests/fleet-metrics-export.test.sh (like fleet-usd-spend).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
measure="$repo_root/measure.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$measure" ]] || fail "measure.sh not found"
command -v jq >/dev/null 2>&1 || fail "jq required"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# fake gh: returns the fixture question list; captures issue create/comment
cat >"$tmp/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GLOG"
for i in "$@"; do
  if [ "$i" = "list" ]; then cat "$QFI"; exit 0; fi
done
printf '%s\n' "${CREATE_URL:-https://github.com/Nishfleet/demo/issues/42}"
exit 0
GH
chmod +x "$tmp/gh"

# fixture: 2 confirmed (nish-reserved + conference-approved), 1 in-conference
cat >"$tmp/questions.json" <<'J'
[{"number":1,"title":"top up?","createdAt":"2026-09-06T10:00:00Z","labels":[{"name":"question"},{"name":"nish-reserved"}]},
 {"number":2,"title":"route this","createdAt":"2026-09-07T10:00:00Z","labels":[{"name":"question"}]},
 {"number":3,"title":"old one","createdAt":"2026-09-01T10:00:00Z","labels":[{"name":"question"},{"name":"conference-approved"}]}]
J

# unfiled source: one "Nish, should we…?" line (fresh mtime now = scanned)
mkdir -p "$tmp/checks"
printf 'Nish, should we buy a new seat?\n' > "$tmp/checks/judge-report.md"
: > "$tmp/seen"; : > "$tmp/ghlog"

run_measure() {
  FLEET_SESSIONS_DIR="$tmp/sessions" MEASURE_REPOS="" \
    QFI="$tmp/questions.json" GLOG="$tmp/ghlog" FLEET_QUESTION_GH="$tmp/gh" \
    FLEET_QUESTION_REPOS="demo" FLEET_QUESTION_SOURCES="$tmp/checks" \
    FLEET_QUESTION_STATE="$tmp/seen" bash "$measure" 2>/dev/null
}

# --- 1. the four fields on the ^questions: line -----------------------------
line="$(run_measure | grep -E '^questions:' || true)"
[[ -n "$line" ]] || fail "measure.sh did not print a ^questions: line"
for f in for-nish= oldest= in-conference= unfiled=; do
  printf '%s\n' "$line" | grep -q "$f" || fail "questions line missing $f; got: $line"
done
ok "measure.sh prints questions line: $line"

# --- 2. real counts (2 confirmed, old confirmed >24h, 1 in-conference) ------
case "$line" in
  *"for-nish=2"*) : ;;
  *) fail "for-nish should be 2 (confirmed), got: $line" ;;
esac
case "$line" in
  *"in-conference=1"*) : ;;
  *) fail "in-conference should be 1, got: $line" ;;
esac
oldest="$(printf '%s\n' "$line" | sed -E 's/.*oldest=([0-9]+)h.*/\1/')"
[[ "$oldest" -gt 24 ]] || fail "oldest should reflect a multi-day confirmed question, got $oldest"
ok "counts are real (for-nish=2, oldest=$oldest>24h, in-conference=1)"

# --- 1b. unfiled detector sees the line AND auto-files an issue ------------
case "$line" in
  *"unfiled=1"*) : ;;
  *) fail "unfiled should be 1 for the fixture line; got: $line" ;;
esac
grep -q 'issue create' "$tmp/ghlog" || fail "unfiled detector did not auto-file a question issue"
grep -q 'should we buy a new seat' "$tmp/ghlog" || fail "auto-filed issue did not quote the unfiled source line"
ok "unfiled=1 + an auto-filed question issue quoting the source"

# --- 3. dedupe: second run yields unfiled=0 (state-held) --------------------
line2="$(run_measure | grep -E '^questions:' || true)"
case "$line2" in
  *"unfiled=0"*) : ;;
  *) fail "second run should dedupe unfiled to 0; got: $line2" ;;
esac
ok "unfiled dedupes to 0 on the second run (state-held)"

echo "PASS: tests/fleet-questions-line.test.sh"