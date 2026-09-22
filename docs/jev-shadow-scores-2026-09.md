# Jev shadow scores, 2026-09 (fleet-ops#7754)

Read-only join of the shared Jev helper logs at
`~/.local/state/pi-packet/jev/<site>.jsonl` to outcomes that already exist.
No gate, timer, hook, label, or config was changed, and nothing here was
hand-labelled: every outcome comes from GitHub or from a value already
stamped in the log row.

Scored 2026-09-22. The bar is the one the epic's own benchmark set in
`docs/jev-benchmark-2026-09.md`:

- a **flag** decision is GO only when `flag-rate <= 25%` and recall of the
  rare class is at least the rule it shadows;
- a **reserved-class** decision tolerates **0** false `auto_fixable` calls on
  items that truly took the reserved route;
- a **confident bucket** (`p >= 0.9`) is reported on its own, and a
  disagreement rate above 15% against an independent reading is no-go.

## Which logs clear the bar

25 site logs were on disk. The task scores a site at **>= 100 rows**. Two
clear it.

| site | rows | window (UTC) | outcome used |
|---|---:|---|---|
| `label-sanity` | 1245 | 2026-09-22T00:56:07Z – 00:58:34Z | GitHub issue state, labels, timeline, merged closing PR, Nish's own comments |
| `vault-drop-routing` | 499 | 2026-09-22T01:19:13Z – 01:22:35Z | the path-rule placement stamped in the row (`baseline.area`, `baseline.note_type`) |

`label-sanity.jsonl`: 1,484,864 bytes, sha256
`be937f98e684b9a3efc4ce370beacccdc4de31a9b1a64fb75a1c0d42e7dde76b`,
1,245 rows, 0 unparseable. Tokens 3,107,017 in / 166,512 out, median 288 ms.
`vault-drop-routing.jsonl`: 499 rows, sha256
`81ea05ad04981dbbac918f87fa1685dde3bc2ff29ea5b9b9926d3eb76d28c333`
(unchanged since `docs/vault-drop-routing-2026-09.md`).

The other 23 sites are below 100 rows, so they are not scored. Largest:
`claim-check-report` 86, `worker-context` 85, `reviewer-needs-review` 70,
`claim-check-pr` 65, `merge-queue-enqueue` 64, `second-opinion-reserved` 60,
`worker-escalation-target` 52. That is why epic children 5, 6, 7 and 8 stay
**missing evidence** below: `failure-triage` has 3 rows, `hermes-digest` 33,
`fleet-weekly-review-triage` 1, and no findings-ledger site log exists.

## 1. `label-sanity` — the question and the outcome

One call per issue, two questions (`docs/label-sanity-2026-09.md`):

- `reservedClass` (choice of the 9 canonical reserved classes plus
  `auto_fixable`) — which class the issue **text** justifies.
- `labelsMatch` (boolean) — do the applied labels reflect that class.

The site's own registration on this issue defines the outcomes:

- `reservedClass` predicts the **route**. A text-reserved issue is resolved by
  a Nish decision (it carries or carried `nish-reserved` /
  `needs-nish-decision`, or Nish answers it himself) rather than closing on a
  merged agent PR. A text-`auto_fixable` issue closes on a merged linked PR.
- `labelsMatch` predicts a **label correction**: the label set changes after
  the run, or the issue is reclassified reserved.

**Outcome source:** GitHub, read 2026-09-22. For all 1,245 refs
(`Nishfleet/fleet-ops` 844, `Nishfleet/0509` 401; 0 missing): issue state,
current labels, the label/close timeline, and
`closedByPullRequestsReferences`. For the 365 refs where the text or the
applied label was reserved, Nish's comments (`author: nish3451` after the row
timestamp) were also read. 29 of those 365 had one.

**Resolved slice.** 649 of 1,245 issues are still open, so their route is not
yet knowable. The precision/recall tables use the **596 closed** issues
(fleet-ops 502, 0509 94). The full-cohort numbers are in the calibration
section, labelled as such.

Truth, per closed issue:

- **reserved route** (27/596): it ever carried `nish-reserved` or
  `needs-nish-decision`, or Nish commented after the call, and it did not
  close on a merged PR with neither of those.
- **agent route** (243/596): closed by a merged linked PR, no reserved label
  now, no Nish comment after the call.

