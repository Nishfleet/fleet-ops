# Skill proposals: no stock path fits (fleet-ops#9495, 2026-10-09)

The decision this page records: no stock, event-driven way to turn a session's
learning into a skill proposal exists on this fleet, and nothing is built to
replace it. The rule that follows from it lives in the vault's global standing
rules (`_system/shared-memory/global-standing-rules.md`, the one rules file every
agent follows) under "Skill ladder"; that file is the rule, this page is the
evidence.

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

## Off switch

None needed, because this page is a decision record only: no unit, timer, hook,
workflow, config knob or file is added by it.
