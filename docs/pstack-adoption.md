# pstack adoption (fleet-ops#1260)

pstack (github.com/cursor/plugins pstack, by poteto) was installed on this
VPS on 2026-08-26 (`~/.cursor/rules/pstack-models.mdc`, Pi skills under
`~/.pi/agent/skills/`). Fleet flows never invoked it. Armed, never fired.

This file is Phase A (evaluate) plus the Phase C rejection log. Phase B is
the worker-prompt routing in `prompts/worker.md`.

Constraint: do not fork pstack. Point at the installed upstream files.

`architect skipped: depth-1 worker`. Two shapes: copy playbooks into this
repo, or point the packet at `~/.pi/agent/skills/poteto-mode/playbooks/`.
Copying loses. The copies would drift the next time upstream moves.

Throughput checkpoint:

- Blocking first steps: inventory vs upstream, then the prompt lock.
- Independent workstreams: n/a: one writer, prompt + test + this doc + the
  enforcement row must stay in sync.
- Shared mutable state: n/a: `claim/issue-1260` is exclusive.
- Smallest safe decomposition: one worker. Spawn-guard forbids a sibling
  lane running a second copy of the same packet.

## Inventory (2026-08-27, live vs upstream `cursor/plugins` main)

Upstream counts from the live tree: 24 workflow skill folders (README still
says 23; `make-bot-ui` is the extra), 21 `principle-*` skills, 22 named
playbooks plus `opening-a-pr.md` (called at the end of the others), 2
subagents (`agents/comment-sicko.md`, `agents/poteto-agent.md`).

Present on the Pi harness (`~/.pi/agent/skills/`):

- All 21 principles. SHA of `unslop` and `why` SKILL.md match upstream.
- Playbooks under `poteto-mode/playbooks/`: all 22 plus `opening-a-pr.md`.
  `bug-fix.md` and `feature.md` SHA-match upstream.
- Workflow skills: architect, arena, automate-me, blast-radius, bro,
  create-verification-skill, figure-it-out, how, interrogate,
  maintain-verification-skill, no-comments, poteto-mode, recall, reflect,
  setup-pstack, show-me-your-work, swarm, tdd, teach, technical-writing,
  typescript-best-practices, unslop, why.

Missing vs upstream:

- `make-bot-ui` (not used by fleet issue workers).
- `agents/` subagent prompts (Cursor Task fan-out; spawn-guard forbids).
- `docs/guide/` (human onboarding, not a worker packet).
- `automations/benny` (Slack; we use Telegram). Already skipped in the
  2026-08-20 standing-rule review.
- `poteto-mode/scripts/check-plan.mjs` (Cursor plan helper).

