# Observe-close for #6799 — the five #4263 placeholder tests and their ci.yml lines are already deleted from main

fleet-ops#6799 (filed 2026-09-14) asked for the removal of the five tests
fleet-ops#4263's P3b lane planted in ci.yml — listed there only because
workers then could not edit workflows — plus the files themselves and any
live_skip/host entries in `tests/p14-test-listing-gate.test.sh`. By the
time the issue was filed the five files were pure placeholders: each was
a 15-line stub whose only assertion was that the retired picker
(`pick_seat`) is absent from `lib/litellm-seat.sh`, carrying the literal
header comment:

```
# fleet-ops#4263 P3b: listed in ci.yml (workers cannot edit workflows).
# Degraded-mode picking lived in the deleted routing library.
# This file proves the retired picker is gone from the routing library ...
```

(sampled verbatim from `git show 34fd4e36a^:tests/seat-lib-degraded.test.sh`;
the other four carry the same shape).

This claim ran after the work the issue asked for had already landed on
main. Every item in the Do list is resolved there; no new code and no
workflow edit is needed. This report is the resolution record, matching
the established observe-close pattern (e.g. the #6467 record,
PR #7964).

## What was found

1. **The five placeholder test files are deleted from main** by
   `34fd4e36a` ("test(exporter): repair the P14 host graph the exporter
   cut broke", 2026-09-19 00:32 +0530; authored nishfleet-worker[bot],
   committed by Nish — the exporter-cut repair lane). `git show
   34fd4e36a --stat` carries exactly the five paths the issue names,
   `-15` lines each: `tests/audition-lane.test.sh`,
   `tests/seat-lib-degraded.test.sh`,
   `tests/seat-lib-org-reserve.test.sh`,
   `tests/seat-lib-product-only-spend-cap.test.sh`,
   `tests/seat-wall-reset-horizon.test.sh`. `git merge-base
   --is-ancestor 34fd4e36a origin/main` passes at origin/main
   `8f145ca6d`.
2. **Their ci.yml host lines went in the same commit.** `git log -S`
   for each of the five names over `.github/workflows/ci.yml` shows
   `34fd4e36a` as the most recent commit touching any of them (earlier
   history: `6088e2712`, the #5658 spawn-guard ci.yml refactor, which
   carried the host lines at the issue-cited offsets 147–149/153/264).
   Current ci.yml — the single-job stock-check workflow #7861 dropped in
   (shellcheck / promtool / semgrep / `yaml.safe_load`, 27 lines) —
   references none of them; a grep over it returns zero hits.
3. **The P14 listing gate is deleted with its suite.**
   `tests/p14-test-listing-gate.test.sh` no longer exists: `ca67f5705`
   ("cut(ci): drop detector scripts, their workflows, and the P14
   suite", PR #7861, merged 2026-09-19T17:37:41Z, ancestor of
   origin/main) removed the P14 gate and 88 test files in the same PR.
   The issue's third item — "drop any live_skip/host entries in
   tests/p14-test-listing-gate.test.sh" — therefore has no file left to
   edit; the file and the host shape it belonged to are gone.
4. **The placeholders' subject retired underneath them.**
   `lib/litellm-seat.sh` — the file all five placeholders grep — was
   deleted by `9853ec72c` ("cut(seat-lib): delete litellm-seat.sh — the
   router already does all of it", 2026-09-18 23:52), ~40 minutes
   before the placeholder deletion. The stubs' own
   `[[ -f "$lib" ]] || fail "lib/litellm-seat.sh missing"` line makes
   them un-runnable on main even in principle; their single assertion
   (picker absence) is subsumed by the library's absence.
5. **No live residue on main.** A repo-wide grep at `8f145ca6d` for
   `audition-lane`, `seat-lib-degraded`, `seat-lib-org-reserve`,
   `seat-lib-product-only`, `seat-wall-reset-horizon`,
   `p14-test-listing` matches only historical PR-body records
   (`.fleet/pr-body-*.md`, `.pr-body-2288.md`) — no workflow, test,
   script, or manifest entry references any of them.

## Why deletion is the resolution

#6799's body attributes the placeholder genesis to #6032's stub
deletions and states the tests "now assert only that the retired picker
is absent — placeholder value". The deleted file contents confirm that
premise verbatim. #6032 itself remains open as the separate
no-undefined-call residue issue; this record does not depend on its
state. Nothing in the issue's Do list remains to do on main. The Workflows-scope
constraint the issue was filed around (the nishfleet-worker App token
cannot push `.github/workflows/**`) did not end up gating the outcome:
the content landed through the exporter-cut/cut lanes, and what stayed
open was only the close, which this PR's `Closes #6799` trailer
performs — the same close path the 2026-09-18/19 cuts adopted once the
observe-to-close sweep was retired (fleet-ops#7828, cf. #6467).

## Verification

- `git merge-base --is-ancestor 34fd4e36a origin/main` → yes (origin/main `8f145ca6d`).
- `git merge-base --is-ancestor ca67f5705 origin/main` → yes; `gh pr view 7861` → MERGED 2026-09-19T17:37:41Z.
- `test -f` over the five paths plus `tests/p14-test-listing-gate.test.sh` at `8f145ca6d` → all MISSING on main.
- `git log -S "<name>" -- .github/workflows/ci.yml` per name → last touch `34fd4e36a`; current `ci.yml` grep for all five names → zero hits.
- Repo-wide grep at `8f145ca6d` for the six names → only `.fleet/pr-body-*.md` and `.pr-body-2288.md` historical records.
- `git show 34fd4e36a --stat` → the five paths at `-15` lines each.
- `lib/litellm-seat.sh` deleted on main by `9853ec72c` (`git log --diff-filter=D -- lib/litellm-seat.sh`), ancestor of origin/main.

run-proof: probes above ran live on netcup-rs2000 2026-09-20 ~18:30 IST
against origin/main `8f145ca6d`; commit ancestry via `git merge-base
--is-ancestor`; PR state via `gh pr view 7861 --json state,mergedAt`;
docs-only record — no unit, timer, workflow or script path touched.

loose-ends: none — docs-only resolution record for work already landed
on main; nothing half-done.
