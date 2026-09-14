#!/usr/bin/env bash
# tests/lifecycle-label-sweep-refusal-dedup.test.sh
#
# fleet-ops#5890: the hourly sweep re-posted the identical
# "spec-gate: refused agent-ready" comment on every tick for the same
# unchanged body (#4939: 45 identical comments over ~45h). The fix comments
# ONCE PER BODY DIGEST: the sweep persists sha256(body) of the last refused
# comment in the summary state file it already owns, skips silently while
# the digest is unchanged, and re-evaluates (comments again) only when the
# body changes.
#
# Fails on the pre-fix binary (which commented on every tick):
#   - accept a: sweep twice against a fixture issue with an unchanged
#     non-compliant body -> exactly ONE refusal comment.
#   - accept b: edit the body -> a SECOND evaluation (a second comment).
#   - run once more -> still exactly two (at most one comment per distinct
#     body state).
# Also pins the persistence: the summary carries sha256 of the CURRENT
# refused body, seeded before each run and written back after it.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/lifecycle-label-sweep"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin"

cat >"$scratch/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  issue)
    case "$2" in
      list)   cat "$FAKE_DIR/list.json"; exit 0 ;;
      comment) printf '%s\n' "$*" >>"$FAKE_DIR/comments.log"; exit 0 ;;
      *)      printf '%s\n' "issue $2" >>"$FAKE_DIR/other.log"; exit 0 ;;
    esac
    ;;
  label) printf '%s\n' "$*" >>"$FAKE_DIR/labels.log"; exit 0 ;;
  *)     printf '%s\n' "$*" >>"$FAKE_DIR/other.log"; exit 0 ;;
esac
FAKE
chmod +x "$scratch/bin/gh" "$bin"
export FAKE_DIR="$scratch"
export PATH="$scratch/bin:$PATH"
# Hermetic: the token stub skips the token-minting block; the state the
# dedup persists lives in $scratch, never the production summary.
export GH_TOKEN="test-stub"
export LIFECYCLE_SWEEP_REPOS="Nishfleet/fleet-ops"
export LIFECYCLE_SWEEP_NOW="2026-09-13T06:00:00Z"
export LIFECYCLE_SWEEP_LOCKDIR="$scratch/lock"
export LIFECYCLE_SWEEP_SUMMARY="$scratch/summary.json"
unset LIFECYCLE_SWEEP_DRILL || true

# Fixture: one unlabeled fleet-ops issue whose body fails the spec gate
# (no termination:/accept:/required:/metric: line, no moves: line).
# Title classifies agent-ready on fleet-ops (the #4939 shape: an escalation
# wrapper stripped of its labels, spec-gate refused, never labeled).
FIXNUM=5900
FIXKEY="Nishfleet/fleet-ops#$FIXNUM"
BODY1="please look at this"
BODY2="please look at this, thanks"

write_fixture() { # $1 = body
    jq -n --arg b "$1" \
        '[{"number":5900,"title":"feat(quality): inescapable per-role gates","body":$b,"labels":[]}]' \
        >"$FAKE_DIR/list.json"
}

digest_of() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

stored_digest() {
    jq -r --arg k "$FIXKEY" '.refusals // {} | .[$k] // "MISSING"' "$LIFECYCLE_SWEEP_SUMMARY"
}

refusal_comments() {
    grep -c 'spec-gate: refused agent-ready' "$FAKE_DIR/comments.log" || true
}

: >"$FAKE_DIR/comments.log"
: >"$FAKE_DIR/edits.log" 2>/dev/null || : >"$FAKE_DIR/edits.log"

# --- accept (a): unchanged non-compliant body -> exactly ONE comment --------
write_fixture "$BODY1"

out1=$("$bin" 2>"$scratch/err1.txt") || fail "run1 exit: $(cat "$scratch/err1.txt")"
[[ "$(refusal_comments)" -eq 1 ]] \
    || fail "run1: exactly one refusal comment expected, got $(refusal_comments): $(cat "$FAKE_DIR/comments.log")"
grep -q 'SPEC-GATE-REFUSED' "$scratch/err1.txt" \
    || fail "run1: must log SPEC-GATE-REFUSED: $(cat "$scratch/err1.txt")"
# The refused issue never becomes agent-ready (the label never lands).
if grep -q -- '--add-label agent-ready' "$FAKE_DIR/edits.log" 2>/dev/null; then
    fail "run1: refused issue must not get agent-ready: $(cat "$FAKE_DIR/edits.log" 2>/dev/null)"
fi
# The digest for THIS body is persisted after the comment lands.
[[ "$(stored_digest)" == "$(digest_of "$BODY1")" ]] \
    || fail "run1: summary must carry sha256(body)=$FIXKEY, got: $(stored_digest)"

out2=$("$bin" 2>"$scratch/err2.txt") || fail "run2 exit: $(cat "$scratch/err2.txt")"
[[ "$(refusal_comments)" -eq 1 ]] \
    || fail "run2 (unchanged body): still exactly ONE refusal comment, got $(refusal_comments): $(cat "$FAKE_DIR/comments.log")"
grep -q 'unchanged body digest — comment skipped' "$scratch/err2.txt" \
    || fail "run2: the skip must be logged, not silent: $(cat "$scratch/err2.txt")"
[[ "$(stored_digest)" == "$(digest_of "$BODY1")" ]] \
    || fail "run2: digest must be unchanged, got: $(stored_digest)"
ok "unchanged non-compliant body, two sweeps -> exactly ONE refusal comment (digest skipped the second)"

# --- accept (b): edit the body -> a second evaluation ------------------------
write_fixture "$BODY2"
out3=$("$bin" 2>"$scratch/err3.txt") || fail "run3 exit: $(cat "$scratch/err3.txt")"
[[ "$(refusal_comments)" -eq 2 ]] \
    || fail "run3 (edited body): a SECOND evaluation must comment again, got $(refusal_comments): $(cat "$FAKE_DIR/comments.log")"
[[ "$(stored_digest)" == "$(digest_of "$BODY2")" ]] \
    || fail "run3: summary must carry the NEW body digest, got: $(stored_digest)"
[[ "$(stored_digest)" != "$(digest_of "$BODY1")" ]] \
    || fail "run3: new digest must differ from the old one"

out4=$("$bin" 2>"$scratch/err4.txt") || fail "run4 exit: $(cat "$scratch/err4.txt")"
[[ "$(refusal_comments)" -eq 2 ]] \
    || fail "run4 (unchanged): no third comment — at most one per distinct body, got $(refusal_comments): $(cat "$FAKE_DIR/comments.log")"
ok "edited body gets a second evaluation; the re-stabilized body gets no third comment"

echo "all lifecycle-label-sweep-refusal-dedup cases passed"
