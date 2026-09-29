# Jev call sites in fleet-ops (measured 2026-09-29)

Live Jev call sites on origin/main as of 2026-09-29:
- `prompts/worker.md` step 4: `needsNish` Noul (blocker text only, no Exa)
- `config/litellm-proxy.yaml` `/jev` pass-through (infra)

Removed by lean sweep (#8959, 2026-09-29):
- `agent.yml` Gate `cheap_ok` Noul with full context + Exa
- `opus-vet.yml`, `fleet-map.yml`, `code-audit.yml`
- AI grader (grade.yml, opus-review, devin-grade, kimi-probe)

## Replay method
State mirrors the shipped #8894/#8905 Gate state:
```
{issue: {ref, title, body, labels}, blocked_by: [...], named_files_on_main: {path: text|"missing on main"}, repo_rules_AGENTS_md: 0509's AGENTS.md (169 chars), web_evidence: Exa highlights array}
```
Exa: `query=title[:120], numResults=5, type=auto, contents.highlights.maxCharacters=300, highlightsPerUrl=1`.

Run on the 63-issue corpus from #8905 (all 0509 issues with an `opus-size:` verdict at that date), against jev-1.13.0 on the VPS. Two runs.

## Candidate table

| # | Candidate | Population | Answer key | Replay agreement (run 1/2) | Harmful calls | Paid calls saved/week | Clears bar? |
|---|---|---|---|---|---|---|---|
| 1 | opus-size split vs strong-only (Choice) | 360 issues with an `opus-size:` verdict (search `in:comments`); 84 verdicts on the 63-issue corpus over 6 days (~98/wk) | `opus-size:` comments | lane Choice: 29/63 (46%) / 28/63 (44%) | 1 strong_only→small (0509#5740) | ~98 | **No** |
| 2 | opus-vet keep/close/park (Choice) | 658 issues with `opus-vet:` verdict; 32 with a key in corpus | `opus-vet:` comments | vet Choice: 9/32 (28%) / 10/32 (31%) | 23 keep→park | — | **No** |
| 3 | pre-grade before a PR opens (Noul) | 350 PRs with A+ grade; 888 issues carry `grade /` | `grade` comments | Not replayed — grader and every grade check deleted 2026-09-29 (#8953/#8959) | — | — | N/A — call site gone |
| 4 | worker park decision (needsNish) | 27 fleet-ops / 45 0509 `jev needsNish` comments; only 1 park body records `p(needsNish)` | parks Nish later resolved/reversed | Not run — n=1 usable answer key | — | small | **Too little history** |
| 5 | seat choice for a packet | 350 A+ PRs; grades name the grader ("Devin grade: A+"), not the building lane | measured first-try A+ by seat | Not run — no answer key; grade stream deleted | — | — | **Too little history** |
| 6 | 0509 product decisions (D2/D5/D6/D8/D9) | prod `jev_verdict`: 15 rows, 3 question ids (is_competitor 5, public_subject 5, identity_field_confidence.name 5), 10 reasons null | prod `jev_verdict` | Not run — D2/D5/D6/D8/D9 have 0 rows, gated on 0509#4834 (open) | — | — | **Too little history** |
| 7 | calibration from user corrections | `user_decision` table: 0 rows | prod `user_decision` | Not run — 0 user decisions recorded | — | — | **Too little history** |

## Baseline drift finding
The shipped `cheap_ok` Noul (candidate 1's small-or-not half, #8894/#8905) re-measured today on jev-1.13.0:
- 52/63 (83%) agreement = the always-"no" baseline (52 non-small of 63)
- 0 wrongly cheap (safety holds)
- 0 of 11 small caught — below #8905's 55–56/63 with 3–4/11 on 2026-09-28

The one shipped Jev decision has already drifted below its own acceptance bar on the same corpus and model version update. This validates the issue's "replay before wiring" discipline.

## Conclusion
No candidate clears the bar. No child issues will be filed. The fleet's single live Jev call site (`prompts/worker.md` step 4 `needsNish`) remains the only production Jev decision; its replay data is insufficient to prove a full-context+Exa upgrade. Any future Jev wiring must follow this replay method and clear the zero-harm bar per #8894's protocol.
