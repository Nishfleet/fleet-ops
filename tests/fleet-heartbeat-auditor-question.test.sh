#!/usr/bin/env bash
# tests/fleet-heartbeat-auditor-question.test.sh
#
# fleet-ops#4474 (part 1: conference gate). Proves the senior-auditor panel
# (fleet-heartbeat-auditor) ALSO walks open `question` issues — the ones that
# ask Nish — and:
#   1. starts the same pi-audit@<repo>--<candidate>--<role>.service units for
#      an UNDECIDED question (label question, no nish-reserved/conference-
#      approved), exactly as it already does for scout-candidates.
#   2. SKIPS an already-decided question (nish-reserved): no unit start, no
#      burn of the per-tick start cap.
#   3. calls pi-audit-tally when all three votes are present.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
auditor_bin="$repo_root/bin/fleet-heartbeat-auditor"
tally_bin="$repo_root/bin/pi-audit-tally"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$auditor_bin" ]] || fail "not executable: $auditor_bin"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t auditor-q.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
export HOME="$scratch/home"; mkdir -p "$HOME"

cat >"$scratch/intake-repos.json" <<'JSON'
{"repos":[{"name":"demo"}],"excluded":[],"deferred":[]}
JSON
mkdir -p "$scratch/log" "$scratch/audit-state"
: >"$scratch/triage.md"
calls="$scratch/calls.log"; : >"$calls"
gh_calls="$scratch/gh_calls"; : >"$gh_calls"

# Fake gh: answers `issue list -l question` from $QUESTION_CANDIDATES, the
# scout list as empty, and issue view from $GH_ISSUE_BODY.
gh_fake="$scratch/gh"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_CALLS:-/dev/null}"
case "$*" in
  *"issue list"*"-l question"*)
    jq -R -s -c 'split("\n")|map(select(length>0))|map(split("\t") as $p|{
      number:($p[0]|tonumber),
      labels:((if ($p|length)>1 and $p[1]=="decided" then [{name:"question"},{name:"nish-reserved"}]
               else [{name:"question"}] end)),
      author:{login:(if ($p|length)>2 then $p[2] else "agent-x" end)}
    })' ${QUESTION_CANDIDATES:-/dev/null}
    exit 0
    ;;
  *"issue list"*"-l scout-candidate"*)
    printf '[]\n'; exit 0
    ;;
  *"issue list"*"-l agent-ready"*)
    printf '[]\n'; exit 0
    ;;
  *"issue view"*)
    if [[ -f "${GH_ISSUE_BODY:-/dev/nonexistent}" ]]; then
      jq -n --rawfile b "${GH_ISSUE_BODY}" '{title:"q",body:$b,
        labels:[{"name":"question"}]}'
    else
      printf '{"title":"q","body":"question: decide?\\noptions: a | b","labels":[{"name":"question"}]}\n'
    fi
    exit 0
    ;;
  *"issue edit"*|*"issue comment"*)
    exit 0
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$gh_fake"

systemctl_fake="$scratch/systemctl"
cat >"$systemctl_fake" <<'FAKE'
#!/usr/bin/env bash
shift
cmd="$1"; shift
case "$cmd" in
  is-active) unit="$1"; [[ -f "${ACTIVE_UNITS:-/dev/nonexistent}" ]] && grep -qxF "$unit" "${ACTIVE_UNITS}" && { echo active; exit 0; }; echo inactive; exit 0 ;;
  start) unit="$2"; echo "start $unit" >>"${CALLS_LOG:-/dev/null}"; exit 0 ;;
  reset-failed) exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$systemctl_fake"

export FLEET_INTAKE_REPOS_JSON="$scratch/intake-repos.json"
export FLEET_HEARTBEAT_LOG_DIR="$scratch/log"
export FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md"
export AUDIT_STATE_DIR="$scratch/audit-state"
export AUDIT_GH="$scratch/gh"
export SYSTEMCTL="$scratch/systemctl"
export AUDIT_TALLY_BIN="$repo_root/bin/pi-audit-tally"
export GH_CALLS="$gh_calls"
export CALLS_LOG="$calls"
export ACTIVE_UNITS="$scratch/active"; : >"$ACTIVE_UNITS"
export GH_ISSUE_BODY="$scratch/issue-body.md"
printf 'question: should we top up straitly?\noptions: a | b | c\nblocked-on: nish-decision\n' >"$GH_ISSUE_BODY"
export AUDIT_TICK_MAX_START=8

# =============================================================================
# 1. undecided question -> panel unit started for all three roles
# =============================================================================
printf '55\tundecided\tsomeone\n' >"$scratch/qcands"
export QUESTION_CANDIDATES="$scratch/qcands"
if ! "$auditor_bin" >"$scratch/out" 2>"$scratch/err"; then
  echo "--- auditor err ---"; cat "$scratch/err"; fail "question auditor exit nonzero"
fi
grep -q "start pi-audit@demo--55--devin.service" "$calls" || fail "question: devin unit not started"
grep -q "start pi-audit@demo--55--free-glm.service" "$calls" || fail "question: free-glm unit not started"
grep -q "start pi-audit@demo--55--senior.service" "$calls" || fail "question: senior unit not started"
grep -q 'pi-audit@demo--55--devin.service ' "$0" 2>/dev/null || true
ok "undecided question -> panel starts all three audit units"

# =============================================================================
# 2. already-decided question (nish-reserved) -> no unit start
# =============================================================================
: >"$calls"
printf '60\tdecided\tsomeone\n' >"$scratch/qcands2"
export QUESTION_CANDIDATES="$scratch/qcands2"
"$auditor_bin" >"$scratch/out2" 2>"$scratch/err2"
grep -q "start pi-audit@" "$calls" && fail "decided question: should not start any audit unit"
ok "already-decided (nish-reserved) question -> skipped, no unit start"

# =============================================================================
# 3. all votes present -> pi-audit-tally called (question route)
# =============================================================================
: >"$calls"
printf '70\tundecided\tsomeone\n' >"$scratch/qcands3"
export QUESTION_CANDIDATES="$scratch/qcands3"
d="$AUDIT_STATE_DIR/demo/70"
mkdir -p "$d"
for role in devin free-glm senior; do
  jq -n --arg r "$role" --arg v NISH --arg reason "reserved: money, decided already no" \
    '{role:$r,verdict:$v,reason:$reason,at:"2026-09-08T00:00:00Z"}' >"$d/$role.vote"
done
"$auditor_bin" >"$scratch/out3" 2>"$scratch/err3"
grep -q 'all votes present' "$scratch/err3" || { echo "--- err3 ---"; cat "$scratch/err3"; fail "question: did not detect all votes present"; }
grep -q "add-label nish-reserved" "$gh_calls" || { echo "--- gh_calls ---"; cat "$gh_calls"; fail "question: tally did not route NISH -> nish-reserved"; }
ok "all votes present -> tally routes NISH verdict to nish-reserved"

echo "PASS: tests/fleet-heartbeat-auditor-question.test.sh"
