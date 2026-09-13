#!/usr/bin/env bash
# tests/pi-escalation-audit-spec-compliant.test.sh
#
# fleet-ops#5890 (required): the escalate-senior pipeline's filed fix issue —
# the admission tally (bin/pi-escalation-audit-tally, called by
# bin/pi-escalation-audit once the 2-of-3 panel admits) must PASS the
# spec-gate (fleet-ops#543) on a fixture escalation. The four spec lines
# (termination:/accept:/required:/metric:) derived from the failing check
# name and the repo must be present, plus the moves: line naming a product
# metric (fleet-ops#3255) — without them the admission itself re-enters the
# hourly SPEC-GATE-REFUSED comment storm (#4939: 45 identical comments).
#
# Drives the REAL tally with a REAL lib/agent-ready-spec-gate.py:
#   - fixture escalation = the pre-#5890 wrapper shape (no spec lines) whose
#     admission used to re-enter the storm;
#   - a fake gh captures the `issue create --body` the tally actually emits;
#   - that captured body must (a) carry the four lines + moves, (b) derive
#     the failing check name from the escalation title, (c) exit 0 through
#     `check-body --repo fleet-ops`, while the (old) wrapper body itself
#     still fails the same gate — proving the assertions bite.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tally="$repo_root/bin/pi-escalation-audit-tally"
gate="$repo_root/lib/agent-ready-spec-gate.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$tally" ]] || fail "not executable: $tally"
[[ -f "$gate" ]] || fail "missing: $gate"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/votes/fleet-ops/5901"
export FAKE_DIR="$scratch"
export AUDIT_STATE_DIR="$scratch/votes"
export AUDIT_ESCALATION_REPO="Nishfleet/fleet-ops"
export AUDIT_GH="$scratch/bin/gh"

# The fixture escalation: EXACTLY the escalation-title format the detector
# renders ("[escalate-senior] <full-repo>: <workflow>/<job> failing
# repeatedly") and a body WITHOUT the four spec lines (the pre-#5890
# wrapper — the very shape that starved in the #4939 storm).
cat >"$scratch/fixture-escalation.json" <<'JSON'
{
  "title": "[escalate-senior] Nishfleet/fleet-ops: ci/deploy-check failing repeatedly",
  "body": "<!-- escalate-sig: 5a1b2c3d4e5f6071 -->\n\nGitHub-plane failure escalation (fleet-ops#221). This check failed repeatedly and is NOT owned by auto-revert (main CI) or the #124 red-PR repair (claim/* worker PRs). Route to the senior-auditor panel per #146.\n\n## Failure context\n\n- **Repo:** `Nishfleet/fleet-ops`\n- **Workflow/Job:** ci/deploy-check\n- **Last green:** 2026-09-12T00:00:00Z\n\nSignature hash: `deadbeef00000000`. One escalation per signature per 6h; deduped against open `escalate-senior` issues. Closing this issue releases the bound."
}
JSON

cat >"$scratch/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  issue)
    case "$2" in
      view)
        if [[ "$*" == *"--json state"* ]]; then
          # the caller pipes through --jq '.state'; emit the post-jq value
          echo "OPEN"; exit 0
        fi
        if [[ "$*" == *"--json title,body"* ]]; then
          cat "$FAKE_DIR/fixture-escalation.json"; exit 0
        fi
        echo "unexpected issue view: $*" >&2; exit 1 ;;
      create)
        prev=""
        for a in "$@"; do
          case "$prev" in
            --body)  printf '%s' "$a" >"$FAKE_DIR/fix-body.md" ;;
            --title) printf '%s' "$a" >"$FAKE_DIR/created-title" ;;
          esac
          prev="$a"
        done
        printf '%s\n' "$*" >>"$FAKE_DIR/creates.log"
        echo "https://github.com/Nishfleet/fleet-ops/issues/5902"; exit 0 ;;
      comment) printf '%s\n' "$*" >>"$FAKE_DIR/comments.log"; exit 0 ;;
      close)   printf '%s\n' "$*" >>"$FAKE_DIR/closes.log"; exit 0 ;;
      *)       echo "unexpected: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$scratch/bin/gh" "$tally"

