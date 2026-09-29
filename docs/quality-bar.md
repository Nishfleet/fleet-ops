# Fleet quality bar

Every PR from the fleet, for any repo and any author, is graded against this bar by the shared `grade` check (fleet-ops#8655).

1. Does exactly what the issue asked and nothing more, as the smallest correct change: only files in scope, no unrequested change, no dead code, scaffolding, unused export or option, speculative generality or gold-plating.
2. Reuses the existing paved path; never a second way to do a thing that has one.
3. Fails loud: no swallowed error, no fallback that hides a missing case, no cast that silences a type, no retry around a thing that should not fail.
4. No glue: no script, hook, wrapper, helper or inline program; a stock tool or the product's own code.
5. No comment that justifies a workaround.
6. Tests assert behaviour through the public surface, fail on the old code and pass on the new. A `test.skip`/`.skip()` on a known, still-open defect where the suite's own expected-failure idiom is the right tool for it (`test.fail()` in Vitest, `test.failing()` in Jest) is a finding: the skip never fails, so the defect stays invisible instead of recorded.
7. Every claim in the PR body is proven by a file:line in the diff or a run URL; every acceptance bullet carries real output. A change to what a running system does is proven by a run already done (run URL or invocation id); a proof put off to a later or scheduled run is a finding. Two cases are not a put-off: a change that cannot run before merge — a workflow a branch cannot run (its ref gate, its runner group, or its `@main` action reference) — is proven by a faithful local simulation of the exact changed lines, with its real output pasted, the changed lines named and every stub input named; and a claim about text the change carries itself (a log field name, a copy string, a test expectation, a predicate the diff shows in full) is proven by the diff, which settles that claim and nothing else — point 6's test is still required. A change that cannot alter behaviour (docs, comments, a rename the tests cover) says `run-proof: not-needed - <reason>` instead, and a false reason is a finding.
8. Reads like the surrounding code (naming, idiom, size limits); a stranger could maintain it.
9. Product repos: follows the repo's DESIGN.md; user-facing text is plain and true.
10. Workspace scope: the multi-tenant store is the set of tables that carry a workspace or owner column. A statement against one of them carries the caller's workspace (or owner) filter, unless it is keyed by a row the same code path already resolved through a scoped read; a statement that drops that filter crosses workspaces. A read that returns internal-only columns — config, credentials, decision notes, or another workspace's rows — to a public or shared surface is a finding.

**A+ = all ten met with zero findings.** Any finding is not A+. Only A+ passes.
