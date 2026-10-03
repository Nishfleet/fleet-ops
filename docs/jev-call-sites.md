# Jev call sites in fleet-ops (measured 2026-09-29)

Live Jev call sites on origin/main:
- `prompts/worker.md` step 4: the `needsNish` Noul (blocker text only, no Exa).
- `config/litellm-proxy.yaml`: the `/jev` TypeSafe pass-through (infra, not a decision).

Removed by the lean sweep (#8959, 2026-09-29): the `agent.yml` Gate `cheap_ok`
Noul with full context + Exa, `opus-vet.yml`, `fleet-map.yml`, `code-audit.yml`
and the AI grader (grade.yml, opus-review, devin-grade, kimi-probe).

## Replay method

The state mirrors the shipped #8894/#8905 Gate builder
(`git show 5f5c06a5:.github/workflows/agent.yml`, Gate step):

```
{issue: {ref, title, body, labels},
 blocked_by: [{n, title, state}],
 named_files_on_main: {path: text | "missing on main"},   # first 8 paths, 5k chars each
 repo_rules_AGENTS_md: the sized repo's AGENTS.md,        # 0509's is 169 chars
 web_evidence: [{title, url, highlight}] | "unavailable"}
```

Exa: `query=title[:120], numResults=5, type=auto,
contents.highlights.maxCharacters=300, highlightsPerUrl=1`. A missing key, an
HTTP error or zero results record `"unavailable"` and Jev still answers.

Two questions were replayed per issue, one Choice each, plus the shipped
`cheap_ok` Noul verbatim as the baseline. Verbatim instructions:

- `lane` (choice): "Which dispatch lane should take this packet?", criteria
  `small` "One behaviour, already shaped, and a cheap worker finishes it in a
  single run." / `split` "More than one independent behaviour, or enough work
  that it must be cut into separate packets before anyone builds it." /
  `strong_only` "The change cannot be designed without a senior reasoning model:
  architecture, a migration plan, or a product judgement call."
- `vet` (choice): "Is this issue a well-formed packet a worker can claim right
  now?", criteria `keep` "Well formed: the named files and prior art resolve on
  main, the acceptance is runnable, and nothing needs the owner. Claim it." /
  `close` "Not worth doing: duplicate, superseded, already shipped, or the
  requester is asking for something that will not exist." / `park` "Cannot be
  started now: it waits on another issue or PR, on a runtime gate, or on the
  owner. Leave it parked and do not claim it."
- `cheap_ok` (noul): the exact string at
  `git show 5f5c06a5:.github/workflows/agent.yml`, Gate step.

Corpus membership is pinned two ways: the issue-number list is the `0509#N`
refs extracted from the #8905 PR body
(`gh pr view 8905 -R Nishfleet/fleet-ops --json body`), 63 numbers, and each
issue's answer key is the newest `opus-size:` / `opus-vet:` comment at read time
(2026-09-29T17:5xZ), with the comment timestamp recorded per row. Nothing is
deduped or sampled. `~98/wk` is projected addressable volume from the timestamps
of the 84 `opus-size:` verdicts in the corpus (6 days), not a measured saving.

Corpus: the 63 0509 issues that carried an `opus-size:` verdict on 2026-09-28
(the corpus #8905 used), 84 `opus-size:` comments, 32 with an `opus-vet:`
verdict. Model: `jev-1.13.0` (the `/jev` response's `.model`), two runs.
Two failure classes are counted separately, because only the first costs
correctness:

- **harmful**: `strong_only` answered `small`/`split` (senior work onto a cheap
  lane) or `keep` answered `park` (work stalled that a worker could have
  claimed).
- **wasteful**: `split` answered `strong_only` (a paced senior seat spent on a
  packet a cheap lane could have cut), or `small` answered `split` (a cheap
  packet delayed a cut). Reported separately and never counted as harmful.

## Candidate table

| # | Candidate | Population | Answer key | Replay agreement (run 1 / run 2) | Harmful calls | Paid calls saved/wk | Clears bar? |
|---|---|---|---|---|---|---|---|
| 1 | opus-size split vs strong-only (Choice) | 360 issues carry an `opus-size:` verdict (GitHub search `in:comments`); 84 verdicts over 6 days on the 63-issue corpus (projected ~98/wk) | `opus-size:` comments | 29/63 (46%) / 28/63 (44%) | harmful 1 (`strong_only`→`small`, 0509#5740); wasteful 9/10 `split`→`strong_only` | projected ~98 | **No** |
| 2 | opus-vet keep/close/park (Choice) | 658 issues carry an `opus-vet:` verdict; 32 with an answer key in the corpus | `opus-vet:` comments | 9/32 (28%) / 10/32 (31%) | 23 / 22 `keep`→`park` | — | **No** |
| 3 | pre-grade before a PR opens (Noul) | 350 PRs with an A+ grade; 888 issues carry `grade /` | `grade` comments | Not replayed — the grader and every grade check were deleted 2026-09-29 (#8953, #8959) | — | — | N/A — call site gone |
| 4 | worker park decision (`needsNish`) | 27 fleet-ops / 45 0509 `jev needsNish` comments; 1 park body records `p(needsNish)` (0509#3990, p=0.84) | parks Nish later resolved or reversed | Not run — n=1 usable answer key | — | small | **Too little history** |
| 5 | seat choice for a packet | 350 A+ PRs, but the grades name the grader ("Devin grade: A+"), not the building lane | measured first-try A+ by seat | Not run — no answer key; the grade stream was deleted | — | — | **Too little history** |
| 6 | 0509 product decisions (D2/D5/D6/D8/D9) | prod `jev_verdict`: 15 rows, 3 question ids (is_competitor 5, public_subject 5, identity_field_confidence.name 5), 10 reasons null | prod `jev_verdict` (D1 746c6e3d) | Not run — D2/D5/D6/D8/D9 have 0 rows; core-loop gate 0509#4834 is open | — | — | **Too little history** |
| 7 | calibration from user corrections | prod `user_decision`: 0 rows (`entity` 6, `user` 6) | prod `user_decision` | Not run — 0 user decisions recorded | — | — | **Too little history** |

## Run detail

Run-to-run stability (same item answered the same way): `lane` 61/63, `vet`
62/63. `lane` confusion against the answer key, run 1: `small`→`small` 11/11,
`strong_only`→`strong_only` 1/2, `split`→`split` 17/50, `split`→`small` 24,
`split`→`strong_only` 9. The small class is perfect on this corpus; the whole
loss is inside the `split` class, which Jev reads as either end of the scale.
`vet` is the worst: it parks 23 of 29 issues the answer key says a worker
should claim.

### Baseline drift

The shipped `cheap_ok` Noul (#8894, #8905) re-measured on the same corpus and
builder:

| run | agrees with opus-size | wrongly cheap | small caught | mean p on big | mean p on small |
|---|---|---|---|---|---|
| #8905 run 2, 2026-09-28 | 55/63 | 0 | 3 of 11 | 0.67 (highest) | — |
| this replay run 1 | 52/63 | 0 | 0 of 11 | 0.227 (max 0.71) | 0.635 (max 0.88) |
| this replay run 2 | 52/63 | 0 | 0 of 11 | 0.226 (max 0.72) | 0.629 (max 0.89) |

52 is exactly the number of non-small issues in the corpus, so the shipped
question is now the always-"no" baseline while the safety bar (nothing big
called cheap) still holds. The one shipped Jev decision no longer reproduces
its own acceptance numbers on jev-1.13.0; re-running it is
Nishfleet/fleet-ops#8983.

## Conclusion

No candidate clears the bar, so no child issues are filed. The fleet's single
live Jev decision call site (`prompts/worker.md` step 4 `needsNish`; the `/jev`
pass-through in `config/litellm-proxy.yaml` is infrastructure, not a decision)
has n=1 of usable answer-key history, so a full-context+Exa upgrade cannot be
proven. Any future Jev wiring repeats this replay and clears the zero-harm bar
first.

Per-issue run rows (`/tmp/r2_1.json`, `/tmp/r2_2.json`) were scratch files on
the host that ran the replay and were not committed, so the tables above are
the only record; a reader who needs the rows reruns the replay using the
"Replay method" section.