The two are mutually exclusive; 326 closed issues are neither (closed with no
merged PR and no Nish decision).

### `reservedClass` → reserved route

Probability of "reserved" = `1 - p(auto_fixable)`.

| rule | flags | flag-rate | P | R | TP | FP | FN | TN |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| shadow: applied label is `nish-reserved`/`needs-nish-decision` | 7/596 | 1.2% | 1.00 | 0.26 | 7 | 0 | 20 | 569 |
| Jev p>=0.5 | 159/596 | 26.7% | 0.15 | 0.89 | 24 | 135 | 3 | 434 |
| Jev p>=0.7 | 110/596 | 18.5% | 0.19 | 0.78 | 21 | 89 | 6 | 480 |
| Jev p>=0.9 | 72/596 | 12.1% | 0.21 | 0.56 | 15 | 57 | 12 | 512 |

Jev recalls far more reserved-route issues than the label rule (0.89 vs 0.26
at p>=0.5) and its precision is far worse (0.15 vs 1.00). The three it misses
even at p>=0.5 were all called `auto_fixable`: fleet-ops#1359 (p 0.97),
#5787 (p 0.51), #5807 (p 1.00).

### `reservedClass` → agent route

Probability = `p(auto_fixable)`.

| rule | flags | flag-rate | P | R | TP | FP | FN | TN |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| shadow: applied label is **not** reserved | 589/596 | 98.8% | 0.41 | 1.00 | 243 | 346 | 0 | 7 |
| Jev p>=0.5 | 437/596 | 73.3% | 0.36 | 0.65 | 158 | 279 | 85 | 74 |
| Jev p>=0.7 | 403/596 | 67.6% | 0.33 | 0.55 | 133 | 270 | 110 | 83 |
| Jev p>=0.9 | 343/596 | 57.6% | 0.31 | 0.44 | 108 | 235 | 135 | 118 |

The label rule's perfect recall is an empty achievement: it flags 589 of 596
issues. Jev is stricter and, on this outcome, slightly less precise. Neither
separates "will be closed by an agent PR" from "will be closed some other
way" — the base rate among closed issues is 243/596 = 40.8%, and Jev's
precision sits below it at every threshold.

### Calibration

Closed issues, reserved route against `1 - p(auto_fixable)`:

| bucket | n | reserved-route | rate |
|---|---:|---:|---:|
| 0.0–0.1 | 343 | 2 | 0.006 |
| 0.1–0.2 | 42 | 0 | 0.000 |
| 0.2–0.3 | 18 | 0 | 0.000 |
| 0.3–0.4 | 13 | 0 | 0.000 |
| 0.4–0.5 | 21 | 1 | 0.048 |
| 0.5–0.6 | 31 | 1 | 0.032 |
| 0.6–0.7 | 18 | 2 | 0.111 |
| 0.7–0.8 | 16 | 3 | 0.188 |
| 0.8–0.9 | 22 | 3 | 0.136 |
| 0.9–1.0 | 72 | 15 | 0.208 |

The top bucket is the most enriched (0.208 vs a 27/596 = 0.045 base rate),
so the score ranks, but a 0.9 prediction lands right about a fifth of the
time. It is not a calibrated probability.

Same table for the agent route against `p(auto_fixable)`, closed issues:
0.0–0.1 is 35/68 = 0.52 and 0.9–1.0 is 108/343 = 0.31. The curve slopes the
wrong way. High confidence that the text is `auto_fixable` does not predict
closure by a merged PR.

### `labelsMatch` → label correction

Truth: a label was added or removed after the row's timestamp, or the issue's
reserved-ness changed relative to `label_class` recorded at call time.
91/1245 issues (36/596 closed). Probability of a predicted correction =
`1 - labelsMatch`.

| rule | flags | flag-rate | P | R | TP | FP | FN | TN |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| shadow: text reserved-ness differs from the applied label's | 336/1245 | 27.0% | 0.07 | 0.26 | 24 | 312 | 67 | 842 |
| Jev p>=0.5 | 225/1245 | 18.1% | 0.08 | 0.19 | 17 | 208 | 74 | 946 |
| Jev p>=0.7 | 89/1245 | 7.1% | 0.11 | 0.11 | 10 | 79 | 81 | 1075 |
| Jev p>=0.9 | 0/1245 | 0.0% | — | 0.00 | 0 | 0 | 91 | 1154 |

