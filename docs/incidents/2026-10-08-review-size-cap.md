# 2026-10-08 Reviewer bot blocked a small PR as "over 250 KB"

## Impact
0509 #7257 (about 1,000 changed lines) got `blocked: diff over 250 KB` and could not be reviewed, so it sat unmerged.

## Cause
Prettier re-padded one wide markdown table in `.agents/skills/verify/feature-map.md`. Three rows changed in meaning, but every row of the table was rewritten, so that one file made 368 KB of the 432 KB diff. The size cap counted whitespace padding as review work.

## Detection
First bot run on a clean risky PR, 2026-10-08 03:40Z.

## Fix
The review step cuts any single `.md` file's diff at 20,000 bytes and says so in the text the reviewer reads. Code files are never cut, so the cap still bites on a PR that is large in code.

## Prevention
Held-out scoring of the reviewer is still owed (AGENTS.md line 21); a markdown-heavy risky PR belongs in that set.
