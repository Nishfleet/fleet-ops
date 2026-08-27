#!/usr/bin/env bash
# tests/pstack-worker-prompt.test.sh
#
# Locks the fleet-ops#1260 contract: pstack playbooks are the default
# worker discipline. Skills were installed and unused; the packet now
# points at upstream paths instead of forking them.
#
# Proven thing (step 0): this is the same grep-lock shape as
# tests/exec-review-prompt.test.sh. No new binary. pstack itself is
# consumed from ~/.pi/agent/skills/poteto-mode/playbooks/.
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
prompt="$repo_root/prompts/worker.md"
intake="$repo_root/prompts/intake.md"
adoption="$repo_root/docs/pstack-adoption.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$prompt" ]] || fail "missing $prompt"
[[ -f "$intake" ]] || fail "missing $intake"
[[ -f "$adoption" ]] || fail "missing $adoption"

grep -q 'pstack playbooks (fleet-ops#1260)' "$prompt" \
  || fail "worker.md must name pstack playbooks (fleet-ops#1260)"
ok "names pstack playbooks"

grep -q 'poteto-mode/playbooks/' "$prompt" \
  || fail "worker.md must point at upstream poteto-mode/playbooks/"
ok "points at upstream playbooks"

for book in bug-fix.md feature.md investigation.md perf-issue.md opening-a-pr.md; do
  grep -q "$book" "$prompt" || fail "worker.md must name $book"
done
ok "names bug-fix, feature, investigation, perf-issue, opening-a-pr"

grep -q 'Depth-1 spawn-guard' "$prompt" \
  || fail "worker.md must name the depth-1 spawn-guard"
grep -q 'do NOT spawn Task, arena, architect, swarm, or interrogate' "$prompt" \
  || fail "worker.md must forbid Task/arena/architect/swarm/interrogate spawn"
ok "depth-1 spawn-guard forbids fan-out"

grep -q 'bin/pi-salvage-worktree' "$prompt" \
  || fail "worker.md must keep salvage as fleet-owned"
grep -q 'Claim branch' "$prompt" \
  || fail "worker.md must keep the claim branch as fleet-owned"
ok "keeps claim branch and salvage"

grep -q 'Ignore pstack babysit, shipping, orchestrate, autopilot-' "$prompt" \
  || fail "worker.md must skip Graphite playbooks"
ok "skips Graphite babysit/shipping/orchestrate/autopilot"

grep -q 'cat /home/nish/.pi/agent/prompts/worker.md' "$intake" \
  || fail "intake.md must still cat worker.md into the packet"
ok "intake packet still cats worker.md"

grep -q '## Rejection log' "$adoption" \
  || fail "docs/pstack-adoption.md must carry a Rejection log (prior-art gate)"
ok "adoption doc has a Rejection log"

# fleet-ops#82: CI host lock. Workers cannot add a verify-command line.
# This file must stay listed in ci.yml OR invoked from a test that already
# is (currently pi-issue-start.test.sh).
ci_yml="$repo_root/.github/workflows/ci.yml"
host="$repo_root/tests/pi-issue-start.test.sh"
listed=0
hosted=0
grep -Fq 'bash tests/pstack-worker-prompt.test.sh' "$ci_yml" && listed=1
grep -Fq 'bash "$here/pstack-worker-prompt.test.sh"' "$host" && hosted=1
if [[ "$listed" -eq 0 && "$hosted" -eq 0 ]]; then
  fail "pstack-worker-prompt.test.sh has no CI host (fleet-ops#82): list it in ci.yml or invoke it from pi-issue-start.test.sh"
fi
ok "CI host exists (ci.yml listed=$listed pi-issue-start hosted=$hosted)"

empty=$(mktemp -d)
trap 'rm -rf "$empty"' EXIT
: >"$empty/ci.yml"
: >"$empty/host.test.sh"
empty_listed=0
empty_hosted=0
grep -Fq 'bash tests/pstack-worker-prompt.test.sh' "$empty/ci.yml" && empty_listed=1
grep -Fq 'bash "$here/pstack-worker-prompt.test.sh"' "$empty/host.test.sh" && empty_hosted=1
[[ "$empty_listed" -eq 0 && "$empty_hosted" -eq 0 ]] \
  || fail "empty-host drill must miss both hosts (listed=$empty_listed hosted=$empty_hosted)"
ok "empty-host drill trips (neither host matches empty files)"

echo "OK: worker.md routes pstack playbooks by default"
