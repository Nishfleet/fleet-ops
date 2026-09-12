#!/usr/bin/env bash
# tests/pi-audit-run-question.test.sh
#
# fleet-ops#4474 (part 1: conference gate). Proves pi-audit-run switches to the
# Nish-question panel for a candidate carrying the `question` label (and not
# already decided), and accepts NISH/MATRIX verdicts that the question tally
# routes:
#   1. a `question` candidate -> the nish-question-auditor prompt is used and a
#      NISH verdict is extracted + written to the vote.
#   2. a MATRIX verdict is likewise extracted + written.
#   3. a scout candidate (no question label) still falls through to the default
#      scout prompt + PASS/FAIL verdicts.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/pi-audit-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t pi-audit-run-q.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
export HOME="$scratch/home"
mkdir -p "$HOME" "$scratch/state"
export AUDIT_STATE_DIR="$scratch/state"

# Fake gh: `issue view` returns labels from $ISSUE_LABELS env so we can drive
# the question/scout switch without changing the request. Body stays
# single-line so the JSON is valid (a literal newline breaks jq).
gh_fake="$scratch/gh"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *"issue view"*"--json"*)
    printf '{"title":"test","body":"question: decide? options: a | b","labels":%s}\n' "${ISSUE_LABELS:-[]}"
    exit 0
    ;;
  *"pr list"*|*"issue list"*)
    printf '[]\n'
    exit 0
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$gh_fake"

pi_fake="$scratch/pi"
cat >"$pi_fake" <<'FAKE'
#!/usr/bin/env bash
shift  # --print
if [[ -n "${PI_DUMP_PACKET:-}" ]]; then cat >"$PI_DUMP_PACKET"; else cat >/dev/null; fi
printf '%s' "${PI_RESPONSE:-}"
FAKE
chmod +x "$pi_fake"

seat_lib="$scratch/seatlib.sh"
cat >"$seat_lib" <<'LIB'
enumerate_seats() { printf '%s\t%s\t-\t1\n' devin glm-5-2; }
class_of() { printf 'prepaid-quota\n'; }
model_cap() { printf '1\n'; }
seat_usable() { return 0; }
seat_ledger_path() { printf '/dev/null/%s__%s.json\n' "$1" "$2"; }
LIB

scout_prompt="$scratch/scout-auditor.md"
cat >"$scout_prompt" <<'EOF'
# Senior auditor (scout)
PASS
<reason>
OR
FAIL
<reason>
keyword: duplicate, north-star
EOF
question_prompt="$scratch/question-auditor.md"
cat >"$question_prompt" <<'EOF'
# Senior auditor (Nish-question)
NISH
<reason>
OR
MATRIX
<reason>
keyword: reserved, decided
EOF

export AUDIT_GH="$gh_fake"
export AUDIT_PROMPT="$scout_prompt"
export AUDIT_QUESTION_PROMPT="$question_prompt"
export PI_BIN="$pi_fake"
export PI_PACKET_SEAT_LIB="$seat_lib"

# =============================================================================
# 1. question candidate + NISH -> uses question prompt, writes NISH vote
# =============================================================================
: >"$scratch/pkt1"
ISSUE_LABELS='[{"name":"question"}]' PI_RESPONSE=$'NISH\nreserved: money ask, not decided in the ledger' \
  PI_DUMP_PACKET="$scratch/pkt1" \
  bash "$bin" 'demo--55--devin' >/dev/null 2>"$scratch/err1" \
  || { echo "--- err1 ---"; cat "$scratch/err1"; fail "run1 exit failed"; }
grep -q "Senior auditor (Nish-question)" "$scratch/pkt1" || fail "run1: question prompt not used"
grep -q "Senior auditor (scout)" "$scratch/pkt1" && fail "run1: scout prompt erroneously used"
v=$(jq -r '.verdict' "$AUDIT_STATE_DIR/demo/55/devin.vote")
[[ "$v" == "NISH" ]] || fail "run1: expected NISH verdict, got $v"
ok "question candidate -> question prompt + NISH verdict written"

# =============================================================================
# 2. question candidate + MATRIX -> MATRIX verdict written with route padding
# =============================================================================
ISSUE_LABELS='[{"name":"question"}]' PI_RESPONSE=$'MATRIX\norchestrator — not reserved, decision-sweep resolves' \
  PI_DUMP_PACKET="$scratch/pkt2" \
  bash "$bin" 'demo--55--free-glm' >/dev/null 2>"$scratch/err2" \
  || { echo "--- err2 ---"; cat "$scratch/err2"; fail "run2 exit failed"; }
v=$(jq -r '.verdict' "$AUDIT_STATE_DIR/demo/55/free-glm.vote")
[[ "$v" == "MATRIX" ]] || fail "run2: expected MATRIX verdict, got $v"
ok "question candidate -> MATRIX verdict written"

# =============================================================================
# 3. scout candidate -> scout prompt + PASS/FAIL only (no question prompt)
# =============================================================================
ISSUE_LABELS='[]' PI_RESPONSE=$'PASS\nclear user impact; no duplicate; advances north star; see bin/x' \
  PI_DUMP_PACKET="$scratch/pkt3" \
  bash "$bin" 'demo--56--devin' >/dev/null 2>"$scratch/err3" \
  || { echo "--- err3 ---"; cat "$scratch/err3"; fail "run3 exit failed"; }
grep -q "Senior auditor (scout)" "$scratch/pkt3" || fail "run3: scout prompt not used"
grep -q "Senior auditor (Nish-question)" "$scratch/pkt3" && fail "run3: question prompt used for a scout"
v=$(jq -r '.verdict' "$AUDIT_STATE_DIR/demo/56/devin.vote")
[[ "$v" == "PASS" ]] || fail "run3: expected PASS verdict, got $v"
ok "scout candidate -> scout prompt + PASS/FAIL only"

echo "PASS: tests/pi-audit-run-question.test.sh"
