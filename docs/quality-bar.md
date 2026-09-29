# Fleet quality bar

Every PR from the fleet, for any repo and any author, is held to this bar. CI is the merge gate; the coordinator reviews the risky paths.

1. Does exactly what the issue asked and nothing more, as the smallest correct change: only files in scope, no unrequested change, no dead code, scaffolding, unused export or option, speculative generality or gold-plating.
2. Reuses the existing paved path; never a second way to do a thing that has one.
3. Fails loud: no swallowed error, no fallback that hides a missing case, no cast that silences a type, no retry around a thing that should not fail.
4. No glue: no script, hook, wrapper, helper or inline program; a stock tool or the product's own code.
5. No comment that justifies a workaround.
6. Tests assert behaviour through the public surface, fail on the old code and pass on the new.
7. Every claim in the PR body is proven by a file:line in the diff or a run URL; every acceptance bullet carries real output. A change to what a running system does is proven by a run already done (run URL or invocation id); a proof put off to a later or scheduled run is a finding. A change that cannot alter behaviour (docs, comments, a rename the tests cover) says `not needed: <reason>` in the PR body instead, and a false reason is a finding.
8. Reads like the surrounding code (naming, idiom, size limits); a stranger could maintain it.
9. Product repos: follows the repo's DESIGN.md; user-facing text is plain and true.

**A+ = all nine met with zero findings.** A worker checks its own PR against the nine before `gh pr ready`.
