# Observe-close for #7571 — a retrospective review receipt for #7564, and why the arming that merged it never read a review receipt

Issue #7571 (filed 2026-09-17, claimed 2026-09-22) observed that fleet-ops
PR #7564 auto-merged at 2026-09-17T21:03:24Z before the local review blocker was
recorded anywhere a gate could read: the PR body already carried
`Local review: crgate --agent failed with exit 3, not signed in. This gate is
blocked, not passed.` as prose, the runbook diff had not been re-read, and no
receipt linked a review to the merge in either direction: no gate saw the
failure, and no receipt exists saying it was later reviewed. It asks for (a) a
real review of the one-file diff under the existing review process with
actionable findings addressed, (b) an explanation of why the existing arming
accepted the recorded incomplete review, (c) no new checker. Acceptance: a real
review receipt and disposition linked to #7564. Relates to #6748.

This report is the receipt and the disposition, in the observe-close convention
(#7536 -> PR #8137, #7403, #7426). It carries two edits to the reviewed file
itself for the act-on findings.

## The review receipt

Reviewer: the fleet's own senior review seat — the LiteLLM `judge` group (the
proxy's ordered senior fallback ladder, serving `pareto` `z-ai/glm-5.3-flash`
here), called post-model-review from this worker unit at
`127.0.0.1:4000/v1/chat/completions` on 2026-09-22 with (i) the exact merged
diff of PR #7564 (`git show 907d2343b --format='' -- docs/litellm-postgres-setup.md`),
(ii) the post-merge repo facts that bound the review (the wrapper deletion in
the 2026-09-19 glue sweep, the 2026-09-18 canary deletion, the journal's
retention floor), and (iii) the issue's acceptance. The reviewer is independent
of the PR's authoring run: a different model, a different day, and a prompt
that did not include the author's own review claims. One process note: the
first call was aimed at the model group `senior` and the proxy refused it
(`key_model_access_denied` — the fleet senior-tier key is restricted to the
`judge` group); the call was retargeted to `judge`, HTTP 200, 909 completion
tokens over 2,256 prompt tokens. The reviewer's raw output, verbatim:

```
## Critical (must fix)

**C1 — The incident block's journal citations are now unverifiable, and the doc still presents them as live evidence.**
Bucket: **act-on** (documentation correction only; no new tooling).
Line: `"The preserved user journal identifies a startup failure, not a slow boot."`
Actionable TODAY against origin/main: **Yes.** The host journal now retains only from 2026-09-19 16:03Z, so every cited stop, the `04:00:36–04:02:12` unbound-variable error, the `04:03:00` dead counter of 120,660s, and the `04:04:01` green record cannot be re-checked. The block should be relabeled as a *historical, non-reproducible* record (or the citations marked "as-of 2026-09-17, journal since rotated"). This is the one finding that materially misleads a future operator.

## Warnings (should fix)

**W1 — The block references a wrapper that no longer exists, and section 3a now contradicts it.**
Bucket: **act-on**.
Line: `"Inspection on September 17 found the 14 replacement source paths in that wrapper, no old directory references, and a clean bash -n result."`
Actionable TODAY: **Yes.** `~/.local/bin/fleet-litellm-proxy-start` was deleted by 1ae2704cc (PR #8076), and 3a was rewritten to systemd `EnvironmentFile` globs. The verbatim block still says "the live wrapper's mtime is 04:15:27 UTC" and "updating the wrapper." Add a one-line superseded-by pointer to 3a. No tooling.

**W2 — The 14 `source` paths in the installed-wrapper code block are now stale instructions.**
Bucket: **act-on**.
Line: `"source /home/nish/.config/fleet-ops/seats/opencode.env"`
Actionable TODAY: **Yes.** The PR repointed these correctly for its time, but the wrapper they install into was deleted two days later. The code block should be marked historical or folded into 3a's glob form, otherwise a reader reinstalls a wrapper the repo no longer ships.

**W3 — Health-canary references outlive the canary.**
Bucket: **consider**.
Line: `"fleet-litellm-health-canary.service remained unreachable through September 15 and into September 16."`
Actionable TODAY: **Yes** (annotation). The canary was deleted 2026-09-18 (b7d63866f). Historical text is fine; a reader shouldn't go looking for the unit.

## Suggestions (consider)

**S1 — "No merged repair SHA was found for the operator-owned wrapper."**
Bucket: **noted**. Still true and still the honest disposition; no change needed.

**S2 — Rejected-commit paragraph (`9b8ef205…`, `0b8ef1d0…`).**
Bucket: **noted**. Correctly scoped as a review decision, not a deploy claim. Leave as-is.

**S3 — "Its claim that gap-audit caused the deletion is an attributed report."**
Bucket: **consider**. Good epistemic hygiene; keep. Optionally add that the deletion remains unproven *today* too.

## Verdict

**Disposition: request changes (documentation-only), then merge.** The PR's substantive act — repointing 14 credential paths and recording the #6748 repair — was correct and well-evidenced *at merge time*. It is not wrong; it has been overtaken by b7d63866f and 1ae2704cc. The actionable findings (C1, W1, W2, W3) are all edits to the same file, achievable today against origin/main, and require **no new checker** — satisfying #7571's constraint. The existing arming accepted an incomplete review because the diff was one file and self-consistent; the gap was that no reviewer re-read the block *after* the wrapper and canary were deleted. Receipt: this review, linked to #7564, disposition **request-changes → approve on edit**.
```

