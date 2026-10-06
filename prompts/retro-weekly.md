/skill:retro

Run the retro over ONE WEEK of sessions on this VPS, not one session. The window
is the seven days ending at run time: compute it from today's date first
(today's IST date is the end, six days earlier is the start), and use those two
real dates everywhere below.

Sources (read-only; about 1.2 GB total, so NEVER read a file whole: use rg, jq
and counts, then read only the slices you cite):
- Claude Code sessions: ~/.claude/projects/*/*.jsonl modified in the last 7 days
  (count the files and bytes yourself with find -printf).
- Pi worker sessions: ~/.pi/agent/sessions/**/*.jsonl modified in the last 7
  days (same counting).
- Steering files the agents load: ~/.claude/CLAUDE.md, ~/AGENTS.md,
  ~/workspaces/tooling/nish-vault/_system/shared-memory/global-standing-rules.md,
  the memory index ~/.claude/projects/-home-nish/memory/MEMORY.md.
- Repos: ~/workspaces/products/{0509,fleet-ops,drive,inish-site,tinystudio-in} at
  origin/main (git show, do not check out).

Redaction rule for every quote: cite a session id and a timestamp and at most a
few words. Never paste a raw transcript line, a tool result or a config value
into the report or the issue body, and never copy a token, key, bearer header,
env dump, curl argv or a path that holds one, even truncated.

Count these classes across the week (each with the number, 2-3 example session
ids + timestamps, and the fix rung):
1. Main red after merge: a session merged or reported "done" while the required
   check or main's CI was red or still running.
2. Tool economy: Bash calls that EDIT files with python3/sed/perl/heredoc
   instead of the Edit/Write tool; the biggest token-wasting tool results (huge
   outputs pasted into context).
3. Corrections from Nish: user turns that say "eli5", "file it", "do it now",
   "you sure", "why", or quote a line back. Group by cause.
4. False claims: a reply said done/merged/running and a later tool result in the
   same session contradicted it.
5. Repeated failures: the same command or the same error 3+ times in one
   session.
6. Steering no-ops: rules in the steering files that the week's sessions never
   acted on or that contradict each other.
Skip the "auto mode blocked" class: these sessions run with permissions bypassed.

Already known, do not re-report: search the issues labelled `retro` (open and
closed, created in the last 60 days) with
`gh issue list -R Nishfleet/fleet-ops --label retro --state all --search "created:>=<start-60d>"`,
and the same query on each product repo above (fall back to a `"Retro week"` in:title
search there if a repo has no `retro` label yet). Read those titles and
summaries and report only what is new. When something recurs, say how its
earlier proposed fix was picked up or not.

Output: write the report to $DELIVERABLE (the unit sets it to
/home/nish/workspaces/agent-state/retro/retro-week-<YYYY-MM-DD>.md with today's
IST date). Start with a 5-line summary ranked by severity. Each candidate: the
class, the count, the evidence (session id + timestamp, cite), the lowest-rung
fix (structure > static gate > rule > skill > prose), and the repo that owns the
fix. Times in IST. Write in plain English (~/AGENTS.md rules). Do not edit any
file except $DELIVERABLE.

Then file the report, exactly once: after the report file is written, open ONE
fleet-ops issue by piping the body into
`gh issue create -R Nishfleet/fleet-ops --title "Retro week <start>..<end>" --label retro,needs-orchestrator --body-file -`,
where <start>..<end> are this run's real window dates. The body carries the
5-line summary and the report path. Never label it `agent-ready`: workers must
never queue fleet-ops work for themselves, so a retro finding waits for a
person. If an issue with that exact title already exists, post the summary as a
comment on it instead of opening a second one. Open no other issues or PRs.

Both labels already exist (retro 5319E7, needs-orchestrator D93F0B). If the
create fails because one is missing, create that label with
`gh label create <name> -R Nishfleet/fleet-ops --color <hex> --description "Found by the weekly /retro run"`
and retry the create once. Do not retry past that.

The unit gates on your last line, so end your reply with exactly one line in
this form and nothing after it:

`RETRO_ISSUE_URL: https://github.com/Nishfleet/fleet-ops/issues/<number>`

If the report or the issue could not be written, end with `RETRO_ISSUE_URL:`
and nothing else, so the unit fails loudly instead of recording a clean run.
