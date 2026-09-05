#!/usr/bin/env bash
# tests/worker-prompt-manager-mode.test.sh
#
# fleet-ops#3274 (child of #3140): when the packet's first line is
# `difficulty: heavy` or `difficulty: keystone` (written by the intake tick
# from the issue's labels/body), the pi-issue worker runs as MANAGER — it
# plans phases, delegates each to a fresh stock `worker` subagent, reviews
# each phase diff with the stock `reviewer`, ticks `.fleet/plan.md`, and
# ships the PR. Light issues stay flat.
#
# This is a prompt-only change (no new bin/ file — the issue forbids that by
# design via research-before-build-check). The replay drill:
#   1. grep-locks every manager-mode directive into prompts/worker.md,
#   2. rebuilds a packet the way `lib/pi-intake-tick.sh` does (difficulty
#      header + worker.md + TARGET) for heavy, keystone, and light, and
#      asserts the header is line 1 and the manager section keys off it,
#   3. asserts the stock subagent pieces the section names actually exist
#      on disk (so the prompt never points at a missing file),
#   4. CI host: hosted from tests/pi-issue-start.test.sh (fleet-ops#82 —
#      workers have no Workflows permission, so no new ci.yml line).
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
prompt="$repo_root/prompts/worker.md"
tick="$repo_root/lib/pi-intake-tick.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$prompt" ]] || fail "missing $prompt"
[[ -f "$tick" ]]   || fail "missing $tick"

# --- 1. manager-mode directive grep-locks -----------------------------------
grep -qF 'Manager mode (heavy|keystone) — fleet-ops#3274' "$prompt" \
  || fail "worker.md must carry the Manager mode (heavy|keystone) header (fleet-ops#3274)"
ok "manager-mode header present"

grep -qF '`difficulty: heavy`, `difficulty: keystone`, or `difficulty: light`' "$prompt" \
  || fail "worker.md must key manager mode off the packet's difficulty header line"
ok "keys off the difficulty header"

grep -qF 'you run as MANAGER' "$prompt" \
  || fail "worker.md must state the worker runs as MANAGER for heavy|keystone"
ok "names the MANAGER role"

grep -qF 'Light issues' "$prompt" \
  || fail "worker.md must keep light issues flat (skip manager mode)"
ok "light issues stay flat"

# (1) plan into .fleet/plan.md
grep -qF '.fleet/plan.md' "$prompt" \
  || fail "worker.md must write the phased checklist to .fleet/plan.md"
grep -qF 'Use planner' "$prompt" \
  || fail "worker.md must Use planner to write the plan"
grep -qF '<= 6 phases' "$prompt" \
  || fail "worker.md must cap the plan at <= 6 phases"
ok "(1) plan into .fleet/plan.md with planner, <= 6 phases"

# (2) fresh worker per phase with handoff
grep -qF 'FRESH `worker` subagent' "$prompt" \
  || fail "worker.md must spawn a FRESH worker subagent per phase"
grep -qF 'Complete phase N extremely well' "$prompt" \
  || fail "worker.md must hand the worker the 'Complete phase N extremely well' task"
grep -qF 'previous phase'"'"'s final message' "$prompt" \
  || fail "worker.md must pass the previous phase's final message as handoff"
ok "(2) fresh worker per phase with written handoff"

# (3) reviewer on phase diff, one retry
grep -qF 'Use reviewer' "$prompt" \
  || fail "worker.md must Use reviewer on the phase diff"
grep -qF 'one retry per phase' "$prompt" \
  || fail "worker.md must cap act-on findings at one fresh worker retry per phase"
ok "(3) reviewer on phase diff, one retry"

# (4) tick + commit per phase
grep -qF '`- [x]`' "$prompt" \
  || fail "worker.md must tick boxes (- [x]) in plan.md"
grep -qF 'commit after each phase' "$prompt" \
  || fail "worker.md must commit after each phase"
ok "(4) tick boxes and commit per phase"

# (5) manager opens PR + arms auto-merge
grep -qF 'Manager opens the PR and arms auto-merge' "$prompt" \
  || fail "worker.md must have the manager open the PR and arm auto-merge"
ok "(5) manager opens PR and arms auto-merge"

# constraints
grep -qF '<= 8 per call' "$prompt" \
  || fail "worker.md must batch subagent calls at <= 8 per call"
grep -qF 'Never fork the stock subagent extension' "$prompt" \
  || fail "worker.md must forbid forking the stock subagent extension to raise the constant"
ok "constraint: batch <= 8 per call, no fork"

grep -qF 'prompts/implement.md' "$prompt" \
  || fail "worker.md must name the stock prompts/implement.md workflow"
grep -qF 'prompts/implement-and-review.md' "$prompt" \
  || fail "worker.md must name the stock prompts/implement-and-review.md workflow"
grep -qF 'prompts/scout-and-plan.md' "$prompt" \
  || fail "worker.md must name the stock prompts/scout-and-plan.md workflow"
grep -qF 'does NOT re-implement any stock prompt or the plan format' "$prompt" \
  || fail "worker.md must forbid re-implementing stock prompts/plan format"
grep -qF 'A PR that adds a new `bin/` file for this fails' "$prompt" \
  || fail "worker.md must state a new bin/ file fails research-before-build-check"
ok "constraint: stock pieces only, no new bin/"

grep -qF 'Stall rule (both levels)' "$prompt" \
  || fail "worker.md must carry the stall rule at both levels"
