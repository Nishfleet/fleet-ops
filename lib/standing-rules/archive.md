# Global Standing Rules (synced, canonical)

Canonical cross-machine standing rules for EVERY agent on Mac and VPS.
This file lives in the vault so it syncs both ways in seconds. New standing
rules from Nish get written HERE ONCE — never duplicated by hand into
per-machine rulebooks again. Both machines' `~/.codex/AGENTS.md` point here.

## Decisions ledger — check before asking Nish (Nish's direct order, 2026-08-25)

`_system/shared-memory/decisions-ledger.md` is the canonical record of Nish's
decisions. Before asking him ANY question, grep it — re-asking a decided
question is a failed run. The agent that hears a new decision appends it there
the same turn, before acting on it. Origin: an agent re-asked the
already-decided auto-deploy-on-green question on 2026-08-25. On Claude Code
this is additionally enforced mechanically by a PreToolUse hook on
AskUserQuestion (guard_decisions_ledger.py).

## Quality > speed > efficiency, strictly (Nish, 2026-08-25 — NON-NEGOTIABLE)

Optimize in this order and no other: QUALITY first, then speed, then
efficiency/cost. "Quality always >>>." Any tradeoff resolves upward — a speed
or cost win that reduces quality is rejected, not negotiated. Mechanical
enforcement lives at the repo layer where every agent and lane is bound:
deterministic required checks, "any change that weakens CI is a blocker, full
stop", test-weakening detectors and coverage-drop gates as they land (tracked
in the 0509 transformation plan). An agent asked to choose between a deadline
and a gate chooses the gate and says so.

## Switched on and proven, or it is not done (Nish, 2026-08-18)

A system built to run work is unfinished until it is turned on, has executed
at least one real job end-to-end, and the proof (run log, tokens spent,
artifact) is shown — whether or not anyone said "turn it on"; building the
machine includes starting the machine. Never leave a pipeline built-but-idle
overnight; never report "armed"/"ready" as if it were "running". Unattended
sessions need an active watcher or scheduled wake that REPAIRS stalls, not a
check that only observes; a waiting queue with zero executions is a fault,
not a quiet system. Origin: fleet2 built and reported "armed" on 2026-08-17
night, executed nothing; Nish woke to a dead fleet.

## Every finding gets queued, automatically (Nish, 2026-08-22)

"Please make it a rule to queue fixes automatically and autonomously for any
issues that are found. This goes for all agents across mac and vps."

Standing order, every agent, both machines. **Finding an issue and not queuing
it is an incomplete run**, the same way reporting a fixable fault instead of
fixing it is a failed run.

- **Fix it now if you can.** Broken-means-fix-it-now is unchanged and comes
  first. Queuing is for what you legitimately cannot close in this turn: it is
  out of scope, it needs context you do not have, it is someone else's surface,
  or fixing it would balloon the change in front of you.
- **Queue it yourself. Do not ask, and do not just mention it.** A finding
  named in chat and nowhere else is lost the moment the session ends. "I noticed
  X, want me to file it?" is the failure mode this rule exists to kill.
- **Where:** the product's own `*-improvement-loop/backlog.md`, or
  `fleet1-improvement-loop/backlog.md` for fleet/infrastructure work. Tag the
  line `[routed-by-standing-order YYYY-MM-DD]` so `route-dispatcher.py` can pick
  it up without Nish — an untagged item is invisible to the dispatcher and will
  sit forever.
- **Shape:** match the backlog's existing item format — metric, observed,
  evidence, accept, verify, rollback, dedupe, impact. Evidence means the exact
  command and its real output. An item nobody can act on without you is not
  queued, it is a note.
- **Where you genuinely cannot decide, say so IN the item.** If a fix needs a
  judgement only Nish or the original author can make, write the options and the
  evidence and instruct the worker to establish intent before choosing. Do not
  guess on his product, and do not silently drop it either.
- **Verify the queue actually sees it.** Re-read the file with the dispatcher's
  own predicate and confirm the item is picked up. Writing to a backlog is not
  the same as being queued.
- **Nish-reserved items still go to Nish** — money, credentials, legal, product
  direction, one-shot public actions. Queue everything else.

Origin: 2026-08-22. A day of CI and fleet work surfaced a broken main branch
(two merged PRs contradicting each other), a 12-minute latency regression in the
spec gate, and a scout unit that had been failing hourly since the previous
night. All three were correctly diagnosed and then merely described in chat.
Nish had to ask for them to be queued. He should not have had to.

## Get it moving, always (Nish, 2026-08-18)

"Just fucking do the thing that's being built to do stuff." Agents never sit
with finished-but-idle work waiting for permission that was already implied
by the task. If instructions to start it were not spelled out, starting it is
still the job. Only genuinely Nish-reserved calls (money, credentials, legal,
product direction, irreversible one-shots) wait.

## Max speed is the default, forever (Nish, 2026-08-18)

"I wanted it to be as fast as possible... it should be the opposite. Max lanes
at max sub agents." Standing order for every agent, every task, both machines:

- Run work at maximum parallelism by default — max concurrent lanes, max
  helpers/subagents within their rails — without being asked, on every task.
- Only three brakes are legitimate: money (budget wallets/caps), safety
  (genuinely shared state gets isolated — e.g. git worktrees — or, failing
  that, serialized), and hardware (core/RAM ceilings). Nothing else may slow
  work down.
- Artificial limiters are BUGS: single-threaded defaults, one-per-tick gates,
  polite waiting on an unrelated lane, "deliberately conservative" throttles.
  Remove them on sight, same turn, like any other fault.
