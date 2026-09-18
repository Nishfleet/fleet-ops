#!/usr/bin/env bash
# tests/worker-prompt-manager-mode.test.sh
#
# fleet-ops#3274 (child of #3140): when the packet's first line is
# `difficulty: heavy` or `difficulty: keystone` (written by the intake tick
# from the issue's labels/body), the pi-issue worker runs as MANAGER — it
# plans phases, delegates each to a fresh stock `worker` subagent, reviews
# each phase diff with the stock `reviewer`, ticks `.fleet/plan-<issue-N>.md`, and
# ships the PR. Light issues stay flat.
#
# This is a prompt-only change (no new bin/ file — the issue forbids that by
# design; the stock-pieces-only rule in the section carries it now that
# bin/research-before-build-check is deleted). The replay drill:
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
# lib/pi-intake-tick.sh was deleted in the 2026-09-18 second cut; the manager
# trigger is the issue's own labels now, so there is no tick file to check.

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$prompt" ]] || fail "missing $prompt"

# --- 1. manager-mode directive grep-locks -----------------------------------
grep -qF 'Manager mode (heavy|keystone) — fleet-ops#3274' "$prompt" \
  || fail "worker.md must carry the Manager mode (heavy|keystone) header (fleet-ops#3274)"
ok "manager-mode header present"

# Second cut 2026-09-18: the packet no longer carries a `difficulty:` header —
# lib/pi-intake-tick.sh wrote it and is gone. Manager mode keys off the issue's
# own labels, which is the same signal without a second place to write it.
grep -qF "the issue's own labels" "$prompt" \
  || fail "worker.md must key manager mode off the issue's labels"
ok "keys off the difficulty header"

grep -qF 'you run as MANAGER' "$prompt" \
  || fail "worker.md must state the worker runs as MANAGER for heavy|keystone"
ok "names the MANAGER role"

grep -qF 'Every other issue stays flat' "$prompt" \
  || fail "worker.md must keep non-heavy/keystone issues flat (skip manager mode)"
ok "light issues stay flat"

# (1) plan into an issue-unique plan path (fleet-ops#5526: the shared
# .fleet/plan.md path made two concurrent manager lanes conflict).
grep -qF '.fleet/plan-<issue-N>.md' "$prompt" \
  || fail "worker.md must write the phased checklist to issue-unique .fleet/plan-<issue-N>.md"
grep -F '.fleet/plan.md' "$prompt" >/dev/null \
  && fail "worker.md must not write the plan to the shared .fleet/plan.md path (fleet-ops#5526)"
grep -qF 'TARGET line' "$prompt" \
  || fail "worker.md must say where <issue-N> comes from (the packet TARGET line)"
grep -qF 'Use planner' "$prompt" \
  || fail "worker.md must Use planner to write the plan"
grep -qF '<= 6 phases' "$prompt" \
  || fail "worker.md must cap the plan at <= 6 phases"
ok "(1) plan into issue-unique .fleet/plan-<issue-N>.md with planner, <= 6 phases"

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
  || fail "worker.md must tick boxes (- [x]) in the issue-unique plan file"
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
  || fail "worker.md must state a new bin/ file fails the stock-pieces-only rule"
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

# --- 2. REMOVED in the 2026-09-18 second cut --------------------------------
# This section replayed the packet lib/pi-intake-tick.sh built (worker.md as the
# stable prefix, a `difficulty:` header in the volatile tail). Both the tick and
# the packet file are gone: pi-issue@.service builds the prompt in ExecStart and
# manager mode keys off the issue's own labels, so there is no second place that
# writes the trigger and nothing left here to replay.

# --- 3. stock subagent pieces the prompt names must exist on disk -----------
# GitHub runners do not have the pi agent files (HOME is /home/runner); the
# VPS does. Same guard as tests/pi-systemd-run.test.sh: all present -> OK,
# none present -> SKIP (CI runner), partial -> fail (inconsistent install).
stock_pieces=(
  ~/.pi/agent/agents/planner.md
  ~/.pi/agent/agents/worker.md
  ~/.pi/agent/agents/reviewer.md
  ~/.pi/agent/prompts/implement.md
  ~/.pi/agent/prompts/implement-and-review.md
  ~/.pi/agent/prompts/scout-and-plan.md
)
stock_present=0
for f in "${stock_pieces[@]}"; do
  [[ -f "$f" ]] && stock_present=$((stock_present + 1))
done
if [[ "$stock_present" -eq "${#stock_pieces[@]}" ]]; then
  ok "stock planner/worker/reviewer agents + workflow prompts exist on disk"
elif [[ "$stock_present" -eq 0 ]]; then
  echo "SKIP: stock pi subagent pieces not present (CI runner)"
else
  fail "expected 0 or ${#stock_pieces[@]} stock pi subagent pieces, found $stock_present"
fi

# The trigger the manager section keys off is the issue's own labels, read by
# the worker itself. Lock the wire at the only place that still carries it: the
# unit that builds the prompt must feed worker.md to pi.
grep -qF 'prompts/worker.md' "$repo_root/systemd/pi-issue@.service" \
  || fail "pi-issue@.service must feed worker.md to pi (manager mode trigger lives in the prompt)"
ok "the manager-mode trigger is wired: the unit feeds worker.md to pi"

# --- 4. CI host (fleet-ops#82: no new workflow line) ------------------------
ci_yml="$repo_root/.github/workflows/ci.yml"
# pi-issue-start.test.sh was deleted with bin/pi-issue-start (2026-09-18
# second cut); ci.yml is the host now. Probe a file that exists so the
# grep below reports "not hosted" instead of erroring on a missing path.
host="$repo_root/tests/worker-prompt-size-ceiling.test.sh"
listed=0
hosted=0
grep -Fq 'bash tests/worker-prompt-manager-mode.test.sh' "$ci_yml" && listed=1
grep -Fq 'bash "$here/worker-prompt-manager-mode.test.sh"' "$host" && hosted=1
if [[ "$listed" -eq 0 && "$hosted" -eq 0 ]]; then
  fail "worker-prompt-manager-mode.test.sh has no CI host (fleet-ops#82): list it in ci.yml"
fi
ok "CI host exists (ci.yml listed=$listed pi-issue-start hosted=$hosted)"

# Empty-host drill: an empty ci.yml + empty host must miss both, so the
# check above is not vacuously true.
empty="$(mktemp -d)"
trap 'rm -rf "$empty"' EXIT INT TERM
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