Drift (re-synced, fleet-ops#1311):

- `blast-radius/SKILL.md` upstream `b060df3ca858`, the vault copy
  `88274acde55a` is the house-adapted canonical, and all live harnesses
  (Claude, Codex, Pi) now symlink to that single vault copy.
  `unslop` and `why` were in the same real-dir state and were re-linked at
  the same time.
- The `fleet-skills-symlink-canary` compares the SHA-256 of every vault-listed
  house skill against each harness on every heartbeat tick, so a pstack install
  that leaves a real directory behind no longer silently diverges.

`~/.cursor/rules/pstack-models.mdc` sets every role to `inherit-parent` so
pstack cannot bypass the seat governor. That stays.

## Packet runs

Spawn-guard: this worker is depth-1. It cannot launch sibling issue units.
The three runs below are this lane applying the playbooks to real fleet
work, not a second worker rewriting the same issue.

### 1. Bug-fix playbook on PR #1195 / issue #1074 (retrospective)

`bug-fix.md` wants: reproduce on the matching surface, binary-search the
cause, smallest evidence-backed fix, failing repro before the fix, then
opening-a-pr.

What shipped: `lib/failed-command-flagged.py` plus
`tests/fleet-failed-command-flagged.test.sh` locking the live
`git show` error-literal false positive. That is reproduce-then-pass. The
fleet mechanical-fix rule (#366) is stricter than pstack here: a class
detector had to land in the same PR. pstack would have been happy with the
repro test alone and would have spent a subagent on a two-file diff.

Verdict truthfulness: the merged PR's claim ("this class is locked") is
true because the test replays the live snippet. pstack blast-radius would
have asked for that same replay. Packet template already had the proof
shape. The miss was that workers were never told to read `bug-fix.md`
before editing.

Winner: keep #366. Add the playbook pointer so the next failed-command
issue reproduces first instead of guessing.

### 2. Feature playbook on this issue (#1260) (live)

`feature.md` wants: `how` over the subsystem, architect, a four-item
checkpoint, then implementation.

`how`: intake writes the packet by catting `prompts/worker.md`
(`prompts/intake.md` step 3d). Repair units do not implement issues.
Nothing in that path named a playbook. `sr-pstack-review` claimed
"enforced" because the skill files existed. Installed is not invoked.

Implementation: one prompt section, one grep-lock test hosted by
`tests/pi-issue-start.test.sh` (workers cannot add a CI workflow line),
this doc, and the enforcement-row proof now names `prompts/worker.md`.

### 3. Review playbook on PR #1273 / issue #1146 (retrospective)

`opening-a-pr.md` plus `review-adjudication`. Skip babysit/shipping
(Graphite). Skip interrogate fan-out (depth-1).

PR #1273 landed the weekly fleet review timer, service, prompt, and
enforcement row for #1146. Review-adjudication buckets:

- Act on: heartbeat metric + absent-organ rule in the same PR. That is
  the standing pattern. It landed.
- Consider: whether Sunday-after-maintenance is the right cadence. Out of
  this packet.
- Noted: docs still claimed dead Hermes sweeps (#1145 class). The issue
  asked to fix that doc in the WFR work; check the merged diff if a later
  worker needs it.
- Dismissed-with-reason: pstack `interrogate` as the conference. #1146
  already has a five-lens senior conference. Replacing it with pstack
  arena/interrogate would be a fork of a fleet-specific ritual.

Verdict truthfulness: the PR body claims a WFR mechanism exists. The
timer unit and `tests/weekly-fleet-review.test.sh` are the proof. That
matches pstack prove-it-works and also matches #1134's "VERIFY by
re-running commands" idea.

## Overlaps

### #1134 independent evidence re-execution

Still open. pstack `principle-prove-it-works` and blast-radius's proof
ladder (asserted → cited → walked-through → script-ran → reproduced-live)
are the same job as a machine-readable VERIFY block plus a cheap checker
that re-runs it. #1134 is the fleet form: commands in the packet, a second
unit that executes them, mismatch overrides the worker. Do not replace
#1134 with a pstack skill pointer. The playbook tells the worker to write
proof; #1134 tells the fleet to not trust the worker's word.

### #1146 weekly fleet review / senior conference

pstack arena + interrogate + how-critics are a multi-model bakeoff inside
one Cursor session. #1146 is a weekly systemd ritual with five blind
lenses and a conference cap of five actions. Same instinct (several
seniors, not one self-grade), different runtime. Fleet workers cannot be
the arena. Keep #1146. Do not wire arena into `prompts/worker.md`.

## Phase B (shipped here)

`prompts/worker.md` now names the playbooks and the fleet adaptations.
Intake still cats that file into the packet, so every issue worker gets
them by default. `sr-pstack-review` proof now includes `prompts/worker.md`.

## Rejection log

Prior-art gate (#1250). What exists, what was tested, why it lost.

| Candidate | What exists | Why rejected |
|---|---|---|
| Fork pstack into `docs/` or `lib/` | Full plugin at `~/.pi/agent/skills/` and github.com/cursor/plugins pstack | Proven-extensions: consume upstream. Copies drift (`blast-radius` already has). |
| Wire arena / architect / swarm / interrogate as live fan-out | Skills installed; poteto-mode defaults to Task spawn | Depth-1 spawn-guard. Seat governor. `pstack-models.mdc` is inherit-parent on purpose. |
| Wire babysit / shipping / orchestrate / autopilot-* | Playbooks present | Graphite stack. Fleet already has systemd units, claim branches, salvage, auto-merge-arm. |
| Wire setup-pstack real model slugs | `~/.cursor/rules/pstack-models.mdc` | Would bypass pick_seat. Fable is orchestrator-only. grok cap 0. sol has no Pi transport. |
| Benny Slack automations | Upstream `automations/benny` | Slack. We use Telegram. Skipped 2026-08-20. |
| `make-bot-ui` | Upstream skill, not installed | No fleet issue worker builds a bot UI. |
| New `bin/pstack-dispatch` | Would pick a playbook in bash | Execution IS the review is agentic (#31). No-hand-built-orchestration. The prompt is the dispatcher. |
| Replace VERIFY / #1134 with pstack prove-it-works | Skill + principle installed | #1134 is an independent checker unit. A skill cannot override a worker's self-report. |
| Replace #1146 conference with pstack arena | arena/interrogate installed | Weekly WFR is a systemd ritual with a five-action cap, not an in-session bakeoff. |

Nothing in Phase C needs a new tool. The gap was invocation, not a missing
binary.
