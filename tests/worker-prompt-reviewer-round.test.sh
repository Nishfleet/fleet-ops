#!/usr/bin/env bash
# tests/worker-prompt-reviewer-round.test.sh
#
# fleet-ops#3708 (part 1/2 of #3264, child of #3127): product PRs (0509,
# siterep-public, inish-site; fleet-ops exempt) get exactly ONE reviewer
# round before the auto-merge arm, run on the first usable entry of
# `senior_seats_in_order` (#3121), passed explicitly to the reviewer
# subagent (the extension inherits the parent seat by default), never the
# worker's own seat. Findings land in the review-adjudication buckets; Act-on
# items are fixed before the arm; one round only, no loops. Part 2/2 owns the
# no-capable-seat fallback — this test does not require it.
#
# This is a prompt-contract lock (same shape as exec-review-prompt.test.sh)
# PLUS a replay drill: a fake product PR + fake reviewer verdict carrying one
# Act-on item is replayed through the two arm states. The arm must refuse
# until the Act-on item is resolved AND the PR body carries the four buckets
# AND the reviewer seat name. The drill's gate is the exact set of contracts
# step 8 mandates, so it fails before the edit ships and passes after.
#
# Invariants:
#   1. worker.md step 8 names the reviewer round with the exact reviewer prompt.
#   2. The auto-merge arm is step 9, so the round precedes the arm.
#   3. The reviewer seat comes from `senior_seats_in_order`
#      (cursor/cursor-grok-4.6-high first), passed explicitly to the subagent,
#      never the worker's own seat.
#   4. The four review-adjudication buckets are named; Act-on items are fixed
#      before the arm; one round only, no loops.
#   5. 0509, siterep-public, inish-site are marked `product` in
#      config/intake-repos.json; fleet-ops is not.
#   6. Replay drill: the arm refuses until the Act-on item is resolved AND the
#      PR body carries the four buckets AND the reviewer seat name.
#   7. CI host exists (fleet-ops#82): this file is listed in ci.yml OR invoked
#      from a test that already is (pi-issue-start.test.sh).
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
prompt="$repo_root/prompts/worker.md"
intake="$repo_root/config/intake-repos.json"
seats="$repo_root/config/seat-caps.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$prompt" ]] || fail "missing $prompt"
[[ -f "$intake" ]] || fail "missing $intake"
[[ -f "$seats" ]]  || fail "missing $seats"

# --- 1. reviewer round named with the exact reviewer prompt -----------------
grep -q 'Use reviewer to review the diff origin/main...HEAD against' "$prompt" \
  || fail "worker.md must carry the reviewer prompt (fleet-ops#3708)"
ok "worker.md carries the reviewer prompt"

# --- 2. reviewer round (step 8) precedes the auto-merge arm (step 9) --------
reviewer_line=$(grep -n '^8\. Reviewer round' "$prompt" | head -1 | cut -d: -f1)
arm_line=$(grep -n '^9\. Arm' "$prompt" | head -1 | cut -d: -f1)
[[ -n "$reviewer_line" ]] || fail "worker.md must have a step 8 'Reviewer round'"
[[ -n "$arm_line" ]] || fail "worker.md must have a step 9 'Arm'"
[[ "$reviewer_line" -lt "$arm_line" ]] \
  || fail "reviewer round (line $reviewer_line) must precede the arm (line $arm_line)"
ok "reviewer round (step 8) precedes the auto-merge arm (step 9)"

# --- 3. senior seat: senior_seats_in_order, explicit pass, not worker's seat -
grep -q 'senior_seats_in_order' "$prompt" \
  || fail "worker.md must source the reviewer seat from senior_seats_in_order (fleet-ops#3121)"
grep -q 'cursor/cursor-grok-4.6-high first' "$prompt" \
  || fail "worker.md must name cursor/cursor-grok-4.6-high first in the senior ladder"
grep -q 'passed explicitly' "$prompt" \
  || fail "worker.md must pass the reviewer seat explicitly to the subagent call"