# 2-of-3 PASS votes (the #234 admission panel) -> the tally ADMITS and files.
jq -n '{repo:"fleet-ops",candidate:"5901",role:"devin",verdict:"PASS",reason:"runner fix verified green on ci/deploy-check, see #6209",at:"2026-09-13T05:00:00Z"}' >"$AUDIT_STATE_DIR/fleet-ops/5901/devin.vote"
jq -n '{repo:"fleet-ops",candidate:"5901",role:"free-glm",verdict:"PASS",reason:"diagnosis cites the failing check and a green rerun",at:"2026-09-13T05:10:00Z"}' >"$AUDIT_STATE_DIR/fleet-ops/5901/free-glm.vote"
jq -n '{repo:"fleet-ops",candidate:"5901",role:"senior",verdict:"FAIL",reason:"wants one more green run",at:"2026-09-13T05:20:00Z"}' >"$AUDIT_STATE_DIR/fleet-ops/5901/senior.vote"

out=$("$tally" fleet-ops 5901 2>&1) || fail "tally exited non-zero: $out"
grep -q 'admitted' <<<"$out" || fail "tally must admit (2-of-3 PASS): $out"

# The admit path completed: the wrapper got its comment and its close, so the
# captured fix-body.md IS the artifact the pipeline actually files.
grep -q 'Fix issue filed:' "$FAKE_DIR/comments.log" \
    || fail "admit comment missing: $(cat "$FAKE_DIR/comments.log")"
[[ -s "$FAKE_DIR/closes.log" ]] \
    || fail "admit must close the escalation wrapper: $(cat "$FAKE_DIR/closes.log")"

# --- required: the four spec lines + moves, derived from the failing check --
FIXBODY="$FAKE_DIR/fix-body.md"
[[ -s "$FIXBODY" ]] || fail "no fix-issue body captured: $(cat "$FAKE_DIR/creates.log" 2>/dev/null)"
for line in '- termination: ' '- accept: ' '- required: ' '- metric: ' '- moves: product_merges_per_day'; do
    grep -q -- "$line" "$FIXBODY" || fail "fix issue body misses '$line': $(cat "$FIXBODY")"
done
# Derived from the failing check name, not pasted: the wrapper title is
# "[escalate-senior] Nishfleet/fleet-ops: ci/deploy-check failing repeatedly".
grep -q -- '- termination: failing check .ci/deploy-check' "$FIXBODY" \
    || fail "termination must name the failing check ci/deploy-check: $(cat "$FIXBODY")"
# The failing check is that of the ESCALATION, not the tally's own.
[[ "$(cat "$FAKE_DIR/created-title")" == "[escalate-senior] Nishfleet/fleet-ops: ci/deploy-check failing repeatedly" ]] \
    || fail "tally must carry the escalation title: $(cat "$FAKE_DIR/created-title")"
ok "admitted fix issue carries termination/accept/required/metric + moves, derived from the failing check"

# --- the output PASSES the spec-gate (fleet-ops: also needs the moves: line)
if ! "$gate" check-body --repo fleet-ops <"$FIXBODY" >"$FAKE_DIR/verdict.txt" 2>&1; then
    fail "admitted fix issue must PASS the spec-gate: $(cat "$FAKE_DIR/verdict.txt") / $(cat "$FIXBODY")"
fi
grep -q 'SPEC-GATE: ok' "$FAKE_DIR/verdict.txt" \
    || fail "expected SPEC-GATE: ok, got: $(cat "$FAKE_DIR/verdict.txt")"
ok "admitted fix issue passes lib/agent-ready-spec-gate.py check-body --repo fleet-ops"

# Negative control: the (old) escalation wrapper body itself still FAILS the
# same gate — the assertions discriminate, the test cannot pass vacuously.
if jq -r '.body' "$FAKE_DIR/fixture-escalation.json" | "$gate" check-body --repo fleet-ops >"$FAKE_DIR/negverdict.txt" 2>&1; then
    fail "control: the spec-less wrapper body must FAIL the gate: $(cat "$FAKE_DIR/negverdict.txt")"
fi
grep -q 'SPEC-GATE: refused' "$FAKE_DIR/negverdict.txt" \
    || fail "control: expected SPEC-GATE: refused, got: $(cat "$FAKE_DIR/negverdict.txt")"
ok "control: the spec-less pre-#5890 wrapper body fails the same gate (the check bites)"

echo "all pi-escalation-audit-spec-compliant cases passed"
