# 2026-10-08 Reviewer bot blocked PRs for problems that do not exist

## Impact
Three blocks were false: 0509 #7219 at 64838885 (cap check "not atomic") and at 498eece5 (`.reduce()` on an empty array), and 0509 #7260 at efd3f346 (`tsconfig.test.json` "not in the diff"). Each cost a push and a fresh review. On #7260 the bot had approved the same one-line change twice before blocking it.

## Cause
The review job gives the model only the PR diff, with `--no-tools --no-context-files`. It cannot see any file the diff does not touch, so a file that exists on main looks missing, and a guard clause outside the diff hunk looks absent. It is not reading a stale base: it reads no base at all. The prompt did not say so, and it let a `blocker` be reported with no input that reaches the faulty line. The verdict also flips between heads because the model fills the gap differently each run.

## Detection
SELF-MERGE compared each claim against the code on main. Cases are in the reviewer false-blockers log.

## Fix
`prompts/risky-review.md` now tells the reviewer it sees only the diff, forbids reporting something as missing because the diff omits it, and requires a blocker to name a concrete input that reaches the faulty line, else it is a `risk`.

## Prevention
Held-out scoring is still owed (AGENTS.md line 21): run the bot on past risky PRs, including 0509#7092 which must still block, and count false blockers against real ones. If false blocks continue, give the job read access to the base tree instead of prompt rules.