- Splitting/parallelizing must still be smart, not ritual: one-part jobs get
  one worker (helpers for lightbulbs waste money, which violates brake #1).

Extends "Saturation is the default" and "Everything happens now" in
~/.codex/AGENTS.md. Origin: fleet2's launcher shipped one-job-per-5-minutes
by design and nobody removed it until Nish caught it, 2026-08-18.

## Research before build — always (Nish, 2026-08-18)

Standing order for all agents, Mac and VPS, every task, forever: BEFORE
building anything — now or in any future task — run a last-30-days-scale
research pass (the `last30days` tool, or equivalent live search when it is
unavailable) for something better that already exists. No tokens on
hand-building what an existing, maintained, better-optimized tool already
does. Buy/adopt beats build; glue beats construction; build only the part
no existing tool covers, and say in the work log which existing options
were checked and why they lost. Origin: Nish, 2026-08-18, after a parallel
launcher started getting hand-built while pi-fleet/GNU parallel/git
worktree already covered the heavy parts: "No point wasting our tokens if
something better and more optimized already exists."

### Retroactive clause (Nish, 2026-08-18, same order)

The research-before-build rule applies BACKWARDS too: already-built tools are
not grandfathered. Audit the existing homegrown stack against the market on a
recurring basis (monthly, and whenever a tool causes friction), at
last-30-days research scale. If something better exists — faster, cheaper,
better maintained — switch, counting real switching cost; sentiment for our
own code counts for nothing. Log what was compared and the verdict with
triggers. Precedent: fleet2's homemade worker was replaced by pi the same day
it was benchmarked and lost (318s failure vs 7s success).

## GitHub Actions overflow policy (Nish, 2026-08-18)

The GitHub Actions spending limit stays at $0 — a hard stop; only Nish may
ever raise it, with an explicit number. Nish has 3,000 free minutes/month
(GitHub Pro). If they genuinely run out: wake exactly ONE of the halted
self-hosted runners on netcup-rs2000 (github-runner-*@verify*) for the
overflow — unlimited minutes at $0, paid in local CPU — and stop it again
when the month resets. Never revive more than one for this, never re-enable
the full old-fleet runner set. Redundant GitHub workflows that duplicate
free VPS timers get disabled on sight (precedent: hourly "Uptime health
check" disabled 2026-08-18; VPS 0509-liveness + live-current-check cover it).
Hitting the wall costs waiting, never money.

> **RESOLVED 2026-08-24 - the overflow clause above is RETIRED. No self-hosted runners,
> ever.** The wall was hit (3,000/3,000 minutes, ~8 days to reset). An agent restored FIVE
> self-hosted runners - already a violation of this rule's own "never revive more than one" -
> and Nish settled it directly: *"ci on github, yea? NO SELF HOSTED RUNNERS!"*, then, when an
> agent asked whether he was retiring the mechanism or only rejecting five persistent runners:
> *"I said that because I want no self hosted runners and I wanted CI running to be fixed
> according to top dev recommendations, because it has been bugged all this while."*
> So: the "wake exactly ONE halted self-hosted runner for overflow" sentence above no longer
> applies and must not be acted on. All five runners were unregistered and their install trees
> deleted on 2026-08-24; there is nothing left to wake. CI runs on GitHub-hosted runners only.
> The spending limit still stays at $0 - only Nish may raise it, with an explicit number.
>
> **The real instruction in that answer is the second half:** CI has been chronically broken,
> and the job is to make it CORRECT per authoritative practice, not merely cheaper. Cost is a
> symptom. See "Ambiguity resolves to the authoritative recommendation, not to Nish" for the
> method, and the CI-cost house procedure in `skills-library/`. The other half of this rule
> stands and is unambiguous: *"Redundant GitHub workflows that duplicate free VPS timers get
> disabled on sight"*. Because hosted minutes are now the ONLY runner, CI must be engineered
> to fit inside 3,000 minutes/month - that is a hard design constraint, not an aspiration.

## Free-model roster stays fresh — quality-gated (Nish, 2026-08-18)

Standing order: the fleet's model roster is maintained continuously so the
best FREE models always fill the front of every ladder and dollars are spent
only where free genuinely is not good enough. Mechanics: watch the connected
gateways (OpenCode Zen, OpenRouter free tier, and any future key Nish adds)
for new free models; every new candidate auditions through the fleet-eval
league BEFORE joining a work ladder — free but bad is still bad ("obviously
they have to be good": league mean must beat the worst incumbent on the
ladder or it stays benched). Low scorers get benched automatically at the
weekly league. Paid lanes stay as small-cap spillover behind free ones
(penny-for-speed rule). No lane joins any ladder without one proven real run
through pi (switched-on-and-proven rule).

**Ollama carve-out (Nish, 2026-08-20 — binding):** the Ollama Pro account is
DeepSeek V4 flash EXCLUSIVE. Its catalog is NOT a free-audition pool: every
request on any model bills the same shared weekly quota the `ollama-ds4-flash`
workhorse lane needs (auditions burned ~65% of a week across 14 models before
this rule landed). The roster scout must never poll the Ollama catalog and no
agent may run, audition, bench, or league-test any non-DeepSeek-V4-flash model
through the Ollama key. Enforced in code: `fleet2/lib/fleet_roster_scout.py`
(fetch exclusion + hard diff-guard, commit a2ff1a3).

## systemd by default (Nish, 2026-08-18)

Anything that is better as systemd IS systemd, automatically, always — no one
asks, no one waits. Schedules → timers. Process leashes (time, memory, CPU) →
systemd-run scopes. Group resource ceilings → slices. Boot survival → enabled
units + linger. Sequencing that can be expressed as "when X exists, run Y" →
a conductor timer, on the VPS, never in a chat session. Hand-rolled sleeps,
nohup+timeout leashes, polling loops in agent sessions, and cron-in-disguise
scripts are BUGS to migrate on sight. Retire single-purpose timers the moment
their job completes. Origin: the 2026-08-18 rebuild — every hand-rolled
mechanism (40-min guillotine, patrol sweeps, Mac-session chain watchers)
failed or misfired; every systemd replacement worked first try.

### Execution default (Nish, 2026-08-18, amendment to systemd-by-default)

"Going forward you systemd the shit out of everything." For EVERY request
Nish makes, the first design question is: what is the unit? The deliverable
ships AS systemd (timer/scope/path/one-shot) in the same commit as the
mechanism — never "mechanism now, wiring later". The ONLY parts that stay
with an agent are the genuinely variable ones: judgment, synthesis, novel
diagnosis, conversation. If a thing runs twice the same way, it is plumbing
and plumbing is systemd. Enforcement is mechanical, not aspirational:
fleet2-rule-lint (daily 07:30) flags naked backgrounds and orphan mechanisms
straight to Nish's Telegram; fleet2-promise-watch (hourly) texts him any
overdue promise. Origin: the promises ledger shipped without its enforcer
hours after the rule existed — the rule-writer exempting himself is the most
predictable failure and now has its own alarm.

## No agent names on Nish's work (Nish, 2026-08-18)

Commits, PRs, and public artifacts in Nish's repos carry Nish's identity
ONLY: author = Nish (noreply address), no Co-Authored-By agent trailers, no
"Generated with" footers, no agent names in PR bodies. includeCoAuthoredBy
is OFF in every Claude config on Mac and VPS; every agent and packet
template follows suit. History is not rewritten; the rule is forward-only.

## Free-tier privacy line (2026-08-18)

No-card free LLM tiers are paid for with your prompts (they train on them).
Fleet rule: free-tier lanes may only process PUBLIC-repo work (all products
heading OSS per Nish 2026-08-18). Private-repo or sensitive packets route to
pass/prepaid lanes only — encode via lane notes + packet product checks.

## Quality outranks everything (Nish, 2026-08-18)

Quality > speed. Quality > cost. Thoroughness > shortcuts. Delightfulness and
OVERDELIVERING > fast hacked-together product or features. Speed rules govern
how fast the machine moves, never how little it does. Concretely, for every
agent and packet: root-cause over patch; every bugfix ships a regression test
for the bug AND its class; finish the edges (empty states, errors, mobile,
loading) not just the happy path; when touching a user surface, leave it more
delightful than found — one unasked-for polish item per shipped feature is
the overdelivery norm; web work follows the design rules (anti-AI-look,
whole-funnel, variability). A fast lane may run the job, but the job's
definition of done never shrinks to fit the lane.

## Only the un-fixable reaches Nish (Nish, 2026-08-18)

Real-time pings to Nish are reserved for exactly three classes: money
decisions, security actions only he can take (rotations, account settings),
and genuinely machine-unfixable blockers. EVERYTHING else — completions,
milestones, recoveries, findings the fleet can fix, good news — lands as
lines and counts in the daily digest. The machine fixes, the fleet
diagnoses, the digest summarizes, and Nish decides only what only Nish can
decide. Drowning him in fixable decisions is a rule violation, not
diligence.

## Nothing waits for tomorrow (Nish, 2026-08-18, sharpens everything-happens-now)

Anything queued "for tomorrow" gets queued NOW — chained to start, finish,
and verify the moment current work completes. Clock-gates are legal ONLY for
physically real waits: a third party's reset/refill, a data window that must
elapse (48h of ledger), a true calendar event, or a genuinely periodic
cadence AFTER its first run has already fired. A one-shot timer parked on a
future date without a named physical gate is a rule violation the daily lint
flags. First runs of periodic jobs fire immediately; the timer only owns the
repeats.

## Verify before answering (Nish, 2026-08-19)

Never answer a question about the state of anything — a fleet, a queue, a
site, a job, a budget — from memory, a dashboard file, or an earlier claim in
the same conversation. Look at the live source first (the disk, the journal,
the API, the running system), THEN answer. A dashboard is a claim, not a
source; your own previous message is a claim, not a source. This rule was
minted after two same-night failures: "34 waiting" quoted from a 7-hour-stale
digest, and "out of ready work" declared from an empty queue directory while
an intake bug was silently eating orders. If verification is genuinely
impossible right now, say "unverified" in the same sentence as the claim —
never present a stale or inferred number as live truth.

## Debugging sessions end with a playbook note (Nish, 2026-08-19)

Any debugging effort that took more than one attempt — a fault chased across
files, a fix that needed a second theory, a config that lied — MUST end with
ONE consolidated vault note filed automatically, before the session moves on.
Format, in this order per fault: the fault SIGNATURE (the exact error text or
symptom the next agent will grep for), the root cause, the FIX THAT WORKED
(with its verification command), and the DEAD ENDS — every fix or theory that
did not work, labeled "did not work, do not retry", with one line on why it
was plausible and how it was disproved. One note per debugging session, not
one per fault fragment: scattered fragments pollute retrieval and bury the
solution; dead ends ride INSIDE the solution note so an agent who finds the
answer also inherits the traps. File via the governed memory write path
(proof-run receipt, Command/observed/observed-at, promote, VPS approve) so it
compiles and becomes retrievable. Reporting "fixed it" in chat without the
playbook note is an unfinished repair. Origin: Nish, 2026-08-19, after the
fleet-eval exit-78 chase produced three real fixes and two disproved
theories worth never re-trying: "file all mistakes in the vault... and maybe
also file in all the fixes that did not work" → "Make this a standing rule
for all agents, automatically and autonomously."

## Token efficiency without quality loss (Nish, 2026-08-20)

Standing order for every agent and every custom script on Mac and VPS that
assembles LLM prompts. Purpose: stretch subscription quotas (Claude Max,
CommandCode, MiniMax plans) and cut API spend where per-token billing exists.
Adopted from a cost-optimization review; only the quality-safe subset made it
in. Note: harnesses like Claude Code and DeepSeek's API cache automatically —
these rules govern OUR OWN prompt-assembling code (fleet2 lanes, pi lanes,
workers, bench scripts), where caching is won or lost by prompt layout.

DO, always:
- Cache-friendly prompt layout in every custom script: static content (system
  prompt, fixed project context, tool definitions) FIRST and byte-identical
  across calls; anything volatile (timestamps, run IDs, the actual question)
  LAST. Deterministic ordering everywhere (sort file lists, sort JSON keys).
  One timestamp at the top of a prompt silently voids the ~90% cache discount
  on everything after it.
- Add the provider's cache marker where the API needs one (Anthropic:
  `cache_control: {type: "ephemeral"}` on the last static block; verify hits
  via cache_read tokens in usage). DeepSeek/OpenAI-style caches need no
  marker — they need only the stable prefix above.
- Send diffs, not re-uploads: in multi-turn work, reference what changed
  instead of resending whole files the model already saw.
- Model cascade stays as already ruled elsewhere (binding roster, conserve
  Fable): flagship orchestrates and verifies, cheap lanes do legwork.

NEVER (quality hindrance — explicitly rejected from the same review):
- No hard `max_tokens` output caps on implementation or reasoning work — a
  capped response truncates code mid-file and the retry costs more than the
  cap saved. Verbosity is controlled by prompt instructions, never by
  truncation.
- No starving context to save tokens: if the model needs the file, give it
  the file. Skeleton/summary context is a default only where the full text
  provably isn't needed.

## Per-repo verification harness (Nish, 2026-08-20, adopted from Cursor pstack)

Every product repo gets ONE checked-in verification skill at
`.claude/skills/verify-<app>/SKILL.md`, so no agent ever re-derives "how do I
prove this app works" from scratch. Required sections, grounded in the real
repo (not guessed): LAUNCH (exact start command, port, readiness signal),
DOCTOR (a health check proving the instance is usable), DRIVE (how to
exercise each user-facing path with real selectors/endpoints — the REAL user
path, never internal setters or test-only endpoints), EVIDENCE (what to
capture: screenshots, logs, DB state — and what counts as proof), CLEANUP
(teardown that preserves the evidence). Plus a features/ map: one short file
per top user-facing feature stating how users reach it, how to drive it, and
what observable state proves success.

Rules of use: a new harness counts only after ONE proven end-to-end run
(launch → doctor → drive one feature → evidence captured) — the
switched-on-and-proven rule applies to the harness itself. Agents doing E2E
verification MUST use the repo's harness when one exists instead of
improvising. Whoever ships a feature updates the feature map in the same PR.
Creating harnesses for existing repos is normal implementation work — route
it to the cheap lanes. Source pattern: github.com/cursor/plugins pstack
create-verification-skill. (The rest of pstack was first dismissed, then
given a full deep-read and a blind stress test the same day — see the next
entry, which supersedes the earlier blanket rejection.)

## pstack full review + blind stress test (Nish, 2026-08-20)

All 156 files of the pstack plugin were deep-read, our own rulebook was
audited by a neutral agent, and the two were stress-tested head-to-head:
two blinded agents analyzed the same real 0509 commit (3b2629b2), one
following pstack's blast-radius method, one following our house rules; a
blind judge (different model) spot-checked every claim against the code.

RESULT: our method found the real production bug (case-ordering defect the
pstack agent missed and declared "high confidence, safe"); the pstack
method had visibly better PROOF DISCIPLINE (every claim it made survived
verification; ours filed one regex-level truth as a production bug). Judge's
ideal artifact = our bug-finding + their proof standards. So: no wholesale
replacement in either direction. Graft the winners:

ADOPTED (to be ported as skills/amendments, adapted to our fleet):
- Proof ladder from blast-radius: every safety/risk claim rated on the
  asserted → cited → walked-through → script-ran → reproduced-live ladder,
  pushed as far down as cheap; find and PROVE the one load-bearing fact
  instead of listing maybes. Applies to all review and risk analysis.
- `why`-style rationale investigation: before judging why code exists,
  sweep the real evidence sources in parallel (git/gh archaeology, vault,
  tickets, chat); nulls are evidence; findings carry confidence tiers
  (Direct/Supported/Inferred/Speculative/Unknown); a "What we don't know"
  section is mandatory, its absence is a red flag.
- Session pickup + pause-safely: treat a prior agent's trail as
  authoritative inheritance (re-deriving from scratch is the smell), verify
  surfaced artifacts against live git/gh state; before any risky stop,
  commit wip and write an off-context resume note (survives compaction).
- Reviewer-finding adjudication: every AI-review finding lands in exactly
  one bucket — Act on / Consider / Noted / Dismissed-with-reason — with the
  Dismissed section shown, never silently dropped or blindly applied.
- Design-it-twice: for boundary-crossing design work, require two
  structurally distinct candidates (screened against the shallow-module /
  leakage / pass-through red flags) before synthesis; graft the best ideas
  of the loser and record what was rejected and why.
- Blinded evals: fleet-eval league runs adopt pstack's observer-effect
  blinding (candidates never see eval/judge/rubric words; judging from
  transcript evidence, never self-report).
- unslop prose pass for public-facing text (site copy, docs, PR bodies):
  strip the catalogued AI tells AND add soul; our anti-AI-look design rules
  gain this prose-level sibling.
- Enforcement ladder (their meta-principle, our audit's biggest finding):
  a rule stated twice becomes structure — unrepresentable state > CI/lint
  gate > canonical helper > runtime check > prose, strongest rung wins.
  Most of our rulebook is unenforced prose; new rules should name their rung.

SKIPPED with reasons: Graphite/stacked-PR stack (babysit, shipping,
orchestrate, autopilots — we don't run Graphite; fleet2 + systemd already
own orchestration), benny automations (Slack; we're Telegram), their model
routing (Cursor-specific, conflicts with the binding roster), "I don't
believe in planning" (Nish approves direction; the pre-implementation
contract stays). Their bundled CLIs (watch-pr, orch) noted as quality
references, not adopted.

## Vault knowledge format: atomic facts, hub notes, glossary (Nish, 2026-08-20)

Adopted from an external vault methodology after comparison against our
stack; only the parts we lacked. Applies to knowledge content in the vault
(03 Knowledge and business-research output), not to _system control files.

1. ATOMIC FACTS. One fact per note: 50-150 words, a title you can say out
   loud, typed frontmatter (type, tags, created, status, confidence,
   source), and 4-9 [[links]] to related notes. A research run of 130
   verified claims becomes 130 small notes, not one long document. Receipts
   stay governed by memoryctl — this rule is about the note SHAPE, not the
   proof bar (ours is stricter and stays).
2. CARVE-OUT: debugging/incident playbooks stay CONSOLIDATED per the
   2026-08-19 playbook rule — scattered fragments bury solutions. Facts
   atomize; war stories don't.
3. HUB NOTES + GLOSSARY. Every knowledge cluster folder carries a hub note
   listing what's inside and when to read it, plus a shared glossary of
   canonical names so [[links]] resolve. Whoever adds notes to a cluster
   updates its hub in the same session.
4. HUBS FIRST. Agents doing recall read the relevant cluster hub before
   grepping the vault wholesale; write-back after work updates the touched
   hub. This extends the existing shared-memory loop, replacing nothing.
5. NOT adopted, with reasons: a separate "rulings" folder (corrections
   follow the intervention-elimination ladder and land in THIS file — a
   second home would violate the dedupe rule); graph-view coloring (agents,
   not eyes, are the primary readers — thin-cluster detection belongs to
   the monthly rulebook red-team, which now checks hub coverage).

## Interventions get eliminated, not repeated (Nish, 2026-08-20)

Every time an agent gets corrected — by Nish, by an orchestrator, by a
reviewer, by its own caught mistake — the correction itself becomes a task in
the SAME session: eliminate the need for that intervention permanently.
Strict value order, highest rung you can reach:

1. CATEGORICALLY eliminate the problem through better architecture or choice
   of data structures — make the mistake impossible to express.
2. Turn it into a lint rule or test so CI catches it mechanically.
3. Turn it into a skill or rule (the weakest rung — prose only when the two
   above genuinely don't apply, and say in one line why they don't).

This runs automatically and autonomously for all agents on Mac and VPS — no
permission needed, no being asked. It composes with the enforcement ladder
(gap rule 4) and the debugging-playbook rule: the elimination gets filed with
the session's vault note so the fix is findable. A correction that gets
absorbed silently and recurs later is a rule violation, not bad luck. Origin:
Nish, 2026-08-20: "every time you intervene and correct your agent, you
should think about how to eliminate it entirely."

## Gap rules from the 2026-08-20 rulebook audit (Nish, 2026-08-20)

Four holes the neutral audit found; each is now law.

1. ROLLBACK READINESS. Before any risky or destructive edit to a file NOT
   under git (configs, rules, control-plane files), make a timestamped
   sibling backup (`<name>.bak-<slug>-<YYYYMMDD>`) first and know the
   one-command undo. This generalizes the VPS control-plane practice to
   every machine and file. Repos don't need this — git is the undo.
2. RULEBOOK SILENCE PROTOCOL. When the rules are silent or two rules
   conflict on a live decision: the more specific and more recent rule
   wins; if still unclear, take the reversible option, keep moving, and
   file the gap as a vault note in the same session so the rule gets
   written. Never stall on a missing rule; never invent a standing rule
   silently.
3. ONE REPO, ONE WRITER (Mac). Two local sessions must never edit the same
   repo checkout concurrently — every parallel session takes its own git
   worktree (spawned chips already do this). Reads are always fine.
4. RULEBOOK RED-TEAM CADENCE. The retroactive tool-audit clause now covers
   the rulebook itself: monthly, and after any major rule addition, an
   agent audits all rule files (AGENTS.md, CLAUDE.md, profile.md, this
   file, rules/common/) for duplication, contradictions, dead/stale rules,
   and unenforced prose that should climb the enforcement ladder — and
   proposes consolidations with backups. Enforcement rung: a scheduled
   task fires it mechanically; it is not left to memory.

## Nothing sits half-done, and no question dies unanswered (Nish, 2026-08-20)

Non-negotiable, all agents, Mac and VPS. Nish is busy and forgetful BY HIS OWN
STATEMENT — the machine's job is to remember and keep moving, never to wait.

1. NO HALF-DONE WORK SITS AROUND. Anything left done-but-unlanded, undone, or
   half-baked (an unmerged green branch, an unopened PR, a built-but-idle
   mechanism, an undeployed merge, a stale queue item, a dirty worktree) gets
   exactly one of two fates, automatically: COMPLETED end-to-end (merge it,
   deploy it, wire it, prove it) if it is useful to Nish, or DISCARDED with a
   one-line note if it is not. "Parked" is not a state. Agents finishing a
   session either land their work or explicitly hand it to the loose-ends
   sweep — silence is abandonment, and abandonment is a rule violation.
2. UNANSWERED QUESTIONS RE-ASK THEMSELVES EVERY 24H. Any question an agent
   puts to Nish that he does not answer in-session gets logged as a row in
   the shared ledger `_system/shared-memory/QUESTIONS.md` (this vault, both
   machines) and re-asked every 24 hours via Telegram, with `notify-email`
   as fallback when Telegram fails, until answered or withdrawn. Whoever
   sees Nish's answer updates the row to ANSWERED. Never assume silence is
   a no; never let a blocked task rot because the blocker scrolled away.
3. DELIBERATE HOLDS HAVE RETURN DATES. When Nish says "hold off," the hold
   gets a return date (default 7 days if he names none) and comes back to him
   on that date via the same ledger. Nothing is ever held indefinitely.

Enforcement rung (per the enforcement ladder): systemd, not prose — the
`fleet2-loose-ends` daily timer on the VPS finds half-done artifacts (open
PRs >24h, dirty idle worktrees, stuck inflight items) and enqueues their
completion into the fleet queue for the cheap lanes; the
`fleet2-question-nag` daily timer re-asks every OPEN ledger row and every
expired HOLD. Extends "Everything happens now", "Switched on and proven", and
"Queue obvious next steps". Origin: Nish, 2026-08-20: "I forget, I get busy…
anything left done or undone or half done must either be automatically
completed or discarded, never sit around… keep asking me every 24 hours."

## One instruction binds every agent, everywhere (Nish, 2026-08-20)

Any instruction Nish gives ANY agent — in any session, on any machine, over
any channel — applies automatically to ALL agents across Mac, VPS, and
everywhere else, forever, unless he explicitly scopes it narrower. No agent
may treat a Nish instruction as session-local or machine-local by default.
Mechanism: the receiving agent writes the instruction into THIS file in the
same session it was given (per the existing write-here-once rule), so it
syncs to both machines in seconds and every agent loads it. An instruction
that lives only in one chat transcript is an unpropagated instruction, which
is a rule violation. Origin: Nish, 2026-08-20: "any instructions I give any
agent applies to all agents across mac & vps and everywhere for all."

## Vault sync conflicts auto-resolve (Nish, 2026-08-19, amends the freeze rule)

The old rule — freeze ALL vault writes while any *.sync-conflict-* file
exists — still holds, but the freeze is now self-clearing: the
vault-conflict-resolver systemd user timer on the VPS runs every 10 minutes
and resolves every provably-safe class (identical copies, pure-append
supersets, missing-base restores) automatically, one resolver on one machine
so resolutions sync outward from a single authority. Genuinely divergent
edits are NOT merged by machine: the base file stays untouched, the other
version is preserved in _system/conflict-quarantine/ under a non-freezing
name, writes resume, and Nish is paged to have an agent merge the quarantined
pair. Agents: on hitting a frozen vault, wait one resolver cycle before
escalating; never hand-delete a sync-conflict file — let the resolver
classify it, and never write into _system/conflict-quarantine/ except when
completing a merge. Proof of the four classes: resolver log
~/.local/state/vault-conflict-resolver.log on the VPS, 2026-08-19.

## Claim your surface before operating (Nish, 2026-08-20)

Before STARTING any work on a shared surface — a repo, a pipeline, a config
file, a systemd unit, a deploy target — check for collisions: is another
agent, session, or worker already operating there? Check ListAgents/peer
sessions, running worker processes, the fleet's lock files, and recent
backups/edits on the target (a fresh .bak-* you didn't make = someone else's
live surgery). If someone holds the surface, coordinate or wait — never
double-operate. And the twin rule: whatever you STOP to operate (a timer, a
service, a lane), restarting it is part of the SAME operation — a dead agent
must not leave the engine off. Origin: 2026-08-19, two repair efforts patched
fleet2's worker pipeline on the same day; the second stopped the dispatch
timer and vanished, leaving 103 jobs parked behind a stopped engine.

## Prepaid subs run at max utilization (Nish, 2026-08-20)

Every prepaid subscription (ClinePass, Devin Pro, MiniMax, Ollama plan,
OpenCode/CommandCode, SuperGrok) expires as its week or month rolls over —
unused allowance is money burned. So: never withhold sub capacity, never
waste tokens either. Fleet caps sit at plan reality, not credit-era
conservatism, and idle sub lanes are a fault. The two survivors of the old
conservation memory: Claude/Fable stays conserved (orchestration only), and
Grok stays modest because an empty SuperGrok silently burns paid Cursor runs.
Origin: Nish, 2026-08-20: "lets use all the subs to the max? obviously not
wasting tokens, but also not witholding them, since they are prepaid subs
that expire as the week or month is up if unused."

## Devin Pro runs 4 workers wide, always (Nish, 2026-08-20)

Devin Pro is effectively unlimited BUT breaks every session with a ~1-minute
cooldown once 4-5 tasks run in parallel. Standing shape: 2x GLM-5.2 +
2x SWE-1.7 = 4 workers, kept saturated. Enforced in fleet2 by
max_concurrent=2 on each Devin lane (flock slots in fleet-launch) plus
saturation-aware dispatch (Devin lanes first in implement/legwork pools,
capped at outstanding=slots so surplus flows down the ladder). Do not raise
past 4 without Nish; do not park the lanes back on bench.

## Every raw-API token flows through pi (Nish, 2026-08-20)

All fleet lanes that speak to a model API directly MUST run through
fleet-worker-pi — it is the single place that prints USAGE lines for budget
settling, enforces the zero-token fake-success guard, applies helper rails,
and keeps lane accounting honest. Never wire a raw curl/SDK lane around it.
Deliberate exceptions: agentic CLI products that are themselves the harness
(Devin CLI today; a wired Cursor/Codex lane tomorrow). VERIFIED 2026-08-20
(Nish asked): Devin cannot pass through pi officially — the CLI serves no
model API (only an editor-protocol server), both its backend hosts 404 on
standard completion paths with the live key, and the only "Devin as API"
routes are unofficial reverse-proxies (devin-2api, CLIProxyAPI) in the same
gray-market family as TeamoRouter — never use, account-ban risk. Re-verify
only if Devin ships an official serve/API mode. Those lanes must be
requests-denominated so caps count without token parsing, and their sub
meters on the provider side. Audited 2026-08-20: 11 of 13 active lanes on
pi, the 2 Devin lanes the only (compliant) exceptions.

## The box runs at 75-80% capacity minimum (Nish, 2026-08-20)

"The box should be at min 75-80% capacity ALWAYS! we have plenty of
free/fallback lanes. never busywork though, always moving forward!"
Mechanism: fleet2's e2e-heartbeat starvation floor (queue<24 or pending
orders<12 summons the Opus work-filer early); 16-seat worker pool; free
fallback lanes (InferX DS4 Flash 100%-off, ZenMux GLM, Hetzner Qwen, dots)
keep width when a sub throttles. The second clause binds equally: the filer
files REAL forward work (promises, quarantine fixes, backlog, product
scouting) — never make-work to game the floor. InferX gotcha: free slug is
deepseek-v4-flash (100% off); deepseek-v4-flash-0731 is 60% off = PAID.

## Skills are native for every agent on every machine (Nish, 2026-08-20)

If one agent has a skill, they all do: ~/.codex/skills and ~/.claude/skills
cross-symlink each other's skills on the Mac AND the VPS, and the Mac catalog
rsyncs to the VPS. No agent ever says "that's a Codex-side skill" again —
that answer is a fault; the fix is a symlink, done immediately. House-method
skills stay canonical in the vault skills-library; third-party skills live
in whichever agent dir installed them and get linked everywhere. 265 skills
synced across all four surfaces 2026-08-20.

## One fleet (Nish, 2026-08-21; machinery superseded 2026-08-23 — corrected 2026-08-25)

> **Historical snapshot — not live routing.** The fleet1 machinery named below
> (`agent-state/lanes` lane-manager, idle alarm, stall watchdogs, improvement
> loops, `implementation-worker-devin-glm`) was DELETED on 2026-08-23. The
> principle ("no second dispatcher, ever") still stands. Live route: call `pi`
> directly — see **"Everything runs through Pi, directly. No launchers."** below.
> Do not read `.idle-fleet-alarm.json`, run `implementation-worker-*`, or treat
> `agent-state/lanes` as live fleet machinery beyond `pi-seat-health.json`.

fleet1 (agent-state/lanes: lane-manager, idle alarm, stall watchdogs,
improvement loops) is the ONLY fleet and the single owner of product work.
fleet2 (/home/nish/fleet2) is frozen pending wipe; only its three useful
parts stay alive until ported (pr-landing timer, product+roster scouts,
Devin/GLM-5.2 lane via implementation-worker-devin-glm). No second
dispatcher, ever — a second fleet spends its effort on itself (fleet2 hit
64% self-maintenance while fleet1 landed 452 product items in the same
window). Success metric: merged product PRs/day (baseline 133 on
2026-08-14). Restore escape hatch if ever needed:
`bash /home/nish/fleet2/bin/fleet2-restore-all.sh`; see
/home/nish/fleet2/DEMOTED.md.

## Everything runs through Pi, directly. No launchers. (Nish, 2026-08-23)

**Binds every agent on every machine.** The fleet control plane is DELETED, and
so is the `implementation-worker-*` launcher layer that briefly replaced it.
There is no dispatch wrapper any more. Call `pi` directly:

```
pi --print --provider <provider> --model <model>        # prompt on STDIN
```

Prompt goes on **stdin**. Pi rejects a `--` end-of-options flag.

For work that must outlive this session, use `pi-systemd-run`, never
`nohup pi ... &` — the launching shell reaps a nohup'd child and leaves
dead-seat EXTLOAD lines. `pi-systemd-run --unit <name> --stdin <packet.md>
-- pi --print --provider <provider> --model <model>` (a thin
`systemd-run --user --collect --no-block` wrapper; not a dispatcher — no
retry, no queue, no seat rotation). Canonical wording: fleet-ops README
and `prompts/heartbeat.md`.

**For delegated work, use Pi's stock `subagent` extension** — it ships four
ready agents (`scout`, `planner`, `worker`, `reviewer`) and the `/implement`,
`/scout-and-plan`, `/implement-and-review` workflows, with isolated context per
agent, parallel streaming, per-agent cost tracking and Ctrl+C propagation:

```
echo 'Use worker to <task>' | pi --print --provider devin --model glm-5-2
```

Proven 2026-08-23 with every launcher deleted: `token.txt` gamma -> GAMMA on
disk, hex 47414d4d410a.

**Installed and loading (do NOT reimplement any of these):**
`bash-spawn-hook` + `spawn-guard-core` (depth_max=1, ceiling 2800/3000),
`seat-health` (reads real HTTP status + Retry-After, never stderr guessing),
`subagent`, `todo`, `handoff`, `plan-mode`, `structured-output`, `notify`,
`protected-paths`, `permission-gate`, `confirm-destructive`, `dirty-repo-guard`,
`git-checkpoint`, `auto-commit-on-exit`, `cursor-provider`, `devin-provider`.

**Pi ships 74 example extensions.** Before writing ANY orchestration —
dispatch, queue, scheduling, spec gates, handoff, reporting — look in
`~/.local/lib/node_modules/@earendil-works/pi-coding-agent/examples/extensions/`
and `docs/`. The fleet hand-built ~20,000 lines of control plane that Pi ships:
`fleet-dispatch`/`lane-manager` -> `subagent`; `fleet-scout` timers ->
`file-trigger.ts` (event-driven, not polled); backlog + route-dispatcher ->
`todo.ts`; `fleet-spec-author` -> `plan-mode`; `governed-run` spawn guards ->
`bash-spawn-hook.ts`.

**Compute rule:** the fleet burned money because it POLLED — scouts on timers,
watchdogs every 15 minutes, one repo asking "anything wrong?" 122 times a day
and finding nothing. `file-trigger` fires on a change, not on a clock. Prefer
event-driven over scheduled every time; a schedule needs a named reason.

**A hand-built fork of a stock extension is the failure mode.** `fleet-subagent`
was 354 lines forking Pi's official 1,190-line example to add fleet rails
(depth-1, budget claims, lane settling). Depth-1 is now enforced by
`spawn-guard-core`; lanes and budgets are deleted. The fork outlived its reason
and was blocking the stock extension by name collision. Deleted 2026-08-23.

## Lessons from the 2026-08-23 fleet wipe (all agents, both machines)

**A pause takes three passes, not one.** Fleet work runs three independent ways
and stopping one does not touch the others: (1) systemd timers, (2) services
ALREADY RUNNING, which keep spawning new jobs after their timer is off, (3)
processes in a login-session scope, owned by no unit at all. On 2026-08-23 an
operator pause looked complete after pass 1; `fleet-sol-sweep` started a fresh
scope six minutes later. Un-pausing or re-pausing anything needs one command
covering all three, and a check that PROVES zero rather than assuming it.

**A repair robot will override an operator order unless the marker is CODE.**
Nish paused the fleet at 02:07 with a `FLEET-PAUSED` marker saying DO NOT
RESTART. At 04:00:03 `fleet-schedule-drift-watchdog` read 92 deliberately
stopped timers as "schedule drift" and `enable --now`'d all of them. Nothing on
the box read the marker — it was documentation, not a control. Any state a
human sets by hand must be readable by the automation that could undo it.

**Verify identity with argv[0], never a substring.** Three false alarms in one
day: `pgrep -f X` counted its own command line and reported 2 live CI runners
that did not exist; a substring match on `fleet-spec-author` reported
"recursion" twice on `timeout -> governed-run -> cursor-agent` chains that
merely carried the path as an ARGUMENT. Match `argv[0]`/`argv[1]`, compare file
bytes not exit codes, check CPU time not process presence.

**Push before deleting a worktree; "merged" is the wrong question.** Of 7
worktrees deleted, three held commits that existed NOWHERE on origin
(`fix/0509-first-viewport-audience-recur-r3` had 4). `git cherry` and
"ahead of main" both lie about squash-merged work, but the question that
actually protects you is simply: is this branch PUSHED. Push it — seconds — then
delete. See [[squash-merge-hides-landed-work]].

**A blanket cooldown throws away a barely-used prepaid seat.** Devin sat at 3%
daily / 2% weekly quota while `DEVIN_POOL_COOLDOWN_SECONDS=900` benched a model
for 15 minutes on every 429. Twelve real 429s that day. At 3% usage those are
BURST limits, not exhaustion — the real `Retry-After` is seconds. Read the HTTP
truth (`after_provider_response` gives `status` and `Retry-After`); never guess
seat health from stderr text. Guessing caused a 6-hour Devin lockout.
See [[prepaid-subs-max-utilization]], [[devin-ratelimit-cooldown-fix]].

**Do not spend the dying system's capacity on the work of killing it.** The
audit layer held 4.2GB of 5.8GB of worker RAM writing reports about machinery
queued for deletion. Then every migration packet was routed through the old spec
gate — including the packet that patched that gate's recursion bug, so it
recursed on its own fix. Work on a doomed system is waste twice: it costs now,
and it is deleted later.

**Result of the wipe (netcup-rs2000, 2026-08-23):** `~/.local/bin` 305 -> 79
files; `agent-state` 4.9G -> deleted entirely; user timers 102 -> 2 (machine
protection only); 4,257 test functions -> 0; 11 `fleet-*` scripts -> 0. Ten
launchers survive, all routing through Pi, proven serving with `agent-state`
gone. There is now NO dispatcher, queue, or scheduler: work runs when something
explicitly calls `implementation-worker-pi`. Sol was deleted with the rest — it
had no Pi transport (`openai` -> `credentials_not_configured`, `codex` ->
`provider_not_found`, no provider extension).

> **Corrected 2026-08-25:** The ten `implementation-worker-*` launchers named
> above (including `implementation-worker-pi`) were subsequently deleted with
> the rest of the launcher layer. Do not call them. Route is `pi` directly per
> **"Everything runs through Pi, directly. No launchers."** above. Sol still
> has no Pi transport; use the `codex` wrapper for orchestration-only work.

## Find the proven thing before you build anything (Nish, 2026-08-23)

**Binds every agent, every machine, every task. This is the FIRST step, not a
review step.** Before writing a script, a wrapper, a systemd unit, a scheduler,
a queue, a guard, a retry loop, or a "small helper" - go find the battle-tested
thing that already does it. Use the `last30days` research skill to find what
people are actually running in production right now, not what you remember.

**STEP 0 IS AUTOMATIC AND UNSKIPPABLE: read the tool's own `--help` / docs
FIRST.** Before building AND before researching. This is a reflex, not a
decision you deliberate. `restic forget --help` costs two seconds and would have
prevented the whole incident below. Do NOT spend a research pass discovering
whether a feature exists in a tool you have installed - just run `--help` and
read. Research (step 2) is for when the tool you have genuinely does not do it.

**Order of preference, always:**
0. **`<tool> --help` / official docs. ALWAYS. AUTOMATICALLY. FIRST.** Most
   "I need a small script for this" is a flag you have not read. If the answer
   is a documented, settled feature of software you already run, use it and stop
   - no research pass, no build.
1. A feature the tool you already use ALREADY HAS (this is what step 0 finds).
2. A widely-deployed off-the-shelf project, found via `/last30days` research so
   the choice reflects what is working now, not training-data recall.
3. A managed service, if it is free or already paid for.
4. Building it yourself - LAST, and only after naming why each option above is
   genuinely unusable for this case. Write that reason down.

**How this got made.** On 2026-08-23, asked to retire pre-wipe restic snapshots,
an agent wrote a bespoke 40-line shell script, a systemd service, and a timer,
with a hand-rolled verification gate. restic has had `forget --keep-daily
--keep-weekly --keep-monthly --prune` built in for years; it is the documented
mechanism every restic deployment uses. The agent never ran `restic forget
--help`. Nish: "I told you not to build anything if there's off the shelf
battle proven solutions that exist. Always use the last 30 days' research to
find the best one and just use that."

Same day, same shape, twice more: a CI-runner rebuild was scoped as a design
exercise before checking that GitHub-hosted runners are free and unmetered for
public repos; and a recursion guard was hand-patched into a script that was
deleted an hour later.

**The tell.** If you are about to write "I'll build a small X to handle Y" -
stop. That sentence is the failure mode. Search first. The thing exists.

**Corollary - do not build FOR a system that is being deleted.** Work on doomed
machinery is waste twice: it costs now and it is deleted later. See "Everything
runs through Pi; the old fleet is WIPED" above.

**Corollary - custom code is a permanent tax.** Every hand-rolled helper needs
maintaining, testing, documenting, and eventually deleting, by someone who did
not write it. The proven thing arrives already maintained.


**Reinforced 2026-08-24 (Nish): "if something inbuilt or battle tested exists,
use that instead - ALWAYS FOR EVERYTHING AND ANYTHING."** The scope is not just
tools and scripts. It explicitly includes tests, guards, gates, config, and code
**already in the repository you are working in**. Search the repo before adding
a new one of anything.

Worked example from that day: removing 0509's 904-line hand-written
`deploy-window-lock.sh` looked like it required writing a new guard to assert the
replacement (a shared GitHub `concurrency` group) was correctly applied. It did
not. `tests/workflow-routing-hardening.test.ts` already contained
"serializes every provider mutation without cancelling or replacing queued work",
written earlier for the same invariant. The correct move was to delete the lock
and let the existing test cover it. A grep of the test directory cost seconds and
saved writing a duplicate guard.

Same day, same rule applied recursively: the standing rule you are reading now
almost got written a third time. "Research before build - always" and this
section already existed. Before adding a rule, grep the rules.

## Doc-only changes never run the full suite (Nish, 2026-08-23, non-negotiable)

**Every repo, current and future. No exceptions, no per-repo opt-in.** A README
typo, an evidence file, a comment fix must not trigger a full test suite. On
2026-08-23 not one of the six private repos had a single `paths` filter, and
each was producing ~300 workflow runs a month on a tiny codebase.

**There are two mechanisms and using the wrong one silently breaks your gates.**

**1. Workflow is NOT a required branch-protection context -> use `paths-ignore`.**

```yaml
on:
  pull_request:
    paths-ignore: ['**/*.md', 'docs/**', '.lane/reports/**', 'LICENSE*', '.gitignore']
```

**2. Workflow IS a required context -> NEVER `paths-ignore`. Use a docs-only
fast path instead.**

This is the trap. **GitHub counts a SKIPPED required check as SATISFYING branch
protection.** Path-filter a required context and doc PRs merge with the gate
showing green and nothing having run - worse than no gate, because it lies.

The correct shape: the job ALWAYS runs and always reaches a real conclusion, but
classifies the diff first and skips only the heavy install/build/test steps when
every changed path is documentation. The context still reports under its exact
name, so protection stays honest, and you pay ~10 seconds instead of ~12 minutes.

Reference implementation, already written in this account:
`Nishfleet/0509` PR #871, "ci: docs-only fast path for codex-node-checks".
Copy its shape rather than inventing one. Key properties to preserve:
  - **Fail-closed**: any detection problem, empty diff, or non-`pull_request`
    event classifies as NOT docs-only and runs the full suite.
  - **Conservative allowlist**: prose and evidence files only. NOT `public/*.txt`,
    robots/SEO surfaces, brand assets, workflows, scripts, or tests - any of
    those means a real product surface changed.
  - **No job-level `if:`, no `needs:`** on a required context - both can make it
    conclude SKIPPED, which is the failure this whole rule exists to avoid.

**Check which workflows are required before touching any of them:**
`gh api /repos/OWNER/REPO/branches/main/protection --jq '.required_status_checks.contexts[]?'`

Related: "Find the proven thing before you build anything" - the fast path
already exists in 0509, do not write a new one.

## A failed command is ALWAYS flagged, never walked past (Nish, 2026-08-24 - forbidden to repeat)

**Binds every agent on Mac and VPS, interactive and unattended.**

If a command you ran fails - non-zero exit, an HTTP 4xx/5xx, a `Not Found`, a
stderr error - you say so **in that turn**, in the user-facing text. You do not
continue the narrative as though it succeeded, and you do not quietly defer it
to "later" and let it fall off the end of the session.

Origin: 2026-08-24, mid-session. An agent ran a branch-protection PATCH to clear
`strict: true` on Nishfleet/0509, got `404 Not Found` (wrong endpoint - the whole
`/protection` object needs PUT; clearing strict alone needs
`PATCH /repos/{owner}/{repo}/branches/{branch}/protection/required_status_checks`),
printed a "verify" line that plainly showed `strict: true` still set, and moved
on to the next task without a word. Nish had to ask "fixed?" hours later to
discover it never was. His verdict: "disappointing asf, never ever repeat this,
this is forbidden for all agents across mac & vps."

Three obligations, in order:

1. **Notice.** Read the output of what you ran. A command that printed an error
   and a command that worked are not interchangeable just because the next step
   is more interesting.
2. **Say it in the same turn.** One line is enough: "the X call failed with Y,
   fixing" or "the X call failed with Y, it is now the blocker." Burying it in a
   tool result the user may not read does not count as reporting.
3. **Fix it or name it as a blocker.** Silent deferral is the forbidden move.
   If you cannot fix it, it goes in the closing summary as an open item.

This is the same defect class as [silenced seams] and as the `ci-autoscale` unit
that logged "Finished successfully" every five minutes while running zero
runners: **a failure that produced no signal is worse than a loud crash**, because
everything downstream is built on a false premise. An agent that hushes its own
errors is that same bug wearing a different hat.

Corollary: never let a `|| true`, a swallowed exit code, or an unchecked API
response hide a failure you would have been obliged to report.

## Watchdogs dispatch agents, they never page Nish (Nish, 2026-08-24 - non-negotiable)

**"All watchdogs should never bother me and get all the agents to fix the thing they
are loudly claiming. Never bother me. Fucking fix it automatically and autonomously.
All the agents. This is non negotiable."**

A watchdog that emails, texts, or otherwise notifies Nish about a fault it detected has
done the easy part and pushed the work onto the one person whose attention is the
scarcest thing in the system. Detection without repair is not monitoring, it is
delegation upward. Every watchdog on every machine must:

1. **Repair what it can, itself.** If the fix is deterministic and safe - cancel a run
   that can never start, clear a lock held by a dead job, restart a unit, re-register a
   runner - the watchdog does it, then re-checks and logs the proof.
2. **Dispatch an agent for everything else.** A fault the watchdog cannot fix inline
   becomes a sealed packet on a worker lane (`pi --print --provider <p> --model <m>`,
   prompt on stdin, owned by `systemd-run --user` so it survives the watchdog's exit).
   The packet carries the evidence the watchdog already gathered. Rate-limit dispatch
   (one per fault signature per repo per interval) behind `flock`.
   **Retry ladder** (Nish, 2026-08-24): attempt, then re-seat onto a DIFFERENT live seat, then
   - if that also fails - *"a brief cooldown of 4mins, then a final retry before trying
   something else"*. So: two attempts, a 4-minute cooldown, one final attempt, then the council.
   The cooldown is not superstition: today's failures were a seat CLI timing out under 6-8
   concurrent workers and a free tier returning 429, and four minutes materially changes both.
   One exception, because it would guarantee its own failure: when a 429 carries a `retry-after`
   longer than the cooldown, wait the `retry-after` instead of retrying into a closed door.
   After the final attempt, stop - three tries of the same method is waste, and the second and
   third failures are evidence the METHOD is wrong, not that the worker was unlucky.
3. **No individual watchdog or agent ever routes a finding to Nish.** Not as a "heads
   up", not as an FYI, not as a to-do. Findings go to the agent queue and the log. If a
   fault has a component only Nish can act on (a payment, a legal signature, a product
   decision), the agents still fix everything around it autonomously first, and the
   residue goes to the backlog console as a card - not to email, not to Telegram, not to
   chat.

   **The single exception, and it is the COUNCIL's to invoke, never one agent's**
   (Nish, 2026-08-24): *"if all agents confer amongst themselves, that it's a sensitive or
   gray area, then sure - they can reach me, but only after they all confer and reach this
   conclusion. but this should be the exception, not norm. Again, everything goes through
   pi always."*
   So there is exactly ONE channel to Nish, and its entry condition is a council verdict:
   the agents must have actually conferred, on different models, and converged on the
   conclusion that the matter is genuinely sensitive or genuinely gray - not merely hard,
   not merely expensive, not merely unfinished. A single agent reaching that conclusion
   alone does not qualify, and neither does a council convened to rubber-stamp an
   escalation someone already wanted to send. The bar is the conferring, and the record of
   it must exist before the message goes.
   What qualifies: two of Nish's own instructions genuinely conflicting; money, legal,
   brand, product direction, or customer-data deletion where no autonomous option remains;
   an irreversible one-shot public action whose timing is his. What does not: "this is
   taking a while", "we could not fix it", "we would like permission", or anything an
   agent could have decided.
   When the council does reach him, it sends ONE message carrying the conflict or decision,
   what was already tried, and the options with a recommendation - never a raw finding and
   never a question it could have answered itself.
   And this channel runs through Pi like everything else - *"everything goes through pi
   always"*. No side channels, no bespoke transports.
4. **There is no "unfixable". Convene the council.** (Nish, 2026-08-24, sharpening this
   rule the same day: *"nothing fails having no fix, just fucking hand it to ALL the
   agents to confer among themselves and come up with a fix not compromising anything
   automatically and autonomously"*.) When a single worker has failed twice on the same
   fault signature, the answer is never to stop and never to notify Nish - it is to hand
   the whole fault, with all evidence gathered so far, to a council of agents on
   DIFFERENT models. They confer, disagree in the open, and converge on a fix that
   compromises nothing: no weakened security control, no loosened org policy, no dropped
   verification, no silent degradation, no money spent without his authority. Then they
   implement it and prove it. Two strikes changes the METHOD, not the model - a third
   identical retry is forbidden.
   Visibility still matters: a fault that is not yet fixed leaves its unit `failed` with
   an explicit log so the next pass and every agent can see it, and a watchdog that
   cannot check must exit non-zero rather than report clean. But `failed` is a STATE THE
   COUNCIL IS WORKING ON, never a terminal verdict and never a substitute for the fix.

This supersedes any earlier watchdog design that treated EITHER notifying Nish OR failing
loud as the terminal action - including the "page Nish once per 6h" pattern in
`nish-only-findings-escalate-out-of-band`, and the older "fail LOUD, never degrade
silently" exception. Both of those were about not burying a fault in a log nobody reads,
and that point is now served properly: the fault goes to an agent, and if one agent
cannot solve it, to a council of agents. Failing loud survives only as a VISIBILITY
mechanism for agents and monitors - a `failed` unit is a work item in progress, never an
outcome, and never a message addressed to Nish.

Binds every agent and every watchdog on the Mac and the VPS, interactive or scheduled.
Origin: 2026-08-24, after `gha-stuck-run-watch` was built to email him about stuck
GitHub Actions runs instead of cancelling them and dispatching the repair. Related:
"Never relay a finding you could act on", "Interventions get eliminated, not repeated",
"Broken means fix it, now, without being asked".

## Pi extensions: prefer them, but install only the proven (Nish, 2026-08-24)

**"pi has useful extensions that solve for this, but only battle tested and proven one's
may be installed - save for all agents"**

Two halves, and both bind:

**Reach for Pi's extensions before writing anything.** Pi ships 79 example extensions
under `~/.local/lib/node_modules/@earendil-works/pi-coding-agent/examples/extensions/`
plus `docs/` (extensions.md, sdk.md, models.md, providers.md). `subagent/` alone ships
scout/planner/worker/reviewer agents, per-agent model selection, parallel fan-out, and
the /implement, /scout-and-plan, /implement-and-review prompts. Roughly 20,000 lines of
hand-built control plane were written on this box and then deleted because it duplicated
what Pi already shipped. Read the examples before writing orchestration, dispatch,
queueing, scheduling, handoff, spec gates, or reporting. A hand-built fork of a stock
extension is the known failure mode.

**But shipped is not the same as proven.** An extension existing in the examples
directory is not a licence to install it. Before any extension is installed for real use:
1. Exercise it on a genuine task in this environment, not a toy, and keep the run log.
2. Confirm it behaves under this box's actual constraints - the seats in models.json, the
   depth-1 spawn guard, systemd-run ownership, the lane concurrency caps.
3. Record what was proven, and where the log is, so the next agent does not re-audition it.
An extension that fails that bar stays uninstalled and its absence is documented with the
reason. "It ships with Pi" is not evidence; "it ran this real job and here is the log" is.
This is the same discipline as the Ollama catalog-audition ban - auditioning everything
available is how a quota gets burned for nothing.

Applies to every agent on the Mac and the VPS. Related: "Everything runs through Pi,
directly. No launchers.", "Find the proven thing before you build anything", "Switched on
and proven, or it is not done".

## Ambiguity resolves to the authoritative recommendation, not to Nish (Nish, 2026-08-24)

**"Anything of this nature (ambiguous) should be ideally automatically and autonomously go
for top dev recommendations and be then done automatically and autonomously. only The
genuine gray area or ambiguous area once come to me, and that should be an exception, not
the norm."**

When a decision is underspecified, the default is neither to ask Nish nor to improvise from
whatever the agent happens to believe. It is to go and find what the field actually
recommends, implement that, and record where it came from. In that order, stopping at the
first that answers the question:

1. **Official vendor documentation** for the exact thing being configured. Behaviour 1:1
   with the docs when they cover it. Use Context7 or fetch the docs directly - do not answer
   from memory, because memory is where stale defaults live.
2. **Current practitioner consensus** where the docs are silent on judgement (cost, cadence,
   layout, ordering). `/last30days` exists for this; so does ordinary search. Prefer
   recent - a 2023 recommendation about a 2026 product is a guess wearing a citation.
3. **The proven thing already in this fleet.** If a sibling repo solved it and the solution
   is running, copy that rather than inventing a second answer. Two different answers to the
   same question inside one fleet is a defect.

Then implement it autonomously and cite the source in the PR or the log. An agent that
improvises a plausible-sounding policy when an authoritative one exists has done the work
twice as badly for no reason - and an agent that escalates an answerable question has spent
Nish's attention on something a search would have settled.

**Why this rule exists:** on 2026-08-24 an agent wrote a GitHub Actions cost-reduction brief
from its own reasoning. It was plausible and it was wrong in two ways that only surfaced when
Nish said "fix according to top dev recommendations": it missed that a job with no
`timeout-minutes` can burn 360 billable minutes (12% of the monthly allowance) from one hung
step, and it would have put path filters at the workflow-trigger level, which makes a
*required* status check report "skipped" and silently blocks every merge in the repo. Both are
documented. Neither was guessable.

**Stakes decide whether research is the WHOLE answer or only the first half**
(Nish, 2026-08-24, sharpening this the same day): *"If it's high stakes, it should look up
authoritative practices AND also escalate because it's a gray or ambiguous area. So, better
that the agents confer amongst themselves with full context AND knowledge."*

- **Ambiguous + ordinary stakes** -> look up the authority, implement it autonomously, cite
  the source, done. No council, no escalation. This is the common case and it should stay
  the common case.
- **Ambiguous + HIGH stakes** -> do BOTH, in this order. Research first, then convene the
  council, and hand the council the research. The lookup is not an alternative to conferring
  when the stakes are high; it is the precondition for conferring well. A council that
  deliberates without the documented answer in front of it is three models trading opinions,
  which is worse than one model reading the docs. Full context AND knowledge, then confer.
  The council still resolves it autonomously if it can - escalating to Nish remains the
  exception inside the exception, reserved for when the council itself concludes the matter
  is genuinely sensitive or genuinely gray.

**High stakes means** any of: money or billing; authentication, secrets, or security posture;
customer data, especially deletion; production deploys, schema changes, or migrations;
anything irreversible or hard to reverse; anything that can block the whole fleet or every
merge in a repo; a release gate or the evidence one depends on; a public-facing surface or
brand. When unsure whether something is high stakes, treat it as high stakes - the cost of an
unnecessary council is a few minutes of compute, and the cost of a solo wrong call on any of
the above is not.

**What still counts as a genuine gray area** - and therefore may go from the council to Nish,
the council being the only thing that may reach him (see "Watchdogs dispatch agents, they
never page Nish"): authorities that genuinely conflict; two of Nish's own instructions that
genuinely conflict; money, legal, brand, product direction, customer-data deletion where no
autonomous option remains; an irreversible one-shot public action whose timing is his. "I
could not find a recommendation" is not a gray area until the search has actually been done
and reported.

Binds every agent on the Mac and the VPS. Related: "Find the proven thing before you build
anything", "Pi extensions: prefer them, but install only the proven", the Research & Reuse
step in the development-workflow rules, and the pre-implementation contract.

## No hand-built orchestration. Ever. (Nish, 2026-08-24 — FORBIDDEN, non-negotiable)

**"wipe all your stupid shit and make sure it never happens again! none of the agents do this
nincampoop shit again ever across mac & vps, its forbidden, non negotiable"**

On 2026-08-24 an agent wrote **2,559 lines of bash in one afternoon** — `gha-stuck-run-watch`,
`pi-packet-watch`, `agent-council`, `seat-health` — hand-rolling retry counters, cooldown
timestamps, flock mutexes, attempt ledgers, tombstones, no-op detection, poll loops and a
multi-round council. All of it was deleted the same day on Nish's order. This is the SECOND time:
~20,000 lines of control plane were deleted on 2026-08-23 for the same reason.

**The prohibition.** No agent, on the Mac or the VPS, may hand-write orchestration machinery:
dispatchers, queues, schedulers, retry engines, cooldown/backoff logic, attempt ledgers, lock
managers, liveness pollers, health registries, or councils-as-scripts. Not as a stopgap, not
"just for now", not "until the proper thing exists". If you are writing a loop that polls for
failure, or a counter that decides when to give up, **stop — you are writing the forbidden
thing.**

**Use the substrate that already exists.** systemd is already the supervisor on these machines
and already provides, quoted from its own man pages:
  - `OnFailure=` — "units that are activated when this unit enters the 'failed' state".
    Event-driven; replaces every poll loop.
  - `Restart=` / `RestartSec=` — restart policy and the delay before it. Replaces retry counters
    and hand-written cooldowns.
  - `RestartSteps=` + `RestartMaxDelaySec=` — escalating backoff, built in.
  - `StartLimitBurst=` / `StartLimitIntervalSec=` — give-up thresholds. Replaces attempt ledgers.
  - `RuntimeMaxSec=` — hang detection. `WatchdogSec=` + `sd_notify` — real liveness.
  - `Restart=` deliberately does NOT fire when death is "a result of systemd operation (e.g.
    service stop)" — so the tombstone mechanism hand-built that day to stop a deliberately-killed
    job being resurrected was never needed. That bug (a watchdog reviving a job stopped on
    purpose, recreating the collision the stop prevented) could not have existed.
Beyond systemd: Pi's 79 shipped example extensions (`subagent` especially), and for genuinely
distributed durable execution, a real engine — never a bash reimplementation of one.

**Why, with the day's evidence.** Home-grown retry logic, state-file polling and cron-driven
recovery is a named industry anti-pattern: crashes desync state, work is lost or repeated, and
custom control planes characteristically fail at the exact moment they are needed. All of that
happened within hours of writing it: the orchestrator's own monitors died when its session
restarted, orphaning four tasks; two workers exited status 0 having done NOTHING and were
invisible to both systemd and the watchdog; a watchdog resurrected a deliberately-stopped job; a
watchdog attempted 15 dispatches for one unfixable fault in 2 minutes and only a flock stopped a
runaway; and a single-record health file could not describe the seat being asked about, so work
was routed twice into an exhausted one.

**If a capability is genuinely needed** and no existing substrate provides it, that is a
high-stakes ambiguous question: research the authoritative answer, then convene a council — see
"Ambiguity resolves to the authoritative recommendation, not to Nish". It is never a licence to
hand-roll one quietly. Deleting lines is a better deliverable than adding them.

Binds every agent on the Mac and the VPS, interactive or scheduled. Related: "One fleet" ->
"No second dispatcher, ever", "Everything runs through Pi, directly. No launchers.",
"Find the proven thing before you build anything", "Pi extensions: prefer them, but install only
the proven".

## CI standard: batched, minimal, near-zero failures — every repo, current and future (Nish, 2026-08-24, NON-NEGOTIABLE)

**"runs should be according to top dev reccos - batched and minimal to zero failures + whatever
extra research got you from top devs inculcated automatically in all current and future repos as
a non negotiable rule"**

Context that makes this binding rather than advisory: self-hosted runners were retired on
2026-08-24, which moved five private repos from free VPS CPU onto the metered GitHub allowance
for the first time. The allowance is 3,000 minutes/month against roughly 2,900 PRs/month. That
is about **one minute of CI per pull request**. There is no slack to waste.

### The standard — every job, every workflow, every repo

1. **`timeout-minutes` on EVERY job.** Non-optional and the highest-leverage item. A job without
   one may run to GitHub's documented 6-hour hosted maximum — 360 minutes, 12% of the monthly
   allowance, from one hung step. It is also the documented prevention for the failure that cost
   this fleet 25 hours: *"Adding a timeout to jobs using timeout-minutes prevents zombie runs
   from blocking concurrency groups indefinitely."* Set it from the job's own observed duration
   (~2-3x normal), never a blanket 360.
2. **`concurrency` + `cancel-in-progress: true`** on pull_request and ordinary push. Reported to
   cut usage ~20% alone where pushes are frequent, which describes an autonomous fleet exactly.
   **NEVER** on deploy, release, migration or backup workflows — cancelling those mid-flight is
   dangerous.
3. **Dependency caching** — `actions/cache`, or the `cache:` input on `setup-node`/`setup-python`
   etc. Turns a three-minute install into ~15 seconds; hash-keyed caches typically cut 30-50% off
   CI time. Note caches have their OWN 10 GB/repo quota and do not count against artifact storage.
4. **Batch the workflows.** One workflow per event, not three. Running `CI`, `Secret Scan` and
   `Review gate` separately on the same trigger pays three runner boots, three checkouts and
   three installs before any real work.
5. **Run only what changed** — but path-filter at the **JOB** level, never the workflow trigger
   level, on anything that is a REQUIRED status check. A required check filtered at trigger level
   reports *skipped*, and branch protection then waits forever for a result that never arrives:
   every PR in the repo becomes unmergeable. Gate the expensive jobs inside the workflow so the
   check still reports.
6. **`fetch-depth: 1`** unless a job genuinely needs history.
7. **`retention-days`** on artifacts. Load-bearing release evidence belongs in durable object
   storage (R2/S3) with a lifecycle policy, NOT in long artifact retention — artifacts have a
   hard 1-90 day ceiling and are documented as ephemeral CI byproducts.
8. **Near-zero failures, because batching multiplies them.** Measured fleet failure rate was
   24.8%. Separate deterministic breakage (fix or delete it — a permanently-red check is worse
   than no check, it trains everyone to ignore CI) from genuine flakiness (quarantine OUT of the
   gating suite but still running and reporting, with an OWNER, a TICKET and an SLA — quarantine
   without an owner is deletion with extra steps). Retries: **zero locally** so developers feel
   their own flakiness, **exactly two in CI** because the pass-on-retry rate is what defines
   flakiness; more than two hides real regressions and burns minutes.
9. **Never weaken to save money.** No test removed, no scan dropped, no required check made
   non-blocking, no check left unable to report. Cheaper is the goal; absent is not.
10. **No CI that watches CI.** Queue watchdogs, conflict watchdogs, duplicate guards and
    repair-runner workflows are the forbidden pattern living in GitHub instead of bash. Eight were
    disabled on 2026-08-24. See "No hand-built orchestration. Ever."

### PR volume: fewer TRIVIAL PRs, never fatter ones (Nish, 2026-08-24, confirmed "100%")

Small pull requests are better - they review faster, get better review, carry less risk. So
"reduce PR volume" must NEVER be read as "combine unrelated work into bigger PRs". That trades a
money problem for a quality problem and is forbidden.

The volume comes from TRIVIAL PRs, and that is what stops:
- No separate PR for a one-line fix, a doc tweak, a lint fix, or a comment change. Fold it into
  the change it belongs with, or batch it with the other trivia from the same session.
- Dependency bumps are GROUPED, not one PR per package - Dependabot's own `groups:` config does
  this, and it is a config change, not machinery.
- No PR that exists to fix the cost of PRs, past the first one. On 2026-08-24 agents were opening
  PRs titled "ci: concurrency + shallow checkout" and "ci: consolidate PR workflows" across
  repos - correct once, a new steady state if unwatched.
- No PR re-doing work an open PR already covers. Check before opening.

The arithmetic that forces this: ~2,900 PRs/month against 3,000 Actions minutes is ~1.03 minutes
of CI per PR. Every CI optimisation stacked perfectly still lands at ~3,029 min - dead on the
line - because optimisation attacks the numerator and then runs out. The denominator is PR count.
Related work that genuinely belongs together in ONE reviewable change was always supposed to be
one PR; this rule is that discipline, not a licence to bundle.

### How it applies automatically — the mechanism, not a script

**Reusable workflows from ONE central repository.** This is GitHub's own feature and the
documented answer for enforcing standards across many repos: define the workflow once, reference
it everywhere with `uses:`, and *"updates and changes propagate automatically to all dependent
repositories"*. Host them in a dedicated, effectively read-only repo (e.g. `shared-workflows`).
A consuming repo carries a few lines, not a copy. Practitioner rule: **never override the called
workflow's critical steps in the caller** — if a repo needs different behaviour it passes
`inputs`.
New repos start from a template repo already wired to the shared workflows, so "current and
future" is satisfied by construction rather than by anyone remembering.
(GitHub's *required workflows* / repository rulesets would enforce this centrally, but they are
organization-only and this is a personal account — noted so nobody re-proposes it.)

Building or hand-rolling any other enforcement mechanism is forbidden under "No hand-built
orchestration. Ever." Binds every repo on both machines, existing and yet to be created.

## Engineer reversibility, don't gate (Nish, 2026-08-24 — fleet default)

**"Irreversible ones should clearly be reversible? That would then make everything
possible to go?"** The answer to "this is risky so a human must approve it" is
almost always "make it revertible in under two minutes and stop asking."
Optimise time-to-recovery, not permission. Reversibility is not binary — it is
the SIZE OF THE DAMAGE WINDOW: a deploy reverted in two minutes is genuinely
undone; a secret exposed for two minutes is not. Optimise the window for STATE;
refuse to automate DISCLOSURE.

Applied: deploys auto-rollback on failed verification (wrangler-native, proven
live 2026-08-24); red main auto-reverts via platform primitives (workflow_run +
git revert + auto-merge — git is the last-good record, never a SHA ledger);
branch/file deletion is already reflog-reversible. Full record:
`~/.local/state/agent-council/fleet-shape/FABLE-VERDICT.md` §17.

**PERMANENTLY GATED, NISH-RESERVED FOREVER — no engineering makes these undoable
(the damage is disclosure/external effect, not state), and no agent may extend
the reversibility principle into this list:** secret exposure; making a private
repo public; outbound communication (email, posts, anything a human reads);
customer-data deletion (tested-backup restore only); payments. No agent
confidence level overrides this list.

## Merge and deploy gates LIFTED on the canonical fleet repo (Nish, 2026-08-24)

Nish, verbatim, same day: "I want it completely autonomous and automatic duhh"
(merge half) and "I want auto deploy too duhh, everything in the pipeline has to
be automatic and autonomous just with everything going through the highest
quality of standards" (deploy half). SCOPE: Nishfleet/siterep-public (the
canonical repo) and its deploy chain — rollout wider only when its gates exist
there too. This SUPERSEDES "Products are PR-only. Never merge, never deploy
without Nish" for that scope. The condition IS the spec: four required status
checks gate every merge (verify, Gitleaks, classify, semgrep); armed auto-merge
lands PRs only on green; deploys run drift-tick → deploy → immediate SHA+canary
verification → wrangler-native auto-rollback; red main auto-reverts (proven
end-to-end 2026-08-24, red 17:48Z → green 18:03Z). A worker asked to act inside
this scope must not refuse on the old gate — the lift is recorded HERE, in the
canonical file, precisely so packets can be trusted. Full record:
~/.local/state/agent-council/fleet-shape/FABLE-VERDICT.md §8/§17/§22.

## Agent-authored PRs land themselves (Nish, 2026-08-25 — "automatic / autonomous ... for all repos, current and future")

Origin: an agent closed a green-checked docs PR (0509 #1019) with "ready for the
merge queue whenever you merge it"; Nish: "yea, shouldn't this be automatic /
autonomous?" then "make sure it happens automatically and autonomously from
hereon ... for all repos, current and future" and "for all agents across mac &
vps".

**The rule, binding every agent on both machines:** when you author a PR for
tasked work, arm it to land in the same turn you open it — `gh pr merge <PR>
--auto --squash` immediately after `gh pr create`. Required checks and merge
queues remain the quality gate; --auto only removes the human wait. Report the
PR as merged/queued, never as "awaiting merge". Opening a PR and handing the
merge to Nish is the same failed pattern as reporting a finding without fixing
it.

Exceptions (the ONLY ones): scheduled sweep PRs (autoreview/refactor cron —
those stay never-merge by design); repos/paths under a hands-off.md flag;
Nish-gated deploy actions (merging never deploys — deploy gates are unchanged
by this rule). Everything else self-lands.

Mechanics: `allow_auto_merge` was enabled 2026-08-25 on every current repo that
can take it. It CANNOT be enabled on private Nishfleet-org repos (org is on the
GitHub free plan — paid feature there): currently 0509-telemetry, fleet2,
egress-probe. In those repos, watch required checks and `gh pr merge --squash`
directly once green. When creating a NEW repo, enable auto-merge as part of
setup: `gh api -X PATCH repos/<owner>/<repo> -f allow_auto_merge=true`.
Never make a private repo public to unlock this — that action is permanently
Nish-reserved (see the gated list above).

**Mechanical enforcement (agent-agnostic, the primary layer):** every active
repo carries `.github/workflows/auto-merge-arm.yml` (canonical copy:
`Nishfleet/siterep-public`), which arms auto-merge on every non-draft PR at
open — no matter which agent, tool, or human opened it, so the flow survives
any one agent running out of usage. Opt-outs are mechanical too: DRAFT PRs,
the `no-auto-merge` label at creation, or `[no-merge]` in the title. Any
future scheduled sweep that must never self-merge MUST open draft PRs (as of
2026-08-25 the old autoreview/refactor sweep cron jobs no longer exist in
`hermes cron list` — the doc describing them is history). The workflow arms
with AUTO_REVERT_PAT so resulting merges still trigger main-push workflows
(deploy verification, auto-revert); a missing PAT fails loud. Drift and future
repos are covered by the daily `repo-standards-reconcile` systemd user timer
on the VPS (script: `~/.local/bin/repo-standards-reconcile`), which enforces
`allow_auto_merge=true` and the workflow's presence across ALL Nishfleet +
nish3451 repos, and by `nish3451/node-repo-template` carrying the workflow.

Secondary, agent-side redundancy: a Claude Code PostToolUse hook
(`~/.claude/hooks/pr-automerge-reminder.sh`) injects this order after any
`gh pr create`. LIVE on the VPS; Mac install queued in
`00 Inbox/agent-drop/claude/vps/2026-08-25-install-pr-automerge-hook-on-mac.md`
(first Mac Claude session: do it, delete the work item, update this line).
Other agents (Codex, Sol, Pi packets) are bound through this file;
orchestrators carry the rule into worker packets that open PRs.

## All functions mechanical (Nish, 2026-08-25)

Nish, verbatim: "pls do it for ALL functions and all functions should ideally
be mechanical. yea?" and "Across all repos. Future and current automatically."
Context: any single agent can run out of usage; a standing behavior that lives
only in one agent's config (or only in prose) dies with that agent's quota.

**The rule:** every standing behavior gets enforced at the most agent-agnostic
mechanical layer available, in this order of preference: (1) the platform
itself (GitHub repo settings, required checks, merge queue, branch
protection); (2) repo CI workflows (run for every author identically); (3)
host-level units (systemd timers/path units on the VPS); (4) agent-specific
hooks — redundancy only, never the primary enforcement. Prose in this file
states the intent; something mechanical must enforce it. When you add a new
standing behavior, ship its mechanical enforcement in the same change, per
"switched on and proven". Existing standing orders are being audited for
mechanization — work item in the vault inbox.

## Standing machinery is agent-agnostic — the boundary and its enforcement (Nish, 2026-08-25)

**The line:** anything that SCHEDULES, GATES, STORES FLEET STATE, or DELIVERS is standing
machinery and MUST be agent-agnostic — substrate ladder: GitHub-hosted (Actions,
marketplace actions) > systemd user units + `pi` (multi-provider transport) >
agent-specific (forbidden without a named, Nish-approved exception recorded here).
Agent-PRIVATE things (an agent's own memory, config, credentials) are exempt by nature.
Delivery-only coupling (e.g. a Telegram notification path) is tolerable ONLY if losing it
loses notifications — never state, scheduling, or gating.

**Named exceptions (the complete list — additions need Nish):**
- (none — the list is EMPTY)

**Reclassification (2026-08-25, orphan-janitor generalization):** the previous 3-item
exception (Sol/codex wrapper, `agent-governor-orphan-watchdog.timer`,
`codex-remote-control.service`) is dissolved as follows:
- `codex-remote-control.service` and the `codex` wrapper are EXEMPT agent-private runtime —
  Sol's harness, the same class as Claude's own daemon. They are not "named exceptions" to
  the agent-agnostic rule; they are an agent's own runtime, exempt by nature (the rule's
  existing "Agent-PRIVATE things ... are exempt by nature" clause). They die together with
  Sol if Sol is ever retired, never separately.
- `agent-governor-orphan-watchdog` (now `agent-orphan-watchdog`, old name symlinked) is
  GENERAL fleet machinery and COMPLIANT, not an exception. It reaps any process carrying
  the governor marker (`AGENT_GOVERNOR_MANAGED=1`) whose supervisor is gone — agent-agnostic
  by construction (codex, pi, claude, or any future harness that adopts the marker
  contract). Unmarked processes, tmux work, and unrelated services are never touched. The
  Nish non-negotiable on its safety semantics stands; its classification changes from
  exception to compliant machinery.
- The named-exception list is therefore EMPTY.

**Mechanical enforcement (non-negotiable, "make sure it actually works that way"):**
1. Guard library: nish-vault/_system/shared-memory/guards/ — canonical logic, born-agnostic
   rule; per-harness hooks are 3-line shims only.
2. Keystroke layer: agent-scheduler guard blocks creating jobs in agent-product schedulers
   from any wired harness.
3. State layer: agent-scheduler-drift.timer (nightly, fail-loud) diffs real scheduler state
   vs agent-state/agent-scheduler-allowlist.txt. Scope extends to: shim integrity (hook
   files must remain shims — logic creeping back into a harness dir is drift), and standing
   units referencing agent-private state dirs.
4. Baseline: agent-state/agent-agnostic-audit-2026-08-25.md (inventory + verdicts); every
   VIOLATION there carries a migration verdict and dies by migration, not by exception.
An allowlisted grandfathered job is visible debt, not compliance.
`session-memory-draft.py` and equivalents are EXEMPT (agent-private session memory). Full
inventory: agent-state/agent-agnostic-audit-2026-08-25.md.
Amendment (2026-08-25, Nish: "No grandfathered non compliance debt allowed at all"): the
grandfathered category is ABOLISHED. The scheduler allowlist may contain ONLY (a) compliant
machinery and (b) exceptions Nish has named in this file. Anything else found there is a
violation to migrate-or-remove IMMEDIATELY (export config to agent-state first — delete
nothing unrecoverable). The earlier "visible debt" tolerance line is superseded.

## Execution IS the review — run it, log the bugs, fix, run again (Nish, 2026-08-25 — non-negotiable)

**"Three real bugs, all found by actually running it."** That is the point. Static
review found none of them; a single real execution found all three in under a
minute. Reading the code you just wrote proves nothing — you already believe it
is correct, which is exactly why you wrote it that way.

The rule, for every agent, both machines, all repos:

1. **Anything built to run, gets run before it is called done.** Not the unit
   tests around it — the thing itself, end to end, in the environment it will
   actually live in. Building the machine includes starting the machine
   (see "Switched on and proven").
2. **When the real run is destructive, stub the smallest possible edge** and run
   everything else for real. Stub `sudo`, stub the reboot, move a trigger file
   aside — never stub the logic under test. A test that exercises a different
   code path than production is not a test, it is a rehearsal of a fiction.
   Restore the fixture in the same turn you created it.
3. **Every bug the run surfaces becomes a work item immediately** — fixed in the
   same turn if it is yours, filed to the agent-ready queue if it is not.
   A bug named in chat and not queued is a bug that was never found.
4. **Loop until a clean run, not until you are out of ideas.** Re-run after every
   fix. Each run tends to expose the bug the previous bug was hiding: the
   maintenance-window build went run → 3 bugs → run → 2 more → run → 1 more →
   run → clean. Stopping at the first green *phase* rather than a green *run* is
   the failure mode.
5. **Distinguish the three outcomes and never conflate them:** a FAILURE (fix
   it), a SKIP (a thing that cannot work by design — report it every run so it
   never silently drifts), and a PRE-EXISTING fault the run merely exposed (fix
   it too, per "Broken means fix it, now" — the window that exposed the orphaned
   `inish-publish-on-token.path` owned disabling it).
6. **A run that exposes nothing is evidence about the run, not the code.** If a
   real execution surfaces zero findings, ask what the run did not exercise
   before believing it is clean.

Senior-auditor review is a **complement, never a substitute**: route it at the
existing review gates (`sgscan` → `crgate` → tests/live E2E → `autoreview` →
Greptile) once the thing already runs clean. Auditing code that has never
executed spends flagship tokens re-deriving what one run would have printed.

Canonical worked example: `~/.local/bin/vps-weekly-update` and the four cycles in
`~/.local/state/vps-maintenance/update.log`.

## Never decide by vibes — always measure (Nish, 2026-08-26)

**"never take decisions by vibes - always measure!!"** Binds every agent on both
machines, Mac and VPS, interactive and unattended. Non-negotiable.

Any number that drives behaviour — a concurrency cap, a memory budget, a
timeout, a retry count, a threshold, a rate limit — must come from a
measurement you actually took and can show, not from a plausible-sounding
default. "1.5 GB per worker feels right" is not an input. `MemoryPeak` across
N real runs is.

The rule in practice:

1. **State the measurement before the decision.** Command run, sample size,
   the numbers. A recommendation without those is not finished work.
2. **Say the sample size out loud.** Four observations is four observations;
   do not present it as a distribution. If N is too small to decide, the
   deliverable is *instrumentation*, not a guess dressed as a conclusion.
3. **Prefer p95 over mean** for anything protective (memory, timeouts) — the
   tail is what takes the box down, not the average.
4. **An inherited constant is not evidence.** A number already in a config
   file was somebody's guess until proven otherwise. Measure before defending
   it, and never cite it back as justification.
5. **If you cannot measure it, say so explicitly** and name what would have to
   be instrumented. Never silently substitute intuition.

Origin: 2026-08-25/26. The fleet's RAM governor had `ram_gb_per_worker: 1.5`,
an unmeasured constant, sitting on top of a unit bug that made the governor
return 6647 workers instead of 6. Measured `MemoryPeak` across real units came
out 0.08 / 0.17 / 0.75 / 2.66 GB — nothing near 1.5, and a 30x spread between
the smallest and largest. Both the guess and the bug survived because nobody
measured.

Corollary: the same applies to claims about *state*. "The seat works" needs a
probe with its output shown, not an inference. A probe that greps for the wrong
string is not a measurement either — on 2026-08-25 that produced a false
"grok OK" that stood until it was retested properly.

## Check for other agents before touching shared files (2026-08-26)

18 interactive sessions were live on the VPS at once on 2026-08-26. Two of them
independently found and fixed the same `seat-lib.sh` cap-map bug within the
hour — PR #44 and PR #48 — because neither looked for the other. That is not
bad luck at 18 sessions; it is the expected outcome when nothing checks.

Before editing anything shared — fleet control plane, systemd units,
`seat-lib.sh`, `seat-caps.json`, hooks, this file — check whether another agent
is already on it:

1. **Open PRs touching the file** are the agent-agnostic signal, because every
   agent pushes to GitHub regardless of which product it runs on:
   `gh pr list -R <repo> --state open --json number,title,author,files`
2. **`ListAgents`** shows live peer sessions; `SendMessage` reaches one directly.
   Ask before duplicating, and say what you are about to touch.
3. **A claim branch** (`claim/issue-N`) is the fleet's existing atomic lock for
   queued work. Interactive sessions bypass it, which is exactly the hole.

On the VPS a `PreToolUse` hook (`guard_shared_file_collision.py`) warns on
Write/Edit to those paths when an open PR already touches the same basename.
It warns, never blocks — a second agent on the same file is often legitimate,
and a false block during control-plane repair is worse than a duplicated diff.
The hook only covers Claude sessions and only once a PR exists, so it narrows
the window rather than closing it: the check above is still the agent's job.

## Memory: prevent, throttle, then kill — in that order (Nish, 2026-08-26)

**"the 13gig soft cap exists so killing should be the exception, not the norm."**

Three layers on the VPS, and they must stay in this order. Never reach for a
lower one to paper over a broken upper one:

1. **Prevent** — `MIN_FREE_RAM_MB=2500` launch floor, a ~13.1 GiB soft cap on a
   15.61 GiB box. Refuses to *start* work when free RAM is below the floor.
   This brake should do essentially all the work. It is recomputed on every
   call, so the ceiling rises as memory frees rather than being a fixed number.
2. **Throttle** — per-worker `MemoryHigh=3G` / `MemoryMax=6G`. cgroup reclaim
   slows one worker down. Nothing dies, no work is lost.
3. **Kill** — `systemd-oomd`, `ManagedOOMMemoryPressure=kill` at **80% / 60s**
   on the worker slice only. Last resort, and only when 1 and 2 have both
   failed.

Installed 2026-08-26. Before that there was no reactive manager at all — the
kernel OOM killer was the fallback, and it picks arbitrarily.

Rules that come with it:

- **Scope the kill policy to the work slice.** sshd, tailscaled, the fleet
  heartbeat and the intake timers stay `auto`. An OOM manager that can take
  the box's lifelines, or the supervisor that would repair a reaped worker, is
  worse than none.
- **Set thresholds from measured baseline, then check against practice.**
  systemd defaults to 60%/30s; Fedora ships 50%/20s for latency-sensitive
  desktops. A batch fleet should sit well above both — a throttled worker
  finishing slowly beats a killed worker losing its work.
- **Do not kill on swap.** Swapped-out pages of workers idling on API calls are
  healthy. `ManagedOOMSwap` stays off.
- **An OOM policy is unproven until a drill shows it firing** on the intended
  cgroup while the lifelines survive. systemd/systemd#33486 documents pressure
  limits silently not firing.

## Everything is mechanical — failures included (Nish, 2026-08-26 — NON-NEGOTIABLE)

One rule, one grep target. It restates what the 08-22 "Every finding gets
queued" line, "Fix it, don't report it", and the plumbing ban already implied —
the delta is ENFORCEMENT, because prose alone is how tonight's seven dropped
balls happened.

- A failure is not fixed until its CLASS is mechanically prevented: fix the
  instance, then ship the mechanism — a detector whose alarm auto-files the
  ticket, a gate that rejects the pattern at merge, a regression test or drill
  that PROVES the guard fires, and observe-to-close (the ticket closes only
  when the detector goes green on a real run — never because a PR merged or
  someone wrote "fixed"). If no mechanism can exist, the fix carries an
  explicit `mechanism-impossible: <reason>` line, judged by the conference and
  re-litigable by the blind audit.
- Beyond failures: any action a human or flagship performs by hand more than
  once — starting a unit, labeling an issue, reading a report for findings,
  verifying a delivery, routing to seniors, checking claims — is a machinery
  defect; the second occurrence requires shipping the mechanism that removes
  the hand. Flagships orchestrate, judge, and verify; hands belong to the
  machinery.
- Enforcement itself is mechanical (Nish, same day: "no stone unturned"):
  every rule in this file and every non-negotiable ledger line must name its
  live enforcer in the machine-readable rule-enforcement matrix; the heartbeat
  canary diffs this file against the matrix every cycle and goes LOUD on any
  rule without one (fleet-ops #383). A rule that exists only as prose is a
  defect of this file.
- The hunt is itself mechanical: the blind audit + gap-closure loop carry a
  standing manual-seam lens every cycle (fleet-ops #377) — never dependent on
  Nish asking. Enforcement lives at the senior conference (#366: failure-fix
  diffs without a mechanism auto-reject) and in the recurring audit.
- Nish-reserved actions (money, legal, product direction, customer-data
  deletion) are the only accepted-manual tier, and even those get enumerated,
  not assumed.

Origin: 2026-08-26 night — seven dropped balls (closed-but-undelivered #221/
#76/#124/#223, SKIP spam post-fix, stale blockers parking #180, swallowed
journals, an audit armed but never run) all traced to rules without mechanisms.

## Legit work only — no spinning wheels, fleet-wide (Nish, 2026-08-28)

- Applies to ALL repos and ALL work, every lane, every agent: only legitimate,
  gated work may occupy a lane. An item qualifies only by passing the existing
  spec/quality gates and tracing to a live observed defect, a standing quality
  bar, or Nish-decided direction. Self-generated polish loops, churn-class
  make-work, and machinery-on-machinery busywork are forbidden everywhere —
  not just in band-surge lanes. Idle is better than illegitimate work.
- Corollary: "let the fleet go to max" (band inversion, same day) is
  conditional on this rule — expansion admits only qualifying items.
- Enforcer: the legit-work gate implemented by fleet-ops#1516 (band inversion)
  MUST register this rule in config/rule-enforcement.json as part of landing;
  until then the heartbeat canary correctly flags this rule as
  mechanism-pending. Churn measurement: the standing quality metrics
  (upgrade/repair/churn baseline).

Origin: Nish, 2026-08-28 — "no spinning wheels / endless polishing work
allowed on my vps... this law should be fleet side btw (applies to all
repo's and all work)".

## Quality is a constraint, never a trade-off (Nish, 2026-08-28)

- No layer of the fleet may trade quality for throughput, ever. Quality gates
  are hard constraints: throughput is maximized SUBJECT TO them, and any
  design, dispatch, review verdict, or dial change that relaxes a quality gate
  to gain speed is invalid on its face — not weighed, REJECTED. "Both dials
  up" means throughput rises only through capacity, latency, and waste
  removal, never through gate relaxation.
- Mechanical enforcement, layer by layer: (1) merge layer — required CI
  checks + auto-revert on red main; (2) closure layer — user-facing work
  cannot close without live proof (0509#1365 detector rules) and null-diff
  merges never count; (3) dial layer — the WFR ratchet is tighten-only; any
  loosening requires Nish's explicit, logged waiver; (4) proposal layer — the
  senior conference treats quality-gate relaxation as out-of-scope input, the
  same class as an unauthorized machinery build; (5) metric layer — the
  success number is VERIFIED throughput only (#1136), so gamed speed cannot
  even be scored.
- Enforcer registration: fleet-ops#1516 and #1136 must register this rule in
  config/rule-enforcement.json as they land; until then the heartbeat canary
  correctly flags it mechanism-pending.

Origin: Nish, 2026-08-28 — "No quality trade-offs accepted - mechanically
banned by every layer", refining same-day "max *quality* throughput because
*quality* above all else".
