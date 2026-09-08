#!/usr/bin/env bash
# tests/fleet-question-answer-ingest.test.sh
#
# fleet-ops#4476 (part 3, answer ingestion): Nish answers in a Claude session
# or by replying on Telegram -- never on GitHub. The receiving agent posts
# the `decision-resolved:` comment via the worker App token. This is the
# single testable in-repo surface for that rule.
#
# acceptance: "a fixture Telegram reply naming a handle produces the
# `decision-resolved:` comment."
#   - reply Q:<repo>#<n> <words> -> gh issue comment posts
#       `decision-resolved: <words verbatim>`; ONE confirmation line.
#   - never guess: an ambiguous reply (no/multiple handle, multiple open)
#       prints ONE clarifying line and posts nothing.
#
# Hosted from tests/nish-boundary-notify-classes.test.sh.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-question-answer-ingest"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$bin" ]] || fail "missing: $bin"
[[ -x "$bin" ]] || fail "not executable: $bin"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# fake gh: logs every call to GLOG; for `issue list` returns $QFI
cat >"$tmp/gh" <<'GH'
#!/usr/bin/env bash
printf 'CALL %s\n' "$*" >> "$GLOG"
for i in "$@"; do
  if [ "$i" = "list" ]; then printf '%s' "$Q3"; exit 0; fi
done
# a comment write: succeed
exit 0
GH
chmod +x "$tmp/gh"

intake="$(mktemp)"
printf '{"repos":[{"name":"fleet-ops"}],"excluded":[],"deferred":[]}' > "$intake"

q1() { : >"$tmp/glog"; }
q1
# --- 1. a name-any-handle reply produces the decision-resolved comment -------
printf 'Q:fleet-ops#4474 b\n' | GLOG="$tmp/glog" FLEET_QING_GH="$tmp/gh" \
  FLEET_QING_INTAKE_JSON="$intake" bash "$bin" >"$tmp/o1" 2>"$tmp/e1"
grep -q 'confirmation: posted decision-resolved: b on Q:fleet-ops#4474' "$tmp/o1" \
  || fail "no confirmation line; got: $(cat "$tmp/o1")"
grep -q 'issue comment 4474 -R Nishfleet/fleet-ops' "$tmp/glog" \
  || { cat "$tmp/glog"; fail "ingest did not post the comment to the named issue"; }
grep -q 'decision-resolved: b' "$tmp/glog" \
  || fail "the comment body is not decision-resolved: b (verbatim)"
ok "handle-named reply posts decision-resolved: b on Q:fleet-ops#4474"

# --- 2. --dry-run prints, posts nothing -------------------------------------
: >"$tmp/glog2"
printf 'Q:fleet-ops#4474 c\n' | GLOG="$tmp/glog2" FLEET_QING_GH="$tmp/gh" \
  FLEET_QING_INTAKE_JSON="$intake" bash "$bin" --dry-run >"$tmp/o2" 2>&1
grep -q 'dry-run decision-resolved: c' "$tmp/o2" || fail "--dry-run did not print the would-be comment"
[[ -s "$tmp/glog2" ]] && fail "--dry-run must not post"
ok "--dry-run prints the decision without posting"

# --- 3. ambiguous (two handles) -> ONE clarifying line, no post --------------
: >"$tmp/glog3"
set +e
printf 'Q:fleet-ops#4474 b and Q:0509#12 c\n' | GLOG="$tmp/glog3" FLEET_QING_GH="$tmp/gh" \
  FLEET_QING_INTAKE_JSON="$intake" bash "$bin" >"$tmp/o3" 2>"$tmp/e3"
rc3=$?
set -e
[[ "$rc3" -eq 2 ]] || fail "ambiguous reply should exit 2, got $rc3"
grep -q '^clarify:' "$tmp/o3" || fail "ambiguous reply must emit ONE clarifying line"
[[ -s "$tmp/glog3" ]] && fail "ambiguous reply must not post anything"
ok "ambiguous (two handles) reply asks a clarifying line and never guesses"

# --- 4. no handle + exactly one open question -> answer it ------------------
Q3='[{"number":4474}]' GLOG="$tmp/glog4" FLEET_QING_GH="$tmp/gh" \
  FLEET_QING_INTAKE_JSON="$intake" \
  bash "$bin" <<< 'pick b' >"$tmp/o4" 2>"$tmp/e4"; rc4=$?
grep -q 'confirmation: posted decision-resolved: pick b on Q:fleet-ops#4474' "$tmp/o4" \
  || { cat "$tmp/o4"; fail "single-outstanding reply did not answer it"; }
grep -q 'decision-resolved: pick b' "$tmp/glog4" || fail "single-outstanding post missing the decision text"
ok "no-handle reply to a single open question posts to it"

# --- 5. no handle, no/multiple open -> clarify, no post ----------------------
printf '%s' '[{"number":null}]' > "$tmp/empty.json"
set +e
Q3="[]" GLOG="$tmp/glog5" FLEET_QING_GH="$tmp/gh" FLEET_QING_INTAKE_JSON="$intake" \
  bash "$bin" <<< 'pick b' >"$tmp/o5" 2>"$tmp/e5"
rc5=$?
set -e
[[ "$rc5" -eq 2 ]] || fail "no-open case should exit 2, got $rc5"
grep -q '^clarify:' "$tmp/o5" || fail "no-open case must emit one clarify line"
grep -q 'issue comment' "$tmp/glog5" && fail "no-open case must not post"
ok "no open question = one clarify line, no post"

# --- 6. --help exits 0 -------------------------------------------------------
bash "$bin" --help >"$tmp/o6" 2>&1 && ok "--help exits 0" || fail "--help failed"

echo "PASS: tests/fleet-question-answer-ingest.test.sh"