# Fleet quality bar

Every PR from the fleet, for any repo and any author, is graded against this bar by the shared `grade` check (fleet-ops#8655).

1. Does exactly what the issue asked and nothing more, as the smallest correct change: only files in scope, no unrequested change, no dead code, scaffolding, unused export or option, speculative generality or gold-plating.
2. Reuses the existing paved path; never a second way to do a thing that has one.
3. Fails loud: no swallowed error, no fallback that hides a missing case, no cast that silences a type, no retry around a thing that should not fail.
4. No glue: no script, hook, wrapper, helper or inline program; a stock tool or the product's own code.
5. No comment that justifies a workaround.
6. Tests assert behaviour through the public surface, fail on the old code and pass on the new. A `test.skip`/`.skip()` on a known, still-open defect where the suite's own idiom for it is `test.fail()` is a finding: the skip never fails, so the defect stays invisible instead of recorded.
7. Every claim in the PR body is proven by a file:line in the diff or a run URL; every acceptance bullet carries real output. A change to what a running system does is proven by a run already done (run URL or invocation id); a proof put off to a later or scheduled run is a finding. Two cases are not a put-off: a change that cannot run before merge (a dispatch-only workflow, a self-hosted runner label, an action referenced at `@main`) is proven by a faithful local simulation of the exact changed lines, with its real output pasted, the changed lines named and every stub input named; and a change whose behaviour is fully determined by its own text (a predicate, a log field, a copy string, a test expectation) is proven by the diff itself. A change that cannot alter behaviour (docs, comments, a rename the tests cover) says `run-proof: not-needed - <reason>` instead, and a false reason is a finding.
8. Reads like the surrounding code (naming, idiom, size limits); a stranger could maintain it.
9. Product repos: follows the repo's DESIGN.md; user-facing text is plain and true.
10. Tenant scope: every statement against the multi-tenant store carries its workspace (or owner) filter, and a statement keyed only by a record id another tenant can supply is a finding; so is a read that pulls internal-only columns — another workspace's rows, config or decision notes — into a public or shared surface.

**A+ = all ten met with zero findings.** Any finding is not A+. Only A+ passes.
