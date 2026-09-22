# Label-sanity shadow run — 2026-09

Shadow-only measurement for fleet-ops#7762. **No labels were changed.** The proposed
corrections below are an advisory list for a separate, human-reviewed change.

This is the follow-up measurement to the benchmark in `docs/jev-benchmark-2026-09.md`,
where mechanically-derived truth labels and an independent text relabel disagreed on
92% of sampled issues. Here the question is narrower and runs at scale: for every open
issue in both repos plus the recent closed set, does the issue *text* justify a reserved
class, and do the applied labels agree?

## What this measures

For every issue in the cohort, one Jev call at site `label-sanity` asks two questions:

- **`reservedClass` (choice)** — which single class does the issue *text* justify, judged
  against the canonical reserved-classes list plus `auto_fixable`? The text only; the
  current labels are deliberately excluded from this question.
- **`labelsMatch` (boolean)** — do the applied labels correctly reflect the class the text
  justifies?

A **mismatch** is an issue where either the boolean says the labels do not match
(`labelsMatch < 0.5`) or the derived comparison disagrees (text-justified reserved-ness
differs from the reserved-ness the applied labels assert). Both flags are reported so the
two signals can be compared.

## Method

- Transport: the shared Jev helper, `POST 127.0.0.1:4000/jev`, key from the seat env file
  (never inlined). `state` carries the full context per the standing rule: roles,
  `reserved_class_definitions`, `label_semantics`, `rules`, and the issue
  (repo/number/state/title/body/first 3 comments/current labels/current label class).
- Criteria for the choice = the canonical reserved classes (money/pricing, privacy,
  security, legal, brand, product direction, customer-data deletion, destructive/
  irreversible, authority Nish explicitly reserved) plus `auto_fixable`.
- Label semantics used for the comparison: `nish-reserved` / `needs-nish-decision` assert
  reserved-to-Nish; `needs-orchestrator`, `escalate-senior`, `agent-ready`,
  `agent-in-progress`, `agent-blocked`, `question` and the rest assert non-reserved.
- Rows land in the shared site log `~/.local/state/pi-packet/jev/label-sanity.jsonl`
  (host state, not committed). Real records only; no invented samples.

## Cohort

| repo | open | closed | total |
|---|---|---|---|
| Nishfleet/0509 | 312 | 89 | 401 |
| Nishfleet/fleet-ops | 433 | 411 | 844 |
| **total** | **745** | **500** | **1245** |

Closed set = the 500 most recently closed issues across both repos (fleet-ops 411, 0509 89).
Calls: **1245**, errors: **0**; input tokens 3,107,017, output tokens 166,512; median latency 288 ms.

## Headline

| signal | count | share |
|---|---|---|
| issues in cohort | 1245 | 100% |
| text justifies a reserved class (`reservedClass != auto_fixable`) | 348 | 28% |
| applied labels assert reserved (`nish-reserved`/`needs-nish-decision`) | 46 | 4% |
| **mismatches (union)** | **351** | **28%** |
| `labelsMatch` false (boolean) | 215 | 17% |
| derived comparison disagrees (structural) | 336 | 27% |
| both flags agree it is a mismatch | 200 | |
| structural only (boolean says match) | 136 | |
| boolean only (structural says match) | 15 | |

Text-justified class distribution:

| class | issues |
|---|---|
| `auto_fixable` | 897 |
| `security` | 93 |
| `authority_nish_reserved` | 74 |
| `destructive_irreversible` | 59 |
| `money_pricing` | 47 |
| `product_direction` | 44 |
| `brand` | 19 |
| `privacy` | 8 |
| `customer_data_deletion` | 3 |
| `legal` | 1 |

Mismatch direction:

| direction | count |
|---|---|
| labels non-reserved, text justifies a reserved class | 319 |
| labels reserved, text justifies `auto_fixable` | 17 |

## Mismatches by label

Counts are per label; an issue can carry several labels. Rate = share of issues carrying
that label that are mismatches.

| label | issues with label | mismatches | rate |
|---|---|---|---|
| `agent-in-progress` | 425 | 128 | 30% |
| `agent-ready` | 287 | 79 | 28% |
| `superseded-by-rebuild` | 181 | 48 | 27% |
| `agent-blocked` | 139 | 74 | 53% |
| `scout-candidate` | 136 | 47 | 35% |
| `critical-path` | 122 | 48 | 39% |
| `needs-orchestrator` | 119 | 48 | 40% |
| `priority` | 100 | 59 | 59% |
| `observe-to-close` | 59 | 0 | 0% |
| `awaiting-runtime-gate` | 54 | 13 | 24% |
| `discarded` | 50 | 15 | 30% |
| `gap-audit` | 44 | 7 | 16% |
| `deploy-fault` | 44 | 6 | 14% |
| `research-delta` | 32 | 17 | 53% |
| `nish-reserved` | 30 | 18 | 60% |
| `escalate-senior` | 27 | 1 | 4% |
| `needs-nish-decision` | 19 | 13 | 68% |
| `bug` | 16 | 4 | 25% |
| `usage-uncited` | 14 | 4 | 29% |
| `stop-the-line` | 11 | 0 | 0% |
| `question` | 6 | 2 | 33% |
| `umbrella` | 5 | 5 | 100% |
| `red-on-main` | 5 | 0 | 0% |
| `noise-class` | 3 | 1 | 33% |
| `epic` | 3 | 1 | 33% |
| `deputy` | 3 | 3 | 100% |
| `enhancement` | 2 | 1 | 50% |
| `split-after-fix` | 2 | 0 | 0% |
| `triage-mass-close` | 1 | 1 | 100% |
| `auto-revert-halt` | 1 | 1 | 100% |
| `invalid` | 1 | 1 | 100% |
| `verification-only` | 1 | 1 | 100% |

## 50 highest-confidence mismatches

Confidence = the larger of the text-class probability (when the derived comparison
disagrees) and `1 - labelsMatch`. `p` is the text-justified class probability; `lm` is the
`labelsMatch` probability.