That verdict — request changes on documentation grounds, then merge — is now
discharged below. The reviewer found no defect in what #7564 did: the two
substance acts (repointing the 14 credential `source` paths, and recording the
#6748 repair with its evidence limits) were correct at merge time.

## Findings and disposition

| ID | reviewer finding (quote) | adjudication | disposition |
|---|---|---|---|
| C1 | "The incident block's journal citations are now unverifiable, and the doc still presents them as live evidence" | act-on | fixed in this PR — the block now states it is a historical record as of the 2026-09-17 review, that the user journal has since rotated (the retained journal on this host begins 2026-09-19), and that the cited stops, counts and ticks carry no live verification weight |
| W1 | "The block references a wrapper that no longer exists" | act-on | fixed in this PR — a dated later-states sentence now points the reader at the 2026-09-19 glue sweep's wrapper deletion and at §3a as the reinstatement path |
| W3 | "References outlive the canary" | act-on | fixed in this PR — the same dated sentence records the 2026-09-18 canary deletion so a reader of the incident block does not go looking for the unit |
| W2 | "The 14 `source` paths in the installed-wrapper code block are now stale instructions" | dismissed-with-reason | already resolved by the sweep that postdates the reviewer's cited line: the wrapper code block no longer exists on origin/main, §3a is retitled `Credential environment — no wrapper` and carries the rebuild-reference list instead; there is nothing left to annotate |
| S1 | "`No merged repair SHA was found for the operator-owned wrapper`" | noted | still true, still the honest disposition, no change needed |
| S2 | rejected-commit paragraph (9b8ef205 / 0b8ef1d0) | noted | correctly scoped as a review decision rather than a deploy claim; left as-is |
| S3 | "its claim that gap-audit caused the deletion is an attributed report" | noted | genuine epistemic hygiene; kept, no stronger claim is justified today either |
| extra | §4 of the same doc still instructs reading `/var/lib/prometheus/node-exporter/fleet-litellm-health.prom`, and §1 still cites "the canary" | act-on, pre-existing | outside this review's diff — that section predates PR #7564 and is not part of what is being reviewed; verified dead on this host (`ls: No such file or directory`) and filed as **fleet-ops#8146** per the file-extras-as-new-issues rule |

Net: no evidence-limit-free claim in #7564 needed walking back beyond the two
annotations; the verdict on the reviewed diff is request-changes, and the
changes are made.

## Why the existing arming accepted the recorded incomplete review

The arming did not accept an incomplete review; nothing in the arming path ever
read a review receipt at all. The recorded failure was inert prose in the PR
body — true, prominent, and invisible to every gate on the path:

1. `PR #7564 body`: `Local review: crgate --agent failed with exit 3, not
   signed in. This gate is blocked, not passed. No login attempted.` (verbatim,
   2026-09-17.)
2. The arming path was `.github/workflows/auto-merge-arm.yml` →
   `.github/workflows/reusable-auto-merge-arm.yml`, run **35274421588**, event
   `pull_request`, created 2026-09-17T21:02:53Z, head `cda98a0f` (the PR head),
   conclusion `success`. Its arm condition is a fixed list — draft ==
   false, no `[no-merge]` in the title, no `no-auto-merge` label — plus the
   stop-the-line freeze, the quality-ceiling gate, the merge-trample gate and
   the gate-arm-guard. **None of them accepts as input a review receipt,
   either a pass or a failure.** Review admission (crgate) and merge
   authorisation (arming) were two unconnected doors in the same hallway.
3. The PR timeline makes the ordering unambiguous:
   `auto_squash_enabled` 21:03:07Z; merge 21:03:24Z; then the worker's
   advisory 40s later (comment at 21:04:04Z), then the `blocked-by-judge`
   label at 21:04:59Z and the blocking review handoff at 21:05:00Z — 1m36s
   after the merge. `crgate` is Nish-side (needs an interactive gh sign-in)
   and is not runnable from a fleet unit, so no lane could have produced the
   receipt the PR body wanted inside the window.
4. This is the same diagnosis the repo already recorded for the sibling case:
   the #7536 observe-close (PR #8137) identified the identical workflow and the
   identical fixed gate list — a list that never knew `blocked-by-judge` and
   that has no review-receipt input. The gap is not a missing check on this PR;
   it is that the arming side and the review side never shared a surface. This
   report does not rebuild that record; it names the surviving cause.
5. The offending arming path itself was deleted on 2026-09-19 (`ca67f570`,
   PR #7861), for the same reason as in the #7536 diagnosis. Deletion is the
   strongest form of "an arm path will never again merge before a review is
   recorded": there is no workflow left to be misinformed by a missing
   receipt. The surviving arm site is the worker prompt step 9, which carries
   the full refusal list (`blocked-by-judge`, among others) and explicitly
   refuses to arm on it.
6. The repair is receipts-first: since no gate reads a review receipt, the
   durable review artifact is the receipt itself — a comment on #7564 quoting
   the review and its disposition. That is what this PR carries, alongside the
   annotations to the reviewed file.

## Reconciled against the issue

- *"review the one-file runbook diff in #7564 under the existing review
  process"* — done: the diff was re-read after the merge, and the review was
  taken from the fleet's senior review seat (the `judge` group), independent of
  the author, with the raw output published above.
- *"address any actionable findings"* — done: C1, W1 and W3 are fixed as prose
  in the reviewed file in this PR; W2 is dismissed-with-reason (already
  resolved by the sweep); S1-S3 noted; the pre-existing §4/§1 staleness is
  filed at #8146 instead of widening this review.
- *"Check why existing arming accepted the recorded incomplete review"* — done:
  every gate accepts a fixed list of conditions, no gate reads a review
  receipt; the recorded failure was never consumed.
- *"Do not build another checker"* — none built, none requested: no script, no
  workflow, no unit, no gate.
- *"Acceptance: a real review receipt and disposition linked to #7564"* — the
  raw receipt and the disposition are published above and quoted in a comment
  on #7564; that comment is the link surface (`reviewed` is not a label on this
  repo).

## What this PR changes

1. `docs/reports/review-gap-7564-runbook-review-observe-close-7571.md` — this
   receipt.
2. `docs/litellm-postgres-setup.md` — two dated, prose-only annotations inside
   the September 15–16 block (evidence-floor note; later-states sentence
   pointing at the glue sweep and §3a). No code, no paths walked back that
   were not the reviewer's own act-on items.
3. One follow-up issue, #8146, for the pre-existing §4/§1 canary staleness.

loose-ends: 7571-8146-§4-canary-staleness (filed #8146).

mechanism: the arm-side void was closed by deletion of the arming workflow
(#7861), repointing of the surviving arm site, and per-ticket enforcement of
the #4557 rule; the review-side void — a merge that left no review receipt in
either direction — is only repairable by producing the receipt itself, which
this report + comment do.