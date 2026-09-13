#!/usr/bin/env bash
# tests/pi-audit-run-product-repo-reality.test.sh
#
# fleet-ops#3966: an escalate-senior issue filed by the CI failure escalation
# bridge (fleet-ops#221) names the failing PRODUCT repo in its body
# (`- **Repo:** `Nishfleet/0509``), which is usually NOT the escalation repo
# (fleet-ops) the issue lives in. Before this fix, build_packet() only fetched
# the escalation repo's reality, so the three senior auditors never saw the
# product repo's open issues/PRs and admitted an already-owned product failure
# (the live 0509#1752 duplicate that filed fleet-ops#3966). The fix appends the
# named product repo's open issues/PRs/merged PRs to the auditor packet so a
# duplicate owner is visible and the panel can FAIL the duplicate.
#
# This test stubs gh, pi, and seatlib, dumps the assembled packet via the
# PI_DUMP_PACKET seam, and asserts:
#   - the product repo's reality section is present when the body names one,
#   - it is NOT present when the body names no product repo (regression guard),
#   - it is NOT present when the named product repo equals the escalation repo.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/pi-audit-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t pi-audit-run-product-repo.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME" "$scratch/state"

# --- fake gh: returns distinct issue/PR lists per repo so the test can tell
# which repo's reality landed in the packet. The candidate issue body is
# controlled by $CANDIDATE_BODY so each scenario can name a different repo.
gh_fake="$scratch/gh"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *"issue view"*"--json"*)
    printf '%s\n' "${CANDIDATE_BODY:-{\"title\":\"esc\",\"body\":\"no repo named\",\"labels\":[]}}"
    exit 0
    ;;
  *"issue list"*)
    # Echo the -R target repo slug so the test can attribute the call.
    repo=$(printf '%s\n' "$*" | sed -nE 's/.*-R[[:space:]]+Nishfleet\/([^[:space:]]+).*/\1/p')
    if [[ "$repo" == "0509" ]]; then
      printf '[{"number":1752,"title":"fix(deploy): Deploy production red"}]\n'
    else
      printf '[{"number":3957,"title":"escalate-senior wrapper"}]\n'
    fi
    exit 0
    ;;
  *"pr list"*)
    repo=$(printf '%s\n' "$*" | sed -nE 's/.*-R[[:space:]]+Nishfleet\/([^[:space:]]+).*/\1/p')
    if [[ "$repo" == "0509" ]]; then
      printf '[{"number":84,"title":"0509 product PR"}]\n'
    else
      printf '[{"number":12,"title":"fleet-ops PR"}]\n'
    fi
    exit 0
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$gh_fake"

# --- fake pi: dumps the assembled packet to PI_DUMP_PACKET -------------------
pi_fake="$scratch/pi"
cat >"$pi_fake" <<'FAKE'
#!/usr/bin/env bash
if [[ -n "${PI_DUMP_PACKET:-}" ]]; then
  cat >"$PI_DUMP_PACKET"
else
  cat >/dev/null
fi
printf 'PASS\nNo duplicate; durable fix advances the north star.\n'
FAKE
chmod +x "$pi_fake"

# --- fake seatlib: minimal, one usable seat --------------------------------
seat_lib="$scratch/seatlib.sh"
cat >"$seat_lib" <<'LIB'
load_seat_caps() { :; }
enumerate_seats() { printf '%s\t%s\t-\t1\n' devin glm-5-2; }
class_of() { printf 'prepaid-quota\n'; }
model_cap() { printf '1\n'; }
seat_usable() { return 0; }
seat_ledger_path() { printf '/dev/null\n'; }
LIB

prompt="$scratch/auditor.md"
printf '# Senior auditor\n\nPASS\n<reason>\n\nFAIL\n<reason>\n' >"$prompt"

plan="$scratch/plan.md"
printf '# Decisions ledger\n- north-star: beat the customer edge AI\n' >"$plan"

state_dir="$scratch/audit-state"
mkdir -p "$state_dir"

export AUDIT_GH="$gh_fake"
export PI_BIN="$pi_fake"
export PI_PACKET_SEAT_LIB="$seat_lib"
export AUDIT_PROMPT="$prompt"
export AUDIT_PLAN_FILE="$plan"
export AUDIT_STATE_DIR="$state_dir"
export AUDIT_DEVIN_SEAT='devin:glm-5-2'

packet="$scratch/packet.md"

# -----------------------------------------------------------------------------
# Scenario 1: body names a product repo (0509) different from the escalation
# repo (fleet-ops). The packet MUST include 0509's reality (issue #1752) so
# the auditors can see the already-owned product fix.
# -----------------------------------------------------------------------------
rm -rf "$state_dir"; mkdir -p "$state_dir"; : >"$packet"
export CANDIDATE_BODY='{"title":"[escalate-senior] 0509: Deploy production failing","body":"<!-- escalate-sig: abc -->\n\nGitHub-plane failure escalation.\n\n## Failure context\n- **Repo:** `Nishfleet/0509`\n- **Workflow:** `Deploy production`\n","labels":[]}'
PI_DUMP_PACKET="$packet" bash "$bin" 'fleet-ops--3966--devin' >/dev/null 2>&1 || true

grep -q 'Named product repo reality (Nishfleet/0509)' "$packet" \
  || fail "scenario1: packet must include the named product repo reality section: $(cat "$packet")"
grep -q '#1752: fix(deploy): Deploy production red' "$packet" \
  || fail "scenario1: packet must list 0509's open issue #1752: $(cat "$packet")"
grep -q '0509 product PR' "$packet" \
  || fail "scenario1: packet must list 0509's open PRs: $(cat "$packet")"
ok "scenario1: packet includes the named product repo (0509) reality with its open issue #1752"

# -----------------------------------------------------------------------------
# Scenario 2: body names NO product repo. The packet must NOT carry a product
# repo reality section (regression guard — do not invent a repo).
# -----------------------------------------------------------------------------
rm -rf "$state_dir"; mkdir -p "$state_dir"; : >"$packet"
export CANDIDATE_BODY='{"title":"escalation","body":"no repo named here","labels":[]}'
PI_DUMP_PACKET="$packet" bash "$bin" 'fleet-ops--5000--devin' >/dev/null 2>&1 || true

! grep -q 'Named product repo reality' "$packet" \
  || fail "scenario2: packet must NOT include a product repo section when none is named: $(cat "$packet")"
ok "scenario2: no product repo section when the body names none"

# -----------------------------------------------------------------------------
# Scenario 3: body names the SAME repo as the escalation repo (fleet-ops).
# The packet must NOT duplicate the reality section (the escalation repo's
# reality is already fetched above).
# -----------------------------------------------------------------------------
rm -rf "$state_dir"; mkdir -p "$state_dir"; : >"$packet"
export CANDIDATE_BODY='{"title":"escalation","body":"## Failure context\n- **Repo:** `Nishfleet/fleet-ops`\n","labels":[]}'
PI_DUMP_PACKET="$packet" bash "$bin" 'fleet-ops--5001--devin' >/dev/null 2>&1 || true

! grep -q 'Named product repo reality' "$packet" \
  || fail "scenario3: packet must NOT duplicate reality when product repo == escalation repo: $(cat "$packet")"
ok "scenario3: no duplicate reality section when the named repo equals the escalation repo"

echo "all pi-audit-run product-repo-reality cases passed"