grep -qF 'stalled: phase N' "$prompt" \
  || fail "worker.md must name the stalled: phase N note shape"
grep -qF 'the manager decides' "$prompt" \
  || fail "worker.md must let the manager amend the plan (implementer proposes, manager decides)"
ok "constraint: stall rule at both levels"

grep -qF "Wording: 'extremely well', never 'perfect'." "$prompt" \
  || fail "worker.md must lock the 'extremely well' wording in manager mode"
ok "constraint: 'extremely well' wording"

# spawn-guard reconciliation: stock planner/worker/reviewer are allowed
grep -qF 'planner/worker/reviewer are NOT those — they are allowed' "$prompt" \
  || fail "worker.md must reconcile the depth-1 spawn-guard with stock subagents"
ok "spawn-guard reconciled with stock subagents"

# --- 2. packet replay drill (heavy / keystone / light) ----------------------
scratch="$(mktemp -d -t worker-prompt-manager-mode.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Rebuild the packet the way lib/pi-intake-tick.sh does: difficulty header,
# then worker.md, then a blank line, then the TARGET line. The tick emits the
# header for every issue via issue_difficulty(); we only assert the shape.
build_packet() {
  local diff="$1" out="$2"
  {
    echo "difficulty: $diff"
    cat "$prompt"
    echo
    echo "TARGET: repo Nishfleet/fleet-ops issue 3274 unit pi-issue-fleet-ops-3274"
  } > "$out"
}

for d in heavy keystone light; do
  build_packet "$d" "$scratch/$d.in"
  hdr=$(head -1 "$scratch/$d.in")
  [[ "$hdr" == "difficulty: $d" ]] \
    || fail "packet header for $d must be 'difficulty: $d' (got '$hdr')"
  # worker.md body follows the header
  sed -n '2p' "$scratch/$d.in" | grep -q '^# Pi fleet issue worker' \
    || fail "worker.md body must follow the difficulty header for $d"
done
ok "packet replay: difficulty header is line 1, worker.md follows (heavy/keystone/light)"

# Heavy and keystone packets must contain the manager-mode trigger wording;
# the light packet must still contain the flat Steps (so light did not get
# deleted). All three carry the manager section (it is gated by the header,
# not by absence of the text), so assert the section is present in each and
# that the flat Steps survive.
for d in heavy keystone light; do
  grep -qF 'Manager mode (heavy|keystone) — fleet-ops#3274' "$scratch/$d.in" \
    || fail "$d packet lost the manager-mode section"
  grep -qF 'Steps:' "$scratch/$d.in" \
    || fail "$d packet lost the flat Steps section (light must still work)"
done
ok "all three packets carry manager section + flat Steps"

# --- 3. stock subagent pieces the prompt names must exist on disk -----------
for f in \
  ~/.pi/agent/agents/planner.md \
  ~/.pi/agent/agents/worker.md \
  ~/.pi/agent/agents/reviewer.md \
  ~/.pi/agent/prompts/implement.md \
  ~/.pi/agent/prompts/implement-and-review.md \
  ~/.pi/agent/prompts/scout-and-plan.md ; do
  [[ -f "$f" ]] || fail "stock subagent piece the prompt names is missing: $f"
done
ok "stock planner/worker/reviewer agents + workflow prompts exist on disk"

# The tick still emits the difficulty header (the trigger the manager section
# keys off). Lock the wire so a refactor cannot silently drop it.
grep -qF 'difficulty="$(issue_difficulty' "$tick" \
  || fail "lib/pi-intake-tick.sh must still capture difficulty via issue_difficulty()"
grep -qF 'echo "difficulty: $difficulty"' "$tick" \
  || fail "lib/pi-intake-tick.sh must still emit 'difficulty: $difficulty' as the packet header"
ok "tick still emits the difficulty header the manager section keys off"

# --- 4. CI host (fleet-ops#82: no new workflow line) ------------------------
ci_yml="$repo_root/.github/workflows/ci.yml"
host="$repo_root/tests/pi-issue-start.test.sh"
listed=0
hosted=0
grep -Fq 'bash tests/worker-prompt-manager-mode.test.sh' "$ci_yml" && listed=1
grep -Fq 'bash "$here/worker-prompt-manager-mode.test.sh"' "$host" && hosted=1
if [[ "$listed" -eq 0 && "$hosted" -eq 0 ]]; then
  fail "worker-prompt-manager-mode.test.sh has no CI host (fleet-ops#82): list it in ci.yml or invoke it from pi-issue-start.test.sh"
fi
ok "CI host exists (ci.yml listed=$listed pi-issue-start hosted=$hosted)"

# Empty-host drill: an empty ci.yml + empty host must miss both, so the
# check above is not vacuously true.
empty="$(mktemp -d)"
trap 'rm -rf "$scratch" "$empty"' EXIT INT TERM
: >"$empty/ci.yml"
: >"$empty/host.test.sh"
empty_listed=0
empty_hosted=0
grep -Fq 'bash tests/worker-prompt-manager-mode.test.sh' "$empty/ci.yml" && empty_listed=1
grep -Fq 'bash "$here/worker-prompt-manager-mode.test.sh"' "$empty/host.test.sh" && empty_hosted=1
[[ "$empty_listed" -eq 0 && "$empty_hosted" -eq 0 ]] \
  || fail "empty-host drill must miss both hosts (listed=$empty_listed hosted=$empty_hosted)"
ok "empty-host drill trips (neither host matches empty files)"

echo "PASS: worker-prompt-manager-mode (fleet-ops#3274)"