grep -qE "never the worker's own seat|never your own seat" "$prompt" \
  || fail "worker.md must forbid running the reviewer on the worker's own seat"
ok "reviewer seat: senior_seats_in_order (cursor/cursor-grok-4.6-high first), passed explicitly, not the worker's own seat"

# --- 4. review-adjudication buckets; Act-on fixed before arm; one round ------
for bucket in 'Act on' Consider Noted 'Dismissed-with-reason'; do
  grep -q "$bucket" "$prompt" || fail "worker.md must name review-adjudication bucket '$bucket'"
done
grep -q 'fix Act-on items before arming' "$prompt" \
  || fail "worker.md must require Act-on items fixed before arming"
grep -q 'One round only, no loops' "$prompt" \
  || fail "worker.md must cap the reviewer round at one (no loops)"
ok "review-adjudication buckets named; Act-on fixed before arm; one round only"

# --- 5. product marking in intake-repos.json ---------------------------------
for repo in 0509 siterep-public inish-site; do
  python3 - "$intake" "$repo" <<'PY' || fail "product marking missing for $repo"
import json, sys
data = json.load(open(sys.argv[1]))
name = sys.argv[2]
rows = (data.get("repos") or []) + (data.get("deferred") or [])
if not any(r.get("name") == name and r.get("product") is True for r in rows):
    sys.exit(1)
PY
done
# fleet-ops is the control-plane exemption: it must NOT be marked product.
python3 - "$intake" <<'PY' || fail "fleet-ops must NOT be marked product (exempt)"
import json, sys
data = json.load(open(sys.argv[1]))
rows = (data.get("repos") or []) + (data.get("deferred") or [])
if any(r.get("name") == "fleet-ops" and r.get("product") is True for r in rows):
    sys.exit(1)
PY
ok "0509, siterep-public, inish-site marked product; fleet-ops exempt"

# --- 6. replay drill: arm refuses until Act-on resolved + 4 buckets + seat ----
# The reviewer seat name the prompt mandates is the first entry of
# senior_seats_in_order, read live from the config so the drill is coupled to
# the seat ladder (fleet-ops#3121), not a hardcoded string.
REVIEWER_SEAT="$(jq -r '.senior_seats_in_order[0]' "$seats")"
[[ -n "$REVIEWER_SEAT" ]] || fail "senior_seats_in_order[0] is empty in $seats"
grep -q "$REVIEWER_SEAT" "$prompt" \
  || fail "worker.md must name the first senior seat ($REVIEWER_SEAT)"

drill="$(mktemp -d)"
trap 'rm -rf "$drill"' EXIT

# gate_arm models the step-8 arm gate as the agent would apply it: arm is
# allowed only when the PR body carries the reviewer seat name AND all four
# review-adjudication buckets AND no unresolved Act-on item remains. This is a
# replay of the contract, not a re-implementation of the prompt.
gate_arm() {
  local body="$1"
  grep -qF "$REVIEWER_SEAT" "$body" || { echo "missing reviewer seat: $REVIEWER_SEAT"; return 1; }
  for bucket in '**Act on**' '**Consider**' '**Noted**' '**Dismissed-with-reason**'; do
    grep -qF "$bucket" "$body" || { echo "missing bucket: $bucket"; return 1; }
  done
  grep -qiF 'unresolved' "$body" && { echo "unresolved Act-on item remains"; return 1; }
  return 0
}

# Fake reviewer verdict carrying exactly one Act-on item, as the reviewer
# subagent lands it on the senior seat.
cat >"$drill/verdict.md" <<EOF
Reviewer: $REVIEWER_SEAT
- **Act on**: guard XXXX_UNDEFINED against an empty string before use.
- **Consider**: say how the fallback is tested.
- **Noted**: existing coverage is otherwise adequate.
- **Dismissed-with-reason**: the refactor is out of scope for this issue.
EOF
ok "fake reviewer verdict carries one Act-on item"

