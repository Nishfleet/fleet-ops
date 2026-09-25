# Fleet quality bar

Every PR from the fleet, for any repo and any author, is graded against this bar by the shared `grade` check (fleet-ops#8655).

1. Does exactly what the issue asked and nothing more: only files in scope, no unrequested change.
2. Reuses the existing paved path; never a second way to do a thing that has one.
3. Fails loud: no swallowed error, no fallback that hides a missing case, no cast that silences a type, no retry around a thing that should not fail.
4. No glue: no script, hook, wrapper, helper or inline program; a stock tool or the product's own code.
5. No comment that justifies a workaround.
6. Tests assert behaviour through the public surface, fail on the old code and pass on the new.
7. Every claim in the PR body is proven by a file:line in the diff or a run URL; every acceptance bullet carries real output.
8. Reads like the surrounding code (naming, idiom, size limits); a stranger could maintain it.
9. Product repos: follows the repo's DESIGN.md; user-facing text is plain and true.

**A+ = all nine met with zero findings.** Any finding is not A+. Only A+ passes.
