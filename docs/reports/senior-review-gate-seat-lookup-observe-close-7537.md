# Observe-close for #7537 — arm-check vs seat-lookup disagreement deleted in the sweep; independent review of 0509 claim/issue-2952 discharged

Issue #7537 (filed 2026-09-17, observed in unit pi-issue-0509-2952) reported a
false-green: the installed `fleet-review-arm-check` exited 0 while
`find_senior_seat` (installed `lib/litellm-seat.sh`, after loading seat caps)
exited 1 with no provider/model — `senior_seat_available` enumerated the
configured seats while `find_senior_seat` only offered `litellm/senior`. The
issue asked to (1) resolve the disagreement and (2) run the independent
review the gate let slip: Nishfleet/0509 `claim/issue-2952` head
`04e4aa9d4cabdccd7c8a1b3bec6b9c041a534125`. By the time this re-claim ran
(2026-09-22), both organs of the disagreement were deleted. This report is
the resolution record, same convention as the #7403 observe-close (PR #8108)
and the #7399 observe-close.

## What was found

1. **Both sides of the disagreement are deleted.** `9853ec72c`
   ("cut(seat-lib): delete litellm-seat.sh — the router already does all of
   it", 2026-09-18 23:52 IST) removed `bin/fleet-review-arm-check` (56 lines),
   `lib/litellm-seat.sh` (2,040) and `tests/fleet-review-arm-check.test.sh`
   (144) — 2,245 lines in one commit. `git merge-base --is-ancestor
   9853ec72c origin/main` passes; origin/main is `8792d256f`. The reported
   symptom was structural: the arm-check walked the `senior_seats_in_order`
   roster in `config/seat-caps.json` (several rostered candidates) while
   `find_senior_seat` offered only `litellm/senior` — two enumerations of
   "senior", so a green gate and an empty seat lookup coexisted. Deleting
   both enumerations is the resolution: there is nothing left to disagree.
2. **No surviving organ can produce the false-green.** `prompts/worker.md`
   step 8 has the reviewer round call the `senior` LiteLLM model group
   directly (`config/litellm-proxy.yaml` `model_name: senior` →
   pareto z-ai/glm-5.3-flash); the router owns ordering, health and
   fallbacks, so there is no pre-check to drift out of sync. If every rung
   is walled the reviewer round is skipped, step 9 refuses the arm, and the
   PR body carries `review: skipped, no capable seat`. The seat probe IS the
   review call — a gate cannot pass while the seat is empty because they are
   the same operation. Live evidence 2026-09-22 ~03:52 IST:
   `curl -s 127.0.0.1:4000/health/readiness` → `{"status":"healthy"}`;
   `litellm_deployment_state{model_id="pareto-glm53flash-senior"}=0`
   (healthy; the `litellm_model_name="senior"` alias row reads 2, the known
   cooldown-flip behaviour of alias rows, while the raw-model health row is
   0). Installed copies are gone: `~/.local/bin/fleet-review-arm-check` does
   not exist; no `litellm-seat*`/`review-arm*` file under `~/.local`,
   `~/.pi` or `workspaces/tooling`.
3. **The review debt was real and is discharged below.** PR
   Nishfleet/0509#3588 (`claim/issue-2952` @ `04e4aa9d4`, +316/−19 across
   `app/routes/search.tsx` and `tests/search.route.test.ts`) was closed
   unmerged 2026-09-18T05:48Z with zero reviews — CodeRabbit self-skipped
   via an embedded marker. Issue 0509#2952 is still OPEN, labeled
   `discarded` + `superseded-by-rebuild`. The independent review is in the
   next section; it is also posted on the closed PR so it is findable if the
   branch is ever revived.
4. **Residual drift is documented, not edited.** `config/seat-caps.json`
   still carries the `senior_seats_in_order` key and `_comment` text naming
   `lib/litellm-seat.sh`, `find_senior_seat` and `senior_seat_available` —
   all dead references with no consumer on main (`git grep` hits are this
   file, bench fixtures, reports and the worker.md historical note).
   Pruning a hot config file is a sweep decision, not this report's scope;
   the references are data/comment-only and cannot route anything.

## Independent review — Nishfleet/0509 claim/issue-2952 @ 04e4aa9d4

Scope reviewed: `gh pr diff 3588` (431 diff lines, 2 files). Verdict: **the
diff is sound for its stated goal — approve-with-comments; no Act-on
items.** The eager-shell + streamed-promise split preserves the #3400
honest-200 contract on both legs (streamed rejection → `Await`
errorElement inside the already-200 document; non-navigation `await search`
inside the existing leg guard), and the new test pins a real streaming
assertion — shell settles <500ms against a mocked 1,000ms source.

- **Consider — navigation check does not cover SPA navigations.**
  `sec-fetch-mode: navigate` is sent only on document loads; React Router
  SPA single-fetch `.data` requests are `fetch()` calls and carry
  `sec-fetch-mode: cors`. The comment at the check ("initial document or
  SPA single-fetch") overclaims: SPA navigations silently take the settled
  path. The issue's goal (first-load visitors from `/ads/<brand>` redirects)
  is still met — those are document navigations — but if streaming on SPA
  transitions was intended, the mechanism does not deliver it.
- **Consider — no rejection-path test.** The streamed-rejection →
  errorElement path and the non-navigation rejection → #3400 leg-guard path
  are asserted only in comments. One `searchAdsViaSourceResolver` mock that
  rejects would pin both.
- **Consider — exact-key assertion does not cover the streamed union.** The
  `Object.keys(settled).sort()` exact-set check runs on the non-navigation
  payload only; the streamed branch is checked with `toMatchObject`, which
  tolerates dropped keys. A field lost from the streamed+resolved merge
  would pass green.
- **Noted — pending promise precedes the navigation check.** The `search`
  IIFE starts before `isBrowserNavigation` is computed; if any shell code
  after it threw before the payload returned, the pending promise would be
  unobserved and could reject unhandled (Workers: logged, non-fatal). The
  intervening code is pure object construction, so probability is low.
- **Noted — helpers outside the diff.** `buildIdleSearchResult`,
  `SearchRouteResults`, `PublicSearchRateLimitError`, `PublicSearchError`
  are referenced but not shown in the diff; names match the file's existing
  conventions and the test file imports the same fixtures.

"Worker must not fake GITHUB_ACTIONS or arm an unreviewed PR" — this review
ran against the real diff at the named head; the PR it covers is closed
unmerged, so nothing was or could be armed.

## Reconciled against the packet

- *Resolve the disagreement*: resolved by deletion — both enumerations are
  gone (`9853ec72c`); the surviving path makes the false-green impossible by
  construction (probe = call).
- *Run an independent review of claim/issue-2952 head 04e4aa9d4*: done above
  and posted on Nishfleet/0509#3588.
- *Worker must not fake GITHUB_ACTIONS or arm an unreviewed PR*: nothing
  armed; the only PR from this run carries its own verification receipt.

## Residual path

If the fleet wants the stale `senior_seats_in_order` roster and dead
seat-lib references pruned from `config/seat-caps.json`, that is a small
follow-up sweep PR, not an organ. Nothing here asks for a new gate — the
newest authoritative act on the site is its deletion, and the surviving
reviewer path already fails closed.

mechanism: the sweep itself resolved the issue's target — observe-close
record per the fleet's deleted-organ convention (fleet-ops#7399 → #8108,
fleet-ops#7403 → #8108 sibling).
