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
# 2026-09-18: the pstack playbook rule is a per-run invariant, so it moved
# from prompts/worker.md to the repo AGENTS.md that Pi loads as context.
prompt="$repo_root/AGENTS.md"
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

grep -q 'Claim branch' "$prompt" \
  || fail "worker.md must keep the claim branch as fleet-owned"
ok "keeps claim branch"

grep -q 'Ignore pstack babysit, shipping, orchestrate, autopilot-' "$prompt" \
  || fail "worker.md must skip Graphite playbooks"
ok "skips Graphite babysit/shipping/orchestrate/autopilot"

# Nishfleet/0509#3622 (the fix now lives in prompts/intake.md step 2): the
# fleet-wide capacity count must cover BOTH live states. `pi-issue@*.service`
# is Type=oneshot, so a RUNNING worker sits in `activating` for the entire
# ExecStart and only reaches `active` at completion — a bare `--state=active`
# count therefore reads 0 while the fleet is full, `slots = min(3, 8 - running)`
# never hits 0, and the cap silently never fires. Live-proven on this host
# 2026-09-18: 12 workers mid-run, old command 0, new command 12. This is the
# regression lock the fix landed without (fleet-ops#366 mechanical-fix rule).
grep -q -- "--state=active,activating" "$intake" \
  || fail "intake.md capacity count must use --state=active,activating (0509#3622)"
if grep -q -- "--state=active --no-legend" "$intake"; then
  fail "intake.md must not count with bare --state=active — it misses activating oneshot workers (0509#3622)"
fi
ok "intake capacity count covers activating oneshot workers"

# Second cut 2026-09-18: the packet is assembled by pi-issue@.service's
# ExecStart, not by intake.md — intake starts the unit and the unit builds
# the prompt. Assert the unit still feeds worker.md to pi.
unit="$repo_root/systemd/pi-issue@.service"
grep -q "echo \"/worker " "$unit" \
  || fail "pi-issue@.service must invoke the /worker prompt template it pipes to pi"
ok "unit invokes the /worker prompt template"

grep -q '## Rejection log' "$adoption" \
  || fail "docs/pstack-adoption.md must carry a Rejection log (prior-art gate)"
ok "adoption doc has a Rejection log"

# fleet-ops#82: CI host lock. Workers cannot add a verify-command line.
# This file must stay listed in ci.yml OR invoked from a test that already
# is (currently pi-issue-start.test.sh).
ci_yml="$repo_root/.github/workflows/ci.yml"
# pi-issue-start.test.sh was deleted with bin/pi-issue-start (2026-09-18
# second cut); ci.yml is the host now. Probe a file that exists so the
# grep below reports "not hosted" instead of erroring on a missing path.
host="$repo_root/tests/worker-prompt-size-ceiling.test.sh"
listed=0
hosted=0
grep -Fq 'bash tests/pstack-worker-prompt.test.sh' "$ci_yml" && listed=1
grep -Fq 'bash "$here/pstack-worker-prompt.test.sh"' "$host" && hosted=1
if [[ "$listed" -eq 0 && "$hosted" -eq 0 ]]; then
  fail "pstack-worker-prompt.test.sh has no CI host (fleet-ops#82): list it in ci.yml"
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
