# Skill proposals and prunes: no stock path fits (fleet-ops#9495, fleet-ops#9497, 2026-10-09)

The decision this page records: no stock, event-driven way to turn a session's
learning into a skill proposal exists on this fleet, and no stock, event-driven
way to prune an unused skill or repair a broken one either. Nothing is built to
replace either. The rule that follows lives in the vault's global standing rules
(`_system/shared-memory/global-standing-rules.md`, the one rules file every
agent follows) under "Skill ladder"; that file is the rule, this page is the
evidence.

This page is the paired record for both halves of the ladder, because
fleet-ops#9497 asked that additions and removals come from one mechanism. The
proposal half (#9495) is above; the prune half (#9497) is below.

## Why it was asked

The weekly gardener was cut on 2026-09-29 (fleet-ops#8954) and filed 0 skill
proposals in its life. fleet-ops#9495 asked for an event-driven replacement with
three guardrails: proposals only (never auto-merged), each citing the session it
came from, and fired by session end or handoff rather than a schedule.

## The four stock paths, checked 2026-10-09

Checked in the order the issue names them.

1. **Hermes `skills.creation_nudge_interval`** — set to `0` in the Hermes
   `config.yaml` (`skills.creation_nudge_interval`, with `skills.write_approval:
   true`); the shipped default is `10` (`hermes-agent/agent/agent_init.py:1369`
   and `:1371`). It is not session-end: it counts tool iterations since the last
   `skill_manage` (`agent/turn_iteration_prep.py:136-138`) and fires a background
   review after the turn once that count passes the interval
   (`agent/turn_finalizer.py:715-722`). The fork "costs ~30K tokens / event"
   (`agent/turn_finalizer.py:731-733`) and the trigger needs `skill_manage` in the
   tool list. **No**: Hermes-only, turn-counted rather than session-end, and its
   write path is a tool call, not a proposal that cites a session.

2. **Pi stock skills** — `pi-coding-agent/docs/skills.md` is 93 lines in five
   sections and covers only creating, loading, installing, frontmatter and
   validating a skill by hand. There is no proposal step. Pi's extension API has
   `session_shutdown` (`docs/extensions.md:59-60`), documented for releasing
   resources — that is a hand-built extension, which this repo's GLUE-ZERO rule
   bans (`docs/ARCHITECTURE.md`, "GLUE-ZERO": no new scripts, helpers, hooks or
   extensions, anywhere). **No stock path.**

3. **compound-engineering `ce-compound`** — the `/ce-compound` skill, from the
   compound-engineering Claude Code plugin (installed and enabled here), read at
   `skills/ce-compound/SKILL.md`. It writes one durable learning under
   `<root>/solutions/` for a solved and verified problem, and only when invoked
   as `/ce-compound`. It produces repo learnings, not skills. **Wrong artifact.**

4. **Claude Code stock memory** — the stock memory surface is auto-memory:
   a `memory/MEMORY.md` index plus one file per fact under each project's
   session dir (three such indexes on this host, all facts). It records facts,
   never skills. Claude Code 2.1.294 does ship a stock `propose_skills` tool
   ("Surface recurring multi-step procedures from this session as skill
   proposals. Render-only — calling this shows a review card in the conversation;
   it does not write any files or create the skill"), but it is gated by the
   org's user-created-skills feature and is not offered here: a live session was
   asked for it and reported no such tool. Even where offered it is interactive —
   a person saves from the card — so it cannot serve an unattended worker.
   **Not available, and not unattended.**

## The decision

Nothing is built. Three independent blocks, each enough on its own:

- The pro-dev path is a new component in its own repo (vault
  `global-standing-rules.md`, "Build and ship"). This worker's GitHub App token
  holds Contents/PRs/Issues write and Metadata read and no Administration, so it
  cannot create that repo.
- The demonstration the finish line asks for is a proposal PR to the vault
  skills-library, and the worker jail hides the GitHub login that reaches it:
  `gh api repos/nish3451/nish-vault` (the vault's own GitHub repo) answers 404. A
  vault proposal from a worker is not possible today.
- In-repo is not an option either: GLUE-ZERO bans new hooks and extensions, and
  the correction ladder puts a rule at rung 3.

So the rung-3 rule carries it. The rule text is in the vault
`_system/shared-memory/global-standing-rules.md` -> "Skill ladder"; this page
does not restate it.

## The prune half (fleet-ops#9497)

The manual prune of 2026-10-09 found 7 dead duplicates, 3 skills that were on but
unused, broken-but-useful skills, and ~50 Pi copies that were real directories
instead of symlinks. Nobody noticed until someone looked by hand.
fleet-ops#9497 asked for the event-driven replacement: count each skill's uses
over the last 30 days, propose a turn-off or a delete for a 0-use skill that
duplicates a kept one or does not fit the host, and repair broken-but-useful
skills. Proposals only, each citing its 30-day count and its session-log source.

### The stock paths for the counting, checked 2026-10-09

The counting itself has a stock source on this host, and this is where the prune
half differs from the proposal half. Measured over the trailing 30 days:

- **Claude Code session logs.** Every skill use is a `Skill` tool call in
  `~/.claude/projects/*/*.jsonl`. 35 such calls across 13 distinct skills.
  Countable, but nothing aggregates it.
- **Pi session logs.** Every skill use is a tool call whose arguments name a
  `.../skills/<name>/SKILL.md` path in `~/.pi/agent/sessions/*/*.jsonl`. 177
  such calls across 22 distinct skills. Countable, nothing aggregates it.
- **Pi's `available_skills` block.** It sits in the system prompt of every
  session, 2,904 messages across the 2,726 Pi session files of the last 30 days.
  That is the skill *listing*, not usage, so it cannot count uses. It is,
  however, the actual token cost the issue is about: 133 skills are listed in
  every prompt whether or not anything ever reads them.
- **`autoDream` / memory settings.** Covers memory consolidation only, not
  skills, in both harnesses.

So the count is derivable today from two stock log sources, with no new
telemetry. What does not exist is anything that aggregates it, decides from it,
or acts on it.

### The measured numbers, so nobody re-derives them

One run on 2026-10-09, from the two log sources above:

| | |
|---|---|
| Skill-use events, 30 days | 212 (35 Claude + 177 Pi) |
| Installed skills at `~/.pi/agent/skills/` | 133 |
| Used at least once | 28 |
| Zero-use | 106 |

Most used: `verify` 57, `verify-fleet` 28, `review-adjudication` 20, `drive` 13,
`forus` 12, `unslop` 4. The zero-use list of 106 contains every skill the
manual prune named, including `no-ai-slop` (kept: `unslop`), `architect` (kept:
`design-it-twice`), `automatic-tool-routing`, `vitest` and `human-review`.

**Drift re-measured, and it contradicts the premise.** Of the 133 installed
skills, 76 are symlinks (47 into `~/.claude/skills`, 29 into the vault
skills-library) and 57 are real directories. All 57 real directories are
byte-identical to their vault copy today, so 0 have drifted. The problem is
structural, not actual: a copy *can* drift and a symlink cannot. The repair is to
re-point the 57, not to fix content.

### The decision

Nothing is built, for the same two reasons as the proposal half, and one more:

- The pro-dev path is a new component in its own repo (vault
  `global-standing-rules.md`, "Build and ship"). This worker's GitHub App token
  holds Contents/PRs/Issues write and Metadata read and no Administration, so it
  cannot create that repo. `gh api /installation/repositories` on the worker
  token answers `total_count: 1` with the single name `Nishfleet/fleet-ops`.
- The two PRs the finish line asks for land in the vault skills-library, and the
  worker jail hides the GitHub login that reaches it: `gh api
  repos/nish3451/nish-vault` answers 404. The vault memory
  `nish3451-repos-outside-worker-reach` records that installing the App on
  nish3451 is a security call only Nish can make.
- The counting half is not worth shipping on its own. A count with no authority
  to act on it is a report, and the report above is the deliverable.

A Jev call on this blocker returned needsNish p=0.45, so it is not a
reserved-class park. The planner picked the park-with-dependency option over
both "ask Nish to widen the App" and "build the counting half alone", because
the counting half without the PR half is this paragraph.

## Off switch

None needed, because this page is a decision record only: no unit, timer, hook,
workflow, config knob or file is added by it.