# State A: bare product-PR body — no reviewer seat, no buckets, Act-on
# unresolved. The arm must refuse.
cat >"$drill/body-a.md" <<'EOF'
What and why: <the smallest durable fix>

Closes #N
EOF
if gate_arm "$drill/body-a.md" >/dev/null; then
  fail "arm must refuse with no reviewer seat / no buckets / unresolved Act-on (State A)"
fi
ok "replay: arm refuses when the body lacks the reviewer seat and buckets and the Act-on is unresolved"

# State A2: reviewer seat + all four buckets present, but the Act-on item is
# still UNRESOLVED. The arm must STILL refuse (Act-on items are fixed before
# arming).
cat >"$drill/body-a2.md" <<EOF
What and why: <the smallest durable fix>

Reviewer: $REVIEWER_SEAT
- **Act on**: UNRESOLVED — guard XXXX_UNDEFINED against empty string.
- **Consider**: noted.
- **Noted**: existing coverage otherwise adequate.
- **Dismissed-with-reason**: refactor out of scope.

Closes #N
EOF
if gate_arm "$drill/body-a2.md" >/dev/null; then
  fail "arm must refuse while an Act-on item is UNRESOLVED (State A2)"
fi
ok "replay: arm refuses while the Act-on item is unresolved, even with buckets + seat"

# State B: reviewer seat + four buckets + Act-on item resolved. The arm is
# allowed.
cat >"$drill/body-b.md" <<EOF
What and why: <the smallest durable fix>

Reviewer: $REVIEWER_SEAT
- **Act on**: resolved — empty-string guard added in lib X; unit test covers it.
- **Consider**: noted.
- **Noted**: existing coverage otherwise adequate.
- **Dismissed-with-reason**: refactor out of scope.

Closes #N
EOF
if ! gate_arm "$drill/body-b.md"; then
  fail "arm must allow once the Act-on item is resolved and the body carries the four buckets + reviewer seat name (State B)"
fi
ok "replay: arm allows after the Act-on item is resolved and the body carries four buckets + reviewer seat name"

# --- 7. CI host (fleet-ops#82) ---------------------------------------------
# Workers have no Workflows permission, so this file cannot be added to ci.yml
# verify-command by a worker. It rides an existing CI-listed test instead
# (pi-issue-start.test.sh).
ci_yml="$repo_root/.github/workflows/ci.yml"
host="$repo_root/tests/pi-issue-start.test.sh"
listed=0
hosted=0
grep -Fq 'bash tests/worker-prompt-reviewer-round.test.sh' "$ci_yml" && listed=1
grep -Fq 'bash "$here/worker-prompt-reviewer-round.test.sh"' "$host" && hosted=1
if [[ "$listed" -eq 0 && "$hosted" -eq 0 ]]; then
  fail "worker-prompt-reviewer-round.test.sh has no CI host (fleet-ops#82): list it in ci.yml or invoke it from pi-issue-start.test.sh"
fi
ok "CI host exists (ci.yml listed=$listed pi-issue-start hosted=$hosted)"

# Empty-host drill: an empty ci.yml + empty host must miss both, proving the
# check is not trivially true.
empty="$(mktemp -d)"
trap 'rm -rf "$drill" "$empty"' EXIT
: >"$empty/ci.yml"
: >"$empty/host.test.sh"
empty_listed=0
empty_hosted=0
grep -Fq 'bash tests/worker-prompt-reviewer-round.test.sh' "$empty/ci.yml" && empty_listed=1
grep -Fq 'bash "$here/worker-prompt-reviewer-round.test.sh"' "$empty/host.test.sh" && empty_hosted=1
[[ "$empty_listed" -eq 0 && "$empty_hosted" -eq 0 ]] \
  || fail "empty-host drill must miss both hosts (listed=$empty_listed hosted=$empty_hosted)"
ok "empty-host drill trips (neither host matches empty files)"

echo "worker-prompt-reviewer-round: PASS"
