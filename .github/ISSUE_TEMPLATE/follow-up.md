---
name: Follow-up
about: Work found while doing other work, filed so it is not lost (fleet-ops#9278 items 8 and 10)
---

<!--
Search before you file, so a duplicate is a comment on the issue that owns the
work, never a second issue:

  gh issue list -R Nishfleet/<repo> --state all -L 200 \
    --search "<the key phrase from the title> in:title" --json number,title,state

File through this template:

  gh issue create -R Nishfleet/<repo> --template follow-up.md \
    --title "<one line: the defect, not the fix>" --body-file <file>

The number this is judged on is the not-planned share of closed issues, which
`state_reason: duplicate` and `state_reason: not planned` both lower:

  gh api -X GET search/issues -f q='repo:Nishfleet/<repo> is:issue is:closed reason:"not planned"' \
    -f per_page=1 --jq .total_count

Measured 2026-10-29 on fleet-ops: 443 of 6990 closed issues, 6.3%.
-->

## Evidence

<!--
The command and its real output, or a file:line, that shows the problem. A
follow-up with no evidence is a guess, and a guess costs a worker run to
disprove.
-->

## Why not in this PR

<!--
What stopped it here: a different scope, a permission GH_TOKEN lacks, a
decision, a dependency. Name the PR or issue it came from.
-->

## Acceptance

<!--
One bullet per thing that must be true when it is done, each one a command
whose output settles it.
-->