| # | issue | state | text class (p) | current labels | lm | proposed correction |
|---|---|---|---|---|---|---|
| 1 | [fleet-ops#7748](https://github.com/Nishfleet/fleet-ops/issues/7748) | open | `auto_fixable` (1.00) | `agent-blocked`, `needs-nish-decision` | 0.13 | remove `nish-reserved`/`needs-nish-decision`; add `agent-ready` |
| 2 | [fleet-ops#7747](https://github.com/Nishfleet/fleet-ops/issues/7747) | open | `auto_fixable` (1.00) | `agent-blocked`, `needs-nish-decision` | 0.12 | remove `nish-reserved`/`needs-nish-decision`; add `agent-ready` |
| 3 | [fleet-ops#7572](https://github.com/Nishfleet/fleet-ops/issues/7572) | open | `auto_fixable` (1.00) | `agent-blocked`, `needs-nish-decision` | 0.13 | remove `nish-reserved`/`needs-nish-decision`; add `agent-ready` |
| 4 | [0509#3648](https://github.com/Nishfleet/0509/issues/3648) | open | `money_pricing` (1.00) | `agent-blocked` | 0.19 | add `nish-reserved` |
| 5 | [fleet-ops#5807](https://github.com/Nishfleet/fleet-ops/issues/5807) | closed | `auto_fixable` (1.00) | `agent-ready`, `priority`, `nish-reserved` | 0.11 | remove `nish-reserved`/`needs-nish-decision`; keep `agent-ready` |
| 6 | [fleet-ops#7532](https://github.com/Nishfleet/fleet-ops/issues/7532) | closed | `security` (1.00) | `agent-ready` | 0.12 | add `nish-reserved`; remove `agent-ready` |
| 7 | [fleet-ops#7529](https://github.com/Nishfleet/fleet-ops/issues/7529) | closed | `security` (1.00) | `agent-ready` | 0.13 | add `nish-reserved`; remove `agent-ready` |
| 8 | [fleet-ops#6767](https://github.com/Nishfleet/fleet-ops/issues/6767) | open | `auto_fixable` (0.99) | `agent-blocked`, `nish-reserved` | 0.13 | remove `nish-reserved`/`needs-nish-decision`; add `agent-ready` |
| 9 | [0509#2982](https://github.com/Nishfleet/0509/issues/2982) | open | `customer_data_deletion` (0.99) | `discarded`, `superseded-by-rebuild` | 0.14 | add `nish-reserved` |
| 10 | [0509#3821](https://github.com/Nishfleet/0509/issues/3821) | open | `security` (0.99) | `superseded-by-rebuild` | 0.28 | add `nish-reserved` |
| 11 | [0509#3519](https://github.com/Nishfleet/0509/issues/3519) | open | `product_direction` (0.99) | `scout-candidate`, `research-delta`, `superseded-by-rebuild` | 0.33 | add `nish-reserved` |
| 12 | [fleet-ops#7463](https://github.com/Nishfleet/fleet-ops/issues/7463) | closed | `security` (0.99) | `agent-in-progress` | 0.13 | add `nish-reserved`; remove `agent-in-progress` |
| 13 | [fleet-ops#7448](https://github.com/Nishfleet/fleet-ops/issues/7448) | closed | `security` (0.99) | `agent-in-progress` | 0.12 | add `nish-reserved`; remove `agent-in-progress` |
| 14 | [fleet-ops#7381](https://github.com/Nishfleet/fleet-ops/issues/7381) | closed | `security` (0.99) | `agent-in-progress` | 0.12 | add `nish-reserved`; remove `agent-in-progress` |
| 15 | [0509#3861](https://github.com/Nishfleet/0509/issues/3861) | closed | `destructive_irreversible` (0.99) | `critical-path` | 0.48 | add `nish-reserved`; remove `critical-path` |
| 16 | [fleet-ops#6793](https://github.com/Nishfleet/fleet-ops/issues/6793) | closed | `security` (0.99) | `agent-in-progress`, `scout-candidate`, `research-delta` | 0.44 | add `nish-reserved`; remove `agent-in-progress` |
| 17 | [fleet-ops#6566](https://github.com/Nishfleet/fleet-ops/issues/6566) | closed | `security` (0.99) | `agent-in-progress` | 0.20 | add `nish-reserved`; remove `agent-in-progress` |
| 18 | [fleet-ops#7961](https://github.com/Nishfleet/fleet-ops/issues/7961) | open | `security` (0.98) | `agent-ready` | 0.29 | add `nish-reserved`; remove `agent-ready` |
| 19 | [fleet-ops#7779](https://github.com/Nishfleet/fleet-ops/issues/7779) | open | `security` (0.98) | `agent-ready`, `priority` | 0.27 | add `nish-reserved`; remove `agent-ready`, `priority` |
| 20 | [fleet-ops#3167](https://github.com/Nishfleet/fleet-ops/issues/3167) | open | `security` (0.98) | `agent-in-progress` | 0.38 | add `nish-reserved`; remove `agent-in-progress` |
| 21 | [0509#3768](https://github.com/Nishfleet/0509/issues/3768) | open | `security` (0.98) | `superseded-by-rebuild` | 0.26 | add `nish-reserved` |
| 22 | [0509#3862](https://github.com/Nishfleet/0509/issues/3862) | closed | `destructive_irreversible` (0.98) | `agent-in-progress`, `critical-path` | 0.58 | add `nish-reserved`; remove `agent-in-progress`, `critical-path` |
| 23 | [fleet-ops#6635](https://github.com/Nishfleet/fleet-ops/issues/6635) | closed | `security` (0.98) | `agent-in-progress`, `scout-candidate`, `research-delta` | 0.45 | add `nish-reserved`; remove `agent-in-progress` |
| 24 | [0509#2970](https://github.com/Nishfleet/0509/issues/2970) | open | `security` (0.97) | `scout-candidate`, `superseded-by-rebuild` | 0.25 | add `nish-reserved` |
| 25 | [0509#3078](https://github.com/Nishfleet/0509/issues/3078) | open | `security` (0.97) | `scout-candidate`, `superseded-by-rebuild` | 0.34 | add `nish-reserved` |
| 26 | [0509#3304](https://github.com/Nishfleet/0509/issues/3304) | open | `product_direction` (0.97) | `scout-candidate`, `research-delta`, `superseded-by-rebuild` | 0.43 | add `nish-reserved` |
| 27 | [fleet-ops#4518](https://github.com/Nishfleet/fleet-ops/issues/4518) | closed | `product_direction` (0.97) | `agent-in-progress`, `priority` | 0.13 | add `nish-reserved`; remove `agent-in-progress`, `priority` |
| 28 | [fleet-ops#8050](https://github.com/Nishfleet/fleet-ops/issues/8050) | open | `destructive_irreversible` (0.95) | `agent-blocked`, `needs-orchestrator` | 0.45 | add `nish-reserved` |
| 29 | [fleet-ops#8038](https://github.com/Nishfleet/fleet-ops/issues/8038) | open | `destructive_irreversible` (0.95) | `agent-ready` | 0.55 | add `nish-reserved`; remove `agent-ready` |
| 30 | [fleet-ops#7978](https://github.com/Nishfleet/fleet-ops/issues/7978) | open | `destructive_irreversible` (0.95) | `agent-ready` | 0.39 | add `nish-reserved`; remove `agent-ready` |
| 31 | [fleet-ops#7934](https://github.com/Nishfleet/fleet-ops/issues/7934) | open | `security` (0.95) | `agent-ready` | 0.17 | add `nish-reserved`; remove `agent-ready` |
| 32 | [0509#3458](https://github.com/Nishfleet/0509/issues/3458) | open | `brand` (0.95) | `scout-candidate`, `research-delta`, `superseded-by-rebuild` | 0.58 | add `nish-reserved` |
| 33 | [0509#1258](https://github.com/Nishfleet/0509/issues/1258) | closed | `product_direction` (0.95) | `agent-ready`, `scout-candidate`, `research-delta` | 0.33 | add `nish-reserved`; remove `agent-ready` |
| 34 | [fleet-ops#7829](https://github.com/Nishfleet/fleet-ops/issues/7829) | closed | `destructive_irreversible` (0.95) | `agent-in-progress`, `critical-path`, `priority` | 0.47 | add `nish-reserved`; remove `agent-in-progress`, `critical-path`, `priority` |
| 35 | [fleet-ops#7505](https://github.com/Nishfleet/fleet-ops/issues/7505) | closed | `security` (0.95) | _(none)_ | 0.58 | add `nish-reserved` |
| 36 | [0509#3592](https://github.com/Nishfleet/0509/issues/3592) | closed | `brand` (0.94) | `agent-in-progress`, `usage-uncited` | 0.80 | add `nish-reserved`; remove `agent-in-progress` |
| 37 | [fleet-ops#3345](https://github.com/Nishfleet/fleet-ops/issues/3345) | open | `authority_nish_reserved` (0.94) | `agent-blocked`, `needs-orchestrator` | 0.30 | add `nish-reserved` |
| 38 | [fleet-ops#4459](https://github.com/Nishfleet/fleet-ops/issues/4459) | open | `money_pricing` (0.93) | `agent-ready`, `priority`, `needs-orchestrator`, `awaiting-runtime-gate` | 0.45 | add `nish-reserved`; remove `agent-ready`, `priority` |
| 39 | [fleet-ops#8055](https://github.com/Nishfleet/fleet-ops/issues/8055) | open | `security` (0.93) | `agent-ready` | 0.54 | add `nish-reserved`; remove `agent-ready` |
| 40 | [fleet-ops#7967](https://github.com/Nishfleet/fleet-ops/issues/7967) | open | `money_pricing` (0.93) | `agent-ready` | 0.18 | add `nish-reserved`; remove `agent-ready` |
| 41 | [fleet-ops#3150](https://github.com/Nishfleet/fleet-ops/issues/3150) | open | `money_pricing` (0.93) | `agent-in-progress`, `critical-path`, `umbrella` | 0.15 | add `nish-reserved`; remove `agent-in-progress`, `critical-path` |
| 42 | [fleet-ops#4403](https://github.com/Nishfleet/fleet-ops/issues/4403) | open | `security` (0.93) | `agent-in-progress` | 0.32 | add `nish-reserved`; remove `agent-in-progress` |
| 43 | [0509#2973](https://github.com/Nishfleet/0509/issues/2973) | open | `legal` (0.93) | `discarded`, `superseded-by-rebuild` | 0.15 | add `nish-reserved` |
| 44 | [0509#3231](https://github.com/Nishfleet/0509/issues/3231) | open | `brand` (0.93) | `scout-candidate`, `superseded-by-rebuild` | 0.62 | add `nish-reserved` |
| 45 | [0509#3796](https://github.com/Nishfleet/0509/issues/3796) | open | `destructive_irreversible` (0.93) | `superseded-by-rebuild` | 0.25 | add `nish-reserved` |
| 46 | [0509#3431](https://github.com/Nishfleet/0509/issues/3431) | open | `money_pricing` (0.93) | `discarded`, `superseded-by-rebuild` | 0.14 | add `nish-reserved` |
| 47 | [fleet-ops#7863](https://github.com/Nishfleet/fleet-ops/issues/7863) | closed | `destructive_irreversible` (0.93) | `agent-ready` | 0.36 | add `nish-reserved`; remove `agent-ready` |
| 48 | [fleet-ops#8079](https://github.com/Nishfleet/fleet-ops/issues/8079) | open | `authority_nish_reserved` (0.92) | `agent-ready` | 0.14 | add `nish-reserved`; remove `agent-ready` |
| 49 | [fleet-ops#8033](https://github.com/Nishfleet/fleet-ops/issues/8033) | open | `security` (0.92) | `agent-ready` | 0.51 | add `nish-reserved`; remove `agent-ready` |
| 50 | [0509#2964](https://github.com/Nishfleet/0509/issues/2964) | open | `security` (0.92) | `scout-candidate`, `needs-orchestrator`, `awaiting-runtime-gate` | 0.44 | add `nish-reserved` |

## Proposed correction list

Grouped over all 351 mismatches; the 50 rows above are the highest-confidence slice of
this list. The full list is in the appendix so a follow-up correction PR is mechanical.

| correction | count |
|---|---|
| add `nish-reserved` (and unclaim) — text justifies a reserved class, labels do not | 319 |
| remove `nish-reserved`/`needs-nish-decision` — text justifies `auto_fixable` | 17 |

Reserved classes behind the `add nish-reserved` group:

| text class | issues |
|---|---|
| `security` | 86 |
| `authority_nish_reserved` | 69 |
| `destructive_irreversible` | 55 |
| `money_pricing` | 39 |
| `product_direction` | 39 |
| `brand` | 19 |
| `privacy` | 8 |
| `customer_data_deletion` | 3 |
| `legal` | 1 |

Corrections are applied by a separate human-reviewed PR, not this one. Nothing in this
report changes a label, closes an issue, or claims work.

## Calibration notes and limits

- The boolean and the derived comparison disagree on 151 issues (136 structural-only, 15
  boolean-only). Structural-only cases are ones where the applied labels assert
  non-reserved but the text justifies a reserved class while `labelsMatch` still reads
  `true`; boolean-only cases are the reverse. Treat the union as the candidate set.
- `needs-orchestrator` is treated as non-reserved, per the canonical rule that only the
  reserved classes reach Nish and everything else parks on the orchestrator. The
  benchmark-B truth set treated it (and `question`, `escalate-senior`) as reserved, which
  is part of why truth labels and text relabels disagreed there.
- The text classifier can over-attribute `security`/`destructive_irreversible` to issues
  that merely mention secrets, auth, deletion or reverts without asking Nish to decide
  anything. The per-label rates above show where that bites; the top-50 list is the
  highest-confidence slice, not a verdict.
- Jev is a first opinion only. This run is advisory (`advisory_only: true`, band edges
  `null`) and scored later like the other shadow sites.
- The highest-confidence slice is dominated by `security` (21 of the top 50) and
  `destructive_irreversible` (8), the two classes most prone to over-attribution, so
  read the top-50 as a triage queue, not a correction list. `authority_nish_reserved` is
  the catch-all class and carries the long tail of the full list (70 of 351).

## Appendix — full mismatch list

All 351 mismatches, ordered by confidence. `text class` is the class the text justifies;
`lm` is the `labelsMatch` probability.

| issue | state | text class | current labels | lm | proposed correction |
|---|---|---|---|---|---|
| [fleet-ops#7748](https://github.com/Nishfleet/fleet-ops/issues/7748) | open | `auto_fixable` | `agent-blocked`, `needs-nish-decision` | 0.13 | remove `nish-reserved`/`needs-nish-decision`; add `agent-ready` |
| [fleet-ops#7747](https://github.com/Nishfleet/fleet-ops/issues/7747) | open | `auto_fixable` | `agent-blocked`, `needs-nish-decision` | 0.12 | remove `nish-reserved`/`needs-nish-decision`; add `agent-ready` |
| [fleet-ops#7572](https://github.com/Nishfleet/fleet-ops/issues/7572) | open | `auto_fixable` | `agent-blocked`, `needs-nish-decision` | 0.13 | remove `nish-reserved`/`needs-nish-decision`; add `agent-ready` |
| [0509#3648](https://github.com/Nishfleet/0509/issues/3648) | open | `money_pricing` | `agent-blocked` | 0.19 | add `nish-reserved` |
| [fleet-ops#5807](https://github.com/Nishfleet/fleet-ops/issues/5807) | closed | `auto_fixable` | `agent-ready`, `priority`, `nish-reserved` | 0.11 | remove `nish-reserved`/`needs-nish-decision`; keep `agent-ready` |
| [fleet-ops#7532](https://github.com/Nishfleet/fleet-ops/issues/7532) | closed | `security` | `agent-ready` | 0.12 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#7529](https://github.com/Nishfleet/fleet-ops/issues/7529) | closed | `security` | `agent-ready` | 0.13 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#6767](https://github.com/Nishfleet/fleet-ops/issues/6767) | open | `auto_fixable` | `agent-blocked`, `nish-reserved` | 0.13 | remove `nish-reserved`/`needs-nish-decision`; add `agent-ready` |
| [0509#2982](https://github.com/Nishfleet/0509/issues/2982) | open | `customer_data_deletion` | `discarded`, `superseded-by-rebuild` | 0.14 | add `nish-reserved` |
| [0509#3821](https://github.com/Nishfleet/0509/issues/3821) | open | `security` | `superseded-by-rebuild` | 0.28 | add `nish-reserved` |
| [0509#3519](https://github.com/Nishfleet/0509/issues/3519) | open | `product_direction` | `scout-candidate`, `research-delta`, `superseded-by-rebuild` | 0.33 | add `nish-reserved` |
| [fleet-ops#7463](https://github.com/Nishfleet/fleet-ops/issues/7463) | closed | `security` | `agent-in-progress` | 0.13 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#7448](https://github.com/Nishfleet/fleet-ops/issues/7448) | closed | `security` | `agent-in-progress` | 0.12 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#7381](https://github.com/Nishfleet/fleet-ops/issues/7381) | closed | `security` | `agent-in-progress` | 0.12 | add `nish-reserved`; remove `agent-in-progress` |
| [0509#3861](https://github.com/Nishfleet/0509/issues/3861) | closed | `destructive_irreversible` | `critical-path` | 0.48 | add `nish-reserved`; remove `critical-path` |
| [fleet-ops#6793](https://github.com/Nishfleet/fleet-ops/issues/6793) | closed | `security` | `agent-in-progress`, `scout-candidate`, `research-delta` | 0.44 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#6566](https://github.com/Nishfleet/fleet-ops/issues/6566) | closed | `security` | `agent-in-progress` | 0.20 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#7961](https://github.com/Nishfleet/fleet-ops/issues/7961) | open | `security` | `agent-ready` | 0.29 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#7779](https://github.com/Nishfleet/fleet-ops/issues/7779) | open | `security` | `agent-ready`, `priority` | 0.27 | add `nish-reserved`; remove `agent-ready`, `priority` |
| [fleet-ops#3167](https://github.com/Nishfleet/fleet-ops/issues/3167) | open | `security` | `agent-in-progress` | 0.38 | add `nish-reserved`; remove `agent-in-progress` |
| [0509#3768](https://github.com/Nishfleet/0509/issues/3768) | open | `security` | `superseded-by-rebuild` | 0.26 | add `nish-reserved` |
| [0509#3862](https://github.com/Nishfleet/0509/issues/3862) | closed | `destructive_irreversible` | `agent-in-progress`, `critical-path` | 0.58 | add `nish-reserved`; remove `agent-in-progress`, `critical-path` |
| [fleet-ops#6635](https://github.com/Nishfleet/fleet-ops/issues/6635) | closed | `security` | `agent-in-progress`, `scout-candidate`, `research-delta` | 0.45 | add `nish-reserved`; remove `agent-in-progress` |
| [0509#2970](https://github.com/Nishfleet/0509/issues/2970) | open | `security` | `scout-candidate`, `superseded-by-rebuild` | 0.25 | add `nish-reserved` |
| [0509#3078](https://github.com/Nishfleet/0509/issues/3078) | open | `security` | `scout-candidate`, `superseded-by-rebuild` | 0.34 | add `nish-reserved` |
| [0509#3304](https://github.com/Nishfleet/0509/issues/3304) | open | `product_direction` | `scout-candidate`, `research-delta`, `superseded-by-rebuild` | 0.43 | add `nish-reserved` |
| [fleet-ops#4518](https://github.com/Nishfleet/fleet-ops/issues/4518) | closed | `product_direction` | `agent-in-progress`, `priority` | 0.13 | add `nish-reserved`; remove `agent-in-progress`, `priority` |
| [fleet-ops#8050](https://github.com/Nishfleet/fleet-ops/issues/8050) | open | `destructive_irreversible` | `agent-blocked`, `needs-orchestrator` | 0.45 | add `nish-reserved` |
| [fleet-ops#8038](https://github.com/Nishfleet/fleet-ops/issues/8038) | open | `destructive_irreversible` | `agent-ready` | 0.55 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#7978](https://github.com/Nishfleet/fleet-ops/issues/7978) | open | `destructive_irreversible` | `agent-ready` | 0.39 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#7934](https://github.com/Nishfleet/fleet-ops/issues/7934) | open | `security` | `agent-ready` | 0.17 | add `nish-reserved`; remove `agent-ready` |
| [0509#3458](https://github.com/Nishfleet/0509/issues/3458) | open | `brand` | `scout-candidate`, `research-delta`, `superseded-by-rebuild` | 0.58 | add `nish-reserved` |
| [0509#1258](https://github.com/Nishfleet/0509/issues/1258) | closed | `product_direction` | `agent-ready`, `scout-candidate`, `research-delta` | 0.33 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#7829](https://github.com/Nishfleet/fleet-ops/issues/7829) | closed | `destructive_irreversible` | `agent-in-progress`, `critical-path`, `priority` | 0.47 | add `nish-reserved`; remove `agent-in-progress`, `critical-path`, `priority` |
| [fleet-ops#7505](https://github.com/Nishfleet/fleet-ops/issues/7505) | closed | `security` | _(none)_ | 0.58 | add `nish-reserved` |
| [0509#3592](https://github.com/Nishfleet/0509/issues/3592) | closed | `brand` | `agent-in-progress`, `usage-uncited` | 0.80 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#3345](https://github.com/Nishfleet/fleet-ops/issues/3345) | open | `authority_nish_reserved` | `agent-blocked`, `needs-orchestrator` | 0.30 | add `nish-reserved` |
| [fleet-ops#4459](https://github.com/Nishfleet/fleet-ops/issues/4459) | open | `money_pricing` | `agent-ready`, `priority`, `needs-orchestrator`, `awaiting-runtime-gate` | 0.45 | add `nish-reserved`; remove `agent-ready`, `priority` |
| [fleet-ops#8055](https://github.com/Nishfleet/fleet-ops/issues/8055) | open | `security` | `agent-ready` | 0.54 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#7967](https://github.com/Nishfleet/fleet-ops/issues/7967) | open | `money_pricing` | `agent-ready` | 0.18 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#3150](https://github.com/Nishfleet/fleet-ops/issues/3150) | open | `money_pricing` | `agent-in-progress`, `critical-path`, `umbrella` | 0.15 | add `nish-reserved`; remove `agent-in-progress`, `critical-path` |
| [fleet-ops#4403](https://github.com/Nishfleet/fleet-ops/issues/4403) | open | `security` | `agent-in-progress` | 0.32 | add `nish-reserved`; remove `agent-in-progress` |
| [0509#2973](https://github.com/Nishfleet/0509/issues/2973) | open | `legal` | `discarded`, `superseded-by-rebuild` | 0.15 | add `nish-reserved` |
| [0509#3231](https://github.com/Nishfleet/0509/issues/3231) | open | `brand` | `scout-candidate`, `superseded-by-rebuild` | 0.62 | add `nish-reserved` |
| [0509#3796](https://github.com/Nishfleet/0509/issues/3796) | open | `destructive_irreversible` | `superseded-by-rebuild` | 0.25 | add `nish-reserved` |
| [0509#3431](https://github.com/Nishfleet/0509/issues/3431) | open | `money_pricing` | `discarded`, `superseded-by-rebuild` | 0.14 | add `nish-reserved` |
| [fleet-ops#7863](https://github.com/Nishfleet/fleet-ops/issues/7863) | closed | `destructive_irreversible` | `agent-ready` | 0.36 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#8079](https://github.com/Nishfleet/fleet-ops/issues/8079) | open | `authority_nish_reserved` | `agent-ready` | 0.14 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#8033](https://github.com/Nishfleet/fleet-ops/issues/8033) | open | `security` | `agent-ready` | 0.51 | add `nish-reserved`; remove `agent-ready` |
| [0509#2964](https://github.com/Nishfleet/0509/issues/2964) | open | `security` | `scout-candidate`, `needs-orchestrator`, `awaiting-runtime-gate` | 0.44 | add `nish-reserved` |
| [0509#3080](https://github.com/Nishfleet/0509/issues/3080) | open | `authority_nish_reserved` | `scout-candidate`, `superseded-by-rebuild` | 0.38 | add `nish-reserved` |
| [0509#3353](https://github.com/Nishfleet/0509/issues/3353) | open | `product_direction` | `scout-candidate`, `research-delta`, `superseded-by-rebuild` | 0.45 | add `nish-reserved` |
| [fleet-ops#4147](https://github.com/Nishfleet/fleet-ops/issues/4147) | closed | `destructive_irreversible` | `agent-in-progress`, `critical-path`, `priority`, `awaiting-runtime-gate` | 0.41 | add `nish-reserved`; remove `agent-in-progress`, `critical-path`, `priority` |
| [0509#2546](https://github.com/Nishfleet/0509/issues/2546) | closed | `brand` | `agent-in-progress`, `scout-candidate` | 0.71 | add `nish-reserved`; remove `agent-in-progress` |
| [0509#3602](https://github.com/Nishfleet/0509/issues/3602) | closed | `brand` | `agent-in-progress` | 0.54 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#6571](https://github.com/Nishfleet/fleet-ops/issues/6571) | closed | `authority_nish_reserved` | `gap-audit` | 0.28 | add `nish-reserved` |
| [0509#2817](https://github.com/Nishfleet/0509/issues/2817) | closed | `security` | `agent-in-progress`, `scout-candidate` | 0.55 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#6593](https://github.com/Nishfleet/fleet-ops/issues/6593) | closed | `security` | `agent-in-progress`, `scout-candidate`, `research-delta` | 0.67 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#7526](https://github.com/Nishfleet/fleet-ops/issues/7526) | open | `auto_fixable` | `agent-blocked`, `nish-reserved` | 0.25 | remove `nish-reserved`/`needs-nish-decision`; add `agent-ready` |
| [fleet-ops#7813](https://github.com/Nishfleet/fleet-ops/issues/7813) | open | `authority_nish_reserved` | `agent-ready` | 0.19 | add `nish-reserved`; remove `agent-ready` |
| [0509#3132](https://github.com/Nishfleet/0509/issues/3132) | open | `product_direction` | `scout-candidate`, `superseded-by-rebuild` | 0.23 | add `nish-reserved` |
| [0509#3568](https://github.com/Nishfleet/0509/issues/3568) | open | `brand` | `agent-blocked` | 0.51 | add `nish-reserved` |
| [0509#3860](https://github.com/Nishfleet/0509/issues/3860) | closed | `destructive_irreversible` | `critical-path` | 0.53 | add `nish-reserved`; remove `critical-path` |
| [fleet-ops#4142](https://github.com/Nishfleet/fleet-ops/issues/4142) | closed | `destructive_irreversible` | `invalid`, `agent-in-progress`, `critical-path`, `priority`, `awaiting-runtime-gate` | 0.39 | add `nish-reserved`; remove `agent-in-progress`, `critical-path`, `priority` |
| [0509#3621](https://github.com/Nishfleet/0509/issues/3621) | closed | `security` | `agent-ready`, `agent-blocked`, `needs-orchestrator` | 0.30 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#7842](https://github.com/Nishfleet/fleet-ops/issues/7842) | closed | `destructive_irreversible` | `agent-ready` | 0.67 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#8061](https://github.com/Nishfleet/fleet-ops/issues/8061) | open | `authority_nish_reserved` | `agent-ready`, `agent-blocked`, `needs-orchestrator` | 0.20 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#5707](https://github.com/Nishfleet/fleet-ops/issues/5707) | open | `authority_nish_reserved` | `agent-in-progress` | 0.11 | add `nish-reserved`; remove `agent-in-progress` |
| [0509#3678](https://github.com/Nishfleet/0509/issues/3678) | closed | `destructive_irreversible` | `agent-ready` | 0.49 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#7966](https://github.com/Nishfleet/fleet-ops/issues/7966) | open | `money_pricing` | `agent-ready` | 0.16 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#8119](https://github.com/Nishfleet/fleet-ops/issues/8119) | open | `authority_nish_reserved` | `agent-ready` | 0.12 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#7970](https://github.com/Nishfleet/fleet-ops/issues/7970) | open | `money_pricing` | `agent-ready` | 0.12 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#5385](https://github.com/Nishfleet/fleet-ops/issues/5385) | open | `destructive_irreversible` | `agent-in-progress` | 0.14 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#7450](https://github.com/Nishfleet/fleet-ops/issues/7450) | open | `security` | `agent-in-progress`, `critical-path`, `priority` | 0.30 | add `nish-reserved`; remove `agent-in-progress`, `critical-path`, `priority` |
| [0509#3778](https://github.com/Nishfleet/0509/issues/3778) | open | `security` | `agent-in-progress`, `critical-path` | 0.60 | add `nish-reserved`; remove `agent-in-progress`, `critical-path` |
| [0509#3567](https://github.com/Nishfleet/0509/issues/3567) | open | `privacy` | `agent-in-progress` | 0.21 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#7975](https://github.com/Nishfleet/fleet-ops/issues/7975) | open | `security` | `agent-ready` | 0.20 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#4232](https://github.com/Nishfleet/fleet-ops/issues/4232) | open | `security` | `agent-in-progress` | 0.33 | add `nish-reserved`; remove `agent-in-progress` |
| [0509#2188](https://github.com/Nishfleet/0509/issues/2188) | open | `brand` | `needs-orchestrator`, `awaiting-runtime-gate`, `superseded-by-rebuild` | 0.55 | add `nish-reserved` |
| [0509#3168](https://github.com/Nishfleet/0509/issues/3168) | open | `customer_data_deletion` | `discarded`, `superseded-by-rebuild` | 0.37 | add `nish-reserved` |
| [0509#3061](https://github.com/Nishfleet/0509/issues/3061) | open | `authority_nish_reserved` | `discarded`, `superseded-by-rebuild` | 0.13 | add `nish-reserved` |
| [0509#3720](https://github.com/Nishfleet/0509/issues/3720) | open | `brand` | `scout-candidate`, `superseded-by-rebuild` | 0.14 | add `nish-reserved` |
| [fleet-ops#6784](https://github.com/Nishfleet/fleet-ops/issues/6784) | open | `security` | `agent-blocked`, `needs-orchestrator` | 0.20 | add `nish-reserved` |
| [fleet-ops#8032](https://github.com/Nishfleet/fleet-ops/issues/8032) | open | `destructive_irreversible` | `agent-ready` | 0.68 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#7782](https://github.com/Nishfleet/fleet-ops/issues/7782) | open | `authority_nish_reserved` | `agent-ready` | 0.14 | add `nish-reserved`; remove `agent-ready` |
| [0509#3863](https://github.com/Nishfleet/0509/issues/3863) | closed | `destructive_irreversible` | `agent-blocked`, `critical-path` | 0.50 | add `nish-reserved`; remove `critical-path` |
| [0509#2158](https://github.com/Nishfleet/0509/issues/2158) | open | `brand` | `agent-in-progress` | 0.15 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#6569](https://github.com/Nishfleet/fleet-ops/issues/6569) | closed | `authority_nish_reserved` | `agent-in-progress`, `gap-audit` | 0.34 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#6392](https://github.com/Nishfleet/fleet-ops/issues/6392) | open | `authority_nish_reserved` | `agent-blocked`, `needs-orchestrator` | 0.27 | add `nish-reserved` |
| [fleet-ops#6770](https://github.com/Nishfleet/fleet-ops/issues/6770) | open | `destructive_irreversible` | `agent-ready`, `needs-orchestrator`, `awaiting-runtime-gate` | 0.44 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#8082](https://github.com/Nishfleet/fleet-ops/issues/8082) | open | `money_pricing` | `agent-ready` | 0.16 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#7462](https://github.com/Nishfleet/fleet-ops/issues/7462) | open | `destructive_irreversible` | `agent-in-progress`, `critical-path`, `priority`, `awaiting-runtime-gate` | 0.16 | add `nish-reserved`; remove `agent-in-progress`, `critical-path`, `priority` |
| [fleet-ops#7915](https://github.com/Nishfleet/fleet-ops/issues/7915) | open | `destructive_irreversible` | `agent-ready` | 0.41 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#7856](https://github.com/Nishfleet/fleet-ops/issues/7856) | open | `destructive_irreversible` | `agent-ready` | 0.72 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#3234](https://github.com/Nishfleet/fleet-ops/issues/3234) | open | `authority_nish_reserved` | `agent-in-progress` | 0.31 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#1853](https://github.com/Nishfleet/fleet-ops/issues/1853) | open | `money_pricing` | `agent-in-progress` | 0.50 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#6572](https://github.com/Nishfleet/fleet-ops/issues/6572) | closed | `authority_nish_reserved` | `gap-audit`, `verification-only` | 0.27 | add `nish-reserved` |
| [0509#3576](https://github.com/Nishfleet/0509/issues/3576) | closed | `money_pricing` | `discarded` | 0.16 | add `nish-reserved` |
| [fleet-ops#7486](https://github.com/Nishfleet/fleet-ops/issues/7486) | closed | `security` | `agent-ready` | 0.62 | add `nish-reserved`; remove `agent-ready` |
| [0509#3593](https://github.com/Nishfleet/0509/issues/3593) | closed | `brand` | `agent-in-progress`, `usage-uncited` | 0.84 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#7719](https://github.com/Nishfleet/fleet-ops/issues/7719) | open | `auto_fixable` | `agent-blocked`, `needs-nish-decision` | 0.17 | remove `nish-reserved`/`needs-nish-decision`; add `agent-ready` |
| [fleet-ops#7836](https://github.com/Nishfleet/fleet-ops/issues/7836) | open | `money_pricing` | `agent-ready` | 0.48 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#7501](https://github.com/Nishfleet/fleet-ops/issues/7501) | open | `security` | `agent-in-progress`, `critical-path` | 0.46 | add `nish-reserved`; remove `agent-in-progress`, `critical-path` |
| [0509#3918](https://github.com/Nishfleet/0509/issues/3918) | open | `security` | `agent-blocked`, `critical-path`, `needs-orchestrator` | 0.46 | add `nish-reserved`; remove `critical-path` |
| [0509#3747](https://github.com/Nishfleet/0509/issues/3747) | open | `product_direction` | `superseded-by-rebuild` | 0.17 | add `nish-reserved` |
| [fleet-ops#7927](https://github.com/Nishfleet/fleet-ops/issues/7927) | open | `security` | `agent-ready` | 0.18 | add `nish-reserved`; remove `agent-ready` |
| [0509#3842](https://github.com/Nishfleet/0509/issues/3842) | open | `product_direction` | `agent-in-progress`, `critical-path`, `epic` | 0.18 | add `nish-reserved`; remove `agent-in-progress`, `critical-path` |
| [fleet-ops#7368](https://github.com/Nishfleet/fleet-ops/issues/7368) | closed | `security` | `agent-ready` | 0.49 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#5792](https://github.com/Nishfleet/fleet-ops/issues/5792) | open | `money_pricing` | `bug`, `agent-in-progress`, `critical-path`, `priority` | 0.22 | add `nish-reserved`; remove `agent-in-progress`, `critical-path`, `priority` |
| [fleet-ops#7844](https://github.com/Nishfleet/fleet-ops/issues/7844) | open | `destructive_irreversible` | `agent-ready`, `priority` | 0.54 | add `nish-reserved`; remove `agent-ready`, `priority` |
| [0509#2646](https://github.com/Nishfleet/0509/issues/2646) | open | `money_pricing` | `bug`, `scout-candidate`, `critical-path`, `needs-orchestrator`, `awaiting-runtime-gate`, `deploy-fault` | 0.52 | add `nish-reserved`; remove `critical-path` |
| [0509#2671](https://github.com/Nishfleet/0509/issues/2671) | open | `authority_nish_reserved` | `agent-blocked`, `scout-candidate` | 0.19 | add `nish-reserved` |
| [fleet-ops#4625](https://github.com/Nishfleet/fleet-ops/issues/4625) | open | `authority_nish_reserved` | `agent-ready`, `needs-orchestrator`, `awaiting-runtime-gate` | 0.20 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#7828](https://github.com/Nishfleet/fleet-ops/issues/7828) | open | `destructive_irreversible` | `agent-in-progress`, `critical-path`, `priority`, `needs-orchestrator` | 0.20 | add `nish-reserved`; remove `agent-in-progress`, `critical-path`, `priority` |
| [fleet-ops#8045](https://github.com/Nishfleet/fleet-ops/issues/8045) | open | `destructive_irreversible` | `agent-ready` | 0.74 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#7765](https://github.com/Nishfleet/fleet-ops/issues/7765) | open | `privacy` | `agent-ready`, `priority` | 0.22 | add `nish-reserved`; remove `agent-ready`, `priority` |
| [fleet-ops#7397](https://github.com/Nishfleet/fleet-ops/issues/7397) | closed | `security` | `agent-in-progress`, `priority` | 0.43 | add `nish-reserved`; remove `agent-in-progress`, `priority` |
| [fleet-ops#8003](https://github.com/Nishfleet/fleet-ops/issues/8003) | closed | `destructive_irreversible` | `bug`, `agent-in-progress`, `critical-path` | 0.64 | add `nish-reserved`; remove `agent-in-progress`, `critical-path` |
| [0509#1948](https://github.com/Nishfleet/0509/issues/1948) | closed | `security` | `agent-ready`, `discarded` | 0.59 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#7398](https://github.com/Nishfleet/fleet-ops/issues/7398) | closed | `security` | `agent-ready`, `priority` | 0.35 | add `nish-reserved`; remove `agent-ready`, `priority` |
| [fleet-ops#7751](https://github.com/Nishfleet/fleet-ops/issues/7751) | open | `auto_fixable` | `agent-blocked`, `needs-nish-decision` | 0.21 | remove `nish-reserved`/`needs-nish-decision`; add `agent-ready` |
| [0509#2997](https://github.com/Nishfleet/0509/issues/2997) | open | `security` | `needs-orchestrator`, `awaiting-runtime-gate`, `deploy-fault` | 0.65 | add `nish-reserved` |
| [0509#3910](https://github.com/Nishfleet/0509/issues/3910) | open | `security` | `agent-blocked`, `critical-path`, `needs-orchestrator` | 0.23 | add `nish-reserved`; remove `critical-path` |
| [0509#3149](https://github.com/Nishfleet/0509/issues/3149) | open | `product_direction` | `question`, `scout-candidate`, `superseded-by-rebuild` | 0.21 | add `nish-reserved` |
| [fleet-ops#7392](https://github.com/Nishfleet/fleet-ops/issues/7392) | closed | `security` | `agent-in-progress`, `priority` | 0.29 | add `nish-reserved`; remove `agent-in-progress`, `priority` |
| [fleet-ops#7400](https://github.com/Nishfleet/fleet-ops/issues/7400) | open | `auto_fixable` | `agent-blocked`, `priority`, `needs-nish-decision` | 0.22 | remove `nish-reserved`/`needs-nish-decision`; add `agent-ready` |
| [fleet-ops#7395](https://github.com/Nishfleet/fleet-ops/issues/7395) | open | `security` | `agent-blocked`, `priority`, `needs-orchestrator` | 0.42 | add `nish-reserved`; remove `priority` |
| [fleet-ops#7370](https://github.com/Nishfleet/fleet-ops/issues/7370) | open | `product_direction` | `agent-blocked`, `umbrella`, `priority`, `needs-orchestrator` | 0.22 | add `nish-reserved`; remove `priority` |
| [fleet-ops#7865](https://github.com/Nishfleet/fleet-ops/issues/7865) | open | `authority_nish_reserved` | `agent-ready` | 0.22 | add `nish-reserved`; remove `agent-ready` |
| [0509#3847](https://github.com/Nishfleet/0509/issues/3847) | open | `destructive_irreversible` | `agent-blocked`, `critical-path`, `needs-orchestrator` | 0.43 | add `nish-reserved`; remove `critical-path` |
| [0509#2971](https://github.com/Nishfleet/0509/issues/2971) | open | `security` | `discarded`, `superseded-by-rebuild` | 0.59 | add `nish-reserved` |
| [0509#3151](https://github.com/Nishfleet/0509/issues/3151) | open | `product_direction` | `discarded`, `superseded-by-rebuild` | 0.52 | add `nish-reserved` |
| [0509#3536](https://github.com/Nishfleet/0509/issues/3536) | open | `security` | `agent-in-progress` | 0.35 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#7396](https://github.com/Nishfleet/fleet-ops/issues/7396) | closed | `security` | `agent-in-progress`, `priority` | 0.41 | add `nish-reserved`; remove `agent-in-progress`, `priority` |
| [fleet-ops#7394](https://github.com/Nishfleet/fleet-ops/issues/7394) | closed | `security` | `agent-ready`, `priority` | 0.40 | add `nish-reserved`; remove `agent-ready`, `priority` |
| [fleet-ops#7388](https://github.com/Nishfleet/fleet-ops/issues/7388) | closed | `security` | `agent-blocked`, `priority` | 0.33 | add `nish-reserved`; remove `priority` |
| [fleet-ops#7770](https://github.com/Nishfleet/fleet-ops/issues/7770) | closed | `authority_nish_reserved` | `priority`, `awaiting-runtime-gate` | 0.62 | add `nish-reserved`; remove `priority` |
| [fleet-ops#7664](https://github.com/Nishfleet/fleet-ops/issues/7664) | closed | `security` | `agent-in-progress`, `critical-path`, `priority` | 0.33 | add `nish-reserved`; remove `agent-in-progress`, `critical-path`, `priority` |
| [fleet-ops#7447](https://github.com/Nishfleet/fleet-ops/issues/7447) | open | `privacy` | `agent-in-progress`, `agent-blocked`, `needs-orchestrator` | 0.23 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#4598](https://github.com/Nishfleet/fleet-ops/issues/4598) | open | `authority_nish_reserved` | `agent-in-progress` | 0.30 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#6032](https://github.com/Nishfleet/fleet-ops/issues/6032) | open | `authority_nish_reserved` | `agent-in-progress`, `critical-path` | 0.38 | add `nish-reserved`; remove `agent-in-progress`, `critical-path` |
| [0509#3881](https://github.com/Nishfleet/0509/issues/3881) | open | `money_pricing` | `critical-path`, `deputy` | 0.56 | add `nish-reserved`; remove `critical-path` |
| [0509#2992](https://github.com/Nishfleet/0509/issues/2992) | open | `authority_nish_reserved` | `agent-in-progress` | 0.23 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#6602](https://github.com/Nishfleet/fleet-ops/issues/6602) | closed | `money_pricing` | `agent-in-progress` | 0.40 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#7389](https://github.com/Nishfleet/fleet-ops/issues/7389) | open | `security` | `agent-in-progress`, `priority` | 0.40 | add `nish-reserved`; remove `agent-in-progress`, `priority` |
| [fleet-ops#7766](https://github.com/Nishfleet/fleet-ops/issues/7766) | open | `authority_nish_reserved` | `agent-ready`, `priority` | 0.24 | add `nish-reserved`; remove `agent-ready`, `priority` |
| [fleet-ops#4233](https://github.com/Nishfleet/fleet-ops/issues/4233) | open | `money_pricing` | `agent-in-progress` | 0.24 | add `nish-reserved`; remove `agent-in-progress` |
| [0509#3172](https://github.com/Nishfleet/0509/issues/3172) | open | `product_direction` | `enhancement`, `scout-candidate`, `superseded-by-rebuild` | 0.24 | add `nish-reserved` |
| [0509#3537](https://github.com/Nishfleet/0509/issues/3537) | open | `security` | `agent-in-progress` | 0.41 | add `nish-reserved`; remove `agent-in-progress` |
| [0509#3542](https://github.com/Nishfleet/0509/issues/3542) | open | `security` | `agent-in-progress` | 0.42 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#8041](https://github.com/Nishfleet/fleet-ops/issues/8041) | open | `security` | `agent-ready` | 0.62 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#4286](https://github.com/Nishfleet/fleet-ops/issues/4286) | open | `security` | `agent-in-progress` | 0.40 | add `nish-reserved`; remove `agent-in-progress` |
| [0509#3540](https://github.com/Nishfleet/0509/issues/3540) | open | `security` | `agent-blocked`, `needs-orchestrator` | 0.41 | add `nish-reserved` |
| [0509#3541](https://github.com/Nishfleet/0509/issues/3541) | open | `security` | `agent-in-progress` | 0.37 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#6570](https://github.com/Nishfleet/fleet-ops/issues/6570) | closed | `authority_nish_reserved` | `gap-audit` | 0.29 | add `nish-reserved` |
| [fleet-ops#4161](https://github.com/Nishfleet/fleet-ops/issues/4161) | closed | `destructive_irreversible` | `agent-in-progress`, `nish-reserved` | 0.25 | re-check labels against the text class |
| [0509#3534](https://github.com/Nishfleet/0509/issues/3534) | closed | `privacy` | `agent-blocked`, `needs-orchestrator` | 0.35 | add `nish-reserved` |
| [fleet-ops#7760](https://github.com/Nishfleet/fleet-ops/issues/7760) | open | `destructive_irreversible` | `agent-blocked`, `needs-nish-decision` | 0.26 | re-check labels against the text class |
| [0509#2284](https://github.com/Nishfleet/0509/issues/2284) | open | `product_direction` | `question`, `agent-in-progress` | 0.34 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#7504](https://github.com/Nishfleet/fleet-ops/issues/7504) | closed | `money_pricing` | `agent-in-progress` | 0.30 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#7369](https://github.com/Nishfleet/fleet-ops/issues/7369) | closed | `security` | `agent-in-progress` | 0.56 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#7584](https://github.com/Nishfleet/fleet-ops/issues/7584) | closed | `destructive_irreversible` | `gap-audit` | 0.49 | add `nish-reserved` |
| [0509#2742](https://github.com/Nishfleet/0509/issues/2742) | closed | `destructive_irreversible` | `agent-in-progress`, `scout-candidate` | 0.26 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#7371](https://github.com/Nishfleet/fleet-ops/issues/7371) | closed | `security` | `agent-in-progress`, `critical-path`, `priority` | 0.49 | add `nish-reserved`; remove `agent-in-progress`, `critical-path`, `priority` |
| [fleet-ops#7519](https://github.com/Nishfleet/fleet-ops/issues/7519) | open | `security` | `agent-blocked`, `nish-reserved`, `needs-nish-decision` | 0.27 | re-check labels against the text class |
| [fleet-ops#7482](https://github.com/Nishfleet/fleet-ops/issues/7482) | open | `authority_nish_reserved` | `agent-in-progress`, `critical-path`, `priority` | 0.44 | add `nish-reserved`; remove `agent-in-progress`, `critical-path`, `priority` |
| [0509#3880](https://github.com/Nishfleet/0509/issues/3880) | open | `privacy` | `critical-path`, `deputy` | 0.27 | add `nish-reserved`; remove `critical-path` |
| [fleet-ops#8035](https://github.com/Nishfleet/fleet-ops/issues/8035) | closed | `authority_nish_reserved` | `agent-ready` | 0.36 | add `nish-reserved`; remove `agent-ready` |
| [0509#3789](https://github.com/Nishfleet/0509/issues/3789) | closed | `authority_nish_reserved` | `agent-in-progress`, `critical-path` | 0.50 | add `nish-reserved`; remove `agent-in-progress`, `critical-path` |
| [fleet-ops#2117](https://github.com/Nishfleet/fleet-ops/issues/2117) | closed | `money_pricing` | `agent-in-progress` | 0.40 | add `nish-reserved`; remove `agent-in-progress` |
| [0509#2734](https://github.com/Nishfleet/0509/issues/2734) | closed | `product_direction` | `agent-in-progress`, `discarded` | 0.30 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#8052](https://github.com/Nishfleet/fleet-ops/issues/8052) | open | `destructive_irreversible` | `agent-blocked`, `needs-orchestrator` | 0.73 | add `nish-reserved` |
| [fleet-ops#7464](https://github.com/Nishfleet/fleet-ops/issues/7464) | open | `product_direction` | `agent-blocked`, `critical-path`, `priority`, `needs-orchestrator` | 0.28 | add `nish-reserved`; remove `critical-path`, `priority` |
| [fleet-ops#3124](https://github.com/Nishfleet/fleet-ops/issues/3124) | open | `authority_nish_reserved` | `agent-in-progress`, `critical-path`, `umbrella` | 0.28 | add `nish-reserved`; remove `agent-in-progress`, `critical-path` |
| [0509#3538](https://github.com/Nishfleet/0509/issues/3538) | open | `security` | `agent-blocked`, `needs-orchestrator` | 0.40 | add `nish-reserved` |
| [0509#3884](https://github.com/Nishfleet/0509/issues/3884) | open | `product_direction` | `agent-blocked`, `critical-path`, `needs-orchestrator` | 0.62 | add `nish-reserved`; remove `critical-path` |
| [0509#3539](https://github.com/Nishfleet/0509/issues/3539) | open | `security` | `agent-in-progress` | 0.42 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#7100](https://github.com/Nishfleet/fleet-ops/issues/7100) | closed | `authority_nish_reserved` | `agent-ready` | 0.28 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#4278](https://github.com/Nishfleet/fleet-ops/issues/4278) | closed | `destructive_irreversible` | `agent-in-progress` | 0.36 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#7499](https://github.com/Nishfleet/fleet-ops/issues/7499) | closed | `money_pricing` | _(none)_ | 0.28 | add `nish-reserved` |
| [fleet-ops#8037](https://github.com/Nishfleet/fleet-ops/issues/8037) | open | `product_direction` | `agent-ready`, `needs-orchestrator` | 0.29 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#7731](https://github.com/Nishfleet/fleet-ops/issues/7731) | open | `security` | `agent-in-progress`, `escalate-senior`, `critical-path` | 0.64 | add `nish-reserved`; remove `agent-in-progress`, `critical-path` |
| [0509#1988](https://github.com/Nishfleet/0509/issues/1988) | open | `product_direction` | `superseded-by-rebuild` | 0.58 | add `nish-reserved` |
| [0509#3578](https://github.com/Nishfleet/0509/issues/3578) | open | `money_pricing` | `discarded`, `superseded-by-rebuild` | 0.44 | add `nish-reserved` |
| [fleet-ops#8034](https://github.com/Nishfleet/fleet-ops/issues/8034) | closed | `security` | `needs-orchestrator` | 0.29 | add `nish-reserved` |
| [0509#3777](https://github.com/Nishfleet/0509/issues/3777) | closed | `destructive_irreversible` | `agent-in-progress`, `critical-path` | 0.60 | add `nish-reserved`; remove `agent-in-progress`, `critical-path` |
| [fleet-ops#7440](https://github.com/Nishfleet/fleet-ops/issues/7440) | closed | `authority_nish_reserved` | `agent-in-progress`, `priority` | 0.29 | add `nish-reserved`; remove `agent-in-progress`, `priority` |
| [fleet-ops#7437](https://github.com/Nishfleet/fleet-ops/issues/7437) | open | `auto_fixable` | `agent-blocked`, `priority`, `nish-reserved`, `deploy-fault` | 0.30 | remove `nish-reserved`/`needs-nish-decision`; add `agent-ready` |
| [fleet-ops#4291](https://github.com/Nishfleet/fleet-ops/issues/4291) | open | `authority_nish_reserved` | `agent-in-progress` | 0.47 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#7460](https://github.com/Nishfleet/fleet-ops/issues/7460) | open | `destructive_irreversible` | `agent-in-progress`, `priority` | 0.80 | add `nish-reserved`; remove `agent-in-progress`, `priority` |
| [0509#2217](https://github.com/Nishfleet/0509/issues/2217) | open | `destructive_irreversible` | `agent-blocked` | 0.64 | add `nish-reserved` |
| [fleet-ops#7405](https://github.com/Nishfleet/fleet-ops/issues/7405) | closed | `money_pricing` | `agent-in-progress`, `priority` | 0.53 | add `nish-reserved`; remove `agent-in-progress`, `priority` |
| [fleet-ops#6616](https://github.com/Nishfleet/fleet-ops/issues/6616) | closed | `destructive_irreversible` | `agent-in-progress` | 0.54 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#8057](https://github.com/Nishfleet/fleet-ops/issues/8057) | open | `security` | `agent-ready` | 0.65 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#6292](https://github.com/Nishfleet/fleet-ops/issues/6292) | closed | `destructive_irreversible` | `agent-ready`, `priority` | 0.70 | add `nish-reserved`; remove `agent-ready`, `priority` |
| [0509#2296](https://github.com/Nishfleet/0509/issues/2296) | open | `authority_nish_reserved` | `agent-in-progress` | 0.31 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#7753](https://github.com/Nishfleet/fleet-ops/issues/7753) | open | `auto_fixable` | `agent-blocked`, `needs-nish-decision` | 0.45 | remove `nish-reserved`/`needs-nish-decision`; add `agent-ready` |
| [fleet-ops#8011](https://github.com/Nishfleet/fleet-ops/issues/8011) | open | `authority_nish_reserved` | `agent-ready` | 0.61 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#6829](https://github.com/Nishfleet/fleet-ops/issues/6829) | open | `authority_nish_reserved` | `agent-in-progress`, `agent-blocked`, `scout-candidate`, `research-delta` | 0.33 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#7893](https://github.com/Nishfleet/fleet-ops/issues/7893) | open | `destructive_irreversible` | `agent-ready` | 0.82 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#7443](https://github.com/Nishfleet/fleet-ops/issues/7443) | open | `money_pricing` | `agent-blocked`, `critical-path`, `priority` | 0.41 | add `nish-reserved`; remove `critical-path`, `priority` |
| [0509#3579](https://github.com/Nishfleet/0509/issues/3579) | open | `money_pricing` | `agent-blocked`, `scout-candidate`, `needs-orchestrator` | 0.63 | add `nish-reserved` |
| [0509#3624](https://github.com/Nishfleet/0509/issues/3624) | closed | `destructive_irreversible` | _(none)_ | 0.58 | add `nish-reserved` |
| [fleet-ops#7973](https://github.com/Nishfleet/fleet-ops/issues/7973) | open | `authority_nish_reserved` | `agent-ready` | 0.32 | add `nish-reserved`; remove `agent-ready` |
| [0509#3845](https://github.com/Nishfleet/0509/issues/3845) | closed | `authority_nish_reserved` | `critical-path` | 0.32 | add `nish-reserved`; remove `critical-path` |
| [fleet-ops#3128](https://github.com/Nishfleet/fleet-ops/issues/3128) | closed | `destructive_irreversible` | `agent-blocked`, `critical-path`, `umbrella`, `needs-orchestrator` | 0.32 | add `nish-reserved`; remove `critical-path` |
| [fleet-ops#7911](https://github.com/Nishfleet/fleet-ops/issues/7911) | open | `security` | `agent-ready` | 0.50 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#5414](https://github.com/Nishfleet/fleet-ops/issues/5414) | open | `authority_nish_reserved` | `agent-in-progress` | 0.43 | add `nish-reserved`; remove `agent-in-progress` |
| [0509#3885](https://github.com/Nishfleet/0509/issues/3885) | open | `product_direction` | `agent-blocked`, `critical-path`, `needs-orchestrator` | 0.55 | add `nish-reserved`; remove `critical-path` |
| [0509#3786](https://github.com/Nishfleet/0509/issues/3786) | open | `security` | `critical-path`, `superseded-by-rebuild` | 0.47 | add `nish-reserved`; remove `critical-path` |
| [0509#3814](https://github.com/Nishfleet/0509/issues/3814) | open | `product_direction` | `scout-candidate`, `usage-uncited`, `superseded-by-rebuild` | 0.54 | add `nish-reserved` |
| [fleet-ops#7442](https://github.com/Nishfleet/fleet-ops/issues/7442) | closed | `product_direction` | `agent-ready`, `priority` | 0.45 | add `nish-reserved`; remove `agent-ready`, `priority` |
| [0509#3846](https://github.com/Nishfleet/0509/issues/3846) | closed | `product_direction` | `critical-path` | 0.50 | add `nish-reserved`; remove `critical-path` |
| [fleet-ops#6799](https://github.com/Nishfleet/fleet-ops/issues/6799) | closed | `destructive_irreversible` | `agent-blocked`, `needs-orchestrator` | 0.53 | add `nish-reserved` |
| [0509#2000](https://github.com/Nishfleet/0509/issues/2000) | closed | `security` | `agent-in-progress`, `discarded`, `deploy-fault` | 0.42 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#7998](https://github.com/Nishfleet/fleet-ops/issues/7998) | open | `authority_nish_reserved` | `agent-ready` | 0.33 | add `nish-reserved`; remove `agent-ready` |
| [0509#3891](https://github.com/Nishfleet/0509/issues/3891) | open | `money_pricing` | `agent-blocked`, `critical-path`, `needs-orchestrator` | 0.33 | add `nish-reserved`; remove `critical-path` |
| [0509#2919](https://github.com/Nishfleet/0509/issues/2919) | open | `customer_data_deletion` | `discarded`, `superseded-by-rebuild` | 0.33 | add `nish-reserved` |
| [fleet-ops#8054](https://github.com/Nishfleet/fleet-ops/issues/8054) | open | `destructive_irreversible` | `agent-blocked`, `needs-orchestrator` | 0.56 | add `nish-reserved` |
| [fleet-ops#6903](https://github.com/Nishfleet/fleet-ops/issues/6903) | open | `product_direction` | `agent-blocked`, `needs-orchestrator` | 0.48 | add `nish-reserved` |
| [fleet-ops#7393](https://github.com/Nishfleet/fleet-ops/issues/7393) | closed | `security` | `agent-in-progress`, `priority` | 0.38 | add `nish-reserved`; remove `agent-in-progress`, `priority` |
| [fleet-ops#7458](https://github.com/Nishfleet/fleet-ops/issues/7458) | open | `auto_fixable` | `agent-blocked`, `priority`, `nish-reserved` | 0.34 | remove `nish-reserved`/`needs-nish-decision`; add `agent-ready` |
| [fleet-ops#7391](https://github.com/Nishfleet/fleet-ops/issues/7391) | open | `security` | `agent-blocked`, `priority`, `needs-orchestrator` | 0.45 | add `nish-reserved`; remove `priority` |
| [fleet-ops#8134](https://github.com/Nishfleet/fleet-ops/issues/8134) | open | `security` | `agent-ready` | 0.65 | add `nish-reserved`; remove `agent-ready` |
| [0509#3569](https://github.com/Nishfleet/0509/issues/3569) | open | `brand` | `agent-blocked` | 0.70 | add `nish-reserved` |
| [0509#3535](https://github.com/Nishfleet/0509/issues/3535) | open | `security` | `agent-in-progress`, `deploy-fault` | 0.35 | add `nish-reserved`; remove `agent-in-progress` |
| [0509#3389](https://github.com/Nishfleet/0509/issues/3389) | open | `auto_fixable` | `agent-blocked`, `needs-orchestrator`, `nish-reserved` | 0.35 | remove `nish-reserved`/`needs-nish-decision`; add `agent-ready` |
| [0509#3681](https://github.com/Nishfleet/0509/issues/3681) | closed | `destructive_irreversible` | `agent-ready` | 0.67 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#3127](https://github.com/Nishfleet/fleet-ops/issues/3127) | open | `authority_nish_reserved` | `agent-in-progress`, `critical-path`, `umbrella` | 0.46 | add `nish-reserved`; remove `agent-in-progress`, `critical-path` |
| [0509#3772](https://github.com/Nishfleet/0509/issues/3772) | open | `product_direction` | `needs-nish-decision`, `superseded-by-rebuild` | 0.36 | re-check labels against the text class |
| [fleet-ops#7582](https://github.com/Nishfleet/fleet-ops/issues/7582) | closed | `authority_nish_reserved` | `agent-in-progress` | 0.47 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#6072](https://github.com/Nishfleet/fleet-ops/issues/6072) | open | `auto_fixable` | `agent-in-progress`, `nish-reserved`, `needs-orchestrator` | 0.37 | remove `nish-reserved`/`needs-nish-decision`; keep `agent-in-progress` |
| [0509#3801](https://github.com/Nishfleet/0509/issues/3801) | open | `authority_nish_reserved` | `bug`, `agent-blocked`, `superseded-by-rebuild` | 0.37 | add `nish-reserved` |
| [0509#3531](https://github.com/Nishfleet/0509/issues/3531) | open | `security` | `agent-in-progress` | 0.44 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#7904](https://github.com/Nishfleet/fleet-ops/issues/7904) | open | `destructive_irreversible` | `agent-ready` | 0.82 | add `nish-reserved`; remove `agent-ready` |
| [0509#3346](https://github.com/Nishfleet/0509/issues/3346) | open | `product_direction` | `scout-candidate`, `research-delta`, `superseded-by-rebuild` | 0.64 | add `nish-reserved` |
| [0509#3379](https://github.com/Nishfleet/0509/issues/3379) | closed | `security` | `agent-ready`, `scout-candidate` | 0.67 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#8056](https://github.com/Nishfleet/fleet-ops/issues/8056) | open | `security` | `agent-blocked`, `needs-orchestrator` | 0.53 | add `nish-reserved` |
| [fleet-ops#8144](https://github.com/Nishfleet/fleet-ops/issues/8144) | open | `security` | `agent-ready` | 0.77 | add `nish-reserved`; remove `agent-ready` |
| [0509#3927](https://github.com/Nishfleet/0509/issues/3927) | open | `authority_nish_reserved` | `agent-blocked`, `needs-orchestrator` | 0.42 | add `nish-reserved` |
| [0509#3238](https://github.com/Nishfleet/0509/issues/3238) | open | `security` | `scout-candidate`, `superseded-by-rebuild` | 0.39 | add `nish-reserved` |
| [0509#3640](https://github.com/Nishfleet/0509/issues/3640) | open | `brand` | `scout-candidate`, `superseded-by-rebuild` | 0.78 | add `nish-reserved` |
| [0509#3764](https://github.com/Nishfleet/0509/issues/3764) | open | `brand` | `superseded-by-rebuild` | 0.39 | add `nish-reserved` |
| [fleet-ops#5787](https://github.com/Nishfleet/fleet-ops/issues/5787) | closed | `auto_fixable` | `agent-in-progress`, `nish-reserved`, `needs-orchestrator` | 0.39 | remove `nish-reserved`/`needs-nish-decision`; keep `agent-in-progress` |
| [fleet-ops#7914](https://github.com/Nishfleet/fleet-ops/issues/7914) | open | `destructive_irreversible` | `agent-ready` | 0.77 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#7420](https://github.com/Nishfleet/fleet-ops/issues/7420) | open | `money_pricing` | `agent-blocked`, `priority`, `nish-reserved` | 0.40 | re-check labels against the text class |
| [0509#3926](https://github.com/Nishfleet/0509/issues/3926) | open | `money_pricing` | `agent-in-progress` | 0.43 | add `nish-reserved`; remove `agent-in-progress` |
| [0509#3788](https://github.com/Nishfleet/0509/issues/3788) | open | `security` | `critical-path`, `superseded-by-rebuild` | 0.46 | add `nish-reserved`; remove `critical-path` |
| [0509#3079](https://github.com/Nishfleet/0509/issues/3079) | open | `product_direction` | `scout-candidate`, `superseded-by-rebuild` | 0.40 | add `nish-reserved` |
| [0509#3651](https://github.com/Nishfleet/0509/issues/3651) | open | `brand` | `scout-candidate`, `superseded-by-rebuild` | 0.55 | add `nish-reserved` |
| [0509#3603](https://github.com/Nishfleet/0509/issues/3603) | closed | `brand` | `agent-in-progress` | 0.66 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#7671](https://github.com/Nishfleet/fleet-ops/issues/7671) | closed | `security` | _(none)_ | 0.40 | add `nish-reserved` |
| [0509#3185](https://github.com/Nishfleet/0509/issues/3185) | open | `security` | `agent-in-progress` | 0.41 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#7768](https://github.com/Nishfleet/fleet-ops/issues/7768) | closed | `authority_nish_reserved` | _(none)_ | 0.41 | add `nish-reserved` |
| [fleet-ops#8046](https://github.com/Nishfleet/fleet-ops/issues/8046) | open | `destructive_irreversible` | `agent-ready` | 0.56 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#7439](https://github.com/Nishfleet/fleet-ops/issues/7439) | closed | `authority_nish_reserved` | `agent-ready`, `priority` | 0.56 | add `nish-reserved`; remove `agent-ready`, `priority` |
| [fleet-ops#6889](https://github.com/Nishfleet/fleet-ops/issues/6889) | closed | `product_direction` | `agent-in-progress` | 0.55 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#6003](https://github.com/Nishfleet/fleet-ops/issues/6003) | closed | `authority_nish_reserved` | `agent-ready` | 0.48 | add `nish-reserved`; remove `agent-ready` |
| [0509#3784](https://github.com/Nishfleet/0509/issues/3784) | open | `authority_nish_reserved` | `critical-path`, `superseded-by-rebuild` | 0.42 | add `nish-reserved`; remove `critical-path` |
| [0509#3794](https://github.com/Nishfleet/0509/issues/3794) | open | `authority_nish_reserved` | `superseded-by-rebuild` | 0.42 | add `nish-reserved` |
| [fleet-ops#7390](https://github.com/Nishfleet/fleet-ops/issues/7390) | open | `security` | `agent-blocked`, `priority` | 0.43 | add `nish-reserved`; remove `priority` |
| [0509#3267](https://github.com/Nishfleet/0509/issues/3267) | open | `authority_nish_reserved` | `agent-in-progress` | 0.66 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#4926](https://github.com/Nishfleet/fleet-ops/issues/4926) | open | `authority_nish_reserved` | `agent-ready`, `needs-orchestrator`, `awaiting-runtime-gate` | 0.43 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#7541](https://github.com/Nishfleet/fleet-ops/issues/7541) | open | `money_pricing` | `agent-in-progress`, `agent-blocked`, `nish-reserved`, `needs-nish-decision` | 0.43 | re-check labels against the text class |
| [fleet-ops#7771](https://github.com/Nishfleet/fleet-ops/issues/7771) | open | `destructive_irreversible` | `agent-in-progress`, `critical-path`, `priority`, `nish-reserved` | 0.43 | re-check labels against the text class |
| [0509#3367](https://github.com/Nishfleet/0509/issues/3367) | open | `privacy` | `agent-in-progress`, `scout-candidate` | 0.62 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#7518](https://github.com/Nishfleet/fleet-ops/issues/7518) | closed | `authority_nish_reserved` | `agent-blocked`, `nish-reserved` | 0.43 | re-check labels against the text class |
| [0509#2312](https://github.com/Nishfleet/0509/issues/2312) | open | `brand` | `agent-blocked` | 0.79 | add `nish-reserved` |
| [fleet-ops#5099](https://github.com/Nishfleet/fleet-ops/issues/5099) | closed | `security` | `agent-in-progress` | 0.50 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#8173](https://github.com/Nishfleet/fleet-ops/issues/8173) | open | `security` | `agent-ready` | 0.64 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#7803](https://github.com/Nishfleet/fleet-ops/issues/7803) | open | `authority_nish_reserved` | `agent-ready` | 0.64 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#7428](https://github.com/Nishfleet/fleet-ops/issues/7428) | open | `security` | `agent-blocked`, `priority`, `nish-reserved` | 0.44 | re-check labels against the text class |
| [fleet-ops#6101](https://github.com/Nishfleet/fleet-ops/issues/6101) | open | `destructive_irreversible` | `agent-blocked`, `priority` | 0.44 | add `nish-reserved`; remove `priority` |
| [0509#2988](https://github.com/Nishfleet/0509/issues/2988) | open | `authority_nish_reserved` | `scout-candidate`, `needs-orchestrator`, `awaiting-runtime-gate` | 0.52 | add `nish-reserved` |
| [fleet-ops#8042](https://github.com/Nishfleet/fleet-ops/issues/8042) | closed | `destructive_irreversible` | `agent-ready` | 0.67 | add `nish-reserved`; remove `agent-ready` |
| [0509#3776](https://github.com/Nishfleet/0509/issues/3776) | closed | `destructive_irreversible` | `agent-in-progress`, `critical-path` | 0.77 | add `nish-reserved`; remove `agent-in-progress`, `critical-path` |
| [fleet-ops#7739](https://github.com/Nishfleet/fleet-ops/issues/7739) | open | `auto_fixable` | `agent-ready`, `triage-mass-close`, `needs-nish-decision` | 0.45 | remove `nish-reserved`/`needs-nish-decision`; keep `agent-ready` |
| [fleet-ops#7716](https://github.com/Nishfleet/fleet-ops/issues/7716) | open | `destructive_irreversible` | `auto-revert-halt`, `agent-ready`, `noise-class` | 0.45 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#7446](https://github.com/Nishfleet/fleet-ops/issues/7446) | open | `security` | `agent-in-progress`, `critical-path`, `priority` | 0.56 | add `nish-reserved`; remove `agent-in-progress`, `critical-path`, `priority` |
| [fleet-ops#5123](https://github.com/Nishfleet/fleet-ops/issues/5123) | open | `destructive_irreversible` | `agent-in-progress`, `scout-candidate`, `research-delta` | 0.53 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#4218](https://github.com/Nishfleet/fleet-ops/issues/4218) | open | `authority_nish_reserved` | `agent-in-progress` | 0.52 | add `nish-reserved`; remove `agent-in-progress` |
| [0509#3679](https://github.com/Nishfleet/0509/issues/3679) | open | `authority_nish_reserved` | `superseded-by-rebuild` | 0.45 | add `nish-reserved` |
| [0509#3552](https://github.com/Nishfleet/0509/issues/3552) | open | `money_pricing` | `agent-in-progress` | 0.49 | add `nish-reserved`; remove `agent-in-progress` |
| [0509#3553](https://github.com/Nishfleet/0509/issues/3553) | open | `money_pricing` | `agent-in-progress` | 0.45 | add `nish-reserved`; remove `agent-in-progress` |
| [0509#3560](https://github.com/Nishfleet/0509/issues/3560) | open | `money_pricing` | `agent-in-progress` | 0.45 | add `nish-reserved`; remove `agent-in-progress` |
| [0509#3562](https://github.com/Nishfleet/0509/issues/3562) | open | `money_pricing` | `agent-in-progress` | 0.45 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#6153](https://github.com/Nishfleet/fleet-ops/issues/6153) | closed | `security` | `agent-in-progress`, `scout-candidate`, `research-delta` | 0.85 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#7774](https://github.com/Nishfleet/fleet-ops/issues/7774) | open | `auto_fixable` | `agent-ready`, `priority` | 0.46 | re-check labels against the text class |
| [0509#3338](https://github.com/Nishfleet/0509/issues/3338) | open | `privacy` | `scout-candidate`, `research-delta`, `superseded-by-rebuild` | 0.60 | add `nish-reserved` |
| [0509#3635](https://github.com/Nishfleet/0509/issues/3635) | open | `privacy` | `scout-candidate`, `superseded-by-rebuild` | 0.59 | add `nish-reserved` |
| [0509#3616](https://github.com/Nishfleet/0509/issues/3616) | open | `authority_nish_reserved` | `agent-in-progress` | 0.52 | add `nish-reserved`; remove `agent-in-progress` |
| [0509#3787](https://github.com/Nishfleet/0509/issues/3787) | closed | `authority_nish_reserved` | `agent-ready`, `critical-path` | 0.50 | add `nish-reserved`; remove `agent-ready`, `critical-path` |
| [fleet-ops#7438](https://github.com/Nishfleet/fleet-ops/issues/7438) | closed | `authority_nish_reserved` | `agent-in-progress`, `priority` | 0.47 | add `nish-reserved`; remove `agent-in-progress`, `priority` |
| [fleet-ops#3658](https://github.com/Nishfleet/fleet-ops/issues/3658) | open | `security` | `agent-in-progress`, `discarded` | 0.57 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#6359](https://github.com/Nishfleet/fleet-ops/issues/6359) | open | `auto_fixable` | `agent-blocked`, `nish-reserved` | 0.54 | remove `nish-reserved`/`needs-nish-decision`; add `agent-ready` |
| [0509#2868](https://github.com/Nishfleet/0509/issues/2868) | open | `auto_fixable` | `needs-orchestrator`, `superseded-by-rebuild` | 0.47 | re-check labels against the text class |
| [0509#3815](https://github.com/Nishfleet/0509/issues/3815) | open | `money_pricing` | `scout-candidate`, `usage-uncited`, `superseded-by-rebuild` | 0.66 | add `nish-reserved` |
| [0509#3547](https://github.com/Nishfleet/0509/issues/3547) | open | `product_direction` | `agent-in-progress` | 0.47 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#7583](https://github.com/Nishfleet/fleet-ops/issues/7583) | closed | `destructive_irreversible` | `gap-audit` | 0.48 | add `nish-reserved` |
| [fleet-ops#7496](https://github.com/Nishfleet/fleet-ops/issues/7496) | open | `money_pricing` | `agent-blocked`, `nish-reserved`, `needs-nish-decision` | 0.48 | re-check labels against the text class |
| [fleet-ops#7791](https://github.com/Nishfleet/fleet-ops/issues/7791) | open | `destructive_irreversible` | `agent-ready` | 0.52 | add `nish-reserved`; remove `agent-ready` |
| [0509#3905](https://github.com/Nishfleet/0509/issues/3905) | open | `product_direction` | `agent-blocked`, `critical-path`, `needs-orchestrator` | 0.48 | add `nish-reserved`; remove `critical-path` |
| [fleet-ops#7233](https://github.com/Nishfleet/fleet-ops/issues/7233) | closed | `security` | `agent-ready`, `gap-audit` | 0.48 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#6887](https://github.com/Nishfleet/fleet-ops/issues/6887) | open | `product_direction` | `agent-blocked` | 0.49 | add `nish-reserved` |
| [fleet-ops#7920](https://github.com/Nishfleet/fleet-ops/issues/7920) | open | `auto_fixable` | `agent-ready` | 0.49 | re-check labels against the text class |
| [fleet-ops#7387](https://github.com/Nishfleet/fleet-ops/issues/7387) | open | `security` | `agent-blocked`, `priority`, `nish-reserved` | 0.49 | re-check labels against the text class |
| [fleet-ops#3488](https://github.com/Nishfleet/fleet-ops/issues/3488) | open | `auto_fixable` | `agent-in-progress` | 0.49 | re-check labels against the text class |
| [0509#3323](https://github.com/Nishfleet/0509/issues/3323) | open | `brand` | `scout-candidate`, `research-delta`, `superseded-by-rebuild` | 0.67 | add `nish-reserved` |
| [0509#3301](https://github.com/Nishfleet/0509/issues/3301) | open | `security` | `agent-blocked`, `needs-orchestrator` | 0.63 | add `nish-reserved` |
| [0509#3559](https://github.com/Nishfleet/0509/issues/3559) | open | `money_pricing` | `agent-blocked` | 0.49 | add `nish-reserved` |
| [fleet-ops#7734](https://github.com/Nishfleet/fleet-ops/issues/7734) | closed | `destructive_irreversible` | `agent-in-progress` | 0.70 | add `nish-reserved`; remove `agent-in-progress` |
| [0509#3532](https://github.com/Nishfleet/0509/issues/3532) | closed | `authority_nish_reserved` | `agent-blocked` | 0.57 | add `nish-reserved` |
| [fleet-ops#7867](https://github.com/Nishfleet/fleet-ops/issues/7867) | open | `destructive_irreversible` | `agent-ready` | 0.79 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#5118](https://github.com/Nishfleet/fleet-ops/issues/5118) | open | `product_direction` | `agent-in-progress`, `scout-candidate`, `research-delta` | 0.50 | add `nish-reserved`; remove `agent-in-progress` |
| [0509#3556](https://github.com/Nishfleet/0509/issues/3556) | open | `brand` | `agent-blocked` | 0.50 | add `nish-reserved` |
| [fleet-ops#8116](https://github.com/Nishfleet/fleet-ops/issues/8116) | open | `product_direction` | `agent-ready` | 0.73 | add `nish-reserved`; remove `agent-ready` |
| [fleet-ops#7465](https://github.com/Nishfleet/fleet-ops/issues/7465) | open | `authority_nish_reserved` | `agent-blocked`, `priority` | 0.70 | add `nish-reserved`; remove `priority` |
| [fleet-ops#7415](https://github.com/Nishfleet/fleet-ops/issues/7415) | open | `money_pricing` | `agent-blocked`, `priority` | 0.71 | add `nish-reserved`; remove `priority` |
| [0509#3557](https://github.com/Nishfleet/0509/issues/3557) | open | `product_direction` | `agent-in-progress` | 0.51 | add `nish-reserved`; remove `agent-in-progress` |
| [0509#3558](https://github.com/Nishfleet/0509/issues/3558) | open | `product_direction` | `agent-in-progress` | 0.51 | add `nish-reserved`; remove `agent-in-progress` |
| [0509#3561](https://github.com/Nishfleet/0509/issues/3561) | open | `money_pricing` | `agent-in-progress` | 0.51 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#7403](https://github.com/Nishfleet/fleet-ops/issues/7403) | closed | `money_pricing` | `agent-in-progress`, `priority` | 0.51 | add `nish-reserved`; remove `agent-in-progress`, `priority` |
| [0509#2691](https://github.com/Nishfleet/0509/issues/2691) | closed | `destructive_irreversible` | `agent-in-progress`, `scout-candidate` | 0.65 | add `nish-reserved`; remove `agent-in-progress` |
| [0509#3430](https://github.com/Nishfleet/0509/issues/3430) | closed | `product_direction` | `agent-in-progress`, `scout-candidate` | 0.65 | add `nish-reserved`; remove `agent-in-progress` |
| [0509#3364](https://github.com/Nishfleet/0509/issues/3364) | closed | `destructive_irreversible` | `agent-in-progress`, `scout-candidate`, `deploy-fault` | 0.63 | add `nish-reserved`; remove `agent-in-progress` |
| [0509#3555](https://github.com/Nishfleet/0509/issues/3555) | open | `money_pricing` | `agent-in-progress` | 0.52 | add `nish-reserved`; remove `agent-in-progress` |
| [0509#3563](https://github.com/Nishfleet/0509/issues/3563) | open | `money_pricing` | `agent-in-progress` | 0.52 | add `nish-reserved`; remove `agent-in-progress` |
| [0509#3447](https://github.com/Nishfleet/0509/issues/3447) | open | `destructive_irreversible` | `agent-in-progress`, `scout-candidate` | 0.52 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#7399](https://github.com/Nishfleet/fleet-ops/issues/7399) | closed | `money_pricing` | `agent-in-progress`, `priority` | 0.52 | add `nish-reserved`; remove `agent-in-progress`, `priority` |
| [0509#3875](https://github.com/Nishfleet/0509/issues/3875) | closed | `authority_nish_reserved` | `agent-in-progress` | 0.52 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#8161](https://github.com/Nishfleet/fleet-ops/issues/8161) | open | `product_direction` | `agent-ready` | 0.67 | add `nish-reserved`; remove `agent-ready` |
| [0509#3533](https://github.com/Nishfleet/0509/issues/3533) | closed | `authority_nish_reserved` | `agent-blocked`, `needs-orchestrator` | 0.62 | add `nish-reserved` |
| [fleet-ops#7503](https://github.com/Nishfleet/fleet-ops/issues/7503) | closed | `authority_nish_reserved` | _(none)_ | 0.53 | add `nish-reserved` |
| [fleet-ops#7772](https://github.com/Nishfleet/fleet-ops/issues/7772) | open | `authority_nish_reserved` | `agent-ready`, `priority` | 0.53 | add `nish-reserved`; remove `agent-ready`, `priority` |
| [0509#3549](https://github.com/Nishfleet/0509/issues/3549) | open | `authority_nish_reserved` | `agent-in-progress` | 0.67 | add `nish-reserved`; remove `agent-in-progress` |
| [0509#3551](https://github.com/Nishfleet/0509/issues/3551) | open | `product_direction` | `agent-in-progress` | 0.53 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#6476](https://github.com/Nishfleet/fleet-ops/issues/6476) | closed | `security` | `agent-blocked`, `scout-candidate`, `research-delta` | 0.55 | add `nish-reserved` |
| [0509#3878](https://github.com/Nishfleet/0509/issues/3878) | closed | `authority_nish_reserved` | `critical-path`, `deputy` | 0.61 | add `nish-reserved`; remove `critical-path` |
| [fleet-ops#4791](https://github.com/Nishfleet/fleet-ops/issues/4791) | open | `authority_nish_reserved` | `agent-blocked`, `needs-orchestrator` | 0.54 | add `nish-reserved` |
| [fleet-ops#7693](https://github.com/Nishfleet/fleet-ops/issues/7693) | closed | `security` | _(none)_ | 0.61 | add `nish-reserved` |
| [fleet-ops#7414](https://github.com/Nishfleet/fleet-ops/issues/7414) | open | `product_direction` | `agent-in-progress`, `priority` | 0.55 | add `nish-reserved`; remove `agent-in-progress`, `priority` |
| [fleet-ops#7658](https://github.com/Nishfleet/fleet-ops/issues/7658) | closed | `authority_nish_reserved` | _(none)_ | 0.55 | add `nish-reserved` |
| [fleet-ops#7576](https://github.com/Nishfleet/fleet-ops/issues/7576) | closed | `authority_nish_reserved` | _(none)_ | 0.57 | add `nish-reserved` |
| [fleet-ops#7401](https://github.com/Nishfleet/fleet-ops/issues/7401) | closed | `money_pricing` | `agent-in-progress`, `priority` | 0.57 | add `nish-reserved`; remove `agent-in-progress`, `priority` |
| [0509#3803](https://github.com/Nishfleet/0509/issues/3803) | open | `brand` | `scout-candidate`, `superseded-by-rebuild` | 0.70 | add `nish-reserved` |
| [0509#3515](https://github.com/Nishfleet/0509/issues/3515) | open | `product_direction` | `scout-candidate`, `superseded-by-rebuild` | 0.60 | add `nish-reserved` |
| [fleet-ops#5130](https://github.com/Nishfleet/fleet-ops/issues/5130) | closed | `product_direction` | `agent-in-progress`, `discarded`, `research-delta` | 0.61 | add `nish-reserved`; remove `agent-in-progress` |
| [0509#3550](https://github.com/Nishfleet/0509/issues/3550) | open | `money_pricing` | `agent-in-progress` | 0.61 | add `nish-reserved`; remove `agent-in-progress` |
| [fleet-ops#7421](https://github.com/Nishfleet/fleet-ops/issues/7421) | open | `authority_nish_reserved` | `agent-blocked`, `priority` | 0.62 | add `nish-reserved`; remove `priority` |
| [fleet-ops#7459](https://github.com/Nishfleet/fleet-ops/issues/7459) | closed | `authority_nish_reserved` | `agent-in-progress`, `priority` | 0.62 | add `nish-reserved`; remove `agent-in-progress`, `priority` |
| [fleet-ops#7416](https://github.com/Nishfleet/fleet-ops/issues/7416) | open | `authority_nish_reserved` | `agent-in-progress`, `priority` | 0.68 | add `nish-reserved`; remove `agent-in-progress`, `priority` |

loose-ends: the 351 proposed corrections are unapplied by design — they land in a
separate human-reviewed PR; this run changed no label, closed no issue and claimed no work.
The site is registered with fleet-ops#7754 with its outcome definitions so it is scored
like the other shadow sites. `config/jev-bands.json` is deliberately untouched: that table
pins one row per consumer-emitted site, and adding a `label-sanity` row with no consumer
literal would fail `tests/jev-bands.test.py`.