Jev never reached p>=0.9 on this question (max bucket 0.8–0.9, 43 rows, 5
positives). Precision stays near the 91/1245 = 7.3% base rate in every
bucket, so the probability carries nothing about whether a label later
changed. The structural comparison the site already computes
(`docs/label-sanity-2026-09.md` reports 336 such disagreements) predicts
correction no better: precision 0.07.

### Gate verdict — `label-sanity`

| gate | result |
|---|---|
| flag ceiling 25% | **FAIL** at p>=0.5 (26.7% on the closed slice, 32.1% = 400/1245 on the full cohort). p>=0.7 is under it (18.5%) |
| recall vs the rule it shadows | passes at every threshold (0.89/0.78/0.56 vs the label rule's 0.26) |
| reserved false-`auto_fixable` = 0 | **FAIL**. 3 of the 27 reserved-route issues were called `auto_fixable`, two of them confidently (fleet-ops#1359 at 0.97, #5807 at 1.00) |
| confident bucket | 15/72 = 0.21 of closed issues with p(reserved)>=0.9 actually took the reserved route |

**NO-GO.** No threshold is both under the flag ceiling and at zero reserved
false negatives. p>=0.7 is the only threshold under 25%, and it still misses
6 of 27 reserved-route issues, 3 of them called `auto_fixable`.

## 2. `vault-drop-routing` — agreement with the rule it shadows

The outcome this window can actually be joined to is the deterministic
path-rule placement, stamped per row in `baseline`. The curator's compiled
placement exists for 1/499 captures, so it is not usable. Full method, the
`memory_kind` → note-type map, and the independent 100-capture relabel are in
`docs/vault-drop-routing-2026-09.md`; the counts re-derived from the log for
this report agree with that file exactly.

| question | compared | agree | p>=0.9 agree |
|---|---:|---:|---:|
| `area` | 469/499 (30 baseline null) | 384/469 = 0.819 | 320/346 = 0.925 |
| `note_type` | 486/499 (13 baseline null) | 457/486 = 0.940 | 444/453 = 0.980 |

This is not a precision/recall against an external outcome: the only
joinable outcome **is** the rule, so "the rule's precision on the same rows"
would be 1 by construction. The meaningful number is the disagreement, and
the independent relabel already adjudicated it: where Jev was confident and
contradicted the path rule, the relabel sided with Jev 25 times of 26 on
area. Confident-bucket disagreement is 26/346 = 7.5% (area) and 9/453 = 2.0%
(note type), both under the 15% line.

Two caveats, both from that report and both still true: the rows stamp
`act_hi: null` because the band row was added after the run, and the
confident cut used is the `p >= 0.9` that `config/jev-bands.json` now pins
for the site.

**NO-GO for wiring, PASS for the disagreement gate.** The site beats the rule
it shadows on exactly the cases where the rule is a path artifact, but the
comparison is against the rule itself, not against a later human placement,
so it does not clear an outcome gate this report can verify.

## 3. Epic #7370 children this issue covers

Children 1, 2, 4 and 9 were scored in `docs/jev-benchmark-2026-09.md` and are
not re-opened here. Children 3, 5, 6, 7, 8 are the ones that were
"missing evidence" for lack of hand-labelled data.

| # | child | site log used | verdict |
|---|---|---|---|
| 3 | intake: scope score, cheap-vs-flagship tier, duplicate-of-open | none with >= 100 rows. `label-sanity` is the nearest reserved-class signal and is NO-GO | **NO-GO** on the reserved-route question (3 false `auto_fixable` on 27 reserved-route issues; flag 26.7% at p>=0.5). Scope, seat tier and duplicate detection have no log |
| 5 | packet-verdict (done / partial / empty-run / failed) | no site log | **missing evidence** |
| 6 | CI failure triage | `failure-triage`, 3 rows | **missing evidence** (below the 100-row bar) |
| 7 | Hermes message tiering | `hermes-digest`, 33 rows | **missing evidence** |
| 8 | findings-ledger class labelling + dedupe | no site log | **missing evidence** |

Nothing in this report is a measured GO, and no gate is wired.
