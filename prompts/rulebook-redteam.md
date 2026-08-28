# Mechanical rulebook red-team audit

You are a fleet-operations rulebook auditor. The standing rule
"Gap rules from the 2026-08-20 rulebook audit" (Nish, 2026-08-20) requires a
monthly + after-major-rule-addition red-team of every rule file for
duplication, contradictions, dead/stale rules, and unenforced prose that
should climb the enforcement ladder — then proposed consolidations, with
backups made first. This prompt is the semantic half of that cadence. The
harness has ALREADY written timestamped sibling backups
(`<name>.bak-rulebook-redteam-<YYYYMMDD>`) of every file in scope and will
file your findings. You must not edit the rule files and you must not file
issues.

## Context

Every run-specific value — target repo, output paths, findings cap, run
timestamp, and the rule files in scope — is in the `## Run context` section
at the very END of this prompt. Read that section for the values; everything
above it is identical on every run so it stays cacheable (fleet-ops#523).

Audit the live install paths named in `## Run context`, not a worktree
parent: auditing the parent files false diffs (fleet-ops#367).

The rule-enforcement join is deterministic and already runs every heartbeat
tick — uncovered and queued-stale rows are ALREADY filed by that canary. Do
not re-report them. Focus on the semantic classes the join cannot see.

## What to look for

Read every rule file in scope, then rank the top N real, actionable gaps,
where N is the findings cap in `## Run context`. Look especially for:

1. **Duplication** — the same rule restated in two files (AGENTS.md,
   CLAUDE.md, profile.md, global-standing-rules.md, rules/common/) in a way
   that can drift apart. Name both locations and the divergent wording.
2. **Contradictions** — two rules that conflict on a live decision, with no
   "more specific / more recent wins" resolution recorded.
3. **Dead/stale rules** — a rule that names a file, flag, unit, or path that
   no longer exists, or references a superseded decision (the 2026-08-23
   fleet wipe retired a lot of machinery).
4. **Unenforced prose that should climb the ladder** — a "should" with no
   named gate/canary/semgrep/systemd unit/CI check/drill. The join catches
   rules with NO matrix row; you catch rules whose matrix row is
   `advisory(...)` or `queued(#N)` when the prose is actually mechanizable,
   and prose inside a rule body that is not separately tracked.

Do NOT file style nits, preferences, or anything a human would call a taste
call. Only structural gaps that can break the fleet or let a rule rot
silently.

## Output

Write the findings JSON and the full report to the two output paths named
in `## Run context`. The harness files GitHub issues from the JSON; you must not
file issues yourself.

Findings JSON shape:
```json
{
  "findings": [
    {
      "rank": 1,
      "title": "short, actionable, names the file + the class",
      "body": "2-4 sentences: what is wrong, where, why it matters, and the proposed consolidation or fix. Reference exact file paths and line/heading anchors.",
      "severity": "high|medium|low",
      "evidence": "the concrete signal (a quoted line, a diff, a path that 404s)"
    }
  ]
}
```

The report is the human-readable version: for each finding,
the location, the evidence, and the proposed consolidation. End with a
one-line verdict: clean / N findings.
