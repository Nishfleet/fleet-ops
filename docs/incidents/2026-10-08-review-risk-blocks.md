# 2026-10-08 Reviewer bot blocked PRs whose review said "No blockers"

## Impact
0509 #7276 (head d0c3e0fe) and #7257 (four heads, last f18630d0) got `blocked` although the review text listed only `risk` and `nit` lines. Almost nothing needing the bot merged for hours, and authors pushed a fix per round for notes that were not defects.

## Cause
The prompt asks for three labels (`blocker`, `risk`, `nit`), but the Jev question that decides defined block as "a blocker or a risk". Any risk line blocked, so the labels did nothing, and a reviewer told to find what would hurt nearly always lists a risk.

## Detection
Coordinator read the #7276 comment on 2026-10-08; AUDIT FIXES saw the same pattern on #7257.

## Fix
Nish approved on 2026-10-08 ("let the reviewer bot approve when it finds no blockers"). Jev's block criterion is now "at least one blocker line, or the review is empty or unclear". The prompt defines the three labels so `blocker` is a real stop. The approval comment still prints risk and nit lines, and approval still needs probability 0.9.

## Prevention
Held-out scoring is still owed (AGENTS.md line 21): run the bot on past risky PRs, including 0509#7092, which must still block, and count real defects labelled `risk`.
