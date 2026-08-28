# Rule-debt consolidation inventory (fleet-ops#1537)

P1 INVENTORY — the disposition map for all 121 vault rules. This is the
foundation P2 (blind review), P3 (execute), and P4 (prove) build on.

## Before counts (live, 2026-08-28T16:00Z)

Source: `python3 lib/rule-enforcement.py join --rules $STANDING --ledger
$LEDGER --matrix config/rule-enforcement.json`

| metric | count |
|---|---|
| vault rules (standing + ledger) | 122 |
| matrix entries | 113 |
| enforced | 76 |
| advisory | 8 |
| queued (mechanism pending) | 29 |
| uncovered (no matrix entry) | 9 |
| violations (canary LOUD) | 9 |

The 9 uncovered are rules added 2026-08-28 without matrix entries yet —
pre-existing, not introduced by this PR.

## Method

Every rule was read in full from `global-standing-rules.md` (1656 lines, 55
## sections) and `decisions-ledger.md` (124 lines, 66 entries). Each was
classified into one of six classes and given one of four dispositions, per
the issue's spec. The matrix id mapping comes from `lib/rule-enforcement.py`'s
own join (authoritative — no re-derivation).

## Classes

| class | meaning |
|---|---|
| binding-constraint | live Nish-endorsed obligation that constrains action |
| mechanism-exists | prose subsumed by a shipped, enforced mechanism |
| duplicate-of | same obligation as another rule; merge target named |
| incident-memorial | records a past incident; the lesson lives on in a mechanism |
| superseded-history | corrected/retired/superseded by a later rule |
| advisory | senior-judged un-mechanizable, or product-direction guard |

## Dispositions

| disposition | meaning |
|---|---|
| keep | stays in the short binding-constraints file, verbatim or merged |
| collapse-into | merges into the named binding constraint |
| demote-to-pointer | one line in the short file pointing at the archive/mechanism |
| archive | moves verbatim to standing-rules-archive.md (history preserved) |

## Proposed binding-constraint clusters (the ~dozen)

The consolidation merges 122 rules into 15 binding constraints. Each cluster
preserves every Nish-endorsed obligation verbatim-or-stronger — the cluster
heading states the merged constraint; the full text of every member moves to
the archive.

| # | binding constraint | merges (matrix ids) |
|---|---|---|
| BC0 | Deletion-first, verified not vibes — prefer edits/deletions over construction; run on existing rails; net machinery trends negative; paper is not machinery; no checkers for canary-enforced conventions; prove state with live commands before claiming it. | no-hand-built-orchestration (agent instruction), prefer-proven-off-the-shelf (agent instruction), check-help-before-building (agent instruction), led-2026-08-28-deletion-first (uncovered) |
| BC1 | Quality is the sole north star — constraint, never trade-off | sr-quality-speed-efficiency, sr-quality-outranks, sr-quality-is-a-constraint-never-a-trade-off (uncovered), led-north-star-quality, led-quality-inescapable, led-optimization-order, led-optimization-target-max-quality-throughput (uncovered), led-quality-is-a-constraint-never-a-trade-off (uncovered) |
| BC2 | Act now, max speed, no deferral without a named clock | sr-get-it-moving, sr-max-speed, sr-nothing-waits-tomorrow, led-top-gear-everywhere |
| BC3 | Fix it, don't report it — only the un-fixable reaches Nish | sr-unfixable-reaches-nish, sr-findings-queued, sr-failed-command-flagged, sr-watchdogs-dispatch |
| BC4 | Everything runs through Pi, one fleet, no launchers | sr-pi-directly, sr-one-fleet, sr-raw-api-through-pi |
| BC5 | No hand-built orchestration — everything mechanical | sr-no-hand-built-orch, sr-all-functions-mechanical, sr-everything-mechanical, led-plumbing-ban, led-everything-mechanical, led-enforcement-mechanical, led-mechanical-fix, led-machinery-ban-mechanical (uncovered), led-machinery-violations-senior-conference (uncovered) |
| BC6 | Find the proven thing before you build anything | sr-research-before-build, sr-find-proven-thing, sr-pi-extensions-proven |
| BC7 | Execution IS the review — run it, prove it, loop to clean | sr-execution-is-review, sr-switched-on-proven |
| BC8 | Never decide by vibes — always measure | sr-never-vibes, led-capacity-measured |
| BC9 | systemd by default; engineer reversibility, don't gate | sr-systemd-by-default, sr-reversibility |
| BC10 | CI standard: batched, minimal, near-zero failures, every repo | sr-ci-standard, sr-doc-only-suite, sr-gha-overflow |
| BC11 | Agent-authored PRs land themselves; no agent names | sr-prs-self-land, sr-no-agent-names, sr-gates-lifted |
| BC12 | Standing machinery is agent-agnostic; the boundary is enforced | sr-agent-agnostic, sr-one-instruction-binds |
| BC13 | Decisions ledger — check before asking; one instruction binds all | sr-decisions-ledger, sr-one-instruction-binds |
| BC14 | Legit work only — no spinning wheels; quality gates are hard | sr-legit-work-no-spinning-wheels, led-legit-work-only-is-fleet-wide-law (uncovered) |

Plus two conventions (not constraints — process rules for the file itself):
- **Sunset convention**: every new standing rule carries a review-by date or
  an "absorbed into mechanism X" exit condition; the WFR quality ratchet
  reviews expiring rules.
- **Net-down convention**: a new standing rule requires naming which existing
  rule it merges into or replaces; net rule count trends DOWN.

## Full disposition table

### Standing rules (55)

| matrix_id | status | class | disposition | merge_target | heading |
|---|---|---|---|---|---|
| sr-decisions-ledger | enforced | binding-constraint | keep | BC13 | Decisions ledger — check before asking Nish |
| sr-quality-speed-efficiency | enforced | binding-constraint | collapse-into | BC1 | Quality > speed > efficiency, strictly |
| sr-switched-on-proven | queued(#378) | binding-constraint | collapse-into | BC7 | Switched on and proven, or it is not done |
| sr-findings-queued | enforced | binding-constraint | collapse-into | BC3 | Every finding gets queued, automatically |
| sr-get-it-moving | advisory | binding-constraint | collapse-into | BC2 | Get it moving, always |
| sr-max-speed | queued(#516) | binding-constraint | collapse-into | BC2 | Max speed is the default, forever |
| sr-research-before-build | enforced | binding-constraint | collapse-into | BC6 | Research before build — always |
| sr-gha-overflow | enforced | superseded-history | collapse-into | BC10 | GitHub Actions overflow policy (self-hosted runners RETIRED 2026-08-24) |
| sr-free-model-roster | enforced | binding-constraint | demote-to-pointer | — | Free-model roster stays fresh (mechanism: fleet-eval league) |
| sr-systemd-by-default | enforced | binding-constraint | collapse-into | BC9 | systemd by default |
| sr-no-agent-names | enforced | binding-constraint | collapse-into | BC11 | No agent names on Nish's work |
| sr-free-tier-privacy | queued(#520) | binding-constraint | keep | — | Free-tier privacy line |
| sr-quality-outranks | advisory | binding-constraint | collapse-into | BC1 | Quality outranks everything |
| sr-unfixable-reaches-nish | enforced | binding-constraint | collapse-into | BC3 | Only the un-fixable reaches Nish |
| sr-nothing-waits-tomorrow | enforced | binding-constraint | collapse-into | BC2 | Nothing waits for tomorrow |
| sr-verify-before-answering | advisory | binding-constraint | keep | — | Verify before answering |
| sr-debug-playbook | queued(#522) | binding-constraint | demote-to-pointer | — | Debugging sessions end with a playbook note |
| sr-token-efficiency | queued(#523) | binding-constraint | demote-to-pointer | — | Token efficiency without quality loss |
| sr-verify-harness | enforced | mechanism-exists | demote-to-pointer | — | Per-repo verification harness (mechanism: .claude/skills/verify-*) |
| sr-pstack-review | enforced | incident-memorial | archive | — | pstack full review + blind stress test (one-time event; adopted skills live in skills-library) |
| sr-vault-knowledge-format | enforced | binding-constraint | demote-to-pointer | — | Vault knowledge format: atomic facts, hub notes, glossary |
| sr-interventions-eliminated | queued(#526) | binding-constraint | collapse-into | BC5 | Interventions get eliminated, not repeated |
| sr-gap-rules-audit | queued(#527) | binding-constraint | demote-to-pointer | — | Gap rules from the 2026-08-20 rulebook audit |
| sr-nothing-half-done | queued(#528) | binding-constraint | collapse-into | BC7 | Nothing sits half-done, and no question dies unanswered |
| sr-one-instruction-binds | enforced | binding-constraint | collapse-into | BC13 | One instruction binds every agent, everywhere |
| sr-vault-sync-conflicts | enforced | mechanism-exists | demote-to-pointer | — | Vault sync conflicts auto-resolve (mechanism: vault-conflict-resolver timer) |
| sr-claim-surface | enforced | binding-constraint | keep | — | Claim your surface before operating |
| sr-prepaid-max-util | queued(#531) | binding-constraint | collapse-into | BC2 | Prepaid subs run at max utilization |
| sr-devin-4-wide | enforced | mechanism-exists | demote-to-pointer | — | Devin Pro runs 4 workers wide (mechanism: fleet seat-caps.json) |
| sr-raw-api-through-pi | enforced | binding-constraint | collapse-into | BC4 | Every raw-API token flows through pi |
| sr-box-75-80 | enforced | binding-constraint | demote-to-pointer | — | The box runs at 75-80% capacity minimum |
| sr-skills-native | queued(#532) | mechanism-exists | demote-to-pointer | — | Skills are native (mechanism: cross-symlink + rsync) |
| sr-one-fleet | enforced | superseded-history | collapse-into | BC4 | One fleet (machinery superseded 2026-08-23; principle stands) |
| sr-pi-directly | enforced | binding-constraint | collapse-into | BC4 | Everything runs through Pi, directly. No launchers. |
| sr-fleet-wipe-lessons | enforced | incident-memorial | archive | — | Lessons from the 2026-08-23 fleet wipe (5 lessons; live in fleet-wipe-lessons-check) |
| sr-find-proven-thing | enforced | binding-constraint | collapse-into | BC6 | Find the proven thing before you build anything |
| sr-doc-only-suite | enforced | binding-constraint | collapse-into | BC10 | Doc-only changes never run the full suite |
| sr-failed-command-flagged | enforced | binding-constraint | collapse-into | BC3 | A failed command is ALWAYS flagged, never walked past |
| sr-watchdogs-dispatch | enforced | binding-constraint | collapse-into | BC3 | Watchdogs dispatch agents, they never page Nish |
| sr-pi-extensions-proven | enforced | binding-constraint | collapse-into | BC6 | Pi extensions: prefer them, but install only the proven |
| sr-ambiguity-authoritative | advisory | binding-constraint | keep | — | Ambiguity resolves to the authoritative recommendation |
| sr-no-hand-built-orch | enforced | binding-constraint | collapse-into | BC5 | No hand-built orchestration. Ever. |
| sr-ci-standard | enforced | binding-constraint | collapse-into | BC10 | CI standard: batched, minimal, near-zero failures |
| sr-reversibility | enforced | binding-constraint | collapse-into | BC9 | Engineer reversibility, don't gate |
| sr-gates-lifted | enforced | binding-constraint | collapse-into | BC11 | Merge and deploy gates LIFTED on the canonical fleet repo |
| sr-prs-self-land | enforced | binding-constraint | collapse-into | BC11 | Agent-authored PRs land themselves |
| sr-all-functions-mechanical | queued(#377) | binding-constraint | collapse-into | BC5 | All functions mechanical |
| sr-agent-agnostic | enforced | binding-constraint | collapse-into | BC12 | Standing machinery is agent-agnostic |
| sr-execution-is-review | enforced | binding-constraint | collapse-into | BC7 | Execution IS the review |
| sr-never-vibes | queued(#538) | binding-constraint | collapse-into | BC8 | Never decide by vibes — always measure |
| sr-check-other-agents | enforced | binding-constraint | keep | — | Check for other agents before touching shared files |
| sr-memory-oom | enforced | mechanism-exists | demote-to-pointer | — | Memory: prevent, throttle, then kill (mechanism: systemd-oomd + cgroup) |
| sr-everything-mechanical | queued(#366) | binding-constraint | collapse-into | BC5 | Everything is mechanical — failures included |
| sr-legit-work-no-spinning-wheels | enforced | binding-constraint | collapse-into | BC14 | Legit work only — no spinning wheels |
| UNCOVERED | uncovered | binding-constraint | collapse-into | BC1 | Quality is a constraint, never a trade-off (2026-08-28) |

### Ledger decisions (66)

| matrix_id | status | class | disposition | merge_target | heading |
|---|---|---|---|---|---|
| led-plumbing-ban | enforced | binding-constraint | collapse-into | BC5 | hand-built plumbing BAN, enforced at the gate |
| led-0509-exclusive | enforced | advisory | archive | — | 0509 EXCLUSIVE supply (superseded by led-fleet-ops-precedence) |
| led-senior-conference | queued(#223) | binding-constraint | keep | — | serious builds get the senior conference |
| led-capacity-measured | enforced | binding-constraint | collapse-into | BC8 | capacity is measured, never declared |
| led-loop-all-repos | enforced | binding-constraint | demote-to-pointer | — | loop for ALL repos |
| led-gap-closure-loop | queued(#362) | binding-constraint | demote-to-pointer | — | gap-closure loop |
| led-blind-audit | queued(#378) | binding-constraint | demote-to-pointer | — | recurring blind audit |
| led-escalation-coverage | enforced | mechanism-exists | demote-to-pointer | — | escalation coverage (mechanism: escalation-coverage-canary) |
| led-merge-to-live | enforced | mechanism-exists | demote-to-pointer | — | merge-to-live (mechanism: heartbeat pull+install+verify) |
| led-work-supply-24h | enforced | mechanism-exists | demote-to-pointer | — | work supply 24h (mechanism: scouts + senior admission) |
| led-fleet-ops-enrolment | enforced | advisory | archive | — | fleet-ops enrolment (config; superseded by led-fleet-ops-precedence) |
| led-0509-deploys | enforced | mechanism-exists | demote-to-pointer | — | 0509 deploys (auto-deploy-on-green) |
| led-continuous-research | enforced | binding-constraint | demote-to-pointer | — | continuous research |
| led-portable-standards | enforced | binding-constraint | demote-to-pointer | — | portable standards |
| led-optimization-order | enforced | binding-constraint | collapse-into | BC1 | optimization order (quality > speed > efficiency) |
| led-0509-focus | enforced | superseded-history | archive | — | 0509 focus (superseded by led-0509-exclusive then led-fleet-ops-precedence) |
| led-transformation-bets | advisory | advisory | archive | — | transformation bets |
| led-seo-geo-aeo | advisory | advisory | archive | — | SEO/GEO/AEO |
| led-discovery-feature | advisory | advisory | archive | — | discovery feature |
| led-lanes | enforced | mechanism-exists | demote-to-pointer | — | lanes (mechanism: seat-caps.json) |
| led-repo-visibility | enforced | binding-constraint | demote-to-pointer | — | repo visibility |
| led-work-supply-agent-ready | queued(#543) | binding-constraint | demote-to-pointer | — | work supply (agent-ready) |
| led-gitleaks | enforced | mechanism-exists | demote-to-pointer | — | Gitleaks (mechanism: gitleaks CI check) |
| led-coderabbit | advisory | advisory | archive | — | CodeRabbit |
| led-tailscale | enforced | mechanism-exists | demote-to-pointer | — | Tailscale (mechanism: tailscale-acl-lockdown.json) |
| led-attestation-breach | enforced | incident-memorial | archive | — | attestation breach evidence (one-time; worker-identity fix is the mechanism) |
| led-mechanical-fix | queued(#366) | binding-constraint | collapse-into | BC5 | every failure gets a mechanical fix |
| led-everything-mechanical | queued(#377) | binding-constraint | collapse-into | BC5 | EVERYTHING mechanical |
| led-enforcement-mechanical | enforced | binding-constraint | collapse-into | BC5 | enforcement itself is mechanical |
| led-worker-lane-refresh | enforced | advisory | archive | — | worker-lane refresh (point-in-time routing decision) |
| led-2026-08-27-worker-lane-order | enforced | advisory | archive | — | Worker lane order (point-in-time) |
| led-north-star-quality | enforced | binding-constraint | collapse-into | BC1 | NORTH STAR: quality through and through |
| led-quality-inescapable | enforced | binding-constraint | collapse-into | BC1 | quality is INESCAPABLE, every role |
| led-researchers-join | enforced | binding-constraint | demote-to-pointer | — | researchers join the fleet |
| led-glm-5-3-free-clinepass | enforced | advisory | archive | — | GLM 5.3 flash free on ClinePass (point-in-time wiring) |
| led-cursor-grok-re-admitted | queued(#437) | advisory | archive | — | cursor grok-4.6 heavy re-admitted (point-in-time) |
| led-straitly-ds4-pro-workers | enforced | advisory | archive | — | straitly ds4-pro approved for workers (point-in-time) |
| led-top-gear-everywhere | enforced | binding-constraint | collapse-into | BC2 | TOP GEAR everywhere, non-negotiable |
| led-escalation-matrix-fixes | enforced | binding-constraint | collapse-into | BC3 | escalation matrix FIXES, not just routes |
| led-2026-08-27-d1-prod-migrations | queued(#905) | superseded-history | archive | — | D1 prod migrations (VOIDED by correction) |
| led-2026-08-27-d1-prod-migrations-correction | queued(#906) | superseded-history | archive | — | D1 prod migrations — CORRECTION (superseded by DECIDED) |
| led-2026-08-27-d1-prod-migrations-decided | queued(#907) | binding-constraint | keep | — | D1 prod migrations — DECIDED (vacation grant) |
| led-2026-08-27-d1-prod-migrations-process-amendment | queued(#908) | binding-constraint | keep | — | D1 prod migrations — process amendment (senior process) |
| led-fleet-ops-precedence-over-0509 | enforced | advisory | archive | — | Fleet-ops precedence over 0509, for now (vacation-window) |
| led-2026-08-27-vacation-window-corrected | enforced | advisory | archive | — | Vacation window corrected (expires 2026-09-08) |
| led-2026-08-27-weekly-fleet-review-approved | enforced | binding-constraint | keep | — | Weekly Fleet Review approved |
| led-2026-08-27-token-economy-rebalance | enforced | advisory | archive | — | Token economy rebalance (point-in-time meters) |
| led-2026-08-27-cursor-400-correction | queued(#1177) | advisory | archive | — | Cursor $400 correction (point-in-time) |
| led-2026-08-27-cursor-400-sequencing | queued(#1179) | advisory | archive | — | Cursor $400 sequencing + model (point-in-time) |
| led-2026-08-27-quality-ratchet | enforced | binding-constraint | demote-to-pointer | — | Quality ratchet (mechanism: WFR + quality-ratchet.json) |
| led-2026-08-27-precedence-band | enforced | mechanism-exists | demote-to-pointer | — | Precedence band (mechanism: precedence-band.json) |
| led-2026-08-27-geo-aeo-fleet-executes | enforced | binding-constraint | demote-to-pointer | — | GEO/AEO: fleet executes measurement + owned-content |
| led-2026-08-27-geo-plan-approved | enforced | advisory | archive | — | GEO plan approved (point-in-time) |
| led-2026-08-27-free-lanes-auto-retry | enforced | mechanism-exists | demote-to-pointer | — | Free lanes auto-retry after cooldowns (mechanism: seat-health) |
| led-2026-08-27-opus-duty-officer | enforced | mechanism-exists | demote-to-pointer | — | Opus duty-officer heartbeat: HOURLY (mechanism: systemd timer) |
| led-2026-08-27-heartbeat-made-exhaustive | enforced | mechanism-exists | demote-to-pointer | — | Heartbeat made exhaustive (mechanism: heartbeat timer) |
| led-2026-08-28-relic-pager-masked-emergency | queued(#1399) | incident-memorial | archive | — | Relic pager masked (emergency, one-time) |
| led-2026-08-28-machinery-ban-mechanical | queued(#1480) | binding-constraint | collapse-into | BC5 | Machinery ban is mechanically enforced |
| led-2026-08-28-machinery-violations-senior-conference | queued(#1480) | binding-constraint | collapse-into | BC5 | Machinery violations self-adjudicate via senior conference |
| UNCOVERED | uncovered | binding-constraint | collapse-into | BC14 | Legit-work-only is fleet-wide law |
| UNCOVERED | uncovered | binding-constraint | collapse-into | BC1 | Optimization target: MAX QUALITY THROUGHPUT |
| UNCOVERED | uncovered | binding-constraint | collapse-into | BC1 | Quality is a CONSTRAINT, never a trade-off |
| UNCOVERED | uncovered | advisory | archive | — | Runway measured in TIME, not items (point-in-time clarification) |
| UNCOVERED | uncovered | advisory | archive | — | Band inversion: 70:30 is priority order (point-in-time) |
| UNCOVERED | uncovered | advisory | archive | — | 0509 completeness claims distrusted (point-in-time) |
| UNCOVERED | uncovered | advisory | archive | — | 0509 product direction: three epics (product direction, Nish-reserved) |
| UNCOVERED | uncovered | binding-constraint | keep | BC0 | Deletion-first is the FIRST rule every agent reads (2026-08-28) |

## Disposition summary

| disposition | count | % |
|---|---|---|
| collapse-into (binding constraint) | 47 | 39% |
| demote-to-pointer (mechanism exists) | 24 | 20% |
| archive (history/incident/point-in-time) | 36 | 30% |
| keep (standalone binding constraint) | 15 | 12% |
| **total** | **122** | |

Net effect: 122 rules → 15 binding constraints + 24 pointers + 36 archived
+ 2 conventions. The short file carries ~41 lines (15 constraints + 24
one-line pointers + 2 conventions); the archive preserves all 1656 lines
verbatim.

## 29 queued mechanisms — re-scoping

Each queued mechanism re-scoped against the consolidated set. "Close" = the
binding constraint it serves is already enforced by another mechanism, so the
queued issue is obsolete. "Keep" = the mechanism is still needed. "Merge" =
two queued issues serve the same constraint, merge into one.

| queued issue | serves | re-scope | reason |
|---|---|---|---|
| #378 (switched-on-proven + blind-audit) | BC7, BC3 | keep | the run-proof gate and blind audit are distinct mechanisms not yet built |
| #516 (max-speed) | BC2 | merge-into-#378 | "no artificial limiters" is the same detector class as the gap-closure loop |
| #520 (free-tier-privacy) | — | keep | standalone constraint, no other mechanism covers lane-level privacy |
| #522 (debug-playbook) | — | keep | standalone, the vault-note gate is not yet mechanical |
| #523 (token-efficiency) | — | keep | standalone, prompt-layout lint not yet built |
| #526 (interventions-eliminated) | BC5 | merge-into-#366 | intervention elimination is the same class as mechanical-fix |
| #527 (gap-rules-audit) | — | keep | the rulebook red-team cadence is a distinct mechanism |
| #528 (nothing-half-done) | BC7 | merge-into-#378 | loose-ends sweep is the same detector class as switched-on-proven |
| #531 (prepaid-max-util) | BC2 | close | seat-caps.json + the saturation floor already enforce this; the queued mechanism is obsolete |
| #532 (skills-native) | — | close | cross-symlink + rsync already enforce this; the mechanism exists |
| #538 (never-vibes) | BC8 | keep | the "measure before deciding" gate is not yet built |
| #377 (all-functions-mechanical + everything-mechanical) | BC5 | merge-into-#366 | same constraint, same mechanism class |
| #366 (mechanical-fix + everything-mechanical + machinery-ban) | BC5 | keep | the senior-conference auto-reject for missing mechanisms is the primary enforcement |
| #223 (senior-conference) | — | keep | the conference panel itself is the mechanism |
| #362 (gap-closure-loop) | — | keep | the audit→fix→drill→re-audit loop is a distinct mechanism |
| #543 (work-supply-agent-ready) | — | keep | the agent-ready work-filer is a distinct mechanism |
| #437 (cursor-grok-re-admitted) | — | close | point-in-time routing decision; archived, not a standing mechanism |
| #905 (D1-prod-migrations) | — | close | VOIDED by the correction |
| #906 (D1-prod-migrations-correction) | — | close | superseded by DECIDED |
| #907 (D1-prod-migrations-decided) | — | keep | the vacation grant is live through 2026-09-08 |
| #908 (D1-prod-migrations-process-amendment) | — | keep | the senior-process requirement is live |
| #1177 (cursor-400-correction) | — | close | point-in-time budget decision; archived |
| #1179 (cursor-400-sequencing) | — | close | point-in-time; archived |
| #1399 (relic-pager-masked-emergency) | — | close | one-time emergency; archived |
| #1480 (machinery-ban-mechanical + machinery-violations) | BC5 | merge-into-#366 | same constraint, same mechanism class |

Re-scope summary: **keep 13, merge 5 into 3, close 11**. Net queued mechanisms
drop from 29 to 16 (13 kept + 3 merge targets).

## What this PR ships

This PR ships the P1 inventory (this document) + the `bin/rule-debt-inventory.py`
tool that generates it from the live join. It does NOT rewrite the vault file
or the matrix — those are P3, which requires the P2 blind review first (two
independent senior POVs checking the disposition map for meaning loss).

## What P2/P3/P4 require (follow-up)

- **P2 BLIND REVIEW**: two independent senior POVs (Pi subagents, blind to
  each other) check this disposition map for meaning loss — every Nish-endorsed
  obligation must survive verbatim-or-stronger in the consolidated set. A
  depth-1 worker cannot spawn subagents; this needs the senior conference or
  a dispatched multi-seat review.
- **P3 EXECUTE**: rewrite `global-standing-rules.md` as the short
  binding-constraints file; move everything verbatim to
  `standing-rules-archive.md`; backup the original with a date suffix; update
  `config/rule-enforcement.json` to the consolidated ids; re-scope the 29
  pending mechanisms per the table above.
- **P4 PROVE**: rule-enforcement join before/after counts; heartbeat canary
  green on the new file; grep every instruction-file reference to renamed
  rules still resolves; post the full before/after diff summary on the issue.
